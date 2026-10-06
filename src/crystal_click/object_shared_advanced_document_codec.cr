module CrystalClick
  # Paired whole-part coordinator for Object ADVANCED v2 and CHUNKED v3.
  # Physical parent marks, logical child chunks, and row values remain distinct
  # coordinates; this owner only composes the existing Copy and bucket codecs.
  module ObjectSharedAdvancedDocumentCodec
    COPY_LANES = ["sizes", "indexes", "values"] of String

    def self.encode(
      rows_by_parent : Array(Array(ObjectSharedMapRow)),
      physical_rows : Array(UInt64),
      version : Int,
      bucket_count : Int32,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int = 4096,
      profile : BinaryBulkProfile = ObjectSharedPathCodec::COMPACT_PROFILE,
    ) : ObjectSharedAdvancedDocumentFiles
      unless codec_budget.writing?
        raise ArgumentError.new("Object shared advanced document encode requires a write-direction codec budget")
      end
      transport_budget.ensure_direction(true)
      validate_profile!(version, bucket_count)
      unless rows_by_parent.size == physical_rows.size && !rows_by_parent.empty?
        raise UnsupportedFormatError.new("Object shared advanced parent row grids do not match")
      end
      if rows_by_parent.size > Int32::MAX - 1
        raise UnsupportedFormatError.new("Object shared advanced parent mark count exceeds the supported domain")
      end

      chunk_counts = Array(Int32).new(rows_by_parent.size)
      total_chunks = 0_u64
      total_rows = 0_u64
      rows_by_parent.each_with_index do |rows, parent_index|
        physical = physical_rows[parent_index]
        if physical == 0_u64 || physical > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("Object shared advanced physical parent rows must be positive Int32 values")
        end
        if rows.size > Int32::MAX
          raise UnsupportedFormatError.new("Object shared advanced logical parent rows exceed Int32")
        end
        chunks = version == 2 ? 1 : Math.max(rows.size, 1)
        chunk_counts << chunks
        total_chunks = checked_add(total_chunks, chunks.to_u64)
        total_rows = checked_add(total_rows, rows.size.to_u64)
      end

      # Reserve all coordinator-owned parent/chunk/bucket containers before
      # constructing the first chunk. The child codecs account for their own
      # row, path, Copy, and transport work on these same borrowed budgets.
      bucket_parent_nodes = checked_multiply(rows_by_parent.size.to_u64, bucket_count.to_u64)
      layout_nodes = checked_add(
        bucket_count.to_u64,
        checked_add(total_chunks, bucket_parent_nodes)
      )
      layout_edges = checked_add(
        rows_by_parent.size.to_u64,
        checked_add(total_chunks, checked_multiply(total_chunks, bucket_count.to_u64))
      )
      codec_budget.ensure_future_nodes(layout_nodes)
      codec_budget.ensure_future_elements(layout_edges)
      codec_budget.charge_elements(layout_edges)
      layout_nodes.times { codec_budget.charge_node }

      chunks_by_parent = Array(Array(ObjectSharedAdvancedChunk)).new(rows_by_parent.size)
      rows_by_parent.each_with_index do |rows, parent_index|
        chunks = Array(ObjectSharedAdvancedChunk).new(chunk_counts[parent_index])
        if version == 2
          chunks << ObjectSharedAdvancedChunkCodec.encode(rows, bucket_count, codec_budget, profile: profile)
        elsif rows.empty?
          chunks << ObjectSharedAdvancedChunkCodec.encode([] of ObjectSharedMapRow, bucket_count, codec_budget, profile: profile)
        else
          rows.each do |row|
            one_row = Array(ObjectSharedMapRow).new(1)
            one_row << row
            chunks << ObjectSharedAdvancedChunkCodec.encode(one_row, bucket_count, codec_budget, profile: profile)
          end
        end
        chunks_by_parent << chunks
      end

      bucket_parents = Array(Array(ObjectSharedPhysicalParentMark)).new(bucket_count)
      bucket_count.times { bucket_parents << Array(ObjectSharedPhysicalParentMark).new(rows_by_parent.size) }
      rows_by_parent.size.times do |parent_index|
        parent_chunks = chunks_by_parent[parent_index]
        bucket_count.times do |bucket_index|
          physical_chunks = Array(ObjectSharedPhysicalChunk).new(parent_chunks.size)
          parent_chunks.each do |chunk|
            physical_chunks << chunk.bucket_at(bucket_index)
          end
          bucket_parents[bucket_index] << ObjectSharedPhysicalParentMark.new(
            physical_rows[parent_index],
            physical_chunks
          )
        end
      end

      copy_lanes = ObjectSharedAdvancedCopyLayout.encode(
        chunks_by_parent,
        physical_rows,
        codec_budget,
        transport_budget,
        frame_bytes
      )
      bucket_files = Array(ObjectSharedPhysicalBucketFiles).new(bucket_count)
      bucket_count.times do |bucket_index|
        bucket_files << ObjectSharedPhysicalBucketCodec.encode(
          version,
          bucket_parents[bucket_index],
          codec_budget,
          transport_budget,
          frame_bytes,
          profile: profile,
        )
      end
      ObjectSharedAdvancedDocumentFiles.new(copy_lanes, bucket_files)
    end

    def self.decode(
      copy_inputs : Hash(String, ObjectSharedPhysicalLaneInput),
      bucket_inputs : Array(ObjectSharedPhysicalBucketLaneInputs),
      physical_rows : Array(UInt64),
      logical_rows : Array(UInt64),
      version : Int,
      bucket_count : Int32,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = ObjectSharedPathCodec::COMPACT_PROFILE,
    ) : Array(Array(ObjectSharedMapRow))
      if codec_budget.writing?
        raise ArgumentError.new("Object shared advanced document decode requires a read-direction codec budget")
      end
      transport_budget.ensure_direction(false)
      validate_profile!(version, bucket_count)
      unless copy_inputs.size == COPY_LANES.size && COPY_LANES.all? { |name| copy_inputs.has_key?(name) }
        raise CorruptPartError.new("Object shared advanced Copy inputs must contain exactly sizes, indexes, and values")
      end
      unless bucket_inputs.size == bucket_count &&
             physical_rows.size == logical_rows.size &&
             !physical_rows.empty? &&
             physical_rows.size <= Int32::MAX - 1
        raise CorruptPartError.new("Object shared advanced parent and bucket input grids do not match")
      end
      physical_rows.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared advanced physical parent rows must be positive Int32 values")
        end
      end
      logical_rows.each do |rows|
        if rows > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared advanced logical parent rows exceed Int32")
        end
      end

      # Decode every bucket before applying any caller selection. This makes
      # the complete all-bucket chunk schedule authoritative even for zero- or
      # middle-window reads.
      bucket_parents = Array(Array(ObjectSharedPhysicalParentMark)).new(bucket_count)
      bucket_inputs.each do |inputs|
        bucket_parents << ObjectSharedPhysicalBucketCodec.decode(
          version,
          inputs,
          physical_rows,
          codec_budget,
          transport_budget,
          profile: profile,
        )
      end
      validate_bucket_schedules!(bucket_parents, physical_rows, logical_rows, codec_budget)

      copy_by_parent = ObjectSharedAdvancedCopyLayout.decode(
        copy_inputs,
        bucket_parents,
        physical_rows,
        codec_budget,
        transport_budget
      )
      unless copy_by_parent.size == physical_rows.size
        raise CorruptPartError.new("Object shared advanced Copy parent grid does not match the physical marks")
      end

      total_rows = 0_u64
      logical_rows.each { |rows| total_rows = checked_add(total_rows, rows) }
      coordinator_nodes = checked_add(physical_rows.size.to_u64, total_rows)
      codec_budget.ensure_future_nodes(coordinator_nodes)
      codec_budget.ensure_future_elements(total_rows)
      codec_budget.charge_elements(total_rows)
      coordinator_nodes.times { codec_budget.charge_node }

      output = Array(Array(ObjectSharedMapRow)).new(physical_rows.size)
      physical_rows.size.times do |parent_index|
        first_bucket_parent = bucket_parents[0][parent_index]
        parent_rows = Array(ObjectSharedMapRow).new(logical_rows[parent_index].to_i)
        first_bucket_parent.chunk_count.times do |chunk_index|
          chunks = Array(ObjectSharedPhysicalChunk).new(bucket_count)
          bucket_count.times do |bucket_index|
            chunks << bucket_parents[bucket_index][parent_index].chunk_at(chunk_index)
          end
          copy_parent = copy_by_parent[parent_index]? || raise(CorruptPartError.new("Object shared advanced Copy parent is missing"))
          copy = copy_parent[chunk_index]? || raise(CorruptPartError.new("Object shared advanced Copy chunk is missing"))
          decoded_rows = ObjectSharedAdvancedChunkCodec.decode(chunks, copy, codec_budget, profile: profile)
          decoded_rows.each { |row| parent_rows << row }
        end
        unless parent_rows.size.to_u64 == logical_rows[parent_index]
          raise CorruptPartError.new("Object shared advanced decoded rows disagree with the logical parent grid")
        end
        output << parent_rows
      end
      output
    end

    private def self.validate_bucket_schedules!(
      buckets : Array(Array(ObjectSharedPhysicalParentMark)),
      physical_rows : Array(UInt64),
      logical_rows : Array(UInt64),
      budget : BinaryCodecBudget,
    ) : Nil
      unless buckets.size > 0
        raise CorruptPartError.new("Object shared advanced part has no bucket ordinals")
      end
      buckets.each do |parents|
        unless parents.size == physical_rows.size
          raise CorruptPartError.new("Object shared advanced bucket parent grid does not match the physical marks")
        end
      end

      parent_count = physical_rows.size
      parent_count.times do |parent_index|
        reference = buckets[0][parent_index]
        unless reference.physical_rows == physical_rows[parent_index]
          raise CorruptPartError.new("Object shared advanced physical parent rows disagree with the outer grid")
        end
        chunk_count = reference.chunk_count
        if chunk_count <= 0
          raise CorruptPartError.new("Object shared advanced physical parent has no logical chunks")
        end
        budget.ensure_future_nodes((buckets.size - 1).to_u64)
        buckets.size.times do |bucket_index|
          parent = buckets[bucket_index][parent_index]
          unless parent.physical_rows == physical_rows[parent_index] && parent.chunk_count == chunk_count
            raise CorruptPartError.new("Object shared advanced bucket chunk schedules disagree")
          end
          chunk_count.times do |chunk_index|
            unless parent.chunk_at(chunk_index).row_count == reference.chunk_at(chunk_index).row_count
              raise CorruptPartError.new("Object shared advanced bucket chunk row schedules disagree")
            end
          end
        end

        logical_count = 0_u64
        chunk_count.times do |chunk_index|
          rows = reference.chunk_at(chunk_index).row_count
          if rows > UInt64::MAX - logical_count
            raise CorruptPartError.new("Object shared advanced logical chunk row sum overflows UInt64")
          end
          logical_count += rows
        end
        unless logical_count == logical_rows[parent_index]
          raise CorruptPartError.new("Object shared advanced chunk rows disagree with the logical parent grid")
        end
      end
      nil
    end

    private def self.validate_profile!(version : Int, bucket_count : Int32) : Nil
      unless version == 2 || version == 3
        raise UnsupportedFormatError.new("Object shared advanced document version must be ADVANCED v2 or CHUNKED v3")
      end
      unless 1 <= bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i
        raise UnsupportedFormatError.new("Object shared advanced bucket count must be between 1 and 256")
      end
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Object shared advanced count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left != 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Object shared advanced count overflows UInt64")
      end
      left * right
    end
  end
end
