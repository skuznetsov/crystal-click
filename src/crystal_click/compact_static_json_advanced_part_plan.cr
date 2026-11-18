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
  # compressed frames captured with the complete JSON+UInt64 source read.
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
    @mark_rows : Array(UInt64)
    @uint64_mark_bytes : Hash(String, Array(Bytes))
    @companion_columns : Array(String)
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
      @mark_rows = mark_rows.dup
      @companion_columns = companion_columns.map { |name| String.new(name.to_slice) }
      @uint64_mark_bytes = Hash(String, Array(Bytes)).new(initial_capacity: uint64_mark_bytes.size)
      uint64_mark_bytes.each do |name, marks|
        @uint64_mark_bytes[String.new(name.to_slice)] = marks.map(&.dup)
      end
      unless !@advanced_marks.empty? &&
             @advanced_marks.size == @mark_rows.size &&
             !@frames.empty?
        raise CorruptPartError.new("Compact Advanced plan is incomplete")
      end
      @uint64_mark_bytes.each_value do |marks|
        unless marks.size == @mark_rows.size
          raise CorruptPartError.new("Compact Advanced plan companion grid differs from its root grid")
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

    def mark_row_count_at(mark_index : Int) : UInt64
      @mark_rows[mark_index]
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
      unless marks && mark_index >= 0 && mark_index < marks.size
        raise ArgumentError.new("Compact Advanced plan has no selected UInt64 mark")
      end
      marks[mark_index].dup
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
      unless mark_index >= 0 && mark_index < @advanced_marks.size
        raise ArgumentError.new("Compact Advanced plan mark index is outside its sealed grid")
      end
      unless budget.same?(@preparation_budget) || budget.includes_preparation_from?(@preparation_budget)
        raise ArgumentError.new("Compact Advanced plan decode requires its preparation receipt")
      end
      owner = @advanced_marks[mark_index]
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
      @retained_workspace_bytes
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
    # admission; `frames` and UInt64 bytes come from the same complete mmap as
    # the root JSON shards.
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
    ) : CompactStaticJsonAdvancedPartPlan
      extras = Hash(String, Array(Bytes)).new(initial_capacity: uint64_columns.size)
      uint64_columns.each do |name|
        marks = Array(Bytes).new(mark_rows.size)
        mark_rows.size.times do |mark|
          bytes = capture.companion_uint64_mark_bytes(name, mark)
          expected_size = checked_multiply(mark_rows[mark], sizeof(UInt64).to_u64)
          unless bytes.size.to_u64 == expected_size
            raise CorruptPartError.new("Compact Advanced plan UInt64 mark width differs from its row grid")
          end
          marks << bytes
        end
        extras[String.new(name.to_slice)] = marks
      end
      new(
        reader,
        part_path,
        data_path,
        data_size,
        transport_limits,
        frame_index,
        source_files,
        capture.authenticated_frames,
        advanced_marks,
        mark_rows,
        extras,
        uint64_columns,
        preparation_budget,
      )
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
