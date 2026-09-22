#!/usr/bin/env node
// Interactive wizard for claude-account. The bash CLI stays the engine (it is
// the only thing that touches the Keychain); this file is the screen.
//
// Env (set by `claude-account wizard`): CLAUDE_ACCOUNT_BIN (the CLI),
// CLAUDE_NATIVE_BIN (the real claude), CLAUDE_ACCOUNT_HOME (config dir).
import React, { useEffect, useState } from 'react';
import { render, Box, Text, useApp, useInput } from 'ink';
import SelectInput from 'ink-select-input';
import TextInput from 'ink-text-input';
import Spinner from 'ink-spinner';
import { spawn, execFile } from 'node:child_process';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

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

function loadProfiles() {
  const dir = join(HOME, 'profiles');
  if (!existsSync(dir)) return [];
  const active = readText(join(HOME, 'active'));
  const owner = readText(join(HOME, 'native-owner'));
  return readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => {
      const p = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      const email = p.account || (p.label || '').match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/)?.[0] || '';
      return { name: p.name, type: p.type, email, active: p.name === active, owner: p.name === owner, measurable: p.type === 'oauth_token' || !!p.measureKeychainService };
    })
    .sort((a, b) => (a.active === b.active ? a.name.localeCompare(b.name) : a.active ? -1 : 1));
}

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
    const [name, status, http, u5, , u7, , overage] = m.split(',');
    out[name] = { status, http, u5: u5 ? Math.round(parseFloat(u5) * 100) : null, u7: u7 ? Math.round(parseFloat(u7) * 100) : null, overage };
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
  const feed = (chunk) => {
    raw += chunk.toString();
    buf += stripAnsi(chunk.toString());
    if (!url) {
      // the CLI prints the URL as an OSC 8 hyperlink, whose payload is never wrapped
      const m = raw.match(/\x1b\]8;[^;]*;(https:\/\/claude\.com\/[^\x07\x1b]+)/) || buf.match(/(https:\/\/claude\.com\/\S+)/);
      if (m) { url = m[1]; onUrl(url); }
    }
    if (!asked && /Paste code here/i.test(buf)) { asked = true; onNeedCode(); }
  };
  child.stdout.on('data', feed);
  child.stderr.on('data', feed);
  child.on('error', () => onDone({ code: 127, token: null }));
  child.on('close', (code) => {
    const OAT = 'sk-ant-oat01';
    const oat = buf.match(new RegExp(OAT + '-[A-Za-z0-9_-]+', 'g'))?.pop() || null;
    onDone({ code, oat });
  });
  return { sendCode: (code) => child.stdin.write(code + '\n'), kill: () => child.kill() };
}

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

function QuotaLine({ q }) {
  return h(Box, null, h(Text, { color: C.muted }, '5h  '), h(Bar, { pct: q?.u5 }), h(Text, { color: C.muted }, '   7d  '), h(Bar, { pct: q?.u7 }));
}

function ProfileRow({ p, q, loading }) {
  const mark = p.active ? h(Text, { color: C.accent, bold: true }, '● ') : h(Text, { color: C.muted }, '○ ');
  const kind = p.type === 'native_archive' ? 'native login' : 'setup-token';
  const status = loading
    ? h(Text, { color: C.muted }, h(Spinner, { type: 'dots' }), ' measuring')
    : !q ? h(Text, { color: C.muted }, 'not measured')
    : q.status === 'allowed' ? h(Text, { color: C.ok }, '✓ ok')
    : q.status === 'rejected' ? h(Text, { color: C.fail }, '✗ quota exhausted')
    : q.status === 'unmeasurable' ? h(Text, { color: C.muted }, '- no measuring token')
    : h(Text, { color: C.fail }, `✗ token failing (HTTP ${q.http || '?'})`);
  return h(Box, { flexDirection: 'column', marginBottom: 1 },
    h(Box, null, mark, h(Text, { color: C.cream, bold: p.active }, p.name.padEnd(12)), h(Text, { color: C.muted }, `${kind}  ${p.email || ''}`)),
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
function Home({ profiles, quotas, loading, onPick }) {
  const items = [
    { label: 'Switch account', value: 'switch' },
    { label: 'Renew a token', value: 'renew' },
    { label: 'Sync native archive', value: 'sync' },
    { label: 'Doctor', value: 'doctor' },
    { label: 'Quit', value: 'quit' },
  ];
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: 'switch Claude Code accounts, no re-login' }),
    profiles.length === 0
      ? h(Text, { color: C.warn }, 'No profiles yet. Run: claude-account import-native <name>')
      : profiles.map((p) => h(ProfileRow, { key: p.name, p, q: quotas[p.name], loading })),
    h(Text, { color: C.muted }, 'What do you want to do?'),
    h(Menu, { items, onSelect: (i) => onPick(i.value) }),
    h(Hint, null, '↑↓ move · Enter select · q quit'));
}

function PickProfile({ title, profiles, filter, onPick, onBack }) {
  useInput((_, key) => { if (key.escape) onBack(); });
  const items = profiles.filter(filter).map((p) => ({ label: `${p.name}  ${p.email || ''}`.trim(), value: p.name }));
  return h(Box, { flexDirection: 'column' },
    h(Header, { subtitle: title }),
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
      onUrl: (u) => { setUrl(u); setMsg(`Sign in as ${profile.email || profile.name} and approve.`); },
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
    if (url) body.push(h(Text, { key: 'u', color: C.muted }, `Didn't open?  ${url}`), h(Text, { key: 'c', color: C.muted }, 'press c to copy the link'));
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

function App() {
  const { exit } = useApp();
  const [screen, setScreen] = useState('home');
  const [profiles, setProfiles] = useState(loadProfiles());
  const [quotas, setQuotas] = useState({});
  const [loading, setLoading] = useState(true);
  const [picked, setPicked] = useState(null);
  const [res, setRes] = useState(null);

  const refresh = () => {
    setProfiles(loadProfiles()); setLoading(true);
    run(['measure']).then((r) => { setQuotas(parseMeasure(r.stdout)); setLoading(false); });
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

  if (screen === 'home') return h(Home, { profiles, quotas, loading, onPick: (v) => {
    if (v === 'quit') exit();
    else if (v === 'switch') setScreen('switch');
    else if (v === 'renew') setScreen('renew-pick');
    else if (v === 'sync') showResult('sync native archive', run(['sync-archive']));
    else if (v === 'doctor') showResult('doctor', run(['doctor']));
  } });
  if (screen === 'switch') return h(PickProfile, { title: 'switch to which account?', profiles, filter: (p) => !p.active, onBack: goHome, onPick: (n) => showResult(`switch to ${n}`, run(['use', n])) });
  if (screen === 'renew-pick') return h(PickProfile, { title: 'renew the token of which profile?', profiles, filter: (p) => p.measurable, onBack: goHome, onPick: (n) => { setPicked(profiles.find((p) => p.name === n)); setScreen('renew'); } });
  if (screen === 'renew') return h(Renew, { profile: picked, onBack: goHome });
  if (screen === 'busy') return h(Box, { flexDirection: 'column' }, h(Header, { subtitle: 'working' }), h(Text, { color: C.accent }, h(Spinner, { type: 'dots' }), ' talking to the Keychain...'));
  if (screen === 'result') return h(Result, { ...res, onBack: goHome });
  return null;
}

render(h(App));
