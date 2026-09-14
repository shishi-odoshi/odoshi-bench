# frozen_string_literal: true
# Track C contender: odoshi detecting the wedge via ACTIVE heartbeats. The
# app itself reports "degraded" over the supervision socket while wedged
# (BENCH_WEDGE_HEARTBEAT in the heartbeat initializer) — the state only the
# app can see. Three consecutive degraded reports one second apart =>
# drain + restart.
strategy :rest_for_one
max_restarts 5, within: 60
backoff :exponential, base: 1, cap: 30

child :web, adapter: :puma, port: Integer(ENV.fetch("PORT", 3000)), shutdown: 30,
            health_interval: 1, degraded_restart_after: 3,
            env: { "BENCH_WEDGE_HEARTBEAT" => "1", "ODOSHI_HEARTBEAT_INTERVAL" => "1" }
child :jobs, adapter: :solid_queue, shutdown: 60,
             env: { "ODOSHI_CHILD_ID" => "jobs" }
