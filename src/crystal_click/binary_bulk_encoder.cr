module CrystalClick
  # Recursive writer for the normalized per-mark physical-lane profile.
  module BinaryBulkEncoder
    def self.encode(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : BinaryBulkStreams
      unless budget.writing?
        raise ArgumentError.new("binary bulk encoder requires a write-direction budget")
      end
      if granules.size == Int32::MAX
        raise UnsupportedFormatError.new("binary bulk mark grid exceeds the supported domain")
      end

      traversal = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      traversal.validate_type_tree(type)
      plan = BinaryBulkTypePlan.new(type, profile)

      # Every per-role offset record, plus each explicit mark row count, is
      # count-derived metadata. Preflight and charge it before allocating lane
      # buffers or the K+1 offset grids.
      mark_records = granules.size.to_u64
      offsets_per_role = checked_add(mark_records, 1_u64)
      grid_records = checked_multiply(plan.role_count, offsets_per_role)
      metadata_records = checked_add(grid_records, mark_records)
      budget.ensure_future_nodes(metadata_records)
      budget.ensure_future_elements(metadata_records)
      budget.charge_elements(metadata_records)
      metadata_records.times { budget.charge_node }

      roles = plan.roles

      # Establish a complete write-side node/edge/wire lower bound before any
      # role buffers or canonical hidden-NULL defaults are materialized.
      total = zero_cost
      default_costs = Hash(UInt64, BinaryBulkDefaultValue::Cost).new
      granules.each do |rows|
        rows.each do |value|
          minimum = minimum_value_cost(type, value, profile, default_costs)
          ensure_cost_fits(budget, add_cost(total, minimum))
          total = add_cost(total, value_cost(type, value, profile, budget, total, default_costs))
        end
      end
      budget.ensure_future_nodes(total[:nodes])
      budget.ensure_future_elements(total[:edges])
      budget.ensure_wire_bytes(total[:wire_bytes])

      lanes = Hash(String, Array(UInt8)).new
      offsets = Hash(String, Array(UInt64)).new
      roles.each do |role|
        lanes[role] = [] of UInt8
        offsets[role] = [0_u64]
      end

      granules.each do |rows|
        rows.each do |value|
          write_value(type, value, "root", 1, traversal, budget, lanes, profile)
        end
        roles.each do |role|
          offsets[role] << lanes[role].size.to_u64
        end
      end

      streams = Hash(String, BinaryBulkStream).new
      roles.each do |role|
        lane = lanes[role]
        bytes = Bytes.new(lane.size) { |index| lane[index] }
        streams[role] = BinaryBulkStream.new(bytes, offsets[role])
      end
      BinaryBulkStreams.new(granules.size, streams)
    end

    private def self.zero_cost : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      {nodes: 0_u64, edges: 0_u64, wire_bytes: 0_u64}
    end

    private def self.add_cost(
      left : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
      right : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
    ) : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      {
        nodes:      checked_add(left[:nodes], right[:nodes]),
        edges:      checked_add(left[:edges], right[:edges]),
        wire_bytes: checked_add(left[:wire_bytes], right[:wire_bytes]),
      }
    end

    private def self.minimum_value_cost(
      type : BinaryDataType,
      value : BinaryValue,
      profile : BinaryBulkProfile,
      default_costs : Hash(UInt64, BinaryBulkDefaultValue::Cost),
    ) : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end
      nodes = 1_u64
      edges = 0_u64
      wire_bytes = 0_u64
      case type.tag
      when BinaryDataType::TAG_STRING
        size = value.byte_size.to_u64
        wire_bytes = profile.with_size_stream? ? checked_add(8_u64, size) : checked_add(var_uint_size(size), size)
      when BinaryDataType::TAG_BOOL, BinaryDataType::TAG_NOTHING
        wire_bytes = 1_u64
      when BinaryDataType::TAG_ARRAY
        count = value.element_count.to_u64
        child = BinaryBulkDefaultValue.measure(type.child_at(0), profile, default_costs)
        nodes = checked_add(nodes, checked_multiply(count, child.nodes))
        edges = checked_add(count, checked_multiply(count, child.edges))
        wire_bytes = checked_add(8_u64, checked_multiply(count, child.wire_bytes))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        unless value.element_count == count
          raise UnsupportedFormatError.new("Tuple bulk value does not match its descriptor")
        end
        if count == 0
          wire_bytes = 1_u64
        else
          edges = count.to_u64
          count.times do |index|
            child = BinaryBulkDefaultValue.measure(type.child_at(index), profile, default_costs)
            nodes = checked_add(nodes, child.nodes)
            edges = checked_add(edges, child.edges)
            wire_bytes = checked_add(wire_bytes, child.wire_bytes)
          end
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count.to_u64
        unless flat_count.even?
          raise UnsupportedFormatError.new("Map bulk value has an incomplete key/value pair")
        end
        nodes = 1_u64
        edges = flat_count
        wire_bytes = 8_u64
        pairs = flat_count // 2_u64
        key = BinaryBulkDefaultValue.measure(type.child_at(0), profile, default_costs)
        item = BinaryBulkDefaultValue.measure(type.child_at(1), profile, default_costs)
        nodes = checked_add(nodes, checked_multiply(pairs, checked_add(key.nodes, item.nodes)))
        edges = checked_add(edges, checked_multiply(pairs, checked_add(key.edges, item.edges)))
        wire_bytes = checked_add(wire_bytes, checked_multiply(pairs, checked_add(key.wire_bytes, item.wire_bytes)))
      when BinaryDataType::TAG_NULLABLE
        child = BinaryBulkDefaultValue.measure(type.child_at(0), profile, default_costs)
        nodes = checked_add(nodes, child.nodes)
        edges = checked_add(1_u64, child.edges)
        wire_bytes = checked_add(1_u64, child.wire_bytes)
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk leaf")
        unless value.byte_size == width
          raise UnsupportedFormatError.new("fixed-width bulk payload does not match its descriptor")
        end
        wire_bytes = width.to_u64
      end
      {nodes: nodes, edges: edges, wire_bytes: wire_bytes}
    end

    private def self.ensure_cost_fits(
      budget : BinaryCodecBudget,
      cost : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
    ) : Nil
      budget.ensure_future_nodes(cost[:nodes])
      budget.ensure_future_elements(cost[:edges])
      budget.ensure_wire_bytes(cost[:wire_bytes])
    end

    private def self.value_cost(
      type : BinaryDataType,
      value : BinaryValue,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      base : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
      default_costs : Hash(UInt64, BinaryBulkDefaultValue::Cost),
    ) : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end

      minimum = minimum_value_cost(type, value, profile, default_costs)
      ensure_cost_fits(budget, add_cost(base, minimum))

      nodes = 1_u64
      edges = 0_u64
      wire_bytes = 0_u64
      case type.tag
      when BinaryDataType::TAG_STRING
        size = value.byte_size.to_u64
        wire_bytes = profile.with_size_stream? ? checked_add(8_u64, size) : checked_add(var_uint_size(size), size)
      when BinaryDataType::TAG_BOOL
        wire_bytes = 1_u64
      when BinaryDataType::TAG_NOTHING
        unless value.is_null?
          raise UnsupportedFormatError.new("Nothing bulk values must use the NULL sentinel")
        end
        wire_bytes = 1_u64
      when BinaryDataType::TAG_ARRAY
        wire_bytes = 8_u64
        count = value.element_count
        edges = count.to_u64
        count.times do |index|
          child = value_cost(type.child_at(0), value.element_at(index), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs)
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = value.element_count
        if count == 0
          wire_bytes = 1_u64
        else
          edges = count.to_u64
          count.times do |index|
            child = value_cost(type.child_at(index), value.element_at(index), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs)
            nodes = checked_add(nodes, child[:nodes])
            edges = checked_add(edges, child[:edges])
            wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
          end
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count
        wire_bytes = 8_u64
        edges = flat_count.to_u64
        flat_count.times do |index|
          child_type = type.child_at(index.even? ? 0 : 1)
          child = value_cost(child_type, value.element_at(index), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs)
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_NULLABLE
        wire_bytes = 1_u64
        edges = 1_u64
        child_type = type.child_at(0)
        if value.is_null?
          default = BinaryBulkDefaultValue.measure(child_type, profile, default_costs)
          nodes = checked_add(nodes, default.nodes)
          edges = checked_add(edges, default.edges)
          wire_bytes = checked_add(wire_bytes, default.wire_bytes)
        else
          child = value_cost(child_type, value.child_at(0), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs)
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk leaf")
        unless value.byte_size == width
          raise UnsupportedFormatError.new("fixed-width bulk payload does not match its descriptor")
        end
        wire_bytes = width.to_u64
      end
      cost = {nodes: nodes, edges: edges, wire_bytes: wire_bytes}
      ensure_cost_fits(budget, add_cost(base, cost))
      cost
    end

    private def self.write_value(
      type : BinaryDataType,
      value : BinaryValue,
      path : String,
      depth : Int,
      traversal : BinaryCodecContext,
      budget : BinaryCodecBudget,
      lanes : Hash(String, Array(UInt8)),
      profile : BinaryBulkProfile,
    ) : Nil
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end
      traversal.visit_node(depth)

      case type.tag
      when BinaryDataType::TAG_STRING
        size = value.byte_size
        if profile.with_size_stream?
          write_u64(lanes, "#{path}.string_sizes", size.to_u64, budget)
        else
          write_var_uint(lanes, "#{path}.data", size.to_u64, budget)
        end
        size.times do |index|
          write_byte(lanes, "#{path}.data", value.byte_at(index), budget)
        end
      when BinaryDataType::TAG_BOOL
        write_byte(lanes, "#{path}.data", BoolValueCodec.encode(value.as_bool), budget)
      when BinaryDataType::TAG_NOTHING
        unless value.is_null?
          raise UnsupportedFormatError.new("Nothing bulk values must use the NULL sentinel")
        end
        write_byte(lanes, "#{path}.data", 0x30_u8, budget)
      when BinaryDataType::TAG_ARRAY
        count = value.element_count
        traversal.preflight_children(count.to_u64) unless count == 0
        traversal.ensure_depth(depth + 1) unless count == 0
        write_u64(lanes, "#{path}.sizes", count.to_u64, budget)
        count.times do |index|
          write_value(type.child_at(0), value.element_at(index), "#{path}.elements", depth + 1, traversal, budget, lanes, profile)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = value.element_count
        if count == 0
          write_byte(lanes, "#{path}.data", 0x30_u8, budget)
        else
          traversal.preflight_children(count.to_u64)
          traversal.ensure_depth(depth + 1)
          count.times do |index|
            write_value(type.child_at(index), value.element_at(index), "#{path}.field.#{index}", depth + 1, traversal, budget, lanes, profile)
          end
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count
        pairs = flat_count // 2
        traversal.preflight_children(flat_count.to_u64) unless flat_count == 0
        traversal.ensure_depth(depth + 1) unless flat_count == 0
        write_u64(lanes, "#{path}.sizes", pairs.to_u64, budget)
        flat_count.times do |index|
          child_index = index.even? ? 0 : 1
          child_path = "#{path}.elements.field.#{child_index}"
          write_value(type.child_at(child_index), value.element_at(index), child_path, depth + 1, traversal, budget, lanes, profile)
        end
      when BinaryDataType::TAG_NULLABLE
        child_type = type.child_at(0)
        if value.is_null?
          write_byte(lanes, "#{path}.nulls", 1_u8, budget)
          traversal.preflight_children(1_u64)
          traversal.ensure_depth(depth + 1)
          child = BinaryBulkDefaultValue.build(child_type)
          write_value(child_type, child, "#{path}.nested", depth + 1, traversal, budget, lanes, profile)
        else
          write_byte(lanes, "#{path}.nulls", 0_u8, budget)
          traversal.preflight_children(1_u64)
          traversal.ensure_depth(depth + 1)
          write_value(child_type, value.child_at(0), "#{path}.nested", depth + 1, traversal, budget, lanes, profile)
        end
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk leaf")
        unless value.byte_size == width
          raise UnsupportedFormatError.new("fixed-width bulk payload does not match its descriptor")
        end
        width.times do |index|
          write_byte(lanes, "#{path}.data", value.byte_at(index), budget)
        end
      end
      nil
    end

    private def self.write_byte(lanes : Hash(String, Array(UInt8)), role : String, byte : UInt8, budget : BinaryCodecBudget) : Nil
      buffer = lanes[role]?
      unless buffer
        raise UnsupportedFormatError.new("binary bulk value addressed an unplanned lane")
      end
      budget.charge_wire_bytes(1_u64)
      buffer << byte
      nil
    end

    private def self.write_u64(lanes : Hash(String, Array(UInt8)), role : String, value : UInt64, budget : BinaryCodecBudget) : Nil
      8.times do |index|
        write_byte(lanes, role, ((value >> (index * 8)) & 0xff_u64).to_u8, budget)
      end
      nil
    end

    private def self.write_var_uint(lanes : Hash(String, Array(UInt8)), role : String, value : UInt64, budget : BinaryCodecBudget) : Nil
      remaining = value
      loop do
        payload = (remaining & 0x7f_u64).to_u8
        remaining >>= 7
        write_byte(lanes, role, remaining == 0_u64 ? payload : payload | 0x80_u8, budget)
        break if remaining == 0_u64
      end
      nil
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      remaining = value
      size = 1_u64
      while remaining >= 128_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary bulk write cost overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("binary bulk write cost overflows UInt64")
      end
      left * right
    end
  end
end
