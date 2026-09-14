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

# No run may end in harness-error outcomes.
bad = aggs.flat_map { |a| a["outcomes"].keys } & %w[boot_failed kill_failed wedge_failed wedge_not_applied jobs_never_flowed pid_not_found]
failures << "harness-error outcomes present: #{bad}" unless bad.empty?

if failures.empty?
  puts "sanity: OK (mode=#{mode}, #{aggs.size} aggregates)"
else
  warn "sanity FAILURES (mode=#{mode}):"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
