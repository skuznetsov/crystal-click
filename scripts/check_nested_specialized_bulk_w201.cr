require "../src/crystal_click"
require "json"
require "digest/sha256"

# Kernel-only consumer for W201 stock-created Nested/Array(Tuple) parts. It
# validates immutable stock files, reads real compressed mark lanes, and checks
# decoded values against runner-authored literals. It is not a public writer,
# complete-part, or ATTACH qualification.
raise "usage: check_nested_specialized_bulk_w201.cr MANIFEST" unless ARGV.size == 1
manifest_path = File.realpath(ARGV[0])
manifest = JSON.parse(File.read(manifest_path))
pin = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
binary = manifest["clickhouse_binary"].as_s
raise "stock runtime SHA pin mismatch" unless manifest["clickhouse_binary_sha256_before"].as_s == pin &&
                                              manifest["clickhouse_binary_sha256_after_stock"].as_s == pin &&
                                              File.file?(binary)
raise "runtime version/build pin mismatch" unless manifest["clickhouse_version"].as_s == "26.10.1.1201" &&
                                                  manifest["clickhouse_build"].as_s == "d9bcb5ab007f0f6299f7f973f2642245bab3d028"

root = File.realpath(File.dirname(manifest_path))
store = File.realpath(File.join(root, "stores", "native"))
rows_per_mark = manifest["rows_per_mark"].as_a.map(&.as_i64.to_u64)
raise "unexpected outer mark grid" unless rows_per_mark == [2_u64, 2_u64, 2_u64, 2_u64]
literal_rows = manifest["literal_rows"].as_a
raise "fixture must have eight rows" unless literal_rows.size == 8

def w201_require(ok : Bool, message : String) : Nil
  raise "W201: #{message}" unless ok
end

def w201_string_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive("String")
end

def w201_descriptor(carrier : String) : CrystalClick::BinaryDataType
  string = w201_string_type
  nullable = CrystalClick::BinaryDataType.nullable(string)
  low = CrystalClick::BinaryDataType.low_cardinality(nullable)
  fields = [low, string] of CrystalClick::BinaryDataType
  names = ["label", "text"] of String
  if carrier == "nested"
    CrystalClick::BinaryDataType.nested(fields, names)
  elsif carrier == "array_tuple"
    CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.tuple(fields, names))
  else
    raise "unknown W201 carrier #{carrier.inspect}"
  end
end

def w201_profile(name : String) : CrystalClick::BinaryBulkProfile
  case name
  when "single_stream"    then CrystalClick::BinaryBulkProfile.single_stream
  when "with_size_stream" then CrystalClick::BinaryBulkProfile.with_size_stream
  else                         raise "unknown W201 String profile #{name.inspect}"
  end
end

def w201_inventory_under(path : String, root : String, result : Array({String, String, Int64, String?})) : Nil
  Dir.each_child(path) do |name|
    child = File.join(path, name)
    raise "symlink in stock part: #{child}" if File.symlink?(child)
    info = File.info(child)
    relative = child.byte_slice(root.bytesize + 1, child.bytesize - root.bytesize - 1)
    if info.directory?
      result << {relative, "directory", 0_i64, nil}
      w201_inventory_under(child, root, result)
    elsif info.file?
      result << {relative, "file", info.size, Digest::SHA256.hexdigest(File.read(child))}
    else
      raise "unexpected stock part entry: #{child}"
    end
  end
end

def w201_inventory(part : String) : Array({String, String, Int64, String?})
  result = [] of {String, String, Int64, String?}
  w201_inventory_under(part, part, result)
  result.sort_by!(&.[0])
  result
end

def w201_check_inventory(part : String, expected : JSON::Any) : Nil
  actual = w201_inventory(part)
  roster = expected.as_a.map do |entry|
    {entry["name"].as_s, entry["kind"].as_s, entry["size"].as_i64,
     entry["sha256"].raw.nil? ? nil : entry["sha256"].as_s}
  end
  w201_require(actual == roster, "stock part inventory/hash changed before decode: #{part}")
end

