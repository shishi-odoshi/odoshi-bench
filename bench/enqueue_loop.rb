# frozen_string_literal: true
# Enqueue one marker job per INTERVAL seconds via the app's HTTP surface
# (so enqueues originate in the web child, like production traffic).
# Enqueue failures are expected while the web child is down — logged to
# stderr, never fatal. SIGTERM exits cleanly.
#
#   ruby enqueue_loop.rb BASE_URL PREFIX [INTERVAL_S]
require "net/http"
require "uri"

base, prefix, interval = ARGV
abort "usage: enqueue_loop.rb BASE_URL PREFIX [INTERVAL_S]" unless prefix
interval = Float(interval || 1.0)

stop = false
Signal.trap("TERM") { stop = true }
Signal.trap("INT")  { stop = true }

i = 0
until stop
  uri = URI("#{base}/bench/enqueue?count=1&prefix=#{prefix}-#{i}")
  begin
    Net::HTTP.start(uri.host, uri.port, open_timeout: 0.5, read_timeout: 2.0) do |http|
      http.get("#{uri.path}?#{uri.query}")
    end
  rescue StandardError => e
    warn "enqueue #{i} failed: #{e.class}"
  end
  i += 1
  sleep interval
end
