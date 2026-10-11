require "../src/crystal_click"
require "digest/sha256"
require "json"
require "./support/static_recursive_selected_metadata_w258_fixture"

module CheckStaticRecursiveSelectedMetadataW258
  FORMAT         = "static_recursive_selected_metadata_w258_roundtrip_v1"
  WRITER_PROFILE = {
    ordinary_string:       "with_size_stream",
    shared_string:         "single_stream",
    variant_discriminator: "BASIC",
    frame_bytes:           32,
    rows_per_mark:         StaticRecursiveSelectedMetadataW258Fixture::ROWS_PER_MARK,
  }
  KEY_COUNT      = 8_u64
  MAX_PART_BYTES = 64_u64 * 1024 * 1024
  MAX_PART_FILES = 4096
  COLUMNS        = [
    StaticRecursiveSelectedMetadataW258Fixture::U_COLUMN,
    StaticRecursiveSelectedMetadataW258Fixture::SIDE_COLUMN,
    StaticRecursiveSelectedMetadataW258Fixture::ARRAY_COLUMN,
    StaticRecursiveSelectedMetadataW258Fixture::TUPLE_COLUMN,
    StaticRecursiveSelectedMetadataW258Fixture::LOW_CARDINALITY_COLUMN,
    StaticRecursiveSelectedMetadataW258Fixture::VARIANT_COLUMN,
  ]

  def self.hex(value : String) : String
    String.build do |io|
      value.to_slice.each do |byte|
        io << byte.to_s(16).rjust(2, '0')
      end
    end
  end

  def self.variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
    case value
    when String
      "variant<String>(string:#{hex(value)})"
    when UInt64
      "variant<UInt64>(uint64:#{value})"
    else
      "variant<NULL>(null)"
    end
  end

  def self.append_public_batch(
    batch : CrystalClick::WidePartTableBatch,
    signatures : Hash(String, Array(String)),
    expected_rows : Int32,
  ) : Nil
    raise CrystalClick::CorruptPartError.new("W258 pk batch has an unexpected row count") unless batch.values_for("pk", UInt64).size == expected_rows

    batch.values_for(StaticRecursiveSelectedMetadataW258Fixture::U_COLUMN, UInt64).each do |value|
      signatures[StaticRecursiveSelectedMetadataW258Fixture::U_COLUMN] << "uint64:#{value}"
    end
    batch.strings_for(StaticRecursiveSelectedMetadataW258Fixture::SIDE_COLUMN).each do |value|
      signatures[StaticRecursiveSelectedMetadataW258Fixture::SIDE_COLUMN] << "string:#{hex(value)}"
    end
    batch.array_nullable_uint64s_for(StaticRecursiveSelectedMetadataW258Fixture::ARRAY_COLUMN).each do |row|
      children = row.map { |value| value ? "uint64:#{value}" : "null" }
      signatures[StaticRecursiveSelectedMetadataW258Fixture::ARRAY_COLUMN] << "array[#{children.join(',')}]"
    end
    batch.tuple_rows_for(StaticRecursiveSelectedMetadataW258Fixture::TUPLE_COLUMN).each do |row|
      n = row.value_as("n", UInt64)
      s = row.value_as("s", String)
      signatures[StaticRecursiveSelectedMetadataW258Fixture::TUPLE_COLUMN] <<
        "tuple[uint64:#{n},string:#{hex(s)}]"
    end
    batch.low_cardinality_strings_for(StaticRecursiveSelectedMetadataW258Fixture::LOW_CARDINALITY_COLUMN).each do |value|
      signatures[StaticRecursiveSelectedMetadataW258Fixture::LOW_CARDINALITY_COLUMN] << "string:#{hex(value)}"
    end
    batch.variant_string_uint64_for(StaticRecursiveSelectedMetadataW258Fixture::VARIANT_COLUMN).each do |value|
      signatures[StaticRecursiveSelectedMetadataW258Fixture::VARIANT_COLUMN] << variant_signature(value)
    end

    COLUMNS.each do |column|
      unless signatures[column].size <= KEY_COUNT.to_i
        raise CrystalClick::CorruptPartError.new("W258 typed accessor returned excess rows for #{column}")
      end
    end
    nil
  end

  def self.read_public_window(
    table : CrystalClick::WidePartTable,
    start_row : UInt64,
    max_rows : Int32,
  ) : NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String)))
    keys = [] of UInt64
    signatures = Hash(String, Array(String)).new do |values, name|
      values[name] = [] of String
    end
    table.scan_typed_window(start_row, max_rows) do |batch|
      batch_keys = batch.values_for("pk", UInt64)
      keys.concat(batch_keys)
      append_public_batch(batch, signatures, batch_keys.size)
    end
    {keys: keys, columns: signatures}
  end

  def self.offline_signature(column : String, value : CrystalClick::OfflineColumnValue) : String
    case column
    when StaticRecursiveSelectedMetadataW258Fixture::U_COLUMN
      "uint64:#{value.as(UInt64)}"
    when StaticRecursiveSelectedMetadataW258Fixture::SIDE_COLUMN,
         StaticRecursiveSelectedMetadataW258Fixture::LOW_CARDINALITY_COLUMN
      "string:#{hex(value.as(String))}"
    when StaticRecursiveSelectedMetadataW258Fixture::ARRAY_COLUMN
      children = value.as(Array(UInt64?)).map { |child| child ? "uint64:#{child}" : "null" }
      "array[#{children.join(',')}]"
    when StaticRecursiveSelectedMetadataW258Fixture::TUPLE_COLUMN
      row = value.as(CrystalClick::WideTupleRow)
      n = row.value_as("n", UInt64)
      s = row.value_as("s", String)
      "tuple[uint64:#{n},string:#{hex(s)}]"
    when StaticRecursiveSelectedMetadataW258Fixture::VARIANT_COLUMN
      case value
      when String
        "variant<String>(string:#{hex(value)})"
      when UInt64
        "variant<UInt64>(uint64:#{value})"
      when Nil
        "variant<NULL>(null)"
      else
        raise CrystalClick::UnsupportedFormatError.new("W258 offline Variant accessor returned an unexpected value")
      end
    else
      raise CrystalClick::UnsupportedFormatError.new("W258 offline signature does not support column #{column}")
    end
  end

  def self.read_offline(part : String) : NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String)))
    columns = [CrystalClick::OfflineColumn.new("pk", "UInt64")] of CrystalClick::OfflineColumn
    StaticRecursiveSelectedMetadataW258Fixture.types.each do |name, type|
      columns << CrystalClick::OfflineColumn.new(name, type.name)
    end
    info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
    candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, KEY_COUNT)
    table = CrystalClick::OfflineTable.new(
      "events",
      "w258-selected-metadata",
      "MergeTree",
      columns,
      [candidate] of CrystalClick::OfflinePartCandidate,
      "pk",
    )

    keys = table["pk"].values(max_rows: KEY_COUNT).map(&.as(UInt64))
    signatures = Hash(String, Array(String)).new
    COLUMNS.each do |name|
      values = table[name].values(max_rows: KEY_COUNT)
      unless values.size == keys.size
        raise CrystalClick::CorruptPartError.new("W258 offline #{name} value count differs from key count")
      end
      signatures[name] = values.map { |value| offline_signature(name, value) }
    end
    {keys: keys, columns: signatures}
  end

  def self.part_files(part : String) : Array(NamedTuple(path: String, bytes: UInt64, sha256: String))
    expanded = File.expand_path(part)
    expanded = expanded == "/" ? expanded : expanded.rstrip('/')
    relative_prefix = expanded == "/" ? expanded : "#{expanded}/"
    unless Dir.exists?(expanded) && !File.symlink?(expanded)
      raise CrystalClick::InvalidPartError.new("W258 part must be an existing non-symlink directory")
    end

    files = [] of String
    pending = [expanded]
    until pending.empty?
      directory = pending.pop
      Dir.children(directory).each do |name|
        path = File.join(directory, name)
        if File.symlink?(path)
          raise CrystalClick::InvalidPartError.new("W258 part contains a symlink")
        elsif Dir.exists?(path)
          pending << path
        elsif File.file?(path)
          files << path
        else
          raise CrystalClick::InvalidPartError.new("W258 part contains a non-regular entry")
        end
      end
    end
    files.sort!
    raise CrystalClick::InvalidPartError.new("W258 part file inventory exceeds its entry bound") if files.size > MAX_PART_FILES
    total = 0_u64
    result = [] of NamedTuple(path: String, bytes: UInt64, sha256: String)
    files.each do |path|
      if File.symlink?(path)
        raise CrystalClick::InvalidPartError.new("W258 part contains a symlink")
      end
      size = File.size(path).to_u64
      if size > MAX_PART_BYTES || total > MAX_PART_BYTES - size
        raise CrystalClick::InvalidPartError.new("W258 part inventory exceeds its byte bound")
      end
      total += size
      contents = File.read(path)
      unless path.starts_with?(relative_prefix)
        raise CrystalClick::InvalidPartError.new("W258 part file escaped its canonical directory")
      end
      relative = path[relative_prefix.bytesize, path.bytesize - relative_prefix.bytesize]
      result << {path: relative, bytes: size, sha256: Digest::SHA256.hexdigest(contents.to_slice)}
    end
    result
  end

  def self.inspect_part(path : String, label : String) : NamedTuple(
    label: String,
    path: String,
    keys: Array(UInt64),
    mark_row_counts: Array(UInt64),
    full_public: NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String))),
    middle_public: NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String))),
    eof_callbacks: Int32,
    offline: NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String))),
    files: Array(NamedTuple(path: String, bytes: UInt64, sha256: String)),
  )
    expanded = File.expand_path(path)
    table = CrystalClick::WidePartTable.open_selected_typed(
      [expanded],
      ["pk"] + COLUMNS,
    )
    full = read_public_window(table, 0_u64, KEY_COUNT.to_i32)
    middle = read_public_window(table, 2_u64, 4)
    eof_callbacks = 0
    table.scan_typed_window(KEY_COUNT, 4) do |_batch|
      eof_callbacks += 1
    end
    unless eof_callbacks == 0
      raise CrystalClick::CorruptPartError.new("W258 EOF window unexpectedly yielded a callback")
    end

    offline = read_offline(expanded)
    key_reader = CrystalClick::WidePart.open_typed(expanded, "pk")
    keys = key_reader.read_numeric_mark_range("pk", 0, key_reader.mark_count, UInt64)
    unless keys.size == KEY_COUNT.to_i
      raise CrystalClick::CorruptPartError.new("W258 key stream row count differs from its fixture")
    end

    {label: label, path: expanded, keys: keys, mark_row_counts: key_reader.mark_row_counts,
     full_public: full, middle_public: middle, eof_callbacks: eof_callbacks,
     offline: offline, files: part_files(expanded)}
  end

  def self.write_string_array(json : JSON::Builder, values : Array(String)) : Nil
    json.array do
      values.each { |value| json.string(value) }
    end
  end

  def self.write_scan(json : JSON::Builder, scan : NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String)))) : Nil
    json.object do
      json.field "keys", scan[:keys]
      json.field "columns" do
        json.object do
          COLUMNS.each do |column|
            json.field column do
              write_string_array(json, scan[:columns][column])
            end
          end
        end
      end
    end
  end

  def self.write_part_report(json : JSON::Builder, report : NamedTuple(
                               label: String,
                               path: String,
                               keys: Array(UInt64),
                               mark_row_counts: Array(UInt64),
                               full_public: NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String))),
                               middle_public: NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String))),
                               eof_callbacks: Int32,
                               offline: NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String))),
                               files: Array(NamedTuple(path: String, bytes: UInt64, sha256: String)),
                             )) : Nil
    json.object do
      json.field "label", report[:label]
      json.field "path", report[:path]
      json.field "keys", report[:keys]
      json.field "mark_row_counts", report[:mark_row_counts]
      json.field "full_public" do
        write_scan(json, report[:full_public])
      end
      json.field "middle_public" do
        write_scan(json, report[:middle_public])
      end
      json.field "eof_callbacks", report[:eof_callbacks]
      json.field "offline" do
        write_scan(json, report[:offline])
      end
      json.field "files" do
        json.array do
          report[:files].each do |file|
            json.object do
              json.field "path", file[:path]
              json.field "bytes", file[:bytes]
              json.field "sha256", file[:sha256]
            end
          end
        end
      end
    end
  end

  def self.run : Nil
    unless ARGV.size == 3 && ARGV[0] == "roundtrip"
      STDERR.puts "usage: check_static_recursive_selected_metadata_w258.cr roundtrip STOCK_PART LIBRARY_PART"
      exit(2)
    end
    stock_part = File.expand_path(ARGV[1])
    library_part = File.expand_path(ARGV[2])
    if File.exists?(library_part) || File.symlink?(library_part)
      raise CrystalClick::InvalidPartError.new("W258 library output destination already exists")
    end
    unless Dir.exists?(File.dirname(library_part))
      raise CrystalClick::InvalidPartError.new("W258 library output parent directory is absent")
    end

    StaticRecursiveSelectedMetadataW258Fixture.write_part(library_part)
    stock = inspect_part(stock_part, "stock_wide")
    library = inspect_part(library_part, "library_wide")
    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "writer_profile" do
          json.object do
            json.field "ordinary_string", WRITER_PROFILE[:ordinary_string]
            json.field "shared_string", WRITER_PROFILE[:shared_string]
            json.field "variant_discriminator", WRITER_PROFILE[:variant_discriminator]
            json.field "frame_bytes", WRITER_PROFILE[:frame_bytes]
            json.field "rows_per_mark", WRITER_PROFILE[:rows_per_mark]
          end
        end
        json.field "key_column", "pk"
        json.field "stock" do
          write_part_report(json, stock)
        end
        json.field "library" do
          write_part_report(json, library)
        end
      end
    end
    STDOUT << '\n'
    nil
  end
end

CheckStaticRecursiveSelectedMetadataW258.run
