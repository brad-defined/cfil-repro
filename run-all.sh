#!/bin/bash
# Runs the whole repro inside the test Mac/VM and saves everything under results/<timestamp>/.
# Assumes CFILRepro.app is in /Applications and has been activated (CFILRepro activate).
#
#   "/Volumes/My Shared Files/cfil-repro/run-all.sh"
#
# Each client exits as soon as its outcome is clear, so this takes under a minute:
# a few seconds for the allow (control) runs, at most GIVE_UP seconds for the drop runs.
# Raise GIVE_UP (default 45) to watch whether a stuck socket ever recovers, e.g. GIVE_UP=600.
#
# Exit codes: 0 RECOVERED, 1 REPRODUCED (lost wakeup), 2 error, 3 HUNG (never writable), 4 NOT HELD.
set -u
GIVE_UP=${GIVE_UP:-45}
S="$(cd "$(dirname "$0")" && pwd)"
R=/Applications/CFILRepro.app/Contents/MacOS/CFILRepro
OUT="$S/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || { echo "can't write to $OUT (is the shared folder read-only?)"; exit 1; }
START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "saving results to $OUT"

{ sw_vers; uname -a; csrutil status; nvram boot-args; systemextensionsctl list; } > "$OUT/env.txt" 2>&1

run() { # name, command...
  local name=$1; shift
  "$@" > "$OUT/$name.txt" 2>&1
  echo "exit: $?" >> "$OUT/$name.txt"
  echo "  $name: $(tail -1 "$OUT/$name.txt")"
}

# Each client uses its own socket, so they can run in parallel without affecting each other.
clients() { # verdict
  run "$1-kqrepro-v4"   "$S/client/kqrepro/kqrepro" -m v4   192.0.2.1 4242 "$GIVE_UP" &
  run "$1-kqrepro-dual" "$S/client/kqrepro/kqrepro" -m dual 192.0.2.1 4242 "$GIVE_UP" &
  run "$1-gorepro-v4"   "$S/client/gorepro/gorepro" -net udp4 -held 192.0.2.1:4242 -give-up "${GIVE_UP}s" &
  run "$1-gorepro-dual" "$S/client/gorepro/gorepro" -net udp  -held 192.0.2.1:4242 -give-up "${GIVE_UP}s" &
  wait
}

echo "control run (verdict allow): expect exit 0 RECOVERED from all four"
$R enable --port 4242 --hold-ms 2000 --verdict allow > "$OUT/enable-allow.txt" 2>&1
clients allow

# Drop run: every client with and without periodic probe sends while stuck. kqrepro probes by
# default and gorepro doesn't; the question is whether those (failing) sends are what gets the
# dropped flow's send space released.
echo "drop run (verdict drop, up to ${GIVE_UP}s)"
$R enable --port 4242 --hold-ms 2000 --verdict drop > "$OUT/enable-drop.txt" 2>&1
for m in v4 dual; do
  run "drop-kqrepro-$m-probe"   "$S/client/kqrepro/kqrepro" -m $m    192.0.2.1 4242 "$GIVE_UP" &
  run "drop-kqrepro-$m-noprobe" "$S/client/kqrepro/kqrepro" -m $m -P 192.0.2.1 4242 "$GIVE_UP" &
done
for n in udp4 udp; do
  run "drop-gorepro-$n-probe"   "$S/client/gorepro/gorepro" -net $n -probe-every 5s -held 192.0.2.1:4242 -give-up "${GIVE_UP}s" &
  run "drop-gorepro-$n-noprobe" "$S/client/gorepro/gorepro" -net $n -held 192.0.2.1:4242 -give-up "${GIVE_UP}s" &
done
wait

$R status > "$OUT/status.txt" 2>&1
log show --start "$START" --info --predicate 'subsystem == "net.example.cfilrepro"' > "$OUT/filter-log.txt" 2>&1
echo "done: $OUT"
