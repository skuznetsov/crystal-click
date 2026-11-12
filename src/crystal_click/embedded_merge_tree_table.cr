require "file_utils"
require "json"

module CrystalClick
  # A Crystal-owned table over immutable Wide parts with a UInt64 key and
  # either String payloads or declared scalar JSON typed paths.
  #
  # Visibility is selected by an empty directory under `committed/`. This is
  # process-atomic for cooperating writers on a local Darwin filesystem; it is
  # not a ClickHouse server table or a power-loss durability protocol.
  class EmbeddedMergeTreeTable
    FORMAT_VERSION          =         1
    JSON_FORMAT_VERSION     =         2
    MAX_COLUMN_NAME_BYTES   =       128
    MAX_MANIFEST_BYTES      = 4_096_i64
    MAX_METADATA_BYTES      = 4_096_i64
    MAX_CHECKSUMS_BYTES     = 64_i64 * 1024
    MAX_PARTS               = WidePartTable::MAX_PARTS
    MAX_PHYSICAL_ENTRIES    =       2_048
    MAX_COMMITTED_MARKERS   =       2_048
    MAX_MERGE_ROWS          = 100_000_u64
    MAX_MERGE_PAYLOAD_BYTES = 64_i64 * 1024 * 1024
    MAX_JSON_PATHS          = WidePartTable::MAX_COLUMNS - 1
    WRITER_STAGE_PREFIX     = ".crystal-click-wide-writer-"
    TABLE_STAGE_PREFIX      = ".crystal-click-embedded-table-"
    LOCK_FILE               = "writer.lock"
    MANIFEST_FILE           = "manifest.json"
    RENAME_EXCL             = 0x0000_0004_u32

    {% if flag?(:darwin) %}
      @[Link("c")]
      lib LibEmbeddedMergeTreeTableAtomicPublish
        fun renamex_np(old_path : UInt8*, new_path : UInt8*, flags : UInt32) : Int32
      end
    {% end %}

    private struct PhysicalPart
      getter name : String
      getter path : String
      getter info : MergeTreePartInfo

      def initialize(@name : String, @path : String, @info : MergeTreePartInfo)
      end
    end

    private struct Schema
      getter format_version : Int32
      getter key_name : String
      getter value_name : String
      getter value_type : String
      getter json_paths : Array(Tuple(String, String))

      def initialize(
        @format_version : Int32,
        @key_name : String,
        @value_name : String,
        @value_type : String,
        @json_paths : Array(Tuple(String, String)),
      )
      end
    end

    private struct MergeInput
      getter keys : Array(UInt64)
      getter values : Array(String)
      getter payload_bytes : Int64

      def initialize(@keys : Array(UInt64), @values : Array(String), @payload_bytes : Int64)
      end
    end

    private struct JSONMergeInput
      getter keys : Array(UInt64)
      getter paths : Array(WidePartWriter::JSONTypedPathColumn)
      getter payload_bytes : Int64

      def initialize(
        @keys : Array(UInt64),
        @paths : Array(WidePartWriter::JSONTypedPathColumn),
        @payload_bytes : Int64,
      )
      end
    end

    @root : String
    @key_name : String
    @value_name : String
    @value_type : String
    @json_paths : Array(Tuple(String, String))

    def self.create(root : String, key_name : String, value_name : String) : EmbeddedMergeTreeTable
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("root must not be empty") if root.empty?

      target = File.expand_path(root)
      raise ArgumentError.new("root must not already exist") if File.exists?(target) || File.symlink?(target)
      parent = File.dirname(target)
      raise ArgumentError.new("root parent must exist") unless Dir.exists?(parent)
      raise UnsupportedFormatError.new("atomic exclusive table publication is supported only on Darwin") unless darwin?

      stage = create_stage(parent)
      begin
        Dir.mkdir(File.join(stage, "parts"))
        Dir.mkdir(File.join(stage, "committed"))
        File.write(File.join(stage, MANIFEST_FILE), manifest_json(key_name, value_name))
        File.write(File.join(stage, LOCK_FILE), "")
        publish_root_exclusively(stage, target)
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end

      open(target)
    end

    # Create a table whose payload is a top-level JSON column with an explicit,
    # bounded set of simple scalar typed paths. Values for absent paths are
    # supplied by the caller as normalized scalar defaults.
    def self.create_json(
      root : String,
      key_name : String,
      value_name : String,
      paths : Array(Tuple(String, String)),
    ) : EmbeddedMergeTreeTable
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("root must not be empty") if root.empty?
      canonical_paths = validate_json_schema!(key_name, value_name, paths)

      target = File.expand_path(root)
      raise ArgumentError.new("root must not already exist") if File.exists?(target) || File.symlink?(target)
      parent = File.dirname(target)
      raise ArgumentError.new("root parent must exist") unless Dir.exists?(parent)
      raise UnsupportedFormatError.new("atomic exclusive table publication is supported only on Darwin") unless darwin?

      stage = create_stage(parent)
      begin
        Dir.mkdir(File.join(stage, "parts"))
        Dir.mkdir(File.join(stage, "committed"))
        File.write(File.join(stage, MANIFEST_FILE), manifest_json_v2(key_name, value_name, canonical_paths))
        File.write(File.join(stage, LOCK_FILE), "")
        publish_root_exclusively(stage, target)
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end

      open(target)
    end

    def self.open(root : String) : EmbeddedMergeTreeTable
      raise InvalidPartError.new("embedded table root must not be empty") if root.empty?
      target = File.expand_path(root)
      reject_symlink!(target, "table root")
      raise InvalidPartError.new("embedded table root is not a directory") unless Dir.exists?(target)

      manifest = read_manifest(target)
      table = new(target, manifest.key_name, manifest.value_name, manifest.json_paths)
      table.part_paths
      table
    end

    def key_name : String
      @key_name.dup
    end

    def value_name : String
      @value_name.dup
    end

    def value_type : String
      @value_type.dup
    end

    def json_paths : Array(Tuple(String, String))
      @json_paths.map { |name, type| {name.dup, type.dup} }
    end

    # Return paths for the currently committed, structurally valid parts.
    # The inventory is resolved anew for each call. Returned paths are not
    # pinned after this method returns; use with_part_paths for a scoped borrow.
    def part_paths : Array(String)
      with_part_paths { |paths| paths }
    end

    # Borrow the current active paths while holding the table's shared lock.
    # The paths must not escape the callback if reclamation may run concurrently.
    # Do not reenter a table write from the callback; that can self-deadlock.
    def with_part_paths(&block : Array(String) -> T) : T forall T
      with_reader_lock do
        committed, _orphans, _physical, _physical_entry_count, _marker_count, _covered = inventory
        yield committed.map(&.path)
      end
    end

    # Return complete unmarked parts and recognizable writer staging
    # directories. They are never adopted or removed automatically.
    def orphan_part_names : Array(String)
      with_reader_lock do
        _committed, orphans, _physical, _physical_entry_count, _marker_count, _covered = inventory
        orphans
      end
    end

    # Explicitly reclaim only history already superseded by active parts,
    # covered unmarked parts, and recognizable writer stages. Uncovered
    # canonical orphans retain their block and merge-level reservations.
    def reclaim_obsolete! : Nil
      with_writer_lock do
        active, orphan_names, physical, _physical_entry_count, _marker_count, covered_markers = inventory
        active_infos = active.map(&.info)

        # Marker removal is the recovery boundary: a death after this point
        # leaves only an unmarked physical orphan for a later explicit retry.
        covered_markers.each do |part|
          marker_path = File.join(committed_path, part.name)
          reject_symlink!(marker_path, "commit marker")
          Dir.delete(marker_path)
          {% if flag?(:crystal_click_test_failpoints) %}
            CrystalClick::TestFailpoint.hit("gc_marker_removed")
          {% end %}
          remove_physical_entry!(part.name)
        end

        physical.each do |part|
          next if active.any? { |current| current.name == part.name }
          next if covered_markers.any? { |covered| covered.name == part.name }
          next unless active_infos.any? { |info| contains_or_equals?(info, part.info) }

          remove_physical_entry!(part.name)
        end

        orphan_names.each do |name|
          next unless name.starts_with?(WRITER_STAGE_PREFIX)
          remove_physical_entry!(name)
        end
      end
      nil
    end

    # Publish one sorted UInt64/String part and then its exclusive commit
    # marker. A part whose marker publication fails remains an invisible
    # orphan and keeps its allocated block number.
    def insert(keys : Slice(UInt64), values : Slice(String), rows_per_mark : Int32 = 8192) : String
      validate_insert_inputs(keys, values, rows_per_mark)
      validate_layout!

      with_writer_lock do
        committed, _orphans, physical, physical_entry_count, marker_count, _covered = inventory
        raise BoundsError.new("embedded table exceeds part limit") if committed.size >= MAX_PARTS
        preflight_new_part!(physical_entry_count, marker_count)

        max_block = physical.reduce(0_i64) { |current, part| {current, part.info.max_block}.max }
        raise BoundsError.new("embedded part block number is exhausted") if max_block == Int64::MAX
        block = max_block + 1_i64
        part_name = "all_#{block}_#{block}_0"
        part_path = File.join(parts_path, part_name)

        WidePartWriter.write_uint64_string_pair(
          part_path,
          @key_name,
          keys,
          @value_name,
          values,
          rows_per_mark
        )

        # mkdir is the exclusive atomic visibility point. If this raises, the
        # already-published part deliberately remains an orphan.
        Dir.mkdir(File.join(committed_path, part_name))
        {% if flag?(:crystal_click_test_failpoints) %}
          CrystalClick::TestFailpoint.hit("marker_created")
        {% end %}
        part_name
      end
    end

    # Publish one sorted UInt64 part with the complete declared JSON path set.
    # Each path column must be homogeneous and have exactly the declared type.
    def insert_json(
      keys : Slice(UInt64),
      paths : Array(WidePartWriter::JSONTypedPathColumn),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_json_insert_inputs(keys, paths, rows_per_mark)
      validate_layout!

      with_writer_lock do
        committed, _orphans, physical, physical_entry_count, marker_count, _covered = inventory
        raise BoundsError.new("embedded table exceeds part limit") if committed.size >= MAX_PARTS
        preflight_new_part!(physical_entry_count, marker_count)

        max_block = physical.reduce(0_i64) { |current, part| {current, part.info.max_block}.max }
        raise BoundsError.new("embedded part block number is exhausted") if max_block == Int64::MAX
        block = max_block + 1_i64
        part_name = "all_#{block}_#{block}_0"
        part_path = File.join(parts_path, part_name)

        WidePartWriter.write_uint64_json_typed_paths(
          part_path,
          @key_name,
          keys,
          @value_name,
          paths,
          rows_per_mark
        )

        # mkdir remains the only visibility point for both schema versions.
        Dir.mkdir(File.join(committed_path, part_name))
        {% if flag?(:crystal_click_test_failpoints) %}
          CrystalClick::TestFailpoint.hit("marker_created")
        {% end %}
        part_name
      end
    end

    # Merge two neighboring visible parts into one new immutable part. The
    # input names are resolved against the locked active inventory before any
    # caller-supplied string can be used as a filesystem path.
    def merge_adjacent(left_name : String, right_name : String, rows_per_mark : Int32 = 8192) : String
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > WidePartWriter::MAX_ROWS_PER_MARK
      validate_layout!

      with_writer_lock do
        active, _orphans, physical, physical_entry_count, marker_count, _covered = inventory
        left_index = active.index { |part| part.name == left_name }
        right_index = active.index { |part| part.name == right_name }
        unless left_index && right_index && right_index == left_index + 1
          raise ArgumentError.new("merge inputs must be neighboring active parts in ascending block order")
        end

        left = active[left_index]
        right = active[right_index]
        preflight_new_part!(physical_entry_count, marker_count)

        unless @json_paths.empty?
          next merge_json_pair(left, right, physical, rows_per_mark)
        end

        left_reader = WidePartTable.open_selected_typed([left.path], [@key_name, @value_name])
        right_reader = WidePartTable.open_selected_typed([right.path], [@key_name, @value_name])
        left_row_count = part_row_count(left_reader)
        right_row_count = part_row_count(right_reader)
        if left_row_count > MAX_MERGE_ROWS || right_row_count > MAX_MERGE_ROWS - left_row_count
          raise BoundsError.new("embedded merge exceeds row limit")
        end

        left_rows = read_merge_input(left_reader, left_row_count, 0_i64)
        right_rows = read_merge_input(right_reader, right_row_count, left_rows.payload_bytes)
        merged_keys, merged_values = stable_merge(left_rows, right_rows)
        level = next_merge_level(physical, left, right)
        part_name = canonical_part_name(left.info.min_block, right.info.max_block, level)
        part_path = File.join(parts_path, part_name)

        WidePartWriter.write_uint64_string_pair(
          part_path,
          @key_name,
          merged_keys.to_unsafe.to_slice(merged_keys.size),
          @value_name,
          merged_values.to_unsafe.to_slice(merged_values.size),
          rows_per_mark
        )

        # The marker is the only visibility point. If it fails, the complete
        # result remains an ignored orphan and both old sources stay visible.
        Dir.mkdir(File.join(committed_path, part_name))
        part_name
      end
    end

    # Validate the selection even on an empty table, where there is no part
    # reader available to perform the usual type/column checks. The callback
    # runs under the shared lock and must not reenter a table write.
    def scan_typed(columns : Array(String), batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      validate_scan_request!(columns, batch_rows)
      with_reader_lock do
        committed, _orphans, _physical, _physical_entry_count, _marker_count, _covered = inventory
        unless committed.empty?
          table = WidePartTable.open_selected_typed(committed.map(&.path), columns)
          table.scan_typed(batch_rows) { |batch| yield batch }
        end
      end
      nil
    end

    # Scan conservative candidate granules for an inclusive UInt64 primary-key
    # range. Callers must apply the exact key predicate to every returned row.
    # The shared table lock remains held through callbacks; callbacks must not
    # reenter a table write.
    def scan_uint64_pk_candidates(
      columns : Array(String),
      lower_bound : UInt64? = nil,
      upper_bound : UInt64? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      raise BoundsError.new("at least one primary-key bound is required") unless lower_bound || upper_bound
      if lower = lower_bound
        if upper = upper_bound
          raise BoundsError.new("primary-key lower bound exceeds upper bound") if lower > upper
        end
      end
      validate_pk_candidate_request!(columns)

      with_reader_lock do
        committed, _orphans, _physical, _physical_entry_count, _marker_count, _covered = inventory
        unless committed.empty?
          table = WidePartTable.open_selected_typed(committed.map(&.path), columns)
          expected_column_types = columns.map { |column| {column, embedded_column_type(column).not_nil!} }
          unless table.column_types == expected_column_types
            raise UnsupportedFormatError.new("embedded candidate column types do not match the table schema")
          end

          part_mark_rows = table.part_mark_row_counts
          raise CorruptPartError.new("selected part mark inventory changed") unless part_mark_rows.size == committed.size

          # Validate every active index and construct every schedule before the
          # typed reader can expose its first callback.
          candidate_marks = Array(Array(Int32)).new(committed.size)
          committed.each_with_index do |part, part_index|
            checksums = PartChecksums.open(part.path)
            index = PrimaryKeyIndex.open(
              part.path,
              part_mark_rows[part_index].size,
              checksums,
              verify_recorded_hash: true
            )
            candidate_marks << index.candidate_marks(lower_bound, upper_bound)
          end

          table.scan_typed_candidate_marks(candidate_marks) { |batch| yield batch }
        end
      end
      nil
    end

    private def initialize(
      @root : String,
      @key_name : String,
      @value_name : String,
      paths : Array(Tuple(String, String)) = [] of Tuple(String, String),
    )
      @json_paths = paths.map { |name, type| {name.dup, type.dup} }
      @value_type = @json_paths.empty? ? "String" : json_value_type(@json_paths)
    end

    private def reject_symlink!(path : String, label : String) : Nil
      raise CorruptPartError.new("#{label} must not be a symbolic link") if File.symlink?(path)
      nil
    end

    private def json_value_type(paths : Array(Tuple(String, String))) : String
      "JSON(#{paths.map { |name, type| "#{name} #{type}" }.join(", ")})"
    end

    private def validate_layout! : Nil
      reject_symlink!(@root, "table root")
      raise InvalidPartError.new("embedded table root is not a directory") unless Dir.exists?(@root)

      manifest_path = File.join(@root, MANIFEST_FILE)
      reject_symlink!(manifest_path, "manifest")
      raise UnsupportedFormatError.new("embedded table manifest is missing") unless File.file?(manifest_path)
      manifest = self.class.read_manifest(@root)
      unless manifest.key_name == @key_name && manifest.value_name == @value_name &&
             manifest.value_type == @value_type && manifest.json_paths == @json_paths
        raise UnsupportedFormatError.new("embedded table schema changed after open")
      end

      parts = parts_path
      committed = committed_path
      lock = File.join(@root, LOCK_FILE)
      [parts, committed].each do |path|
        reject_symlink!(path, "table directory")
        raise UnsupportedFormatError.new("required embedded table directory is missing") unless Dir.exists?(path)
      end
      reject_symlink!(lock, "writer lock")
      raise UnsupportedFormatError.new("writer lock file is missing or not regular") unless File.file?(lock)

      expected_root_entries = [MANIFEST_FILE, "parts", "committed", LOCK_FILE].sort
      unless Dir.children(@root).sort == expected_root_entries
        raise UnsupportedFormatError.new("embedded table root contains unsupported entries")
      end
      nil
    end

    private def inventory : {Array(PhysicalPart), Array(String), Array(PhysicalPart), Int32, Int32, Array(PhysicalPart)}
      validate_layout!

      physical = [] of PhysicalPart
      orphan_names = [] of String
      parts_children = Dir.children(parts_path)
      raise BoundsError.new("embedded table exceeds physical entry limit") if parts_children.size > MAX_PHYSICAL_ENTRIES
      parts_children.each do |name|
        path = File.join(parts_path, name)
        if name.starts_with?(WRITER_STAGE_PREFIX)
          reject_symlink!(path, "writer staging entry")
          raise CorruptPartError.new("writer staging entry is not a directory") unless Dir.exists?(path)
          orphan_names << name
          next
        end

        info = parse_part_name(name)
        validate_part_name!(name, info)
        physical << PhysicalPart.new(name, path, info)
      end

      marker_names = Dir.children(committed_path)
      raise BoundsError.new("embedded table exceeds committed marker limit") if marker_names.size > MAX_COMMITTED_MARKERS
      marked_names = Set(String).new
      marked_parts = [] of PhysicalPart
      marker_names.each do |name|
        info = parse_part_name(name)
        validate_part_name!(name, info, "commit marker")
        marker_path = File.join(committed_path, name)
        reject_symlink!(marker_path, "commit marker")
        raise CorruptPartError.new("commit marker is not a directory") unless Dir.exists?(marker_path)
        raise CorruptPartError.new("commit marker must be empty") unless Dir.children(marker_path).empty?
        raise CorruptPartError.new("duplicate commit marker") unless marked_names.add?(name)
        marked_parts << PhysicalPart.new(name, File.join(parts_path, name), info)
      end

      # Resolve marker intervals before consulting part contents. Historical
      # parts may already be damaged or partially removed by interrupted GC.
      reject_ambiguous_marked_intervals!(marked_parts)
      active_markers = marked_parts.reject do |part|
        marked_parts.any? { |other| other.name != part.name && strictly_contains?(other.info, part.info) }
      end
      covered_markers = marked_parts.reject { |part| active_markers.any? { |active| active.name == part.name } }
      covered_marker_names = covered_markers.map(&.name).to_set

      physical_by_name = physical.to_h { |part| {part.name, part} }
      committed = [] of PhysicalPart
      active_markers.each do |marker|
        part = physical_by_name[marker.name]?
        raise CorruptPartError.new("commit marker has no physical part") unless part
        validate_part!(part)
        committed << part
      end

      # Preserve W5's fail-closed treatment of active and uncovered physical
      # entries. A malformed root is tolerated only if a validated active
      # interval covers it: either a historical marker still names it or GC
      # already removed that marker before dying.
      active_infos = committed.map(&.info)
      physical.each do |part|
        next if covered_marker_names.includes?(part.name)
        next if !marked_names.includes?(part.name) &&
                active_infos.any? { |info| contains_or_equals?(info, part.info) } &&
                (File.symlink?(part.path) || !Dir.exists?(part.path))
        reject_symlink!(part.path, "part")
        raise CorruptPartError.new("physical part entry is not a directory") unless Dir.exists?(part.path)
      end
      physical.each { |part| orphan_names << part.name unless marked_names.includes?(part.name) }
      committed.sort_by! { |part| {part.info.min_block, part.info.max_block, part.info.name} }
      raise BoundsError.new("embedded table exceeds active part limit") if committed.size > MAX_PARTS
      orphan_names.sort!
      {committed, orphan_names, physical, parts_children.size, marker_names.size, covered_markers}
    end

    private def remove_physical_entry!(name : String) : Nil
      path = File.join(parts_path, name)
      return nil unless File.exists?(path) || File.symlink?(path)
      # rm_r unlinks symlink entries rather than following them, and raises if
      # removal fails instead of silently reporting a successful cleanup.
      FileUtils.rm_r(path)
      nil
    end

    private def validate_part!(part : PhysicalPart) : Nil
      reject_symlink!(part.path, "part")
      raise CorruptPartError.new("physical part entry is not a directory") unless Dir.exists?(part.path)

      unless @json_paths.empty?
        validate_json_part_contents!(part)
        return nil
      end

      expected_columns = "columns format version: 1\n2 columns:\n`#{@key_name}` UInt64\n`#{@value_name}` String\n"
      expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `#{@key_name}`:\n\t#{@key_name}\n2 substreams for column `#{@value_name}`:\n\t#{@value_name}.size\n\t#{@value_name}\n"
      expected_files = [
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
        "serialization.json",
        "count.txt",
        "primary.idx",
        "checksums.txt",
      ]
      checksummed_files = ["count.txt", "primary.idx", "serialization.json"]
      {StreamName.hash(@key_name), StreamName.hash("#{@value_name}.size"), StreamName.hash(@value_name)}.each do |base|
        expected_files << "#{base}.bin"
        expected_files << "#{base}.mrk2"
        checksummed_files << "#{base}.bin"
        checksummed_files << "#{base}.mrk2"
      end
      raise UnsupportedFormatError.new("embedded table column streams collide") unless expected_files.uniq.size == expected_files.size

      children = Dir.children(part.path)
      unless children.sort == expected_files.sort
        raise CorruptPartError.new("committed part has an unexpected physical layout")
      end
      children.each do |name|
        child = File.join(part.path, name)
        reject_symlink!(child, "part entry")
        raise CorruptPartError.new("part entry is not a regular file") unless File.file?(child)
      end
      unless read_part_metadata(part.path, "columns.txt") == expected_columns
        raise UnsupportedFormatError.new("committed part schema does not match the embedded table")
      end
      unless read_part_metadata(part.path, "columns_substreams.txt") == expected_substreams
        raise UnsupportedFormatError.new("committed part substreams do not match the embedded table")
      end
      unless read_part_metadata(part.path, "default_compression_codec.txt") == "CODEC(LZ4)"
        raise UnsupportedFormatError.new("committed part codec does not match W3")
      end
      unless read_part_metadata(part.path, "metadata_version.txt") == "0"
        raise UnsupportedFormatError.new("committed part metadata version does not match W3")
      end
      unless read_part_metadata(part.path, "serialization.json") == "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        raise UnsupportedFormatError.new("committed part serialization metadata does not match W3")
      end

      checksums_path = File.join(part.path, "checksums.txt")
      raise CorruptPartError.new("checksums.txt exceeds embedded table metadata limit") if File.size(checksums_path) > MAX_CHECKSUMS_BYTES
      checksums = PartChecksums.open(part.path)
      unless checksums.entries.keys.sort == checksummed_files.sort
        raise CorruptPartError.new("committed part checksum entries do not match the W3 layout")
      end
      checksummed_files.each do |name|
        checksums.validate_selected_entries(part.path, name)
      end

      reader = WidePartTable.open_selected_typed([part.path], [@key_name, @value_name])
      unless reader.column_types == [{@key_name, "UInt64"}, {@value_name, "String"}]
        raise UnsupportedFormatError.new("committed part types do not match the embedded table")
      end
      mark_rows = reader.part_mark_row_counts.first? || raise(CorruptPartError.new("committed part has no marks"))
      PrimaryKeyIndex.open(part.path, mark_rows.size, checksums)
      nil
    end

    private def validate_json_part_contents!(part : PhysicalPart) : Nil
      sorted_paths = @json_paths.sort_by { |name, _type| name }
      expected_columns = "columns format version: 1\n2 columns:\n`#{@key_name}` UInt64\n`#{@value_name}` #{json_value_type(sorted_paths)}\n"
      substreams = ["#{@value_name}.object_structure"]
      sorted_paths.each do |name, type|
        typed_name = "#{@value_name}.#{name}"
        substreams << "#{typed_name}.size" if type == "String"
        substreams << typed_name
      end
      substreams.concat([
        "#{@value_name}.object_shared_data.0.size0",
        "#{@value_name}.object_shared_data.0%2Epaths",
        "#{@value_name}.object_shared_data.0%2Evalues",
      ])
      expected_substreams = String.build do |text|
        text << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{@key_name}`:\n\t#{@key_name}\n"
        text << "#{substreams.size} substreams for column `#{@value_name}`:\n"
        substreams.each { |stream| text << "\t#{stream}\n" }
      end

      expected_files = [
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
        "serialization.json",
        "count.txt",
        "primary.idx",
        "checksums.txt",
      ]
      checksummed_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams = [@key_name, "#{@value_name}.object_structure"]
      sorted_paths.each do |name, type|
        typed_name = "#{@value_name}.#{name}"
        logical_streams << "#{typed_name}.size" if type == "String"
        logical_streams << typed_name
      end
      logical_streams.concat([
        "#{@value_name}.object_shared_data.0.size0",
        "#{@value_name}.object_shared_data.0%2Epaths",
        "#{@value_name}.object_shared_data.0%2Evalues",
      ])
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        {"#{base}.bin", "#{base}.mrk2"}.each do |name|
          expected_files << name
          checksummed_files << name
        end
      end
      raise UnsupportedFormatError.new("embedded JSON part streams collide") unless expected_files.uniq.size == expected_files.size

      children = Dir.children(part.path)
      unless children.sort == expected_files.sort
        raise CorruptPartError.new("committed JSON part has an unexpected physical layout")
      end
      children.each do |name|
        child = File.join(part.path, name)
        reject_symlink!(child, "part entry")
        raise CorruptPartError.new("part entry is not a regular file") unless File.file?(child)
      end
      unless read_part_metadata(part.path, "columns.txt") == expected_columns
        raise UnsupportedFormatError.new("committed JSON part schema does not match the embedded table")
      end
      unless read_part_metadata(part.path, "columns_substreams.txt") == expected_substreams
        raise UnsupportedFormatError.new("committed JSON part substreams do not match the embedded table")
      end
      unless read_part_metadata(part.path, "default_compression_codec.txt") == "CODEC(LZ4)"
        raise UnsupportedFormatError.new("committed JSON part codec does not match W3")
      end
      unless read_part_metadata(part.path, "metadata_version.txt") == "0"
        raise UnsupportedFormatError.new("committed JSON part metadata version does not match W3")
      end

      checksums_path = File.join(part.path, "checksums.txt")
      raise CorruptPartError.new("checksums.txt exceeds embedded table metadata limit") if File.size(checksums_path) > MAX_CHECKSUMS_BYTES
      checksums = PartChecksums.open(part.path)
      unless checksums.entries.keys.sort == checksummed_files.sort
        raise CorruptPartError.new("committed JSON part checksum entries do not match the declared streams")
      end
      checksummed_files.each { |name| checksums.validate_selected_entries(part.path, name) }

      projections = [@key_name] + sorted_paths.map { |name, _type| "#{@value_name}.#{name}" }
      expected_types = [{@key_name, "UInt64"}] + sorted_paths.map { |name, type| {"#{@value_name}.#{name}", type} }
      reader = WidePartTable.open_selected_typed([part.path], projections)
      unless reader.column_types == expected_types
        raise UnsupportedFormatError.new("committed JSON part types do not match the embedded table")
      end
      row_count = reader.total_row_count
      unless read_part_metadata(part.path, "count.txt") == row_count.to_s
        raise CorruptPartError.new("committed JSON part count does not match its marks")
      end
      validate_json_serialization_metadata!(part.path, row_count)
      mark_rows = reader.part_mark_row_counts.first? || raise(CorruptPartError.new("committed JSON part has no marks"))
      PrimaryKeyIndex.open(part.path, mark_rows.size, checksums)
      nil
    end

    private def validate_json_serialization_metadata!(part_path : String, rows : UInt64) : Nil
      text = read_part_metadata(part_path, "serialization.json")
      begin
        manifest = JSON.parse(text).as_h
        expected_top = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
        raise UnsupportedFormatError.new("embedded JSON serialization fields do not match") unless manifest.keys.sort == expected_top
        raise UnsupportedFormatError.new("embedded JSON serialization version is unsupported") unless manifest["version"].as_i == 1
        raise UnsupportedFormatError.new("embedded JSON nested serialization flag differs") unless manifest["propagate_types_serialization_versions_to_nested_types"].as_bool
        raise UnsupportedFormatError.new("embedded JSON serialization type versions differ") unless manifest["types_serialization_versions"].as_h == {"string" => JSON::Any.new(1_i64)}

        columns = manifest["columns"].as_a
        raise UnsupportedFormatError.new("embedded JSON serialization columns differ") unless columns.size == 1
        key = columns[0].as_h
        raise UnsupportedFormatError.new("embedded JSON key serialization fields differ") unless key.keys.sort == ["kind", "name", "num_defaults", "num_rows"].sort
        raise UnsupportedFormatError.new("embedded JSON key serialization kind differs") unless key["kind"].as_s == "Default"
        raise UnsupportedFormatError.new("embedded JSON key serialization name differs") unless key["name"].as_s == @key_name
        raise UnsupportedFormatError.new("embedded JSON key serialization row count differs") unless key["num_rows"].as_i == rows
        defaults = key["num_defaults"].as_i
        raise UnsupportedFormatError.new("embedded JSON key default count exceeds row count") if defaults < 0 || defaults.to_u64 > rows
      rescue ex : JSON::ParseException | TypeCastError | KeyError
        raise UnsupportedFormatError.new("embedded JSON serialization metadata is malformed")
      end
      nil
    end

    private def validate_insert_inputs(keys : Slice(UInt64), values : Slice(String), rows_per_mark : Int32) : Nil
      raise ArgumentError.new("insert requires a String table; use insert_json") unless @json_paths.empty?
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end
      nil
    end

    private def validate_json_insert_inputs(
      keys : Slice(UInt64),
      paths : Array(WidePartWriter::JSONTypedPathColumn),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("insert_json requires a JSON typed-path table") if @json_paths.empty?
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty?
      raise ArgumentError.new("JSON path set differs from the table schema") if paths.size != @json_paths.size
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > WidePartWriter::MAX_ROWS_PER_MARK

      actual_schema = paths.map { |path| {path.name, path.type_name} }.sort_by(&.[0])
      raise ArgumentError.new("JSON path set differs from the table schema") unless actual_schema == @json_paths
      unless paths.all? { |path| path.values.size == keys.size }
        raise ArgumentError.new("JSON typed-path columns must match key row count")
      end
      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end
      nil
    end

    private def preflight_new_part!(physical_entry_count : Int32, marker_count : Int32) : Nil
      raise BoundsError.new("embedded table exceeds physical entry limit") if physical_entry_count >= MAX_PHYSICAL_ENTRIES
      raise BoundsError.new("embedded table exceeds committed marker limit") if marker_count >= MAX_COMMITTED_MARKERS
      nil
    end

    private def part_row_count(reader : WidePartTable) : UInt64
      mark_counts = reader.part_mark_row_counts.first? || raise(CorruptPartError.new("merge input has no data marks"))
      mark_counts.reduce(0_u64) do |total, mark_rows|
        raise BoundsError.new("embedded merge exceeds row limit") if mark_rows > MAX_MERGE_ROWS - total
        total + mark_rows
      end
    end

    private def read_merge_input(reader : WidePartTable, expected_rows : UInt64, payload_bytes_before : Int64) : MergeInput
      keys = [] of UInt64
      values = [] of String
      payload_bytes = payload_bytes_before
      have_previous = false
      previous_key = 0_u64

      reader.scan_typed do |batch|
        batch_keys = batch.values_for(@key_name, UInt64)
        batch_values = batch.strings_for(@value_name)
        unless batch_keys.size == batch_values.size
          raise CorruptPartError.new("merge input columns are not row-aligned")
        end

        batch_keys.each_with_index do |key, index|
          if have_previous && key < previous_key
            raise CorruptPartError.new("merge input primary keys are not nondecreasing")
          end
          value = batch_values[index]
          value_bytes = value.bytesize.to_i64
          if value_bytes > MAX_MERGE_PAYLOAD_BYTES - payload_bytes
            raise BoundsError.new("embedded merge exceeds String payload limit")
          end
          payload_bytes += value_bytes
          keys << key
          values << value
          previous_key = key
          have_previous = true
        end
      end

      unless keys.size.to_u64 == expected_rows
        raise CorruptPartError.new("merge input row count changed while reading")
      end
      MergeInput.new(keys, values, payload_bytes)
    end

    private def merge_json_pair(
      left : PhysicalPart,
      right : PhysicalPart,
      physical : Array(PhysicalPart),
      rows_per_mark : Int32,
    ) : String
      projections = [@key_name] + @json_paths.map { |name, _type| "#{@value_name}.#{name}" }
      left_reader = WidePartTable.open_selected_typed([left.path], projections)
      right_reader = WidePartTable.open_selected_typed([right.path], projections)
      left_row_count = part_row_count(left_reader)
      right_row_count = part_row_count(right_reader)
      if left_row_count > MAX_MERGE_ROWS || right_row_count > MAX_MERGE_ROWS - left_row_count
        raise BoundsError.new("embedded merge exceeds row limit")
      end

      left_rows = read_json_merge_input(left_reader, left_row_count, 0_i64)
      right_rows = read_json_merge_input(right_reader, right_row_count, left_rows.payload_bytes)
      merged_keys, merged_paths = stable_json_merge(left_rows, right_rows)
      level = next_merge_level(physical, left, right)
      part_name = canonical_part_name(left.info.min_block, right.info.max_block, level)
      part_path = File.join(parts_path, part_name)

      WidePartWriter.write_uint64_json_typed_paths(
        part_path,
        @key_name,
        merged_keys.to_unsafe.to_slice(merged_keys.size),
        @value_name,
        merged_paths,
        rows_per_mark
      )
      Dir.mkdir(File.join(committed_path, part_name))
      part_name
    end

    private def read_json_merge_input(
      reader : WidePartTable,
      expected_rows : UInt64,
      payload_bytes_before : Int64,
    ) : JSONMergeInput
      keys = [] of UInt64
      path_values = @json_paths.map { [] of WidePartWriter::JSONTypedPathValue }
      payload_bytes = payload_bytes_before
      have_previous = false
      previous_key = 0_u64
      reader.scan_typed do |batch|
        batch_keys = batch.values_for(@key_name, UInt64)
        batch_values = @json_paths.map do |name, type|
          read_json_path_values(batch, "#{@value_name}.#{name}", type)
        end
        unless batch_values.all? { |values| values.size == batch_keys.size }
          raise CorruptPartError.new("JSON merge input columns are not row-aligned")
        end

        batch_keys.each_with_index do |key, row|
          if have_previous && key < previous_key
            raise CorruptPartError.new("merge input primary keys are not nondecreasing")
          end
          batch_values.each_with_index do |values, path_index|
            value = values[row]
            if value.is_a?(String)
              value_bytes = value.bytesize.to_i64
              if value_bytes > MAX_MERGE_PAYLOAD_BYTES - payload_bytes
                raise BoundsError.new("embedded merge exceeds String payload limit")
              end
              payload_bytes += value_bytes
            end
            path_values[path_index] << value
          end
          keys << key
          previous_key = key
          have_previous = true
        end
      end

      unless keys.size.to_u64 == expected_rows
        raise CorruptPartError.new("JSON merge input row count changed while reading")
      end
      columns = @json_paths.each_with_index.map do |(name, type), index|
        WidePartWriter::JSONTypedPathColumn.new(name, type, path_values[index])
      end.to_a
      JSONMergeInput.new(keys, columns, payload_bytes)
    end

    private def read_json_path_values(
      batch : WidePartTableBatch,
      column : String,
      type_name : String,
    ) : Array(WidePartWriter::JSONTypedPathValue)
      case type_name
      when "String"  then batch.strings_for(column).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "Int8"    then batch.values_for(column, Int8).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "Int16"   then batch.values_for(column, Int16).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "Int32"   then batch.values_for(column, Int32).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "Int64"   then batch.values_for(column, Int64).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "UInt8"   then batch.values_for(column, UInt8).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "UInt16"  then batch.values_for(column, UInt16).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "UInt32"  then batch.values_for(column, UInt32).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "UInt64"  then batch.values_for(column, UInt64).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "Float32" then batch.values_for(column, Float32).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      when "Float64" then batch.values_for(column, Float64).to_a.map { |value| value.as(WidePartWriter::JSONTypedPathValue) }
      else                raise UnsupportedFormatError.new("embedded JSON path type is unsupported")
      end
    end

    private def stable_json_merge(
      left : JSONMergeInput,
      right : JSONMergeInput,
    ) : {Array(UInt64), Array(WidePartWriter::JSONTypedPathColumn)}
      merged_keys = Array(UInt64).new(left.keys.size + right.keys.size)
      merged_values = @json_paths.map do |_name, _type|
        [] of WidePartWriter::JSONTypedPathValue
      end
      left_index = 0
      right_index = 0

      while left_index < left.keys.size || right_index < right.keys.size
        take_left = right_index >= right.keys.size ||
                    left_index < left.keys.size && left.keys[left_index] <= right.keys[right_index]
        source = take_left ? left : right
        row = take_left ? left_index : right_index
        merged_keys << source.keys[row]
        source.paths.each_with_index do |path, path_index|
          merged_values[path_index] << path.values[row]
        end
        if take_left
          left_index += 1
        else
          right_index += 1
        end
      end

      columns = @json_paths.each_with_index.map do |(name, type), index|
        WidePartWriter::JSONTypedPathColumn.new(name, type, merged_values[index])
      end.to_a
      {merged_keys, columns}
    end

    private def stable_merge(left : MergeInput, right : MergeInput) : {Array(UInt64), Array(String)}
      merged_keys = Array(UInt64).new(left.keys.size + right.keys.size)
      merged_values = Array(String).new(left.values.size + right.values.size)
      left_index = 0
      right_index = 0

      while left_index < left.keys.size || right_index < right.keys.size
        take_left = right_index >= right.keys.size ||
                    left_index < left.keys.size && left.keys[left_index] <= right.keys[right_index]
        if take_left
          merged_keys << left.keys[left_index]
          merged_values << left.values[left_index]
          left_index += 1
        else
          merged_keys << right.keys[right_index]
          merged_values << right.values[right_index]
          right_index += 1
        end
      end

      {merged_keys, merged_values}
    end

    private def next_merge_level(physical : Array(PhysicalPart), left : PhysicalPart, right : PhysicalPart) : UInt32
      max_level = {left.info.level, right.info.level}.max
      physical.each do |part|
        if part.info.min_block == left.info.min_block && part.info.max_block == right.info.max_block && part.info.level > max_level
          max_level = part.info.level
        end
      end
      raise BoundsError.new("embedded merge level is exhausted") if max_level >= MergeTreePartInfo::MAX_LEVEL
      max_level + 1_u32
    end

    private def read_part_metadata(part_path : String, name : String) : String
      path = File.join(part_path, name)
      size = File.size(path)
      raise UnsupportedFormatError.new("#{name} exceeds embedded table metadata limit") if size > MAX_METADATA_BYTES
      text = File.read(path)
      raise CorruptPartError.new("#{name} changed size while being read") unless text.bytesize.to_i64 == size
      text
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read committed part metadata")
    end

    private def validate_scan_request!(columns : Array(String), batch_rows : Int) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > WidePartTable::MAX_BATCH_ROWS
      raise UnsupportedFormatError.new("at least one embedded table column must be selected") if columns.empty?
      max_columns = @json_paths.empty? ? 2 : WidePartTable::MAX_COLUMNS
      raise UnsupportedFormatError.new("embedded table scan exceeds the selected-column limit") if columns.size > max_columns
      raise UnsupportedFormatError.new("selected embedded table columns must be distinct") unless columns.uniq.size == columns.size
      unless columns.all? { |column| !embedded_column_type(column).nil? }
        raise UnsupportedFormatError.new("selected column is not present in the embedded table")
      end
      nil
    end

    private def validate_pk_candidate_request!(columns : Array(String)) : Nil
      raise BoundsError.new("at least one embedded table column must be selected") if columns.empty?
      max_columns = @json_paths.empty? ? 2 : WidePartTable::MAX_COLUMNS
      raise BoundsError.new("embedded table scan exceeds the selected-column limit") if columns.size > max_columns
      raise BoundsError.new("selected embedded table columns must be distinct") unless columns.uniq.size == columns.size
      columns.each do |column|
        raise BoundsError.new("column name is empty or exceeds limit") if column.empty? || column.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        unless !embedded_column_type(column).nil?
          raise UnsupportedFormatError.new("selected column is not present in the embedded table")
        end
      end
      raise UnsupportedFormatError.new("selected columns must include the embedded primary key") unless columns.includes?(@key_name)
      nil
    end

    private def embedded_column_type(column : String) : String?
      return "UInt64" if column == @key_name
      return "String" if @json_paths.empty? && column == @value_name
      return nil if @json_paths.empty?

      path = @json_paths.find { |name, _type| column == "#{@value_name}.#{name}" }
      path.try(&.[1])
    end

    private def with_reader_lock(&)
      with_advisory_lock(LibC::FlockOp::SH, "r", "reader") { yield }
    end

    private def with_writer_lock(&)
      with_advisory_lock(LibC::FlockOp::EX, "r+", "writer") { yield }
    end

    private def with_advisory_lock(operation : LibC::FlockOp, access_mode : String, owner : String, &)
      {% if flag?(:darwin) %}
        validate_lock_path!
        File.open(File.join(@root, LOCK_FILE), access_mode) do |lock_file|
          descriptor = lock_file.fd.to_i32
          result = LibC.flock(descriptor.to_i, operation)
          raise IO::Error.from_errno("embedded table #{owner} lock failed") unless result == 0
          begin
            yield
          ensure
            unlock_result = LibC.flock(descriptor.to_i, LibC::FlockOp::UN)
            raise IO::Error.from_errno("embedded table #{owner} lock release failed") unless unlock_result == 0
          end
        end
      {% else %}
        raise UnsupportedFormatError.new("advisory embedded table #{owner} locks are supported only on Darwin")
      {% end %}
    end

    private def validate_lock_path! : Nil
      reject_symlink!(@root, "table root")
      raise InvalidPartError.new("embedded table root is not a directory") unless Dir.exists?(@root)
      lock = File.join(@root, LOCK_FILE)
      reject_symlink!(lock, "writer lock")
      raise UnsupportedFormatError.new("writer lock file is missing or not regular") unless File.file?(lock)
      nil
    end

    private def parts_path : String
      File.join(@root, "parts")
    end

    private def committed_path : String
      File.join(@root, "committed")
    end

    protected def self.read_manifest(root : String) : Schema
      path = File.join(root, MANIFEST_FILE)
      reject_symlink!(path, "manifest")
      raise UnsupportedFormatError.new("embedded table manifest is missing or not regular") unless File.file?(path)
      begin
        size = File.size(path)
        raise UnsupportedFormatError.new("embedded table manifest exceeds metadata limit") if size > MAX_MANIFEST_BYTES
        text = File.read(path)
        raise CorruptPartError.new("manifest changed size while being read") unless text.bytesize.to_i64 == size
        manifest = JSON.parse(text).as_h
        version = manifest["format_version"].as_i
        expected_keys = if version == FORMAT_VERSION
                          ["format_version", "key_name", "key_type", "partition", "value_name", "value_type"].sort
                        elsif version == JSON_FORMAT_VERSION
                          ["format_version", "json_paths", "key_name", "key_type", "partition", "value_name", "value_type"].sort
                        else
                          raise UnsupportedFormatError.new("unsupported embedded table format version")
                        end
        raise UnsupportedFormatError.new("embedded table manifest fields do not match its version") unless manifest.keys.sort == expected_keys
        raise UnsupportedFormatError.new("unsupported embedded table key type") unless manifest["key_type"].as_s == "UInt64"
        raise UnsupportedFormatError.new("unsupported embedded table partition") unless manifest["partition"].as_s == "all"
        key_name = manifest["key_name"].as_s
        value_name = manifest["value_name"].as_s
        validate_column_name(key_name)
        validate_column_name(value_name)
        raise UnsupportedFormatError.new("embedded table column names are not distinct") if key_name == value_name
        value_type = manifest["value_type"].as_s
        paths = [] of Tuple(String, String)
        if version == FORMAT_VERSION
          raise UnsupportedFormatError.new("unsupported embedded table payload type") unless value_type == "String"
        else
          paths = manifest["json_paths"].as_a.map do |entry|
            path_fields = entry.as_h
            unless path_fields.keys.sort == ["name", "type"]
              raise UnsupportedFormatError.new("embedded JSON path schema fields do not match")
            end
            {path_fields["name"].as_s, path_fields["type"].as_s}
          end
          paths = validate_json_schema!(key_name, value_name, paths)
          unless value_type == json_value_type(paths)
            raise UnsupportedFormatError.new("embedded JSON payload type does not match its path schema")
          end
        end
        Schema.new(version.to_i32, key_name, value_name, value_type, paths)
      rescue ex : JSON::ParseException | TypeCastError | KeyError | ArgumentError
        raise UnsupportedFormatError.new("embedded table manifest is malformed")
      end
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read embedded table manifest")
    end

    private def self.manifest_json(key_name : String, value_name : String) : String
      "{\"format_version\":1,\"key_name\":\"#{key_name}\",\"key_type\":\"UInt64\",\"partition\":\"all\",\"value_name\":\"#{value_name}\",\"value_type\":\"String\"}\n"
    end

    private def self.manifest_json_v2(key_name : String, value_name : String, paths : Array(Tuple(String, String))) : String
      encoded_paths = paths.map { |name, type| "{\"name\":\"#{name}\",\"type\":\"#{type}\"}" }.join(",")
      "{\"format_version\":2,\"json_paths\":[#{encoded_paths}],\"key_name\":\"#{key_name}\",\"key_type\":\"UInt64\",\"partition\":\"all\",\"value_name\":\"#{value_name}\",\"value_type\":\"#{json_value_type(paths)}\"}\n"
    end

    private def self.json_value_type(paths : Array(Tuple(String, String))) : String
      "JSON(#{paths.map { |name, type| "#{name} #{type}" }.join(", ")})"
    end

    private def self.validate_json_schema!(
      key_name : String,
      value_name : String,
      paths : Array(Tuple(String, String)),
    ) : Array(Tuple(String, String))
      raise ArgumentError.new("JSON typed-path declaration must be nonempty") if paths.empty?
      raise ArgumentError.new("embedded JSON schema exceeds the selected-column limit") if paths.size > MAX_JSON_PATHS

      canonical = paths.sort_by { |name, _type| name }
      seen = Set(String).new
      canonical.each do |name, type|
        unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES && /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
          raise ArgumentError.new("JSON typed-path name must be a bounded simple identifier")
        end
        raise ArgumentError.new("duplicate JSON typed path") unless seen.add?(name)
        unless type == "String" || WidePart.supports_numeric_type?(type)
          raise ArgumentError.new("JSON typed-path type must be an exact supported scalar")
        end
      end

      declaration_bytes = canonical.sum { |name, type| name.bytesize + 1 + type.bytesize }
      metadata_line_bytes = "`#{value_name}` JSON(".bytesize + declaration_bytes + 2 * (canonical.size - 1) + ")\n".bytesize
      raise ArgumentError.new("JSON typed-path metadata line exceeds reader limit") if metadata_line_bytes > WidePart::MAX_METADATA_LINE_BYTES

      declaration = canonical.map { |name, type| "#{name} #{type}" }.join(", ")
      columns_metadata = "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` JSON(#{declaration})\n"
      raise ArgumentError.new("embedded JSON columns metadata exceeds table limit") if columns_metadata.bytesize.to_i64 > MAX_METADATA_BYTES

      logical_names = [key_name, "#{value_name}.object_structure"]
      canonical.each do |name, type|
        logical_name = "#{value_name}.#{name}"
        logical_names << "#{logical_name}.size" if type == "String"
        logical_names << logical_name
      end
      logical_names.concat([
        "#{value_name}.object_shared_data.0.size0",
        "#{value_name}.object_shared_data.0%2Epaths",
        "#{value_name}.object_shared_data.0%2Evalues",
      ])
      logical_names.each do |name|
        raise ArgumentError.new("physical stream name exceeds reader limit") if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
      end
      stream_bases = logical_names.map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      substreams_metadata = String.build do |text|
        text << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        text << "#{logical_names.size - 1} substreams for column `#{value_name}`:\n"
        logical_names[1..].each { |name| text << "\t#{name}\n" }
      end
      if substreams_metadata.bytesize.to_i64 > MAX_METADATA_BYTES || substreams_metadata.bytesize.to_i64 > WidePart::MAX_METADATA_FILE_BYTES
        raise ArgumentError.new("embedded JSON substream metadata exceeds table limit")
      end

      result = manifest_json_v2(key_name, value_name, canonical)
      raise ArgumentError.new("embedded table manifest exceeds metadata limit") if result.bytesize.to_i64 > MAX_MANIFEST_BYTES
      canonical
    end

    private def self.validate_column_name(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES && /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("column name must be a bounded ASCII identifier")
      end
      nil
    end

    private def self.reject_symlink!(path : String, label : String) : Nil
      raise CorruptPartError.new("#{label} must not be a symbolic link") if File.symlink?(path)
      nil
    end

    private def parse_part_name(name : String) : MergeTreePartInfo
      info = MergeTreePartInfo.parse(name)
      raise CorruptPartError.new("malformed embedded part name") unless info
      info.not_nil!
    end

    private def validate_part_name!(name : String, info : MergeTreePartInfo, label : String = "physical part") : Nil
      bounded_shape = info.partition_id == "all" && info.min_block > 0 && info.mutation == 0 &&
                      if info.min_block == info.max_block
                        info.level == 0
                      else
                        info.level > 0 && info.level <= MergeTreePartInfo::MAX_LEVEL
                      end
      unless bounded_shape && name == canonical_part_name(info.min_block, info.max_block, info.level)
        raise CorruptPartError.new("#{label} name is outside the bounded W5 format")
      end
      nil
    end

    private def canonical_part_name(min_block : Int64, max_block : Int64, level : UInt32) : String
      "all_#{min_block}_#{max_block}_#{level}"
    end

    private def reject_ambiguous_marked_intervals!(parts : Array(PhysicalPart)) : Nil
      parts.each_with_index do |part, index|
        parts[(index + 1)..].each do |other|
          next unless part.info.overlaps?(other.info)
          unless strictly_contains?(part.info, other.info) || strictly_contains?(other.info, part.info)
            raise CorruptPartError.new("marked part intervals overlap ambiguously")
          end
        end
      end
      nil
    end

    private def strictly_contains?(outer : MergeTreePartInfo, inner : MergeTreePartInfo) : Bool
      outer.partition_id == inner.partition_id &&
        outer.min_block <= inner.min_block &&
        outer.max_block >= inner.max_block &&
        (outer.min_block < inner.min_block || outer.max_block > inner.max_block)
    end

    private def contains_or_equals?(outer : MergeTreePartInfo, inner : MergeTreePartInfo) : Bool
      outer.partition_id == inner.partition_id &&
        outer.min_block <= inner.min_block &&
        outer.max_block >= inner.max_block
    end

    private def self.create_stage(parent : String) : String
      8.times do
        candidate = File.tempname("#{TABLE_STAGE_PREFIX}", nil, dir: parent)
        next if File.exists?(candidate) || File.symlink?(candidate)
        begin
          Dir.mkdir(candidate)
          return candidate
        rescue ex : File::Error
          raise ex unless Errno.value == Errno::EEXIST
        end
      end
      raise IO::Error.new("cannot allocate a unique embedded table staging directory")
    end

    private def self.publish_root_exclusively(stage : String, target : String) : Nil
      {% if flag?(:darwin) %}
        result = LibEmbeddedMergeTreeTableAtomicPublish.renamex_np(stage.to_unsafe, target.to_unsafe, RENAME_EXCL)
        if result != 0
          raise ArgumentError.new("root already exists") if Errno.value == Errno::EEXIST
          raise IO::Error.from_errno("atomic embedded table publish failed")
        end
      {% else %}
        raise UnsupportedFormatError.new("atomic exclusive table publication is supported only on Darwin")
      {% end %}
      nil
    end

    private def self.darwin? : Bool
      {% if flag?(:darwin) %}
        true
      {% else %}
        false
      {% end %}
    end
  end
end
