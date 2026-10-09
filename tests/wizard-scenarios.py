#!/usr/bin/env python3
"""Drives the wizard in a pseudo-terminal with `security`, `curl`, `launchctl` and
the native `claude` stubbed: adds an account end to end and checks the rotation
screen. Needs node 22+ and the wizard dependencies installed by install.sh."""
import os, pty, re, select, shutil, subprocess, sys, tempfile, time

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
write(f'{S}/curl', r'''#!/usr/bin/env bash
hdr=""; while [ $# -gt 0 ]; do [ "$1" = -D ] && hdr="$2"; shift; done
printf 'anthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-5h-utilization: 0.12\r\nanthropic-ratelimit-unified-7d-status: allowed\r\nanthropic-ratelimit-unified-7d-utilization: 0.34\r\n' > "$hdr"
printf 200
''', 0o755)
write(f'{S}/claude', r'''#!/usr/bin/env bash
case "$1" in
  setup-token)
    printf 'Open \033]8;;https://claude.com/oauth/x\007this link\033]8;;\007\nPaste code here: '
    IFS= read -r code
    printf '\nsk-ant-oat01-WIZTOKEN\n' ;;
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
env = dict(os.environ, HOME=FAKE_HOME, PATH=f'{S}:{os.environ["PATH"]}', CLAUDE_ACCOUNT_HOME=H,
           CLAUDE_ACCOUNT_BIN=f'{ROOT}/bin/claude-account', CLAUDE_NATIVE_BIN=f'{S}/claude',
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

DOWN = '\x1b[B'
check('home shows the rotation in the overview', read_until(r'autoswitch\s+on.*proteauto.*leo'))
check('home lists "Add an account"', read_until(r'Add an account'))
send(DOWN)              # Switch account -> Add an account (no move pending: 0 sessions)
send('\r')
check('add: asks for a name', read_until(r'Name for this account'))
send('leo\r')
check('add: an existing name is refused', read_until(r'already exists'))
send('\x7f' * 3 + 'terceira\r', 1.0)
check('add: browser step reaches the code prompt', read_until(r'Paste the code here'))
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
import json
prof = json.load(open(f'{H}/profiles/terceira.json'))
check('profile has the e-mail', prof.get('account') == 't@x.io')
check('rotation got the reserve', json.load(open(f'{H}/policy.json')).get('reserves') == ['terceira'])

send(DOWN * 2 + '\r', 1.5)  # Back (never the first item: it switches accounts)
check('back on home with three accounts ranked', read_until(r'③ terceira[\s\S]*What do you want to do', 20))
check('back on home: nothing was switched', open(f'{H}/active').read().strip() == 'proteauto')

screen = ''
read_until(r'✓ ok|not measured|no measuring token|token failing', 20); time.sleep(1.0)  # home done measuring
screen = ''
send(DOWN + DOWN + '\r', 1.0)  # Switch, Add, Rotation
check('rotation: opens its screen', read_until(r'rotation and autoswitch'))
check('rotation: lists the chain in order', read_until(r'rotation and autoswitch[\s\S]*① proteauto\s+② leo\s+③ terceira'))
send(DOWN + '\r', 1.5)  # Change the order, Turn the autoswitch off
check('rotation: autoswitch turned off', read_until(r'autoswitch: off'))
check('rotation: kill switch written', os.path.exists(f'{H}/autoswitch.off'))
send('\r', 1.5)
check('home shows the autoswitch off', read_until(r'autoswitch\s+off'))

os.kill(pid, 9)
shutil.rmtree(T, ignore_errors=True)
print(f'{runs} cases, {fails} failures')
sys.exit(1 if fails else 0)
