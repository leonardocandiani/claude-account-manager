#!/usr/bin/env node
// Interactive wizard for claude-account. The bash CLI stays the engine (it is
// the only thing that touches the Keychain); this file is the screen.
//
// Env (set by `claude-account wizard`): CLAUDE_ACCOUNT_BIN (the CLI),
// CLAUDE_NATIVE_BIN (the real claude), CLAUDE_ACCOUNT_HOME (config dir).
import React, { useEffect, useRef, useState } from 'react';
import { render, Box, Text, useApp, useInput } from 'ink';
import SelectInput from 'ink-select-input';
import TextInput from 'ink-text-input';
import Spinner from 'ink-spinner';
import { spawn, execFile } from 'node:child_process';
import { readdirSync, readFileSync, existsSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const h = React.createElement;

// ---- theme: the README banner (dark, copper accent, cream title) ----------
const C = {
  accent: '#D97757',
  cream: '#F0E6D8',
  muted: '#8A8480',
  ok: '#7BC275',
  warn: '#E0B15C',
  fail: '#E06C5C',
  badgeBg: '#3A3532',
};

const CLI = process.env.CLAUDE_ACCOUNT_BIN || join(homedir(), 'bin', 'claude-account');
const NATIVE = process.env.CLAUDE_NATIVE_BIN || join(homedir(), '.local', 'bin', 'claude');
const HOME = process.env.CLAUDE_ACCOUNT_HOME || join(homedir(), '.config', 'claude-account');

// ---- data ------------------------------------------------------------------
const stripAnsi = (s) => stripOsc(s).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').replace(/\r/g, '');

function readText(p) {
  try { return readFileSync(p, 'utf8').trim(); } catch { return ''; }
}

function loadPolicy() {
  try { return JSON.parse(readFileSync(join(HOME, 'policy.json'), 'utf8')); } catch { return {}; }
}

// The autoswitch chain: preferred, fallback, then the reserves.
function loadChain() {
  const p = loadPolicy();
  return [p.preferred, p.fallback, ...(p.reserves || [])].filter(Boolean);
}

function loadQuarantine() {
  try {
    const q = JSON.parse(readFileSync(join(HOME, 'autoswitch-quarantine.json'), 'utf8'));
    const now = Date.now() / 1000;
    return new Set(Object.keys(q).filter((n) => Number(q[n]?.until) > now));
  } catch { return new Set(); }
}

// The same decision as bin/claude-account-autoswitch (tier, reset_order, best_target,
// up_target): the account whose weekly quota resets first is used first, and each keeps its
// floor until the last release_hours before its reset. Tier 0: room above the floor worth a
// switch; 1: room above the floor; 2: only the floor left; 9: nothing under exhausted_at, or
// no reading. `pick` is where the autoswitch would go now and `why` the reason.
export function planOf(chain, quotas, policy, { active = null, lastTo = null, out = loadQuarantine(), now = Date.now() / 1000 } = {}) {
  const t5 = policy.exhausted_at?.five_hour ?? 0.95;
  const t7 = policy.exhausted_at?.seven_day ?? 0.97;
  const b5 = policy.return_below?.five_hour ?? 0.70;
  const b7 = policy.return_below?.seven_day ?? 0.90;
  const fl = policy.floor?.seven_day ?? 0.10;
  const flh = policy.floor?.release_hours ?? 24;
  const tier = (q) => {
    if (!q || q.status !== 'allowed' || q.f5 >= t5 || q.f7 >= t7) return 9;
    const room = t7 - (q.r7 && q.r7 - now <= flh * 3600 ? 0 : fl) - q.f7;
    return room >= t7 - b7 - 1e-9 ? 0 : room > 1e-9 ? 1 : 2;
  };
  const order = chain.map((n, i) => ({ n, i, r: quotas[n]?.r7 || Infinity }))
    .sort((a, b) => a.r - b.r || a.i - b.i).map((x) => x.n);
  const tiers = Object.fromEntries(chain.map((n) => [n, tier(quotas[n])]));
  const plan = { order, tiers, pick: null, why: null, t5, floorPct: Math.round(fl * 100), releaseHours: flh };
  const cur = active || chain[0];
  if (!cur || !chain.includes(cur) || !['allowed', 'rejected'].includes(quotas[cur]?.status)) return plan;
  const at = tiers[cur];
  const best = order.filter((n) => n !== cur && !out.has(n)).reduce((b, n) => (tiers[n] < (b ? tiers[b] : 9) ? n : b), null);
  const down = best && tiers[best] < at ? best : null;
  plan.pick = cur; plan.why = at <= 1 ? 'room' : at === 2 ? 'all_at_floor' : 'none_left';
  if (active && lastTo && active !== lastTo) {
    if (at <= 1) plan.why = 'manual';
    else if (down) { plan.pick = down; plan.why = at === 2 ? 'at_floor' : 'full'; }
    return plan;
  }
  const up = order.slice(0, order.indexOf(cur)).find((n) => !out.has(n) && tiers[n] === 0 && quotas[n].f5 < b5);
  if (up) { plan.pick = up; plan.why = (quotas[up].r7 || Infinity) < (quotas[cur].r7 || Infinity) ? 'resets_sooner' : 'first_in_rotation'; }
  else if (at > 1 && down) { plan.pick = down; plan.why = at === 2 ? 'at_floor' : 'full'; }
  return plan;
}

// Time left until a reset, short: 47m, 1h49, 1d16h.
function until(epoch, now = Date.now() / 1000) {
  if (!epoch) return '';
  const m = Math.max(0, Math.round((epoch - now) / 60));
  const d = Math.floor(m / 1440), hh = Math.floor((m % 1440) / 60), mm = m % 60;
  return d ? `${d}d${hh}h` : hh ? `${hh}h${String(mm).padStart(2, '0')}` : `${mm}m`;
}

function loadProfiles() {
  const dir = join(HOME, 'profiles');
  if (!existsSync(dir)) return [];
  const active = readText(join(HOME, 'active'));
  const owner = readText(join(HOME, 'native-owner'));
  const chain = loadChain();
  const rank = (n) => chain.indexOf(n) + 1 || 99;
  return readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => {
      const p = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      const email = p.account || (p.label || '').match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/)?.[0] || '';
      return { name: p.name, type: p.type, email, full: !!p.secureStorageDir, active: p.name === active, owner: p.name === owner, measurable: p.type === 'oauth_token' || !!p.measureKeychainService };
    })
    .sort((a, b) => rank(a.name) - rank(b.name) || a.name.localeCompare(b.name));
}

