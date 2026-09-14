#!/usr/bin/env bash
# odoshi-bench entrypoint.
#
#   scripts/bench.sh [--mode full|ci|smoke] [--tracks abcd] [--no-build] [--keep]
#
#   --mode    full (default): N=5, full windows — the README numbers.
#             ci: reduced matrix (N=3, shorter windows) — the smoke/regression check.
#             smoke: N=1, minimal windows — harness plumbing check.
#   --tracks  any subset of "abcd" (default: abc; d is the stretch track).
#   --no-build  skip `docker compose build` (CI pre-builds with layer cache).
#   --keep      leave the stack up afterwards.
#
# Exits non-zero if any track failed to complete or the sanity assertions
# (scripts/assert_sanity.rb) fail. Results: results/raw/DATE-MODE.jsonl
# (every row), results/results.json (aggregates), README tables rendered.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE=full TRACKS=abc BUILD=1 KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE=$2; shift 2 ;;
    --tracks) TRACKS=$2; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 78 ;;
  esac
done
export MODE

source scripts/lib.sh
load_mode
: > "$RAW_FILE"

OVERALL=0
SCOREBOARD=()

run_phase() { # NAME COMMAND...
  local name=$1 start dur status; shift
  echo
  echo "===================================================================="
  echo "  PHASE: $name (mode=$MODE)"
  echo "===================================================================="
  start=$(date +%s)
  # NOT an if-condition: bash suppresses errexit inside any tested context
  # (odoshi-integration lesson — a failed build once slid through setup).
  ( set -eu; "$@" )
  status=$?
  dur=$(( $(date +%s) - start ))
  local result=PASS
  [ "$status" -ne 0 ] && { result=FAIL; OVERALL=1; }
  SCOREBOARD+=("$(printf '%-16s %-4s %5ss' "$name" "$result" "$dur")")
  echo "--- $name: $result (${dur}s)"
}

setup() {
  if [ "$BUILD" = 1 ]; then $COMPOSE build runner; fi
  $COMPOSE up -d postgres runner
  dex bash -c 'cd /app && bin/rails db:prepare' >/dev/null
  cleanup_all
  reset_db
  ruby scripts/collect_meta.rb "$RAW_FILE"
}

run_phase setup setup
if [ "$OVERALL" -ne 0 ]; then
  echo "setup failed — aborting" >&2
  exit 1
fi

case "$TRACKS" in *a*) run_phase track-a scripts/track_a.sh ;; esac
case "$TRACKS" in *b*) run_phase track-b scripts/track_b.sh ;; esac
case "$TRACKS" in *c*) run_phase track-c scripts/track_c.sh ;; esac
case "$TRACKS" in *d*) run_phase track-d scripts/track_d.sh ;; esac

run_phase aggregate ruby scripts/render_results.rb "$RAW_FILE"
run_phase sanity ruby scripts/assert_sanity.rb results/results.json

echo
echo "==================== SCOREBOARD ===================="
printf '%-16s %-4s %6s\n' PHASE RES TIME
for row in "${SCOREBOARD[@]}"; do echo "$row"; done
echo "===================================================="
[ "$OVERALL" -eq 0 ] && echo "BENCH COMPLETE" || echo "FAILURES PRESENT"

if [ "$KEEP" != 1 ]; then
  cleanup_all >/dev/null 2>&1 || true
fi

exit "$OVERALL"
