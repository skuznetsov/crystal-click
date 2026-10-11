#!/usr/bin/env ruby
# Standalone literal check for the W262 Ruby/Crystal Float64 signature bridge.

require_relative 'probe_compact_dynamic_w262'

cases = [
  [3.5, 'Float64:0x400c000000000000', true],
  [-2.25, 'Float64:0xc002000000000000', true],
  [0.0, 'Float64:0x0000000000000000', false],
  [-0.0, 'Float64:0x8000000000000000', true],
]

cases.each do |value, expected, legacy_wire_hex_must_differ|
  actual = ProbeCompactDynamicW262.float64_signature(value)
  raise "#{value.inspect}: expected #{expected}, got #{actual}" unless actual == expected

  if legacy_wire_hex_must_differ
    legacy_wire_hex = [Float(value)].pack('E').unpack1('H*')
    raise "#{value.inspect}: mismatch control no longer distinguishes wire-byte hex" if
      actual == "Float64:0x#{legacy_wire_hex}"
  end
end

puts 'W262 Float64 oracle signatures: PASS (positive, negative, signed zero, wire-byte mismatch controls)'