// What the autoswitch did last, and where the background sessions run.
function lastDecision() {
  const lines = readText(join(HOME, 'autoswitch.log')).split('\n').filter((l) => / decision=/.test(l));
  const m = lines.pop()?.match(/^(\S+) active=(\S*) decision=(\S+) reason=(\S+)/);
  if (!m) return null;
  const at = new Date(m[1]);
  return { at: Number.isNaN(at.getTime()) ? m[1] : at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), decision: m[3], reason: m[4].replace(/_/g, ' ') };
}

function parseBgStatus(stdout) {
  const get = (k) => stdout.match(new RegExp(`^${k}: (.*)$`, 'm'))?.[1] || '';
  return { daemon: get('daemon_profile'), pending: get('pending'), sessions: Number(stdout.match(/^sessions\[(\d+)\]/m)?.[1] || 0) };
}

const RANK = ['', '①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨'];
const NAME_RE = /^[A-Za-z0-9._-]+$/;

function run(args, input) {
  return new Promise((resolve) => {
    const child = execFile(CLI, args, { env: process.env, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code ?? 1) : 0, stdout: stdout || '', stderr: stderr || '' });
    });
    if (input != null) { child.stdin.write(input); }
    child.stdin.end();
  });
}

function parseMeasure(stdout) {
  const out = {};
  for (const line of stdout.split('\n')) {
    const m = line.trim();
    if (!m || m.startsWith('profiles[')) continue;
    const [name, status, http, u5, r5, u7, r7, overage] = m.split(',');
    out[name] = {
      status, http, overage,
      u5: u5 ? Math.round(parseFloat(u5) * 100) : null, u7: u7 ? Math.round(parseFloat(u7) * 100) : null,
      f5: parseFloat(u5) || 0, f7: parseFloat(u7) || 0, r5: Number(r5) || null, r7: Number(r7) || null,
    };
  }
  return out;
}

// `claude setup-token` is an Ink app: without a tty it exits silently, and macOS
// `script`/`expect` do not forward a piped stdin. Python's pty module does, and
// python3 ships with the Xcode command line tools every Claude Code install needs.
// The window is made wide so the sign-in URL is not wrapped.
const PTY_BRIDGE = [
  'import os, pty, sys, fcntl, termios, struct, select',
  'pid, fd = pty.fork()',
  'if pid == 0:',
  '    os.execvp(sys.argv[1], sys.argv[1:])',
  'fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 400, 0, 0))',
  'stdin = sys.stdin.fileno()',
  'while True:',
  '    r, _, _ = select.select([fd, stdin], [], [])',
  '    if fd in r:',
  '        try: data = os.read(fd, 65536)',
  '        except OSError: break',
  '        if not data: break',
  '        os.write(1, data)',
  '    if stdin in r:',
  '        data = os.read(stdin, 65536)',
  '        if data: os.write(fd, data)',
  '_, status = os.waitpid(pid, 0)',
  'sys.exit(os.waitstatus_to_exitcode(status))',
].join('\n');

// OSC sequences (hyperlinks, titles) and CSI sequences, for plain-text matching.
const stripOsc = (s) => s.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '');

// Drives `claude setup-token` through pipes: the browser is opened by the
// child itself; we only read its screen to know when to hand over the code and
// to catch the token. The token never reaches the terminal.
function setupToken({ onUrl, onNeedCode, onDone }) {
  const child = spawn('python3', ['-c', PTY_BRIDGE, NATIVE, 'setup-token'], { env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: '', COLUMNS: '400' }, stdio: ['pipe', 'pipe', 'pipe'] });
  let buf = '';
  let raw = '';
  let url = null;
  let asked = false;
  let finished = false;
  const OAT = /sk-ant-oat01-[A-Za-z0-9_-]+(?=[^A-Za-z0-9_-])/g;
  // 2.1.310 does not exit after the token or after a refused code: it waits for an Enter that
  // never comes, and the wizard sat on "finishing the login" (30/10/2026). The screen decides.
  const finish = (r) => { if (finished) return; finished = true; onDone(r); child.kill(); };
  const feed = (chunk) => {
    raw += chunk.toString();
    buf += stripAnsi(chunk.toString());
    if (!url) {
      // the CLI prints the URL as an OSC 8 hyperlink, whose payload is never wrapped
      const m = raw.match(/\x1b\]8;[^;]*;(https:\/\/claude\.com\/[^\x07\x1b]+)/) || buf.match(/(https:\/\/claude\.com\/\S+)/);
      if (m) { url = m[1]; onUrl(url); }
    }
    // 2.1.310 draws the spaces as cursor moves: the stripped screen reads "Pastecodehere".
    if (!asked && /Paste\s*code\s*here/i.test(buf)) { asked = true; onNeedCode(); }
    const oat = buf.match(OAT)?.pop();
    if (oat) finish({ code: 0, oat });
    else if (asked && /OAuth\s*error/i.test(buf)) finish({ code: 1, oat: null });
  };
  child.stdout.on('data', feed);
  child.stderr.on('data', feed);
  child.on('error', () => finish({ code: 127, oat: null }));
  child.on('close', (code) => finish({ code, oat: buf.match(/sk-ant-oat01-[A-Za-z0-9_-]+/g)?.pop() || null }));
  // The prompt reads the pty in raw mode, where only CR is Enter: with LF the code was typed
  // and never submitted.
  return { sendCode: (code) => child.stdin.write(code + '\r'), kill: () => child.kill() };
}

