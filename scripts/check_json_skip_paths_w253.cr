require "../src/crystal_click"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckJSONSkipPathsW253
  extend self

  COLUMN          = "payload"
  KEY_NAME        = "pk"
  CASE_IDS        = ["root_dynamic", "array_dynamic", "root_object"]
  FORMAT_INPUT    = "json_skip_paths_w253_input_v1"
  FORMAT_OUTPUT   = "json_skip_paths_w253_helper_v1"
  PARENT_ROWS     = [2_u64, 2_u64, 2_u64]
  JSON_CHILD_ROWS = [2_u64, 2_u64, 2_u64, 0_u64]
  RAW_PATHS       = ["a.b", "a%2Eb", "a`b", "id", "maybe", "x=y"]
  DYNAMIC_PATHS   = ["counter", "secretary", "zz"]

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

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W253 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"    then CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream" then CrystalClick::BinaryBulkProfile.with_size_stream
    else                         raise ArgumentError.new("W253 profile is outside the fixed roster")
    end
  end

  private def version(name : String) : UInt64
    case name
    when "v1" then CrystalClick::DynamicStructure::VERSION_V1
    when "v2" then CrystalClick::DynamicStructure::VERSION_V2
    else           raise ArgumentError.new("W253 Dynamic version is outside the fixed roster")
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
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 3,
      max_dynamic_types: max_types,
      typed_paths: typed_paths,
      skip_paths: ["secret", "z"],
    )
  end

  private def profile_version_structure(
    types : Array(CrystalClick::BinaryDataType),
    counts : Hash(String, UInt64),
    selected_version : UInt64,
  ) : CrystalClick::DynamicStructure
    names = types.map(&.name)
    canonical = (names + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort!
    shared = counts.reject { |name, _| names.includes?(name) }
    statistics = CrystalClick::StructureStatistics.new(
      canonical.map do |name|
        name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? shared.values.sum(0_u64) : counts[name]? || 0_u64
      end,
      shared.map { |name, count| CrystalClick::StructureStatistic.new(name, count) }.sort_by(&.name),
    )
    CrystalClick::DynamicStructure.new(
      types,
      statistics,
      version: selected_version,
      legacy_max_dynamic_types: selected_version == CrystalClick::DynamicStructure::VERSION_V1 ? types.size.to_u64 : nil,
    )
  end

  private def json_plan(
    type : CrystalClick::BinaryDataType,
    selected_version : UInt64,
    count : UInt64,
  ) : CrystalClick::ObjectDocumentPlan
    counter = profile_version_structure([i64] of CrystalClick::BinaryDataType, {"Int64" => count}, selected_version)
    integer_child = profile_version_structure([i64] of CrystalClick::BinaryDataType, {"Int64" => count}, selected_version)
    child_structures = {
      "counter"   => counter,
      "secretary" => integer_child,
      "zz"        => integer_child,
    } of String => CrystalClick::DynamicStructure
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(DYNAMIC_PATHS),
      child_structures,
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
    secretary : Int64,
    zz : Int64,
  ) : CrystalClick::BinaryValue
    nullable = CrystalClick::BinaryDataType.nullable(u8)
    row = CrystalClick::BinaryJsonRow.new(type, [
      {"a.b", u8_value(dotted)}, {"a%2Eb", u8_value(percent)},
      {"a`b", u8_value(backtick)}, {"id", u8_value(id)},
      {"maybe", CrystalClick::BinaryValue.null(nullable)}, {"x=y", u8_value(equal)},
      {"counter", CrystalClick::BinaryValue.int64(counter)},
      {"secretary", CrystalClick::BinaryValue.int64(secretary)}, {"zz", CrystalClick::BinaryValue.int64(zz)},
    ] of Tuple(String, CrystalClick::BinaryValue))
    CrystalClick::BinaryValue.json(type, row)
  end

  private def json_signature(value : CrystalClick::BinaryValue) : String
    row = value.json_row
    require!(row.path_count == 9, "JSON row is not six typed paths plus three dynamic paths")
    require!(row.value_for("maybe").not_nil!.is_null?, "maybe Nullable(UInt8) is not NULL")
    values = RAW_PATHS.map do |path|
      child = row.value_for(path).not_nil!
      if path == "maybe"
        "null"
      else
        require!(child.type == u8, "typed JSON path #{path.inspect} is not UInt8")
        child.byte_at(0).to_s
      end
    end
    counter = row.value_for("counter").not_nil!
    secretary = row.value_for("secretary").not_nil!
    zz = row.value_for("zz").not_nil!
    require!(counter.type == i64 && secretary.type == i64 && zz.type == i64, "JSON dynamic child types differ")
    "json[#{values.join(",")};counter=#{counter.as_int64};secretary=#{secretary.as_int64};zz=#{zz.as_int64}]"
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

  private def fixture(case_id : String, version_name : String) : Fixture
    selected_version = version(version_name)
    used = json_type(1)
    unused = json_type(2)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 3)
    array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    site = case case_id
           when "root_dynamic"  then "root"
           when "array_dynamic" then "root.elements"
           else                      raise ArgumentError.new("W253 Dynamic fixture case is invalid")
           end
    uint_count = case case_id
                 when "root_dynamic"  then 4_u64
                 when "array_dynamic" then 3_u64
                 else                      raise ArgumentError.new("W253 Dynamic fixture case is invalid")
                 end
    parent_types = [used, unused, u8] of CrystalClick::BinaryDataType
    parent = profile_version_structure(parent_types, {used.name => 2_u64, "UInt8" => uint_count}, selected_version)
    structures = {site => parent}
    plans = [
      {site, parent.canonical_index_for(used), json_plan(used, selected_version, 2_u64)},
      {site, parent.canonical_index_for(unused), json_plan(unused, selected_version, 0_u64)},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    json = ->(id : UInt8, d : UInt8, p : UInt8, t : UInt8, x : UInt8, c : Int64, s : Int64, z : Int64) {
      value = json_value(used, id, d, p, t, x, c, s, z)
      CrystalClick::BinaryValue.dynamic(dynamic_type, value)
    }
    integer = ->(n : UInt8) { CrystalClick::BinaryValue.dynamic(dynamic_type, u8_value(n)) }
    if case_id == "root_dynamic"
      granules = [
        [integer.call(17_u8), integer.call(18_u8)] of CrystalClick::BinaryValue,
        [integer.call(19_u8), integer.call(20_u8)] of CrystalClick::BinaryValue,
        [json.call(41_u8, 17_u8, 23_u8, 31_u8, 42_u8, 401_i64, 51_i64, 61_i64),
         json.call(42_u8, 18_u8, 24_u8, 32_u8, 43_u8, 402_i64, 52_i64, 62_i64)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, type: dynamic_type, structures: structures, granules: granules, plans: plans,
       site: site, used: used, unused: unused}
    else
      empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
      values = [integer.call(17_u8), integer.call(18_u8)] of CrystalClick::BinaryValue
      array_two = CrystalClick::BinaryValue.array(array_type, values)
      array_one = CrystalClick::BinaryValue.array(array_type, [integer.call(19_u8)] of CrystalClick::BinaryValue)
      j1 = CrystalClick::BinaryValue.array(array_type, [json.call(41_u8, 17_u8, 23_u8, 31_u8, 42_u8, 401_i64, 51_i64, 61_i64)] of CrystalClick::BinaryValue)
      j2 = CrystalClick::BinaryValue.array(array_type, [json.call(42_u8, 18_u8, 24_u8, 32_u8, 43_u8, 402_i64, 52_i64, 62_i64)] of CrystalClick::BinaryValue)
      granules = [[empty, empty], [array_two, array_one], [j1, j2]] of Array(CrystalClick::BinaryValue)
      {case_id: case_id, type: array_type, structures: structures, granules: granules, plans: plans,
       site: site, used: used, unused: unused}
    end
  end

  private def expected_dynamic_rows(case_id : String) : Array(Array(String))
    json1 = "json[17,23,31,41,null,42;counter=401;secretary=51;zz=61]"
    json2 = "json[18,24,32,42,null,43;counter=402;secretary=52;zz=62]"
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

  private def dynamic_structure_report(name : String, structure : CrystalClick::DynamicStructure) : JSON::Any
    stats = structure.statistics || raise CrystalClick::CorruptPartError.new("W253 mandatory Dynamic statistics absent")
    JSON::Any.new({
      "site"                     => JSON::Any.new(name),
      "version"                  => JSON::Any.new(structure.version.to_i64),
      "legacy_max_dynamic_types" => (structure.legacy_max_dynamic_types ? JSON::Any.new(structure.legacy_max_dynamic_types.not_nil!.to_i64) : JSON::Any.new(nil)),
      "types"                    => json_strings(structure.types.map(&.name)),
      "canonical_variant_names"  => json_strings(structure.canonical_variant_names),
      "statistics"               => JSON::Any.new({
        "counts" => json_uints(stats.counts),
        "shared" => JSON::Any.new(stats.shared.map do |entry|
          JSON::Any.new({"name" => JSON::Any.new(entry.name), "count" => JSON::Any.new(entry.count.to_i64)} of String => JSON::Any)
        end),
      } of String => JSON::Any),
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

  private def structure_reports(part : String, fixed : Fixture, site_reader : CrystalClick::DynamicBulkSiteReader, version_name : String, origin : String) : Array(JSON::Any)
    parent = site_reader.plan.structure_for(fixed[:site])
    expected_parent = origin == "library" ? [fixed[:used].name, fixed[:unused].name, u8.name] : [fixed[:used].name, u8.name]
    require!(parent.types.map(&.name).sort == expected_parent.sort, "#{origin} parent Dynamic roster differs")
    reports = [dynamic_structure_report(fixed[:site], parent)]
    sites = site_reader.physical.json_object_sites
    expected_json = origin == "library" ? [fixed[:used].name, fixed[:unused].name].sort : [fixed[:used].name]
    require!(sites.map { |site| site.binding.json_type.name }.sort == expected_json, "#{origin} JSON Object binding roster differs")
    sites.each do |site|
      expected_count = site.binding.json_type == fixed[:used] ? 2_u64 : 0_u64
      DYNAMIC_PATHS.each do |path|
        child = site.binding.plan.structures.dynamic_for(path)
        expected_type = i64
        require!(child.types.map(&.name) == [expected_type.name], "#{origin} JSON child #{path} roster differs")
        reports << dynamic_structure_report("#{fixed[:site]}/#{site.binding.json_type.name}/#{path}", child)
        expected_counts = expected_count
        require!(child.statistics.not_nil!.counts.sum(0_u64) == expected_counts, "#{origin} JSON child #{path} occurrence count differs")
      end
    end
    reports
  end

  private def dynamic_signature_for_row(value : CrystalClick::BinaryValue, case_id : String) : String
    if case_id == "array_dynamic"
      "[#{value.elements.map { |item| dynamic_signature(item) }.join("|")}]"
    else
      dynamic_signature(value)
    end
  end

  private def dynamic_reader_record(part : String, fixed : Fixture, profile_name : String, version_name : String, origin : String) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(part, COLUMN, fixed[:type], CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, CrystalClick::CompressedStreamLimits.new)
    require!(reader.row_count == 6_u64 && reader.mark_count == 3 && reader.mark_row_counts == PARENT_ROWS, "#{origin} parent P grid differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} String profile differs")
    rows = reader.read_marks(0, reader.mark_count).map do |mark|
      mark.map { |value| dynamic_signature_for_row(value, fixed[:case_id]) }
    end
    require!(rows == expected_dynamic_rows(fixed[:case_id]), "#{origin} rows differ from independent W253 literals")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin} EOF-zero read is nonempty")

    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_rows = Array(Array(String)).new(3) { [] of String }
    table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
      require!(batch.part_index == 0 && batch.mark_row_offset == 0_u64, "#{origin} public table coordinate differs")
      table_rows[batch.mark_index] = batch.dynamic_bulk_values_for(COLUMN).map { |value| dynamic_signature_for_row(value, fixed[:case_id]) }.to_a
    end
    require!(table_rows == expected_dynamic_rows(fixed[:case_id]), "#{origin} public candidate scan differs")

    granules = reader.read_marks(0, reader.mark_count)
    owned = CrystalClick::DynamicOwnedValuesW220.materialize(
      part, COLUMN, fixed[:type], reader.row_count, reader.mark_row_counts, fixed[:granules], granules,
    )
    owned_report = CrystalClick::DynamicOwnedValuesW220.to_json(owned) do |value|
      dynamic_signature_for_row(value, fixed[:case_id])
    end
    site_reader = read_site_reader(part, fixed, profile_name, reader.row_count)
    require!(site_reader.plan.site_paths == [fixed[:site]], "#{origin} Dynamic site path differs")
    audits = structure_reports(part, fixed, site_reader, version_name, origin)
    json_sites = site_reader.physical.json_object_sites
    child_streams = json_sites.flat_map { |site| site.physical_plan.stream_names }.sort!
    JSON::Any.new({
      "case_id"                   => JSON::Any.new(fixed[:case_id]),
      "profile_id"                => JSON::Any.new(profile_name),
      "schema_declaration"        => JSON::Any.new(reader.schema_declaration),
      "row_count"                 => JSON::Any.new(6),
      "mark_count"                => JSON::Any.new(3),
      "mark_row_counts"           => json_uints(reader.mark_row_counts),
      "rows_by_mark"              => JSON::Any.new(rows.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names"     => json_strings(reader.physical_stream_names.sort!),
      "selected_checksum_names"   => json_strings(reader.selected_checksum_names.sort!),
      "object_child_stream_names" => json_strings(child_streams),
      "bound_json_type_names"     => json_strings(json_sites.map { |site| site.binding.json_type.name }.sort!),
      "structure_audits"          => JSON::Any.new(audits),
      "owned_values"              => owned_report,
      "offline_values"            => JSON::Any.new(nil),
      "windows"                   => json_strings(["candidate_marks", "eof_zero"]),
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
    require!(result == library_part, "Dynamic writer returned unexpected part path")
    JSON::Any.new({
      "case_id" => JSON::Any.new(case_id), "profile_id" => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(library_part),
      "source" => dynamic_reader_record(source_part, fixed, profile_name, version_name, "stock source"),
      "library" => dynamic_reader_record(library_part, fixed, profile_name, version_name, "library"),
    } of String => JSON::Any)
  end

  private def object_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(typed_paths, 3, 1, skip_paths: ["secret", "z"])
  end

  private def object_documents : Array(Array(CrystalClick::ObjectDocument))
    docs = (0...6).map do |index|
      n = index.to_u8
      values = {
        "a.b" => u8_value(17_u8 + n), "a%2Eb" => u8_value(23_u8 + n), "a`b" => u8_value(31_u8 + n),
        "id" => u8_value(41_u8 + n), "maybe" => CrystalClick::BinaryValue.null(CrystalClick::BinaryDataType.nullable(u8)),
        "x=y" => u8_value(42_u8 + n), "secretary" => CrystalClick::BinaryValue.int64(51_i64 + n), "zz" => CrystalClick::BinaryValue.int64(61_i64 + n),
      } of String => CrystalClick::BinaryValue
      CrystalClick::ObjectDocument.new(values)
    end
    docs.each_slice(2).map(&.to_a).to_a
  end

  private def object_signature(document : CrystalClick::ObjectDocument) : String
    values = RAW_PATHS.map do |path|
      value = document.value_for(path).not_nil!
      path == "maybe" ? "null" : value.byte_at(0).to_s
    end
    values << document.value_for("secretary").not_nil!.as_int64.to_s
    values << document.value_for("zz").not_nil!.as_int64.to_s
    values.join(",")
  end

  private def expected_object_rows : Array(Array(String))
    (0...6).map do |index|
      [(17 + index).to_s, (23 + index).to_s, (31 + index).to_s, (41 + index).to_s, "null",
       (42 + index).to_s, (51 + index).to_s, (61 + index).to_s].join(",")
    end.each_slice(2).map(&.to_a).to_a
  end

  private def object_reader_record(part : String, schema : CrystalClick::ObjectDocumentSchema, profile_name : String, origin : String) : JSON::Any
    reader = CrystalClick::ObjectColumnReader.open(part, COLUMN, schema)
    require!(reader.mark_row_counts == PARENT_ROWS, "#{origin} Object parent P grid differs")
    rows = reader.read_marks(0, reader.mark_row_counts.size).map { |mark| mark.map { |doc| object_signature(doc) } }
    require!(rows == expected_object_rows, "#{origin} Object raw path values differ")
    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_rows = [] of String
    table.scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
      table_rows.concat(batch.object_documents_for(COLUMN).map { |doc| object_signature(doc) })
    end
    require!(table_rows == expected_object_rows.flatten, "#{origin} Object public table rows differ")
    info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
    candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 6_u64)
    offline = CrystalClick::OfflineTable.new(
      "w253_object", "00000000-0000-0000-0000-000000000253", "MergeTree",
      [CrystalClick::OfflineColumn.new(KEY_NAME, "UInt64"), CrystalClick::OfflineColumn.new(COLUMN, schema.declaration)],
      [candidate], KEY_NAME,
    )
    offline_rows = offline[COLUMN].values.map { |value| object_signature(value.as(CrystalClick::ObjectDocument)) }
    require!(offline_rows == expected_object_rows.flatten, "#{origin} OfflineTable.values Object rows differ")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part, COLUMN, schema.typed_paths, reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream, true,
    )
    dynamic_paths = descriptor.plan.structures.object.dynamic_paths
    require!(dynamic_paths == ["secretary", "zz"], "#{origin} Object Dynamic path roster differs")
    selected_version = profile_name == "single_stream" ? CrystalClick::DynamicStructure::VERSION_V1 : CrystalClick::DynamicStructure::VERSION_V2
    audits = dynamic_paths.map do |path|
      structure = descriptor.plan.structures.dynamic_for(path)
      require!(structure.version == selected_version, "#{origin} Object Dynamic #{path} version differs")
      require!(structure.types.map(&.name) == [i64.name], "#{origin} Object Dynamic #{path} type roster differs")
      statistics = structure.statistics || raise CrystalClick::CorruptPartError.new("W253 Object Dynamic statistics absent")
      expected_counts = structure.canonical_variant_names.map do |name|
        name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? 0_u64 : 6_u64
      end
      expected_legacy_max = selected_version == CrystalClick::DynamicStructure::VERSION_V1 ? 1_u64 : nil
      require!(structure.legacy_max_dynamic_types == expected_legacy_max, "#{origin} Object Dynamic #{path} V1 roster count differs")
      require!(statistics.counts == expected_counts && statistics.shared.empty?, "#{origin} Object Dynamic #{path} statistics differ")
      dynamic_structure_report("root_object/#{path}", structure)
    end
    JSON::Any.new({
      "case_id" => JSON::Any.new("root_object"), "profile_id" => JSON::Any.new(profile_name),
      "schema_declaration" => JSON::Any.new(reader.schema_declaration), "row_count" => JSON::Any.new(6),
      "mark_count" => JSON::Any.new(reader.mark_row_counts.size), "mark_row_counts" => json_uints(PARENT_ROWS),
      "rows_by_mark" => JSON::Any.new(rows.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names" => json_strings(descriptor.physical_stream_names.sort!),
      "selected_checksum_names" => json_strings(descriptor.selected_checksum_names.sort!),
      "object_child_stream_names" => json_strings(descriptor.physical_stream_names.sort!),
      "bound_json_type_names" => json_strings([schema.declaration]),
      "structure_audits" => JSON::Any.new(audits),
      "owned_values" => JSON::Any.new(nil), "offline_values" => json_strings(offline_rows),
      "windows" => json_strings(["candidate_marks", "offline_values"]),
    } of String => JSON::Any)
  end

  private def object_fixture(profile_name : String, source_part : String, library_part : String) : JSON::Any
    schema = object_schema
    selected_version = profile_name == "single_stream" ? CrystalClick::DynamicStructure::VERSION_V1 : CrystalClick::DynamicStructure::VERSION_V2
    secretary = profile_version_structure([i64] of CrystalClick::BinaryDataType, {"Int64" => 6_u64}, selected_version)
    zz = profile_version_structure([i64] of CrystalClick::BinaryDataType, {"Int64" => 6_u64}, selected_version)
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["secretary", "zz"] of String),
        {"secretary" => secretary, "zz" => zz},
      ),
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

  private def process_case(item : JSON::Any, capture_root : String, output_root : String, version_name : String, profile_name : String) : JSON::Any
    case_id = item["case_id"].as_s
    require!(item.as_h.keys.sort == ["case_id", "capture_root", "library_part", "profile_id", "source_part", "version"].sort,
      "case input keys differ")
    require!(item["capture_root"].as_s == capture_root && item["version"].as_s == version_name && item["profile_id"].as_s == profile_name,
      "case binding differs")
    source_part = canonical_part(item["source_part"].as_s, capture_root, false)
    library_part = canonical_part(item["library_part"].as_s, output_root, true)
    case_id == "root_object" ? object_fixture(profile_name, source_part, library_part) : dynamic_fixture(case_id, version_name, profile_name, source_part, library_part)
  end

  def main(args : Array(String)) : Nil
    raise ArgumentError.new("usage: check_json_skip_paths_w253.cr INPUT.json OUTPUT_ROOT") unless args.size == 2
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "output root is not canonical")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "input is not a plain file below output root")
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "dynamic_version", "format", "profile_id"] &&
             input["format"].as_s == FORMAT_INPUT, "input format differs")
    version_name = input["dynamic_version"].as_s
    profile_name = input["profile_id"].as_s
    expected_profile = version_name == "v1" ? "single_stream" : "with_size_stream"
    version(version_name)
    profile(profile_name)
    require!(profile_name == expected_profile, "version/profile pair is outside the fixed W253 roster")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    require!(cases.map { |item| item["case_id"].as_s } == CASE_IDS, "case roster/order differs")
    results = cases.map { |item| process_case(item, capture_root, output_root, version_name, profile_name) }
    puts JSON::Any.new({
      "format" => JSON::Any.new(FORMAT_OUTPUT), "dynamic_version" => JSON::Any.new(version_name),
      "dynamic_version_wire" => JSON::Any.new(version(version_name).to_i64), "profile_id" => JSON::Any.new(profile_name),
      "case_ids" => json_strings(CASE_IDS), "parent_mark_rows" => json_uints(PARENT_ROWS),
      "json_child_mark_rows" => json_uints(JSON_CHILD_ROWS), "cases" => JSON::Any.new(results),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W253 helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end
end

CheckJSONSkipPathsW253.main(ARGV)
