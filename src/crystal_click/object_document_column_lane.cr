module CrystalClick
  # Internal generated lane view for ObjectDocumentColumnWriter. Data bytes
  # are borrowed only from in-memory W123/W120 owners and are copied into the
  # returned compressed pair before this temporary object is discarded.
  class ObjectDocumentColumnLane
    getter name : String
    getter byte_size : Int32

    @bytes : Bytes
    @statistics_offset : Int32?
    @bulk_source : BinaryBulkStream?
    @discriminator_source : DynamicDiscriminatorStream?
    @prefix_size : Int32
    @variant_prefix_role : String?

    def initialize(
      @name : String,
      @bytes : Bytes,
      @statistics_offset : Int32? = nil,
      @bulk_source : BinaryBulkStream? = nil,
      @discriminator_source : DynamicDiscriminatorStream? = nil,
      @prefix_size : Int32 = 0,
      @variant_prefix_role : String? = nil,
    )
      if role = @variant_prefix_role
        source = @bulk_source || raise(ArgumentError.new("Variant physical prefix requires a binary bulk source"))
        unless role.ends_with?(".discriminators") && @prefix_size == BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
          raise ArgumentError.new("Variant physical prefix role is not bound to its discriminator prefix")
        end
        unless source.byte_size == @bytes.size && @bytes.size <= Int32::MAX - BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
          raise UnsupportedFormatError.new("Variant physical discriminator lane exceeds the supported byte domain")
        end
        @byte_size = @bytes.size + BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
      else
        @byte_size = @bytes.size
      end
    end

    def encode(
      rows_per_mark : Array(UInt64),
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : CompressedMarkFiles
      if statistics_offset = @statistics_offset
        return CompressedMarkWriter.encode_metadata(
          @bytes,
          statistics_offset,
          rows_per_mark,
          frame_bytes: frame_bytes,
          budget: budget
        )
      end

      mark_count = rows_per_mark.size + 1
      lane_bytes, offsets, prefix_size = if source = @bulk_source
                                           unless source.offset_count == mark_count
                                             raise UnsupportedFormatError.new("Object bulk lane does not have the complete outer mark grid")
                                           end
                                           if role = @variant_prefix_role
                                             BinaryBulkPhysicalPrefixAdapter.write_lane(role, source, @prefix_size)
                                           else
                                             {
                                               @bytes,
                                               Array(UInt64).new(source.offset_count) { |index| source.offset_at(index) },
                                               @prefix_size,
                                             }
                                           end
                                         elsif source = @discriminator_source
                                           unless source.mark_count == mark_count
                                             raise UnsupportedFormatError.new("Dynamic discriminator does not have the complete outer mark grid")
                                           end
                                           offsets = Array(UInt64).new(source.mark_count) do |index|
                                             mark = source.mark_at(index)
                                             if index < rows_per_mark.size && mark.rows != rows_per_mark[index]
                                               raise UnsupportedFormatError.new("Dynamic discriminator rows do not match the outer document grid")
                                             end
                                             if index == rows_per_mark.size && mark.rows != 0_u64
                                               raise UnsupportedFormatError.new("Dynamic discriminator terminal mark must have zero rows")
                                             end
                                             mark.offset
                                           end
                                           {@bytes, offsets, @prefix_size}
                                         else
                                           raise UnsupportedFormatError.new("Object column lane has no mark-coordinate source")
                                         end

      CompressedMarkWriter.encode(
        lane_bytes,
        offsets,
        rows_per_mark,
        prefix_size: prefix_size,
        frame_bytes: frame_bytes,
        budget: budget
      )
    end

    # Emits one physical lane for an explicit recursive child site. Bulk byte
    # offsets delimit logical child data, while adaptive row fields retain the
    # positive physical parent-row counts. Dynamic discriminator bodies are
    # checked against the logical child grid in their mode-specific format.
    def encode_child_site(
      grid : StorageOccurrenceGrid,
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : CompressedMarkFiles
      budget.ensure_direction(true)
      mark_count = grid.mark_count
      # The optional Variant prefix adapter can allocate a full transformed
      # byte lane, so reserve every compressed output axis before copying
      # counts, offsets, or adapted bytes. The physical writer requires at
      # least one real mark; the in-memory child codecs remain useful for an
      # empty logical site grid.
      CompressedMarkWriter.preflight_batch([@byte_size], mark_count + 1, frame_bytes, budget)

      rows_per_mark = Array(UInt64).new(mark_count)
      mark_count.times do |index|
        rows_per_mark << grid.physical_rows_at(index)
      end

      if statistics_offset = @statistics_offset
        return CompressedMarkWriter.encode_metadata(
          @bytes,
          statistics_offset,
          rows_per_mark,
          frame_bytes: frame_bytes,
          budget: budget
        )
      end

      mark_records = mark_count + 1
      lane_bytes, offsets = if source = @bulk_source
                              unless source.offset_count == mark_records
                                raise UnsupportedFormatError.new("child bulk lane does not have the complete occurrence grid")
                              end
                              if role = @variant_prefix_role
                                adapted_bytes, adapted_offsets = BinaryBulkPhysicalPrefixAdapter.write_lane(role, source, @prefix_size)
                                {adapted_bytes, adapted_offsets}
                              else
                                copied_offsets = Array(UInt64).new(source.offset_count) do |index|
                                  source.offset_at(index)
                                end
                                {@bytes, copied_offsets}
                              end
                            elsif source = @discriminator_source
                              unless source.mark_count == mark_records && source.byte_size == @bytes.size
                                raise UnsupportedFormatError.new("child Dynamic discriminator does not match its complete lane")
                              end
                              validate_child_discriminator!(source, grid)
                              copied_offsets = Array(UInt64).new(source.mark_count) do |index|
                                source.mark_at(index).offset
                              end
                              {@bytes, copied_offsets}
                            else
                              raise UnsupportedFormatError.new("child Object lane has no mark-coordinate source")
                            end

      CompressedMarkWriter.encode(
        lane_bytes,
        offsets,
        rows_per_mark,
        prefix_size: @prefix_size,
        frame_bytes: frame_bytes,
        budget: budget
      )
    end

    private def validate_child_discriminator!(
      source : DynamicDiscriminatorStream,
      grid : StorageOccurrenceGrid,
    ) : Nil
      mode = DynamicDiscriminatorBodyValidator.read_mode(source, writing: true)

      byte_size = source.byte_size.to_u64
      previous_end = DynamicDiscriminatorCodec::HEADER_BYTES
      grid.mark_count.times do |index|
        mark = source.mark_at(index)
        following = source.mark_at(index + 1)
        expected_rows = grid.logical_occurrences_at(index)
        unless mark.offset == previous_end && mark.rows == expected_rows
          raise UnsupportedFormatError.new("child Dynamic discriminator rows or offsets disagree with the occurrence grid")
        end
        if following.offset < mark.offset || following.offset > byte_size || mark.offset > byte_size
          raise UnsupportedFormatError.new("child Dynamic discriminator offsets are outside the lane")
        end
        body_size = following.offset - mark.offset
        body = source.borrowed_slice(mark.offset.to_i, body_size.to_i)
        DynamicDiscriminatorBodyValidator.inspect_body(mode, body, expected_rows, writing: true)
        previous_end = following.offset
      end

      terminal = source.mark_at(grid.mark_count)
      unless terminal.rows == 0_u64 && terminal.offset == byte_size && terminal.offset == previous_end
        raise UnsupportedFormatError.new("child Dynamic discriminator terminal mark is invalid")
      end
      if grid.mark_count == 0 && terminal.offset != DynamicDiscriminatorCodec::HEADER_BYTES
        raise UnsupportedFormatError.new("empty child Dynamic discriminator must contain only its mode header")
      end
      nil
    end
  end
end
