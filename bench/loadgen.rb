# frozen_string_literal: true
# Steady HTTP load at a fixed rate, one JSONL line per request:
#   {"t": <epoch float at request start>, "s": <status, 0 = conn error>, "ms": <latency>}
# Used by Track A to count failed requests through a kill; recovery *time*
# comes from the finer-grained wait_200.rb poller, not from this stream.
#
#   ruby loadgen.rb URL RPS OUTFILE [DURATION_S]
#
# SIGTERM/SIGINT flush and exit cleanly; without DURATION it runs forever.
require "net/http"
require "uri"

url, rps, outfile, duration = ARGV
abort "usage: loadgen.rb URL RPS OUTFILE [DURATION_S]" unless outfile
uri = URI(url)
rps = Float(rps)
deadline = duration ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(duration) : nil

out = File.open(outfile, "w")
out.sync = true
mutex = Mutex.new
stop = false
Signal.trap("TERM") { stop = true }
Signal.trap("INT")  { stop = true }

interval = 1.0 / rps
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ticker = Queue.new

scheduler = Thread.new do
  n = 0
  until stop
    target = t0 + n * interval
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep(target - now) if target > now
    break if deadline && now > deadline
    ticker << true
    n += 1
  end
  8.times { ticker << false }
end

workers = 8.times.map do
  Thread.new do
    while ticker.pop
      break if stop
      t_wall = Process.clock_gettime(Process::CLOCK_REALTIME)
      t_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status =
        begin
          Net::HTTP.start(uri.host, uri.port, open_timeout: 0.25, read_timeout: 1.0) do |http|
            http.get(uri.path).code.to_i
          end
        rescue StandardError
          0
        end
      ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_mono) * 1000.0
      mutex.synchronize { out.puts(%({"t":#{t_wall},"s":#{status},"ms":#{ms.round(2)}})) }
    end
  end
end

scheduler.join
workers.each(&:join)
out.close
