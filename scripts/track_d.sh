#!/usr/bin/env bash
# Track D (stretch) — sidecar queue drain: 1000 no-op jobs on one Postgres,
# Ruby Solid Queue worker (bin/jobs) vs the beam Elixir worker, both from
# their published artifacts. Jobs are pre-enqueued with no worker running,
# then the worker starts and the drain is measured from Solid Queue's own
# bookkeeping (finished_at). Reported per run:
#   drain_s     worker start -> last finished_at (includes worker boot)
#   window_s    first finished_at -> last finished_at (excludes boot)
#   jobs_per_s  1000 / window_s
# Caveats (same-job-different-runtime) are documented in the README.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_mode

JOBS=1000
D_RUNS="${D_RUNS:-3}"
DRAIN_TIMEOUT=300

enqueue_batch() { # QUEUE
  dex bash -c "cd /app && bin/rails runner '
    jobs = $JOBS.times.map { BenchNoopJob.new }
    jobs.each { |j| j.queue_name = \"$1\" }
    ActiveJob.perform_all_later(jobs)
  '"
}

finished_count() { psqlq app_production_queue "SELECT count(*) FROM solid_queue_jobs WHERE finished_at IS NOT NULL"; }

drain_stats() { # T_START -> json via ruby
  local t_start=$1 row
  row=$(psqlq app_production_queue "SELECT extract(epoch from min(finished_at)) || ' ' || extract(epoch from max(finished_at)) FROM solid_queue_jobs WHERE finished_at IS NOT NULL" )
  ruby -r json -e '
    first, last = ARGV[0].split.map(&:to_f)
    t0 = ARGV[1].to_f
    window = (last - first).round(3)
    puts({ drain_s: (last - t0).round(3), window_s: window,
           jobs_per_s: window.positive? ? (Integer(ARGV[2]) / window).round(1) : nil }.to_json)
  ' "$row" "$t_start" "$JOBS"
}

wait_drained() {
  local start=$SECONDS
  until [ "$(finished_count)" = "$JOBS" ]; do
    if (( SECONDS - start > DRAIN_TIMEOUT )); then return 1; fi
    sleep 1
  done
}

ruby_cycle() { # RUN
  local run=$1 t_start stats
  log "D/ruby run $run"
  cleanup_all; reset_db
  enqueue_batch default >/dev/null
  t_start=$(dex date +%s.%N)
  dexd bash -c 'cd /app && exec bundle exec bin/jobs >>/tmp/jobs.log 2>&1'
  if wait_drained; then
    stats=$(drain_stats "$t_start")
    emit track=D contender=ruby-solid-queue metric=drain_1000 run="$run" value="$(ruby -r json -e 'puts JSON.parse(ARGV[0])["drain_s"]' "$stats")" outcome=drained extra:="$stats"
  else
    emit track=D contender=ruby-solid-queue metric=drain_1000 run="$run" value=null outcome=timeout extra:="{\"finished\":$(finished_count)}"
  fi
  cleanup_all
}

beam_cycle() { # RUN
  local run=$1 t_start stats
  log "D/beam run $run"
  cleanup_all; reset_db
  $COMPOSE --profile beam stop -t 3 beam-queue >/dev/null 2>&1 || true
  $COMPOSE --profile beam rm -f beam-queue >/dev/null 2>&1 || true
  enqueue_batch elixir >/dev/null
  t_start=$(dex date +%s.%N)
  $COMPOSE --profile beam up -d beam-queue >/dev/null 2>&1
  if wait_drained; then
    stats=$(drain_stats "$t_start")
    emit track=D contender=beam-elixir metric=drain_1000 run="$run" value="$(ruby -r json -e 'puts JSON.parse(ARGV[0])["drain_s"]' "$stats")" outcome=drained extra:="$stats"
  else
    emit track=D contender=beam-elixir metric=drain_1000 run="$run" value=null outcome=timeout extra:="{\"finished\":$(finished_count)}"
  fi
  $COMPOSE --profile beam stop -t 3 beam-queue >/dev/null 2>&1 || true
  $COMPOSE --profile beam rm -f beam-queue >/dev/null 2>&1 || true
  cleanup_all
}

for run in $(seq 1 "$D_RUNS"); do ruby_cycle "$run"; done
for run in $(seq 1 "$D_RUNS"); do beam_cycle "$run"; done

log "Track D complete"
