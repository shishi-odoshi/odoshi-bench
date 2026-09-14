# frozen_string_literal: true
# Parse `wrk --latency` output (on stdin) into a JSON row of milliseconds.
#
#   wrk -t2 -c16 -d30s --latency URL | ruby wrk_parse.rb
require "json"

def to_ms(val)
  num = Float(val[/[\d.]+/])
  case val
  when /us\z/ then num / 1000.0
  when /ms\z/ then num
  when /m\z/  then num * 60_000.0
  when /s\z/  then num * 1000.0
  else num
  end
end

text = $stdin.read
out = {}
text.scan(/^\s+(50|75|90|99)%\s+(\S+)/) { |pct, val| out["p#{pct}_ms"] = to_ms(val).round(3) }
if (m = text.match(/^Requests\/sec:\s+([\d.]+)/))
  out["req_per_s"] = Float(m[1]).round(1)
end
if (m = text.match(/^\s+Latency\s+(\S+)\s+(\S+)/))
  out["mean_ms"] = to_ms(m[1]).round(3)
end
if (m = text.match(/Non-2xx or 3xx responses:\s+(\d+)/))
  out["non_2xx"] = Integer(m[1])
end
abort "wrk_parse: no latency section found:\n#{text}" if out.empty?
puts out.to_json
