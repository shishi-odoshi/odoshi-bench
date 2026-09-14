#!/usr/bin/env bash
# Shared harness plumbing: contender lifecycle, kill switches, DB helpers,
# row emission. Sourced by the track scripts. Two hard-won bash rules from
# odoshi-integration apply throughout:
#   * never run a phase as `if (subshell)` — bash suppresses errexit in any
#     tested context, which once masked a real failure;
#   * every pgrep/pkill pattern carries a [b]racket class so it can never
#     match its own shell invocation.

COMPOSE="docker compose"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Process patterns (from odoshi-template's chaos.rake, the tested originals).
WEB_PATTERN='puma .*config/pum[a].rb|pum[a] [0-9].*(tcp|unix|ssl)://|pum[a]: cluster'
JOBS_PATTERN='solid-queu[e]|bin/job[s]'

# ------------------------------------------------------------- exec helpers -
dex()  { $COMPOSE exec -T runner "$@"; }
dexd() { $COMPOSE exec -d runner "$@"; }
psqlq() { $COMPOSE exec -T postgres psql -U postgres -d "$1" -tAc "$2" | tr -d '[:space:]'; }
psqlx() { $COMPOSE exec -T postgres psql -U postgres -d "$1" -c "$2" >/dev/null; }

fsub() { ruby -e 'puts (Float(ARGV[0]) - Float(ARGV[1])).round(3)' "$1" "$2"; }

emit() { ruby "$ROOT/scripts/emit_row.rb" "$RAW_FILE" "$@"; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --------------------------------------------------------------- lifecycle -
# start_contender NAME — boots the contender; sets WEB_BASE for callers and
# writes the boot instant to /tmp/bench_t0 inside the runner (container
# clocks are the single time base for every measurement).
start_contender() {
  local name=$1 cfg
  WEB_BASE="http://127.0.0.1:3000"
  case "$name" in
    odoshi|odoshi-probe|odoshi-heartbeat)
      case "$name" in
        odoshi)           cfg=config/supervisor.rb ;;
        odoshi-probe)     cfg=config/supervisor_probe.rb ;;
        odoshi-heartbeat) cfg=config/supervisor_heartbeat.rb ;;
      esac
      dexd bash -c "cd /app && date +%s.%N >/tmp/bench_t0 && exec bundle exec odoshi run $cfg >>/tmp/contender.log 2>&1"
      ;;
    foreman)
      # -p 3000: foreman's own base-port mechanism; web gets PORT=3000.
      dexd bash -c "cd /app && date +%s.%N >/tmp/bench_t0 && exec foreman start -p 3000 >>/tmp/contender.log 2>&1"
      ;;
    overmind)
      # --auto-restart web,jobs: overmind's documented supervision mode
      # (without it, overmind stops the formation like foreman does). The
      # socket rm is belt-and-suspenders on top of cleanup_all: a stale
      # socket makes overmind refuse to start ("already running").
      dexd bash -c "cd /app && rm -f /tmp/overmind.sock .overmind.sock && date +%s.%N >/tmp/bench_t0 && OVERMIND_SOCKET=/tmp/overmind.sock OVERMIND_AUTO_RESTART=web,jobs exec overmind start -p 3000 >>/tmp/contender.log 2>&1"
      ;;
    bare)
      dexd bash -c "cd /app && date +%s.%N >/tmp/bench_t0 && exec bundle exec puma -C config/puma.rb >>/tmp/web.log 2>&1"
      dexd bash -c "cd /app && exec bundle exec bin/jobs >>/tmp/jobs.log 2>&1"
      ;;
    bare-web) # Track B latency/boot baseline: puma alone, nothing else
      dexd bash -c "cd /app && date +%s.%N >/tmp/bench_t0 && exec bundle exec puma -C config/puma.rb >>/tmp/web.log 2>&1"
      ;;
    compose)
      dex bash -c "date +%s.%N >/tmp/bench_t0"
      $COMPOSE --profile compose up -d web jobs >/dev/null 2>&1
      WEB_BASE="http://web:3000"
      ;;
    *) echo "unknown contender: $name" >&2; return 1 ;;
  esac
}

boot_t0() { dex cat /tmp/bench_t0; }

# wait_up TIMEOUT — epoch float of the first 200 from $WEB_BASE/up.
wait_up() { dex ruby /bench/wait_200.rb "$WEB_BASE/up" "$1"; }

# wait_down TIMEOUT — block until /up stops returning 200 (a non-200 or a
# connection error), so a killed child's lingering in-flight response can
# never be mistaken for recovery. Returns 0 once down, 1 on timeout.
wait_down() {
  dex ruby -e '
    require "net/http"; require "uri"
    uri = URI(ARGV[0]); deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(ARGV[1])
    loop do
      begin
        code = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.25, read_timeout: 1.0) { |h| h.get(uri.path).code.to_i }
        exit 0 unless code == 200
      rescue StandardError
        exit 0
      end
      exit 1 if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  ' "$WEB_BASE/up" "$1"
}

# Supervisor process PID inside the runner (Track B).
sup_pid() {
  case "$1" in
    odoshi*)  dex pgrep -f "odoshi ru[n]" | head -1 ;;
    foreman)  dex pgrep -f "foreman: mai[n]" | head -1 ;;
    overmind) dex pgrep -f "overmind star[t]" | head -1 ;;
  esac
}

