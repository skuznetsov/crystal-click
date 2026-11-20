module CrystalClick
  # Exact content binding for the small metadata files that define a Compact
  # part's selected schema, mark grid, and serializer interpretation.
  private struct CompactStaticJsonPartFileFingerprint
    getter name : String
    getter present : Bool
    getter size : Int64
    getter hash : {UInt64, UInt64}

    def initialize(@name : String, @present : Bool, @size : Int64, @hash : {UInt64, UInt64})
    end
  end

  # Reusable source binding for one Advanced MRK4 root JSON scan. The binding
  # fingerprints metadata captured at reader admission and authenticated
  # compressed frames captured with the source spans used by this plan.
  class CompactStaticJsonAdvancedPartPlan
    @reader : CompactStaticJsonBulkColumnReader
    @part_path : String
    @data_path : String
    @data_size : Int64
    @transport_limits : CompressedStreamLimits
    @source_files : Array(CompactStaticJsonPartFileFingerprint)
    @frames : Array(CompressedFrameFingerprint)
    @frame_index : CompressedFrameIndex
    @advanced_marks : Array(CompactStaticJsonAdvancedPreparedMark)
    @prepared_mark_indices : Array(Int32)?
    @mark_rows : Array(UInt64)
    @uint64_mark_bytes : Hash(String, Array(Bytes))
    @companion_columns : Array(String)
    @columnar_paths : Array(String)?
    @columnar_fallback_types : Hash(String, BinaryDataType)?
    @columnar_workspace_bytes : UInt64
    @retained_workspace_bytes : UInt64
    @preparation_budget : BinaryCodecBudget

    private def initialize(
      @reader : CompactStaticJsonBulkColumnReader,
      part_path : String,
      data_path : String,
      @data_size : Int64,
      @transport_limits : CompressedStreamLimits,
      @frame_index : CompressedFrameIndex,
      source_files : Array(CompactStaticJsonPartFileFingerprint),
      frames : Array(CompressedFrameFingerprint),
      advanced_marks : Array(CompactStaticJsonAdvancedPreparedMark),
      prepared_mark_indices : Array(Int32)?,
      mark_rows : Array(UInt64),
      uint64_mark_bytes : Hash(String, Array(Bytes)),
      companion_columns : Array(String),
      @preparation_budget : BinaryCodecBudget,
    )
      @part_path = String.new(part_path.to_slice)
      @data_path = String.new(data_path.to_slice)
      @source_files = source_files.dup
      @frames = frames.dup
      @advanced_marks = advanced_marks.dup
      @prepared_mark_indices = prepared_mark_indices.try(&.dup)
      @mark_rows = mark_rows.dup
      @companion_columns = companion_columns.map { |name| String.new(name.to_slice) }
      @columnar_paths = nil
      @columnar_fallback_types = nil
      @columnar_workspace_bytes = 0_u64
      unless !@advanced_marks.empty? && !@frames.empty?
        raise CorruptPartError.new("Compact Advanced plan has no selected prepared marks")
      end
      if indices = @prepared_mark_indices
        unless @advanced_marks.size == indices.size
          raise CorruptPartError.new("Compact Advanced plan selected marks differ from retained owners")
        end
        previous_mark = -1_i32
        indices.each_with_index do |mark, ordinal|
          unless mark > previous_mark && mark < @mark_rows.size
            raise CorruptPartError.new("Compact Advanced plan selected marks are unordered or outside the full grid")
          end
          unless @advanced_marks[ordinal].logical_row_count == @mark_rows[mark]
            raise CorruptPartError.new("Compact Advanced prepared mark differs from its absolute row grid")
          end
          previous_mark = mark
        end
      else
        unless @advanced_marks.size == @mark_rows.size
          raise CorruptPartError.new("Compact Advanced dense plan differs from its full row grid")
        end
        @advanced_marks.each_with_index do |owner, mark|
          unless owner.logical_row_count == @mark_rows[mark]
            raise CorruptPartError.new("Compact Advanced prepared mark differs from its absolute row grid")
          end
        end
      end
      @uint64_mark_bytes = Hash(String, Array(Bytes)).new(initial_capacity: uint64_mark_bytes.size)
      uint64_mark_bytes.each do |name, marks|
        unless marks.size == @advanced_marks.size
          raise CorruptPartError.new("Compact Advanced companion differs from its prepared mark ordinals")
        end
        copied_marks = Array(Bytes).new(marks.size)
        marks.each_with_index do |bytes, ordinal|
          mark = prepared_mark_at_ordinal(ordinal)
          expected_size = checked_multiply(@mark_rows[mark], sizeof(UInt64).to_u64)
          unless bytes.size.to_u64 == expected_size
            raise CorruptPartError.new("Compact Advanced plan companion width differs from its row grid")
          end
          copied_marks << bytes.dup
        end
        @uint64_mark_bytes[String.new(name.to_slice)] = copied_marks
      end
      @companion_columns.each do |name|
        marks = @uint64_mark_bytes[name]?
        unless marks && marks.size == @advanced_marks.size
          raise CorruptPartError.new("Compact Advanced companion selection differs from its prepared marks")
        end
      end
      @retained_workspace_bytes = calculate_retained_workspace_bytes
    end

    def mark_count : Int32
      @mark_rows.size.to_i32
    end

    def companion_columns : Array(String)
      @companion_columns.map { |name| String.new(name.to_slice) }
    end

    def prepared_mark_count : Int32
      @advanced_marks.size.to_i32
    end

    # :nodoc:
    def prepared_mark_indices : Array(Int32)
      @prepared_mark_indices.try(&.dup) || Array(Int32).new(@mark_rows.size) { |mark| mark.to_i32 }
    end

    def mark_row_count_at(mark_index : Int) : UInt64
      unless mark_index >= 0 && mark_index < @mark_rows.size
        raise ArgumentError.new("Compact Advanced plan mark index is outside its full grid")
      end
      @mark_rows[mark_index]
    end

    # :nodoc:
    def new_decode_budget : BinaryCodecBudget
      BinaryCodecBudget.new(@reader.codec_limits)
    end

    # :nodoc:
    def prepare_decode_budget!(budget : BinaryCodecBudget) : Nil
      replay_preparation_budget!(budget)
    end

    # :nodoc:
    def prepare_columnar_output! : Nil
      return nil if @columnar_paths && @columnar_fallback_types

      paths = [] of String
      fallback_types = Hash(String, BinaryDataType).new
      seen_paths = Set(String).new
      shape_build_bytes = checked_add(
        instance_sizeof(Array(String)).to_u64,
        checked_add(instance_sizeof(Hash(String, BinaryDataType)).to_u64,
          sizeof(Set(String)).to_u64),
      )
      @advanced_marks.each do |mark|
        mark.each_columnar_path do |path|
          if seen_paths.add?(path)
            if paths.size.to_i64 >= @reader.codec_limits.max_nodes
              raise CorruptPartError.new("Compact JSON columnar path union exceeds the codec node bound")
            end
            path_cost = checked_add(string_owner_bytes(path),
              checked_add(sizeof(Pointer(String)).to_u64, (64 + sizeof(Pointer(String))).to_u64))
            shape_build_bytes = checked_add(shape_build_bytes, path_cost)
            enforce_columnar_shape_workspace!(shape_build_bytes)
            paths << String.new(path.to_slice)
          end
        end
        mark.each_columnar_fallback_type do |path, type|
          unless fallback_types.has_key?(path)
            type_path_cost = checked_add(string_owner_bytes(path), (64 + sizeof(Pointer(String))).to_u64)
            shape_build_bytes = checked_add(shape_build_bytes, type_path_cost)
            enforce_columnar_shape_workspace!(shape_build_bytes)
            fallback_types[String.new(path.to_slice)] = type
          end
        end
      end
      paths.sort! { |left, right| ObjectSharedChunkStructure.compare_paths(left, right) }
      if paths.size.to_i64 > @reader.codec_limits.max_nodes
        raise CorruptPartError.new("Compact JSON columnar path union exceeds the codec node bound")
      end
      @columnar_workspace_bytes = columnar_shape_workspace_bytes(paths, fallback_types)
      if checked_add(@retained_workspace_bytes, @columnar_workspace_bytes) > WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("Compact JSON columnar plan and path shape exceed the aggregate materialization limit")
      end
      @columnar_paths = paths
      @columnar_fallback_types = fallback_types
      nil
    end

    # :nodoc:
    def new_columnar_output(
      total_workspace_limit : UInt64 = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64,
    ) : CompactJsonColumnarBatch
      prepare_columnar_output!
      paths = @columnar_paths || raise(CorruptPartError.new("Compact JSON columnar shape was not prepared"))
      fallback_types = @columnar_fallback_types || raise(CorruptPartError.new("Compact JSON columnar types were not prepared"))
      retained_bytes = retained_workspace_bytes
      if retained_bytes >= total_workspace_limit
        raise CorruptPartError.new("Compact JSON columnar plan leaves no room for an output arena")
      end
      max_rows = if indices = @prepared_mark_indices
                   indices.reduce(0_i64) { |maximum, mark| Math.max(maximum, @mark_rows[mark].to_i64) }.to_i
                 else
                   @mark_rows.max?.try(&.to_i) || 0
                 end
      max_paths = Math.min(@reader.codec_limits.max_nodes, Int32::MAX.to_i64).to_i
      output = CompactJsonColumnarBatch.from_layout(
        paths,
        @companion_columns,
        fallback_types,
        max_rows,
        @reader.codec_limits.max_elements.to_u64,
        total_workspace_limit - retained_bytes,
        max_paths,
      )
      output.validate_layout!(paths, @companion_columns)
      output
    end

    # :nodoc:
    # Decode exactly one retained source mark into the caller-owned reusable
    # arena. The returned batch carries mark-relative coordinates until a
    # table facade supplies its part/source coordinates.
    def decode_mark_into(
      mark_index : Int,
      budget : BinaryCodecBudget,
      output : CompactJsonColumnarBatch,
    ) : Nil
      unless mark_index >= 0 && mark_index < @mark_rows.size
        raise ArgumentError.new("Compact Advanced plan mark index is outside its full grid")
      end
      unless budget.same?(@preparation_budget) || budget.includes_preparation_from?(@preparation_budget)
        raise ArgumentError.new("Compact Advanced columnar decode requires its preparation receipt")
      end
      unless @columnar_paths && @columnar_fallback_types
        raise CorruptPartError.new("Compact JSON columnar shape must be prepared before decoding")
      end
      ordinal = prepared_ordinal_for_mark(mark_index)
      unless ordinal
        raise ArgumentError.new("Compact Advanced plan mark index was not prepared")
      end
      rows = @mark_rows[mark_index]
      output.begin_mark!(0, File.basename(@part_path), @part_path, mark_index, 0_u64, 0_u64, 0_u64, rows)
      @advanced_marks[ordinal].decode_columnar_with_budget(budget, output)
      @companion_columns.each do |name|
        bytes = uint64_mark_bytes_at(name, ordinal)
        output.fill_uint64_column!(name, bytes, rows)
      end
      output.validate_workspace!
      nil
    end

    def binds_reader?(reader : CompactStaticJsonBulkColumnReader) : Bool
      @reader.same?(reader)
    end

    def validate_reader!(reader : CompactStaticJsonBulkColumnReader) : Nil
      unless binds_reader?(reader)
        raise CorruptPartError.new("Compact Advanced plan belongs to a different root reader")
      end
      nil
    end

    def uint64_mark_bytes(column_name : String, mark_index : Int) : Bytes
      marks = @uint64_mark_bytes[column_name]?
      unless marks && mark_index >= 0 && mark_index < @mark_rows.size
        raise ArgumentError.new("Compact Advanced plan has no selected UInt64 mark")
      end
      ordinal = prepared_ordinal_for_mark(mark_index)
      unless ordinal
        raise ArgumentError.new("Compact Advanced plan mark index was not prepared")
      end
      marks[ordinal]?.try(&.dup) ||
        raise(ArgumentError.new("Compact Advanced plan has no selected UInt64 mark"))
    end

    private def uint64_mark_bytes_at(column_name : String, ordinal : Int32) : Bytes
      marks = @uint64_mark_bytes[column_name]?
      unless marks
        raise ArgumentError.new("Compact Advanced plan has no selected UInt64 mark")
      end
      marks.not_nil![ordinal]? ||
        raise(ArgumentError.new("Compact Advanced plan has no selected UInt64 mark"))
    end

    # Applies the structural parse/preparation work performed once while the
    # immutable plan was built to each independent request budget. The budget
    # records this exact source budget only after atomically charging its live
    # counters, allowing prepared owners to verify receipt provenance.
    def replay_preparation_budget!(budget : BinaryCodecBudget) : Nil
      if budget.writing? || budget.limits != @reader.codec_limits
        raise ArgumentError.new("Compact Advanced plan request budget differs from its read limits")
      end
      budget.replay_preparation_from!(@preparation_budget)
      nil
    end

    # Decode a mark without exposing its prepared owner outside the sealed
    # plan. The destination operation must have paid this plan's exact source
    # preparation counters first.
    def decode_mark_with_budget(
      mark_index : Int,
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil)? = nil,
      assembly_workspace : ObjectDocumentDecodeWorkspace? = nil,
    ) : Array(ObjectDocument)
      unless mark_index >= 0 && mark_index < @mark_rows.size
        raise ArgumentError.new("Compact Advanced plan mark index is outside its full grid")
      end
      ordinal = prepared_ordinal_for_mark(mark_index)
      unless ordinal
        raise ArgumentError.new("Compact Advanced plan mark index was not prepared")
      end
      unless budget.same?(@preparation_budget) || budget.includes_preparation_from?(@preparation_budget)
        raise ArgumentError.new("Compact Advanced plan decode requires its preparation receipt")
      end
      owner = @advanced_marks[ordinal]
      unless owner.logical_row_count == @mark_rows[mark_index]
        raise CorruptPartError.new("Compact Advanced prepared mark differs from the sealed row grid")
      end
      owner.decode_with_budget(budget, workspace_observer, assembly_workspace)
    end

    # Freshly checks the current path before each ordered callback. Metadata is
    # compared by bounded file content fingerprints; data.bin checks only the
    # original authenticated frame set, including all JSON and selected
    # UInt64 granules. This is intentionally read-only and does not decompress
    # or charge the operation transport budget again.
    def validate_source! : Nil
      @source_files.each do |fingerprint|
        current = self.class.fingerprint_file(
          @part_path,
          fingerprint.name,
          self.class.maximum_file_bytes(fingerprint.name, @transport_limits),
          optional: !fingerprint.present,
        )
        unless current.present == fingerprint.present && current.size == fingerprint.size && current.hash == fingerprint.hash
          raise CorruptPartError.new("Compact Advanced plan source metadata changed after preparation")
        end
      end
      CompressedMarkReader.validate_frame_fingerprints!(
        @data_path,
        @data_size,
        @frames,
        @transport_limits,
        @frame_index,
      )
      nil
    end

    def retained_workspace_bytes : UInt64
      checked_add(@retained_workspace_bytes, @columnar_workspace_bytes)
    end

    private def prepared_mark_at_ordinal(ordinal : Int) : Int32
      indices = @prepared_mark_indices
      return ordinal.to_i32 unless indices
      indices.not_nil![ordinal]
    end

    # Dense plans keep the original absolute-index fast path. Sparse plans
    # retain only a sorted absolute-index vector and resolve marks by binary
    # search, avoiding a second full-grid lookup table.
    private def prepared_ordinal_for_mark(mark_index : Int) : Int32?
      return nil if mark_index < 0 || mark_index >= @mark_rows.size
      indices = @prepared_mark_indices
      return mark_index.to_i32 if indices.nil? && mark_index < @advanced_marks.size

      selected = indices || return nil
      low = 0
      high = selected.size - 1
      while low <= high
        middle = low + (high - low) // 2
        candidate = selected[middle]
        if candidate == mark_index
          return middle.to_i32
        elsif candidate < mark_index
          low = middle + 1
        else
          high = middle - 1
        end
      end
      nil
    end

    private def enforce_columnar_shape_workspace!(shape_build_bytes : UInt64) : Nil
      if checked_add(@retained_workspace_bytes, shape_build_bytes) > WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("Compact JSON columnar path union exceeds the aggregate materialization limit")
      end
      nil
    end

    private def columnar_shape_workspace_bytes(paths : Array(String), fallback_types : Hash(String, BinaryDataType)) : UInt64
      bytes = instance_sizeof(Array(String)).to_u64
      bytes = checked_add(bytes, checked_multiply(paths.size.to_u64, sizeof(Pointer(String)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Hash(String, BinaryDataType)).to_u64)
      bytes = checked_add(bytes, checked_multiply(paths.size.to_u64, (64 + sizeof(Pointer(String))).to_u64))
      paths.each { |path| bytes = checked_add(bytes, string_owner_bytes(path)) }
      bytes = checked_add(bytes, checked_multiply(fallback_types.size.to_u64, (64 + sizeof(Pointer(String))).to_u64))
      fallback_types.each_key { |path| bytes = checked_add(bytes, string_owner_bytes(path)) }
      bytes
    end

    private def calculate_retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactStaticJsonAdvancedPartPlan).to_u64
      bytes = checked_add(bytes, instance_sizeof(CompressedFrameIndex).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(BinaryCodecBudget)).to_u64)
      bytes = checked_add(bytes, string_owner_bytes(@part_path))
      bytes = checked_add(bytes, string_owner_bytes(@data_path))
      bytes = checked_add(bytes, instance_sizeof(Array(CompactStaticJsonAdvancedPreparedMark)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(@advanced_marks.size.to_u64, sizeof(Pointer(CompactStaticJsonAdvancedPreparedMark)).to_u64))
      @advanced_marks.each { |mark| bytes = checked_add(bytes, mark.retained_workspace_bytes) }
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@mark_rows.size.to_u64, sizeof(UInt64).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(CompressedFrameFingerprint)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(@frames.size.to_u64, sizeof(CompressedFrameFingerprint).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(Bytes))).to_u64)
      @uint64_mark_bytes.each do |name, marks|
        bytes = checked_add(bytes, string_owner_bytes(name))
        bytes = checked_add(bytes, instance_sizeof(Array(Bytes)).to_u64)
        bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(Bytes).to_u64))
        marks.each { |mark| bytes = checked_add(bytes, mark.size.to_u64) }
      end
      if indices = @prepared_mark_indices
        bytes = checked_add(bytes, instance_sizeof(Array(Int32)).to_u64)
        bytes = checked_add(bytes, checked_multiply(indices.size.to_u64, sizeof(Int32).to_u64))
      end
      bytes = checked_add(bytes, instance_sizeof(Array(CompactStaticJsonPartFileFingerprint)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(@source_files.size.to_u64, sizeof(CompactStaticJsonPartFileFingerprint).to_u64))
      @source_files.each { |file| bytes = checked_add(bytes, string_owner_bytes(file.name)) }
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@companion_columns.size.to_u64, sizeof(Pointer(String)).to_u64))
      @companion_columns.each { |name| bytes = checked_add(bytes, string_owner_bytes(name)) }
      bytes
    end

    # :nodoc:
    # Reader-only factory. `source_files` must have been captured at reader
    # admission. Dense plans take companions from the same complete capture as
    # root JSON. Sparse plans take them from an exact, authenticated key-only
    # capture made before the selected JSON spans.
    def self.build(
      reader : CompactStaticJsonBulkColumnReader,
      part_path : String,
      data_path : String,
      data_size : Int64,
      transport_limits : CompressedStreamLimits,
      frame_index : CompressedFrameIndex,
      source_files : Array(CompactStaticJsonPartFileFingerprint),
      capture : CompactPartPhysicalWindowCapture,
      advanced_marks : Array(CompactStaticJsonAdvancedPreparedMark),
      mark_rows : Array(UInt64),
      uint64_columns : Array(String),
      preparation_budget : BinaryCodecBudget,
      prepared_mark_indices : Array(Int32)? = nil,
      filter_capture : CompactPartPhysicalWindowCapture? = nil,
    ) : CompactStaticJsonAdvancedPartPlan
      selected_marks = prepared_mark_indices
      prepared_count = selected_marks.try(&.size) || advanced_marks.size
      unless prepared_count > 0 && advanced_marks.size == prepared_count
        raise CorruptPartError.new("Compact Advanced plan prepared marks differ from their absolute selection")
      end
      if indices = selected_marks
        previous_mark = -1_i32
        indices.each do |mark|
          unless mark > previous_mark && mark < mark_rows.size
            raise CorruptPartError.new("Compact Advanced plan selected marks are unordered or outside the full grid")
          end
          previous_mark = mark
        end
      elsif advanced_marks.size != mark_rows.size
        raise CorruptPartError.new("Compact Advanced dense plan differs from its full physical grid")
      end

      extras = Hash(String, Array(Bytes)).new(initial_capacity: uint64_columns.size)
      if filter = filter_capture
        unless uint64_columns.size == 1 && !filter.sparse? && filter.column_name == uint64_columns[0]
          raise CorruptPartError.new("Compact Advanced filter receipt differs from its selected UInt64 companion")
        end
        reader.validate_filter_capture!(filter, uint64_columns[0])
      end
      uint64_columns.each do |name|
        marks = Array(Bytes).new(prepared_count)
        prepared_count.times do |ordinal|
          mark = if indices = selected_marks
                   indices[ordinal]
                 else
                   ordinal.to_i32
                 end
          bytes = if filter
                    if filter.root_mark_shard_count_at(mark) != 1
                      raise CorruptPartError.new("Compact Advanced filter receipt has more than one physical slot")
                    end
                    filter.root_mark_shard_bytes_at(mark, 0)
                  else
                    capture.companion_uint64_mark_bytes(name, mark)
                  end
          expected_size = checked_multiply(mark_rows[mark], sizeof(UInt64).to_u64)
          unless bytes.size.to_u64 == expected_size
            raise CorruptPartError.new("Compact Advanced plan UInt64 mark width differs from its row grid")
          end
          marks << bytes
        end
        extras[String.new(name.to_slice)] = marks
      end

      frames = if filter = filter_capture
                 merge_frame_fingerprints(capture.authenticated_frames, filter.authenticated_frames)
               else
                 capture.authenticated_frames
               end
      new(
        reader,
        part_path,
        data_path,
        data_size,
        transport_limits,
        frame_index,
        source_files,
        frames,
        advanced_marks,
        prepared_mark_indices,
        mark_rows,
        extras,
        uint64_columns,
        preparation_budget,
      )
    end

    private def self.merge_frame_fingerprints(
      first : Array(CompressedFrameFingerprint),
      second : Array(CompressedFrameFingerprint),
    ) : Array(CompressedFrameFingerprint)
      by_offset = Hash(Int64, CompressedFrameFingerprint).new(initial_capacity: first.size + second.size)
      result = [] of CompressedFrameFingerprint
      [first, second].each do |group|
        group.each do |fingerprint|
          if previous = by_offset[fingerprint.compressed_offset]?
            unless same_frame_fingerprint?(previous, fingerprint)
              raise CorruptPartError.new("Compact source frame changed between filter and selected JSON capture")
            end
          else
            by_offset[fingerprint.compressed_offset] = fingerprint
            result << fingerprint
          end
        end
      end
      result.sort_by!(&.compressed_offset)
      result
    end

    private def self.same_frame_fingerprint?(
      left : CompressedFrameFingerprint,
      right : CompressedFrameFingerprint,
    ) : Bool
      left.compressed_offset == right.compressed_offset &&
        left.end_offset == right.end_offset &&
        left.logical_start == right.logical_start &&
        left.logical_end == right.logical_end &&
        left.method == right.method &&
        left.checksum == right.checksum
    end

    # :nodoc:
    def self.capture_source_files(
      part_path : String,
      marks_name : String,
      transport_limits : CompressedStreamLimits,
    ) : Array(CompactStaticJsonPartFileFingerprint)
      names = [
        "checksums.txt",
        "columns.txt",
        "count.txt",
        "columns_substreams.txt",
        marks_name,
        "default_compression_codec.txt",
        "serialization.json",
      ]
      names.map do |name|
        fingerprint_file(part_path, name, maximum_file_bytes(name, transport_limits))
      end
    end

    # :nodoc:
    def self.maximum_file_bytes(name : String, limits : CompressedStreamLimits) : Int64
      case name
      when "checksums.txt"
        PartChecksums::MAX_CHECKSUM_FILE_BYTES
      when "columns.txt", "count.txt", "columns_substreams.txt", "serialization.json"
        PartMetadataFileReader::MAX_METADATA_FILE_BYTES
      when "default_compression_codec.txt"
        64_i64
      else
        limits.max_mark_bytes
      end
    end

    # :nodoc:
    def self.fingerprint_file(
      part_path : String,
      name : String,
      maximum_bytes : Int64,
      optional : Bool = false,
    ) : CompactStaticJsonPartFileFingerprint
      path = File.join(part_path, name)
      raise CorruptPartError.new("Compact source metadata must not be a symbolic link") if File.symlink?(path)
      info = File.info?(path, follow_symlinks: false)
      unless info
        if optional
          return CompactStaticJsonPartFileFingerprint.new(String.new(name.to_slice), false, -1_i64, CityHashV1.file_hash(Bytes.new(0)))
        end
        raise CorruptPartError.new("Compact source metadata is missing")
      end
      unless info.type.file?
        raise CorruptPartError.new("Compact source metadata is not a regular file")
      end
      size = info.size
      if size < 0 || size > maximum_bytes || size > Int32::MAX
        raise CorruptPartError.new("Compact source metadata exceeds its fingerprint bound")
      end
      digest = if size == 0
                 CityHashV1.file_hash(Bytes.new(0))
               else
                 result = nil.as({UInt64, UInt64}?)
                 MMapDataSource.with_file(path, size, maximum_bytes) do |bytes|
                   result = CityHashV1.file_hash(bytes)
                 end
                 result || raise(CorruptPartError.new("Compact source metadata fingerprint was not produced"))
               end
      CompactStaticJsonPartFileFingerprint.new(String.new(name.to_slice), true, size, digest)
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot fingerprint Compact source metadata")
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact Advanced plan workspace overflows") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact Advanced plan workspace overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact Advanced plan workspace overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