def w201_read_profile(profile : JSON::Any, root : String, store : String,
                      rows_per_mark : Array(UInt64), literal_rows : Array(JSON::Any)) : String
  id = profile["id"].as_s
  carrier = profile["carrier"].as_s
  string_profile = profile["string_profile"].as_s
  type = w201_descriptor(carrier)
  w201_require(type.name == profile["sql_type"].as_s, "library descriptor differs from stock declaration for #{id}")
  part = File.realpath(profile["part_path"].as_s)
  w201_require(part.starts_with?(store + "/"), "part escapes retained store: #{id}")
  w201_check_inventory(part, profile["part_roster"])

  profile_value = w201_profile(string_profile)
  physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile_value)
  roles = CrystalClick::BinaryBulkTypePlan.new(type, profile_value).roles
  names = physical.stream_names
  w201_require(names.keys.sort == roles, "physical plan roles differ from bulk role grammar: #{id}")
  part_names = profile["part_roster"].as_a.map { |entry| entry["name"].as_s }
  observed_data_files = part_names.select(&.ends_with?(".bin")).sort!
  observed_mark_files = part_names.select(&.ends_with?(".mrk2")).sort!
  pk_basename = CrystalClick::StreamName.hash("pk")
  planned_data_files = (roles.map { |role| physical.data_file_for(role, hashed: true) } + ["#{pk_basename}.bin"]).sort!
  planned_mark_files = (roles.map { |role| physical.marks_file_for(role, hashed: true) } + ["#{pk_basename}.mrk2"]).sort!
  w201_require(observed_data_files == planned_data_files && observed_mark_files == planned_mark_files,
    "planned physical roles do not exactly cover stock data/mark files for #{id}")
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  names.keys.sort.each do |role|
    data_name = physical.data_file_for(role, hashed: true)
    marks_name = physical.marks_file_for(role, hashed: true)
    data = File.join(part, data_name)
    marks = File.join(part, marks_name)
    w201_require(File.file?(data) && !File.symlink?(data), "missing stock lane #{data_name} in #{id}")
    w201_require(File.file?(marks) && !File.symlink?(marks), "missing stock marks #{marks_name} in #{id}")
    lane = CrystalClick::CompressedMarkReader.read(
      data, marks, File.size(data), File.size(marks), prefix_size: physical.prefix_size_for(role)
    )
    w201_require(lane.rows_per_mark == rows_per_mark, "stock lane mark grid differs for #{id}/#{role}: #{lane.rows_per_mark}")
    lanes[role] = CrystalClick::BinaryBulkStream.new(lane.bytes, lane.offsets)
  end
  streams = CrystalClick::BinaryBulkStreams.new(rows_per_mark.size, lanes)
  decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, rows_per_mark, profile: profile_value)
  expected = w201_expected(type, carrier, literal_rows)
  windows = [{"full", 0, 4}, {"first_empty_mark", 0, 1},
             {"later_populated_mark", 1, 1}, {"final_populated_mark", 3, 1},
             {"zero_end_window", 4, 0}]
  windows.each do |name, first, count|
    selected = CrystalClick::BinaryBulkCodec.decode(
      type, streams, rows_per_mark, first_mark: first, mark_count: count, profile: profile_value
    )
    w201_compare_rows(type, carrier, selected, expected[first, count], "#{id} window #{name}")
  end
  w201_compare_rows(type, carrier, decoded, expected, "#{id} full")

  lc_roles = roles.select { |role| role.ends_with?(".dictionary") || role.ends_with?(".indexes") }
  string_size_roles = roles.select(&.ends_with?(".string_sizes"))
  w201_require(lc_roles.size == 2, "expected one dictionary/indexes pair for #{id}")
  expected_size_roles = string_profile == "with_size_stream" ? 1 : 0
  w201_require(string_size_roles.size == expected_size_roles, "String profile lane shape mismatch for #{id}")
  "#{id}:observed_roles=#{roles.join('|')},lc_lanes=#{lc_roles.size},string_size_lanes=#{string_size_roles.size},marks=#{rows_per_mark.size}"
end

