#!/usr/bin/env crystal
# W217 stock-authored projection-child oracle. This checks only physical
# projection child reading/catalog scanning; it does not test projection
# writing, optimizer selection, or materialized-view execution.

require "digest/sha256"
require "file_utils"
require "json"
require "../src/crystal_click"

W217_BINARY                     = "/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped"
W217_BINARY_SHA256              = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W217_VERSION                    = "26.10.1.1201"
W217_BUILD                      = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W217_DATABASE                   = "w217_specialized_projection"
W217_TIMEOUT_SECONDS            =              10
W217_TERMINATION_GRACE_SECONDS  =               2
W217_MAX_MEMORY_BYTES           = 536_870_912_u64
W217_MAX_PHYSICAL_INPUT_ENTRIES =           4_096
W217_MAX_PHYSICAL_INPUT_BYTES   = 64_u64 * 1024_u64 * 1024_u64
W217_MAX_PHYSICAL_INPUT_DEPTH   = 32
W217_PARENT_PARTS               = ["all_1_1_0", "all_2_2_0"]
W217_PARENT_ROWS_PER_PART       = 6_u64
W217_PARENT_ROWS_TOTAL          = W217_PARENT_ROWS_PER_PART * W217_PARENT_PARTS.size.to_u64
W217_JSON_U64                   = "JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt64)"
W217_JSON_U8                    = "JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)"
W217_ARRAY_JSON_U8              = "Array(#{W217_JSON_U8})"
W217_DYNAMIC_U64                = "Dynamic(max_types=1)"
W217_ARRAY_DYNAMIC_U64          = "Array(#{W217_DYNAMIC_U64})"
W217_COUNT_KEY                  = "intDiv(pk, 2)"
W217_COUNT_STATE                = "count()"

alias W217PhysicalInputFile = Tuple(String, String, String, UInt64, String)

struct W217ProjectionCase
  getter id : String
  getter kind : String
  getter table_name : String
  getter column_declarations : String
  getter projection_select : String
  getter selected_columns : Array(String)
  getter source_types : Array(Tuple(String, String))
  getter child_types : Array(Tuple(String, String))
  getter insert_statements : Array(String)
  getter expected_by_part : Hash(String, Array(Array(String)))

  def initialize(
    @id : String,
    @kind : String,
    @table_name : String,
    @column_declarations : String,
    @projection_select : String,
    @selected_columns : Array(String),
    @source_types : Array(Tuple(String, String)),
    @child_types : Array(Tuple(String, String)),
    @insert_statements : Array(String),
    @expected_by_part : Hash(String, Array(Array(String))),
  )
  end
end

private def w217_assert(condition : Bool, message : String) : Nil
  raise "W217 specialized projection oracle: #{message}" unless condition
end

private def w217_settings(count_profile : Bool = false) : String
  base = "index_granularity=2, index_granularity_bytes=10485760, " \
         "enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, " \
         "min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, " \
         "min_compress_block_size=0, max_compress_block_size=4096, " \
         "default_compression_codec='LZ4', serialization_info_version='with_types', " \
         "propagate_types_serialization_versions_to_nested_types=1"
  unless count_profile
    base += ", dynamic_serialization_version='v3', object_serialization_version='v3', " \
            "object_shared_data_serialization_version_for_zero_level_parts='map'"
  else
    # This is the current Count metadata admission profile. Do not change the
    # profile of the JSON/Dynamic families to make Count decode more broadly.
    base += ", string_serialization_version='with_size_stream'"
  end
  base
end

