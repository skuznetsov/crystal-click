require "../src/crystal_click"
require "json"
require "./support/dynamic_recursive_handoff_w249_fixture"

module CheckDynamicStructureVersionsW250
  extend self

  FORMAT = "dynamic_structure_versions_w250_audit_v1"

  private def fail!(message : String) : NoReturn
    raise CrystalClick::CorruptPartError.new("W250 structure audit: #{message}")
  end

  private def require!(condition : Bool, message : String) : Nil
    fail!(message) unless condition
  end

  private class Cursor
    @bytes : Bytes
    @offset : Int32

    def initialize(@bytes : Bytes)
      @offset = 0
    end

    private def fail!(message : String) : NoReturn
      raise CrystalClick::CorruptPartError.new("W250 structure audit: #{message}")
    end

    def offset : Int32
      @offset
    end

    def remaining : Int32
      @bytes.size - @offset
    end

    def read_byte : UInt8
      fail!("truncated Dynamic structure") if @offset >= @bytes.size
      value = @bytes[@offset]
      @offset += 1
      value
    end

    def read_u64_le : UInt64
      value = 0_u64
      8.times do |index|
        value |= read_byte.to_u64 << (index * 8)
      end
      value
    end

    def read_var_uint : UInt64
      value = 0_u64
      shift = 0
      loop do
        byte = read_byte
        payload = (byte & 0x7f_u8).to_u64
        if shift > 63 || (shift == 63 && payload > 1_u64)
          fail!("Dynamic VarUInt exceeds UInt64")
        end
        value |= payload << shift
        if (byte & 0x80_u8) == 0_u8
          fail!("Dynamic VarUInt is not minimally encoded") if shift > 0 && payload == 0_u64
          return value
        end
        shift += 7
        fail!("Dynamic VarUInt exceeds ten bytes") if shift >= 70
      end
    end

    def read_string_binary : String
      size = read_var_uint
      if size > remaining.to_u64 || size > Int32::MAX.to_u64
        fail!("Dynamic type/statistics string exceeds its structure stream")
      end
      finish = @offset + size.to_i32
      value = String.new(@bytes[@offset, size.to_i32])
      @offset = finish
      fail!("Dynamic type/statistics string is not valid UTF-8") unless value.valid_encoding?
      value
    end

    def ensure_consumed! : Nil
      fail!("Dynamic structure has trailing bytes") unless @offset == @bytes.size
    end
  end

  private def audit(part : String) : JSON::Any
    source = CrystalClick::PartStreamSource.new(part)
    columns = DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.map do |name|
      audit_column(source, part, name)
    end
    report = Hash(String, JSON::Any).new
    report["format"] = JSON::Any.new(FORMAT)
    report["part_path"] = JSON::Any.new(File.expand_path(part))
    report["columns"] = JSON::Any.new(columns)
    JSON::Any.new(report)
  end

  private def versioned_structures(name : String, version : UInt64) : Hash(String, CrystalClick::DynamicStructure)
    fixture = DynamicRecursiveHandoffW249Fixture
    actual_types = [CrystalClick::BinaryDataType.primitive("Int64")] of CrystalClick::BinaryDataType
    observed = observed_counts_by_site(name)
    structures = Hash(String, CrystalClick::DynamicStructure).new
    fixture.dynamic_sites[name].each do |site|
      counts = observed[site[:path]]
      ordinary_names = actual_types.map(&.name)
      shared_counts = counts.reject { |type_name, _count| ordinary_names.includes?(type_name) }
      canonical_names = (ordinary_names + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
      variant_counts = canonical_names.map do |variant_name|
        if variant_name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME
          shared_counts.values.sum(0_u64) { |count| count }
        else
          counts[variant_name]? || 0_u64
        end
      end
      shared = shared_counts.map do |type_name, count|
        CrystalClick::StructureStatistic.new(type_name, count)
      end.sort_by(&.name)
      statistics = CrystalClick::StructureStatistics.new(variant_counts, shared)
      structures[site[:path]] = CrystalClick::DynamicStructure.new(
        actual_types,
        statistics,
        version: version,
        legacy_max_dynamic_types: version == CrystalClick::DynamicStructure::VERSION_V1 ? actual_types.size.to_u64 : nil,
      )
    end
    structures
  end

  private def versioned_columns(version : UInt64) : Array(CrystalClick::WidePartColumn)
    fixture = DynamicRecursiveHandoffW249Fixture
    DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.map do |name|
      CrystalClick::WidePartColumn.dynamic_bulk(
        name,
        fixture.column_types[name],
        versioned_structures(name, version),
        fixture.marks(fixture.rows_for(name)),
      )
    end
  end

  private def write_versioned_part(part : String, profile_name : String, version_name : String) : JSON::Any
    fixture = DynamicRecursiveHandoffW249Fixture
    version = case version_name
              when "v1" then CrystalClick::DynamicStructure::VERSION_V1
              when "v2" then CrystalClick::DynamicStructure::VERSION_V2
              else           fail!("writer version must be v1 or v2")
              end
    profile = fixture.profile(profile_name)
    CrystalClick::WidePartWriter.write_uint64_columns(
      part,
      DynamicRecursiveHandoffW249Fixture::KEY_NAME,
      DynamicRecursiveHandoffW249Fixture::KEYS.to_unsafe.to_slice(DynamicRecursiveHandoffW249Fixture::KEYS.size),
      versioned_columns(version),
      rows_per_mark: DynamicRecursiveHandoffW249Fixture::ROWS_PER_MARK,
      profile: profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: DynamicRecursiveHandoffW249Fixture::FRAME_BYTES,
    )

    keys = CrystalClick::WidePart.open_typed(part, DynamicRecursiveHandoffW249Fixture::KEY_NAME).read_uint64
    require!(keys == DynamicRecursiveHandoffW249Fixture::KEYS, "versioned writer changed fixture primary keys")
    values = Hash(String, Array(CrystalClick::BinaryValue)).new
    profiles = [] of String
    DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
      type = fixture.column_types[name]
      reader = CrystalClick::DynamicBulkColumnReader.open(part, name, type)
      require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
        "versioned writer nominal declaration differs for #{name}")
      require!(reader.mark_row_counts == DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS,
        "versioned writer mark grid differs for #{name}")
      profiles << fixture.profile_name(reader.ordinary_profile)
      values[name] = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
      require!(values[name].size == keys.size, "versioned writer row count differs for #{name}")
    end
    require!(profiles.uniq == [fixture.profile_name(profile)], "versioned writer String profile differs")

    rows = Array(JSON::Any).new(keys.size)
    keys.each_with_index do |key, index|
      row_values = Hash(String, CrystalClick::BinaryValue).new
      DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| row_values[name] = values[name][index] }
      rows << fixture.row_record(key, row_values)
    end
    require!(fixture.rows_equal?(rows, fixture.expected_rows), "versioned writer direct values differ from literal fixture")

    columns = DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.map do |name|
      observed = fixture.observed_types_by_site(name, values[name])
      sites = fixture.dynamic_sites[name].map do |site|
        JSON::Any.new({
          "path"                    => JSON::Any.new(site[:path]),
          "registered_actual_types" => json_strings(site[:registered_actual_types]),
          "observed_actual_types"   => json_strings(observed[site[:path]]),
        } of String => JSON::Any)
      end
      JSON::Any.new({
        "name"          => JSON::Any.new(name),
        "type"          => JSON::Any.new(fixture.column_types[name].name),
        "dynamic_sites" => JSON::Any.new(sites),
      } of String => JSON::Any)
    end
    observed_rows = Hash(String, JSON::Any).new
    observed_rows["direct_reader"] = JSON::Any.new(rows)
    ["table_full_scan", "table_window", "table_candidate_marks", "offline_values"].each do |consumer|
      observed_rows[consumer] = JSON::Any.new(nil)
    end
    JSON::Any.new({
      "format"          => JSON::Any.new("dynamic_recursive_handoff_w249_helper_v1"),
      "action"          => JSON::Any.new("write"),
      "part_path"       => JSON::Any.new(File.expand_path(part)),
      "profile"         => JSON::Any.new(fixture.profile_name(profile)),
      "frame_bytes"     => JSON::Any.new(DynamicRecursiveHandoffW249Fixture::FRAME_BYTES.to_i64),
      "rows_per_mark"   => JSON::Any.new(DynamicRecursiveHandoffW249Fixture::ROWS_PER_MARK.to_i64),
      "key_column"      => JSON::Any.new(DynamicRecursiveHandoffW249Fixture::KEY_NAME),
      "columns"         => JSON::Any.new(columns),
      "keys"            => JSON::Any.new(DynamicRecursiveHandoffW249Fixture::KEYS.map { |key| JSON::Any.new(key.to_i64) }),
      "mark_row_counts" => json_uints(DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS),
      "expected_rows"   => JSON::Any.new(fixture.expected_rows),
      "observed"        => JSON::Any.new(observed_rows),
    } of String => JSON::Any)
  end

  private def observed_counts_by_site(column_name : String) : Hash(String, Hash(String, UInt64))
    fixture = DynamicRecursiveHandoffW249Fixture
    result = Hash(String, Hash(String, UInt64)).new
    fixture.dynamic_sites[column_name].each do |site|
      result[site[:path]] = Hash(String, UInt64).new(0_u64)
    end
    type = fixture.column_types[column_name]
    fixture.rows_for(column_name).each do |value|
      collect_actual_counts(type, value, "root", column_name, result)
    end
    result
  end

  private def collect_actual_counts(
    type : CrystalClick::BinaryDataType,
    value : CrystalClick::BinaryValue,
    path : String,
    column_name : String,
    result : Hash(String, Hash(String, UInt64)),
  ) : Nil
    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      if value.child_count > 0
        counts = result[path]? || fail!("unexpected Dynamic site while counting #{column_name}: #{path}")
        counts[value.child_at(0).type.name] += 1_u64
      end
    when CrystalClick::BinaryDataType::TAG_ARRAY
      value.elements.each do |element|
        collect_actual_counts(type.child_at(0), element, "#{path}.elements", column_name, result)
      end
    when CrystalClick::BinaryDataType::TAG_NESTED
      tuple_type = type.child_at(0)
      value.elements.each do |record|
        tuple_type.child_count.times do |index|
          collect_actual_counts(
            tuple_type.child_at(index), record.child_at(index), "#{path}.elements.field.#{index}", column_name, result
          )
        end
      end
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      type.child_count.times do |index|
        collect_actual_counts(type.child_at(index), value.child_at(index), "#{path}.field.#{index}", column_name, result)
      end
    when CrystalClick::BinaryDataType::TAG_MAP
      (0...value.elements.size).step(2) do |index|
        collect_actual_counts(type.child_at(0), value.elements[index], "#{path}.elements.field.0", column_name, result)
        collect_actual_counts(type.child_at(1), value.elements[index + 1], "#{path}.elements.field.1", column_name, result)
      end
    when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      collect_actual_counts(type.child_at(0), value.child_at(0), path, column_name, result)
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      unless value.is_null?
        collect_actual_counts(type.child_at(0), value.child_at(0), "#{path}.nested", column_name, result)
      end
    end
    nil
  end

  private def audit_column(source : CrystalClick::PartStreamSource, part : String, name : String) : JSON::Any
    fixture = DynamicRecursiveHandoffW249Fixture
    type = fixture.column_types[name]
    column = CrystalClick::DynamicBulkColumnReader.open(part, name, type)
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    transport_limits = CrystalClick::CompressedStreamLimits.new
    site_reader = CrystalClick::DynamicBulkSiteReader.open(
      source,
      type,
      CrystalClick::PhysicalStreamName.escape(name),
      0_u64,
      column.ordinary_profile,
      limits,
      transport_limits,
      CrystalClick::BinaryCodecBudget.new(limits),
      CrystalClick::CompressedStreamBudget.new(transport_limits),
      nil,
      nil,
      column.row_count,
    )
    expected_paths = fixture.dynamic_sites[name].map { |site| site[:path] }.sort!
    require!(site_reader.plan.site_paths.sort! == expected_paths, "#{name} Dynamic site roster differs")
    sites = fixture.dynamic_sites[name].map do |site|
      audit_site(source, site_reader, name, site[:path])
    end
    entry = Hash(String, JSON::Any).new
    entry["name"] = JSON::Any.new(name)
    entry["nominal_type"] = JSON::Any.new(type.name)
    entry["sites"] = JSON::Any.new(sites)
    JSON::Any.new(entry)
  end

  private def audit_site(
    source : CrystalClick::PartStreamSource,
    reader : CrystalClick::DynamicBulkSiteReader,
    column_name : String,
    path : String,
  ) : JSON::Any
    logical_name = reader.physical.structure_name_for(path)
    hashed_name = CrystalClick::StreamName.hash(logical_name)
    data_name = CrystalClick::PhysicalStreamName.append_literal(hashed_name, ".bin")
    marks_name = CrystalClick::PhysicalStreamName.append_literal(hashed_name, ".mrk2")
    transport = CrystalClick::CompressedStreamBudget.read_default
    grid = source.inspect_grid(data_name, marks_name, nil, transport)
    bytes = source.read_all(data_name, transport)
    require!(grid.logical_size == bytes.size, "#{column_name} #{path} decompressed size changed")

    raw = parse_structure(bytes)
    decoded = reader.plan.structure_for(path)
    offset = reader.plan.statistics_offset_for(path)
    statistics = decoded.statistics || fail!("#{column_name} #{path} lacks mandatory V1/V2 statistics")
    decoded_types = decoded.types.map(&.name)
    require!(decoded.version == raw[:version], "#{column_name} #{path} raw/decoded version differs")
    require!(decoded.legacy_max_dynamic_types == raw[:legacy_max_dynamic_types],
      "#{column_name} #{path} raw/decoded legacy maximum differs")
    require!(decoded_types == raw[:types], "#{column_name} #{path} raw/decoded type names differ")
    require!(statistics.counts == raw[:counts], "#{column_name} #{path} raw/decoded positional statistics differ")
    require!(shared_entries(statistics.shared) == raw[:shared], "#{column_name} #{path} raw/decoded shared statistics differ")
    require!(raw[:statistics_offset] == offset, "#{column_name} #{path} raw/decoded statistics offset differs")
    require!(grid.prefix_size == offset && grid.mark_count == DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS.size &&
             grid.rows_per_mark == DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS,
      "#{column_name} #{path} structure mark grid differs")
    grid.mark_count.times do |index|
      require!(grid.position_at(index) == offset.to_i64, "#{column_name} #{path} mark #{index} misses statistics suffix")
    end
    require!(grid.position_at(grid.mark_count) == grid.logical_size,
      "#{column_name} #{path} terminal mark misses structure EOF")

    observed_counts = observed_type_counts(column_name, path)
    ordinary_names = decoded_types.sort
    require!(ordinary_names.all? { |type_name| observed_counts.has_key?(type_name) },
      "#{column_name} #{path} ordinary Dynamic roster has no literal value")
    shared_counts = observed_counts.reject { |type_name, _count| ordinary_names.includes?(type_name) }
    expected_names = (ordinary_names + shared_counts.keys).sort!
    actual_names = (ordinary_names + statistics.shared.map(&.name)).sort!
    require!(actual_names == expected_names, "#{column_name} #{path} roster/shared names differ from literal values")

    canonical_names = decoded.canonical_variant_names
    shared_total = shared_counts.values.sum(0_u64) { |count| count }
    expected_counts = canonical_names.map do |variant_name|
      variant_name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? shared_total : observed_counts[variant_name]? || 0_u64
    end
    expected_shared = shared_counts.map { |type_name, count| {type_name, count} }.sort_by(&.[0])
    actual_shared = shared_entries(statistics.shared).sort_by(&.[0])
    require!(statistics.counts == expected_counts && actual_shared == expected_shared,
      "#{column_name} #{path} statistics do not match literal per-type occurrence counts")

    entry = Hash(String, JSON::Any).new
    entry["path"] = JSON::Any.new(path)
    entry["physical_name"] = JSON::Any.new(logical_name)
    entry["version"] = JSON::Any.new(decoded.version.to_i64)
    entry["legacy_max_dynamic_types"] = decoded.legacy_max_dynamic_types ? JSON::Any.new(decoded.legacy_max_dynamic_types.not_nil!.to_i64) : JSON::Any.new(nil)
    entry["types"] = json_strings(decoded_types)
    entry["canonical_variant_names"] = json_strings(canonical_names)
    entry["mandatory_statistics"] = JSON::Any.new(true)
    entry["statistics"] = statistics_json(statistics)
    entry["raw_header"] = raw_header_json(raw)
    entry["statistics_prefix_offset"] = JSON::Any.new(offset.to_i64)
    entry["literal_actual_type_counts"] = JSON::Any.new(observed_counts.to_h do |type_name, count|
      {type_name, JSON::Any.new(count.to_i64)}
    end)
    entry["physical_grid"] = JSON::Any.new({
      "logical_size"      => JSON::Any.new(grid.logical_size),
      "prefix_size"       => JSON::Any.new(grid.prefix_size.to_i64),
      "mark_row_counts"   => json_uints(grid.rows_per_mark),
      "mark_positions"    => json_ints(grid.positions),
      "terminal_position" => JSON::Any.new(grid.position_at(grid.mark_count)),
    } of String => JSON::Any)
    JSON::Any.new(entry)
  end

  private def parse_structure(bytes : Bytes) : NamedTuple(
    version: UInt64,
    legacy_max_dynamic_types: UInt64?,
    types: Array(String),
    counts: Array(UInt64),
    shared: Array(Tuple(String, UInt64)),
    statistics_offset: Int32,
  )
    cursor = Cursor.new(bytes)
    version = cursor.read_u64_le
    unless version == 1_u64 || version == 2_u64
      fail!("expected legacy Dynamic version 1 or 2, found #{version}")
    end
    legacy_max = version == 1_u64 ? cursor.read_var_uint : nil
    count = cursor.read_var_uint
    if count > CrystalClick::DynamicStructure::MAX_ORDINARY_TYPES.to_u64
      fail!("Dynamic ordinary type count exceeds its declared domain")
    end
    types = Array(String).new(count.to_i32)
    count.to_i32.times { types << cursor.read_string_binary }
    if legacy = legacy_max
      require!(legacy == count, "V1 legacy maximum does not match the pinned stock writer's actual roster count")
    end
    statistics_offset = cursor.offset
    canonical_names = (types + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
    counts = Array(UInt64).new(canonical_names.size)
    canonical_names.size.times { counts << cursor.read_var_uint }
    shared_count = cursor.read_var_uint
    if shared_count > cursor.remaining.to_u64 // 2_u64
      fail!("shared statistics count cannot fit in the remaining structure")
    end
    shared = Array(Tuple(String, UInt64)).new(shared_count.to_i32)
    shared_count.to_i32.times do
      shared << {cursor.read_string_binary, cursor.read_var_uint}
    end
    cursor.ensure_consumed!
    {version: version, legacy_max_dynamic_types: legacy_max, types: types, counts: counts,
     shared: shared, statistics_offset: statistics_offset}
  end

  private def observed_type_counts(column_name : String, site_path : String) : Hash(String, UInt64)
    counts = observed_counts_by_site(column_name)[site_path]?
    counts || fail!("fixture is missing Dynamic site #{column_name} #{site_path}")
  end

  private def shared_entries(entries : Array(CrystalClick::StructureStatistic)) : Array(Tuple(String, UInt64))
    entries.map { |entry| {entry.name, entry.count} }
  end

  private def json_strings(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_uints(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_i64) })
  end

  private def json_ints(values : Array(Int64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def statistics_json(statistics : CrystalClick::StructureStatistics) : JSON::Any
    shared = statistics.shared.map do |entry|
      JSON::Any.new({
        "name"  => JSON::Any.new(entry.name),
        "count" => JSON::Any.new(entry.count.to_i64),
      } of String => JSON::Any)
    end
    JSON::Any.new({
      "variant_counts" => json_uints(statistics.counts),
      "shared"         => JSON::Any.new(shared),
    } of String => JSON::Any)
  end

  private def raw_header_json(raw : NamedTuple(
                                version: UInt64,
                                legacy_max_dynamic_types: UInt64?,
                                types: Array(String),
                                counts: Array(UInt64),
                                shared: Array(Tuple(String, UInt64)),
                                statistics_offset: Int32,
                              )) : JSON::Any
    legacy = raw[:legacy_max_dynamic_types] ? JSON::Any.new(raw[:legacy_max_dynamic_types].not_nil!.to_i64) : JSON::Any.new(nil)
    shared = raw[:shared].map do |name, count|
      JSON::Any.new({"name" => JSON::Any.new(name), "count" => JSON::Any.new(count.to_i64)} of String => JSON::Any)
    end
    JSON::Any.new({
      "version"                  => JSON::Any.new(raw[:version].to_i64),
      "legacy_max_dynamic_types" => legacy,
      "types"                    => json_strings(raw[:types]),
      "mandatory_variant_counts" => json_uints(raw[:counts]),
      "shared"                   => JSON::Any.new(shared),
      "statistics_prefix_offset" => JSON::Any.new(raw[:statistics_offset].to_i64),
    } of String => JSON::Any)
  end

  def main(args : Array(String)) : Nil
    if args.size == 2 && args[0] == "audit"
      puts audit(args[1]).to_json
    elsif args.size == 4 && args[0] == "write"
      puts write_versioned_part(args[1], args[2], args[3]).to_json
    else
      raise ArgumentError.new("usage: helper write PART single|sized v1|v2 | audit PART")
    end
  end
end

CheckDynamicStructureVersionsW250.main(ARGV)
