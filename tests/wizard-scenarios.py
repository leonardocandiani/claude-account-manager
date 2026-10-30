#!/usr/bin/env python3
"""Drives the wizard in a pseudo-terminal with `security`, `curl`, `launchctl` and
the native `claude` stubbed: adds an account end to end and checks the rotation
screen. Needs node 22+ and the wizard dependencies installed by install.sh."""
import json, os, pty, re, select, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.expanduser('~/.local/lib/claude-account-manager/wizard/node_modules')
if not os.path.isdir(DEPS) or not shutil.which('node'):
    print('skip: wizard dependencies not installed (run install.sh)')
    sys.exit(0)

T = tempfile.mkdtemp()
H, S, W, KC = (os.path.join(T, d) for d in ('cfg', 'stub', 'wiz', 'kc'))
for d in (H + '/profiles', S, W, KC):
    os.makedirs(d)

def write(path, text, mode=0o644):
    with open(path, 'w') as f:
        f.write(text)
    os.chmod(path, mode)

write(f'{S}/security', r'''#!/usr/bin/env bash
KC="$(dirname "$0")/../kc"; cmd="$1"; shift; svc=""; blob=""; want=false
while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift ;; -w) if [ "$cmd" = add-generic-password ]; then blob="$2"; shift; else want=true; fi ;; -a) shift ;; esac; shift; done
f="$KC/$(printf '%s' "$svc" | tr '/ ' '__')"
case "$cmd" in find-generic-password) [ -f "$f" ] || exit 44; $want && cat "$f"; exit 0 ;; add-generic-password) printf '%s' "$blob" > "$f" ;; esac
exit 0
''', 0o755)
write(f'{S}/launchctl', '#!/usr/bin/env bash\nexit 0\n', 0o755)
write(f'{S}/pbcopy', '#!/usr/bin/env bash\ncat > "$(dirname "$0")/clipboard"\n', 0o755)
write(f'{S}/curl', r'''#!/usr/bin/env bash
case "$*" in *file://*) exec /usr/bin/curl "$@" ;; esac
hdr=""; while [ $# -gt 0 ]; do [ "$1" = -D ] && hdr="$2"; shift; done
now="$(date +%s)"
printf 'anthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-5h-utilization: 0.12\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-status: allowed\r\nanthropic-ratelimit-unified-7d-utilization: 0.34\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n' "$((now + 7200))" "$((now + 108000))" > "$hdr"
printf 200
''', 0o755)
# As 2.1.310 draws it: the spaces as cursor moves, and the code read in raw mode, where
# only CR is Enter (a LF is just one more character of the code).
write(f'{S}/setup-token.py', r'''import os, tty
tty.setraw(0)
os.write(1, b'Open \x1b]8;;https://claude.com/oauth/x\x07this link\x1b]8;;\x07\r\n'
         b'Paste\x1b[1Ccode\x1b[1Chere\x1b[1Cif\x1b[1Cprompted\x1b[1C>\x1b[1C')
# A chunk with text is a paste, and a CR inside it is not Enter: only a lone CR submits.
while (data := os.read(0, 4096)) not in (b'', b'\r'):
    pass
os.write(1, b'\r\nsk-ant-oat01-WIZTOKEN\r\n')
# 2.1.310 then waits for an Enter instead of exiting.
while os.read(0, 1) not in (b'', b'\r'):
    pass
''')
write(f'{S}/claude', r'''#!/usr/bin/env bash
case "$1" in
  setup-token)
    exec python3 "$(dirname "$0")/setup-token.py" ;;
  auth) echo '{"loggedIn":true}' ;;
  agents) echo '[]' ;;
esac
''', 0o755)
write(f'{H}/profiles/proteauto.json', '{"version":2,"name":"proteauto","type":"native_archive","keychainService":"x-archive","label":"proteauto"}')
write(f'{H}/profiles/leo.json', '{"version":2,"name":"leo","type":"oauth_token","keychainService":"Claude Code OAuth Token - leo","label":"leo","account":"leo@x.io"}')
write(f'{H}/policy.json', '{"preferred":"proteauto","fallback":"leo","move_agents":true}')
write(f'{H}/active', 'proteauto\n')
shutil.copy(f'{ROOT}/wizard/index.mjs', W)
shutil.copy(f'{ROOT}/wizard/package.json', W)
os.symlink(DEPS, f'{W}/node_modules')

# HOME is a temp dir too: `use` must never find the real Orca restart helper.
FAKE_HOME = os.path.join(T, 'home')
os.makedirs(FAKE_HOME)
# A native install at 2.1.301 with 2.1.310 published, for the update screen.
INST = os.path.join(T, 'install')
os.makedirs(f'{INST}/share/claude/versions')
write(f'{INST}/share/claude/versions/2.1.301', '#!/bin/sh\n', 0o755)
os.makedirs(f'{INST}/bin')
os.symlink(f'{INST}/share/claude/versions/2.1.301', f'{INST}/bin/claude')
write(f'{T}/latest.json', '{"version":"2.1.310"}')
env = dict(os.environ, HOME=FAKE_HOME, PATH=f'{S}:{os.environ["PATH"]}', CLAUDE_ACCOUNT_HOME=H,
           CLAUDE_ACCOUNT_BIN=f'{ROOT}/bin/claude-account', CLAUDE_NATIVE_BIN=f'{S}/claude',
           CLAUDE_INSTALL_ROOT=INST, CLAUDE_ACCOUNT_UPDATE_REGISTRY=f'file://{T}/latest.json',
           TERM='xterm-256color', COLUMNS='120', LINES='60', NO_COLOR='1', FORCE_COLOR='0')