# Is the contender's supervisor still alive? (classifies foreman's
# documented formation-exit vs a genuine missed restart)
sup_alive() {
  case "$1" in
    odoshi*)  dex pgrep -f "odoshi ru[n]" >/dev/null 2>&1 ;;
    foreman)  dex pgrep -f "foreman: mai[n]" >/dev/null 2>&1 ;;
    overmind) dex pgrep -f "overmind star[t]" >/dev/null 2>&1 ;;
    compose)  return 0 ;; # the docker daemon does not die with the child
    bare)     return 1 ;; # there is no supervisor, by definition
  esac
}

# ------------------------------------------------------------------- kills -
# Print the container-clock instant, THEN SIGKILL (sub-ms apart; ordering
# avoids racing the container teardown in the compose case).
kill_web() {
  case "$1" in
    compose)
      $COMPOSE exec -T web bash -c "date +%s.%N && pkill -9 -f 'pum[a]'"
      ;;
    *)
      $COMPOSE exec -T -e P="$WEB_PATTERN" runner bash -c \
        'date +%s.%N && pid=$(pgrep -f "$P" | sort -n | head -1) && [ -n "$pid" ] && kill -9 "$pid"'
      ;;
  esac
}

kill_jobs() {
  case "$1" in
    compose)
      $COMPOSE exec -T jobs bash -c "date +%s.%N && pkill -9 -f 'solid-queu[e]|bin/job[s]'"
      ;;
    *)
      $COMPOSE exec -T -e P="$JOBS_PATTERN" runner bash -c \
        'date +%s.%N && pkill -9 -f "$P"'
      ;;
  esac
}

# ----------------------------------------------------------------- cleanup -
# Tear down whatever contender (and helpers) may be running, wait for port
# 3000 to free up. Runs bench/cleanup.sh as a FILE so the cleanup shell's
# own cmdline carries none of the kill patterns (the self-match trap that
# once left a stale overmind socket and failed the next boot).
cleanup_all() {
  $COMPOSE --profile compose stop -t 3 web jobs >/dev/null 2>&1 || true
  $COMPOSE --profile compose rm -f web jobs >/dev/null 2>&1 || true
  dex bash /bench/cleanup.sh
}

reset_db() {
  psqlx app_production 'TRUNCATE job_markers RESTART IDENTITY' || true
  psqlx app_production_queue 'TRUNCATE solid_queue_jobs, solid_queue_scheduled_executions, solid_queue_ready_executions, solid_queue_claimed_executions, solid_queue_blocked_executions, solid_queue_failed_executions, solid_queue_pauses, solid_queue_processes, solid_queue_semaphores, solid_queue_recurring_executions, solid_queue_recurring_tasks RESTART IDENTITY CASCADE' || true
}

# first_marker_after KILL_TS TIMEOUT — epoch float of the first marker row
# performed after the kill (the "jobs flowing again" instant).
first_marker_after() {
  local t=$1 timeout=$2 start=$SECONDS val
  while :; do
    val=$(psqlq app_production "SELECT COALESCE(min(performed_at_f), 0) FROM job_markers WHERE performed_at_f > $t")
    if [ -n "$val" ] && [ "$val" != "0" ]; then echo "$val"; return 0; fi
    if (( SECONDS - start > timeout )); then return 1; fi
    sleep 0.3
  done
}

# ------------------------------------------------------------ mode profiles -
load_mode() {
  MODE="${MODE:-full}"
  case "$MODE" in
    full)
      N=5; N_NONDET=2; STEADY=8; REC_TIMEOUT=60; JOBS_TIMEOUT=90; NONREC_WINDOW=30
      RSS_WINDOW=300; LAT_WARMUP=5; LAT_DURATION=30; LAT_RUNS=5; DETECT_TIMEOUT=120
      LOAD_RPS=50; RSS_RPS=25; BOOT_TIMEOUT=120 ;;
    ci)
      N=3; N_NONDET=1; STEADY=4; REC_TIMEOUT=45; JOBS_TIMEOUT=60; NONREC_WINDOW=15
      RSS_WINDOW=60; LAT_WARMUP=3; LAT_DURATION=15; LAT_RUNS=2; DETECT_TIMEOUT=60
      LOAD_RPS=50; RSS_RPS=25; BOOT_TIMEOUT=120 ;;
    smoke)
      N=1; N_NONDET=1; STEADY=2; REC_TIMEOUT=45; JOBS_TIMEOUT=60; NONREC_WINDOW=10
      RSS_WINDOW=20; LAT_WARMUP=2; LAT_DURATION=5; LAT_RUNS=1; DETECT_TIMEOUT=45
      LOAD_RPS=20; RSS_RPS=10; BOOT_TIMEOUT=120 ;;
    *) echo "unknown MODE: $MODE" >&2; exit 78 ;;
  esac
  RAW_FILE="${RAW_FILE:-$ROOT/results/raw/$(date +%Y-%m-%d)-$MODE.jsonl}"
  mkdir -p "$(dirname "$RAW_FILE")"
  export MODE RAW_FILE
}