private def w217_cases : Array(W217ProjectionCase)
  whole_part_a = [
    ["101", "7"], ["102", "0"], ["103", "8"],
    ["104", "9"], ["105", "10"], ["106", "11"],
  ] of Array(String)
  whole_part_b = [
    ["201", "21"], ["202", "22"], ["203", "23"],
    ["204", "24"], ["205", "25"], ["206", "26"],
  ] of Array(String)

  array_part_a = [
    ["101", "1", "7"], ["102", "0", "-"], ["103", "2", "8,9"],
    ["104", "2", "0,1"], ["105", "3", "10,11,12"], ["106", "1", "13"],
  ] of Array(String)
  array_part_b = [
    ["201", "0", "-"], ["202", "1", "21"], ["203", "2", "22,23"],
    ["204", "1", "24"], ["205", "0", "-"], ["206", "2", "26,27"],
  ] of Array(String)

  recursive_part_a = [
    ["101", "1", "10"], ["102", "2", "20"], ["103", "3", "30"],
    ["104", "4", "40"], ["105", "5", "50"], ["106", "6", "60"],
  ] of Array(String)
  recursive_part_b = [
    ["201", "21", "210"], ["202", "22", "220"], ["203", "23", "230"],
    ["204", "24", "240"], ["205", "25", "250"], ["206", "26", "260"],
  ] of Array(String)

  dynamic_part_a = [
    ["101", "UInt64", "7"], ["102", "UInt64", "0"], ["103", "UInt64", "8"],
    ["104", "UInt64", "9"], ["105", "UInt64", "10"], ["106", "UInt64", "11"],
  ] of Array(String)
  dynamic_part_b = [
    ["201", "UInt64", "21"], ["202", "UInt64", "22"], ["203", "UInt64", "23"],
    ["204", "UInt64", "24"], ["205", "UInt64", "25"], ["206", "UInt64", "26"],
  ] of Array(String)

  array_dynamic_part_a = [
    ["101", "1", "UInt64", "7"], ["102", "0", "-", "-"], ["103", "2", "UInt64,UInt64", "8,9"],
    ["104", "2", "UInt64,UInt64", "0,1"], ["105", "3", "UInt64,UInt64,UInt64", "10,11,12"], ["106", "1", "UInt64", "13"],
  ] of Array(String)
  array_dynamic_part_b = [
    ["201", "0", "-", "-"], ["202", "1", "UInt64", "21"], ["203", "2", "UInt64,UInt64", "22,23"],
    ["204", "1", "UInt64", "24"], ["205", "0", "-", "-"], ["206", "2", "UInt64,UInt64", "26,27"],
  ] of Array(String)

  count_part_a = [["50", "2"], ["51", "2"], ["52", "2"]] of Array(String)
  count_part_b = [["100", "2"], ["101", "2"], ["102", "2"]] of Array(String)

  whole_sql_a = "INSERT INTO #{W217_DATABASE}.whole_json VALUES " \
                "(101, CAST('{\"t\":7}', '#{W217_JSON_U64}')), " \
                "(102, CAST('{\"t\":0}', '#{W217_JSON_U64}')), " \
                "(103, CAST('{\"t\":8}', '#{W217_JSON_U64}')), " \
                "(104, CAST('{\"t\":9}', '#{W217_JSON_U64}')), " \
                "(105, CAST('{\"t\":10}', '#{W217_JSON_U64}')), " \
                "(106, CAST('{\"t\":11}', '#{W217_JSON_U64}'));"
  whole_sql_b = "INSERT INTO #{W217_DATABASE}.whole_json VALUES " \
                "(201, CAST('{\"t\":21}', '#{W217_JSON_U64}')), " \
                "(202, CAST('{\"t\":22}', '#{W217_JSON_U64}')), " \
                "(203, CAST('{\"t\":23}', '#{W217_JSON_U64}')), " \
                "(204, CAST('{\"t\":24}', '#{W217_JSON_U64}')), " \
                "(205, CAST('{\"t\":25}', '#{W217_JSON_U64}')), " \
                "(206, CAST('{\"t\":26}', '#{W217_JSON_U64}'));"

  array_sql_a = "INSERT INTO #{W217_DATABASE}.array_json VALUES " \
                "(101, CAST([CAST('{\"t\":7}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(102, CAST([], '#{W217_ARRAY_JSON_U8}')), " \
                "(103, CAST([CAST('{\"t\":8}', '#{W217_JSON_U8}'), CAST('{\"t\":9}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(104, CAST([CAST('{\"t\":0}', '#{W217_JSON_U8}'), CAST('{\"t\":1}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(105, CAST([CAST('{\"t\":10}', '#{W217_JSON_U8}'), CAST('{\"t\":11}', '#{W217_JSON_U8}'), CAST('{\"t\":12}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(106, CAST([CAST('{\"t\":13}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}'));"
  array_sql_b = "INSERT INTO #{W217_DATABASE}.array_json VALUES " \
                "(201, CAST([], '#{W217_ARRAY_JSON_U8}')), " \
                "(202, CAST([CAST('{\"t\":21}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(203, CAST([CAST('{\"t\":22}', '#{W217_JSON_U8}'), CAST('{\"t\":23}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(204, CAST([CAST('{\"t\":24}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}')), " \
                "(205, CAST([], '#{W217_ARRAY_JSON_U8}')), " \
                "(206, CAST([CAST('{\"t\":26}', '#{W217_JSON_U8}'), CAST('{\"t\":27}', '#{W217_JSON_U8}')], '#{W217_ARRAY_JSON_U8}'));"

  recursive_type = "Tuple(doc #{W217_JSON_U8}, n UInt64)"
  recursive_sql_a = "INSERT INTO #{W217_DATABASE}.recursive_json VALUES " \
                    "(101, CAST(tuple(CAST('{\"t\":1}', '#{W217_JSON_U8}'), toUInt64(10)), '#{recursive_type}')), " \
                    "(102, CAST(tuple(CAST('{\"t\":2}', '#{W217_JSON_U8}'), toUInt64(20)), '#{recursive_type}')), " \
                    "(103, CAST(tuple(CAST('{\"t\":3}', '#{W217_JSON_U8}'), toUInt64(30)), '#{recursive_type}')), " \
                    "(104, CAST(tuple(CAST('{\"t\":4}', '#{W217_JSON_U8}'), toUInt64(40)), '#{recursive_type}')), " \
                    "(105, CAST(tuple(CAST('{\"t\":5}', '#{W217_JSON_U8}'), toUInt64(50)), '#{recursive_type}')), " \
                    "(106, CAST(tuple(CAST('{\"t\":6}', '#{W217_JSON_U8}'), toUInt64(60)), '#{recursive_type}'));"
  recursive_sql_b = "INSERT INTO #{W217_DATABASE}.recursive_json VALUES " \
                    "(201, CAST(tuple(CAST('{\"t\":21}', '#{W217_JSON_U8}'), toUInt64(210)), '#{recursive_type}')), " \
                    "(202, CAST(tuple(CAST('{\"t\":22}', '#{W217_JSON_U8}'), toUInt64(220)), '#{recursive_type}')), " \
                    "(203, CAST(tuple(CAST('{\"t\":23}', '#{W217_JSON_U8}'), toUInt64(230)), '#{recursive_type}')), " \
                    "(204, CAST(tuple(CAST('{\"t\":24}', '#{W217_JSON_U8}'), toUInt64(240)), '#{recursive_type}')), " \
                    "(205, CAST(tuple(CAST('{\"t\":25}', '#{W217_JSON_U8}'), toUInt64(250)), '#{recursive_type}')), " \
                    "(206, CAST(tuple(CAST('{\"t\":26}', '#{W217_JSON_U8}'), toUInt64(260)), '#{recursive_type}'));"

  dynamic_sql_a = "INSERT INTO #{W217_DATABASE}.dynamic_root VALUES " \
                  "(101, CAST(toUInt64(7), '#{W217_DYNAMIC_U64}')), " \
                  "(102, CAST(toUInt64(0), '#{W217_DYNAMIC_U64}')), " \
                  "(103, CAST(toUInt64(8), '#{W217_DYNAMIC_U64}')), " \
                  "(104, CAST(toUInt64(9), '#{W217_DYNAMIC_U64}')), " \
                  "(105, CAST(toUInt64(10), '#{W217_DYNAMIC_U64}')), " \
                  "(106, CAST(toUInt64(11), '#{W217_DYNAMIC_U64}'));"
  dynamic_sql_b = "INSERT INTO #{W217_DATABASE}.dynamic_root VALUES " \
                  "(201, CAST(toUInt64(21), '#{W217_DYNAMIC_U64}')), " \
                  "(202, CAST(toUInt64(22), '#{W217_DYNAMIC_U64}')), " \
                  "(203, CAST(toUInt64(23), '#{W217_DYNAMIC_U64}')), " \
                  "(204, CAST(toUInt64(24), '#{W217_DYNAMIC_U64}')), " \
                  "(205, CAST(toUInt64(25), '#{W217_DYNAMIC_U64}')), " \
                  "(206, CAST(toUInt64(26), '#{W217_DYNAMIC_U64}'));"

  array_dynamic_sql_a = "INSERT INTO #{W217_DATABASE}.dynamic_array VALUES " \
                        "(101, CAST([CAST(toUInt64(7), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(102, CAST([], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(103, CAST([CAST(toUInt64(8), '#{W217_DYNAMIC_U64}'), CAST(toUInt64(9), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(104, CAST([CAST(toUInt64(0), '#{W217_DYNAMIC_U64}'), CAST(toUInt64(1), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(105, CAST([CAST(toUInt64(10), '#{W217_DYNAMIC_U64}'), CAST(toUInt64(11), '#{W217_DYNAMIC_U64}'), CAST(toUInt64(12), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(106, CAST([CAST(toUInt64(13), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}'));"
  array_dynamic_sql_b = "INSERT INTO #{W217_DATABASE}.dynamic_array VALUES " \
                        "(201, CAST([], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(202, CAST([CAST(toUInt64(21), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(203, CAST([CAST(toUInt64(22), '#{W217_DYNAMIC_U64}'), CAST(toUInt64(23), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(204, CAST([CAST(toUInt64(24), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(205, CAST([], '#{W217_ARRAY_DYNAMIC_U64}')), " \
                        "(206, CAST([CAST(toUInt64(26), '#{W217_DYNAMIC_U64}'), CAST(toUInt64(27), '#{W217_DYNAMIC_U64}')], '#{W217_ARRAY_DYNAMIC_U64}'));"

  # Three adjacent key pairs per parent make the projection aggregate to
  # three child rows, rather than six source rows.
  count_sql_a = "INSERT INTO #{W217_DATABASE}.count_parent VALUES (100), (101), (102), (103), (104), (105);"
  count_sql_b = "INSERT INTO #{W217_DATABASE}.count_parent VALUES (200), (201), (202), (203), (204), (205);"

  [
    W217ProjectionCase.new(
      "whole_json", "object", "whole_json", "pk UInt64, payload #{W217_JSON_U64}",
      "SELECT pk, payload ORDER BY pk", ["pk", "payload"],
      [{"pk", "UInt64"}, {"payload", W217_JSON_U64}],
      [{"pk", "UInt64"}, {"payload", W217_JSON_U64}],
      [whole_sql_a, whole_sql_b],
      {"all_1_1_0" => whole_part_a, "all_2_2_0" => whole_part_b},
    ),
    W217ProjectionCase.new(
      "array_json", "array_object", "array_json", "pk UInt64, a #{W217_ARRAY_JSON_U8}",
      "SELECT pk, a ORDER BY pk", ["pk", "a"],
      [{"pk", "UInt64"}, {"a", W217_ARRAY_JSON_U8}],
      [{"pk", "UInt64"}, {"a", W217_ARRAY_JSON_U8}],
      [array_sql_a, array_sql_b],
      {"all_1_1_0" => array_part_a, "all_2_2_0" => array_part_b},
    ),
    W217ProjectionCase.new(
      "recursive_json", "recursive", "recursive_json", "pk UInt64, payload #{recursive_type}",
      "SELECT pk, payload ORDER BY pk", ["pk", "payload"],
      [{"pk", "UInt64"}, {"payload", recursive_type}],
      [{"pk", "UInt64"}, {"payload", recursive_type}],
      [recursive_sql_a, recursive_sql_b],
      {"all_1_1_0" => recursive_part_a, "all_2_2_0" => recursive_part_b},
    ),
    W217ProjectionCase.new(
      "dynamic_root", "dynamic", "dynamic_root", "pk UInt64, payload #{W217_DYNAMIC_U64}",
      "SELECT pk, payload ORDER BY pk", ["pk", "payload"],
      [{"pk", "UInt64"}, {"payload", W217_DYNAMIC_U64}],
      [{"pk", "UInt64"}, {"payload", W217_DYNAMIC_U64}],
      [dynamic_sql_a, dynamic_sql_b],
      {"all_1_1_0" => dynamic_part_a, "all_2_2_0" => dynamic_part_b},
    ),
    W217ProjectionCase.new(
      "dynamic_array", "dynamic_array", "dynamic_array", "pk UInt64, wrapped #{W217_ARRAY_DYNAMIC_U64}",
      "SELECT pk, wrapped ORDER BY pk", ["pk", "wrapped"],
      [{"pk", "UInt64"}, {"wrapped", W217_ARRAY_DYNAMIC_U64}],
      [{"pk", "UInt64"}, {"wrapped", W217_ARRAY_DYNAMIC_U64}],
      [array_dynamic_sql_a, array_dynamic_sql_b],
      {"all_1_1_0" => array_dynamic_part_a, "all_2_2_0" => array_dynamic_part_b},
    ),
    W217ProjectionCase.new(
      "count", "count", "count_parent", "pk UInt64",
      "SELECT intDiv(pk, 2) AS bucket, count() AS c GROUP BY bucket",
      [W217_COUNT_KEY, W217_COUNT_STATE],
      [{"pk", "UInt64"}],
      [{W217_COUNT_KEY, "UInt64"}, {W217_COUNT_STATE, "AggregateFunction(count)"}],
      [count_sql_a, count_sql_b],
      {"all_1_1_0" => count_part_a, "all_2_2_0" => count_part_b},
    ),
  ] of W217ProjectionCase
