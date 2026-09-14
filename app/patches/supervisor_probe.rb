# frozen_string_literal: true
# Track C contender: odoshi detecting the wedge via its PASSIVE HTTP probe.
# The :puma adapter probes /up; a wedged child answers 503 with a live PID,
# which is exactly :degraded (DESIGN §5). Three consecutive degraded checks
# one second apart => drain + restart.
#
# ODOSHI_SUPPRESS_HEARTBEAT is required for the probe to be the judge at
# all: health is active-first, so the template's default always-"healthy"
# heartbeat would out-vote the failing probe (see README finding F3).
strategy :rest_for_one
max_restarts 5, within: 60
backoff :exponential, base: 1, cap: 30

child :web, adapter: :puma, port: Integer(ENV.fetch("PORT", 3000)), shutdown: 30,
            health_interval: 1, degraded_restart_after: 3,
            env: { "ODOSHI_SUPPRESS_HEARTBEAT" => "1" }
child :jobs, adapter: :solid_queue, shutdown: 60,
             env: { "ODOSHI_CHILD_ID" => "jobs" }
