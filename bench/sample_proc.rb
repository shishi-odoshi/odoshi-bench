# frozen_string_literal: true
# Sample one process's RSS and CPU for DURATION seconds, printing a JSON
# summary. RSS from /proc/PID/status (VmRSS); CPU% computed from the
# utime+stime delta across the whole window (not ps's lifetime average).
#
#   ruby sample_proc.rb PID DURATION_S [INTERVAL_S]
require "json"

pid, duration, interval = ARGV
abort "usage: sample_proc.rb PID DURATION_S [INTERVAL_S]" unless duration
pid = Integer(pid)
duration = Float(duration)
interval = Float(interval || 5)
hz = 100.0 # USER_HZ; universally 100 on the platforms this runs on

read_rss_kb = lambda do
  File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)\skB/, 1]&.to_i
end
read_ticks = lambda do
  f = File.read("/proc/#{pid}/stat").split(") ").last.split
  f[11].to_i + f[12].to_i # utime + stime (fields 14/15, offset past comm)
end

samples = []
t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ticks_start = read_ticks.call
deadline = t_start + duration

loop do
  rss = read_rss_kb.call
  samples << rss if rss
  break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep [interval, deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
rescue Errno::ENOENT, Errno::ESRCH
  warn "process #{pid} disappeared mid-sample"
  break
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start
cpu_pct =
  begin
    ((read_ticks.call - ticks_start) / hz) / elapsed * 100.0
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

abort "no samples collected for pid #{pid}" if samples.empty?
puts({
  pid: pid,
  window_s: elapsed.round(1),
  samples: samples.size,
  rss_mb_mean: (samples.sum / samples.size.to_f / 1024).round(1),
  rss_mb_max: (samples.max / 1024.0).round(1),
  cpu_pct: cpu_pct&.round(2)
}.to_json)