end

private def w217_case_sql(test_case : W217ProjectionCase) : String
  count_profile = test_case.kind == "count"
  statements = [
    "SELECT '__W217_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
    "CREATE DATABASE #{W217_DATABASE} ENGINE = Atomic;",
    "CREATE TABLE #{W217_DATABASE}.#{test_case.table_name} (#{test_case.column_declarations}, PROJECTION p (#{test_case.projection_select})) ENGINE = MergeTree ORDER BY pk SETTINGS #{w217_settings(count_profile)};",
    "SYSTEM STOP MERGES #{W217_DATABASE}.#{test_case.table_name};",
  ]
  statements.concat(test_case.insert_statements)
  statements << "SELECT '__W217_CHECK_BEGIN__', '#{test_case.id}' FORMAT TSVRaw;"
  statements << "CHECK TABLE #{W217_DATABASE}.#{test_case.table_name} FORMAT TSV;"
  statements << "SELECT '__W217_CHECK_END__', '#{test_case.id}' FORMAT TSVRaw;"
  statements << "SELECT '__W217_SCHEMA__', name, type FROM system.columns WHERE database='#{W217_DATABASE}' AND table='#{test_case.table_name}' ORDER BY position FORMAT TSVRaw;"
  statements << "SELECT '__W217_PARENT__', table, name, path, toString(rows), toString(marks), part_type FROM system.parts WHERE database='#{W217_DATABASE}' AND table='#{test_case.table_name}' AND active ORDER BY min_block_number FORMAT TSVRaw;"
  statements << w217_stock_rows_sql(test_case)
  statements << "SELECT '__W217_EOF__', '#{test_case.id}', toString(count()) FROM #{W217_DATABASE}.#{test_case.table_name} SETTINGS optimize_use_projections=0 FORMAT TSVRaw;"
  statements.join("\n") + "\n"
end

private def w217_stock_rows_sql(test_case : W217ProjectionCase) : String
  table = "#{W217_DATABASE}.#{test_case.table_name}"
  if test_case.kind == "count"
    return "SELECT '__W217_ROWS__', _part, toString(intDiv(pk, 2)) AS bucket, toString(count()) " \
           "FROM #{table} GROUP BY _part, bucket ORDER BY _part, bucket " \
           "SETTINGS optimize_use_projections=0 FORMAT TSVRaw;"
  end

  selected = case test_case.kind
             when "object"
               "toString(pk), toString(payload.t)"
             when "array_object"
               "toString(pk), toString(length(a)), if(length(a)=0, '-', arrayStringConcat(arrayMap(x -> toString(x.t), a), ','))"
             when "recursive"
               "toString(pk), toString(payload.doc.t), toString(payload.n)"
             when "dynamic"
               "toString(pk), dynamicType(payload), ifNull(toString(dynamicElement(payload, 'UInt64')), '')"
             when "dynamic_array"
               "toString(pk), toString(length(wrapped)), if(length(wrapped)=0, '-', arrayStringConcat(arrayMap(x -> dynamicType(x), wrapped), ',')), if(length(wrapped)=0, '-', arrayStringConcat(arrayMap(x -> ifNull(toString(dynamicElement(x, 'UInt64')), ''), wrapped), ','))"
             else
               raise "unhandled W217 case kind: #{test_case.kind}"
             end
  "SELECT '__W217_ROWS__', _part, #{selected} FROM #{table} ORDER BY _part, pk " \
  "SETTINGS optimize_use_projections=0 FORMAT TSVRaw;"
end

private def w217_write_new(path : String, contents : String) : Nil
  w217_assert(!File.exists?(path), "refusing to overwrite evidence file #{path}")
  File.write(path, contents)
end

private def w217_sha256_file(path : String) : String
  digest = Digest::SHA256.new
  File.open(path, "rb") do |file|
    buffer = Bytes.new(64 * 1024)
    loop do
      size = file.read(buffer)
      break if size == 0
      digest.update(buffer[0, size])
    end
  end
  digest.final.hexstring
end

