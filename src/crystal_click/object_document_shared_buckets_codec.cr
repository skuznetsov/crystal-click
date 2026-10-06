module CrystalClick
  # Composition of the existing shared-MAP row codec across Object's
  # MAP_WITH_BUCKETS lanes. Values retain the same borrowed scalar envelopes;
  # only path placement and the outer per-bucket row owners are new.
  module ObjectDocumentSharedBucketsCodec
    alias Entry = ObjectDocumentSharedCodec::Entry

    def self.encode_with_budget(
      granules : Array(Array(Array(Entry))),
      bucket_count : Int32,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : Array(BinaryBulkStreams)
      unless budget.writing?
        raise ArgumentError.new("Object shared buckets encode requires a writing budget")
      end
      validate_bucket_count!(bucket_count)

      total_rows = 0_u64
      total_entries = 0_u64
      granules.each do |mark_rows|
        total_rows = checked_add(total_rows, mark_rows.size.to_u64, true)
        mark_rows.each do |entries|
          total_entries = checked_add(total_entries, entries.size.to_u64, true)
        end
      end
      bucket_rows = checked_multiply(total_rows, bucket_count.to_u64, true)
      minimum_array_wire_bytes = checked_multiply(bucket_rows, 8_u64, true)
      bucket_marks = checked_multiply(granules.size.to_u64, bucket_count.to_u64, true)
      # The outer partition matrix and the eventual lane roster are separate
      # Array owners; each bucket then owns one mark-row array and one entry
      # array per parent row.
      two_roots = 2_u64
      bucket_containers = bucket_count.to_u64
      container_nodes = checked_add(two_roots, checked_add(bucket_containers, checked_add(bucket_marks, bucket_rows, true), true), true)
      container_edges = checked_add(
        checked_multiply(bucket_containers, 2_u64, true),
        checked_add(bucket_marks, bucket_rows, true),
        true
      )
      entry_edges = total_entries
      # SharedCodec's existing lower bound covers one serialized Array per
      # bucketed Object row and the three nodes per shared entry. Include it
      # with our newly owned matrix nodes before any bucket arrays are made;
      # two independent preflights would not prove their sum fits.
      codec_nodes = checked_add(bucket_rows, checked_multiply(total_entries, 3_u64, true), true)
      combined_nodes = checked_add(container_nodes, codec_nodes, true)

      # Admit the complete bucket/mark/row fanout before allocating any
      # bucket-owned array. Individual shared codecs then charge their exact
      # row, entry, and envelope work on this same budget.
      budget.ensure_future_nodes(combined_nodes)
      budget.charge_elements(checked_add(container_edges, entry_edges, true))
      budget.ensure_wire_bytes(minimum_array_wire_bytes)
      container_nodes.times { budget.charge_node }

      partitioned = Array(Array(Array(Array(Entry)))).new(bucket_count)
      bucket_count.times do
        partitioned << Array(Array(Array(Entry))).new(granules.size)
      end
      bucket_count.times do |bucket_index|
        granules.each do |mark_rows|
          partitioned[bucket_index] << Array(Array(Entry)).new(mark_rows.size)
        end
      end
      granules.each_with_index do |mark_rows, mark_index|
        bucket_count.times do |bucket_index|
          mark_rows.size.times do
            partitioned[bucket_index][mark_index] << Array(Entry).new
          end
        end
        mark_rows.each_with_index do |entries, row_index|
          entries.each do |entry|
            bucket_index = ObjectSharedBucketLayout.bucket_for(entry[0], bucket_count)
            partitioned[bucket_index][mark_index][row_index] << entry
          end
        end
      end

      output = Array(BinaryBulkStreams).new(bucket_count)
      bucket_count.times do |bucket_index|
        output << ObjectDocumentSharedCodec.encode_with_budget(partitioned[bucket_index], budget, profile)
      end
      output
    end

    def self.decode_with_budget(
      streams : ObjectDocumentStreams,
      rows_per_mark : Array(UInt64),
      object : ObjectStructure,
      typed_schema : Hash(String, BinaryDataType),
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
    ) : Array(Array(Array(Entry)))
      if budget.writing?
        raise ArgumentError.new("Object shared buckets decode requires a reading budget")
      end
      ObjectSharedBucketLayout.validate!(object)
      expected_bucket_count = ObjectSharedBucketLayout.bucket_count(object)
      unless object.shared_data_version == 1_u64
        raise ArgumentError.new("bucket codec requires Object MAP_WITH_BUCKETS metadata")
      end
      unless streams.shared_bucket_count == expected_bucket_count
        raise CorruptPartError.new("Object shared bucket lane count does not match its metadata")
      end

      selected_count = mark_count || (rows_per_mark.size - first_mark)
      unless 0 <= first_mark <= rows_per_mark.size && 0 <= selected_count <= rows_per_mark.size - first_mark
        raise CorruptPartError.new("Object shared selected range is outside the row grid")
      end
      selected_rows = 0_u64
      selected_count.times do |mark_index|
        rows = rows_per_mark[first_mark + mark_index]
        if rows > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared row count exceeds the supported in-memory domain")
        end
        selected_rows = checked_add(selected_rows, rows, false)
      end
      fanout_rows = checked_multiply(selected_rows, expected_bucket_count.to_u64, false)
      fanout_marks = checked_multiply(selected_count.to_u64, expected_bucket_count.to_u64, false)
      result_nodes = checked_add(selected_count.to_u64, selected_rows, false)
      bucket_containers = expected_bucket_count.to_u64
      required_nodes = checked_add(
        result_nodes,
        checked_add(bucket_containers, checked_add(fanout_marks, fanout_rows, false), false),
        false
      )
      required_elements = checked_add(
        result_nodes,
        checked_add(bucket_containers, checked_add(fanout_marks, fanout_rows, false), false),
        false
      )
      budget.ensure_future_nodes(required_nodes)
      budget.ensure_future_elements(required_elements)
      budget.preflight_children(result_nodes) if result_nodes > 0_u64
      result_nodes.times { budget.charge_node }
      # The selected result owns one mark and row vector plus one row entry
      # array per logical row. Bucket-local bodies remain selected-only.
      result = Array(Array(Array(Entry))).new(selected_count)
      selected_count.times do
        mark_rows = Array(Array(Entry)).new
        rows_per_mark[first_mark + result.size].to_i.times do
          mark_rows << Array(Entry).new
        end
        result << mark_rows
      end

      expected = rows_per_mark
      expected_bucket_count.times do |bucket_index|
        bucket_rows = ObjectDocumentSharedCodec.decode_with_budget(
          streams.shared_bucket(bucket_index),
          expected,
          object,
          typed_schema,
          budget,
          first_mark,
          selected_count,
          profile
        )
        unless bucket_rows.size == selected_count
          raise CorruptPartError.new("Object shared bucket selected mark count changed during decode")
        end
        selected_count.times do |mark_index|
          unless bucket_rows[mark_index].size == result[mark_index].size
            raise CorruptPartError.new("Object shared bucket row grid disagrees with the Object occurrence grid")
          end
          bucket_rows[mark_index].each_with_index do |entries, row_index|
            entries.each do |entry|
              unless ObjectSharedBucketLayout.bucket_for(entry[0], expected_bucket_count) == bucket_index
                raise CorruptPartError.new("shared Object path is stored in the wrong bucket")
              end
              budget.charge_node
              budget.charge_elements(1_u64)
              result[mark_index][row_index] << entry
            end
          end
        end
      end

      result.each do |mark_rows|
        mark_rows.each do |entries|
          entries.sort! { |left, right| compare_paths(left[0], right[0]) }
          previous : String? = nil
          entries.each do |entry|
            if prior = previous
              if compare_paths(prior, entry[0]) >= 0
                raise CorruptPartError.new("shared Object paths are duplicate across buckets")
              end
            end
            previous = entry[0]
          end
        end
      end
      result
    end

    private def self.validate_bucket_count!(bucket_count : Int32) : Nil
      unless 1 <= bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i
        raise UnsupportedFormatError.new("Object shared bucket count must be between 1 and 256")
      end
      nil
    end

    private def self.compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def self.checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right > UInt64::MAX - left
        if writing
          raise UnsupportedFormatError.new("Object shared bucket count overflows UInt64")
        else
          raise CorruptPartError.new("Object shared bucket count overflows UInt64")
        end
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        if writing
          raise UnsupportedFormatError.new("Object shared bucket count overflows UInt64")
        else
          raise CorruptPartError.new("Object shared bucket count overflows UInt64")
        end
      end
      left * right
    end
  end
end