// The code field shows right away and takes every key, so the link is copied as soon as it
// shows: a "press c" never reached the clipboard (30/10/2026).
const copyLink = (u) => { const p = execFile('pbcopy', [], () => {}); p.stdin.on('error', () => {}); p.stdin.end(u); };

// ---- small pieces ----------------------------------------------------------
const Badge = ({ label, value }) => h(Box, { marginRight: 1 },
  h(Text, { backgroundColor: C.badgeBg, color: C.muted }, ` ${label} `),
  h(Text, { backgroundColor: C.accent, color: '#1B1816', bold: true }, ` ${value} `));

const Header = ({ subtitle }) => h(Box, { flexDirection: 'column', marginBottom: 1 },
  h(Box, null, h(Text, { color: C.cream, bold: true }, 'claude-account'), h(Text, { color: C.muted }, '  ·  '), h(Text, { color: C.accent }, subtitle)),
  h(Box, { marginTop: 1 }, h(Badge, { label: 'PLATFORM', value: 'MACOS' }), h(Badge, { label: 'SECRETS', value: 'KEYCHAIN ONLY' }), h(Badge, { label: 'ENGINE', value: 'BASH + JQ' })));

// A paste often arrives as one chunk with a trailing newline; treat that as
// "typed and pressed Enter" instead of leaving a stray \r inside the value.
function Input({ value, onChange, onSubmit, mask }) {
  return h(TextInput, { value, mask, onSubmit,
    onChange: (v) => { if (/[\r\n]/.test(v)) onSubmit(v.replace(/[\r\n]/g, '')); else onChange(v); } });
}

const Hint = ({ children }) => h(Box, { marginTop: 1 }, h(Text, { color: C.muted }, children));

const Menu = ({ items, onSelect }) => h(SelectInput, {
  items,
  onSelect,
  indicatorComponent: ({ isSelected }) => h(Text, { color: C.accent }, isSelected ? '▸ ' : '  '),
  itemComponent: ({ isSelected, label }) => h(Text, { color: isSelected ? C.cream : C.muted, bold: isSelected }, label),
});

function Bar({ pct, width = 16 }) {
  if (pct == null) return h(Text, { color: C.muted }, '·'.repeat(width) + '   ?');
  const filled = Math.round((Math.min(pct, 100) / 100) * width);
  const color = pct >= 90 ? C.fail : pct >= 70 ? C.warn : C.ok;
  return h(Text, null, h(Text, { color }, '█'.repeat(filled)), h(Text, { color: C.badgeBg }, '█'.repeat(width - filled)), h(Text, { color: C.muted }, ` ${String(pct).padStart(3)}%`));
}

// ↻ and the time until that window resets.
const Reset = ({ at }) => h(Text, { color: C.muted }, (at ? ` ↻${until(at)}` : '').padEnd(8));

function QuotaLine({ q }) {
  return h(Box, null, h(Text, { color: C.muted }, '5h  '), h(Bar, { pct: q?.u5 }), h(Reset, { at: q?.r5 }), h(Text, { color: C.muted }, '  7d  '), h(Bar, { pct: q?.u7 }), h(Reset, { at: q?.r7 }));
}

// The window that holds an account back: the five-hour one when it is full, else the week.
const backIn = (q, t5) => until(q.f5 >= t5 && q.r5 ? q.r5 : q.r7);

function ProfileRow({ p, q, tier, rank, t5, loading, pad = 16 }) {
  const mark = p.active ? h(Text, { color: C.accent, bold: true }, '● ') : h(Text, { color: C.muted }, '○ ');
  const kind = p.type === 'native_archive' ? 'native login' : p.full ? 'full login' : 'setup-token';
  const num = h(Text, { color: rank === 1 ? C.accent : rank === 2 ? C.warn : C.muted, bold: true }, (RANK[rank] || ' ') + ' ');
  const status = loading
    ? h(Text, { color: C.muted }, h(Spinner, { type: 'dots' }), ' measuring')
    : !q ? h(Text, { color: C.muted }, 'not measured')
    : q.status === 'allowed' && tier === 2 ? h(Text, { color: C.warn }, '◐ reserve only')
    : q.status === 'allowed' && tier === 9 ? h(Text, { color: C.fail }, `✗ full, back in ${backIn(q, t5) || '?'}`)
    : q.status === 'allowed' ? h(Text, { color: C.ok }, '✓ ok')
    : q.status === 'rejected' ? h(Text, { color: C.fail }, `✗ quota exhausted${backIn(q, t5) ? `, back in ${backIn(q, t5)}` : ''}`)
    : q.status === 'unmeasurable' ? h(Text, { color: C.muted }, '- no quota reading (not counted as full)')
    : h(Text, { color: C.fail }, `✗ token failing (HTTP ${q.http || '?'})`);
  return h(Box, { flexDirection: 'column', marginBottom: 1 },
    h(Box, null, mark, num, h(Text, { color: C.cream, bold: p.active }, p.name.padEnd(pad)), h(Text, { color: C.muted }, `${kind}  ${p.email || ''}`)),
    h(Box, { marginLeft: 2 }, h(QuotaLine, { q }), h(Text, null, '   '), status));
}