def w201_expected(type : CrystalClick::BinaryDataType, carrier : String,
                  literal_rows : Array(JSON::Any)) : Array(Array(CrystalClick::BinaryValue))
  tuple = type.child_at(0)
  low = tuple.child_at(0)
  nullable = low.child_at(0)
  values = literal_rows.map do |row|
    expected_records = row.as_a[1].as_a.map do |record|
      raw_label = record[0]
      label_value = if raw_label.raw.nil?
                      CrystalClick::BinaryValue.nullable(nullable)
                    else
                      CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(raw_label.as_s))
                    end
      label = CrystalClick::BinaryValue.low_cardinality(low, label_value)
      text = CrystalClick::BinaryValue.string(record[1].as_s)
      CrystalClick::BinaryValue.tuple(tuple, [label, text] of CrystalClick::BinaryValue)
    end
    if carrier == "nested"
      CrystalClick::BinaryValue.nested(type, expected_records)
    else
      CrystalClick::BinaryValue.array(type, expected_records)
    end
  end
  marks = [] of Array(CrystalClick::BinaryValue)
  values.each_with_index do |value, index|
    marks << [] of CrystalClick::BinaryValue if index % 2 == 0
    marks.last << value
  end
  marks
end

def w201_compare_rows(type : CrystalClick::BinaryDataType, carrier : String,
                      actual : Array(Array(CrystalClick::BinaryValue)),
                      expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  w201_require(actual.size == expected.size, "row window count mismatch: #{label}")
  actual.each_with_index do |rows, mark|
    wanted_rows = expected[mark]
    w201_require(rows.size == wanted_rows.size, "outer row count mismatch: #{label}/#{mark}")
    rows.each_with_index do |value, row|
      wanted = wanted_rows[row]
      w201_require(value.type == type, "nominal carrier identity lost: #{label}/#{mark}/#{row}")
      w201_require(value.element_count == wanted.element_count, "array/Nested child count mismatch: #{label}/#{mark}/#{row}")
      value.element_count.times do |element|
        actual_record = value.element_at(element)
        expected_record = wanted.element_at(element)
        w201_require(actual_record.type == type.child_at(0), "tuple identity lost: #{label}/#{mark}/#{row}/#{element}")
        actual_lc = actual_record.child_at(0)
        expected_lc = expected_record.child_at(0)
        w201_require(actual_lc.type == expected_lc.type, "LC type mismatch: #{label}/#{mark}/#{row}/#{element}")
        actual_nullable = actual_lc.child_at(0)
        expected_nullable = expected_lc.child_at(0)
        w201_require(actual_nullable.is_null? == expected_nullable.is_null?, "Nullable state mismatch: #{label}/#{mark}/#{row}/#{element}")
        unless expected_nullable.is_null?
          w201_require(actual_nullable.child_at(0).as_string == expected_nullable.child_at(0).as_string,
            "LC label mismatch: #{label}/#{mark}/#{row}/#{element}")
        end
        w201_require(actual_record.child_at(1).as_string == expected_record.child_at(1).as_string,
          "direct String sibling mismatch: #{label}/#{mark}/#{row}/#{element}")
      end
    end
  end
end

profiles = manifest["profiles"].as_a
w201_require(profiles.size == 4, "expected Nested/Array(Tuple) × two String profiles")
observations = profiles.map { |profile| w201_read_profile(profile, root, store, rows_per_mark, literal_rows) }
profile_ids = profiles.map { |profile| profile["id"].as_s }
windows = %w[full first_empty_mark later_populated_mark final_populated_mark zero_end_window]
result = {} of String => JSON::Any
result["status"] = JSON::Any.new("decoded")
result["profile_count"] = JSON::Any.new(profiles.size.to_i64)
result["profile_ids"] = JSON::Any.new(profile_ids.map { |id| JSON::Any.new(id) })
result["full_rows"] = JSON::Any.new(literal_rows.size.to_i64)
result["windows"] = JSON::Any.new(windows.map { |window| JSON::Any.new(window) })
result["observations"] = JSON::Any.new(observations.map { |observation| JSON::Any.new(observation) })
puts "__W201_RESULT__\t#{JSON::Any.new(result).to_json}"
