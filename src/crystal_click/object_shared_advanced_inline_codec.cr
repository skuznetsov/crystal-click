module CrystalClick
  # Materializes the existing advanced chunk, bucket and Copy owners into the
  # source-native Compact callback order without independently compressing a
  # nested role. Coordinates remain callback-local relocations for the outer
  # Data assembler.
  class ObjectSharedAdvancedInlineCodec
    alias Callback = Tuple(String, Bytes)

    def self.encode_body_callbacks(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      physical_rows : Array(UInt64),
      version : Int,
      bucket_count : Int32,
      target_chunk_rows : Int32,
      profile : BinaryBulkProfile,
      callback_root_prefix : String,
      codec_budget : BinaryCodecBudget,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
    ) : ObjectSharedAdvancedInlineRawLayout
      unless codec_budget.writing?
        raise ArgumentError.new("advanced inline callback materialization requires a write-direction budget")
      end
      unless version == 2 || version == 3
        raise UnsupportedFormatError.new("advanced inline callbacks support only SharedData v2/v3")
      end
      unless plan.structures.object.shared_data_version == version.to_u64 &&
             bucket_count == physical_plan.shared_bucket_count &&
             bucket_count == ObjectSharedBucketLayout.bucket_count(plan.structures.object)
        raise UnsupportedFormatError.new("advanced inline plan, version and bucket roster disagree")
      end
      unless target_chunk_rows > 0
        raise ArgumentError.new("advanced inline target chunk rows must be positive")
      end

      rows_by_parent = streams.advanced_shared_rows(codec_budget)
      unless rows_by_parent.size == physical_rows.size && !physical_rows.empty?
        raise UnsupportedFormatError.new("advanced inline shared rows do not match the physical parent grid")
      end
      chunks_by_parent = ObjectSharedAdvancedDocumentCodec.prepare_chunks_by_parent(
        rows_by_parent,
        physical_rows,
        version,
        bucket_count,
        codec_budget,
        profile: profile,
        shared_json_policy: shared_json_policy,
        shared_target_chunk_rows: target_chunk_rows,
      )
      bucket_parents = ObjectSharedAdvancedDocumentCodec.bucket_parents_for_chunks(
        chunks_by_parent,
        physical_rows,
        bucket_count,
        codec_budget,
      )
      copy_layout = ObjectSharedAdvancedCopyLayout.materialize_inline_raw(
        chunks_by_parent,
        physical_rows,
        codec_budget,
      )
      codec_budget.ensure_future_nodes(bucket_count.to_u64)
      raw_bucket_layouts = Array(ObjectSharedPhysicalBucketRawLayout).new(bucket_count)
      bucket_count.times do |bucket_index|
        raw_bucket_layouts << ObjectSharedPhysicalBucketEncoder.materialize_inline_raw(
          version,
          bucket_parents[bucket_index],
          codec_budget,
        )
      end

      bindings = ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
        physical_plan,
        plan,
        profile,
        codec_budget,
      )
      callback_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
        physical_plan,
        plan,
        profile,
        callback_root_prefix,
        codec_budget,
        true,
      )
      callback_names = Hash(String, String).new(initial_capacity: callback_pairs.size)
      callback_pairs.each do |pair|
        if callback_names.has_key?(pair[0])
          raise UnsupportedFormatError.new("advanced inline callback canonical name is duplicated")
        end
        callback_names[pair[0]] = pair[1]
      end

      body_callbacks = [] of Callback
      owner_name_count = checked_multiply(bucket_count.to_u64, ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size.to_u64)
      unless owner_name_count <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("advanced inline bucket owner roster exceeds Int32")
      end
      codec_budget.ensure_future_nodes(owner_name_count)
      codec_budget.ensure_future_elements(owner_name_count)
      owner_name_count.times { codec_budget.charge_node }
      codec_budget.charge_elements(owner_name_count) if owner_name_count > 0_u64
      callback_names_by_owner = Hash(Tuple(Symbol, String, String), String).new(
        initial_capacity: owner_name_count.to_i,
      )
      bindings.each do |binding|
        canonical_name, owner_kind, owner_path, role = binding
        next unless owner_kind == :advanced_bucket || owner_kind == :advanced_copy
        callback_name = callback_names[canonical_name]? ||
                        raise(UnsupportedFormatError.new("advanced inline callback has no canonical/raw name pair"))
        if owner_kind == :advanced_bucket
          owner_key = {owner_kind, owner_path, role}
          if callback_names_by_owner.has_key?(owner_key)
            raise UnsupportedFormatError.new("advanced inline bucket callback owner is duplicated")
          end
          callback_names_by_owner[owner_key] = callback_name
        end
        bytes = if owner_kind == :advanced_bucket
                  bucket_index = owner_path.to_i? ||
                                 raise(UnsupportedFormatError.new("advanced inline bucket owner is not numeric"))
                  raw_bucket_layout = raw_bucket_layouts[bucket_index]? ||
                                      raise(UnsupportedFormatError.new("advanced inline bucket parent is missing"))
                  ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.includes?(role) ||
                    raise(UnsupportedFormatError.new("advanced inline bucket role is not in the seven-role schedule"))
                  raw_bucket_layout.lane(role)
                else
                  {"sizes", "indexes", "values"}.includes?(role) ||
                    raise(UnsupportedFormatError.new("advanced inline Copy role is not in the three-role schedule"))
                  copy_layout.raw_lane(role)
                end
        body_callbacks << {callback_name, bytes}
      end

      unless callback_names_by_owner.size.to_u64 == owner_name_count
        raise UnsupportedFormatError.new("advanced inline bucket callback owner roster is incomplete")
      end
      relocation_count = 0_u64
      raw_bucket_layouts.each do |raw_bucket_layout|
        relocation_count = checked_add(relocation_count, raw_bucket_layout.relocation_count.to_u64)
      end
      unless relocation_count <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("advanced inline callback relocation roster exceeds Int32")
      end
      relocation_name_bytes = 0_u64
      bucket_count.times do |bucket_index|
        owner_prefix = bucket_index.to_s
        raw_bucket_layout = raw_bucket_layouts[bucket_index]
        raw_bucket_layout.relocation_count.times do |index|
          relocation = raw_bucket_layout.relocation_at(index)
          source_callback = callback_names_by_owner[{:advanced_bucket, owner_prefix, relocation.source_lane}]? ||
                            raise(UnsupportedFormatError.new("advanced inline relocation source has no callback name"))
          target_callback = callback_names_by_owner[{:advanced_bucket, owner_prefix, relocation.target_lane}]? ||
                            raise(UnsupportedFormatError.new("advanced inline relocation target has no callback name"))
          relocation_name_bytes = checked_add(relocation_name_bytes, source_callback.bytesize.to_u64)
          relocation_name_bytes = checked_add(relocation_name_bytes, target_callback.bytesize.to_u64)
        end
      end
      relocation_elements = checked_multiply(relocation_count, 3_u64)
      codec_budget.ensure_future_nodes(relocation_count)
      codec_budget.ensure_future_elements(relocation_elements)
      codec_budget.ensure_wire_bytes(relocation_name_bytes)
      relocation_count.times { codec_budget.charge_node }
      codec_budget.charge_elements(relocation_elements) if relocation_elements > 0_u64
      codec_budget.charge_wire_bytes(relocation_name_bytes) if relocation_name_bytes > 0_u64

      relocations = Array(ObjectSharedInlineCallbackRelocation).new(relocation_count.to_i)
      bucket_count.times do |bucket_index|
        owner_prefix = bucket_index.to_s
        raw_bucket_layout = raw_bucket_layouts[bucket_index]
        raw_bucket_layout.relocation_count.times do |index|
          relocation = raw_bucket_layout.relocation_at(index)
          source_callback = callback_names_by_owner[{:advanced_bucket, owner_prefix, relocation.source_lane}]? ||
                            raise(UnsupportedFormatError.new("advanced inline relocation source has no callback name"))
          target_callback = callback_names_by_owner[{:advanced_bucket, owner_prefix, relocation.target_lane}]? ||
                            raise(UnsupportedFormatError.new("advanced inline relocation target has no callback name"))
          relocations << ObjectSharedInlineCallbackRelocation.new(
            source_callback,
            relocation.source_offset,
            target_callback,
            relocation.target_offset,
          )
        end
      end
      unless relocations.size.to_u64 == relocation_count
        raise UnsupportedFormatError.new("advanced inline callback relocation roster changed after preflight")
      end

      ObjectSharedAdvancedInlineRawLayout.new(
        [] of Callback,
        body_callbacks,
        relocations,
        codec_budget,
      )
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("advanced inline callback relocation count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right > 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("advanced inline callback relocation work overflows UInt64")
      end
      left * right
    end
  end
end
