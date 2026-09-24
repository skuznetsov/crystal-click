require "file_utils"
require "json"

module CrystalClick
  # A Crystal-owned table over immutable W3 UInt64/String Wide parts.
  #
  # Visibility is selected by an empty directory under `committed/`. This is
  # process-atomic for cooperating writers on a local Darwin filesystem; it is
  # not a ClickHouse server table or a power-loss durability protocol.
  class EmbeddedMergeTreeTable
    FORMAT_VERSION        =         1
    MAX_COLUMN_NAME_BYTES =       128
    MAX_MANIFEST_BYTES    = 4_096_i64
    MAX_METADATA_BYTES    = 4_096_i64
    MAX_CHECKSUMS_BYTES   = 64_i64 * 1024
    MAX_PARTS             = WidePartTable::MAX_PARTS
    WRITER_STAGE_PREFIX   = ".crystal-click-wide-writer-"
    TABLE_STAGE_PREFIX    = ".crystal-click-embedded-table-"
    LOCK_FILE             = "writer.lock"
    MANIFEST_FILE         = "manifest.json"
    RENAME_EXCL           = 0x0000_0004_u32

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

    @root : String
    @key_name : String
    @value_name : String

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

    def self.open(root : String) : EmbeddedMergeTreeTable
      raise InvalidPartError.new("embedded table root must not be empty") if root.empty?
      target = File.expand_path(root)
      reject_symlink!(target, "table root")
      raise InvalidPartError.new("embedded table root is not a directory") unless Dir.exists?(target)

      manifest = read_manifest(target)
      table = new(target, manifest[0], manifest[1])
      table.part_paths
      table
    end

    def key_name : String
      @key_name.dup
    end

    def value_name : String
      @value_name.dup
    end

    # Return paths for the currently committed, structurally valid parts.
    # The inventory is resolved anew for each call.
    def part_paths : Array(String)
      with_reader_lock do
        committed, _orphans, _physical = inventory
        committed.map(&.path)
      end
    end

    # Return complete unmarked parts and recognizable writer staging
    # directories. They are never adopted or removed automatically.
    def orphan_part_names : Array(String)
      with_reader_lock do
        _committed, orphans, _physical = inventory
        orphans
      end
    end

    # Publish one sorted UInt64/String part and then its exclusive commit
    # marker. A part whose marker publication fails remains an invisible
    # orphan and keeps its allocated block number.
    def insert(keys : Slice(UInt64), values : Slice(String), rows_per_mark : Int32 = 8192) : String
      validate_insert_inputs(keys, values, rows_per_mark)
      validate_layout!

      with_writer_lock do
        committed, orphans, physical = inventory
        raise BoundsError.new("embedded table exceeds part limit") if committed.size >= MAX_PARTS
        # The inventory cap includes both physical parts and interrupted
        # writer staging directories. Do not make a currently readable root
        # exceed that cap by publishing another physical part.
        raise BoundsError.new("embedded table exceeds physical entry limit") if committed.size + orphans.size >= MAX_PARTS * 2

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
        part_name
      end
    end

    # Validate the selection even on an empty table, where there is no part
    # reader available to perform the usual type/column checks.
    def scan_typed(columns : Array(String), batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      validate_scan_request!(columns, batch_rows)
      committed, _orphans, _physical = with_reader_lock { inventory }
      return nil if committed.empty?

      table = WidePartTable.open_selected_typed(committed.map(&.path), columns)
      table.scan_typed(batch_rows) { |batch| yield batch }
      nil
    end

    private def initialize(@root : String, @key_name : String, @value_name : String)
    end

    private def reject_symlink!(path : String, label : String) : Nil
      raise CorruptPartError.new("#{label} must not be a symbolic link") if File.symlink?(path)
      nil
    end

    private def validate_layout! : Nil
      reject_symlink!(@root, "table root")
      raise InvalidPartError.new("embedded table root is not a directory") unless Dir.exists?(@root)

      manifest_path = File.join(@root, MANIFEST_FILE)
      reject_symlink!(manifest_path, "manifest")
      raise UnsupportedFormatError.new("embedded table manifest is missing") unless File.file?(manifest_path)
      manifest = self.class.read_manifest(@root)
      unless manifest[0] == @key_name && manifest[1] == @value_name
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

    private def inventory : {Array(PhysicalPart), Array(String), Array(PhysicalPart)}
      validate_layout!

      physical = [] of PhysicalPart
      orphan_names = [] of String
      parts_children = Dir.children(parts_path)
      raise BoundsError.new("embedded table exceeds physical part limit") if parts_children.size > MAX_PARTS * 2
      parts_children.each do |name|
        path = File.join(parts_path, name)
        reject_symlink!(path, "part or staging entry")
        if name.starts_with?(WRITER_STAGE_PREFIX)
          raise CorruptPartError.new("writer staging entry is not a directory") unless Dir.exists?(path)
          orphan_names << name
          next
        end

        info = parse_part_name(name)
        raise CorruptPartError.new("physical part entry is not a directory") unless Dir.exists?(path)
        physical << PhysicalPart.new(name, path, info)
      end

      reject_overlapping_parts!(physical)
      physical.each do |part|
        unless part.info.partition_id == "all" && part.info.min_block == part.info.max_block &&
               part.info.min_block > 0 && part.info.level == 0 && part.info.mutation == 0 &&
               part.name == canonical_part_name(part.info.max_block)
          raise CorruptPartError.new("physical part name is outside the bounded W4 format")
        end
      end

      marker_names = Dir.children(committed_path)
      raise BoundsError.new("embedded table exceeds committed part limit") if marker_names.size > MAX_PARTS
      marked = Set(String).new
      marker_names.each do |name|
        info = parse_part_name(name)
        unless info.partition_id == "all" && info.min_block == info.max_block &&
               info.min_block > 0 && info.level == 0 && info.mutation == 0 &&
               name == canonical_part_name(info.max_block)
          raise CorruptPartError.new("commit marker name is outside the bounded W4 format")
        end
        marker_path = File.join(committed_path, name)
        reject_symlink!(marker_path, "commit marker")
        raise CorruptPartError.new("commit marker is not a directory") unless Dir.exists?(marker_path)
        raise CorruptPartError.new("commit marker must be empty") unless Dir.children(marker_path).empty?
        raise CorruptPartError.new("duplicate commit marker") unless marked.add?(name)
      end

      physical_by_name = physical.to_h { |part| {part.name, part} }
      marked.each do |name|
        part = physical_by_name[name]?
        raise CorruptPartError.new("commit marker has no physical part") unless part
        validate_part!(part.not_nil!)
      end
      physical.each { |part| orphan_names << part.name unless marked.includes?(part.name) }

      committed = marked.map { |name| physical_by_name[name].not_nil! }
      committed.sort_by! { |part| {part.info.min_block, part.info.max_block, part.info.name} }
      orphan_names.sort!
      {committed, orphan_names, physical}
    end

    private def validate_part!(part : PhysicalPart) : Nil
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

    private def validate_insert_inputs(keys : Slice(UInt64), values : Slice(String), rows_per_mark : Int32) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end
      nil
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
      raise UnsupportedFormatError.new("embedded table scan supports at most two columns") if columns.size > 2
      raise UnsupportedFormatError.new("selected embedded table columns must be distinct") unless columns.uniq.size == columns.size
      unless columns.all? { |column| column == @key_name || column == @value_name }
        raise UnsupportedFormatError.new("selected column is not present in the embedded table")
      end
      nil
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

    protected def self.read_manifest(root : String) : {String, String}
      path = File.join(root, MANIFEST_FILE)
      reject_symlink!(path, "manifest")
      raise UnsupportedFormatError.new("embedded table manifest is missing or not regular") unless File.file?(path)
      begin
        size = File.size(path)
        raise UnsupportedFormatError.new("embedded table manifest exceeds metadata limit") if size > MAX_MANIFEST_BYTES
        text = File.read(path)
        raise CorruptPartError.new("manifest changed size while being read") unless text.bytesize.to_i64 == size
        manifest = JSON.parse(text).as_h
        expected_keys = ["format_version", "key_name", "key_type", "partition", "value_name", "value_type"].sort
        raise UnsupportedFormatError.new("embedded table manifest fields do not match W4") unless manifest.keys.sort == expected_keys
        raise UnsupportedFormatError.new("unsupported embedded table format version") unless manifest["format_version"].as_i == FORMAT_VERSION
        raise UnsupportedFormatError.new("unsupported embedded table key type") unless manifest["key_type"].as_s == "UInt64"
        raise UnsupportedFormatError.new("unsupported embedded table payload type") unless manifest["value_type"].as_s == "String"
        raise UnsupportedFormatError.new("unsupported embedded table partition") unless manifest["partition"].as_s == "all"
        key_name = manifest["key_name"].as_s
        value_name = manifest["value_name"].as_s
        validate_column_name(key_name)
        validate_column_name(value_name)
        raise UnsupportedFormatError.new("embedded table column names are not distinct") if key_name == value_name
        {key_name, value_name}
      rescue ex : JSON::ParseException | TypeCastError | KeyError
        raise UnsupportedFormatError.new("embedded table manifest is malformed")
      end
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read embedded table manifest")
    end

    private def self.manifest_json(key_name : String, value_name : String) : String
      "{\"format_version\":1,\"key_name\":\"#{key_name}\",\"key_type\":\"UInt64\",\"partition\":\"all\",\"value_name\":\"#{value_name}\",\"value_type\":\"String\"}\n"
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

    private def canonical_part_name(block : Int64) : String
      "all_#{block}_#{block}_0"
    end

    private def reject_overlapping_parts!(parts : Array(PhysicalPart)) : Nil
      parts.each_with_index do |part, index|
        parts[(index + 1)..].each do |other|
          if part.info.overlaps?(other.info)
            raise CorruptPartError.new("embedded physical parts overlap")
          end
        end
      end
      nil
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
