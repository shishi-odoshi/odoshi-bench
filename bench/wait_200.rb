# frozen_string_literal: true
# Poll URL every 50ms until it answers HTTP 200; print the epoch float of
# the first 200 and exit 0. Exit 1 on timeout. This is the recovery clock
# for Tracks A/B/C (0.05s resolution against multi-second effects).
#
#   ruby wait_200.rb URL TIMEOUT_S
require "net/http"
require "uri"

url, timeout = ARGV
abort "usage: wait_200.rb URL TIMEOUT_S" unless timeout
uri = URI(url)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(timeout)

loop do
  begin
    code = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.25, read_timeout: 1.0) do |http|
      http.get(uri.path).code.to_i
    end
    if code == 200
      puts Process.clock_gettime(Process::CLOCK_REALTIME)
      exit 0
    end
  rescue StandardError
    # not up yet
  end
  exit 1 if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  sleep 0.05
end