function Steps({ steps, current, failedAt }) {
  return h(Box, { flexDirection: 'column', marginBottom: 1 }, steps.map((s, i) => {
    let icon, color;
    if (failedAt === i) { icon = '✗'; color = C.fail; }
    else if (i < current) { icon = '✓'; color = C.ok; }
    else if (i === current) { icon = h(Spinner, { type: 'dots' }); color = C.accent; }
    else { icon = '○'; color = C.muted; }
    return h(Box, { key: s }, h(Text, { color }, icon, ' '), h(Text, { color: i === current ? C.cream : C.muted, bold: i === current }, `${i + 1}/${steps.length}  ${s}`));
  }));
}

// ---- screens ---------------------------------------------------------------
function Overview({ profiles, bg, plan }) {
  const active = profiles.find((p) => p.active)?.name || 'none';
  const off = existsSync(join(HOME, 'autoswitch.off'));
  const chain = plan.order;
  const last = lastDecision();
  const behind = bg && bg.sessions > 0 && bg.daemon && bg.daemon !== active;
  return h(Box, { flexDirection: 'column', marginBottom: 1 },
    h(Box, null, h(Text, { color: C.muted }, 'autoswitch  '),
      h(Text, { color: off ? C.warn : C.ok, bold: true }, off ? 'off' : 'on'),
      h(Text, { color: C.muted }, chain.length ? `   ${chain.map((n, i) => `${RANK[i + 1] || ''} ${n}`).join('  →  ')}` : '   no rotation set')),
    chain.length ? h(Text, { color: C.muted }, `             soonest weekly reset first; each keeps ${plan.floorPct}% until its last ${plan.releaseHours}h`) : null,
    last ? h(Text, { color: C.muted }, `             last check ${last.at}: ${last.decision} (${last.reason})`) : null,
    !bg ? h(Text, { color: C.muted }, h(Spinner, { type: 'dots' }), ' background sessions...')
      : h(Box, null, h(Text, { color: C.muted }, 'background  '),
        bg.sessions === 0 ? h(Text, { color: C.muted }, 'no sessions')
          : h(Text, { color: behind ? C.warn : C.cream }, `${bg.sessions} session${bg.sessions === 1 ? '' : 's'} on ${bg.daemon || '?'}`),
        behind ? h(Text, { color: C.warn }, `, not on ${active} yet${bg.pending && bg.pending !== 'no' ? ' (move pending)' : ''}`) : null));
}

function Home({ profiles, quotas, loading, bg, onPick }) {
  const active = profiles.find((p) => p.active)?.name;
  const plan = planOf(loadChain(), quotas, loadPolicy());
  const pos = (n) => { const i = plan.order.indexOf(n); return i < 0 ? 99 : i; };
  const rows = [...profiles].sort((a, b) => pos(a.name) - pos(b.name) || a.name.localeCompare(b.name));
  const behind = bg && bg.sessions > 0 && bg.daemon && bg.daemon !== active;
  const items = [
    { label: 'Switch account', value: 'switch' },
    ...(behind ? [{ label: `Move background sessions to ${active} now`, value: 'move' }] : []),
    { label: 'Add an account', value: 'add' },
    { label: 'Rotation and autoswitch', value: 'rotation' },
    { label: 'Renew a token', value: 'renew' },
    { label: 'Log in an account (browser)', value: 'login' },
    { label: 'Doctor', value: 'doctor' },
    { label: 'Sync native archive', value: 'sync' },
    { label: 'Update Claude Code', value: 'update' },
    { label: 'Quit', value: 'quit' },
  ];
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: 'switch Claude Code accounts, no re-login' }),
    h(Overview, { profiles, bg, plan }),
    profiles.length === 0
      ? h(Text, { color: C.warn }, 'No accounts yet. Choose "Add an account".')
      : rows.map((p) => h(ProfileRow, { key: p.name, p, q: quotas[p.name], tier: plan.tiers[p.name], rank: pos(p.name) + 1, t5: plan.t5, loading, pad: Math.max(12, ...profiles.map((x) => x.name.length)) + 2 })),
    h(Text, { color: C.muted }, 'What do you want to do?'),
    h(Menu, { items, onSelect: (i) => onPick(i.value) }),
    h(Hint, null, '↑↓ move · Enter select · q quit'));
}

function PickProfile({ title, profiles, filter, onPick, onBack, describe, note }) {
  useInput((_, key) => { if (key.escape) onBack(); });
  const items = profiles.filter(filter).map((p) => ({ label: describe ? describe(p) : `${p.name}  ${p.email || ''}`.trim(), value: p.name }));
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: title }),
    note ? h(Box, { marginBottom: 1 }, h(Text, { color: C.cream }, note)) : null,
    items.length === 0 ? h(Text, { color: C.warn }, 'Nothing to pick here.') : h(Menu, { items, onSelect: (i) => onPick(i.value) }),
    h(Hint, null, '↑↓ move · Enter select · Esc back'));
}

function Result({ title, lines, ok, onBack }) {
  useInput((_, key) => { if (key.escape || key.return) onBack(); });
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: title }),
    lines.map((l, i) => {
      const color = /^\[FAIL\]|ERROR/.test(l) ? C.fail : /^\[warn\]/.test(l) ? C.warn : /^\[ok\]/.test(l) ? C.ok : C.cream;
      return h(Text, { key: i, color }, l);
    }),
    h(Box, { marginTop: 1 }, h(Text, { color: ok ? C.ok : C.fail, bold: true }, ok ? '✓ done' : '✗ failed')),
    h(Hint, null, 'Enter or Esc back'));
}

