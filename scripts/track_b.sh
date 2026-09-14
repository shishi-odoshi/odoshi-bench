#!/usr/bin/env bash
# Track B — overhead.
#   B1 supervisor-process RSS + CPU over a steady window (odoshi vs foreman
#      vs overmind; the supervisor process ONLY — children excluded; the
#      tmux server overmind requires is sampled separately into extra).
#   B2 boot-to-/up per contender, N runs each.
#   B3 the honesty test: supervised (odoshi beside-mode) vs bare puma
#      latency/throughput on the same app — wrk against /up, warmup
#      discarded. Both sides run web+jobs; only the supervisor differs.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_mode

# ------------------------------------------------------------ B2: boot time -
boot_cycle() { # CONTENDER RUN
  local c=$1 run=$2 t0 t200 val
  log "B/boot $c run $run"
  cleanup_all
  start_contender "$c"
  if t200=$(wait_up "$BOOT_TIMEOUT"); then
    t0=$(boot_t0)
    val=$(fsub "$t200" "$t0")
    emit track=B contender="$c" metric=boot_to_up_s run="$run" value="$val" outcome=ok
  else
    emit track=B contender="$c" metric=boot_to_up_s run="$run" value=null outcome=boot_failed
  fi
  cleanup_all
}

# ------------------------------------------------- B1: supervisor RSS / CPU -
rss_cycle() { # CONTENDER
  local c=$1 pid sample tmux_kb extra
  log "B/rss $c (${RSS_WINDOW}s window)"
  cleanup_all
  start_contender "$c"
  if ! wait_up "$BOOT_TIMEOUT" >/dev/null; then
    emit track=B contender="$c" metric=sup_rss_cpu run=1 value=null outcome=boot_failed
    cleanup_all; return
  fi
  dexd bash -c "exec ruby /bench/loadgen.rb $WEB_BASE/up $RSS_RPS /tmp/load.jsonl >/dev/null 2>&1"
  pid=$(sup_pid "$c")
  if [ -z "$pid" ]; then
    emit track=B contender="$c" metric=sup_rss_cpu run=1 value=null outcome=pid_not_found
    cleanup_all; return
  fi
  sample=$(dex ruby /bench/sample_proc.rb "$pid" "$RSS_WINDOW" 5)
  extra=$sample
  if [ "$c" = overmind ]; then
    # overmind cannot run without a tmux server; its RSS is part of the
    # real supervision footprint even though it is not "the supervisor
    # process". Reported separately, added to nothing.
    tmux_kb=$(dex bash -c 'p=$(pgrep -x tmux | head -1); [ -n "$p" ] && grep VmRSS /proc/$p/status | grep -o "[0-9]*"' || echo "")
    [ -n "$tmux_kb" ] && extra=$(ruby -r json -e 'j = JSON.parse(ARGV[0]); j["tmux_rss_mb"] = (ARGV[1].to_f/1024).round(1); puts j.to_json' "$sample" "$tmux_kb")
  fi
  emit track=B contender="$c" metric=sup_rss_cpu run=1 value=null outcome=ok extra:="$extra"
  cleanup_all
}

# ------------------------------------------ B3: supervised vs bare latency -
latency_cycle() { # CONTENDER (odoshi | bare)
  local c=$1 run out
  log "B/latency $c (${LAT_RUNS}x ${LAT_DURATION}s + ${LAT_WARMUP}s warmup)"
  cleanup_all
  start_contender "$c"
  if ! wait_up "$BOOT_TIMEOUT" >/dev/null; then
    emit track=B contender="$c" metric=latency_up run=1 value=null outcome=boot_failed
    cleanup_all; return
  fi
  sleep 2
  dex bash -c "wrk -t2 -c16 -d${LAT_WARMUP}s $WEB_BASE/up >/dev/null 2>&1" || true # warmup, discarded
  for run in $(seq 1 "$LAT_RUNS"); do
    out=$(dex bash -c "wrk -t2 -c16 -d${LAT_DURATION}s --latency $WEB_BASE/up | ruby /bench/wrk_parse.rb")
    emit track=B contender="$c" metric=latency_up run="$run" value=null outcome=ok extra:="$out"
  done
  cleanup_all
}

for c in odoshi foreman overmind compose bare; do
  for run in $(seq 1 "$N"); do boot_cycle "$c" "$run"; done
done

for c in odoshi foreman overmind; do rss_cycle "$c"; done

for c in odoshi bare; do latency_cycle "$c"; done

log "Track B complete"