private def w217_source_manifest(repo_root : String, script_path : String) : String
  paths = [] of String
  root_entrypoint = File.join(repo_root, "src", "crystal_click.cr")
  paths << root_entrypoint if File.file?(root_entrypoint)
  paths.concat(Dir.glob(File.join(repo_root, "src", "crystal_click", "**", "*.cr")))
  paths << script_path
  paths = paths.uniq.sort

  JSON.build do |json|
    json.object do
      json.field "format", "w217_specialized_projection_source_manifest_v1"
      json.field "source_revision", ENV["W217_SOURCE_REVISION"]?
      json.field "repository_root", repo_root
      json.field "files" do
        json.array do
          paths.each do |path|
            canonical = File.real_path(path)
            w217_assert(canonical.starts_with?(repo_root + "/"), "source file escaped repository: #{canonical}")
            w217_assert(!File.symlink?(path), "source file is a symlink: #{path}")
            json.object do
              json.field "path", canonical[repo_root.bytesize + 1, canonical.bytesize - repo_root.bytesize - 1]
              json.field "size_bytes", File.size(canonical)
              json.field "sha256", w217_sha256_file(canonical)
            end
          end
        end
      end
    end
  end + "\n"
end

private def w217_rows(snapshot : String, label : String) : Array(Array(String))
  snapshot.lines.compact_map do |line|
    fields = line.strip.split('\t')
    fields if fields[0]? == label
  end
end

private def w217_grouped_rows(snapshot : String, label : String) : Hash(String, Array(Array(String)))
  groups = Hash(String, Array(Array(String))).new do |hash, part|
    hash[part] = [] of Array(String)
  end
  w217_rows(snapshot, label).each do |fields|
    w217_assert(fields.size >= 3, "malformed #{label} row: #{fields.inspect}")
    groups[fields[1]] << fields[2, fields.size - 2]
  end
  groups
end

private def w217_section_rows(snapshot : String, begin_marker : String, end_marker : String, case_id : String) : Array(Array(String))
  inside = false
  rows = [] of Array(String)
  snapshot.lines.each do |line|
    fields = line.strip.split('\t')
    if fields[0]? == begin_marker && fields[1]? == case_id
      w217_assert(!inside, "duplicate #{begin_marker} marker for #{case_id}")
      inside = true
      next
    end
    if fields[0]? == end_marker && fields[1]? == case_id
      w217_assert(inside, "unexpected #{end_marker} marker for #{case_id}")
      inside = false
      break
    end
    rows << fields if inside && !fields.empty?
  end
  w217_assert(!inside, "missing #{end_marker} marker for #{case_id}")
  rows
end

private def w217_assert_equal_rows(actual : Hash(String, Array(Array(String))), expected : Hash(String, Array(Array(String))), label : String) : Nil
  w217_assert(actual.keys.sort == expected.keys.sort, "#{label} parent-part roster differs: #{actual.keys.sort.inspect}")
  expected.each do |part, rows|
    w217_assert(actual[part] == rows, "#{label} rows differ for #{part}: #{actual[part].inspect}; expected #{rows.inspect}")
  end
end

private def w217_write_input_manifest(
  path : String,
  test_case : W217ProjectionCase,
  sql : String,
  binary_sha : String,
  script_sha : String,
  store : String,
  source_manifest_sha : String,
) : Nil
  contents = JSON.build do |json|
    json.object do
      json.field "format", "w217_specialized_projection_input_v1"
      json.field "case", test_case.id
      json.field "kind", test_case.kind
      json.field "database", W217_DATABASE
      json.field "table", test_case.table_name
      json.field "projection", "p"
      json.field "store", store
      json.field "clickhouse_binary", W217_BINARY
      json.field "clickhouse_binary_sha256", binary_sha
      json.field "expected_clickhouse_version", W217_VERSION
      json.field "expected_clickhouse_build", W217_BUILD
      json.field "source_revision", ENV["W217_SOURCE_REVISION"]?
      json.field "source_manifest_sha256", source_manifest_sha
      json.field "oracle_script", File.real_path(__FILE__)
      json.field "oracle_script_sha256", script_sha
      json.field "sql_sha256", Digest::SHA256.hexdigest(sql.to_slice)
      json.field "timeout_seconds", W217_TIMEOUT_SECONDS
      json.field "termination_grace_seconds", W217_TERMINATION_GRACE_SECONDS
      json.field "max_threads", 1
      json.field "max_insert_threads", 1
      json.field "max_memory_usage_bytes", W217_MAX_MEMORY_BYTES
      json.field "stop_merges", true
      json.field "separate_six_row_inserts", true
      json.field "parent_parts" do
        json.array { W217_PARENT_PARTS.each { |part| json.string(part) } }
      end
      json.field "source_types" do
        json.array do
          test_case.source_types.each do |name, type|
            json.object do
              json.field "name", name
              json.field "type", type
            end
          end
        end
      end
      json.field "selected_projection_columns" do
        json.array { test_case.selected_columns.each { |column| json.string(column) } }
      end
      json.field "expected_child_types" do
        json.array do
          test_case.child_types.each do |name, type|
            json.object do
              json.field "name", name
              json.field "type", type
            end
          end
        end
      end
      json.field "expected_semantic_rows_by_part" do
        json.object do
          test_case.expected_by_part.each do |part, rows|
            json.field part do
              json.array do
                rows.each do |row|
                  json.array { row.each { |value| json.string(value) } }
                end
              end
            end
          end
        end
      end
      json.field "sql", sql
      json.field "scope_boundary", "stock-authored physical projection child readers only; no projection writing/planning/optimizer/MV claim"
    end
  end
  w217_write_new(path, contents + "\n")
end

private def w217_run_native(binary : String, store : String, sql_path : String, sql : String, result_dir : String, case_id : String) : Tuple(Bool, String)
  stdout_path = File.join(result_dir, "#{case_id}.stdout")
  stderr_path = File.join(result_dir, "#{case_id}.stderr")
  record_path = File.join(result_dir, "#{case_id}.process.json")
  argv = [binary, "local", "--path", store, "--multiquery", "--max_threads=1", "--max_insert_threads=1", "--max_memory_usage=#{W217_MAX_MEMORY_BYTES}", "--max_query_size=1048576", "--query", sql] of String
  timed_out = false
  status = nil.as(Process::Status?)
  process_error : String? = nil

  begin
    File.open(stdout_path, "wb") do |stdout_file|
      File.open(stderr_path, "wb") do |stderr_file|
        child = Process.new(binary, argv[1..], output: stdout_file, error: stderr_file)
        waited = false
        begin
          deadline = Time.instant + W217_TIMEOUT_SECONDS.seconds
          until child.terminated?
            if Time.instant >= deadline
              timed_out = true
              child.terminate unless child.terminated?
              grace_deadline = Time.instant + W217_TERMINATION_GRACE_SECONDS.seconds
              until child.terminated? || Time.instant >= grace_deadline
                sleep 10.milliseconds
              end
              child.signal(Signal::KILL) unless child.terminated?
              break
            end
            sleep 10.milliseconds
          end
          status = child.wait
          waited = true
        ensure
          unless waited
            child.signal(Signal::KILL) unless child.terminated?
            begin
              child.wait
            rescue Channel::ClosedError
            end
          end
        end
      end
    end
  rescue ex
    process_error = "#{ex.class}: #{ex.message}"
  end

  stdout_sha = File.exists?(stdout_path) ? w217_sha256_file(stdout_path) : nil
  stderr_sha = File.exists?(stderr_path) ? w217_sha256_file(stderr_path) : nil
  success = !timed_out && process_error.nil? && status.try(&.success?) == true
  process_record = JSON.build do |json|
    json.object do
      json.field "case", case_id
      json.field "argv", argv
      json.field "sql_file", sql_path
      json.field "timeout_seconds", W217_TIMEOUT_SECONDS
      json.field "termination_grace_seconds", W217_TERMINATION_GRACE_SECONDS
      json.field "timed_out", timed_out
      json.field "process_error", process_error
      json.field "success", success
      json.field "exit_code", status.try(&.exit_code)
      json.field "exit_signal", status.try(&.exit_signal?).try(&.to_s)
      json.field "stdout_file", stdout_path
      json.field "stdout_sha256", stdout_sha
      json.field "stderr_file", stderr_path
      json.field "stderr_sha256", stderr_sha
    end
  end
  w217_write_new(record_path, process_record + "\n")
  w217_assert(File.size(stdout_path) <= 16 * 1024 * 1024, "#{case_id} stdout exceeds 16 MiB") if File.exists?(stdout_path)
  w217_assert(File.size(stderr_path) <= 16 * 1024 * 1024, "#{case_id} stderr exceeds 16 MiB") if File.exists?(stderr_path)
  detail = if process_error
             process_error
           elsif status
             "exit=#{status.exit_code} signal=#{status.exit_signal?.try(&.to_s)} timeout=#{timed_out} stderr=#{File.exists?(stderr_path) ? File.read(stderr_path) : ""}"
           else
             "no process status was recorded"
           end
  {success, detail}
