#!/usr/bin/env bash
# In-container teardown. Run as a FILE (`bash /bench/cleanup.sh`), never as
# `bash -c '<literal patterns>'`: pgrep/pkill -f match a process's whole
# cmdline, and a shell carrying the patterns in its own argv self-matches
# and gets killed mid-cleanup (the classic trap — and the bug that once left
# a stale overmind socket and failed the next boot). As a file the cleanup
# shell's cmdline is just "bash /bench/cleanup.sh", which matches nothing.
#
# Even so, every pattern keeps a [bracket] class as belt-and-suspenders.

# Graceful first.
pkill -TERM -f "odoshi ru[n]" 2>/dev/null
pkill -TERM -f "foreman: mai[n]" 2>/dev/null
pkill -TERM -f "overmin[d]" 2>/dev/null
pkill -TERM -f "bench/loadgen.r[b]" 2>/dev/null
pkill -TERM -f "bench/enqueue_loop.r[b]" 2>/dev/null

# Short grace loop for the supervisors + workers to exit on their own.
for _ in $(seq 1 20); do
  pgrep -f "odoshi ru[n]|foreman: mai[n]|overmin[d]|puma .*config/pum[a].rb|pum[a] [0-9].*(tcp|unix|ssl)://|solid-queu[e]|bin/job[s]" >/dev/null 2>&1 || break
  sleep 0.3
done

# Force the rest.
pkill -9 -f "odoshi ru[n]" 2>/dev/null
pkill -9 -f "foreman: mai[n]" 2>/dev/null
pkill -9 -f "overmin[d]" 2>/dev/null
pkill -9 -f "tmu[x]" 2>/dev/null
pkill -9 -f "puma .*config/pum[a].rb" 2>/dev/null
pkill -9 -f "pum[a] [0-9].*(tcp|unix|ssl)://" 2>/dev/null
pkill -9 -f "solid-queu[e]" 2>/dev/null
pkill -9 -f "bin/job[s]" 2>/dev/null
pkill -9 -f "bench/loadgen.r[b]" 2>/dev/null
pkill -9 -f "bench/enqueue_loop.r[b]" 2>/dev/null

rm -f /tmp/overmind.sock /app/.overmind.sock /tmp/load.jsonl 2>/dev/null

# Port 3000 must actually be free before the next contender boots.
ruby -e '
  require "socket"
  120.times do
    begin
      TCPSocket.new("127.0.0.1", 3000).close
      sleep 0.25
    rescue StandardError
      exit 0
    end
  end
  abort "port 3000 still bound after cleanup"
'
