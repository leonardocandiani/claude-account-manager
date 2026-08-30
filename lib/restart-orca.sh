#!/usr/bin/env bash
# Runs detached because Orca itself may be the calling terminal.
# Restarting Orca (and the claude processes it spawned) is what makes a
# profile switch take effect in persistent processes.
set +e

# Safety guard: never kill anything on a machine without Orca.
if [ ! -d "/Applications/Orca.app" ] && [ ! -d "$HOME/Applications/Orca.app" ]; then
  exit 0
fi

sleep 1
osascript -e 'tell application id "com.stablyai.orca" to quit' >/dev/null 2>&1
sleep 4

for pid in $(pgrep -f '[d]aemon-entry.js --socket .*/orca/daemon/' 2>/dev/null); do
  kill -TERM "$pid" 2>/dev/null
done
for pid in $(pgrep -x claude 2>/dev/null); do
  kill -TERM "$pid" 2>/dev/null
done
sleep 3
open -a Orca