end

private def w217_expected_parent_rows : UInt64
  W217_PARENT_ROWS_TOTAL
end

private def w217_collect_physical_input_files(
  canonical_store : String,
  canonical_parent : String,
  parent_name : String,
  current_path : String,
  depth : Int32,
  files : Array(W217PhysicalInputFile),
) : Tuple(Int32, UInt64)
  w217_assert(depth <= W217_MAX_PHYSICAL_INPUT_DEPTH, "physical input tree exceeds maximum depth")
  entries = 0
  total_bytes = 0_u64

  Dir.children(current_path).sort.each do |name|
    entries += 1
    w217_assert(entries <= W217_MAX_PHYSICAL_INPUT_ENTRIES, "physical input tree exceeds entry budget")
    entry_path = File.join(current_path, name)
    w217_assert(!File.symlink?(entry_path), "physical input contains a symlink: #{entry_path}")
    canonical_entry = File.real_path(entry_path)
    w217_assert(canonical_entry == File.expand_path(entry_path), "physical input path is not canonical: #{entry_path}")
    w217_assert(canonical_entry.starts_with?(canonical_parent + "/"), "physical input escaped its parent part: #{canonical_entry}")
    w217_assert(canonical_entry.starts_with?(canonical_store + "/"), "physical input escaped its isolated store: #{canonical_entry}")

    if File.directory?(entry_path)
      child_entries, child_bytes = w217_collect_physical_input_files(
        canonical_store, canonical_parent, parent_name, canonical_entry, depth + 1, files
      )
      entries += child_entries
      w217_assert(entries <= W217_MAX_PHYSICAL_INPUT_ENTRIES, "physical input tree exceeds entry budget")
      w217_assert(child_bytes <= W217_MAX_PHYSICAL_INPUT_BYTES - total_bytes, "physical input tree exceeds byte budget")
      total_bytes += child_bytes
    elsif File.file?(entry_path)
      size_bytes = File.size(entry_path).to_u64
      w217_assert(size_bytes <= W217_MAX_PHYSICAL_INPUT_BYTES - total_bytes, "physical input tree exceeds byte budget")
      total_bytes += size_bytes
      relative_path = canonical_entry[canonical_parent.bytesize + 1, canonical_entry.bytesize - canonical_parent.bytesize - 1]
      files << {parent_name, relative_path, canonical_entry, size_bytes, w217_sha256_file(canonical_entry)}
    else
      raise "W217 specialized projection oracle: physical input is not a plain file or directory: #{entry_path}"
    end
  end

  {entries, total_bytes}
end

private def w217_physical_input_manifest(case_id : String, store : String, paths : Array(String)) : String
  w217_assert(paths.size == W217_PARENT_PARTS.size, "physical input manifest received #{paths.size} parent paths")
  w217_assert(!File.symlink?(store), "isolated store is a symlink: #{store}")
  canonical_store = File.real_path(store)
  w217_assert(canonical_store == File.expand_path(store), "isolated store path is not canonical: #{store}")

  parents = paths.map do |path|
    w217_assert(!File.symlink?(path), "parent part is a symlink: #{path}")
    canonical_parent = File.real_path(path)
    w217_assert(canonical_parent == File.expand_path(path), "parent part path is not canonical: #{path}")
    w217_assert(canonical_parent.starts_with?(canonical_store + "/"), "parent part escaped its isolated store: #{canonical_parent}")
    parent_name = File.basename(canonical_parent)
    w217_assert(W217_PARENT_PARTS.includes?(parent_name), "unexpected parent part in physical input manifest: #{parent_name}")
    {parent_name, canonical_parent}
  end.sort_by(&.[0])

  w217_assert(parents.map(&.[0]) == W217_PARENT_PARTS.sort, "physical input manifest parent roster differs: #{parents.map(&.[0]).inspect}")
  files = [] of W217PhysicalInputFile
  total_entries = 0
  total_bytes = 0_u64
  parents.each do |parent_name, parent_path|
    entries, bytes = w217_collect_physical_input_files(
      canonical_store, parent_path, parent_name, parent_path, 0, files
    )
    total_entries += entries
    w217_assert(total_entries <= W217_MAX_PHYSICAL_INPUT_ENTRIES, "physical input manifest exceeds entry budget")
    w217_assert(bytes <= W217_MAX_PHYSICAL_INPUT_BYTES - total_bytes, "physical input manifest exceeds byte budget")
    total_bytes += bytes
  end
  w217_assert(!files.empty?, "physical input manifest found no plain files")
  files.sort_by! { |entry| "#{entry[0]}/#{entry[1]}" }

  JSON.build do |json|
    json.object do
      json.field "format", "w217_stock_projection_physical_inputs_v1"
      json.field "case", case_id
      json.field "complete", true
      json.field "store", canonical_store
      json.field "max_entries", W217_MAX_PHYSICAL_INPUT_ENTRIES
      json.field "max_total_bytes", W217_MAX_PHYSICAL_INPUT_BYTES
      json.field "max_depth", W217_MAX_PHYSICAL_INPUT_DEPTH
      json.field "entry_count", total_entries
      json.field "file_count", files.size
      json.field "total_bytes", total_bytes
      json.field "parent_parts" do
        json.array do
          parents.each do |parent_name, parent_path|
            json.object do
              json.field "name", parent_name
              json.field "canonical_path", parent_path
            end
          end
        end
      end
      json.field "files" do
        json.array do
          files.each do |parent_name, relative_path, canonical_path, size_bytes, sha256|
            json.object do
              json.field "parent", parent_name
              json.field "relative_path", relative_path
              json.field "canonical_path", canonical_path
              json.field "size_bytes", size_bytes
              json.field "sha256", sha256
            end
          end
        end
      end
    end
  end + "\n"
