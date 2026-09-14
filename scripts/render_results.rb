#!/usr/bin/env ruby
# frozen_string_literal: true
# Aggregate raw measurement rows into results/results.json and render the
# README's results tables between the BENCH:BEGIN/END markers. The tables
# are GENERATED — edit this script or rerun the bench, never the tables.
#
#   ruby scripts/render_results.rb results/raw/DATE-MODE.jsonl
require "json"
require "time"

ROOT = File.expand_path("..", __dir__)
raw_file = ARGV[0] or abort "usage: render_results.rb RAW_JSONL"

rows = []
meta = nil
File.foreach(raw_file) do |line|
  row = JSON.parse(line)
  if row["row_type"] == "meta" then meta = row else rows << row end
end
abort "no rows in #{raw_file}" if rows.empty?

def percentile(sorted, p)
  return nil if sorted.empty?
  idx = ((sorted.size - 1) * p).round
  sorted[idx]
end

def agg_values(vals)
  s = vals.compact.sort
  return {} if s.empty?
  { "n" => s.size, "median" => percentile(s, 0.5), "p95" => percentile(s, 0.95),
    "min" => s.first, "max" => s.last }
end

aggregates = rows.group_by { |r| [r["track"], r["metric"], r["contender"]] }.map do |(track, metric, contender), group|
  vals = group.map { |r| r["value"] }
  outcomes = group.map { |r| r["outcome"] }.tally
  extra_num = Hash.new { |h, k| h[k] = [] }
  group.each do |r|
    (r["extra"] || {}).each { |k, v| extra_num[k] << v if v.is_a?(Numeric) }
  end
  extra_med = extra_num.transform_values { |v| percentile(v.sort, 0.5) }
  { "track" => track, "metric" => metric, "contender" => contender,
    "runs" => group.size, "outcomes" => outcomes,
    "values" => vals }.merge(agg_values(vals)).merge("extra_median" => extra_med)
end

results = {
  "generated_at" => Time.now.utc.iso8601,
  "mode" => rows.first["mode"],
  "meta" => meta,
  "aggregates" => aggregates.sort_by { |a| [a["track"], a["metric"], a["contender"]] },
  "rows" => rows
}
File.write(File.join(ROOT, "results/results.json"), JSON.pretty_generate(results))
puts "wrote results/results.json (#{rows.size} rows, #{aggregates.size} aggregates)"

# ----------------------------------------------------------- README tables -
A_SEMANTICS = {
  "odoshi" => "restarts the killed child (`rest_for_one`); default 1s-base exponential backoff is part of the number",
  "foreman" => "**by design**: any child death stops the whole formation ([docs](https://github.com/ddollar/foreman)); production supervision is delegated to `foreman export` targets",
  "overmind" => "`--auto-restart` respawns the dead process in its tmux pane, no backoff",
  "compose" => "`restart: always` restarts the crashed container (process = PID 1's child under tini)",
  "bare" => "no supervisor — the honest baseline"
}.freeze

C_SEMANTICS = {
  "odoshi-probe" => "HTTP probe of /up sees 503 ⇒ `:degraded`; `degraded_restart_after: 3` × `health_interval: 1` ⇒ drain + restart",
  "odoshi-heartbeat" => "app self-reports `\"degraded\"` over the supervision socket; same restart rule",
  "foreman" => "no health checking of any kind — process alive ⇒ fine (documented scope: it is a Procfile runner)",
  "overmind" => "no health checking — auto-restart triggers on *death* only",
  "compose" => "healthcheck marks the container `unhealthy`, but restart policies act on *exit* only; stock docker ships no autoheal"
}.freeze

def find(aggs, track, metric, contender)
  aggs.find { |a| a["track"] == track && a["metric"] == metric && a["contender"] == contender }
end

def fmt_s(v) = v.nil? ? "—" : format("%.2fs", v)
def outcome_cell(a, window = nil)
  return "—" unless a
  main = a["outcomes"].max_by { |_, c| c }[0]
  case main
  when "recovered", "detected_recovered" then "recovered #{a['runs']}/#{a['runs']}"
  when "formation_exit" then "formation exited (documented)"
  when "no_supervisor" then "not recovered (no supervisor)"
  when "not_detected" then "not detected within #{window || '?'}s"
  else main
  end
end

md = +""
md << "### Track A — recovery under load (SIGKILL, #{find(aggregates, 'A', 'web_recovery_s', 'odoshi')&.dig('runs') || '?'} runs/contender)\n\n"
md << "Steady load: 50 rps against `/up`, 1 job/s enqueued. Median / p95 of time from SIGKILL to first 200 (web) and to first job performed (jobs). Failed requests = non-200s between kill and recovery at 50 rps.\n\n"
md << "| Contender | Web: outcome | Web median | Web p95 | Failed reqs (median) | Jobs: outcome | Jobs median | Jobs p95 | Semantics |\n"
md << "|---|---|---|---|---|---|---|---|---|\n"
%w[odoshi overmind compose foreman bare].each do |c|
  w = find(aggregates, "A", "web_recovery_s", c)
  j = find(aggregates, "A", "jobs_recovery_s", c)
  next unless w || j
  md << "| #{c} | #{outcome_cell(w)} | #{fmt_s(w&.dig('median'))} | #{fmt_s(w&.dig('p95'))} | #{w&.dig('extra_median', 'failed')&.round || '—'} | #{outcome_cell(j)} | #{fmt_s(j&.dig('median'))} | #{fmt_s(j&.dig('p95'))} | #{A_SEMANTICS[c]} |\n"
