module CrystalClick
  # Recursive Tuple composition over the existing Object and BinaryBulk
  # owners. This first storage profile admits a root Tuple and JSON leaves;
  # other wrappers around JSON remain outside the writer grammar.
  module RecursiveStorageColumnWriter
    def self.encode(
      plan : RecursiveStorageColumnPlan,
      granules : Array(Array(StorageColumnValue)),
    ) : RecursiveStorageColumnFiles
      validate_mark_grid!(granules)
      limits = plan.limits
      granules.each do |rows|
        rows.each do |value|
          StorageColumnDepthGuard.validate(value, limits, writing: true)
        end
      end
      codec_budget = BinaryCodecBudget.new(limits, true)
      validate_rows!(plan.schema, granules, codec_budget)

      objects = Hash(String, Array(Array(ObjectDocument))).new
      plan.object_site_count.times do |index|
        site = plan.object_site_at(index)
        objects[site.key] = Array(Array(ObjectDocument)).new(granules.size) { [] of ObjectDocument }
      end
      bulk = Hash(String, Array(Array(BinaryValue))).new
      plan.bulk_site_count.times do |index|
        site = plan.bulk_site_at(index)
        bulk[site.key] = Array(Array(BinaryValue)).new(granules.size) { [] of BinaryValue }
      end

      granules.each_with_index do |rows, mark_index|
        rows.each do |value|
          collect_row!(plan.schema, value, "root", mark_index, objects, bulk)
        end
      end

      transport_budget = CompressedStreamBudget.new(plan.transport_limits, true)
      pairs = Hash(String, CompressedMarkFiles).new

      plan.object_site_count.times do |index|
        site = plan.object_site_at(index)
        site_granules = objects[site.key]? || raise(UnsupportedFormatError.new("recursive Object site data is missing"))
        files = ObjectDocumentColumnWriter.encode_at_physical_site(
          site.prefix,
          site.object_plan,
          site.physical,
          site_granules,
          codec_budget,
          transport_budget,
          plan.profile,
          plan.shared_profile,
          plan.mode,
          plan.hashed?,
          plan.frame_bytes,
          0_u64
        )
        site_names = files.stream_names
        expected_names = site.physical.stream_names
        raise UnsupportedFormatError.new("encoded Object site roster changed after planning") unless site_names == expected_names
        site_names.each do |name|
          if pairs.has_key?(name)
            raise UnsupportedFormatError.new("recursive Object output lanes collide")
          end
          pairs[name] = files.pair_for(name)
        end
      end

      rows_per_mark = Array(UInt64).new(granules.size) { |index| granules[index].size.to_u64 }
      plan.bulk_site_count.times do |index|
        site = plan.bulk_site_at(index)
        site_granules = bulk[site.key]? || raise(UnsupportedFormatError.new("recursive BinaryBulk site data is missing"))
        streams = BinaryBulkCodec.encode_with_budget(site.type, site_granules, codec_budget, profile: plan.profile)
        physical_names = site.physical.stream_names
        roles = streams.roles
        unless physical_names.keys.sort == roles && streams.mark_count == granules.size
          raise UnsupportedFormatError.new("BinaryBulk output roles or marks differ from the admitted physical plan")
        end

        lanes = Array(ObjectDocumentColumnLane).new(roles.size)
        prefix_adapter_lanes = [] of Tuple(String, BinaryBulkStream, Int32)
        roles.each do |role|
          stream = streams.stream(role)
          prefix = site.physical.prefix_size_for(role)
          variant_prefix = BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
          # write_lane copies K+1 coordinates for every role, and additionally
          # builds a detached header-adjusted byte lane for Variant discriminators.
          # Reserve the adapter's complete operation-local work before any lane
          # encoding; only Variant discriminator lanes need the extra 8-byte header.
          prefix_adapter_lanes << {role, stream, prefix}
          lane = ObjectDocumentColumnLane.new(
            physical_names[role],
            stream.borrowed_slice(0, stream.byte_size),
            nil,
            stream,
            nil,
            prefix,
            variant_prefix ? role : nil
          )
          lanes << lane
        end
        raw_sizes = Array(Int32).new(lanes.size) { |lane_index| lanes[lane_index].byte_size }
        CompressedMarkWriter.preflight_batch(raw_sizes, granules.size + 1, plan.frame_bytes, transport_budget)
        # All lanes acquire a detached K+1 coordinate array in write_lane;
        # Variant discriminator lanes also acquire the BASIC eight-byte
        # physical header. The adapter charges both against the shared
        # operation budget before lane encoding allocates those buffers.
        BinaryBulkPhysicalPrefixAdapter.preflight_write(prefix_adapter_lanes, codec_budget) unless prefix_adapter_lanes.empty?
        lanes.each do |lane|
          if pairs.has_key?(lane.name)
            raise UnsupportedFormatError.new("recursive output lanes collide after encoding")
          end
          pairs[lane.name] = lane.encode(rows_per_mark, plan.frame_bytes, transport_budget)
        end
      end

      RecursiveStorageColumnFiles.new(plan, pairs)
    end

    private def self.validate_mark_grid!(granules : Array(Array(StorageColumnValue))) : Nil
      if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
        raise ArgumentError.new("recursive storage requires a bounded nonempty mark grid")
      end
      total_rows = 0_u64
      granules.each do |rows|
        if rows.empty? || rows.size > WidePartWriter::MAX_ROWS_PER_MARK
          raise ArgumentError.new("recursive storage mark row count is outside the admitted range")
        end
        count = rows.size.to_u64
        if count > WidePart::MAX_ROWS.to_u64 - total_rows
          raise ArgumentError.new("recursive storage row count exceeds the part limit")
        end
        total_rows += count
      end
      nil
    end

    private def self.validate_rows!(
      schema : StorageColumnSchema,
      granules : Array(Array(StorageColumnValue)),
      budget : BinaryCodecBudget,
    ) : Nil
      granules.each do |rows|
        rows.each do |value|
          validate_value!(schema, value, 1, budget)
        end
      end
      nil
    end

    private def self.validate_value!(
      schema : StorageColumnSchema,
      value : StorageColumnValue,
      depth : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.visit_node(depth)
      if schema.tuple?
        unless value.tuple? && value.child_count == schema.child_count
          raise ArgumentError.new("recursive Tuple value shape differs from its declaration")
        end
        child_count = schema.child_count.to_u64
        budget.preflight_children(child_count) if child_count > 0_u64
        schema.child_count.times do |index|
          validate_value!(schema.child_at(index), value.child_at(index), depth + 1, budget)
        end
      elsif schema.object?
        raise ArgumentError.new("recursive JSON site requires an Object document value") unless value.object?
      elsif schema.bulk?
        raise ArgumentError.new("recursive BinaryBulk site requires a bulk value") unless value.bulk?
        unless value.bulk_value.type == schema.bulk_type
          raise ArgumentError.new("recursive BinaryBulk value type differs from its declaration")
        end
        ObjectRecursiveDeclaration.account_descriptor(schema.bulk_type, budget, budget.limits, depth) ||
          raise(UnsupportedFormatError.new("recursive BinaryBulk descriptor exceeds its inherited depth budget"))
      else
        raise UnsupportedFormatError.new("recursive storage schema contains an unknown node")
      end
      nil
    end

    private def self.collect_row!(
      schema : StorageColumnSchema,
      value : StorageColumnValue,
      key : String,
      mark_index : Int32,
      objects : Hash(String, Array(Array(ObjectDocument))),
      bulk : Hash(String, Array(Array(BinaryValue))),
    ) : Nil
      if schema.object?
        marks = objects[key]? || raise(UnsupportedFormatError.new("recursive JSON site is absent from the physical plan"))
        marks[mark_index] << value.object_document
      elsif schema.bulk?
        marks = bulk[key]? || raise(UnsupportedFormatError.new("recursive BinaryBulk site is absent from the physical plan"))
        marks[mark_index] << value.bulk_value
      else
        schema.child_count.times do |index|
          child_key = String.build { |io| io << key << "/tuple[" << index << ']' }
          collect_row!(schema.child_at(index), value.child_at(index), child_key, mark_index, objects, bulk)
        end
      end
      nil
    end
  end
end