end

private def w217_capture_physical_input_manifest(case_id : String, store : String, paths : Array(String)) : Tuple(String, Bool)
  {w217_physical_input_manifest(case_id, store, paths), true}
rescue ex
  failure = JSON.build do |json|
    json.object do
      json.field "format", "w217_stock_projection_physical_inputs_failure_v1"
      json.field "case", case_id
      json.field "complete", false
      json.field "error_class", ex.class.to_s
      json.field "error", ex.message
    end
  end + "\n"
  {failure, false}
end

private def w217_validate_native_snapshot(
  test_case : W217ProjectionCase,
  snapshot : String,
  store : String,
) : Array(String)
  pin_rows = w217_rows(snapshot, "__W217_PIN__")
  w217_assert(pin_rows.size == 1 && pin_rows[0].size == 3 && pin_rows[0][1] == W217_VERSION && pin_rows[0][2] == W217_BUILD,
    "runtime version/build pin differs: #{pin_rows.inspect}")

  source_schema = w217_rows(snapshot, "__W217_SCHEMA__").map do |fields|
    w217_assert(fields.size == 3, "malformed source schema row: #{fields.inspect}")
    {fields[1], fields[2]}
  end
  w217_assert(source_schema == test_case.source_types, "stock source schema differs: #{source_schema.inspect}; expected #{test_case.source_types.inspect}")

  check_rows = w217_section_rows(snapshot, "__W217_CHECK_BEGIN__", "__W217_CHECK_END__", test_case.id)
  w217_assert(check_rows.size == W217_PARENT_PARTS.size && check_rows.all? { |fields| fields.size >= 2 && fields[1] == "1" } &&
              check_rows.map(&.[0]).sort == W217_PARENT_PARTS.sort,
    "actual CHECK TABLE results do not report result=1 for both parents: #{check_rows.inspect}")

  parent_rows = w217_rows(snapshot, "__W217_PARENT__")
  w217_assert(parent_rows.size == W217_PARENT_PARTS.size, "stock reports #{parent_rows.size} active parents, expected 2")
  parent_paths = [] of String
  part_names = [] of String
  parent_rows.each do |fields|
    w217_assert(fields.size == 7, "malformed stock parent-part row: #{fields.inspect}")
    w217_assert(fields[1] == test_case.table_name && W217_PARENT_PARTS.includes?(fields[2]), "unexpected stock parent identity: #{fields.inspect}")
    w217_assert(fields[4].to_u64 == W217_PARENT_ROWS_PER_PART, "#{fields[2]} parent has #{fields[4]} rows, expected #{W217_PARENT_ROWS_PER_PART}")
    w217_assert(fields[5].to_u64 == 4_u64, "#{fields[2]} parent has #{fields[5]} marks, expected three data marks plus the EOF record")
    w217_assert(fields[6] == "Wide", "#{fields[2]} parent is not Wide: #{fields[6]}")
    path = File.real_path(fields[3])
    canonical_store = File.real_path(store)
    w217_assert(path.starts_with?(canonical_store + "/"), "parent part path escaped its isolated store: #{path}")
    child = File.join(path, "p.proj")
    w217_assert(File.directory?(child) && !File.symlink?(child), "stock parent lacks actual p.proj child: #{child}")
    columns_path = File.join(child, "columns.txt")
    w217_assert(File.file?(columns_path) && !File.symlink?(columns_path), "stock child lacks plain columns.txt: #{columns_path}")
    child_columns = File.read(columns_path)
    expected_columns = String.build do |io|
      io << "columns format version: 1\n"
      io << test_case.child_types.size << " columns:\n"
      test_case.child_types.each do |column, type|
        io << '`' << column << "` " << type << '\n'
      end
    end
    w217_assert(child_columns == expected_columns,
      "stock child columns.txt differs for #{fields[2]}: #{child_columns.inspect}; expected #{expected_columns.inspect}")
    parent_paths << path
    part_names << fields[2]
  end
  w217_assert(part_names.sort == W217_PARENT_PARTS.sort, "stock parent-part names differ: #{part_names.inspect}")

  stock_rows = w217_grouped_rows(snapshot, "__W217_ROWS__")
  w217_assert_equal_rows(stock_rows, test_case.expected_by_part, "stock literal semantic SELECT")
  eof_rows = w217_rows(snapshot, "__W217_EOF__")
  w217_assert(eof_rows == [["__W217_EOF__", test_case.id, w217_expected_parent_rows.to_s]],
    "stock source did not reach the expected complete row count: #{eof_rows.inspect}")

  parent_paths
end

private def w217_dynamic_signature(value : CrystalClick::BinaryValue) : Tuple(String, String)
  w217_assert(value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC, "Dynamic actual value lost its Dynamic wrapper: #{value.type.name}")
  w217_assert(value.element_count == 1, "Dynamic row is NULL or has malformed child count #{value.element_count}")
  child = value.element_at(0)
  {child.type.name, child.as_uint64.to_s}
end

private def w217_scan_low_level(reader : CrystalClick::WidePartTable, test_case : W217ProjectionCase) : Hash(String, Array(Array(String)))
  rows = Hash(String, Array(Array(String))).new do |hash, part|
    hash[part] = [] of Array(String)
  end
  reader.scan_typed(batch_rows: 1) do |batch|
    w217_assert(batch.column_names == test_case.selected_columns, "low-level batch columns differ: #{batch.column_names.inspect}")
    case test_case.kind
    when "object"
      keys = batch.values_for("pk", UInt64)
      documents = batch.object_documents_for("payload")
      w217_assert(keys.size == documents.size, "Object batch row alignment differs")
      keys.each_index { |index| rows[batch.part_name] << [keys[index].to_s, documents[index].value_for("t").as_uint64.to_s] }
    when "array_object"
      keys = batch.values_for("pk", UInt64)
      documents = batch.array_object_documents_for("a")
      w217_assert(keys.size == documents.size, "Array(JSON) batch row alignment differs")
      keys.each_index do |index|
        values = documents[index].map { |document| document.value_for("t").bytes[0].to_s }
        rows[batch.part_name] << [keys[index].to_s, values.size.to_s, values.empty? ? "-" : values.join(",")]
      end
    when "recursive"
      keys = batch.values_for("pk", UInt64)
      values = batch.recursive_values_for("payload")
      w217_assert(keys.size == values.size, "recursive JSON batch row alignment differs")
      keys.each_index do |index|
        value = values[index]
        document = value.child_at(0).object_document
        rows[batch.part_name] << [keys[index].to_s, document.value_for("t").bytes[0].to_s, value.child_at(1).bulk_value.as_uint64.to_s]
      end
    when "dynamic"
      keys = batch.values_for("pk", UInt64)
      values = batch.dynamic_bulk_values_for("payload")
      w217_assert(keys.size == values.size, "Dynamic batch row alignment differs")
      keys.each_index do |index|
        actual_type, actual_value = w217_dynamic_signature(values[index])
        rows[batch.part_name] << [keys[index].to_s, actual_type, actual_value]
      end
    when "dynamic_array"
      keys = batch.values_for("pk", UInt64)
      values = batch.dynamic_bulk_values_for("wrapped")
      w217_assert(keys.size == values.size, "Array(Dynamic) batch row alignment differs")
      keys.each_index do |index|
        array = values[index]
        w217_assert(array.type.name == W217_ARRAY_DYNAMIC_U64, "Array(Dynamic) nominal row type differs: #{array.type.name}")
        signatures = array.elements.map { |item| w217_dynamic_signature(item) }
        type_list = signatures.empty? ? "-" : signatures.map(&.[0]).join(",")
        value_list = signatures.empty? ? "-" : signatures.map(&.[1]).join(",")
        rows[batch.part_name] << [keys[index].to_s, signatures.size.to_s, type_list, value_list]
      end
    when "count"
      keys = batch.values_for(W217_COUNT_KEY, UInt64)
      states = batch.aggregate_count_states_for(W217_COUNT_STATE, CrystalClick::BinaryDataType.aggregate_count)
      w217_assert(keys.size == states.size, "Count key/state batch row alignment differs")
      keys.each_index { |index| rows[batch.part_name] << [keys[index].to_s, states[index].count_state.to_s] }
    else
      raise "unhandled W217 scan kind: #{test_case.kind}"
    end
  end
  rows
