require "../src/crystal_click"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckJSONSQLTypeNameW251
  extend self

  COLUMN        = "payload"
  KEY_NAME      = "pk"
  CASE_IDS      = ["root_dynamic", "array_dynamic"]
  FORMAT_INPUT  = "json_sql_type_name_w251_input_v1"
  FORMAT_OUTPUT = "json_sql_type_name_w251_helper_v1"
  PARENT_ROWS   = [2_u64, 2_u64, 2_u64]
  CHILD_ROWS    = [2_u64, 2_u64, 2_u64, 0_u64]
  alias Fixture = NamedTuple(
    case_id: String,
    version_name: String,
    version: UInt64,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    granules: Array(Array(CrystalClick::BinaryValue)),
    plans: Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
    sites: Array(String),
    json_used: CrystalClick::BinaryDataType,
    json_unused: CrystalClick::BinaryDataType,
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
      fail!("truncated Dynamic structure") if @offset >= @bytes.size
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
        fail!("Dynamic VarUInt exceeds UInt64") if shift > 63 || (shift == 63 && payload > 1_u64)
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
      fail!("Dynamic string exceeds its structure stream") if size > remaining.to_u64 || size > Int32::MAX.to_u64
      value = String.new(@bytes[@offset, size.to_i32])
      @offset += size.to_i32
      fail!("Dynamic string is not valid UTF-8") unless value.valid_encoding?
      value
    end

    def ensure_consumed! : Nil
      fail!("Dynamic structure has trailing bytes") unless @offset == @bytes.size
    end

    private def fail!(message : String) : NoReturn
      raise CrystalClick::CorruptPartError.new("W251 helper raw structure: #{message}")
    end
  end

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W251 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W251 profile is outside the fixed roster")
    end
  end

  private def version(name : String) : UInt64
    case name
    when "v1" then CrystalClick::DynamicStructure::VERSION_V1
    when "v2" then CrystalClick::DynamicStructure::VERSION_V2
    else           raise ArgumentError.new("W251 Dynamic version is outside the fixed roster")
    end
  end

  private def u8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def i64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  private def json_type(max_dynamic_types : Int32) : CrystalClick::BinaryDataType
    uint8 = u8_type
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: max_dynamic_types,
      typed_paths: {
        "id"    => uint8,
        "maybe" => CrystalClick::BinaryDataType.nullable(uint8),
      } of String => CrystalClick::BinaryDataType,
    )
  end

  private def statistics(types : Array(CrystalClick::BinaryDataType), counts : Hash(String, UInt64)) : CrystalClick::StructureStatistics
    names = types.map(&.name)
    shared = counts.reject { |name, _count| names.includes?(name) }
    canonical = (names + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
    variant_counts = canonical.map do |name|
      if name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME
        shared.values.sum(0_u64) { |count| count }
      else
        counts[name]? || 0_u64
      end
    end
    shared_entries = shared.map do |name, count|
      CrystalClick::StructureStatistic.new(name, count)
    end.sort_by(&.name)
    CrystalClick::StructureStatistics.new(variant_counts, shared_entries)
  end

  private def versioned_structure(
    types : Array(CrystalClick::BinaryDataType),
    counts : Hash(String, UInt64),
    version : UInt64,
    legacy_max : UInt64,
  ) : CrystalClick::DynamicStructure
    stats = statistics(types, counts)
    CrystalClick::DynamicStructure.new(
      types,
      stats,
      version: version,
      legacy_max_dynamic_types: version == CrystalClick::DynamicStructure::VERSION_V1 ? legacy_max : nil,
    )
  end

  private def json_plan(type : CrystalClick::BinaryDataType, version : UInt64) : CrystalClick::ObjectDocumentPlan
    ordinary = [i64_type] of CrystalClick::BinaryDataType
    count = type.json_type.not_nil!.max_dynamic_types == 1_u8 ? 2_u64 : 0_u64
    # V1's legacy field is the serialized ordinary roster count, not the
    # nominal JSON cap. Both JSON counter sites have exactly one registered
    # ordinary Dynamic type, even when the unused site's occurrence count is
    # zero.
    child = versioned_structure(ordinary, {"Int64" => count}, version, ordinary.size.to_u64)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["counter"] of String),
      {"counter" => child},
    )
    CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
  end

  private def json_value(type : CrystalClick::BinaryDataType, id : UInt8, counter : Int64) : CrystalClick::BinaryValue
    uint8 = u8_type
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [
        {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
        {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
        {"counter", CrystalClick::BinaryValue.int64(counter)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  private def dynamic(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def fixture(case_id : String, version_name : String) : Fixture
    selected_version = version(version_name)
    uint8_occurrences = case case_id
                        when "root_dynamic"  then 4_u64
                        when "array_dynamic" then 3_u64
                        else                      raise ArgumentError.new("W251 case is outside the fixed roster")
                        end
    uint8 = u8_type
    dynamic_type = CrystalClick::BinaryDataType.dynamic(3)
    array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    used = json_type(1)
    unused = json_type(2)
    types = [used, unused, uint8] of CrystalClick::BinaryDataType
    parent = versioned_structure(types, {"UInt8" => uint8_occurrences, used.name => 2_u64}, selected_version, 3_u64)
    site = case case_id
           when "root_dynamic"  then "root"
           when "array_dynamic" then "root.elements"
           else                      raise ArgumentError.new("W251 case is outside the fixed roster")
           end
    plans = [
      {site, parent.canonical_index_for(used), json_plan(used, selected_version)},
      {site, parent.canonical_index_for(unused), json_plan(unused, selected_version)},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    structures = {site => parent}
    uint = ->(value : UInt8) { dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8, Bytes[value])) }
    json = ->(id : UInt8, counter : Int64) { dynamic(dynamic_type, json_value(used, id, counter)) }

    if case_id == "root_dynamic"
      granules = [
        [uint.call(17_u8), uint.call(18_u8)] of CrystalClick::BinaryValue,
        [uint.call(19_u8), uint.call(20_u8)] of CrystalClick::BinaryValue,
        [json.call(41_u8, 401_i64), json.call(42_u8, 402_i64)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, version_name: version_name, version: selected_version, type: dynamic_type,
       structures: structures, granules: granules, plans: plans, sites: [site] of String,
       json_used: used, json_unused: unused}
    else
      empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
      two = CrystalClick::BinaryValue.array(array_type, [uint.call(17_u8), uint.call(18_u8)] of CrystalClick::BinaryValue)
      one = CrystalClick::BinaryValue.array(array_type, [uint.call(19_u8)] of CrystalClick::BinaryValue)
      first_json = CrystalClick::BinaryValue.array(array_type, [json.call(41_u8, 401_i64)] of CrystalClick::BinaryValue)
      second_json = CrystalClick::BinaryValue.array(array_type, [json.call(42_u8, 402_i64)] of CrystalClick::BinaryValue)
      granules = [
        [empty, empty] of CrystalClick::BinaryValue,
        [two, one] of CrystalClick::BinaryValue,
        [first_json, second_json] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, version_name: version_name, version: selected_version, type: array_type,
       structures: structures, granules: granules, plans: plans, sites: [site] of String,
       json_used: used, json_unused: unused}
    end
  end

  private def actual_signature(value : CrystalClick::BinaryValue) : String
    require!(!value.is_null?, "unexpected NULL Dynamic value in fixed fixture")
    actual = value.child_at(0)
    if actual.type.tag == CrystalClick::BinaryDataType::TAG_JSON
      row = actual.json_row
      require!(row.path_count == 3, "JSON actual path count differs")
      id = row.value_for("id").not_nil!.byte_at(0)
      require!(row.value_for("maybe").not_nil!.is_null?, "typed Nullable(UInt8) JSON path differs")
      counter = row.value_for("counter").not_nil!
      require!(counter.type == i64_type, "JSON Dynamic counter is not Int64")
      "json:#{id}:null:counter=#{counter.as_int64}"
    else
      require!(actual.type == u8_type, "ordinary Dynamic arm is not UInt8")
      "u8:#{actual.byte_at(0)}"
    end
  end

  private def row_signature(value : CrystalClick::BinaryValue, case_id : String) : String
    if case_id == "array_dynamic"
      "[#{value.elements.map { |item| actual_signature(item) }.join(",")}]"
    else
      actual_signature(value)
    end
  end

  private def expected_rows(case_id : String) : Array(Array(String))
    if case_id == "root_dynamic"
      [["u8:17", "u8:18"] of String,
       ["u8:19", "u8:20"] of String,
       ["json:41:null:counter=401", "json:42:null:counter=402"] of String]
    else
      [["[]", "[]"] of String,
       ["[u8:17,u8:18]", "[u8:19]"] of String,
       ["[json:41:null:counter=401]", "[json:42:null:counter=402]"] of String]
    end
  end

  private def validate_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part path escaped its authenticated root")
    if generated
      require!(!File.exists?(full) && !File.symlink?(full), "generated destination already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated parent is absent, symlinked or noncanonical")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock source part is absent, symlinked or noncanonical")
    end
  end

  private def rows_by_mark(reader : CrystalClick::DynamicBulkColumnReader, fixed : Fixture, origin : String) : Array(Array(String))
    observed = reader.read_marks(0, reader.mark_count).map do |mark|
      mark.map { |value| row_signature(value, fixed[:case_id]) }
    end
    require!(observed == expected_rows(fixed[:case_id]), "#{origin} values differ from fixed row/mark literals")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin} EOF-zero read is not empty")
    observed
  end

  private def dynamic_occurrences(fixed : Fixture) : Array(CrystalClick::BinaryValue)
    fixed[:granules].flat_map do |mark|
      mark.flat_map do |row|
        if fixed[:type].tag == CrystalClick::BinaryDataType::TAG_ARRAY
          row.elements
        else
          [row] of CrystalClick::BinaryValue
        end
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

  private def actual_json_counter_type_counts(fixed : Fixture, json_type : CrystalClick::BinaryDataType) : Hash(String, UInt64)
    counts = Hash(String, UInt64).new
    dynamic_occurrences(fixed).each do |value|
      actual = value.child_at(0)
      next unless actual.type == json_type
      counter = actual.json_row.value_for("counter").not_nil!
      next if counter.is_null?
      name = counter.type.name
      counts[name] = (counts[name]? || 0_u64) + 1_u64
    end
    counts
  end

  private def read_site_reader(part : String, fixed : Fixture, profile_name : String, rows : UInt64) : CrystalClick::DynamicBulkSiteReader
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    transport_limits = CrystalClick::CompressedStreamLimits.new
    CrystalClick::DynamicBulkSiteReader.open(
      CrystalClick::PartStreamSource.new(part),
      fixed[:type],
      CrystalClick::PhysicalStreamName.escape(COLUMN),
      0_u64,
      profile(profile_name),
      limits,
      transport_limits,
      CrystalClick::BinaryCodecBudget.new(limits),
      CrystalClick::CompressedStreamBudget.new(transport_limits),
      nil,
      nil,
      rows,
    )
  end

  private def raw_structure_audit(
    part : String,
    logical_name : String,
    owner : String,
    site_path : String,
    json_type_name : String?,
    version : UInt64,
    expected_types : Array(String),
    expected_rows : Array(UInt64),
    literal_counts : Hash(String, UInt64),
  ) : JSON::Any
    source = CrystalClick::PartStreamSource.new(part)
    hashed = CrystalClick::StreamName.hash(logical_name)
    data_name = "#{hashed}.bin"
    marks_name = "#{hashed}.mrk2"
    bytes = source.read_all(data_name)
    grid = source.inspect_grid(data_name, marks_name)
    raw = parse_structure(bytes)
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    context = CrystalClick::BinaryCodecContext.new(limits, bytes)
    decoded, decoded_offset = CrystalClick::DynamicStructureCodec.read_with_statistics_offset(context)
    context.ensure_consumed
    stats = decoded.statistics || raise CrystalClick::CorruptPartError.new("W251 complete V1/V2 structure omitted statistics")
    actual_types = decoded.types.map(&.name)
    require!(decoded.version == version && raw[:version] == version, "#{owner}/#{site_path} Dynamic version differs")
    require!(actual_types.sort == expected_types.sort && raw[:types].sort == expected_types.sort,
      "#{owner}/#{site_path} ordinary type roster differs")
    require!(stats.counts == raw[:counts] && shared_entries(stats.shared) == raw[:shared],
      "#{owner}/#{site_path} raw/decoded statistics differ")
    require!(decoded_offset == raw[:statistics_offset], "#{owner}/#{site_path} raw/decoded statistics prefix differs")
    expected_legacy = version == CrystalClick::DynamicStructure::VERSION_V1 ? expected_types.size.to_u64 : nil
    require!(decoded.legacy_max_dynamic_types == expected_legacy && raw[:legacy_max_dynamic_types] == expected_legacy,
      "#{owner}/#{site_path} V1 legacy maximum differs from its exact ordinary roster count")
    canonical = decoded.canonical_variant_names
    expected_positional = canonical.map do |name|
      name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? 0_u64 : literal_counts[name]? || 0_u64
    end
    require!(stats.counts == expected_positional, "#{owner}/#{site_path} statistics differ from independent literal occurrences")
    require!(shared_entries(stats.shared).empty?, "#{owner}/#{site_path} unexpected SharedVariant spill statistics")
    require!(grid.prefix_size == decoded_offset && grid.mark_count == expected_rows.size && grid.rows_per_mark == expected_rows,
      "#{owner}/#{site_path} statistics prefix or parent P grid differs")
    grid.mark_count.times do |index|
      require!(grid.position_at(index) == decoded_offset.to_i64, "#{owner}/#{site_path} mark #{index} misses statistics suffix")
    end
    require!(grid.position_at(grid.mark_count) == grid.logical_size, "#{owner}/#{site_path} terminal mark misses structure EOF")

    JSON::Any.new({
      "owner"                    => JSON::Any.new(owner),
      "site_path"                => JSON::Any.new(site_path),
      "json_type_name"           => (json_type_name ? JSON::Any.new(json_type_name) : JSON::Any.new(nil)),
      "physical_name"            => JSON::Any.new(logical_name),
      "version"                  => JSON::Any.new(decoded.version.to_i64),
      "legacy_max_dynamic_types" => (decoded.legacy_max_dynamic_types ? JSON::Any.new(decoded.legacy_max_dynamic_types.not_nil!.to_i64) : JSON::Any.new(nil)),
      "types"                    => json_strings(actual_types),
      "canonical_variant_names"  => json_strings(canonical),
      "mandatory_statistics"     => JSON::Any.new(true),
      "statistics"               => statistics_json(stats),
      "statistics_prefix_offset" => JSON::Any.new(decoded_offset.to_i64),
      "physical_grid"            => JSON::Any.new({
        "logical_size"      => JSON::Any.new(grid.logical_size),
        "prefix_size"       => JSON::Any.new(grid.prefix_size.to_i64),
        "mark_row_counts"   => json_uints(grid.rows_per_mark),
        "mark_positions"    => json_ints(grid.positions),
        "terminal_position" => JSON::Any.new(grid.position_at(grid.mark_count)),
      } of String => JSON::Any),
      "literal_actual_type_counts" => JSON::Any.new(literal_counts.to_h do |name, count|
        {name, JSON::Any.new(count.to_i64)}
      end),
    } of String => JSON::Any)
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
    require!(selected_version == CrystalClick::DynamicStructure::VERSION_V1 ||
             selected_version == CrystalClick::DynamicStructure::VERSION_V2,
      "raw Dynamic structure is not V1/V2")
    legacy = selected_version == CrystalClick::DynamicStructure::VERSION_V1 ? cursor.read_var_uint : nil
    count = cursor.read_var_uint
    require!(count <= CrystalClick::DynamicStructure::MAX_ORDINARY_TYPES.to_u64 && count <= Int32::MAX.to_u64,
      "raw Dynamic roster exceeds its bounded count")
    types = Array(String).new(count.to_i32) { cursor.read_string_binary }
    statistics_offset = cursor.offset
    canonical = (types + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
    counts = Array(UInt64).new(canonical.size) { cursor.read_var_uint }
    shared_count = cursor.read_var_uint
    require!(shared_count <= cursor.remaining.to_u64 // 2_u64, "raw shared map cannot fit in remaining structure")
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
      JSON::Any.new({"name" => JSON::Any.new(entry.name), "count" => JSON::Any.new(entry.count.to_i64)} of String => JSON::Any)
    end
    JSON::Any.new({
      "counts" => json_uints(statistics.counts),
      "shared" => JSON::Any.new(shared),
    } of String => JSON::Any)
  end

  private def structure_audits(part : String, site_reader : CrystalClick::DynamicBulkSiteReader, fixed : Fixture, origin : String) : Array(JSON::Any)
    parent_path = fixed[:sites].first
    actual_parent = site_reader.plan.structure_for(parent_path)
    expected_parent = if origin == "library"
                        [fixed[:json_used].name, fixed[:json_unused].name, u8_type.name]
                      else
                        [fixed[:json_used].name, u8_type.name]
                      end
    parent_counts = actual_parent_type_counts(fixed)
    audits = [raw_structure_audit(
      part,
      site_reader.physical.structure_name_for(parent_path),
      "dynamic_parent",
      parent_path,
      nil,
      fixed[:version],
      expected_parent,
      PARENT_ROWS,
      parent_counts,
    )]
    require!(actual_parent.types.map(&.name).sort == expected_parent.sort, "#{origin} parsed parent Dynamic roster differs")
    json_sites = site_reader.physical.json_object_sites
    expected_json_types = origin == "library" ? [fixed[:json_used].name, fixed[:json_unused].name].sort : [fixed[:json_used].name]
    require!(json_sites.map { |site| site.binding.json_type.name }.sort == expected_json_types,
      "#{origin} bound JSON Object actual roster differs")
    json_sites.each do |site|
      json_name = site.binding.json_type.name
      structure = site.binding.plan.structures.dynamic_for("counter")
      child_types = structure.types.map(&.name)
      require!(child_types == ["Int64"], "#{origin} JSON child counter roster differs")
      child_counts = actual_json_counter_type_counts(fixed, site.binding.json_type)
      audits << raw_structure_audit(
        part,
        site.physical_plan.dynamic_structure_stream("counter"),
        "json_counter_dynamic",
        "#{parent_path}/#{json_name}/counter",
        json_name,
        fixed[:version],
        ["Int64"],
        # CompressedMarkGrid exposes real marks only. The physical .mrk2
        # roster includes the separate EOF-zero sentinel in CHILD_ROWS.
        PARENT_ROWS,
        child_counts,
      )
    end
    audits
  end

  private def reader_record(part : String, fixed : Fixture, profile_name : String, origin : String) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(
      part, COLUMN, fixed[:type], CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::CompressedStreamLimits.new,
    )
    require!(reader.schema_declaration == fixed[:type].name, "#{origin} nominal schema differs")
    require!(reader.row_count == 6_u64 && reader.mark_count == 3, "#{origin} parent row/mark census differs")
    require!(reader.mark_row_counts == PARENT_ROWS, "#{origin} parent P grid differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} Dynamic String profile differs")
    marks = rows_by_mark(reader, fixed, origin)

    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_values = Array(Array(CrystalClick::BinaryValue)).new(fixed[:granules].size) { [] of CrystalClick::BinaryValue }
    table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
      mark = batch.mark_index
      require!(batch.part_index == 0 && mark >= 0 && mark < fixed[:granules].size, "#{origin} candidate batch identity differs")
      expected_offset = (mark * PARENT_ROWS.first).to_u64
      require!(batch.mark_row_offset == 0_u64 && batch.part_row_offset == expected_offset &&
               batch.source_row_offset == expected_offset, "#{origin} candidate offsets differ")
      table_values[mark] = batch.dynamic_bulk_values_for(COLUMN).to_a
    end
    table_values.each_with_index do |rows, mark|
      expected = fixed[:granules][mark]
      require!(rows.size == expected.size, "#{origin} public table candidate row count differs at mark #{mark}")
      rows.each_with_index do |value, row|
        require!(CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(expected[row]),
          "#{origin} public table candidate literal differs at #{mark}/#{row}")
      end
    end
    window_values = [] of CrystalClick::BinaryValue
    table.scan_typed_window(1_u64, 3) { |batch| window_values.concat(batch.dynamic_bulk_values_for(COLUMN).to_a) }
    expected_window = fixed[:granules].flatten[1, 3]
    require!(window_values.size == expected_window.size, "#{origin} public table window row count differs")
    window_values.each_with_index do |value, index|
      require!(CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(expected_window[index]),
        "#{origin} public table window literal differs at #{index}")
    end
    eof_callbacks = 0
    table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{origin} public table EOF window emitted a callback")

    source = origin == "stock_source"
    site_reader = read_site_reader(part, fixed, profile_name, reader.row_count)
    require!(site_reader.plan.site_paths.sort == fixed[:sites].sort, "#{origin} Dynamic site path roster differs")
    audits = structure_audits(part, site_reader, fixed, source ? "source" : "library")
    if source
      owned = CrystalClick::DynamicOwnedValuesW220.materialize(
        part, COLUMN, fixed[:type], reader.row_count, reader.mark_row_counts, fixed[:granules], reader.read_marks(0, reader.mark_count),
      )
      owned_json = CrystalClick::DynamicOwnedValuesW220.to_json(owned) { |value| row_signature(value, fixed[:case_id]) }
    else
      owned_json = JSON::Any.new(nil)
    end

    record = {
      "case_id"                 => JSON::Any.new(fixed[:case_id]),
      "profile_id"              => JSON::Any.new(profile_name),
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"              => JSON::Any.new(reader.mark_count),
      "mark_row_counts"         => json_uints(reader.mark_row_counts),
      "rows_by_mark"            => JSON::Any.new(marks.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names"   => json_strings(reader.physical_stream_names.sort!),
      "selected_checksum_names" => json_strings(reader.selected_checksum_names.sort!),
      "structure_audits"        => JSON::Any.new(audits),
      "owned_values"            => owned_json,
      "windows"                 => json_strings(["candidate_marks", "middle_window", "eof_zero"]),
    } of String => JSON::Any
    JSON::Any.new(record)
  end

  private def write_library_part!(path : String, fixed : Fixture, profile_name : String) : Nil
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      path,
      KEY_NAME,
      Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
      COLUMN,
      fixed[:type],
      fixed[:structures],
      fixed[:granules],
      rows_per_mark: 2,
      profile: profile(profile_name),
      frame_bytes: 4096,
      metadata_version: 0_i64,
      limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
      json_object_plans: fixed[:plans],
    )
    require!(result == path, "library writer returned a different part path")
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String, version_name : String, root_profile_name : String) : JSON::Any
    case_id = item["case_id"].as_s
    profile_name = item["profile_id"].as_s
    require!(CASE_IDS.includes?(case_id) && ["single_stream", "with_size_stream"].includes?(profile_name), "case/profile is outside fixed roster")
    require!(profile_name == root_profile_name && item["capture_root"].as_s == capture_root && item["version"].as_s == version_name,
      "case capture/version/profile differs from root selection")
    source_part = item["source_part"].as_s
    library_part = item["library_part"].as_s
    validate_path!(source_part, capture_root, false)
    validate_path!(library_part, output_root, true)
    fixed = fixture(case_id, version_name)
    write_library_part!(library_part, fixed, profile_name)
    source = reader_record(source_part, fixed, profile_name, "stock_source")
    library = reader_record(library_part, fixed, profile_name, "library")
    JSON::Any.new({
      "case_id"           => JSON::Any.new(case_id),
      "profile_id"        => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source"            => source,
      "library"           => library,
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_json_sql_type_name_w251.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W251 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W251 helper input must be a plain file below output root")
    end
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "dynamic_version", "format", "profile_id"] &&
             input["format"].as_s == FORMAT_INPUT, "helper input format differs")
    capture_root = input["capture_root"].as_s
    version_name = input["dynamic_version"].as_s
    profile_name = input["profile_id"].as_s
    version(version_name)
    profile(profile_name)
    expected_profile = version_name == "v1" ? "single_stream" : "with_size_stream"
    require!(profile_name == expected_profile, "root Dynamic version/profile pair differs")
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    expected = CASE_IDS
    observed = cases.map { |item| item["case_id"].as_s }
    require!(observed == expected, "case order differs from fixed W251 roster")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part", "version"],
        "case input keys differ")
    end
    results = cases.map { |item| process_case(item, capture_root, output_root, version_name, profile_name) }
    puts JSON::Any.new({
      "format"               => JSON::Any.new(FORMAT_OUTPUT),
      "dynamic_version"      => JSON::Any.new(version_name),
      "dynamic_version_wire" => JSON::Any.new(version(version_name).to_i64),
      "profile_id"           => JSON::Any.new(profile_name),
      "case_ids"             => json_strings(CASE_IDS),
      "parent_mark_rows"     => json_uints(PARENT_ROWS),
      "json_child_mark_rows" => json_uints(CHILD_ROWS),
      "cases"                => JSON::Any.new(results),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W251 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckJSONSQLTypeNameW251.main(ARGV)