function Renew({ profile, onBack }) {
  const steps = ['Browser login', 'Check the token', 'Store in the Keychain'];
  const [step, setStep] = useState(0);
  const [failedAt, setFailedAt] = useState(null);
  const [url, setUrl] = useState(null);
  const [needCode, setNeedCode] = useState(false);
  const [code, setCode] = useState('');
  const [token, setToken] = useState(null);
  const [email, setEmail] = useState(profile.email || '');
  const [askEmail, setAskEmail] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [msg, setMsg] = useState('Opening the browser...');
  const [result, setResult] = useState(null);
  const [ctl, setCtl] = useState(null);

  useEffect(() => {
    const c = setupToken({
      onUrl: (u) => { setUrl(u); copyLink(u); setMsg(`Sign in as ${profile.email || profile.name} and approve.`); },
      onNeedCode: () => setNeedCode(true),
      onDone: ({ oat: t }) => {
        if (!t) { setFailedAt(0); setMsg('The browser login did not finish. Nothing changed.'); return; }
        setToken(t); setNeedCode(false); setStep(1); setMsg('Token received (kept hidden).');
        if (!profile.email) setAskEmail(true); else setConfirm(true);
      },
    });
    setCtl(c);
    return () => c.kill();
  }, []);

  useInput((input, key) => {
    if (key.escape) { if (confirm || askEmail || failedAt != null || result) onBack(); return; }
    if (key.return && result) { onBack(); return; }
    if (input === 'c' && url && !needCode && !askEmail) {
      const p = execFile('pbcopy', [], () => {});
      p.stdin.end(url);
      setMsg('Link copied to the clipboard.');
    }
    if (confirm && key.return) {
      setConfirm(false); setStep(2);
      const args = ['renew', profile.name, '--token-stdin'];
      if (email) args.push('--account', email);
      run(args, token + '\n').then((r) => {
        const line = r.stdout.match(/renewed: (.*)/)?.[1] || '';
        const q = line ? parseMeasure(line)[profile.name] : null;
        if (r.code === 0 && q) { setStep(3); setResult({ ok: true, q }); }
        else { setFailedAt(2); setResult({ ok: false, err: stripAnsi(r.stderr).trim().split('\n').pop() }); }
      });
    }
  });

  const body = [];
  if (step === 0 && failedAt == null) {
    body.push(h(Text, { key: 'm', color: C.cream }, msg));
    if (url) body.push(h(Text, { key: 'u', color: C.muted }, `Didn't open?  ${url}`), h(Text, { key: 'c', color: C.muted }, 'the link is already in the clipboard'));
    if (needCode) body.push(h(Box, { key: 'i', marginTop: 1 }, h(Text, { color: C.accent }, 'Paste the code here ▸ '), h(Input, { value: code, onChange: setCode, mask: '•', onSubmit: (v) => { ctl.sendCode(v.trim()); setNeedCode(false); setMsg('Code sent, finishing the login...'); } })));
  }
  if (step >= 1 && !result) {
    body.push(h(Text, { key: 'm', color: C.cream }, msg));
    if (askEmail) body.push(h(Box, { key: 'e', marginTop: 1 }, h(Text, { color: C.accent }, 'Which e-mail did you sign in with? ▸ '), h(Input, { value: email, onChange: setEmail, onSubmit: (v) => { setEmail((v ?? email).trim()); setAskEmail(false); setConfirm(true); } })));
    if (confirm) body.push(h(Box, { key: 'k', marginTop: 1 }, h(Text, { color: C.cream }, 'Store this token for '), h(Text, { color: C.accent, bold: true }, profile.name), h(Text, { color: C.cream }, email ? ` (${email})` : ''), h(Text, { color: C.muted }, '   Enter to store · Esc to abort')));
  }
  if (result?.ok) {
    body.push(h(Text, { key: 'd', color: C.ok, bold: true }, `✓ ${profile.name} renewed${email ? ` (${email})` : ''}`));
    body.push(h(Box, { key: 'q', marginTop: 1 }, h(QuotaLine, { q: result.q }), h(Text, { color: C.muted }, `   overage ${result.q.overage || '?'}`)));
    body.push(h(Hint, { key: 'h' }, 'Enter or Esc back'));
  }
  if (result && !result.ok) body.push(h(Text, { key: 'x', color: C.fail }, result.err || 'failed'), h(Hint, { key: 'h' }, 'Esc back'));
  if (failedAt === 0) body.push(h(Text, { key: 'x', color: C.fail }, msg), h(Hint, { key: 'h' }, 'Esc back'));

  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: `renew ${profile.type === 'oauth_token' ? 'sign-in' : 'quota-measuring'} token · ${profile.name}` }),
    h(Steps, { steps, current: step, failedAt }),
    ...body);
}