end

private def w217_scan_catalog(table : CrystalClick::OfflineTable, test_case : W217ProjectionCase) : Hash(String, Array(Array(String)))
  rows = Hash(String, Array(Array(String))).new do |hash, part|
    hash[part] = [] of Array(String)
  end
  table.scan_projection_typed("p", test_case.selected_columns, batch_rows: 1) do |batch|
    w217_assert(batch.column_names == test_case.selected_columns, "catalog batch columns differ: #{batch.column_names.inspect}")
    case test_case.kind
    when "object"
      keys = batch.values_for("pk", UInt64)
      documents = batch.object_documents_for("payload")
      w217_assert(keys.size == documents.size, "catalog Object batch row alignment differs")
      keys.each_index { |index| rows[batch.part_name] << [keys[index].to_s, documents[index].value_for("t").as_uint64.to_s] }
    when "array_object"
      keys = batch.values_for("pk", UInt64)
      documents = batch.array_object_documents_for("a")
      w217_assert(keys.size == documents.size, "catalog Array(JSON) batch row alignment differs")
      keys.each_index do |index|
        values = documents[index].map { |document| document.value_for("t").bytes[0].to_s }
        rows[batch.part_name] << [keys[index].to_s, values.size.to_s, values.empty? ? "-" : values.join(",")]
      end
    when "recursive"
      keys = batch.values_for("pk", UInt64)
      values = batch.recursive_values_for("payload")
      w217_assert(keys.size == values.size, "catalog recursive JSON batch row alignment differs")
      keys.each_index do |index|
        value = values[index]
        document = value.child_at(0).object_document
        rows[batch.part_name] << [keys[index].to_s, document.value_for("t").bytes[0].to_s, value.child_at(1).bulk_value.as_uint64.to_s]
      end
    when "dynamic"
      keys = batch.values_for("pk", UInt64)
      values = batch.dynamic_bulk_values_for("payload")
      w217_assert(keys.size == values.size, "catalog Dynamic batch row alignment differs")
      keys.each_index do |index|
        actual_type, actual_value = w217_dynamic_signature(values[index])
        rows[batch.part_name] << [keys[index].to_s, actual_type, actual_value]
      end
    when "dynamic_array"
      keys = batch.values_for("pk", UInt64)
      values = batch.dynamic_bulk_values_for("wrapped")
      w217_assert(keys.size == values.size, "catalog Array(Dynamic) batch row alignment differs")
      keys.each_index do |index|
        array = values[index]
        w217_assert(array.type.name == W217_ARRAY_DYNAMIC_U64, "catalog Array(Dynamic) nominal type differs: #{array.type.name}")
        signatures = array.elements.map { |item| w217_dynamic_signature(item) }
        type_list = signatures.empty? ? "-" : signatures.map(&.[0]).join(",")
        value_list = signatures.empty? ? "-" : signatures.map(&.[1]).join(",")
        rows[batch.part_name] << [keys[index].to_s, signatures.size.to_s, type_list, value_list]
      end
    when "count"
      keys = batch.values_for(W217_COUNT_KEY, UInt64)
      states = batch.aggregate_count_states_for(W217_COUNT_STATE, CrystalClick::BinaryDataType.aggregate_count)
      w217_assert(keys.size == states.size, "catalog Count key/state batch row alignment differs")
      keys.each_index { |index| rows[batch.part_name] << [keys[index].to_s, states[index].count_state.to_s] }
    else
      raise "unhandled W217 catalog scan kind: #{test_case.kind}"
    end
  end
  rows
end

private def w217_verify_library(store : String, paths : Array(String), test_case : W217ProjectionCase) : String
  reader = CrystalClick::WidePartTable.open_selected_projection_typed(paths, "p", test_case.selected_columns)
  w217_assert(reader.part_count == W217_PARENT_PARTS.size, "low-level reader opened #{reader.part_count} parents")
  w217_assert(reader.columns == test_case.selected_columns, "low-level reader selected columns differ: #{reader.columns.inspect}")
  w217_assert(reader.column_types == test_case.child_types, "low-level child schema differs: #{reader.column_types.inspect}; expected #{test_case.child_types.inspect}")
  child_marks = reader.part_mark_row_counts
  expected_child_grid = test_case.kind == "count" ? [2_u64, 1_u64] : [2_u64, 2_u64, 2_u64]
  expected_child_marks = [expected_child_grid, expected_child_grid]
  w217_assert(child_marks == expected_child_marks,
    "projection child data-mark row grid differs: #{child_marks.inspect}; expected #{expected_child_marks.inspect}")
  expected_child_rows = test_case.kind == "count" ? 3_u64 : 6_u64
  child_rows_by_part = child_marks.map(&.sum)
  w217_assert(child_rows_by_part == [expected_child_rows, expected_child_rows],
    "child row count per parent is #{child_rows_by_part.inspect}, expected #{expected_child_rows} each")
  w217_assert(reader.total_row_count == expected_child_rows * W217_PARENT_PARTS.size,
    "low-level child total row count differs: #{reader.total_row_count}")

  low_level_rows = w217_scan_low_level(reader, test_case)
  w217_assert_equal_rows(low_level_rows, test_case.expected_by_part, "low-level child scan")

  catalog = CrystalClick::OfflineCatalog.open(store)
  table = catalog.table(W217_DATABASE, test_case.table_name)
  w217_assert(table.projections.any? { |projection| projection.name == "p" }, "offline catalog omitted declared projection p")
  candidates = table.part_candidates
  w217_assert(candidates.map(&.name).sort == W217_PARENT_PARTS.sort, "offline catalog parent roster differs: #{candidates.map(&.name).inspect}")
  w217_assert(candidates.map(&.path).sort == paths.sort, "offline catalog parent paths differ from stock system.parts")
  catalog_rows = w217_scan_catalog(table, test_case)
  w217_assert_equal_rows(catalog_rows, test_case.expected_by_part, "OfflineTable.scan_projection_typed")
  w217_assert(catalog_rows == low_level_rows, "offline catalog scan differs from low-level selected-child scan")
  "stock literal SELECT, low-level child reader, and OfflineTable scan agree; child rows/parent=#{expected_child_rows}; child marks=#{child_marks.inspect}; schema=#{reader.column_types.inspect}"
