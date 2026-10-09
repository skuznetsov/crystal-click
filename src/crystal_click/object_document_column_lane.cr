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
    @dynamic_discriminator_role : String?
    @discriminator_mode : UInt64?

    def initialize(
      @name : String,
      @bytes : Bytes,
      @statistics_offset : Int32? = nil,
      @bulk_source : BinaryBulkStream? = nil,
      @discriminator_source : DynamicDiscriminatorStream? = nil,
      @prefix_size : Int32 = 0,
      @variant_prefix_role : String? = nil,
      @dynamic_discriminator_role : String? = nil,
      @discriminator_mode : UInt64? = nil,
    )
      if role = @dynamic_discriminator_role
        source = @bulk_source || raise(ArgumentError.new("typed Dynamic physical framing requires a binary bulk source"))
        mode = @discriminator_mode || raise(ArgumentError.new("typed Dynamic physical framing requires an explicit mode"))
        unless role.ends_with?(".discriminators") && @prefix_size == BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
          raise ArgumentError.new("typed Dynamic physical framing role is not bound to its discriminator prefix")
        end
        if @variant_prefix_role
          raise ArgumentError.new("typed Dynamic framing cannot also use the legacy Variant prefix adapter")
        end
        unless source.byte_size == @bytes.size
          raise UnsupportedFormatError.new("typed Dynamic discriminator lane differs from its normalized bulk source")
        end
        @byte_size = BinaryBulkDiscriminatorFramingAdapter.physical_size(source, mode)
      elsif role = @variant_prefix_role
        if @discriminator_mode
          raise ArgumentError.new("legacy Variant prefix lane cannot carry a typed Dynamic mode")
        end
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
                                           if role = @dynamic_discriminator_role
                                             mode = @discriminator_mode || raise(ArgumentError.new("typed Dynamic physical mode is missing"))
                                             BinaryBulkDiscriminatorFramingAdapter.write_lane(role, source, mode)
                                           elsif role = @variant_prefix_role
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
      # Discriminator adapters can allocate transformed byte lanes, so
      # reserve every compressed output axis before copying counts, offsets,
      # or adapted bytes. The physical writer requires at least one real mark;
      # the in-memory child codecs remain useful for an empty logical site grid.
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
                              if role = @dynamic_discriminator_role
                                mode = @discriminator_mode || raise(ArgumentError.new("typed Dynamic physical mode is missing"))
                                adapted_bytes, adapted_offsets, _ = BinaryBulkDiscriminatorFramingAdapter.write_lane(
                                  role,
                                  source,
                                  mode
                                )
                                {adapted_bytes, adapted_offsets}
                              elsif role = @variant_prefix_role
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

    # Exports this lane as detached, ordered inline callback fragments for a
    # nested Object tape. Unlike `encode_child_site`, this does not compress a
    # physical pair: it reuses the same framing adapters and returns the
    # decompressed prefix/body bytes under the names consumed by the paired
    # Object callback reader.
    def inline_fragments_for_child_site(
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(String, Bytes))
      unless budget.writing?
        raise ArgumentError.new("inline child lane export requires a write-direction budget")
      end

      if statistics_offset = @statistics_offset
        unless statistics_offset >= 0 && statistics_offset < @bytes.size
          raise UnsupportedFormatError.new("inline child metadata statistics offset is outside its bytes")
        end

        # Compact inline Object metadata uses StatisticsMode::NONE. The
        # callback is the parseable header only; the Wide statistics flag and
        # suffix are not part of the nested Object tape.
        metadata_size = statistics_offset.to_u64
        name_bytes = @name.bytesize.to_u64
        budget.ensure_future_nodes(1_u64)
        budget.ensure_future_elements(1_u64 + name_bytes)
        budget.ensure_wire_bytes(metadata_size)
        budget.charge_node
        budget.charge_elements(1_u64 + name_bytes)
        budget.charge_wire_bytes(metadata_size)
        return [{String.new(@name.to_slice), Bytes.new(statistics_offset) { |index| @bytes[index] }}]
      end

      mark_records = grid.mark_count.to_u64 + 1_u64

      lane_bytes, prefix_size = if statistics_offset = @statistics_offset
                                  raise UnsupportedFormatError.new("inline child metadata statistics offset was not handled")
                                elsif source = @bulk_source
                                  unless source.offset_count.to_u64 == mark_records
                                    raise UnsupportedFormatError.new("inline child bulk lane does not have the complete occurrence grid")
                                  end
                                  if role = @dynamic_discriminator_role
                                    mode = @discriminator_mode || raise(ArgumentError.new("typed Dynamic physical mode is missing"))
                                    validate_inline_discriminator_grid!(source, grid)
                                    BinaryBulkDiscriminatorFramingAdapter.preflight_write(
                                      [{role, source, mode}] of Tuple(String, BinaryBulkStream, UInt64),
                                      budget,
                                    )
                                    bytes, _offsets, prefix = BinaryBulkDiscriminatorFramingAdapter.write_lane(role, source, mode)
                                    {bytes, prefix}
                                  elsif role = @variant_prefix_role
                                    validate_inline_discriminator_grid!(source, grid)
                                    # SharedData serializes inline child Variant
                                    # discriminators with Compact mode 1 even
                                    # when the parent Wide lane uses BASIC.
                                    # Keep this adaptation local to the inline
                                    # callback boundary; encode/encode_child_site
                                    # retain their established BASIC behavior.
                                    compact_mode = DynamicDiscriminatorBodyValidator::COMPACT_MODE
                                    BinaryBulkDiscriminatorFramingAdapter.preflight_write(
                                      [{role, source, compact_mode}] of Tuple(String, BinaryBulkStream, UInt64),
                                      budget,
                                    )
                                    bytes, _offsets, prefix = BinaryBulkDiscriminatorFramingAdapter.write_lane(role, source, compact_mode)
                                    {bytes, prefix}
                                  elsif @name.ends_with?(".dict") && @prefix_size == BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
                                    unless source.byte_size == @bytes.size
                                      raise UnsupportedFormatError.new("inline child LowCardinality lane has an invalid physical prefix")
                                    end
                                    role = @name.byte_slice(0, @name.bytesize - ".dict".bytesize).not_nil! + ".dictionary"
                                    BinaryBulkPhysicalPrefixAdapter.preflight_write(
                                      [{role, source, @prefix_size}] of Tuple(String, BinaryBulkStream, Int32),
                                      budget,
                                    )
                                    bytes, _offsets, prefix = BinaryBulkPhysicalPrefixAdapter.write_lane(role, source, @prefix_size)
                                    {bytes, prefix}
                                  else
                                    unless @prefix_size == 0
                                      raise UnsupportedFormatError.new("inline child bulk lane has an unsupported physical prefix")
                                    end
                                    {@bytes, 0_i32}
                                  end
                                elsif source = @discriminator_source
                                  unless source.mark_count.to_u64 == mark_records && source.byte_size == @bytes.size
                                    raise UnsupportedFormatError.new("inline child Dynamic discriminator does not match its complete lane")
                                  end
                                  validate_child_discriminator!(source, grid)
                                  {@bytes, @prefix_size}
                                else
                                  raise UnsupportedFormatError.new("inline child Object lane has no mark-coordinate source")
                                end

      unless 0 <= prefix_size <= lane_bytes.size
        raise UnsupportedFormatError.new("inline child lane prefix is outside its bytes")
      end

      old_suffix, new_suffix = if prefix_size == 0
                                 {nil, nil}
                               elsif @name.ends_with?(".variant_discr")
                                 {".variant_discr", ".variant_discr_prefix"}
                               elsif @name.ends_with?(".dict")
                                 {".dict", ".dict_prefix"}
                               else
                                 raise UnsupportedFormatError.new("inline child lane has a prefix but no recognized callback role")
                               end

      fragment_count = new_suffix ? 2_u64 : 1_u64
      name_bytes = @name.bytesize.to_u64
      prefix_name_size = 0_u64
      if old_selected = old_suffix
        new_selected = new_suffix || raise(UnsupportedFormatError.new("inline child lane prefix callback suffix is missing"))
        prefix_name_size = (@name.bytesize - old_selected.bytesize + new_selected.bytesize).to_u64
        name_bytes += prefix_name_size
      end
      budget.ensure_future_nodes(fragment_count)
      budget.ensure_future_elements(fragment_count + name_bytes)
      # The exported buffers are detached from either borrowed lane bytes or
      # the adapter result. Reserve and charge the fragment records and their
      # complete aggregate before copying. Metadata has already taken the
      # no-statistics prefix path above.
      budget.ensure_wire_bytes(lane_bytes.size.to_u64)
      fragment_count.times { budget.charge_node }
      budget.charge_elements(fragment_count + name_bytes)
      budget.charge_wire_bytes(lane_bytes.size.to_u64)

      prefix_name = if old_selected = old_suffix
                      new_selected = new_suffix || raise(UnsupportedFormatError.new("inline child lane prefix callback suffix is missing"))
                      @name.byte_slice(0, @name.bytesize - old_selected.bytesize) + new_selected
                    else
                      nil
                    end
      fragments = Array(Tuple(String, Bytes)).new(fragment_count.to_i)
      if selected_prefix_name = prefix_name
        fragments << {
          String.new(selected_prefix_name.to_slice),
          Bytes.new(prefix_size) { |index| lane_bytes[index] },
        }
      end
      body_size = lane_bytes.size - prefix_size
      fragments << {
        String.new(@name.to_slice),
        Bytes.new(body_size) { |index| lane_bytes[prefix_size + index] },
      }
      fragments
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

    private def validate_inline_discriminator_grid!(
      source : BinaryBulkStream,
      grid : StorageOccurrenceGrid,
    ) : Nil
      unless source.offset_count == grid.mark_count + 1
        raise UnsupportedFormatError.new("inline child discriminator does not have the complete occurrence grid")
      end
      grid.mark_count.times do |index|
        first = source.offset_at(index)
        following = source.offset_at(index + 1)
        if following < first || following - first != grid.logical_occurrences_at(index)
          raise UnsupportedFormatError.new("inline child discriminator rows disagree with the logical occurrence grid")
        end
      end
      nil
    end
  end
end
