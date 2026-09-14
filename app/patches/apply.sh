#!/usr/bin/env bash
# Benchmark-surface patches applied to the template-generated app AT IMAGE
# BUILD. The app under test stays pure template output plus exactly these
# documented deltas — every contender runs the same patched app:
#
#   1. Postgres multi-DB production database.yml (env-driven host/creds).
#   2. queue.yml: Ruby worker pinned to [default] with 0.1s polling; the
#      "elixir" queue is reserved for the beam worker (Track D).
#   3. Marker jobs + job_markers table: recovery/lag measured as plain SQL.
#   4. BenchController: HTTP enqueue endpoint so job traffic originates in
#      the supervised web child (odoshi-integration pattern).
#   5. Wedge middleware: POST /bench/wedge makes /up return 503 while the
#      process stays alive — the Track C wedged state. Process-local memory
#      flag on purpose: a restart cures it, exactly like a real wedged child.
#   6. Heartbeat initializer, extended: template behavior by default; env
#      switches let Track C suppress heartbeats (probe contender) or report
#      wedge-aware degraded state (heartbeat contender).
#   7. Procfile for foreman/overmind (their documented setup).
#   8. Track C supervisor configs (probe / heartbeat detection variants).
set -euxo pipefail

APP_DIR="${1:?usage: apply.sh APP_DIR}"
PATCHES="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"

# --- 1. Postgres production databases ---------------------------------------
cp "$PATCHES/database.yml" config/database.yml

# --- 2. Queue topology: Ruby owns [default]; "elixir" reserved for beam -----
cp "$PATCHES/queue.yml" config/queue.yml

# --- 3+4. Bench surface: marker jobs, model, migration, controller ----------
mkdir -p app/models app/jobs app/controllers db/migrate
cp "$PATCHES/job_marker.rb"        app/models/job_marker.rb
cp "$PATCHES/bench_marker_job.rb"  app/jobs/bench_marker_job.rb
cp "$PATCHES/bench_noop_job.rb"    app/jobs/bench_noop_job.rb
cp "$PATCHES/bench_controller.rb"  app/controllers/bench_controller.rb
cp "$PATCHES/create_job_markers.rb" db/migrate/20260101000000_create_job_markers.rb

ruby -e '
  path = "config/routes.rb"
  src = File.read(path)
  inject = <<-ROUTES
  # odoshi-bench endpoints (job traffic originates inside the web child).
  get "/bench/enqueue", to: "bench#enqueue"
  ROUTES
  src.sub!(/Rails\.application\.routes\.draw do\n/) { |m| m + inject } or abort "routes.rb: draw block not found"
  File.write(path, src)
'

# --- 5. Wedge middleware (config/ is not autoloaded — no Zeitwerk clash) ----
mkdir -p config/middleware
cp "$PATCHES/bench_wedge.rb" config/middleware/bench_wedge.rb

ruby -e '
  path = "config/environments/production.rb"
  src = File.read(path)
  src.gsub!("config.assume_ssl = true", "config.assume_ssl = false")
  src.gsub!("config.force_ssl = true", "config.force_ssl = false")
  extra = <<-RUBY

  # odoshi-bench: the Track C wedged state — POST /bench/wedge flips a
  # process-local flag that makes /up answer 503 while the process lives on.
  require Rails.root.join("config/middleware/bench_wedge")
  config.middleware.insert_before 0, BenchWedge
  RUBY
  src.sub!(/^end\s*\Z/) { extra + "end\n" } or abort "production.rb: trailing end not found"
  File.write(path, src)
'

# --- 6. Heartbeat initializer: template default + Track C env switches ------
cp "$PATCHES/odoshi_heartbeat.rb" config/initializers/odoshi_heartbeat.rb

# --- 7. Procfile: foreman / overmind formation (their documented setup) -----
cp "$PATCHES/Procfile" Procfile

# --- 8. Track C supervisor configs -------------------------------------------
cp "$PATCHES/supervisor_probe.rb"     config/supervisor_probe.rb
cp "$PATCHES/supervisor_heartbeat.rb" config/supervisor_heartbeat.rb

echo "bench patches applied"
