module CrystalClick
  # Compatibility-first bridge from recursive Storage declarations to the
  # neutral DataType reader. Failed candidates never consume the parent's
  # shared budget; only a canonical, admitted prefix-free tree is committed.
  class StorageStaticBulkDeclaration
    def self.parse_slice(
      source : String,
      first : Int32,
      after : Int32,
      parent_budget : BinaryCodecBudget,
      inherited_depth : Int32,
    ) : BinaryDataType?
      bytes = source.to_slice
      if first < 0 || after < first || after > bytes.size
        raise ArgumentError.new("static Bulk declaration slice is outside its source")
      end
      unless parent_budget.writing?
        raise ArgumentError.new("static Bulk declaration trial requires a write-direction parent budget")
      end
      limits = parent_budget.limits
      if inherited_depth <= 0 || inherited_depth > limits.max_depth
        raise ArgumentError.new("static Bulk declaration inherited depth is outside its limits")
      end

      # The gate borrows and scans only the requested source span. In
      # particular, JSON inside a quoted enum label or Tuple field identifier
      # is not a JSON type atom, and a bare `JSON` field name is not a type.
      return nil if json_type_token?(bytes, first, after)

      span_size = (after - first).to_i64
      # Source-span bytes are not charged independently (the canonical reader
      # accounts for its parse/name work), but still bound the temporary copy
      # before allocation. A budget limit is an error, not a rejected grammar
      # candidate, and this check leaves the parent counters untouched.
      parent_budget.ensure_wire_bytes(span_size.to_u64)
      residual_bytes = limits.max_bytes - parent_budget.wire_byte_count

      candidate = String.new(bytes[first, after - first])
      trial_limits = BinaryCodecLimits.new(
        max_depth: limits.max_depth,
        max_nodes: limits.max_nodes - parent_budget.node_count,
        max_elements: limits.max_elements - parent_budget.element_count,
        max_bytes: residual_bytes,
      )
      trial_budget = BinaryCodecBudget.new(trial_limits, true)
      reader = BinaryRecursiveDataTypeNameReader.new(candidate, trial_limits, trial_budget, inherited_depth)
      type = reader.parse || return nil
      name_bounds = BinaryTypeNameBudget.measure(type, trial_budget, inherited_depth)
      return nil unless BinaryTypeNameBudget.materialize(type, trial_budget, name_bounds) == candidate
      return nil unless BinaryPrefixFreeStaticTypeAdmission.admitted?(type, inherited_depth, limits)

      node_delta = trial_budget.node_count.to_u64
      element_delta = trial_budget.element_count.to_u64
      byte_delta = trial_budget.wire_byte_count.to_u64
      # Check the complete transfer before changing any parent dimension.
      parent_budget.ensure_future_nodes(node_delta)
      parent_budget.ensure_future_elements(element_delta)
      parent_budget.ensure_wire_bytes(byte_delta)
      node_delta.times { parent_budget.charge_node }
      parent_budget.charge_elements(element_delta) if element_delta > 0_u64
      parent_budget.charge_wire_bytes(byte_delta) if byte_delta > 0_u64
      type
    end

    private def self.json_type_token?(bytes : Bytes, first : Int32, after : Int32) : Bool
      index = first
      while index < after
        byte = bytes[index]
        if quote_delimiter?(byte)
          delimiter = byte
          index += 1
          while index < after
            current = bytes[index]
            if current == '\\'.ord.to_u8
              index += 1
              index += 1 if index < after
            elsif current == delimiter
              index += 1
              break
            else
              index += 1
            end
          end
          next
        end

        unless identifier_start?(byte)
          index += 1
          next
        end

        token_first = index
        index += 1
        while index < after && identifier_continue?(bytes[index])
          index += 1
        end
        next unless token_equals_json?(bytes, token_first, index)

        lookahead = index
        while lookahead < after && whitespace?(bytes[lookahead])
          lookahead += 1
        end
        return true if lookahead == after
        following = bytes[lookahead]
        return true if following == '('.ord.to_u8 || following == ')'.ord.to_u8 || following == ','.ord.to_u8
        # An identifier followed by another identifier is a named Tuple or
        # Nested field prefix (for example `JSON UInt8`), not a JSON type.
      end
      false
    end

    private def self.token_equals_json?(bytes : Bytes, first : Int32, after : Int32) : Bool
      after - first == 4 &&
        bytes[first] == 'J'.ord.to_u8 &&
        bytes[first + 1] == 'S'.ord.to_u8 &&
        bytes[first + 2] == 'O'.ord.to_u8 &&
        bytes[first + 3] == 'N'.ord.to_u8
    end

    private def self.quote_delimiter?(byte : UInt8) : Bool
      byte == '\''.ord.to_u8 || byte == '`'.ord.to_u8 || byte == '"'.ord.to_u8
    end

    private def self.identifier_start?(byte : UInt8) : Bool
      byte == '_'.ord.to_u8 ||
        ('A'.ord.to_u8 <= byte && byte <= 'Z'.ord.to_u8) ||
        ('a'.ord.to_u8 <= byte && byte <= 'z'.ord.to_u8)
    end

    private def self.identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || ('0'.ord.to_u8 <= byte && byte <= '9'.ord.to_u8)
    end

    private def self.whitespace?(byte : UInt8) : Bool
      byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\n'.ord.to_u8 || byte == '\r'.ord.to_u8
    end
  end
end