// New account: name, browser login, e-mail, rotation, then store. The token
// never reaches the screen; it goes from the browser login straight to
// `add-oauth --token-stdin`.
function AddAccount({ profiles, onBack, onSwitch, onFullLogin }) {
  const steps = ['Name', 'Browser login', 'Details', 'Store and measure'];
  const [step, setStep] = useState(0);
  const [failedAt, setFailedAt] = useState(null);
  const [name, setName] = useState('');
  const [nameErr, setNameErr] = useState('');
  const [url, setUrl] = useState(null);
  const [needCode, setNeedCode] = useState(false);
  const [code, setCode] = useState('');
  const [token, setToken] = useState(null);
  const [email, setEmail] = useState('');
  const [askEmail, setAskEmail] = useState(false);
  const [reserve, setReserve] = useState(true);
  const [askReserve, setAskReserve] = useState(false);
  const [msg, setMsg] = useState('');
  const [result, setResult] = useState(null);
  const [ctl, setCtl] = useState(null);
  const storing = useRef(false);

  useEffect(() => () => ctl?.kill(), [ctl]);

  const submitName = (v) => {
    const n = (v ?? name).trim();
    if (!NAME_RE.test(n)) { setNameErr('Use letters, digits, dot, dash or underscore.'); return; }
    if (profiles.some((p) => p.name === n)) { setNameErr(`"${n}" already exists. To refresh its token, use "Renew a token".`); return; }
    setName(n); setNameErr(''); setStep(1); setMsg('Opening the browser...');
    setCtl(setupToken({
      onUrl: (u) => { setUrl(u); copyLink(u); setMsg('Sign in with the account you are adding and approve.'); },
      onNeedCode: () => setNeedCode(true),
      onDone: ({ oat: t }) => {
        if (!t) { setFailedAt(1); setMsg('The browser login did not finish. Nothing was stored.'); return; }
        setToken(t); setNeedCode(false); setStep(2); setMsg('Signed in (the token stays hidden).'); setAskEmail(true);
      },
    }));
  };

  const store = () => {
    // Two quick keys can land before the re-render: store once.
    if (storing.current) return;
    storing.current = true;
    setStep(3); setMsg('Checking the token with the API and storing it in the Keychain...');
    const args = ['add-oauth', name, '--token-stdin'];
    if (email) args.push('--account', email);
    if (reserve) args.push('--reserve');
    run(args, token + '\n').then((r) => {
      setToken(null);
      const line = r.stdout.match(/added: (.*)/)?.[1] || '';
      const q = line ? parseMeasure(line)[name] : null;
      if (r.code === 0) { setStep(4); setResult({ ok: true, q, rank: loadChain().indexOf(name) + 1 }); }
      else { setFailedAt(3); setResult({ ok: false, err: stripAnsi(r.stderr).trim().split('\n').pop() }); }
    });
  };

  useInput((input, key) => {
    if (key.escape && !result?.ok) { onBack(); return; }
    if (input === 'c' && url && step === 1 && !needCode) {
      const p = execFile('pbcopy', [], () => {});
      p.stdin.end(url);
      setMsg('Link copied to the clipboard.');
    }
    if (askReserve) {
      if (input === 'y' || input === 'Y') { setReserve(true); setAskReserve(false); store(); }
      else if (input === 'n' || input === 'N') { setReserve(false); setAskReserve(false); store(); }
      else if (key.return) { setAskReserve(false); store(); }
    }
  });

  const body = [];
  if (step === 0) {
    body.push(h(Box, { key: 'n' }, h(Text, { color: C.accent }, 'Name for this account ▸ '), h(Input, { value: name, onChange: (v) => { setName(v); setNameErr(''); }, onSubmit: submitName })));
    body.push(h(Text, { key: 'nh', color: nameErr ? C.fail : C.muted }, nameErr || 'A short label, e.g. work or personal-2. It is how you pick it later.'));
  }
  if (step === 1 && failedAt == null) {
    body.push(h(Text, { key: 'm', color: C.cream }, msg));
    if (url) body.push(h(Text, { key: 'u', color: C.muted }, `Didn't open?  ${url}`), h(Text, { key: 'c', color: C.muted }, 'the link is already in the clipboard'));
    if (needCode) body.push(h(Box, { key: 'i', marginTop: 1 }, h(Text, { color: C.accent }, 'Paste the code here ▸ '), h(Input, { value: code, onChange: setCode, mask: '•', onSubmit: (v) => { ctl.sendCode(v.trim()); setNeedCode(false); setMsg('Code sent, finishing the login...'); } })));
  }
  if (step === 2) {
    body.push(h(Text, { key: 'm', color: C.ok }, `✓ ${msg}`));
    if (askEmail) body.push(h(Box, { key: 'e', marginTop: 1 }, h(Text, { color: C.accent }, 'E-mail of this account (Enter to skip) ▸ '), h(Input, { value: email, onChange: setEmail, onSubmit: (v) => { setEmail((v ?? email).trim()); setAskEmail(false); setAskReserve(true); } })));
    if (askReserve) body.push(h(Box, { key: 'r', marginTop: 1 }, h(Text, { color: C.cream }, 'Add it to the automatic rotation, after the accounts already there? '), h(Text, { color: C.accent, bold: true }, '[Y/n]')));
  }
  if (step === 3 && !result) body.push(h(Text, { key: 'm', color: C.accent }, h(Spinner, { type: 'dots' }), ` ${msg}`));
  if (result?.ok) {
    body.push(h(Text, { key: 'd', color: C.ok, bold: true }, `✓ ${name} added${email ? ` (${email})` : ''}${result.rank ? `, ${RANK[result.rank] || `#${result.rank}`} in the rotation` : ''}`));
    if (result.q) body.push(h(Box, { key: 'q', marginTop: 1 }, h(QuotaLine, { q: result.q })));
    body.push(h(Box, { key: 'nx', marginTop: 1 }, h(Text, { color: C.muted }, 'What now?')));
    body.push(h(Menu, { key: 'menu', items: [
      { label: `Switch to ${name} now (moves every session)`, value: 'switch' },
      { label: 'Full login too, for claude.ai connectors (browser, once)', value: 'login' },
      { label: 'Back', value: 'back' },
    ], onSelect: (i) => (i.value === 'switch' ? onSwitch(name) : i.value === 'login' ? onFullLogin(name) : onBack()) }));
  }
  if (result && !result.ok) body.push(h(Text, { key: 'x', color: C.fail }, result.err || 'failed'), h(Hint, { key: 'h' }, 'Nothing was stored. Esc back'));
  if (failedAt === 1) body.push(h(Text, { key: 'x', color: C.fail }, msg), h(Hint, { key: 'h' }, 'Esc back'));

  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: 'add an account' }),
    h(Steps, { steps, current: step, failedAt }),
    ...body,
    step < 3 && failedAt == null ? h(Hint, { key: 'esc' }, 'Esc cancels, nothing is stored until the last step') : null);
}

