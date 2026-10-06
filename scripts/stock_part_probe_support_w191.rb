# frozen_string_literal: true
# Thin adapter for W191 to reuse W185's stock part inventory methods without
# pretending a ClickHouse binary is also a Crystal helper executable.

require_relative 'check_array_json_parts_w185'

class StockPartProbeSupportW191 < CheckArrayJSONPartsW185::Probe
  def initialize(binary, evidence_root)
    @binary = File.expand_path(binary)
    @root = File.expand_path(evidence_root)
    @invocations = []
  end
end
