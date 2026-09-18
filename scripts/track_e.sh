#!/usr/bin/env bash
# Track E — concurrency. A clean A/B of the SAME harness against odoshi
# 0.3.1 and 0.4.0, which is the only honest way to attribute the gain: the
# two images differ in exactly one thing, the pinned gem version.
#
#   E1 boot   5 children, ~1.5s readiness each, one_for_one.
#             0.3.1 boots slot-by-slot (expect ~Sum); 0.4.0 boots the whole
#             one_for_one tree concurrently (expect ~max).
#   E2 drain  5 processes that linger ~1s on SIGTERM; stop -> exit 0.
#             0.3.1 can only express this as 5 ORDERED slots (no `count:`),
#             which drain in reverse order serially — that is its contract,
#             not a bug. 0.4.0 declares them as ONE slot of replicas, which
#             drain together. The shapes differ; the table says so.
#   E3 control  the same 5-child tree under the ORDERED strategies on 0.4.0.
#             Must stay ~serial: parallelism is scoped to where declaration
#             order carries no dependency. This is the guard against "we made
#             it fast by breaking the contract".
#
# Track E's subject is the supervisor's own scheduling, so it runs on the
# slim bench-e image (gem + fixture children), not the Rails app image:
# children are fixture commands with a deliberately slow readiness, so the
# number is scheduling, not Rails boot.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_mode

E_VERSIONS=(${E_VERSIONS:-0.3.1 0.4.0})
E_CHILDREN="${E_CHILDREN:-5}"
E_BOOT="${E_BOOT:-1.5}"
E_LINGER="${E_LINGER:-1.0}"
E_RUNS="${E_RUNS:-$N}"

e_image() { echo "odoshi-bench-e:$1"; }

# Build both pinned images unless they already exist (CI pre-builds them).
e_build() {
  local v
  for v in "${E_VERSIONS[@]}"; do
    if ! docker image inspect "$(e_image "$v")" >/dev/null 2>&1; then
      log "building $(e_image "$v")"
      docker build --build-arg "ODOSHI_VERSION=$v" -t "$(e_image "$v")" "$ROOT/bench-e" >/dev/null || return 1
    fi
  done
}

# e_run VERSION ARGS... -> one JSON result line on stdout
e_run() {
  local v=$1; shift
  docker run --rm -v "$ROOT/bench:/bench:ro" "$(e_image "$v")" \
    ruby /bench/e_driver.rb "$@" 2>/dev/null
}

# e_cycle METRIC VERSION RUN CONTENDER_LABEL ARGS...
e_cycle() {
  local metric=$1 v=$2 run=$3 label=$4; shift 4
  local json value outcome
  json="$(e_run "$v" "$@")"
  if [ -z "$json" ]; then
    emit track=E contender="$label" metric="$metric" run="$run" value=null outcome=harness_error
    return
  fi
  value="$(ruby -rjson -e 'j=JSON.parse(ARGV[0]); puts(j[ARGV[1]] || "null")' "$json" "$metric")"
  outcome="$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["outcome"]' "$json")"
  emit track=E contender="$label" metric="$metric" run="$run" value="$value" outcome="$outcome" extra:="$json"
}

e_build || { log "Track E image build failed"; exit 1; }

# ---- E1: boot-to-all-ready, one_for_one, both versions ---------------------
for v in "${E_VERSIONS[@]}"; do
  for run in $(seq 1 "$E_RUNS"); do
    log "E1/boot odoshi-$v run $run"
    e_cycle boot_s "$v" "$run" "odoshi-$v" \
      --children "$E_CHILDREN" --boot "$E_BOOT" --strategy one_for_one
  done
done

# ---- E2: drain-to-exit-0, replicas on 0.4.0 vs N ordered slots on 0.3.1 ----
for v in "${E_VERSIONS[@]}"; do
  # `count:` exists only from 0.4.0; on 0.3.1 the same intent must be spelled
  # as N separately declared children. Both shapes are measured as each
  # version's BEST available expression of "5 interchangeable workers".
  extra_args=()
  label="odoshi-$v"
  case "$v" in
    0.3.1) label="odoshi-0.3.1-5-slots" ;;
    *)     extra_args=(--replicas); label="odoshi-$v-replicas" ;;
  esac
  for run in $(seq 1 "$E_RUNS"); do
    log "E2/drain $label run $run"
    # ${arr[@]+"${arr[@]}"}: expanding an EMPTY array as "${arr[@]}" is an
    # unbound-variable error under `set -u` in bash 3.2 (macOS), which killed
    # the 0.3.1 arm mid-track. The +-guard is the portable spelling.
    e_cycle drain_s "$v" "$run" "$label" \
      --children "$E_CHILDREN" --boot 0 --linger "$E_LINGER" --measure drain \
      ${extra_args[@]+"${extra_args[@]}"}
  done
done

# Documented asymmetry, measured rather than asserted: what `count:` actually
# does on 0.3.1. (Answer: silently ignored — one child, no error.)
if [ "${E_SKIP_ASYMMETRY:-0}" != 1 ]; then
  log "E2/asymmetry probe: count: on 0.3.1"
  e_cycle drain_s 0.3.1 1 "odoshi-0.3.1-count-attempted" \
    --children "$E_CHILDREN" --boot 0 --linger "$E_LINGER" --measure drain --replicas
fi

# ---- E3: ordered-strategy control on 0.4.0 — must stay ~serial -------------
if [ "${E_SKIP_E3:-0}" != 1 ]; then
  for strat in rest_for_one one_for_all; do
    for run in $(seq 1 "$E_RUNS"); do
      log "E3/control 0.4.0 $strat run $run"
      e_cycle boot_s 0.4.0 "$run" "odoshi-0.4.0-$strat" \
        --children "$E_CHILDREN" --boot "$E_BOOT" --strategy "$strat"
    done
  done
fi

log "Track E complete"
