#!/usr/bin/env bash
# Track C — detection (the differentiator). The wedged state: POST
# /bench/wedge makes /up answer 503 while the process stays alive. A
# PID-aliveness supervisor sees a healthy child; a health-checking
# supervisor sees a wedged one. Measured: wedge-trigger → first 200.
#
# Non-detecting contenders get outcome=not_detected after the full
# observation window — a fair, factual cell (foreman and overmind do not
# health-check by design; docker restart policies act on exit, not on
# health, and the stock engine ships no autoheal).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_mode

CONTENDERS=(odoshi-probe odoshi-heartbeat foreman overmind compose)

detects() { case "$1" in odoshi-*) return 0 ;; *) return 1 ;; esac; }

detect_cycle() { # CONTENDER RUN
  local c=$1 run=$2 wt code rec val outcome timeout
  log "C $c run $run"
  cleanup_all
  start_contender "$c"
  if ! wait_up "$BOOT_TIMEOUT" >/dev/null; then
    emit track=C contender="$c" metric=detect_recover_s run="$run" value=null outcome=boot_failed
    cleanup_all; return
  fi
  sleep 3 # let heartbeats/probes reach steady state
  wt=$(dex bash -c "date +%s.%N && curl -fsS -XPOST $WEB_BASE/bench/wedge >/dev/null") || {
    emit track=C contender="$c" metric=detect_recover_s run="$run" value=null outcome=wedge_failed
    cleanup_all; return
  }
  code=$(dex curl -s -o /dev/null -w '%{http_code}' "$WEB_BASE/up" || echo 000)
  if [ "$code" != "503" ]; then
    emit track=C contender="$c" metric=detect_recover_s run="$run" value=null outcome=wedge_not_applied extra:="{\"code\":\"$code\"}"
    cleanup_all; return
  fi
  if detects "$c"; then timeout=$REC_TIMEOUT; else timeout=$DETECT_TIMEOUT; fi
  if rec=$(wait_up "$timeout"); then
    val=$(fsub "$rec" "$wt"); outcome=detected_recovered
  else
    val=null; outcome=not_detected
  fi
  emit track=C contender="$c" metric=detect_recover_s run="$run" value="$val" outcome="$outcome" extra:="{\"window_s\":$timeout}"
  cleanup_all
}

for c in "${CONTENDERS[@]}"; do
  if detects "$c"; then runs=$N; else runs=$N_NONDET; fi
  for run in $(seq 1 "$runs"); do detect_cycle "$c" "$run"; done
done

log "Track C complete"