// Rotation: the order the autoswitch walks, and its on/off switch.
function Rotation({ profiles, onBack, onRun }) {
  const [order, setOrder] = useState(null);
  const chain = loadChain();
  const { floorPct, releaseHours } = planOf(chain, {}, loadPolicy());
  const off = existsSync(join(HOME, 'autoswitch.off'));
  useInput((_, key) => { if (key.escape) { if (order) setOrder(null); else onBack(); } });

  if (order) {
    const left = profiles.filter((p) => !order.includes(p.name));
    const items = [
      ...left.map((p) => ({ label: `${p.name}  ${p.email || ''}`.trim(), value: p.name })),
      ...(order.length >= 2 ? [{ label: `Done: ${order.join(' → ')}`, value: '__done' }] : []),
    ];
    return h(Box, { flexDirection: 'column' },
      h(Header, { subtitle: 'set the rotation order' }),
      h(Text, { color: C.cream }, order.length ? `So far: ${order.map((n, i) => `${RANK[i + 1]} ${n}`).join('  ')}` : 'Pick the account to use first.'),
      h(Text, { color: C.muted }, order.length ? `Pick account ${order.length + 1}, or Done.` : ''),
      h(Menu, { items, onSelect: (i) => {
        const next = i.value === '__done' ? order : [...order, i.value];
        if (i.value === '__done' || next.length === profiles.length) onRun('rotation', ['rotation', 'set', ...next]);
        else setOrder(next);
      } }),
      h(Hint, null, 'Enter picks · Esc back'));
  }
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: 'rotation and autoswitch' }),
    h(Text, { color: C.muted }, 'Every 5 minutes the autoswitch measures these accounts and uses first the one whose'),
    h(Text, { color: C.muted }, `weekly quota resets first, so none expires unused. Each keeps ${floorPct}% of its week until`),
    h(Text, { color: C.muted }, `the last ${releaseHours}h before its reset, spent only once every account is down to its own.`),
    h(Text, { color: C.muted }, 'This order breaks ties.'),
    h(Box, { flexDirection: 'column', marginY: 1 },
      chain.length ? chain.map((n, i) => h(Text, { key: n, color: C.cream }, `${i + 1}. ${n}`)) : h(Text, { color: C.warn }, 'No rotation yet.')),
    h(Box, null, h(Text, { color: C.muted }, 'autoswitch is '), h(Text, { color: off ? C.warn : C.ok, bold: true }, off ? 'off' : 'on')),
    h(Menu, { items: [
      { label: 'Change the order', value: 'order' },
      { label: off ? 'Turn the autoswitch on' : 'Turn the autoswitch off (switch only by hand)', value: 'toggle' },
      { label: 'Back', value: 'back' },
    ], onSelect: (i) => (i.value === 'order' ? setOrder([]) : i.value === 'toggle' ? onRun('autoswitch', ['rotation', off ? 'on' : 'off']) : onBack()) }),
    h(Hint, null, '↑↓ move · Enter select · Esc back'));
}

function UpdateClaude({ onBack, onApply }) {
  const [info, setInfo] = useState(null);
  useEffect(() => {
    run(['update']).then((r) => {
      const kv = Object.fromEntries(r.stdout.split('\n').map((l) => l.match(/^(\w+): (.*)$/)).filter(Boolean).map((m) => [m[1], m[2]]));
      setInfo({ ...kv, ok: r.code === 0, error: r.code === 0 ? null : stripAnsi(r.stdout + r.stderr).trim() });
    });
  }, []);
  useInput((_, key) => { if (key.escape) onBack(); });
  if (!info) return h(Box, { flexDirection: 'column' }, h(Header, { subtitle: 'update Claude Code' }), h(Text, { color: C.accent }, h(Spinner, { type: 'dots' }), ' checking the versions...'));
  if (!info.ok) return h(Box, { flexDirection: 'column' }, h(Header, { subtitle: 'update Claude Code' }), h(Text, { color: C.fail }, info.error), h(Hint, null, 'Esc back'));
  const staleCopy = info.stable && info.stable !== 'none' && info.stable !== info.installed;
  const behind = /^\d/.test(info.latest || '') && info.latest !== info.installed;
  const n = Number(info.background_sessions || 0);
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: 'update Claude Code' }),
    h(Text, { color: C.cream }, `installed  ${info.installed}   (claude-stable ${info.stable})`),
    h(Text, { color: behind ? C.warn : C.ok }, `latest     ${info.latest}`),
    h(Text, { color: C.muted }, n ? `${n} background session${n === 1 ? '' : 's'}: restarted on the new version with the same ids, Orca too, as a switch does` : 'no background sessions'),
    h(Box, { marginTop: 1 }, h(Menu, { items: [
      ...(behind ? [{ label: `Update to ${info.latest} now`, value: 'apply' }]
        : staleCopy ? [{ label: `Refresh claude-stable to ${info.installed}`, value: 'refresh' }] : []),
      { label: behind || staleCopy ? 'Back' : 'Up to date. Back', value: 'back' },
    ], onSelect: (i) => (i.value === 'apply' ? onApply(info.latest) : i.value === 'refresh' ? onApply(info.installed) : onBack()) })),
    h(Hint, null, '↑↓ move · Enter select · Esc back'));
}

