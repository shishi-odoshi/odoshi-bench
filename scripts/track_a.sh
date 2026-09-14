#!/usr/bin/env bash
# Track A — recovery under load. For each contender, N independent
# boot→load→SIGKILL→measure cycles for the web child, then N for the jobs
# child. Every value is produced on container clocks; the host only
# orchestrates. Semantics are reported, not judged: foreman exiting the
# formation on child death is its documented design and is recorded as
# outcome=formation_exit, never as a crash.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_mode

CONTENDERS=(odoshi foreman overmind compose bare)

# Contenders whose docs promise a restart. The rest get a shorter
# observation window: their non-recovery is by design, not suspense.
recovers() { case "$1" in odoshi|overmind|compose) return 0 ;; *) return 1 ;; esac; }

web_cycle() { # CONTENDER RUN
  local c=$1 run=$2 t0 kt rec val outcome fails timeout window_end
  log "A/web $c run $run"
  cleanup_all
  start_contender "$c"
  if ! wait_up "$BOOT_TIMEOUT" >/dev/null; then
    emit track=A contender="$c" metric=web_recovery_s run="$run" value=null outcome=boot_failed
    cleanup_all; return
  fi
  dexd bash -c "exec ruby /bench/loadgen.rb $WEB_BASE/up $LOAD_RPS /tmp/load.jsonl >/dev/null 2>&1"
  sleep "$STEADY"
  kt=$(kill_web "$c") || { emit track=A contender="$c" metric=web_recovery_s run="$run" value=null outcome=kill_failed; cleanup_all; return; }
  # Require /up to actually drop before timing recovery: a killed puma's
  # last in-flight 200 must never stop the clock at ~0s (the lingering-worker
  # false positive). 5s is generous for a SIGKILLed single-process puma.
  wait_down 5 || true
  if recovers "$c"; then timeout=$REC_TIMEOUT; else timeout=$NONREC_WINDOW; fi
  if rec=$(wait_up "$timeout"); then
    val=$(fsub "$rec" "$kt"); outcome=recovered
  else
    rec=""; val=null
    if sup_alive "$c"; then outcome=not_recovered
    elif [ "$c" = bare ]; then outcome=no_supervisor
    else outcome=formation_exit; fi
  fi
  window_end=${rec:-$(dex date +%s.%N)}
  dex bash -c 'pkill -TERM -f "bench/loadgen.r[b]"; sleep 0.5' || true
  fails=$(dex ruby /bench/count_failures.rb /tmp/load.jsonl "$kt" "$window_end" 2>/dev/null || echo '{}')
  emit track=A contender="$c" metric=web_recovery_s run="$run" value="$val" outcome="$outcome" extra:="$fails"
  cleanup_all
}

jobs_cycle() { # CONTENDER RUN
  local c=$1 run=$2 kt rec val outcome timeout
  log "A/jobs $c run $run"
  cleanup_all
  reset_db
  start_contender "$c"
  if ! wait_up "$BOOT_TIMEOUT" >/dev/null; then
    emit track=A contender="$c" metric=jobs_recovery_s run="$run" value=null outcome=boot_failed
    cleanup_all; return
  fi
  dexd bash -c "exec ruby /bench/enqueue_loop.rb $WEB_BASE a$run 1 >/dev/null 2>&1"
  # Jobs must demonstrably flow before the kill.
  local start=$SECONDS
  until [ "$(psqlq app_production 'SELECT count(*) FROM job_markers')" -ge 2 ] 2>/dev/null; do
    if (( SECONDS - start > 60 )); then
      emit track=A contender="$c" metric=jobs_recovery_s run="$run" value=null outcome=jobs_never_flowed
      cleanup_all; return
    fi
    sleep 0.5
  done
  kt=$(kill_jobs "$c") || { emit track=A contender="$c" metric=jobs_recovery_s run="$run" value=null outcome=kill_failed; cleanup_all; return; }
  if recovers "$c"; then timeout=$JOBS_TIMEOUT; else timeout=$NONREC_WINDOW; fi
  if rec=$(first_marker_after "$kt" "$timeout"); then
    val=$(fsub "$rec" "$kt"); outcome=recovered
  else
    val=null
    if sup_alive "$c"; then outcome=not_recovered
    elif [ "$c" = bare ]; then outcome=no_supervisor
    else outcome=formation_exit; fi
  fi
  emit track=A contender="$c" metric=jobs_recovery_s run="$run" value="$val" outcome="$outcome"
  cleanup_all
}

for c in "${CONTENDERS[@]}"; do
  for run in $(seq 1 "$N"); do web_cycle "$c" "$run"; done
done
for c in "${CONTENDERS[@]}"; do
  for run in $(seq 1 "$N"); do jobs_cycle "$c" "$run"; done
done

log "Track A complete"
