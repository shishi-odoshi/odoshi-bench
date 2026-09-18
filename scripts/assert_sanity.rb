#!/usr/bin/env ruby
# frozen_string_literal: true
# CI/regression gate over results.json. These assertions check that the
# STACK still does what it claims — they never assert that odoshi "wins".
# A competitor beating odoshi is a finding, not a failure; odoshi failing
# to recover or detect is a regression and fails the run.
require "json"

results = JSON.parse(File.read(ARGV[0] || "results/results.json"))
aggs = results["aggregates"]
mode = results["mode"]

failures = []
def find(aggs, track, metric, contender)
  aggs.find { |a| a["track"] == track && a["metric"] == metric && a["contender"] == contender }
end

# Track A: odoshi must recover both children in every run, within claimed bounds.
if (a = find(aggs, "A", "web_recovery_s", "odoshi"))
  failures << "odoshi web recovery: outcomes #{a['outcomes']}" unless a["outcomes"].keys == ["recovered"]
  failures << "odoshi web recovery median #{a['median']} > 15s" if a["median"].to_f > 15
end
if (a = find(aggs, "A", "jobs_recovery_s", "odoshi"))
  failures << "odoshi jobs recovery: outcomes #{a['outcomes']}" unless a["outcomes"].keys == ["recovered"]
  failures << "odoshi jobs recovery median #{a['median']} > 30s" if a["median"].to_f > 30
end

# Track A semantics rows must classify as documented, not as errors.
{ "foreman" => "formation_exit", "bare" => "no_supervisor" }.each do |c, expected|
  %w[web_recovery_s jobs_recovery_s].each do |m|
    next unless (a = find(aggs, "A", m, c))
    unless a["outcomes"].key?(expected)
      failures << "#{c} #{m}: expected #{expected}, got #{a['outcomes']}"
    end
  end
end

# Track C: both odoshi detection modes must detect and recover; the
# non-detectors must be classified not_detected (they have no mechanism).
%w[odoshi-probe odoshi-heartbeat].each do |c|
  next unless (a = find(aggs, "C", "detect_recover_s", c))
  failures << "#{c}: outcomes #{a['outcomes']}" unless a["outcomes"].keys == ["detected_recovered"]
end
%w[foreman overmind compose].each do |c|
  next unless (a = find(aggs, "C", "detect_recover_s", c))
  failures << "#{c}: expected not_detected, got #{a['outcomes']}" unless a["outcomes"].keys == ["not_detected"]
end

# Track B: the latency comparison must exist in any full/ci run with track b.
if aggs.any? { |a| a["track"] == "B" }
  %w[odoshi bare].each do |c|
    failures << "missing latency_up for #{c}" unless find(aggs, "B", "latency_up", c)
  end
end

# Track E: the concurrency claims, and the contract they must not break.
if aggs.any? { |a| a["track"] == "E" }
  e = ->(metric, contender) { find(aggs, "E", metric, contender) }
  par = e.call("boot_s", "odoshi-0.4.0")
  ser = e.call("boot_s", "odoshi-0.3.1")
  if par && ser && par["median"] && ser["median"] && par["median"] > ser["median"] / 2.0
    # 0.4.0's one_for_one boot must be materially faster than 0.3.1's serial
    # boot — the headline claim. 2x is a deliberately loose floor (measured
    # gain is ~5x at 5 children): a regression gate, not a target to tune to.
    failures << "E1: 0.4.0 one_for_one boot #{par['median']}s not materially faster than 0.3.1 #{ser['median']}s"
  end
  # E3 is the contract guard: ordered strategies must NOT have gone parallel.
  %w[rest_for_one one_for_all].each do |strat|
    ordered = e.call("boot_s", "odoshi-0.4.0-#{strat}")
    next unless ordered && ordered["median"] && par && par["median"]
    if ordered["median"] < par["median"] * 2
      failures << "E3: 0.4.0 #{strat} boot #{ordered['median']}s looks parallel — ordered strategies must stay serial (declaration order is a dependency contract)"
    end
  end
  # Every E row that claims a measurement must actually have measured one.
  aggs.select { |a| a["track"] == "E" }.each do |a|
    next if a["contender"].include?("count-attempted") # the documented asymmetry probe
    extra = a["outcomes"].keys - %w[ok]
    failures << "E: #{a['contender']} #{a['metric']} outcomes #{a['outcomes']}" unless extra.empty?
  end
end

# No run may end in harness-error outcomes.
bad = aggs.flat_map { |a| a["outcomes"].keys } & %w[boot_failed kill_failed wedge_failed wedge_not_applied jobs_never_flowed pid_not_found harness_error boot_timeout]
failures << "harness-error outcomes present: #{bad}" unless bad.empty?

if failures.empty?
  puts "sanity: OK (mode=#{mode}, #{aggs.size} aggregates)"
else
  warn "sanity FAILURES (mode=#{mode}):"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
