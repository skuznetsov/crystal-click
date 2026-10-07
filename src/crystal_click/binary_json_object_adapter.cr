module CrystalClick
  # Logical, zero-serde bridge between immutable BinaryJsonRow values and the
  # existing ObjectDocument owner. Object codecs remain responsible for
  # physical-lane admission and encoding. The caller selects the site/arm and
  # validates its contextual roster with DynamicJsonObjectBinding#validate_for!;
  # a row itself carries no outer Dynamic site provenance.
  module BinaryJsonObjectAdapter
    def self.to_document(
      row : BinaryJsonRow,
      binding : DynamicJsonObjectBinding,
      budget : BinaryCodecBudget,
      depth : Int = 1,
    ) : ObjectDocument
      begin
        binding.validate_row!(row, budget, depth)
      rescue ex : ArgumentError
        raise ex if budget.writing?
        raise CorruptPartError.new("JSON row descriptor is inconsistent with its bound Dynamic arm: #{ex.message}")
      end

      count = row.path_count.to_u64
      budget.visit_node(depth)
      # The row visitor already charged the borrowed values and their nodes;
      # the output document adds path edges, not another child-node tree.
      budget.charge_elements(count) if count > 0_u64
      # path_at creates a temporary key and ObjectDocument detaches that key
      # into its own immutable owner. Charge the complete copy set first.
      charge_path_copies!(row, budget, 2_u64)

      values = Hash(String, BinaryValue).new(initial_capacity: row.path_count)
      row.path_count.times do |index|
        values[row.path_at(index)] = row.value_at(index)
      end
      ObjectDocument.new(values)
    end

    def self.to_json_row(
      document : ObjectDocument,
      binding : DynamicJsonObjectBinding,
      budget : BinaryCodecBudget,
      depth : Int = 1,
    ) : BinaryJsonRow
      count = document.path_count.to_u64
      # Prove collection and path-byte bounds before path_at materializes any
      # intermediate Hash key. BinaryJsonRow then charges its retained owner,
      # inherited descriptor/value trees, and final path records.
      budget.ensure_depth(depth)
      budget.ensure_depth(depth + 1) if count > 0_u64
      budget.visit_node(depth)                          # borrowed ObjectDocument root
      budget.preflight_children(count) if count > 0_u64 # source document path edges
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      context.validate_type_tree(binding.json_type, depth)
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count * 2_u64)
      charge_path_copies!(document, budget, 1_u64)

      values = Array(Tuple(String, BinaryValue)).new(document.path_count)
      document.path_count.times do |index|
        path = document.path_at(index)
        values << {path, document.value_for(path)}
      end

      begin
        BinaryJsonRow.new(binding.json_type, values, budget, depth: depth)
      rescue ex : ArgumentError
        raise ex if budget.writing?
        raise CorruptPartError.new("Object JSON child is inconsistent with its bound Dynamic descriptor: #{ex.message}")
      end
    end

    private def self.charge_path_copies!(row : BinaryJsonRow, budget : BinaryCodecBudget, copies : UInt64) : Nil
      bytes = 0_u64
      row.path_count.times do |index|
        bytes = checked_copy_bytes(bytes, row.path_byte_size(index).to_u64, copies, budget)
      end
      budget.charge_wire_bytes(bytes) if bytes > 0_u64
    end

    private def self.charge_path_copies!(document : ObjectDocument, budget : BinaryCodecBudget, copies : UInt64) : Nil
      bytes = 0_u64
      document.path_count.times do |index|
        bytes = checked_copy_bytes(bytes, document.path_byte_size_at(index).to_u64, copies, budget)
      end
      budget.charge_wire_bytes(bytes) if bytes > 0_u64
    end

    private def self.checked_copy_bytes(
      current : UInt64,
      path_bytes : UInt64,
      copies : UInt64,
      budget : BinaryCodecBudget,
    ) : UInt64
      if copies != 0_u64 && path_bytes > (UInt64::MAX - current) // copies
        if budget.writing?
          raise UnsupportedFormatError.new("JSON Object bridge path-copy size overflows UInt64")
        else
          raise CorruptPartError.new("JSON Object bridge path-copy size overflows UInt64")
        end
      end
      current + path_bytes * copies
    end
  end
end
