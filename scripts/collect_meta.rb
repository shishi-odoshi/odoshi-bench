#!/usr/bin/env ruby
# frozen_string_literal: true
# Environment disclosure row (honesty rule: the environment is part of the
# result). Captured from inside the runner container + the host.
require "json"
require "time"

raw_file = ARGV[0] or abort "usage: collect_meta.rb RAW_FILE"

def dex(cmd)
  out = `docker compose exec -T runner bash -c '#{cmd}' 2>/dev/null`.strip
  out.empty? ? nil : out
end

meta = {
  "ts" => Time.now.utc.iso8601,
  "mode" => ENV.fetch("MODE", "full"),
  "row_type" => "meta",
  "host" => {
    "os" => `uname -sm`.strip,
    "cpus" => (dex("nproc") || `sysctl -n hw.ncpu 2>/dev/null`.strip),
    "docker" => `docker --version`.strip,
    "ci" => ENV["GITHUB_ACTIONS"] ? "github-actions #{ENV['RUNNER_OS']} #{ENV['ImageOS']}" : "local"
  },
  "versions" => {
    "ruby" => dex("ruby -v"),
    "rails" => dex("cd /app && bin/rails --version"),
    "puma" => dex("cd /app && bundle exec puma --version | head -1"),
    "odoshi" => dex("cd /app && bundle exec odoshi version 2>/dev/null || gem list odoshi | grep odoshi"),
    "solid_queue" => dex("cd /app && bundle list 2>/dev/null | grep -o \"solid_queue ([0-9.]*)\""),
    "foreman" => dex("foreman --version"),
    "overmind" => dex("overmind --version"),
    "wrk" => dex("wrk --version 2>&1 | head -1 | cut -c1-40"),
    "postgres" => `docker compose exec -T postgres postgres --version 2>/dev/null`.strip
  }
}

File.open(raw_file, "a") { |f| f.puts(JSON.generate(meta)) }
puts "meta: #{meta["versions"].transform_values { |v| v.to_s[0, 40] }.to_json}"