pid, fd = pty.fork()
if pid == 0:
    os.execvpe('node', ['node', f'{W}/index.mjs'], env)

screen = ''
def read_until(pattern, timeout=15):
    global screen
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536).decode('utf-8', 'replace')
            except OSError:
                break
            screen += chunk
        if re.search(pattern, re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07', '', screen)):
            return True
    return False

def pump(seconds):
    """Keeps reading while waiting: an undrained pty blocks Ink on write and stalls its input."""
    global screen
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                screen += os.read(fd, 65536).decode('utf-8', 'replace')
            except OSError:
                return

def send(keys, wait=0.4):
    # Arrows go one per write, spaced like a person: keys faster than a re-render act on a
    # stale cursor. Text goes in one write, as a paste would.
    for k in re.findall(r'\x1b\[[A-D]|[^\x1b]+', keys):
        os.write(fd, k.encode())
        pump(0.4 if k.startswith('\x1b') else 0.1)
    pump(wait)

runs = fails = 0
def check(name, ok):
    global runs, fails
    runs += 1
    print(('ok   ' if ok else 'FAIL ') + name)
    fails += 0 if ok else 1
    if not ok:  # what the screen showed last, to tell a wrong screen from a slow one
        print('     screen: ' + re.sub(r'\s+', ' ', re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07', ' ', screen))[-500:])

DOWN = '\x1b[B'

# planOf takes the same decisions as bin/claude-account-autoswitch (same cases as
# tests/autoswitch-scenarios.sh): imported, the wizard defines and draws nothing.
PARITY = r'''
import { planOf } from '%s/index.mjs';
const now = Math.floor(Date.now() / 1000);
const q = (f5, f7, h) => ({ status: 'allowed', f5, f7, r7: now + h * 3600 });
const pol = { exhausted_at: { five_hour: 0.95, seven_day: 0.97 }, return_below: { five_hour: 0.70, seven_day: 0.90 } };
const opt = (active, lastTo) => ({ active, lastTo, out: new Set(), now });
const real = (h) => ({ proteauto: q(0.02, 0.84, h), 'leo-iacall': q(0.63, 0.93, h + 8), 'leonardo-rejani': q(0, 0.37, h + 56), quasar: q(0, 0.65, h + 7) });
const chain4 = ['proteauto', 'leo-iacall', 'leonardo-rejani', 'quasar'];
const r = (p) => `${p.pick}/${p.why}`;
console.log(JSON.stringify({
  stays_little_room_sooner: r(planOf(['a', 'b'], { a: q(0.1, 0.82, 30), b: q(0.1, 0.3, 88) }, pol, opt('a', 'a'))),
  no_up_five_hours: r(planOf(['a', 'b', 'c'], { a: q(0.1, 0.1, 200), b: q(0.1, 0.1, 100), c: q(0.8, 0.1, 30) }, pol, opt('b', 'b'))),
  up_resets_sooner: r(planOf(['a', 'b', 'c'], { a: q(0.1, 0.1, 200), b: q(0.1, 0.1, 100), c: q(0.1, 0.1, 30) }, pol, opt('b', 'b'))),
  at_floor: r(planOf(['a', 'b', 'c'], { a: q(0.1, 0.9, 50), b: q(0.1, 0.5, 100), c: q(0.1, 0.5, 120) }, pol, opt('a', 'a'))),
  all_at_floor: r(planOf(['a', 'b', 'c'], { a: q(0.1, 0.9, 50), b: q(0.1, 0.9, 100), c: q(0.1, 0.9, 120) }, pol, opt('a', 'a'))),
  manual_at_floor: r(planOf(['a', 'b', 'c'], { a: q(0.1, 0.5, 100), b: q(0.99, 0.5, 30), c: q(0.1, 0.9, 50) }, pol, opt('c', 'a'))),
  real_29_10: r(planOf(chain4, real(32), pol, opt('leo-iacall', 'proteauto'))),
  real_29_10_last_day: r(planOf(chain4, real(10), pol, opt('quasar', 'quasar'))),
}));
''' % W
par = subprocess.run(['node', '--input-type=module', '-e', PARITY], env=dict(os.environ, CLAUDE_ACCOUNT_HOME=H, NODE_NO_WARNINGS='1'),
                     capture_output=True, text=True, timeout=60)
got = json.loads(par.stdout or '{}') if par.returncode == 0 else {}
for case, want in [('stays_little_room_sooner', 'a/room'), ('no_up_five_hours', 'b/room'), ('up_resets_sooner', 'c/resets_sooner'),
                   ('at_floor', 'b/at_floor'), ('all_at_floor', 'a/all_at_floor'), ('manual_at_floor', 'a/at_floor'),
                   ('real_29_10', 'quasar/at_floor'), ('real_29_10_last_day', 'proteauto/resets_sooner')]:
    check(f'parity with the autoswitch: {case} -> {want}', got.get(case) == want)
if par.returncode != 0:
    print(par.stderr[-800:])
check('home shows the rotation in the overview', read_until(r'autoswitch\s+on.*proteauto.*leo'))
check('home lists "Add an account"', read_until(r'Add an account'))
send(DOWN)              # Switch account -> Add an account (no move pending: 0 sessions)
send('\r')
check('add: asks for a name', read_until(r'Name for this account'))
send('leo\r')
check('add: an existing name is refused', read_until(r'already exists'))
send('\x7f' * 3 + 'terceira\r', 1.0)
check('add: browser step reaches the code prompt', read_until(r'Paste the code here'))
# The code field takes every key, so the link goes to the clipboard by itself.
check('add: the link is in the clipboard', open(f'{S}/clipboard').read() == 'https://claude.com/oauth/x' if os.path.exists(f'{S}/clipboard') else False)
send('abc123\r', 1.5)
check('add: asks the e-mail', read_until(r'E-mail of this account'))
send('t@x.io\r')
check('add: asks about the rotation', read_until(r'\[Y/n\]'))
send('y', 2.0)
check('add: done with the rank in the rotation', read_until(r'terceira added \(t@x\.io\), ③ in the rotation', 20))
check('add: offers to switch now', read_until(r'Switch to terceira now'))
check('add: the token never reached the screen', 'WIZTOKEN' not in screen)

kc = os.path.join(KC, 'Claude_Code_OAuth_Token_-_terceira')
check('stored in the Keychain stub', os.path.exists(kc) and open(kc).read() == 'sk-ant-oat01-WIZTOKEN')
prof = json.load(open(f'{H}/profiles/terceira.json'))
check('profile has the e-mail', prof.get('account') == 't@x.io')
check('rotation got the reserve', json.load(open(f'{H}/policy.json')).get('reserves') == ['terceira'])

send(DOWN * 2 + '\r', 1.5)  # Back (never the first item: it switches accounts)
check('back on home with three accounts', read_until(r'terceira[\s\S]*What do you want to do', 20))
check('back on home: nothing was switched', open(f'{H}/active').read().strip() == 'proteauto')

# Only terceira is measured (the stub resets its week in 30h): the known reset goes first. Its
# rank shows only once measured, so this waits for the measurement too, wherever it landed.
check('home: the account whose week resets first is ranked first', read_until(r'① terceira', 30))
check('home: the time until each window resets is shown', read_until(r'↻[12]h\d\d[\s\S]*↻1d[56]h'))
check('home: the overview says how the order works', read_until(r'soonest weekly reset first; each keeps 10% until its last 24h'))
screen = ''
send('\r', 1.5)  # Switch account
check('switch: each option shows its quota and reset', read_until(r'terceira\s+5h\s+12%\s+7d\s+34% ↻1d[56]h'))
# The active account has no quota reading: the autoswitch stays put, so nothing is recommended.
check('switch: no recommendation while the active account is unmeasured', 'Recommended' not in screen and 'recommended' not in screen)
screen = ''
os.write(fd, b'\x1b'); pump(1.0)
check('switch: Esc goes back home', read_until(r'What do you want to do'))
read_until(r'✓ ok', 20); time.sleep(1.0)
screen = ''
send(DOWN + DOWN + '\r', 1.0)  # Switch, Add, Rotation
check('rotation: opens its screen', read_until(r'rotation and autoswitch'))
check('rotation: explains the reset order and the floor', read_until(r'weekly quota resets first[\s\S]*keeps 10% of its week'))
check('rotation: lists the chain that breaks ties', read_until(r'rotation and autoswitch[\s\S]*1\. proteauto\s+2\. leo\s+3\. terceira'))
send(DOWN + '\r', 1.5)  # Change the order, Turn the autoswitch off
check('rotation: autoswitch turned off', read_until(r'autoswitch: off'))
check('rotation: kill switch written', os.path.exists(f'{H}/autoswitch.off'))
send('\r', 1.5)
check('home shows the autoswitch off', read_until(r'autoswitch\s+off'))

screen = ''
send(DOWN * 7 + '\r', 1.5)  # Switch, Add, Rotation, Renew, Log in, Doctor, Sync, Update
check('update: shows the installed and the latest version', read_until(r'installed\s+2\.1\.301[\s\S]*latest\s+2\.1\.310'))
check('update: offers the update, nothing installed yet', read_until(r'Update to 2\.1\.310 now') and os.readlink(f'{INST}/bin/claude').endswith('2.1.301'))
screen = ''
os.write(fd, b'\x1b'); pump(1.0)
check('update: Esc goes back home', read_until(r'What do you want to do'))

os.kill(pid, 9)
shutil.rmtree(T, ignore_errors=True)
print(f'{runs} cases, {fails} failures')
sys.exit(1 if fails else 0)
