module CrystalClick
  # Detached Compact callback payloads plus unresolved coordinate references.
  # The legacy Tuple callback surface is intentionally retained so existing
  # callers can keep consuming prefix/body arrays without learning about
  # relocations.
  class ObjectSharedAdvancedInlineRawLayout
    alias Callback = Tuple(String, Bytes)

    @prefix_callbacks : Array(Callback)
    @body_callbacks : Array(Callback)
    @relocations : Array(ObjectSharedInlineCallbackRelocation)

    def initialize(
      prefix_callbacks : Array(Callback),
      body_callbacks : Array(Callback),
      relocations : Array(ObjectSharedInlineCallbackRelocation),
      budget : BinaryCodecBudget,
    )
      callback_count = prefix_callbacks.size.to_u64 + body_callbacks.size.to_u64
      relocation_count = relocations.size.to_u64
      validation_work = relocation_validation_work(relocation_count)
      budget.ensure_future_nodes(callback_count * 2_u64 + relocation_count)

      retained_elements = callback_count * 2_u64
      retained_wire_bytes = 0_u64
      {prefix_callbacks, body_callbacks}.each do |callbacks|
        callbacks.each do |callback|
          retained_wire_bytes = checked_add(retained_wire_bytes, callback[0].bytesize.to_u64, budget)
          retained_wire_bytes = checked_add(retained_wire_bytes, callback[1].size.to_u64, budget)
        end
      end
      relocations.each do |relocation|
        retained_wire_bytes = checked_add(retained_wire_bytes, relocation.source_callback_byte_size.to_u64, budget)
        retained_wire_bytes = checked_add(retained_wire_bytes, relocation.target_callback_byte_size.to_u64, budget)
        retained_elements = checked_add(retained_elements, 2_u64, budget)
      end
      budget.ensure_future_elements(retained_elements)
      budget.ensure_future_elements(validation_work)
      budget.ensure_wire_bytes(retained_wire_bytes)
      (callback_count * 2_u64).times { budget.charge_node }
      relocation_count.times { budget.charge_node }
      budget.charge_elements(retained_elements) if retained_elements > 0_u64
      budget.charge_wire_bytes(retained_wire_bytes) if retained_wire_bytes > 0_u64

      @prefix_callbacks = snapshot_callbacks(prefix_callbacks)
      @body_callbacks = snapshot_callbacks(body_callbacks)
      @relocations = relocations.dup
      validate_relocations!(budget)
    end

    def prefix_callback_count : Int32
      @prefix_callbacks.size
    end

    def body_callback_count : Int32
      @body_callbacks.size
    end

    def relocation_count : Int32
      @relocations.size
    end

    def prefix_callback_at(index : Int) : Callback
      callback = @prefix_callbacks[index]
      {String.new(callback[0].to_slice), copy_bytes(callback[1])}
    end

    # Budgeted detached accessor for writer owners that retain callback
    # fragments beyond this layout's lifetime. Charge the name and payload
    # before allocating either copy.
    def prefix_callback_at(index : Int, budget : BinaryCodecBudget) : Callback
      detached_callback(@prefix_callbacks[index], budget)
    end

    def body_callback_at(index : Int) : Callback
      callback = @body_callbacks[index]
      {String.new(callback[0].to_slice), copy_bytes(callback[1])}
    end

    # Budgeted detached accessor for writer owners that retain callback
    # fragments beyond this layout's lifetime. Charge the name and payload
    # before allocating either copy.
    def body_callback_at(index : Int, budget : BinaryCodecBudget) : Callback
      detached_callback(@body_callbacks[index], budget)
    end

    def relocation_at(index : Int) : ObjectSharedInlineCallbackRelocation
      @relocations[index]
    end

    def prefix_callbacks : Array(Callback)
      snapshot_callbacks(@prefix_callbacks)
    end

    def body_callbacks : Array(Callback)
      snapshot_callbacks(@body_callbacks)
    end

    def relocations : Array(ObjectSharedInlineCallbackRelocation)
      @relocations.dup
    end

    private def snapshot_callbacks(callbacks : Array(Callback)) : Array(Callback)
      output = Array(Callback).new(callbacks.size)
      callbacks.each do |callback|
        output << {String.new(callback[0].to_slice), copy_bytes(callback[1])}
      end
      output
    end

    private def copy_bytes(bytes : Bytes) : Bytes
      Bytes.new(bytes.size) { |index| bytes[index] }
    end

    private def detached_callback(callback : Callback, budget : BinaryCodecBudget) : Callback
      wire_bytes = checked_add(callback[0].bytesize.to_u64, callback[1].size.to_u64, budget)
      budget.ensure_future_nodes(2_u64)
      budget.ensure_future_elements(2_u64)
      budget.charge_wire_bytes(wire_bytes)
      budget.charge_node
      budget.charge_node
      budget.charge_elements(2_u64)
      {String.new(callback[0].to_slice), copy_bytes(callback[1])}
    end

    private def relocation_validation_work(count : UInt64) : UInt64
      return 0_u64 if count == 0_u64
      if count > UInt64::MAX // 3_u64
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      levels = 0_u64
      remaining = count - 1_u64
      while remaining > 0_u64
        levels += 1_u64
        remaining >>= 1
      end
      if levels > 0_u64 && count > UInt64::MAX // levels
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      sort_work = count * levels
      base_work = count * 3_u64
      if sort_work > UInt64::MAX - base_work
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      base_work + sort_work
    end

    private def validate_relocations!(budget : BinaryCodecBudget) : Nil
      sizes = Hash(String, UInt64).new
      callback_count = 0_u64
      {@prefix_callbacks, @body_callbacks}.each do |callbacks|
        callbacks.each do |callback|
          callback_count = checked_add(callback_count, 1_u64, budget)
          name = callback[0]
          if sizes.has_key?(name)
            raise UnsupportedFormatError.new("inline callback layout contains a duplicate callback name")
          end
          sizes[name] = callback[1].size.to_u64
        end
      end
      budget.ensure_future_nodes(callback_count)

      self.class.validate_relocations_against_sizes(sizes, @relocations, budget)
      nil
    end

    # Validate a merged callback relocation roster before a caller patches or
    # publishes its containing Data bytes. This catches cross-layout overlap,
    # not just collisions within one child Object result.
    def self.validate_relocations_against_sizes(
      sizes : Hash(String, UInt64),
      relocations : Array(ObjectSharedInlineCallbackRelocation),
      budget : BinaryCodecBudget,
    ) : Nil
      count = relocations.size.to_u64
      work = relocation_validation_work(count)
      name_bytes = 0_u64
      relocations.each do |relocation|
        name_bytes = checked_add(name_bytes, relocation.source_callback_byte_size.to_u64, budget)
        name_bytes = checked_add(name_bytes, relocation.target_callback_byte_size.to_u64, budget)
      end
      budget.ensure_future_elements(work)
      budget.ensure_wire_bytes(name_bytes)
      budget.charge_elements(work) if work > 0_u64
      budget.charge_wire_bytes(name_bytes) if name_bytes > 0_u64

      # Keep one flat range roster so sorting and adjacent overlap checks have
      # a single bounded O(n log n) schedule, independent of callback grouping.
      source_fields = Array(Tuple(String, UInt64, UInt64)).new(relocations.size)
      relocations.each do |relocation|
        source = sizes[relocation.source_callback]? ||
                 raise(UnsupportedFormatError.new("inline relocation source callback is absent"))
        target = sizes[relocation.target_callback]? ||
                 raise(UnsupportedFormatError.new("inline relocation target callback is absent"))
        source_end = checked_add(relocation.source_offset, ObjectSharedInlineCallbackRelocation::COORDINATE_BYTES, budget)
        unless source_end <= source
          raise UnsupportedFormatError.new("inline relocation source field exceeds its callback")
        end
        unless relocation.target_offset <= target
          raise UnsupportedFormatError.new("inline relocation target exceeds its callback")
        end
        source_fields << {relocation.source_callback, relocation.source_offset, source_end}
      end
      source_fields.sort! do |left, right|
        name_order = left[0] <=> right[0]
        name_order == 0 ? left[1] <=> right[1] : name_order
      end
      source_fields.each_cons(2) do |pair|
        if pair[0][0] == pair[1][0] && pair[1][1] < pair[0][2]
          raise UnsupportedFormatError.new("inline relocation source fields overlap")
        end
      end
      nil
    end

    private def self.relocation_validation_work(count : UInt64) : UInt64
      return 0_u64 if count == 0_u64
      if count > UInt64::MAX // 3_u64
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      levels = 0_u64
      remaining = count - 1_u64
      while remaining > 0_u64
        levels += 1_u64
        remaining >>= 1
      end
      if levels > 0_u64 && count > UInt64::MAX // levels
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      sort_work = count * levels
      base_work = count * 3_u64
      if sort_work > UInt64::MAX - base_work
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      base_work + sort_work
    end

    private def self.checked_add(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("inline raw-layout work overflows UInt64")
      end
      value = left + right
      budget.ensure_wire_bytes(value)
      value
    end

    private def checked_add(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("inline raw-layout work overflows UInt64")
      end
      value = left + right
      budget.ensure_wire_bytes(value)
      value
    end
  end
end
