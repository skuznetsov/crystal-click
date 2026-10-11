module CrystalClick
  # EOF-first stream and prefix state for one static Compact JSON root. This
  # owner deliberately retains no decoded ObjectDocument values: callers may
  # inspect complete native prefix bytes/statistics metadata after preparation,
  # then decode only a requested mark window.
  #
  # The top-level streams array is copied, but its ObjectDocumentStreams
  # elements are retained by reference. A direct constructor caller must not
  # mutate supplied streams after handoff; this API never returns those streams.
  class CompactStaticJsonPreparedContext
    @streams : Array(ObjectDocumentStreams)
    @mark_rows : Array(UInt64)
    @typed_schema : Hash(String, BinaryDataType)
    @object_prefixes : Array(Bytes)
    @object_statistics_offsets : Array(Int32)
    @dynamic_prefixes : Array(Hash(String, Bytes))
    @dynamic_statistics_offsets : Array(Hash(String, Int32))
    @typed_descriptor_root_depth : Int32
    @inferred_actual_root_depth : Int32

    def initialize(
      streams : Array(ObjectDocumentStreams),
      mark_rows : Array(UInt64),
      typed_schema : Hash(String, BinaryDataType),
      object_prefixes : Array(Bytes),
      object_statistics_offsets : Array(Int32),
      dynamic_prefixes : Array(Hash(String, Bytes)),
      dynamic_statistics_offsets : Array(Hash(String, Int32)),
      @typed_descriptor_root_depth : Int32,
      @inferred_actual_root_depth : Int32,
    )
      count = streams.size
      unless mark_rows.size == count &&
             object_prefixes.size == count &&
             object_statistics_offsets.size == count &&
             dynamic_prefixes.size == count &&
             dynamic_statistics_offsets.size == count
        raise ArgumentError.new("Compact static JSON prepared metadata differs from its mark grid")
      end

      @streams = streams.dup
      @mark_rows = mark_rows.dup
      @typed_schema = Hash(String, BinaryDataType).new(initial_capacity: typed_schema.size)
      typed_schema.each do |path, type|
        @typed_schema[String.new(path.to_slice)] = type
      end
      @object_prefixes = object_prefixes.map { |value| duplicate_bytes(value) }
      @object_statistics_offsets = object_statistics_offsets.dup
      @dynamic_prefixes = dynamic_prefixes.map do |entries|
        detached = Hash(String, Bytes).new(initial_capacity: entries.size)
        entries.each do |name, bytes|
          detached[String.new(name.to_slice)] = duplicate_bytes(bytes)
        end
        detached
      end
      @dynamic_statistics_offsets = dynamic_statistics_offsets.map do |entries|
        detached = Hash(String, Int32).new(initial_capacity: entries.size)
        entries.each do |name, offset|
          detached[String.new(name.to_slice)] = offset
        end
        detached
      end
    end

    def mark_count : Int32
      @streams.size
    end

    def mark_row_count_at(index : Int) : UInt64
      @mark_rows[index]
    end

    def typed_descriptor_root_depth : Int32
      @typed_descriptor_root_depth
    end

    def inferred_actual_root_depth : Int32
      @inferred_actual_root_depth
    end

    # Decode one mark with the caller's operation budget and return only newly
    # materialized documents. Retained streams remain private because their
    # borrowed views are mutable even though their storage is intended to be
    # read-only after preparation.
    def decode_mark_with_budget(
      index : Int,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : Array(ObjectDocument)
      unless index >= 0 && index < @streams.size
        raise ArgumentError.new("Compact static JSON mark index is outside the prepared grid")
      end

      typed_schema = typed_schema_for(budget)
      decoded = ObjectDocumentCodec.decode_with_budget(
        typed_schema,
        @streams[index],
        budget,
        first_mark: 0,
        mark_count: 1,
        profile: profile,
        shared_profile: BinaryBulkProfile.single_stream,
        typed_descriptor_root_depth: @typed_descriptor_root_depth,
        inferred_actual_root_depth: @inferred_actual_root_depth,
      )
      expected_rows = @mark_rows[index]
      unless decoded.size == 1 && decoded[0].size.to_u64 == expected_rows
        raise CorruptPartError.new("Compact static JSON decoder returned the wrong mark row count")
      end
      decoded[0]
    end

    def typed_schema_for(budget : BinaryCodecBudget) : Hash(String, BinaryDataType)
      count = @typed_schema.size.to_u64
      byte_count = 0_u64
      @typed_schema.each_key do |path|
        byte_count = checked_add(byte_count, path.bytesize.to_u64)
      end
      if count > 0_u64
        budget.preflight_children(count)
        budget.charge_wire_bytes(byte_count)
        count.times { budget.charge_node }
      end
      result = Hash(String, BinaryDataType).new(initial_capacity: count.to_i)
      @typed_schema.each do |path, type|
        result[String.new(path.to_slice)] = type
      end
      result
    end

    # Exact Object V1/V2/V3 callback bytes and the parser-observed boundary
    # before the statistics payload. V3 false-statistics prefixes retain their
    # one-byte flag in the returned callback bytes.
    def object_prefix_bytes_at(index : Int) : Bytes
      duplicate_bytes(@object_prefixes[index])
    end

    def object_statistics_offset_at(index : Int) : Int32
      @object_statistics_offsets[index]
    end

    # Callback names are the actual canonical structure names, for example
    # "root.note.dynamic_structure". These bytes/offsets are parser-observed,
    # never reconstructed from decoded Dynamic values or callback lengths.
    def dynamic_prefix_bytes_at(index : Int, callback_name : String) : Bytes
      bytes = @dynamic_prefixes[index][callback_name]? ||
              raise(KeyError.new("Compact static JSON Dynamic prefix not found: #{callback_name.inspect}"))
      duplicate_bytes(bytes)
    end

    def dynamic_statistics_offset_at(index : Int, callback_name : String) : Int32
      @dynamic_statistics_offsets[index][callback_name]? ||
        raise(KeyError.new("Compact static JSON Dynamic statistics offset not found: #{callback_name.inspect}"))
    end

    # Logical retained-owner census for streams, exact prefixes and offsets.
    # It excludes decoded values and allocator capacity/RSS.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactStaticJsonPreparedContext).to_u64
      bytes = checked_add(bytes, checked_multiply(@streams.size.to_u64, sizeof(Pointer(ObjectDocumentStreams)).to_u64))
      @streams.each { |streams| bytes = checked_add(bytes, stream_workspace_bytes(streams)) }
      bytes = checked_add(bytes, checked_multiply(@mark_rows.size.to_u64, sizeof(UInt64).to_u64))
      bytes = checked_add(bytes, checked_multiply(@object_statistics_offsets.size.to_u64, sizeof(Int32).to_u64))
      # Bytes is Slice(UInt8): Array(Bytes) stores each slice descriptor inline,
      # and each retained callback owns one logical byte buffer.
      bytes = checked_add(bytes, checked_multiply(@object_prefixes.size.to_u64, sizeof(Bytes).to_u64))
      @object_prefixes.each { |value| bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, value.size.to_u64)) }

      bytes = checked_add(bytes, instance_sizeof(Hash(String, BinaryDataType)).to_u64)
      @typed_schema.each do |path, _type|
        bytes = checked_add(bytes, string_owner_bytes(path))
        bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      end
      bytes = checked_add(bytes, checked_multiply(@dynamic_prefixes.size.to_u64, sizeof(Pointer(Hash(String, Bytes))).to_u64))
      @dynamic_prefixes.each do |entries|
        bytes = checked_add(bytes, instance_sizeof(Hash(String, Bytes)).to_u64)
        entries.each do |name, value|
          bytes = checked_add(bytes, string_owner_bytes(name))
          bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, value.size.to_u64))
        end
      end
      bytes = checked_add(bytes, checked_multiply(@dynamic_statistics_offsets.size.to_u64, sizeof(Pointer(Hash(String, Int32))).to_u64))
      @dynamic_statistics_offsets.each do |entries|
        bytes = checked_add(bytes, instance_sizeof(Hash(String, Int32)).to_u64)
        entries.each do |name, _offset|
          bytes = checked_add(bytes, string_owner_bytes(name))
          bytes = checked_add(bytes, sizeof(Int32).to_u64)
        end
      end
      bytes
    end

    private def stream_workspace_bytes(streams : ObjectDocumentStreams) : UInt64
      bytes = instance_sizeof(ObjectDocumentStreams).to_u64
      bytes = checked_add(bytes, sizeof(UInt64).to_u64) # one-mark row count
      structures = streams.structures
      bytes = checked_add(bytes, instance_sizeof(ObjectDynamicStructureStreams).to_u64)
      bytes = checked_add(bytes, structures.total_input_byte_size)
      bytes = checked_add(bytes, checked_multiply(structures.dynamic_count.to_u64,
        instance_sizeof(String).to_u64 + sizeof(Bytes).to_u64 + sizeof(Int32).to_u64))

      streams.typed_path_count.times do |index|
        path = streams.typed_path_at(index)
        bytes = checked_add(bytes, string_owner_bytes(path))
        bytes = checked_add(bytes, bulk_streams_workspace_bytes(streams.typed_for(path)))
      end
      streams.typed_dynamic_path_count.times do |index|
        path = streams.typed_dynamic_path_at(index)
        bytes = checked_add(bytes, string_owner_bytes(path))
        typed_dynamic = streams.typed_dynamic_for(path)
        bytes = checked_add(bytes, instance_sizeof(BinaryDynamicBulkStreams).to_u64)
        bytes = checked_add(bytes, typed_dynamic.structures.total_input_byte_size)
        bytes = checked_add(bytes, bulk_streams_workspace_bytes(typed_dynamic.data))
      end
      streams.dynamic_path_count.times do |index|
        path = streams.dynamic_path_at(index)
        bytes = checked_add(bytes, string_owner_bytes(path))
        dynamic = streams.dynamic_for(path)
        bytes = checked_add(bytes, instance_sizeof(DynamicValueStreams).to_u64)
        bytes = checked_add(bytes, dynamic.discriminators.byte_size.to_u64)
        bytes = checked_add(bytes, checked_multiply(dynamic.discriminators.mark_count.to_u64 + 1_u64, sizeof(DynamicDiscriminatorMark).to_u64))
        dynamic.arm_names.each do |name|
          bytes = checked_add(bytes, string_owner_bytes(name))
          bytes = checked_add(bytes, bulk_streams_workspace_bytes(dynamic.arm(name)))
        end
      end
      bytes = checked_add(bytes, checked_multiply(streams.shared_bucket_count.to_u64, instance_sizeof(BinaryBulkStreams).to_u64))
      streams.shared_bucket_count.times do |index|
        bytes = checked_add(bytes, bulk_streams_workspace_bytes(streams.shared_bucket(index)))
      end
      bytes = checked_add(bytes, checked_multiply(streams.advanced_shared_mark_count.to_u64,
        sizeof(Pointer(Array(ObjectSharedMapRow))).to_u64))
      bytes
    end

    private def bulk_streams_workspace_bytes(streams : BinaryBulkStreams) : UInt64
      bytes = instance_sizeof(BinaryBulkStreams).to_u64
      bytes = checked_add(bytes, checked_multiply(streams.role_count.to_u64,
        sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryBulkStream)).to_u64))
      bytes = checked_add(bytes, streams.total_input_byte_size)
      streams.roles.each do |role|
        bytes = checked_add(bytes, string_owner_bytes(role))
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStream).to_u64)
        bytes = checked_add(bytes, checked_multiply(streams.stream(role).offset_count.to_u64, sizeof(UInt64).to_u64))
      end
      bytes
    end

    private def duplicate_bytes(source : Bytes) : Bytes
      Bytes.new(source.size) { |index| source[index] }
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact static JSON workspace estimate overflows")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact static JSON workspace estimate overflows")
      end
      left * right
    end
  end
end