function App() {
  const { exit } = useApp();
  const [screen, setScreen] = useState('home');
  const [profiles, setProfiles] = useState(loadProfiles());
  const [quotas, setQuotas] = useState({});
  const [loading, setLoading] = useState(true);
  const [picked, setPicked] = useState(null);
  const [res, setRes] = useState(null);
  const [bg, setBg] = useState(null);

  const refresh = () => {
    setProfiles(loadProfiles()); setLoading(true);
    run(['measure']).then((r) => { setQuotas(parseMeasure(r.stdout)); setLoading(false); });
    run(['bg-status']).then((r) => setBg(r.code === 0 ? parseBgStatus(r.stdout) : null));
  };
  useEffect(refresh, []);
  useInput((input) => { if (screen === 'home' && input === 'q') exit(); });

  const goHome = () => { setScreen('home'); refresh(); };
  const showResult = (title, promise) => {
    setScreen('busy');
    promise.then((r) => {
      const lines = (r.stdout + '\n' + r.stderr).split('\n').map(stripAnsi).map((l) => l.replace(/^claude-account: /, '')).filter(Boolean);
      setRes({ title, lines, ok: r.code === 0 }); setScreen('result');
    });
  };

  if (screen === 'home') return h(Home, { profiles, quotas, loading, bg, onPick: (v) => {
    if (v === 'quit') exit();
    else if (v === 'switch') setScreen('switch');
    else if (v === 'move') showResult('move background sessions', run(['bg-restart', '--force']));
    else if (v === 'add') setScreen('add');
    else if (v === 'rotation') setScreen('rotation');
    else if (v === 'renew') setScreen('renew-pick');
    else if (v === 'login') setScreen('login-pick');
    else if (v === 'sync') showResult('sync native archive', run(['sync-archive']));
    else if (v === 'doctor') showResult('doctor', run(['doctor']));
    else if (v === 'update') setScreen('update');
  } });
  if (screen === 'switch') {
    const activeName = profiles.find((p) => p.active)?.name;
    const lastTo = (() => { try { return JSON.parse(readFileSync(join(HOME, 'autoswitch-state.json'), 'utf8')).to || null; } catch { return null; } })();
    const plan = planOf(loadChain(), quotas, loadPolicy(), { active: activeName, lastTo });
    const pos = (n) => { const i = plan.order.indexOf(n); return i < 0 ? 99 : i; };
    const pad = Math.max(12, ...profiles.map((x) => x.name.length)) + 2;
    const moves = plan.pick && plan.pick !== activeName;
    const describe = (p) => {
      const q = quotas[p.name];
      if (!q || q.u7 == null) return `${p.name.padEnd(pad)}no quota reading`;
      const t = plan.tiers[p.name];
      const tag = moves && p.name === plan.pick ? '   recommended' : t === 2 ? '   reserve only' : t === 9 ? `   full, back in ${backIn(q, plan.t5) || '?'}` : '';
      return `${p.name.padEnd(pad)}5h ${String(q.u5).padStart(3)}%   7d ${String(q.u7).padStart(3)}% ↻${until(q.r7) || '?'}${tag}`;
    };
    const reserve = `its ${plan.floorPct}% reserve`;
    const note = !plan.pick ? null
      : moves ? `Recommended: ${plan.pick}${{
        resets_sooner: `, its weekly quota resets before ${activeName}'s (in ${until(quotas[plan.pick]?.r7) || '?'})`,
        first_in_rotation: ', first in the rotation and with room again',
        at_floor: `: ${activeName} is down to ${reserve}`,
        full: `: ${activeName} is full`,
      }[plan.why] || ''}.`
      : `The autoswitch would stay on ${activeName}${{
        room: `: no account that resets sooner has room worth a switch`,
        manual: `: you picked it and it still has room above ${reserve}`,
        all_at_floor: `: every other account is down to its reserve too`,
        none_left: ': no other account has room',
      }[plan.why] || ''}.`;
    return h(PickProfile, { title: 'switch to which account?', profiles: [...profiles].sort((a, b) => pos(a.name) - pos(b.name)), filter: (p) => !p.active, describe, note, onBack: goHome, onPick: (n) => showResult(`switch to ${n}`, run(['use', n])) });
  }
  if (screen === 'renew-pick') return h(PickProfile, { title: 'renew the token of which profile?', profiles, filter: (p) => p.measurable, onBack: goHome, onPick: (n) => { setPicked(profiles.find((p) => p.name === n)); setScreen('renew'); } });
  if (screen === 'renew') return h(Renew, { profile: picked, onBack: goHome });
  if (screen === 'add') return h(AddAccount, { profiles, onBack: goHome, onSwitch: (n) => showResult(`switch to ${n}`, run(['use', n])), onFullLogin: (n) => { loginAfterExit = n; exit(); } });
  if (screen === 'rotation') return h(Rotation, { profiles, onBack: goHome, onRun: (title, args) => showResult(title, run(args)) });
  // The browser login needs the real terminal, so the wizard steps aside and
  // hands it to `claude-account login` once Ink has unmounted.
  if (screen === 'login-pick') return h(PickProfile, { title: 'log in which account? (native: fresh login; setup-token: full login for connectors)', profiles, filter: () => true, onBack: goHome, onPick: (n) => { loginAfterExit = n; exit(); } });
  if (screen === 'update') return h(UpdateClaude, { onBack: goHome, onApply: (ver) => showResult(`update Claude Code to ${ver}`, run(['update', '--apply', ver])) });
  if (screen === 'busy') return h(Box, { flexDirection: 'column' }, h(Header, { subtitle: 'working' }), h(Text, { color: C.accent }, h(Spinner, { type: 'dots' }), ' talking to the Keychain...'));
  if (screen === 'result') return h(Result, { ...res, onBack: goHome });
  return null;
}

let loginAfterExit = null;
// Imported (by the tests, for planOf) it only defines; run as a program it draws the screen.
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) render(h(App)).waitUntilExit().then(() => {
  if (!loginAfterExit) return;
  if (process.stdin.isTTY) process.stdin.setRawMode(false);
  process.stdin.pause();
  spawn(CLI, ['login', loginAfterExit], { stdio: 'inherit' })
    .on('error', (err) => { console.error(`claude-account: could not start login: ${err.message}`); process.exit(1); })
    .on('exit', (code) => process.exit(code ?? 1));
});