end

private def w217_write_summary(
  path : String,
  results : Array(Tuple(String, Bool, String)),
  binary_sha : String,
  script_sha : String,
  source_manifest_pre_sha : String,
  source_manifest_post_sha : String,
) : Nil
  contents = JSON.build do |json|
    json.object do
      json.field "format", "w217_specialized_projection_result_v1"
      json.field "clickhouse_binary", W217_BINARY
      json.field "clickhouse_binary_sha256", binary_sha
      json.field "expected_clickhouse_version", W217_VERSION
      json.field "expected_clickhouse_build", W217_BUILD
      json.field "oracle_script_sha256", script_sha
      json.field "source_manifest_pre_sha256", source_manifest_pre_sha
      json.field "source_manifest_post_sha256", source_manifest_post_sha
      json.field "source_manifest_unchanged", source_manifest_pre_sha == source_manifest_post_sha
      json.field "cases" do
        json.array do
          results.each do |case_id, success, detail|
            json.object do
              json.field "case", case_id
              json.field "success", success
              json.field "detail", detail
            end
          end
        end
      end
      json.field "scope", "stock-authored physical projection child readers only; projection writing, optimizer planning/selection, and materialized-view execution are not covered"
    end
  end
  w217_write_new(path, contents + "\n")
end

evidence_root = ENV["W217_EVIDENCE_ROOT"]? || raise "W217_EVIDENCE_ROOT must name an existing empty direct child of /private/tmp"
w217_assert(Dir.exists?(evidence_root) && !File.symlink?(evidence_root), "evidence root must be an existing plain directory")
evidence_root = File.real_path(evidence_root)
w217_assert(File.expand_path(evidence_root) == evidence_root && File.dirname(evidence_root) == "/private/tmp",
  "evidence root must be canonical and a direct child of /private/tmp")
w217_assert(Dir.children(evidence_root).empty?, "evidence root must be empty")

binary = ENV["CLICKHOUSE_BIN"]? || W217_BINARY
w217_assert(File.expand_path(binary) == W217_BINARY && File.file?(binary) && !File.symlink?(binary) && File.executable?(binary),
  "ClickHouse binary is not the pinned executable path")
binary_sha = w217_sha256_file(binary)
w217_assert(binary_sha == W217_BINARY_SHA256, "ClickHouse binary SHA-256 differs: #{binary_sha}")
script_path = File.real_path(__FILE__)
script_sha = w217_sha256_file(script_path)
repo_root = File.expand_path("..", File.dirname(script_path))
source_manifest_pre = w217_source_manifest(repo_root, script_path)
source_manifest_pre_sha = Digest::SHA256.hexdigest(source_manifest_pre.to_slice)

cases = w217_cases
case_root = File.join(evidence_root, "cases")
result_root = File.join(evidence_root, "results")
store_root = File.join(evidence_root, "stores")
Dir.mkdir(case_root, 0o700)
Dir.mkdir(result_root, 0o700)
Dir.mkdir(store_root, 0o700)
w217_write_new(File.join(evidence_root, "source_manifest.pre.json"), source_manifest_pre)
sql_by_id = Hash(String, String).new
store_by_id = Hash(String, String).new
cases.each do |test_case|
  case_dir = File.join(case_root, test_case.id)
  result_dir = File.join(result_root, test_case.id)
  store = File.join(store_root, test_case.id)
  Dir.mkdir(case_dir, 0o700)
  Dir.mkdir(result_dir, 0o700)
  Dir.mkdir(store, 0o700)
  sql = w217_case_sql(test_case)
  sql_path = File.join(case_dir, "stock.sql")
  w217_write_new(sql_path, sql)
  w217_write_input_manifest(
    File.join(case_dir, "input_manifest.json"), test_case, sql, binary_sha, script_sha, store, source_manifest_pre_sha
  )
  sql_by_id[test_case.id] = sql
  store_by_id[test_case.id] = store
end

results = [] of Tuple(String, Bool, String)
cases.each do |test_case|
  store = store_by_id[test_case.id]
  result_dir = File.join(result_root, test_case.id)
  sql_path = File.join(case_root, test_case.id, "stock.sql")
  sql = sql_by_id[test_case.id]
  begin
    native_success, process_detail = w217_run_native(binary, store, sql_path, sql, result_dir, test_case.id)
    unless native_success
      results << {test_case.id, false, "native process failure (not semantic rejection): #{process_detail}"}
      next
    end
    stdout = File.read(File.join(result_dir, "#{test_case.id}.stdout"))
    parent_paths = w217_validate_native_snapshot(test_case, stdout, store)
    physical_pre, physical_pre_complete = w217_capture_physical_input_manifest(test_case.id, store, parent_paths)
    physical_pre_path = File.join(result_dir, "physical_inputs.pre.json")
    w217_write_new(physical_pre_path, physical_pre)
    w217_assert(physical_pre_complete, "could not capture bounded physical input manifest before library verification; see #{physical_pre_path}")
    physical_pre_sha = Digest::SHA256.hexdigest(physical_pre.to_slice)

    verification_detail = nil.as(String?)
    verification_error = nil.as(Exception?)
    begin
      verification_detail = w217_verify_library(store, parent_paths, test_case)
    rescue ex
      verification_error = ex
    end

    physical_post, physical_post_complete = w217_capture_physical_input_manifest(test_case.id, store, parent_paths)
    physical_post_path = File.join(result_dir, "physical_inputs.post.json")
    w217_write_new(physical_post_path, physical_post)
    physical_post_sha = Digest::SHA256.hexdigest(physical_post.to_slice)
    w217_assert(physical_post_complete && physical_pre == physical_post,
      "stock-authored parent/child physical inputs changed or became uninspectable during library verification; " \
      "pre_sha256=#{physical_pre_sha} post_sha256=#{physical_post_sha}; see #{physical_pre_path} and #{physical_post_path}")

    if error = verification_error
      raise error
    end
    detail = verification_detail || raise "library verification returned no result"
    detail += "; physical input manifest SHA-256=#{physical_pre_sha} (before/after equal)"
    results << {test_case.id, true, detail}
    puts "PASS W217 #{test_case.id}: #{detail}"
  rescue ex
    results << {test_case.id, false, "#{ex.class}: #{ex.message}"}
    STDERR.puts "FAIL W217 #{test_case.id}: #{ex.class}: #{ex.message}"
  end
end

source_manifest_post = w217_source_manifest(repo_root, script_path)
source_manifest_post_sha = Digest::SHA256.hexdigest(source_manifest_post.to_slice)
w217_write_new(File.join(evidence_root, "source_manifest.post.json"), source_manifest_post)
unless source_manifest_pre_sha == source_manifest_post_sha
  results << {"source_manifest", false, "source files changed during native run: pre=#{source_manifest_pre_sha} post=#{source_manifest_post_sha}"}
end
w217_write_summary(
  File.join(evidence_root, "result.json"), results, binary_sha, script_sha,
  source_manifest_pre_sha, source_manifest_post_sha,
)
failures = results.reject(&.[1])
w217_assert(failures.empty?, "#{failures.size}/#{results.size} native/library cases failed; inspect result.json and per-case raw evidence")
puts "PASS W217 specialized stock projection oracle: #{results.size} families; evidence=#{evidence_root}"
