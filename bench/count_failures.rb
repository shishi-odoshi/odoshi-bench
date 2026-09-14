# frozen_string_literal: true
# Count loadgen requests that failed (status != 200) in the window [T0, T1],
# plus the total in-window request count. Prints JSON.
#
#   ruby count_failures.rb LOADGEN_JSONL T0 T1
require "json"

file, t0, t1 = ARGV
abort "usage: count_failures.rb FILE T0 T1" unless t1
t0 = Float(t0)
t1 = Float(t1)

total = 0
failed = 0
File.foreach(file) do |line|
  row = JSON.parse(line) rescue next
  next unless row["t"].between?(t0, t1)
  total += 1
  failed += 1 unless row["s"] == 200
end

puts({ window_s: (t1 - t0).round(3), requests: total, failed: failed }.to_json)
