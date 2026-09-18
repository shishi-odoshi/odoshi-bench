# frozen_string_literal: true
# Track E driver: generates a supervisor config, runs it under the pinned
# odoshi in this image, and measures the two scheduling numbers from OUTSIDE
# the supervisor, on one clock:
#
#   boot_s   supervisor start -> every child's readiness port accepting
#   drain_s  SIGTERM -> supervisor exited (with its exit status)
#
# Readiness is a TCP port the fixture binds only after its boot delay, and
# drain is the supervisor's own exit: both are observable identically on
# 0.3.1 and 0.4.0, with no dependency on gem internals or telemetry text.
# That is what makes the A/B honest — the harness cannot tell the versions
# apart except by what they do.
#
#   ruby e_driver.rb --children 5 --boot 1.5 --strategy one_for_one
#   ruby e_driver.rb --children 5 --linger 1.0 --replicas --measure drain
#
# Prints one JSON object. Exits non-zero if the scenario could not be run
# (e.g. --replicas on 0.3.1, where `count:` does not exist — that failure is
# a RESULT, reported as unsupported, not a harness bug).
require "json"
require "socket"
require "optparse"
require "tempfile"

opts = { children: 5, boot: 1.5, linger: 0.0, strategy: "one_for_one",
         replicas: false, base_port: 41_000, measure: "boot", timeout: 60 }
OptionParser.new do |o|
  o.on("--children N", Integer) { |v| opts[:children] = v }
  o.on("--boot SECONDS", Float) { |v| opts[:boot] = v }
  o.on("--linger SECONDS", Float) { |v| opts[:linger] = v }
  o.on("--strategy NAME") { |v| opts[:strategy] = v }
  o.on("--replicas") { opts[:replicas] = true }
  o.on("--base-port N", Integer) { |v| opts[:base_port] = v }
  o.on("--measure WHAT") { |v| opts[:measure] = v } # boot | drain
  o.on("--timeout SECONDS", Float) { |v| opts[:timeout] = v }
end.parse!

N = opts[:children]
MEASURE_DRAIN = opts[:measure] == "drain"
# Drain scenarios use PID health (port 0 = the fixture never binds): replicas
# are interchangeable peers running the SAME command, so they cannot each own
# a distinct probe port, and a shared one would let the first binder vouch for
# all five. Dropping the probe keeps BOTH sides of the A/B identical and makes
# the drain number pure. Boot scenarios keep per-child ports, which replicas
# do not need (they are separately declared children on both versions).
PORTS = MEASURE_DRAIN ? Array.new(N, 0) : (1..N).map { |i| opts[:base_port] + i }
FIXTURE = File.expand_path("slow_child.rb", __dir__)

def child_line(id, port, o, count: nil)
  probe = port.zero? ? "" : ", probe: { tcp: #{port} }"
  tail = count ? ", count: #{count}" : ""
  %(child :#{id}, adapter: :command, start_timeout: 30, health_interval: 5#{tail}, ) +
    %(cmd: "ruby #{FIXTURE} #{port} #{o[:boot]} #{o[:linger]}"#{probe})
end

config = +"strategy :#{opts[:strategy]}\nmax_restarts 20, within: 60\nbackoff :none\nsocket nil\n"
config << if opts[:replicas]
            # 0.4.0 only: ONE declaration slot holding N interchangeable peers.
            child_line("w", PORTS.first, opts, count: N) + "\n"
          else
            # The only way to express N workers before 0.4.0: N ordered slots.
            (1..N).map { |i| child_line("c#{i}", PORTS[i - 1], opts) }.join("\n") + "\n"
          end

cfg = Tempfile.new(["e_config", ".rb"])
cfg.write(config)
cfg.close

def listening?(port)
  Socket.tcp("127.0.0.1", port, connect_timeout: 0.2) { true }
rescue SystemCallError, IO::TimeoutError
  false
end

def fixture_count
  `pgrep -fc "slow_child\\.rb" 2>/dev/null`.to_i
end

# How many children the supervisor actually declared, read from its own
# start event: "supervisor.start {strategy: ..., children: [:a, :b]}".
def declared_children(log_path)
  line = File.read(log_path)[/supervisor\.start.*/] or return nil
  roster = line[/children: \[(.*?)\]/, 1] or return nil
  roster.split(",").count { |s| !s.strip.empty? }
rescue Errno::ENOENT
  nil
end

log = Tempfile.new(["e_sup", ".log"])
t0 = Process.clock_gettime(Process::CLOCK_REALTIME)
mono0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pid = Process.spawn("odoshi", "run", cfg.path, out: log.path, err: [log.path, "a"])

result = { version: ENV.fetch("ODOSHI_VERSION", "unknown"), children: N,
           strategy: opts[:strategy], replicas: opts[:replicas],
           boot_delay_s: opts[:boot], linger_s: opts[:linger] }

elapsed = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) - mono0 }

begin
  # ---- readiness: every child up (ports listening, or all processes alive) --
  ready = false
  until elapsed.call > opts[:timeout]
    if Process.waitpid(pid, Process::WNOHANG)
      result[:outcome] = "supervisor_exited_during_boot"
      result[:log] = File.read(log.path)[0, 800]
      result[:unsupported] = true if result[:log].include?("ConfigError") || result[:log].include?("count")
      puts JSON.generate(result)
      exit 1
    end
    # The supervisor announces its roster on start. A version that does not
    # understand `count:` swallows it into **opts and declares ONE child —
    # silently, with no error. Detect that from the roster rather than waiting
    # out a timeout, so the table can say "unsupported" instead of "slow".
    if (declared = declared_children(log.path)) && declared < N && opts[:replicas]
      result[:outcome] = "replicas_unsupported"
      result[:unsupported] = true
      result[:declared_children] = declared
      result[:note] = "count: silently ignored — #{declared} child declared, #{N} requested"
      puts JSON.generate(result)
      exit 1
    end
    ready = MEASURE_DRAIN ? fixture_count >= N : PORTS.all? { |p| listening?(p) }
    break if ready
    sleep 0.02
  end

  unless ready
    result[:outcome] = "boot_timeout"
    result[:log] = File.read(log.path)[0, 800]
    puts JSON.generate(result)
    exit 1
  end
  result[:boot_s] = (Process.clock_gettime(Process::CLOCK_REALTIME) - t0).round(3)

  # ---- drain: SIGTERM -> supervisor exit ----------------------------------
  sleep 0.3 # let monitors settle so the drain is a steady-state drain
  t_term = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Process.kill("TERM", pid)
  _, status = Process.waitpid2(pid)
  result[:drain_s] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_term).round(3)
  result[:exit_code] = status.exitstatus
  result[:outcome] = status.exitstatus.zero? ? "ok" : "dirty_exit"
rescue Errno::ESRCH, Errno::ECHILD
  result[:outcome] = "supervisor_vanished"
ensure
  begin
    Process.kill("KILL", pid)
    Process.waitpid(pid)
  rescue StandardError
    nil
  end
  cfg.unlink
  log.unlink
end

puts JSON.generate(result)
