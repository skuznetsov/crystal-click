module CrystalClick
  # Source-scheduled ordered fragments that form one logical physical role.
  # Coordinate resolution is valid only inside one of these captured callback
  # intervals; gaps and coordinates belonging to adjacent roles are rejected.
  class ObjectSharedInlineRoleReadView
    @role_name : String
    @segments : Array(ObjectSharedInlineCallbackReadSlice)
    @byte_size : UInt64

    def self.from_advanced_binding(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      callback_root_prefix : String,
      owner_kind : Symbol,
      owner_path : String,
      role_name : String,
      segments : Array(ObjectSharedInlineCallbackReadSlice),
      budget : BinaryCodecBudget,
    ) : ObjectSharedInlineRoleReadView
      unless owner_kind == :advanced_bucket || owner_kind == :advanced_copy
        raise ArgumentError.new("inline role view requires an advanced physical owner")
      end
      canonical_names = [] of String
      callback_names = [] of String
      callback_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
        physical_plan,
        plan,
        profile,
        callback_root_prefix,
        budget,
        true,
      )
      budget.ensure_future_nodes(callback_pairs.size.to_u64)
      budget.ensure_future_elements(callback_pairs.size.to_u64)
      callback_by_canonical = Hash(String, String).new(initial_capacity: callback_pairs.size)
      callback_pairs.each do |canonical_name, callback_name|
        if callback_by_canonical.has_key?(canonical_name)
          raise CorruptPartError.new("inline canonical callback name is duplicated")
        end
        callback_by_canonical[canonical_name] = callback_name
      end

      ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
        physical_plan,
        plan,
        profile,
        budget,
      ).each do |name, candidate_kind, candidate_path, candidate_role|
        if candidate_kind == owner_kind && candidate_path == owner_path && candidate_role == role_name
          canonical_names << name
          callback_name = callback_by_canonical[name]? ||
                          raise(CorruptPartError.new("inline role has no raw callback-name binding"))
          callback_names << String.new(callback_name.to_slice)
        end
      end
      if canonical_names.empty?
        raise CorruptPartError.new("inline role is absent from the source callback schedule")
      end
      callback_pairs.size.times { budget.charge_node }
      budget.charge_elements(callback_pairs.size.to_u64) if callback_pairs.size > 0
      new(role_name, canonical_names, callback_names, segments)
    end

    # Constructs a role view from callback identities already paired against
    # the source schedule by the inline decoder. This avoids rebuilding and
    # recharging the complete callback roster once per physical role.
    def self.from_captured_schedule(
      role_name : String,
      expected_canonical_names : Array(String),
      expected_callback_names : Array(String),
      segments : Array(ObjectSharedInlineCallbackReadSlice),
      budget : BinaryCodecBudget,
    ) : ObjectSharedInlineRoleReadView
      if expected_canonical_names.empty? ||
         expected_canonical_names.size != expected_callback_names.size ||
         expected_callback_names.size != segments.size
        raise CorruptPartError.new("inline role callback fragments disagree with the source schedule")
      end
      segment_count = segments.size.to_u64
      budget.ensure_future_nodes(segment_count + 1_u64)
      budget.ensure_future_elements(segment_count)
      budget.ensure_wire_bytes(role_name.bytesize.to_u64)
      budget.charge_node
      budget.charge_elements(segment_count) if segment_count > 0_u64
      budget.charge_wire_bytes(role_name.bytesize.to_u64) if !role_name.empty?
      new(role_name, expected_canonical_names, expected_callback_names, segments)
    end

    private def initialize(
      role_name : String,
      expected_canonical_names : Array(String),
      expected_callback_names : Array(String),
      segments : Array(ObjectSharedInlineCallbackReadSlice),
    )
      if role_name.empty? || segments.empty? || expected_callback_names.empty? ||
         expected_canonical_names.empty?
        raise CorruptPartError.new("inline role read view has no named callback segments")
      end
      unless expected_callback_names.size == segments.size &&
             expected_canonical_names.size == segments.size
        raise CorruptPartError.new("inline role callback count differs from its source schedule")
      end
      first = segments[0]
      total = 0_u64
      previous_end : UInt64? = nil
      segments.each_with_index do |segment, index|
        unless segment.context_matches?(first)
          raise CorruptPartError.new("inline role segments do not share authenticated path provenance")
        end
        unless segment.callback_name == expected_callback_names[index] &&
               segment.canonical_name == expected_canonical_names[index]
          raise CorruptPartError.new("inline callback belongs to a different source-scheduled role")
        end
        if finish = previous_end
          if segment.relative_start < finish
            raise CorruptPartError.new("inline role segments overlap or are out of source order")
          end
        end
        size = segment.byte_size.to_u64
        if size > UInt64::MAX - total
          raise CorruptPartError.new("inline role byte extent overflows UInt64")
        end
        total += size
        previous_end = segment.relative_end
      end
      @role_name = String.new(role_name.to_slice)
      @segments = segments.dup
      @byte_size = total
    end

    def role_name : String
      String.new(@role_name.to_slice)
    end

    def segment_count : Int32
      @segments.size
    end

    def segment_at(index : Int) : ObjectSharedInlineCallbackReadSlice
      @segments[index]
    end

    def byte_size : UInt64
      @byte_size
    end

    def authenticated_context? : Bool
      @segments.all?(&.authenticated_context?)
    end

    def materialize_bytes(budget : BinaryCodecBudget) : Bytes
      size = @byte_size
      if size > Int32::MAX.to_u64
        raise CorruptPartError.new("inline role exceeds the supported logical byte domain")
      end
      if @segments.size == 1
        segment = @segments[0]
        byte_count = segment.byte_size.to_u64
        budget.ensure_wire_bytes(byte_count)
        budget.ensure_future_elements(byte_count)
        budget.charge_wire_bytes(byte_count)
        budget.charge_elements(byte_count)
        return segment.bytes.dup
      end

      budget.ensure_wire_bytes(size)
      budget.ensure_future_elements(size)
      budget.charge_wire_bytes(size)
      budget.charge_elements(size)
      output = Bytes.new(size.to_i32)
      cursor = 0
      @segments.each do |segment|
        segment.bytes.each do |byte|
          output[cursor] = byte
          cursor += 1
        end
      end
      output
    end

    # Resolves a mark pair into this role's concatenated logical byte domain.
    # Only the final segment admits its terminal coordinate; non-final segment
    # endpoints are not silently treated as a following role's start.
    def logical_position(pair : Tuple(UInt64, UInt64)) : Int64
      logical_base = 0_u64
      @segments.each_with_index do |segment, index|
        allow_terminal = index == @segments.size - 1
        if local = segment.local_position_for_pair(pair, allow_terminal)
          position = logical_base + local.to_u64
          if position > Int32::MAX.to_u64
            raise CorruptPartError.new("inline role coordinate exceeds the supported logical byte domain")
          end
          return position.to_i64
        end
        logical_base += segment.byte_size.to_u64
      end
      raise CorruptPartError.new("inline coordinate is outside the authenticated #{@role_name} role segments")
    end

    def same_context?(context : ObjectSharedInlineCoordinateContext) : Bool
      @segments.all? { |segment| segment.context_matches_context?(context) }
    end
  end
end
