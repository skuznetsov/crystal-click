module CrystalClick
  struct UInt64ScanBatch
    getter part_index : Int32
    getter part_name : String
    getter part_path : String
    getter part_info : MergeTreePartInfo
    getter mark_index : Int32
    getter mark_row_offset : UInt64
    getter part_row_offset : UInt64
    getter source_row_offset : UInt64
    getter values : Slice(UInt64)

    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @part_info : MergeTreePartInfo,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @values : Slice(UInt64),
    )
    end
  end

  # A deterministic, read-only composition of physical Wide parts.
  class WidePartSet
    MAX_PARTS           = 1_024
    MAX_PART_NAME_BYTES = MergeTreePartInfo::MAX_NAME_BYTES
    MAX_TOTAL_ROWS      = 100_000_000_000_u64

    getter root : String
    getter column : String
    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private struct Entry
      getter info : MergeTreePartInfo
      getter reader : WidePart

      def initialize(@info : MergeTreePartInfo, @reader : WidePart)
      end
    end

    def self.open(root : String, column : String) : WidePartSet
      new(root, column)
    end

    def scan_into(
      scratch : Slice(UInt64),
      & : UInt64ScanBatch -> Nil
    ) : Nil
      raise BoundsError.new("empty scratch") if scratch.size == 0
      raise BoundsError.new("scratch must be writable") if scratch.read_only?

      source_row_offset = 0_u64
      @entries.each_with_index do |entry, part_index|
        entry.reader.scan_uint64_marks_into(@column, scratch) do |mark_index, mark_row_offset, part_row_offset, values|
          batch = UInt64ScanBatch.new(
            part_index.to_i32,
            entry.info.name,
            entry.reader.path,
            entry.info,
            mark_index,
            mark_row_offset,
            part_row_offset,
            source_row_offset,
            values
          )
          yield batch
          raise CorruptPartError.new("source row offset overflow") if values.size.to_u64 > MAX_TOTAL_ROWS - source_row_offset
          source_row_offset += values.size.to_u64
        end
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    @entries : Array(Entry)

    private def initialize(@root : String, @column : String)
      validate_root
      candidates = discover_candidates
      raise InvalidPartError.new("no valid parts discovered") if candidates.empty?
      raise BoundsError.new("part count exceeds limit") if candidates.size > MAX_PARTS

      candidates.sort! { |left, right| left[0] <=> right[0] }
      reject_overlaps(candidates)

      @entries = Array(Entry).new(candidates.size)
      total = 0_u64
      candidates.each do |candidate|
        info = candidate[0]
        path = candidate[1]
        reader = WidePart.open(path, @column)
        checksums = PartChecksums.open(path)
        checksums.validate_selected_entries(
          path,
          File.basename(reader.data_path),
          File.basename(reader.mark_path)
        )
        raise BoundsError.new("total row count exceeds limit") if reader.row_count > MAX_TOTAL_ROWS - total
        total += reader.row_count
        @entries << Entry.new(info, reader)
      end

      @part_count = @entries.size.to_i32
      @total_row_count = total
      @checksum_verification = ChecksumVerification::SizeChecked
    end

    private def validate_root
      raise InvalidPartError.new("root must not be a symbolic link") if File.symlink?(@root)
      raise InvalidPartError.new("root is not a directory") unless Dir.exists?(@root)
    end

    private def discover_candidates : Array({MergeTreePartInfo, String})
      candidates = Array({MergeTreePartInfo, String}).new
      Dir.each_child(@root) do |name|
        next if reserved_entry?(name)
        next unless MergeTreePartInfo.part_like?(name)
        raise BoundsError.new("part name exceeds limit") if name.bytesize > MAX_PART_NAME_BYTES

        info = MergeTreePartInfo.parse(name)
        raise InvalidPartError.new("invalid part name: #{name}") unless info
        raise UnsupportedFormatError.new("patch parts are not supported") if info.not_nil!.patch?

        path = File.join(@root, name)
        raise InvalidPartError.new("part is a symbolic link: #{name}") if File.symlink?(path)
        raise InvalidPartError.new("part is not a directory: #{name}") unless Dir.exists?(path)
        candidates << {info.not_nil!, path}
      end
      candidates
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot discover parts")
    end

    private def reject_overlaps(candidates : Array({MergeTreePartInfo, String}))
      candidates.each_cons(2) do |pair|
        left = pair[0]
        right = pair[1]
        next unless left[0].overlaps?(right[0])
        raise InvalidPartError.new("overlapping parts: #{left[0].name} and #{right[0].name}")
      end
    end

    private def reserved_entry?(name : String) : Bool
      name == "detached" || name == "moving" || name == "format_version.txt" || name.starts_with?("tmp")
    end
  end
end
