#!/usr/bin/env ruby
# frozen_string_literal: true
# Append one measurement row (JSON line) to the raw results file.
#
#   emit_row.rb RAW_FILE track=A contender=odoshi metric=web_recovery_s \
#               run=1 value=2.31 outcome=recovered extra:='{"failed":41}'
#
# k=v pairs become strings/numbers (numeric strings are coerced); k:=v pairs
# are parsed as JSON. `value=null`/absent value stays null.
require "json"
require "time"

file = ARGV.shift or abort "usage: emit_row.rb RAW_FILE k=v [k:=json] ..."
row = { "ts" => Time.now.utc.iso8601, "mode" => ENV.fetch("MODE", "full") }

ARGV.each do |arg|
  if arg =~ /\A([a-z_]+):=(.*)\z/m
    row[$1] = JSON.parse($2)
  elsif arg =~ /\A([a-z_]+)=(.*)\z/m
    key, val = $1, $2
    row[key] =
      if val == "null" || val.empty? then nil
      elsif val =~ /\A-?\d+\z/ then Integer(val)
      elsif val =~ /\A-?\d*\.\d+(e-?\d+)?\z/i then Float(val)
      else val
      end
  else
    abort "emit_row.rb: malformed arg #{arg.inspect}"
  end
end

File.open(file, "a") { |f| f.puts(JSON.generate(row)) }
puts "row: #{row.slice('track', 'contender', 'metric', 'run', 'value', 'outcome').compact.to_json}"