end

md << "\n### Track B — overhead\n\n"
md << "**Boot to first `/up` 200** (median of N):\n\n| Contender | Median | p95 |\n|---|---|---|\n"
%w[odoshi foreman overmind compose bare].each do |c|
  b = find(aggregates, "B", "boot_to_up_s", c)
  next unless b
  md << "| #{c} | #{fmt_s(b['median'])} | #{fmt_s(b['p95'])} |\n"
end

md << "\n**Supervisor process RSS / CPU** (the supervisor process only, sampled over a steady window under load; overmind's mandatory tmux server reported separately):\n\n"
md << "| Supervisor | RSS mean | RSS max | CPU% (window) | Window | Note |\n|---|---|---|---|---|---|\n"
%w[odoshi foreman overmind].each do |c|
  r = find(aggregates, "B", "sup_rss_cpu", c)
  next unless r
  e = r["extra_median"]
  note = c == "overmind" ? "+ tmux server #{e['tmux_rss_mb'] ? format('%.1f MB', e['tmux_rss_mb']) : '—'}" : ""
  md << "| #{c} | #{e['rss_mb_mean'] ? format('%.1f MB', e['rss_mb_mean']) : '—'} | #{e['rss_mb_max'] ? format('%.1f MB', e['rss_mb_max']) : '—'} | #{e['cpu_pct'] ? format('%.2f%%', e['cpu_pct']) : '—'} | #{e['window_s']&.round}s | #{note} |\n"
end

md << "\n**Supervised vs bare puma** — the key honesty test. Same app, same complement (web + jobs), `wrk -t2 -c16` against `/up`, warmup discarded; medians across runs:\n\n"
md << "| Setup | mean | p50 | p90 | p99 | req/s |\n|---|---|---|---|---|---|\n"
[["bare", "bare `puma` + `bin/jobs`"], ["odoshi", "odoshi beside-mode (`bin/supervise`)"]].each do |c, label|
  l = find(aggregates, "B", "latency_up", c)
  next unless l
  e = l["extra_median"]
  md << "| #{label} | #{e['mean_ms']&.round(2)}ms | #{e['p50_ms']&.round(2)}ms | #{e['p90_ms']&.round(2)}ms | #{e['p99_ms']&.round(2)}ms | #{e['req_per_s']&.round} |\n"
end

md << "\n### Track C — detection of a wedged (alive-but-broken) child\n\n"
md << "`POST /bench/wedge` makes `/up` answer 503 while the process stays alive. Measured: wedge trigger → first 200. This is the track PID-aliveness supervision cannot win by construction — the table says *why*, per contender.\n\n"
md << "| Contender | Outcome | Median | p95 | Why |\n|---|---|---|---|---|\n"
%w[odoshi-probe odoshi-heartbeat foreman overmind compose].each do |c|
  d = find(aggregates, "C", "detect_recover_s", c)
  next unless d
  window = d.dig("extra_median", "window_s")&.round
  md << "| #{c} | #{outcome_cell(d, window)} | #{fmt_s(d['median'])} | #{fmt_s(d['p95'])} | #{C_SEMANTICS[c]} |\n"
end

d_rows = aggregates.select { |a| a["track"] == "D" }
unless d_rows.empty?
  md << "\n### Track D — sidecar queue drain (1000 no-op jobs, one Postgres)\n\n"
  md << "Pre-enqueued with no worker running; drain measured from `solid_queue_jobs.finished_at`. `drain` includes worker boot; `window` (first→last finish) excludes it. See the same-job-different-runtime caveats below.\n\n"
  md << "| Worker | Outcome | Drain median | Window median | Jobs/s median |\n|---|---|---|---|---|\n"
  %w[ruby-solid-queue beam-elixir].each do |c|
    d = find(aggregates, "D", "drain_1000", c)
    next unless d
    e = d["extra_median"]
    md << "| #{c} | #{d['outcomes'].keys.join(',')} | #{fmt_s(e['drain_s'])} | #{fmt_s(e['window_s'])} | #{e['jobs_per_s']&.round(1) || '—'} |\n"
  end
end

if meta
  md << "\n### Environment\n\n"
  md << "Run #{results['generated_at']} · mode `#{results['mode']}` · #{meta.dig('host', 'ci')} · #{meta.dig('host', 'os')} · #{meta.dig('host', 'cpus')} cpus (container) · #{meta.dig('host', 'docker')}\n\n"
  vers = meta["versions"].map { |k, v| "#{k}: `#{v.to_s.strip.gsub(/\s+/, ' ')[0, 60]}`" }.join(" · ")
  md << vers << "\n"
end

readme_path = File.join(ROOT, "README.md")
if File.exist?(readme_path)
  readme = File.read(readme_path)
  if readme.sub!(/(<!-- BENCH:BEGIN -->\n).*(<!-- BENCH:END -->)/m) { "#{$1}#{md}\n#{$2}" }
    File.write(readme_path, readme)
    puts "README tables rendered"
  else
    warn "README markers not found — tables not rendered"
  end
else
  warn "README.md not found — tables not rendered"
end
