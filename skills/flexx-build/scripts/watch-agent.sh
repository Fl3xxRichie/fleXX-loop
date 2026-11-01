#!/usr/bin/env bash
# Watch a long-running background agent (a flexx-build pass, a review one-shot)
# without blocking the session. Exits early on process death or on a long quiet
# stretch with no progress signal, and always prints a state snapshot.
#
# Usage: watch-agent.sh <pid> <git-dir> <task-file> [<log-file> ...]
#                      [--cap-min N] [--quiet-min N]
#
# Run it as a FOREGROUND terminal call with a timeout above the cap
# (cap_min * 60 + 60): a foreground timeout above 600s auto-promotes to a
# tracked background process with notify on completion, so control returns
# immediately and you are pinged at exit.
#
# Liveness on Windows/MSYS: powershell Get-Process. Do NOT use `tasklist //FI`
# (MSYS mangles the flags and it errors out). Progress signals: HEAD, current
# branch, task-file mtime, newest src/drizzle write, log sizes. QUIET means none
# of them moved for --quiet-min while the pid is still alive (usually composing
# its final report, or stuck; both merit a look).

PID="$1"; GITDIR="$2"; TASKFILE="$3"; shift 3
CAP_MIN=55; QUIET_MIN=25; LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cap-min)   CAP_MIN="$2"; shift 2 ;;
    --quiet-min) QUIET_MIN="$2"; shift 2 ;;
    *) LOGS+=("$1"); shift ;;
  esac
done

alive() { powershell -NoProfile -Command "if (Get-Process -Id $PID -ErrorAction SilentlyContinue) { '1' } else { '0' }" 2>/dev/null | tr -d '\r\n '; }
snap() {
  git -C "$GITDIR" rev-parse --short HEAD 2>/dev/null
  git -C "$GITDIR" branch --show-current 2>/dev/null
  stat -c %Y "$TASKFILE" 2>/dev/null
  find "$GITDIR/src" "$GITDIR/drizzle" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1
  for L in "${LOGS[@]}"; do stat -c %s "$L" 2>/dev/null; done
}

start=$(date +%s); prev=$(snap); quiet=0
echo "watch start pid=$PID alive=$(alive)"
for i in $(seq 1 "$CAP_MIN"); do
  sleep 60
  a=$(alive); cur=$(snap)
  if [ "$a" = "0" ]; then echo "EVENT EXITED t=$(( $(date +%s) - start ))s"; break; fi
  if [ "$cur" = "$prev" ]; then quiet=$((quiet+1)); else quiet=0; prev="$cur"; fi
  if [ "$quiet" -ge "$QUIET_MIN" ]; then echo "EVENT QUIET t=$(( $(date +%s) - start ))s"; break; fi
done
echo "=== snapshot $(date +%H:%M:%S) alive=$(alive) ==="
git -C "$GITDIR" branch --show-current 2>/dev/null
git -C "$GITDIR" log --oneline -3 2>/dev/null
grep -m1 "^status:" "$TASKFILE" 2>/dev/null
grep -m1 "^claimed_at:" "$TASKFILE" 2>/dev/null
for L in "${LOGS[@]}"; do ls -la "$L" 2>/dev/null; done
# convenience probe; adjust the port for the project under watch
curl -s -o /dev/null -w "app :3000 -> %{http_code}\n" --max-time 5 http://localhost:3000/ 2>/dev/null || echo "app down"
