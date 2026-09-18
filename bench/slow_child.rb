# frozen_string_literal: true
# Track E fixture child: a process with a deliberately SLOW READINESS and a
# deliberately SLOW DRAIN — the two things Track E measures the scheduling of.
#
#   ruby slow_child.rb PORT BOOT_DELAY_S LINGER_S
#
# Lifecycle:
#   1. sleep BOOT_DELAY_S            — "booting" (the supervisor's probe fails)
#   2. bind PORT and accept          — readiness: the TCP probe now answers
#   3. on SIGTERM: sleep LINGER_S, exit 0  — a graceful drain that takes time
#
# The port is the readiness signal precisely because it is observable from
# outside the supervisor: the same measurement works identically on 0.3.1 and
# 0.4.0, with no dependency on gem internals or telemetry text that changed
# between versions.
#
# PORT 0 binds nothing (health is then plain PID-aliveness). Replicas are
# interchangeable peers running the SAME command, so they cannot each own a
# distinct probe port; the drain scenarios use port 0 on BOTH sides of the
# A/B so the two shapes stay directly comparable.
require "socket"

port, boot_delay, linger = ARGV
abort "usage: slow_child.rb PORT BOOT_DELAY_S LINGER_S" unless linger
port = Integer(port)
boot_delay = Float(boot_delay)
linger = Float(linger)

draining = false
# SIGTERM is the supervisor's drain signal. Linger, then exit 0 — a clean
# graceful stop, so a slow drain is honest work and never a kill.
Signal.trap("TERM") do
  draining = true
end

sleep boot_delay
server = port.zero? ? nil : TCPServer.new("127.0.0.1", port)

loop do
  if draining
    sleep linger
    exit 0
  end
  # Poll with a short timeout so the drain flag is checked promptly.
  if server.nil?
    sleep 0.05
  elsif IO.select([server], nil, nil, 0.05)
    begin
      server.accept.close
    rescue IOError, SystemCallError
      next
    end
  end
end
