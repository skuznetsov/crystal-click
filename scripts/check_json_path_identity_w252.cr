require "../src/crystal_click"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckJSONPathIdentityW252
  extend self

  COLUMN        = "payload"
  KEY_NAME      = "pk"
  CASE_IDS      = ["root_dynamic", "array_dynamic", "root_object"]
  FORMAT_INPUT  = "json_path_identity_w252_input_v1"
  FORMAT_OUTPUT = "json_path_identity_w252_helper_v1"
  PARENT_ROWS   = [2_u64, 2_u64, 2_u64]
  CHILD_ROWS    = [2_u64, 2_u64, 2_u64, 0_u64]
  RAW_PATHS     = ["a.b", "a%2Eb", "a`b", "id", "maybe", "x=y"]

  alias Fixture = NamedTuple(
    case_id: String,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    granules: Array(Array(CrystalClick::BinaryValue)),
    plans: Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
    site: String,
    used: CrystalClick::BinaryDataType,
    unused: CrystalClick::BinaryDataType,
  )

  private class Cursor
    @bytes : Bytes
    @offset : Int32

    def initialize(@bytes : Bytes)
      @offset = 0
    end

    def offset : Int32
      @offset
    end

    def remaining : Int32
      @bytes.size - @offset
    end

    def read_byte : UInt8
      fail!("truncated Dynamic structure") unless @offset < @bytes.size
      value = @bytes[@offset]
      @offset += 1
      value
    end

    def read_u64_le : UInt64
      value = 0_u64
      8.times { |index| value |= read_byte.to_u64 << (index * 8) }
      value
    end

    def read_var_uint : UInt64
      value = 0_u64
      shift = 0
      loop do
        byte = read_byte
        payload = (byte & 0x7f_u8).to_u64
        fail!("Dynamic VarUInt exceeds UInt64") unless shift <= 63 && !(shift == 63 && payload > 1_u64)
        value |= payload << shift
        if (byte & 0x80_u8) == 0_u8
          fail!("Dynamic VarUInt is not minimally encoded") unless shift == 0 || payload != 0_u64
          return value
        end
        shift += 7
        fail!("Dynamic VarUInt exceeds ten bytes") unless shift < 70
      end
    end

    def read_string_binary : String
      size = read_var_uint
      fail!("Dynamic string exceeds its structure stream") unless size <= remaining.to_u64 && size <= Int32::MAX.to_u64
      value = String.new(@bytes[@offset, size.to_i32])
      @offset += size.to_i32
      fail!("Dynamic structure name is not UTF-8") unless value.valid_encoding?
      value
    end

    def ensure_consumed! : Nil
      fail!("Dynamic structure has trailing bytes") unless @offset == @bytes.size
    end

    private def fail!(message : String) : NoReturn
      raise CrystalClick::CorruptPartError.new("W252 raw Dynamic structure: #{message}")
    end
  end

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W252 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"    then CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream" then CrystalClick::BinaryBulkProfile.with_size_stream
    else                         raise ArgumentError.new("W252 profile is outside the fixed roster")
    end
  end

  private def version(name : String) : UInt64
    case name
    when "v1" then CrystalClick::DynamicStructure::VERSION_V1
    when "v2" then CrystalClick::DynamicStructure::VERSION_V2
    else           raise ArgumentError.new("W252 Dynamic version is outside the fixed roster")
    end
  end

  private def u8 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def i64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  private def typed_paths : Hash(String, CrystalClick::BinaryDataType)
    uint = u8
    {
      "a.b"   => uint,
      "a%2Eb" => uint,
      "a`b"   => uint,
      "id"    => uint,
      "maybe" => CrystalClick::BinaryDataType.nullable(uint),
      "x=y"   => uint,
    } of String => CrystalClick::BinaryDataType
  end

  private def json_type(max_types : Int32) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: max_types, typed_paths: typed_paths)
  end

  private def profile_version_structure(
    types : Array(CrystalClick::BinaryDataType),
    counts : Hash(String, UInt64),
    selected_version : UInt64,
    legacy_max : UInt64,
  ) : CrystalClick::DynamicStructure
    names = types.map(&.name)
    canonical = (names + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
    shared = counts.reject { |name, _| names.includes?(name) }
    statistics = CrystalClick::StructureStatistics.new(
      canonical.map { |name| name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? shared.values.sum(0_u64) : counts[name]? || 0_u64 },
      shared.map { |name, count| CrystalClick::StructureStatistic.new(name, count) }.sort_by(&.name),
    )
    CrystalClick::DynamicStructure.new(
      types, statistics, version: selected_version,
      legacy_max_dynamic_types: selected_version == CrystalClick::DynamicStructure::VERSION_V1 ? legacy_max : nil,
    )
  end

  private def json_plan(type : CrystalClick::BinaryDataType, selected_version : UInt64, count : UInt64) : CrystalClick::ObjectDocumentPlan
    child = profile_version_structure([i64] of CrystalClick::BinaryDataType, {"Int64" => count}, selected_version, 1_u64)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["counter"] of String),
      {"counter" => child},
    )
    CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
  end

  private def u8_value(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(u8, Bytes[value])
  end

  private def json_value(
    type : CrystalClick::BinaryDataType,
    id : UInt8,
    dotted : UInt8,
    percent : UInt8,
    backtick : UInt8,
    equal : UInt8,
    counter : Int64,
  ) : CrystalClick::BinaryValue
    nullable = CrystalClick::BinaryDataType.nullable(u8)
    row = CrystalClick::BinaryJsonRow.new(type, [
      {"a.b", u8_value(dotted)}, {"a%2Eb", u8_value(percent)},
      {"a`b", u8_value(backtick)}, {"id", u8_value(id)},
      {"maybe", CrystalClick::BinaryValue.null(nullable)}, {"x=y", u8_value(equal)},
      {"counter", CrystalClick::BinaryValue.int64(counter)},
    ] of Tuple(String, CrystalClick::BinaryValue))
    CrystalClick::BinaryValue.json(type, row)
  end

  private def json_signature(value : CrystalClick::BinaryValue) : String
    row = value.json_row
    require!(row.path_count == 7, "JSON path roster differs from the six typed paths plus counter")
    require!(row.value_for("maybe").not_nil!.is_null?, "maybe Nullable(UInt8) is not NULL")
    names = RAW_PATHS
    values = names.map do |path|
      child = row.value_for(path).not_nil!
      if path == "maybe"
        "null"
      else
        require!(child.type == u8, "typed JSON path #{path.inspect} is not UInt8")
        child.byte_at(0).to_s
      end
    end
    counter = row.value_for("counter").not_nil!
    require!(counter.type == i64, "counter Dynamic child is not Int64")
    "json[#{values.join(",")};counter=#{counter.as_int64}]"
  end

  private def dynamic_signature(value : CrystalClick::BinaryValue) : String
    require!(!value.is_null?, "unexpected NULL Dynamic actual")
    child = value.child_at(0)
    if child.type.tag == CrystalClick::BinaryDataType::TAG_JSON
      json_signature(child)
    else
      require!(child.type == u8, "ordinary Dynamic actual is not UInt8")
      "u8:#{child.byte_at(0)}"
    end
  end

  private def dynamic_occurrences(fixed : Fixture) : Array(CrystalClick::BinaryValue)
    fixed[:granules].flat_map do |mark|
      mark.flat_map do |row|
        fixed[:case_id] == "array_dynamic" ? row.elements : [row] of CrystalClick::BinaryValue
      end
    end
  end

  private def actual_parent_type_counts(fixed : Fixture) : Hash(String, UInt64)
    counts = Hash(String, UInt64).new
    dynamic_occurrences(fixed).each do |value|
      name = value.child_at(0).type.name
      counts[name] = (counts[name]? || 0_u64) + 1_u64
    end
    counts
  end

  private def actual_counter_type_counts(fixed : Fixture, json_type : CrystalClick::BinaryDataType) : Hash(String, UInt64)
    counts = Hash(String, UInt64).new
    dynamic_occurrences(fixed).each do |value|
      actual = value.child_at(0)
      next unless actual.type == json_type
      counter = actual.json_row.value_for("counter").not_nil!
      next if counter.is_null?
      counts[counter.type.name] = (counts[counter.type.name]? || 0_u64) + 1_u64
    end
    counts
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
    selected_version = cursor.read_u64_le
    require!(selected_version == CrystalClick::DynamicStructure::VERSION_V1 || selected_version == CrystalClick::DynamicStructure::VERSION_V2, "raw structure version is not W252 V1/V2")
    legacy = selected_version == CrystalClick::DynamicStructure::VERSION_V1 ? cursor.read_var_uint : nil
    count = cursor.read_var_uint
    require!(count <= CrystalClick::DynamicStructure::MAX_ORDINARY_TYPES.to_u64 && count <= Int32::MAX.to_u64, "raw structure roster exceeds its bound")
    types = Array(String).new(count.to_i32) { cursor.read_string_binary }
    statistics_offset = cursor.offset
    canonical = (types + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
    counts = Array(UInt64).new(canonical.size) { cursor.read_var_uint }
    shared_count = cursor.read_var_uint
    require!(shared_count <= cursor.remaining.to_u64 // 2_u64, "raw shared map cannot fit")
    shared = Array(Tuple(String, UInt64)).new(shared_count.to_i32) do
      {cursor.read_string_binary, cursor.read_var_uint}
    end
    cursor.ensure_consumed!
    {version: selected_version, legacy_max_dynamic_types: legacy, types: types, counts: counts,
     shared: shared, statistics_offset: statistics_offset}
  end

  private def shared_entries(entries : Array(CrystalClick::StructureStatistic)) : Array(Tuple(String, UInt64))
    entries.map { |entry| {entry.name, entry.count} }
  end

  private def raw_structure_audit(
    part : String,
    logical_name : String,
    owner : String,
    site_path : String,
    json_type_name : String?,
    selected_version : UInt64,
    expected_types : Array(String),
    literal_counts : Hash(String, UInt64),
  ) : JSON::Any
    source = CrystalClick::PartStreamSource.new(part)
    hashed = CrystalClick::StreamName.hash(logical_name)
    data_name = "#{hashed}.bin"
    marks_name = "#{hashed}.mrk2"
    bytes = source.read_all(data_name)
    grid = source.inspect_grid(data_name, marks_name)
    raw = parse_structure(bytes)
    context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, bytes)
    decoded, decoded_offset = CrystalClick::DynamicStructureCodec.read_with_statistics_offset(context)
    context.ensure_consumed
    stats = decoded.statistics || raise CrystalClick::CorruptPartError.new("W252 mandatory versioned statistics are absent")
    canonical = decoded.canonical_variant_names
    expected_counts = canonical.map do |name|
      name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? 0_u64 : literal_counts[name]? || 0_u64
    end
    expected_legacy = selected_version == CrystalClick::DynamicStructure::VERSION_V1 ? expected_types.size.to_u64 : nil
    require!(raw[:version] == selected_version && decoded.version == selected_version, "#{owner}/#{site_path} raw/decoded version differs")
    require!(raw[:types].sort == expected_types.sort && decoded.types.map(&.name).sort == expected_types.sort, "#{owner}/#{site_path} raw/decoded type roster differs")
    require!(raw[:legacy_max_dynamic_types] == expected_legacy && decoded.legacy_max_dynamic_types == expected_legacy, "#{owner}/#{site_path} V1 roster count differs")
    require!(raw[:counts] == stats.counts && raw[:shared] == shared_entries(stats.shared), "#{owner}/#{site_path} raw/decoded statistics differ")
    require!(stats.counts == expected_counts && stats.shared.empty?, "#{owner}/#{site_path} mandatory positional statistics differ from literal census")
    require!(raw[:statistics_offset] == decoded_offset && grid.prefix_size == decoded_offset, "#{owner}/#{site_path} statistics prefix differs")
    require!(grid.mark_count == PARENT_ROWS.size && grid.rows_per_mark == PARENT_ROWS, "#{owner}/#{site_path} P-grid differs")
    grid.mark_count.times { |index| require!(grid.position_at(index) == decoded_offset.to_i64, "#{owner}/#{site_path} mark prefix differs") }
    require!(grid.position_at(grid.mark_count) == grid.logical_size, "#{owner}/#{site_path} structure EOF differs")
    JSON::Any.new({
      "owner" => JSON::Any.new(owner), "site_path" => JSON::Any.new(site_path),
      "json_type_name" => (json_type_name ? JSON::Any.new(json_type_name) : JSON::Any.new(nil)),
      "physical_name" => JSON::Any.new(logical_name), "version" => JSON::Any.new(decoded.version.to_i64),
      "legacy_max_dynamic_types" => (decoded.legacy_max_dynamic_types ? JSON::Any.new(decoded.legacy_max_dynamic_types.not_nil!.to_i64) : JSON::Any.new(nil)),
      "types" => json_strings(decoded.types.map(&.name)), "canonical_variant_names" => json_strings(canonical),
      "mandatory_statistics" => JSON::Any.new(true),
      "statistics" => JSON::Any.new({"counts" => json_uints(stats.counts), "shared" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any),
      "statistics_prefix_offset" => JSON::Any.new(decoded_offset.to_i64),
      "physical_grid" => JSON::Any.new({
        "logical_size" => JSON::Any.new(grid.logical_size), "prefix_size" => JSON::Any.new(grid.prefix_size.to_i64),
        "mark_row_counts" => json_uints(grid.rows_per_mark), "mark_positions" => JSON::Any.new(grid.positions.map { |value| JSON::Any.new(value) }),
        "terminal_position" => JSON::Any.new(grid.position_at(grid.mark_count)),
      } of String => JSON::Any),
      "literal_actual_type_counts" => JSON::Any.new(literal_counts.to_h { |name, count| {name, JSON::Any.new(count.to_i64)} }),
    } of String => JSON::Any)
  end

  private def read_site_reader(part : String, fixed : Fixture, profile_name : String, rows : UInt64) : CrystalClick::DynamicBulkSiteReader
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    transport_limits = CrystalClick::CompressedStreamLimits.new
    CrystalClick::DynamicBulkSiteReader.open(
      CrystalClick::PartStreamSource.new(part), fixed[:type], CrystalClick::PhysicalStreamName.escape(COLUMN),
      0_u64, profile(profile_name), limits, transport_limits,
      CrystalClick::BinaryCodecBudget.new(limits), CrystalClick::CompressedStreamBudget.new(transport_limits),
      nil, nil, rows,
    )
  end

  private def structure_audits(part : String, site_reader : CrystalClick::DynamicBulkSiteReader, fixed : Fixture, origin : String, selected_version : UInt64) : Array(JSON::Any)
    site_path = fixed[:site]
    actual_parent = site_reader.plan.structure_for(site_path)
    expected_parent = origin == "library" ? [fixed[:used].name, fixed[:unused].name, u8.name] : [fixed[:used].name, u8.name]
    audits = [raw_structure_audit(part, site_reader.physical.structure_name_for(site_path), "dynamic_parent", site_path, nil,
      selected_version, expected_parent, actual_parent_type_counts(fixed))]
    require!(actual_parent.types.map(&.name).sort == expected_parent.sort, "#{origin} parsed parent Dynamic roster differs")
    json_sites = site_reader.physical.json_object_sites
    expected_json_types = origin == "library" ? [fixed[:used].name, fixed[:unused].name].sort : [fixed[:used].name]
    require!(json_sites.map { |site| site.binding.json_type.name }.sort == expected_json_types, "#{origin} JSON Object binding roster differs")
    json_sites.each do |site|
      json_name = site.binding.json_type.name
      structure = site.binding.plan.structures.dynamic_for("counter")
      child_types = structure.types.map(&.name)
      require!(child_types == ["Int64"], "#{origin} JSON counter Dynamic roster differs")
      audits << raw_structure_audit(part, site.physical_plan.dynamic_structure_stream("counter"), "json_counter_dynamic",
        "#{site_path}/#{json_name}/counter", json_name, selected_version, ["Int64"], actual_counter_type_counts(fixed, site.binding.json_type))
    end
    audits
  end

  private def row_signature(value : CrystalClick::BinaryValue, case_id : String) : String
    if case_id == "array_dynamic"
      "[#{value.elements.map { |item| dynamic_signature(item) }.join("|")}]"
    else
      dynamic_signature(value)
    end
  end

  private def fixture(case_id : String, version_name : String) : Fixture
    selected_version = version(version_name)
    used = json_type(1)
    unused = json_type(2)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 3)
    array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    site = case case_id
           when "root_dynamic"  then "root"
           when "array_dynamic" then "root.elements"
           else                      raise ArgumentError.new("W252 Dynamic fixture case is invalid")
           end
    json_count = 2_u64
    uint_count = case case_id
                 when "root_dynamic"  then 4_u64
                 when "array_dynamic" then 3_u64
                 else                      raise ArgumentError.new("W252 Dynamic fixture case is invalid")
                 end
    parent_types = [used, unused, u8] of CrystalClick::BinaryDataType
    parent = profile_version_structure(parent_types, {used.name => json_count, "UInt8" => uint_count}, selected_version, 3_u64)
    structures = {site => parent}
    plans = [
      {site, parent.canonical_index_for(used), json_plan(used, selected_version, 2_u64)},
      {site, parent.canonical_index_for(unused), json_plan(unused, selected_version, 0_u64)},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    json = ->(id : UInt8, d : UInt8, p : UInt8, t : UInt8, x : UInt8, c : Int64) {
      CrystalClick::BinaryValue.dynamic(dynamic_type, json_value(used, id, d, p, t, x, c))
    }
    integer = ->(n : UInt8) { CrystalClick::BinaryValue.dynamic(dynamic_type, u8_value(n)) }
    if case_id == "root_dynamic"
      granules = [
        [integer.call(17_u8), integer.call(18_u8)] of CrystalClick::BinaryValue,
        [integer.call(19_u8), integer.call(20_u8)] of CrystalClick::BinaryValue,
        [json.call(41_u8, 17_u8, 23_u8, 31_u8, 42_u8, 401_i64), json.call(42_u8, 18_u8, 24_u8, 32_u8, 43_u8, 402_i64)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, type: dynamic_type, structures: structures, granules: granules, plans: plans, site: site, used: used, unused: unused}
    else
      empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
      values = [integer.call(17_u8), integer.call(18_u8)] of CrystalClick::BinaryValue
      array_two = CrystalClick::BinaryValue.array(array_type, values)
      array_one = CrystalClick::BinaryValue.array(array_type, [integer.call(19_u8)] of CrystalClick::BinaryValue)
      j1 = CrystalClick::BinaryValue.array(array_type, [json.call(41_u8, 17_u8, 23_u8, 31_u8, 42_u8, 401_i64)] of CrystalClick::BinaryValue)
      j2 = CrystalClick::BinaryValue.array(array_type, [json.call(42_u8, 18_u8, 24_u8, 32_u8, 43_u8, 402_i64)] of CrystalClick::BinaryValue)
      granules = [[empty, empty], [array_two, array_one], [j1, j2]] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, type: array_type, structures: structures, granules: granules, plans: plans, site: site, used: used, unused: unused}
    end
  end

  private def expected_rows(case_id : String) : Array(Array(String))
    json1 = "json[17,23,31,41,null,42;counter=401]"
    json2 = "json[18,24,32,42,null,43;counter=402]"
    if case_id == "root_dynamic"
      [["u8:17", "u8:18"], ["u8:19", "u8:20"], [json1, json2]]
    else
      [["[]", "[]"], ["[u8:17|u8:18]", "[u8:19]"], ["[#{json1}]", "[#{json2}]"]]
    end
  end

  private def json_strings(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_uints(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_i64) })
  end

  private def canonical_part(path : String, root : String, generated : Bool) : String
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part escaped its assigned root")
    if generated
      require!(!Dir.exists?(full) && !File.symlink?(full), "generated part already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent, "generated parent is not canonical")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full, "source part is not canonical")
    end
    full
  end

  private def dynamic_reader_record(part : String, fixed : Fixture, profile_name : String, origin : String) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(part, COLUMN, fixed[:type], CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, CrystalClick::CompressedStreamLimits.new)
    require!(reader.row_count == 6_u64 && reader.mark_count == 3 && reader.mark_row_counts == PARENT_ROWS, "#{origin} parent P grid differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} Dynamic String profile differs")
    rows = reader.read_marks(0, reader.mark_count).map { |mark| mark.map { |value| row_signature(value, fixed[:case_id]) } }
    require!(rows == expected_rows(fixed[:case_id]), "#{origin} rows differ from literal W252 fixture")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin} EOF-zero read is nonempty")
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_rows = Array(Array(String)).new(3) { [] of String }
    table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
      require!(batch.part_index == 0 && batch.mark_row_offset == 0_u64, "#{origin} public table coordinate differs")
      table_rows[batch.mark_index] = batch.dynamic_bulk_values_for(COLUMN).map { |value| row_signature(value, fixed[:case_id]) }.to_a
    end
    require!(table_rows == expected_rows(fixed[:case_id]), "#{origin} public candidate scan differs")
    owned = CrystalClick::DynamicOwnedValuesW220.materialize(part, COLUMN, fixed[:type], reader.row_count, reader.mark_row_counts,
      fixed[:granules], reader.read_marks(0, reader.mark_count))
    owned_json = CrystalClick::DynamicOwnedValuesW220.to_json(owned) { |value| row_signature(value, fixed[:case_id]) }
    site_reader = read_site_reader(part, fixed, profile_name, reader.row_count)
    require!(site_reader.plan.site_paths == [fixed[:site]], "#{origin} Dynamic site path differs")
    audits = structure_audits(part, site_reader, fixed, origin, version(profile_name == "single_stream" ? "v1" : "v2"))
    json_sites = site_reader.physical.json_object_sites
    child_streams = json_sites.flat_map { |site| site.physical_plan.stream_names }.sort!
    JSON::Any.new({
      "case_id" => JSON::Any.new(fixed[:case_id]), "profile_id" => JSON::Any.new(profile_name),
      "schema_declaration" => JSON::Any.new(reader.schema_declaration), "row_count" => JSON::Any.new(6),
      "mark_count" => JSON::Any.new(3), "mark_row_counts" => json_uints(reader.mark_row_counts),
      "rows_by_mark" => JSON::Any.new(rows.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names" => json_strings(reader.physical_stream_names.sort!),
      "selected_checksum_names" => json_strings(reader.selected_checksum_names.sort!),
      "object_child_stream_names" => json_strings(child_streams),
      "bound_json_type_names" => json_strings(json_sites.map { |site| site.binding.json_type.name }.sort!),
      "structure_audits" => JSON::Any.new(audits),
      "owned_values" => owned_json, "offline_values" => JSON::Any.new(nil),
      "windows" => json_strings(["candidate_marks", "eof_zero"]),
    } of String => JSON::Any)
  end

  private def dynamic_fixture(case_id : String, version_name : String, profile_name : String, source_part : String, library_part : String) : JSON::Any
    fixed = fixture(case_id, version_name)
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      library_part, KEY_NAME, Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64], COLUMN,
      fixed[:type], fixed[:structures], fixed[:granules], rows_per_mark: 2, profile: profile(profile_name),
      frame_bytes: 4096, metadata_version: 0_i64, limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits: CrystalClick::CompressedStreamLimits.new, json_object_plans: fixed[:plans],
    )
    require!(result == library_part, "writer returned unexpected part path")
    JSON::Any.new({
      "case_id" => JSON::Any.new(case_id), "profile_id" => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(library_part),
      "source" => dynamic_reader_record(source_part, fixed, profile_name, "stock source"),
      "library" => dynamic_reader_record(library_part, fixed, profile_name, "library"),
    } of String => JSON::Any)
  end

  private def object_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(typed_paths, 1, 1)
  end

  private def object_documents : Array(Array(CrystalClick::ObjectDocument))
    docs = (0...6).map do |index|
      n = index.to_u8
      values = {
        "a.b" => u8_value(17_u8 + n), "a%2Eb" => u8_value(23_u8 + n), "a`b" => u8_value(31_u8 + n),
        "id" => u8_value(41_u8 + n), "maybe" => CrystalClick::BinaryValue.null(CrystalClick::BinaryDataType.nullable(u8)),
        "x=y" => u8_value(42_u8 + n),
      } of String => CrystalClick::BinaryValue
      CrystalClick::ObjectDocument.new(values)
    end
    docs.each_slice(2).map(&.to_a).to_a
  end

  private def object_signature(document : CrystalClick::ObjectDocument) : String
    RAW_PATHS.map do |path|
      value = document.value_for(path).not_nil!
      path == "maybe" ? "null" : value.byte_at(0).to_s
    end.join(",")
  end

  private def object_reader_record(part : String, schema : CrystalClick::ObjectDocumentSchema, profile_name : String, origin : String) : JSON::Any
    reader = CrystalClick::ObjectColumnReader.open(part, COLUMN, schema)
    rows = reader.read_marks(0, 3).map { |mark| mark.map { |doc| object_signature(doc) } }
    expected = (0...6).map { |i| [17 + i, 23 + i, 31 + i, 41 + i, "null", 42 + i].join(",") }.each_slice(2).map(&.to_a).to_a
    require!(rows == expected, "#{origin} Object raw path values differ")
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_rows = [] of String
    table.scan_typed_candidate_marks([[0, 1, 2]]) { |batch| table_rows.concat(batch.object_documents_for(COLUMN).map { |doc| object_signature(doc) }) }
    require!(table_rows == expected.flatten, "#{origin} Object public table rows differ")
    info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
    candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 6_u64)
    offline = CrystalClick::OfflineTable.new("w252_object", "00000000-0000-0000-0000-000000000252", "MergeTree",
      [CrystalClick::OfflineColumn.new(KEY_NAME, "UInt64"), CrystalClick::OfflineColumn.new(COLUMN, schema.declaration)],
      [candidate], KEY_NAME)
    offline_rows = offline[COLUMN].values.map { |value| object_signature(value.as(CrystalClick::ObjectDocument)) }
    require!(offline_rows == expected.flatten, "#{origin} OfflineTable.values Object rows differ")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(part, COLUMN, schema.typed_paths, reader.ordinary_profile, CrystalClick::BinaryBulkProfile.single_stream, true)
    JSON::Any.new({
      "case_id" => JSON::Any.new("root_object"), "profile_id" => JSON::Any.new(profile_name),
      "schema_declaration" => JSON::Any.new(reader.schema_declaration), "row_count" => JSON::Any.new(6),
      "mark_count" => JSON::Any.new(3), "mark_row_counts" => json_uints(reader.mark_row_counts),
      "rows_by_mark" => JSON::Any.new(rows.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names" => json_strings(descriptor.physical_stream_names.sort!),
      "selected_checksum_names" => json_strings(descriptor.selected_checksum_names.sort!),
      "object_child_stream_names" => json_strings(descriptor.physical_stream_names.sort!),
      "bound_json_type_names" => json_strings([schema.declaration]), "structure_audits" => JSON::Any.new([] of JSON::Any),
      "owned_values" => JSON::Any.new(nil), "offline_values" => json_strings(offline_rows),
      "windows" => json_strings(["candidate_marks", "offline_values"]),
    } of String => JSON::Any)
  end

  private def object_fixture(profile_name : String, source_part : String, library_part : String) : JSON::Any
    schema = object_schema
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure),
      schema.typed_paths,
    )
    result = CrystalClick::WidePartWriter.write_uint64_object_pair(
      library_part, KEY_NAME, Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64], COLUMN, schema, plan, object_documents,
      rows_per_mark: 2, profile: profile(profile_name), shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    )
    require!(result == library_part, "Object writer returned unexpected part path")
    JSON::Any.new({
      "case_id" => JSON::Any.new("root_object"), "profile_id" => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(library_part),
      "source" => object_reader_record(source_part, schema, profile_name, "stock source"),
      "library" => object_reader_record(library_part, schema, profile_name, "library"),
    } of String => JSON::Any)
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String, version_name : String, profile_name : String) : JSON::Any
    case_id = item["case_id"].as_s
    require!(item.as_h.keys.sort == ["case_id", "capture_root", "library_part", "profile_id", "source_part", "version"].sort, "case input keys differ")
    require!(item["capture_root"].as_s == capture_root && item["version"].as_s == version_name && item["profile_id"].as_s == profile_name, "case binding differs")
    source_part = canonical_part(item["source_part"].as_s, capture_root, false)
    library_part = canonical_part(item["library_part"].as_s, output_root, true)
    if case_id == "root_object"
      object_fixture(profile_name, source_part, library_part)
    else
      dynamic_fixture(case_id, version_name, profile_name, source_part, library_part)
    end
  end

  def main(args : Array(String)) : Nil
    raise ArgumentError.new("usage: check_json_path_identity_w252.cr INPUT.json OUTPUT_ROOT") unless args.size == 2
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root, "output root is not canonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR), "input is not a plain file below output root")
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "dynamic_version", "format", "profile_id"] && input["format"].as_s == FORMAT_INPUT, "input format differs")
    version_name = input["dynamic_version"].as_s
    profile_name = input["profile_id"].as_s
    expected_profile = version_name == "v1" ? "single_stream" : "with_size_stream"
    version(version_name)
    profile(profile_name)
    require!(profile_name == expected_profile, "version/profile pair is outside fixed W252 roster")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root, "capture root is not canonical")
    cases = input["cases"].as_a
    require!(cases.map { |item| item["case_id"].as_s } == CASE_IDS, "case roster/order differs")
    results = cases.map { |item| process_case(item, capture_root, output_root, version_name, profile_name) }
    puts JSON::Any.new({
      "format" => JSON::Any.new(FORMAT_OUTPUT), "dynamic_version" => JSON::Any.new(version_name),
      "dynamic_version_wire" => JSON::Any.new(version(version_name).to_i64), "profile_id" => JSON::Any.new(profile_name),
      "case_ids" => json_strings(CASE_IDS), "parent_mark_rows" => json_uints(PARENT_ROWS),
      "json_child_mark_rows" => json_uints(CHILD_ROWS), "cases" => JSON::Any.new(results),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W252 helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end
end

CheckJSONPathIdentityW252.main(ARGV)
