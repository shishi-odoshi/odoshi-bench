# frozen_string_literal: true
# Template heartbeat initializer + two env switches for the detection track:
#
#   ODOSHI_SUPPRESS_HEARTBEAT — send no heartbeat at all. The Track C probe
#     contender needs this: a child that HAS heartbeated is judged by its
#     heartbeats (DESIGN §5 active-first), so the template's always-"healthy"
#     beat would mask probe-detected degradation. See the README finding.
#   BENCH_WEDGE_HEARTBEAT — the Track C heartbeat contender: report
#     "degraded" while the process is wedged (the app self-reporting the
#     state only it can see).
#
# Default behavior (both unset) is byte-for-byte the template's: beat
# "healthy" whenever supervised.
if ENV["ODOSHI_CHILD_ID"] && !ENV["ODOSHI_SUPPRESS_HEARTBEAT"]
  require "odoshi/heartbeat"

  state =
    if ENV["BENCH_WEDGE_HEARTBEAT"]
      -> { defined?(BenchWedge) && BenchWedge.wedged ? "degraded" : "healthy" }
    else
      -> { "healthy" }
    end

  Odoshi::Heartbeat.start(
    id: ENV["ODOSHI_CHILD_ID"],
    interval: Float(ENV.fetch("ODOSHI_HEARTBEAT_INTERVAL", "2")),
    state: state
  )
end
