require "../src/crystal_click"
require "digest/sha256"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckDynamicSharedJSONW213
  extend self

  COLUMN                  = "payload"
  KEY_NAME                = "pk"
  CASE_IDS                = ["root_json", "root_array_json", "root_tuple_json", "array_dynamic_array_json"]
  PROFILE_IDS             = ["single_stream", "with_size_stream"]
  FORMAT_INPUT            = "dynamic_shared_json_w213_input_v1"
  FORMAT_OUTPUT           = "dynamic_shared_json_w213_helper_v1"
  PARENT_ROWS             = [2_u64, 2_u64, 2_u64, 2_u64]
  PARENT_MARK_THIRD_WORDS = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
  OUTER_ROWS              = [2_u64, 3_u64, 3_u64, 5_u64]

  # Literal wire constants are intentionally independent of the codec under
  # test. The JSON typed-path descriptor is JSON(v0, max_paths=1, max_types=1,
  # id UInt8, maybe Nullable(UInt8)); row path order is parsed independently.
  JSON_DESCRIPTOR = Bytes[
    0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x02_u8,
    0x02_u8, 0x69_u8, 0x64_u8, 0x01_u8,
    0x05_u8, 0x6d_u8, 0x61_u8, 0x79_u8, 0x62_u8, 0x65_u8, 0x23_u8, 0x01_u8,
    0x00_u8, 0x00_u8,
  ]

  alias Fixture = NamedTuple(
    case_id: String,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    granules: Array(Array(CrystalClick::BinaryValue)),
    site: String,
    contents_by_mark: Array(Array(String?)),
    expected_rows: Array(Array(String)),
    site_occurrence_rows: Array(UInt64),
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W213 helper: #{message}") unless condition
  end

  private def byte_slice(bytes : Array(UInt8)) : Bytes
    Slice.new(bytes.to_unsafe, bytes.size)
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W213 profile is outside the fixed roster")
    end
  end

  private def u8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def json_type : CrystalClick::BinaryDataType
    u8 = u8_type
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {
        "id"    => u8,
        "maybe" => CrystalClick::BinaryDataType.nullable(u8),
      } of String => CrystalClick::BinaryDataType,
    )
  end

  private def json_value(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
    u8 = u8_type
    nullable_u8 = CrystalClick::BinaryDataType.nullable(u8)
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [
        {"id", CrystalClick::BinaryValue.fixed(u8, Bytes[id])},
        {"maybe", CrystalClick::BinaryValue.null(nullable_u8)},
        {"counter", CrystalClick::BinaryValue.int64(id.to_i64 * 10_i64 + 1_i64)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  private def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(0)
  end

  private def dynamic(child : CrystalClick::BinaryValue? = nil) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(dynamic_type, child)
  end

  private def array(type : CrystalClick::BinaryDataType, values : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(type, values)
  end

  private def signature(value : CrystalClick::BinaryValue) : String
    return "null" if value.is_null?
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      "D[#{signature(value.child_at(0))}]"
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      id = row.value_for("id").not_nil!.byte_at(0)
      counter = row.value_for("counter").not_nil!.as_int64
      "J(#{id},#{counter})"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "[#{value.elements.map { |item| signature(item) }.join(",")}]"
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      "(#{value.elements.map { |item| signature(item) }.join(",")})"
    when CrystalClick::BinaryDataType::TAG_UINT8
      "U8:#{value.byte_at(0)}"
    else
      raise CrystalClick::CorruptPartError.new("W213 fixture contains an unrostered value type")
    end
  end

  private def make_fixture(case_id : String) : Fixture
    json = json_type
    dynamic = dynamic_type
    array_json = CrystalClick::BinaryDataType.array(json)
    site = case case_id
           when "array_dynamic_array_json"                        then "root.elements"
           when "root_json", "root_array_json", "root_tuple_json" then "root"
           else                                                        raise ArgumentError.new("W213 case is outside the fixed roster")
           end
    column_type = case case_id
                  when "array_dynamic_array_json" then CrystalClick::BinaryDataType.array(dynamic)
                  else                                 dynamic
                  end
    actual_type = case case_id
                  when "root_json"                                   then json
                  when "root_array_json", "array_dynamic_array_json" then array_json
                  when "root_tuple_json"
                    CrystalClick::BinaryDataType.tuple([json, json] of CrystalClick::BinaryDataType)
                  else raise ArgumentError.new("W213 case is outside the fixed roster")
                  end
    json_child = ->(id : UInt8) { json_value(json, id) }
    dynamic_child = ->(child : CrystalClick::BinaryValue) { dynamic(child) }
    array_child = ->(ids : Array(UInt8)) {
      values = ids.map { |id| json_child.call(id) }
      dynamic_child.call(array(array_json, values))
    }
    tuple_child = ->(left : UInt8, right : UInt8) {
      tuple = CrystalClick::BinaryDataType.tuple([json, json] of CrystalClick::BinaryDataType)
      dynamic_child.call(CrystalClick::BinaryValue.tuple(tuple, [json_child.call(left), json_child.call(right)] of CrystalClick::BinaryValue))
    }
    rows = [] of CrystalClick::BinaryValue
    contents = [] of Array(String?)

    case case_id
    when "root_json"
      rows = [
        dynamic(), dynamic(),
        dynamic_child.call(json_child.call(31_u8)), dynamic_child.call(json_child.call(32_u8)),
        dynamic_child.call(json_child.call(33_u8)), dynamic_child.call(json_child.call(34_u8)),
        dynamic_child.call(json_child.call(35_u8)), dynamic_child.call(json_child.call(36_u8)),
      ] of CrystalClick::BinaryValue
      contents = [
        [nil, nil] of String?, ["31", "32"] of String?,
        ["33", "34"] of String?, ["35", "36"] of String?,
      ]
    when "root_array_json"
      rows = [
        dynamic(), dynamic(),
        array_child.call([] of UInt8), array_child.call([41_u8] of UInt8),
        array_child.call([42_u8, 43_u8] of UInt8), array_child.call([44_u8] of UInt8),
        array_child.call([45_u8] of UInt8), array_child.call([46_u8, 47_u8] of UInt8),
      ] of CrystalClick::BinaryValue
      contents = [
        [nil, nil] of String?, ["", "41"] of String?,
        ["42,43", "44"] of String?, ["45", "46,47"] of String?,
      ]
    when "root_tuple_json"
      rows = [
        dynamic(), dynamic(),
        tuple_child.call(51_u8, 52_u8), tuple_child.call(53_u8, 54_u8),
        tuple_child.call(55_u8, 56_u8), tuple_child.call(57_u8, 58_u8),
        tuple_child.call(59_u8, 60_u8), tuple_child.call(61_u8, 62_u8),
      ] of CrystalClick::BinaryValue
      contents = [
        [nil, nil] of String?, ["51,52", "53,54"] of String?,
        ["55,56", "57,58"] of String?, ["59,60", "61,62"] of String?,
      ]
    when "array_dynamic_array_json"
      outer_type = column_type
      outer = ->(items : Array(CrystalClick::BinaryValue)) { array(outer_type, items) }
      rows = [
        outer.call([array_child.call([] of UInt8)] of CrystalClick::BinaryValue),
        outer.call([array_child.call([] of UInt8)] of CrystalClick::BinaryValue),
        outer.call([dynamic(), array_child.call([81_u8] of UInt8)] of CrystalClick::BinaryValue),
        outer.call([array_child.call([82_u8, 83_u8])] of CrystalClick::BinaryValue),
        outer.call([array_child.call([] of UInt8), array_child.call([84_u8] of UInt8)] of CrystalClick::BinaryValue),
        outer.call([array_child.call([85_u8, 86_u8])] of CrystalClick::BinaryValue),
        outer.call([array_child.call([86_u8]), array_child.call([] of UInt8), array_child.call([87_u8])] of CrystalClick::BinaryValue),
        outer.call([array_child.call([88_u8]), array_child.call([89_u8])] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
      contents = [
        ["", ""] of String?, [nil, "81", "82,83"] of String?,
        ["", "84", "85,86"] of String?, ["86", "", "87", "88", "89"] of String?,
      ]
    else
      raise ArgumentError.new("W213 case is outside the fixed roster")
    end

    granules = rows.each_slice(2).map(&.to_a).to_a
    expected = granules.map { |mark| mark.map { |value| signature(value) } }
    structures = {site => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    site_rows = case case_id
                when "array_dynamic_array_json" then OUTER_ROWS.dup
                else                                 PARENT_ROWS.dup
                end
    {case_id: case_id, type: column_type, structures: structures, granules: granules,
     site: site, contents_by_mark: contents, expected_rows: expected, site_occurrence_rows: site_rows}
  end

  private def append_varuint(bytes : Array(UInt8), value : UInt64) : Nil
    remaining = value
    loop do
      byte = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      bytes << (remaining == 0_u64 ? byte : (byte | 0x80_u8))
      break if remaining == 0_u64
    end
  end

  private def varuint_bytes(value : UInt64) : Array(UInt8)
    output = [] of UInt8
    append_varuint(output, value)
    output
  end

  private def json_row_literal(id : UInt8) : Array(UInt8)
    output = [0x03_u8] # three flattened paths
    # Untyped Int64 `counter`; intentionally first in the literal path order.
    output.concat([0x07_u8] of UInt8)
    output.concat("counter".to_slice)
    output << 0x0a_u8
    bits = (id.to_i64 * 10_i64 + 1_i64).unsafe_as(UInt64)
    8.times { |index| output << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
    # Typed UInt8 id and typed Nullable(UInt8) NULL. Typed paths carry no
    # per-value type descriptor because the descriptor above owns their types.
    output.concat([0x02_u8] of UInt8)
    output.concat("id".to_slice)
    output << id
    output.concat([0x05_u8] of UInt8)
    output.concat("maybe".to_slice)
    output << 0x01_u8
    output
  end

  private def literal_envelope(case_id : String, content : String) : Array(UInt8)
    ids = content.empty? ? [] of UInt8 : content.split(",").map(&.to_u8)
    output = [] of UInt8
    case case_id
    when "root_json"
      output.concat(JSON_DESCRIPTOR)
      output.concat(json_row_literal(ids[0]))
    when "root_array_json", "array_dynamic_array_json"
      output << 0x1e_u8
      output.concat(JSON_DESCRIPTOR)
      append_varuint(output, ids.size.to_u64)
      ids.each { |id| output.concat(json_row_literal(id)) }
    when "root_tuple_json"
      output << 0x1f_u8
      output << 0x02_u8
      output.concat(JSON_DESCRIPTOR)
      output.concat(JSON_DESCRIPTOR)
      output.concat(json_row_literal(ids[0]))
      output.concat(json_row_literal(ids[1]))
    else
      raise ArgumentError.new("W213 raw envelope family is outside the fixed roster")
    end
    output
  end

  private def read_varuint(bytes : Bytes, cursor : Int32) : Tuple(UInt64, Int32)
    value = 0_u64
    shift = 0
    10.times do
      if cursor >= bytes.size
        raise CrystalClick::CorruptPartError.new("W213 literal envelope has a truncated VarUInt")
      end
      byte = bytes[cursor]
      cursor += 1
      if shift == 63 && (byte & 0x7e_u8) != 0
        raise CrystalClick::CorruptPartError.new("W213 literal envelope VarUInt overflows")
      end
      value |= (byte & 0x7f_u8).to_u64 << shift
      if (byte & 0x80_u8) == 0
        return {value, cursor}
      end
      shift += 7
    end
    raise CrystalClick::CorruptPartError.new("W213 literal envelope VarUInt is too long")
  end

  private def read_u64_le(bytes : Bytes, cursor : Int32) : Tuple(UInt64, Int32)
    if cursor > bytes.size - 8
      raise CrystalClick::CorruptPartError.new("W213 JSON counter is truncated")
    end
    value = 0_u64
    8.times { |index| value |= bytes[cursor + index].to_u64 << (index * 8) }
    {value, cursor + 8}
  end

  private def parse_json_descriptor(bytes : Bytes, cursor : Int32) : Int32
    prefix = Bytes[0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x02_u8]
    require!(cursor <= bytes.size - prefix.size && bytes[cursor, prefix.size] == prefix,
      "raw JSON descriptor prefix or fixed limits differ")
    cursor += prefix.size
    typed_paths = Hash(String, Array(UInt8)).new
    2.times do
      path_size_start = cursor
      path_size, cursor = read_varuint(bytes, cursor)
      require!(path_size > 0_u64 && path_size <= 32_u64 && path_size <= (bytes.size - cursor).to_u64,
        "raw JSON typed path name length is outside the fixed bound")
      require!(cursor - path_size_start == 1,
        "raw JSON typed path length VarUInt is not canonical")
      path = String.new(bytes[cursor, path_size.to_i32])
      cursor += path_size.to_i32
      require!(!typed_paths.has_key?(path), "raw JSON descriptor repeats a typed path")
      type_descriptor = case path
                        when "id"
                          require!(path_size == 2_u64, "raw JSON id path length differs")
                          require!(cursor < bytes.size && bytes[cursor] == 0x01_u8,
                            "raw JSON id typed child is not UInt8")
                          cursor += 1
                          [0x01_u8]
                        when "maybe"
                          require!(path_size == 5_u64, "raw JSON maybe path length differs")
                          require!(cursor <= bytes.size - 2 && bytes[cursor] == 0x23_u8 && bytes[cursor + 1] == 0x01_u8,
                            "raw JSON maybe typed child is not Nullable(UInt8)")
                          cursor += 2
                          [0x23_u8, 0x01_u8]
                        else
                          raise CrystalClick::CorruptPartError.new("raw JSON descriptor path is outside the fixed typed roster")
                        end
      typed_paths[path] = type_descriptor
    end
    require!(typed_paths == {"id" => [0x01_u8], "maybe" => [0x23_u8, 0x01_u8]},
      "raw JSON descriptor typed-path map differs")
    skips_start = cursor
    skips, cursor = read_varuint(bytes, cursor)
    skips_end = cursor
    regexes_start = cursor
    regexes, cursor = read_varuint(bytes, cursor)
    require!(skips == 0_u64 && regexes == 0_u64 && skips_end - skips_start == 1 && cursor - regexes_start == 1,
      "raw JSON descriptor skip or regex counts are nonzero or noncanonical")
    cursor
  end

  private def canonicalize_envelope_descriptor(bytes : Bytes, case_id : String) : Array(UInt8)
    # parse_envelope first validates every descriptor semantically. Here only
    # normalize unordered_map iteration order to the independent literal order;
    # JSON rows, family tags, and all other envelope bytes remain exact.
    parse_envelope(bytes, case_id)
    prefix_size = case case_id
                  when "root_json"                                   then 0
                  when "root_array_json", "array_dynamic_array_json" then 1
                  when "root_tuple_json"                             then 2
                  else                                                    raise ArgumentError.new("W213 raw envelope family is outside the fixed roster")
                  end
    descriptor_count = case case_id
                       when "root_tuple_json" then 2
                       else                        1
                       end
    descriptor_end = prefix_size + JSON_DESCRIPTOR.size * descriptor_count
    require!(bytes.size >= descriptor_end, "raw JSON descriptor envelope is truncated")
    output = [] of UInt8
    output.concat(bytes[0, prefix_size].to_a)
    descriptor_count.times { output.concat(JSON_DESCRIPTOR) }
    output.concat(bytes[descriptor_end, bytes.size - descriptor_end].to_a)
    output
  end

  private def reordered_json_descriptor : Array(UInt8)
    [
      0x30_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x02_u8,
      0x05_u8, 0x6d_u8, 0x61_u8, 0x79_u8, 0x62_u8, 0x65_u8, 0x23_u8, 0x01_u8,
      0x02_u8, 0x69_u8, 0x64_u8, 0x01_u8,
      0x00_u8, 0x00_u8,
    ]
  end

  private def parse_json_row(bytes : Bytes, cursor : Int32) : Tuple(UInt8, Int64, Int32)
    count, cursor = read_varuint(bytes, cursor)
    require!(count == 3_u64, "raw JSON row path count is not the literal three")
    seen = Set(String).new
    id = nil.as(UInt8?)
    counter = nil.as(Int64?)
    maybe_null = false
    3.times do
      size, cursor = read_varuint(bytes, cursor)
      require!(size > 0_u64 && size <= 256_u64 && size <= (bytes.size - cursor).to_u64, "raw JSON path length is outside the literal bound")
      path = String.new(bytes[cursor, size.to_i32])
      cursor += size.to_i32
      require!(seen.add?(path), "raw JSON row repeats a path")
      case path
      when "counter"
        require!(cursor < bytes.size && bytes[cursor] == 0x0a_u8, "counter is not the untyped Int64 literal")
        cursor += 1
        bits, cursor = read_u64_le(bytes, cursor)
        counter = bits.unsafe_as(Int64)
      when "id"
        require!(cursor < bytes.size, "typed id value is truncated")
        id = bytes[cursor]
        cursor += 1
      when "maybe"
        require!(cursor < bytes.size && bytes[cursor] == 0x01_u8, "typed maybe path is not NULL")
        maybe_null = true
        cursor += 1
      else
        raise CrystalClick::CorruptPartError.new("W213 raw JSON path is outside the literal roster")
      end
    end
    require!(seen == Set{"counter", "id", "maybe"} && maybe_null, "raw JSON typed path set differs")
    {id || raise(CrystalClick::CorruptPartError.new("raw JSON id is absent")),
     counter || raise(CrystalClick::CorruptPartError.new("raw JSON counter is absent")), cursor}
  end

  private def parse_envelope(bytes : Bytes, case_id : String) : Array(Tuple(UInt8, Int64))
    cursor = 0
    case case_id
    when "root_json"
      cursor = parse_json_descriptor(bytes, 0)
    when "root_array_json", "array_dynamic_array_json"
      require!(bytes.size > 0 && bytes[0] == 0x1e_u8, "Array(JSON) envelope tag differs from the literal")
      cursor = parse_json_descriptor(bytes, 1)
    when "root_tuple_json"
      require!(bytes.size >= 2 && bytes[0] == 0x1f_u8 && bytes[1] == 0x02_u8,
        "unnamed Tuple(JSON,JSON) envelope tag/count differs from the literal")
      cursor = parse_json_descriptor(bytes, 2)
      cursor = parse_json_descriptor(bytes, cursor)
    else
      raise ArgumentError.new("W213 raw envelope family is outside the fixed roster")
    end
    count = case case_id
            when "root_tuple_json" then 2_u64
            else                        1_u64
            end
    if case_id == "root_array_json" || case_id == "array_dynamic_array_json"
      count, cursor = read_varuint(bytes, cursor)
    end
    if count > 1_000_u64
      raise CrystalClick::CorruptPartError.new("W213 raw JSON row count exceeds its fixed bound")
    end
    rows = Array(Tuple(UInt8, Int64)).new(count.to_i)
    count.to_i.times do
      id, counter, cursor = parse_json_row(bytes, cursor)
      rows << {id, counter}
    end
    require!(cursor == bytes.size, "raw SharedVariant envelope has trailing bytes")
    rows
  end

  private def expected_roster(case_id : String, profile_name : String) : Array(String)
    names = ["payload.dynamic_structure", "payload.variant_discr", "payload.SharedVariant"]
    names << "payload.SharedVariant.size" if profile_name == "with_size_stream"
    names << "payload.size0" if case_id == "array_dynamic_array_json"
    names.sort!
  end

  private def validate_roster!(observed : Array(String), case_id : String, profile_name : String) : Nil
    expected = expected_roster(case_id, profile_name)
    require!(observed.sort == expected && observed.uniq == observed,
      "physical stream roster differs from the complete literal SharedVariant-only roster")
    require!(observed.none? { |name| name.includes?("object") || name.includes?("counter") || name.includes?(".id") || name.includes?(".maybe") },
      "Object/JSON-child binding unexpectedly appeared in the physical roster")
  end

  private def mark_words(path : String) : Array(UInt64)
    bytes = File.read(path).to_slice
    require!(bytes.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0,
      "physical mark file has an incomplete 24-byte record")
    count = bytes.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
    Array(UInt64).new(count) do |record|
      offset = record * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
  end

  private def validate_part_path!(path : String, root : String, generated : Bool) : Nil
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

  private def read_raw_shared_lane(part : String, fixed : Fixture, physical : CrystalClick::BinaryDynamicBulkPhysicalPlan,
                                   profile_name : String) : NamedTuple(discriminators: Array(Array(UInt8)), envelopes: Array(Array(String?)),
    literal_envelopes: Array(Array(String?)),
    mark_words: Hash(String, Array(UInt64)),
    checksum_file_names: Array(String))
    source = CrystalClick::PartStreamSource.new(part)
    data_bindings = physical.data_stream_names
    shared_entry = data_bindings.find { |_role, name| name.ends_with?("SharedVariant") } ||
                   raise(CrystalClick::CorruptPartError.new("SharedVariant data lane is absent"))
    shared_role, _shared_name = shared_entry
    shared_data = physical.data_file_for(shared_role, true)
    shared_marks = physical.marks_file_for(shared_role, true)
    shared_window = source.read_window(shared_data, shared_marks, 0, PARENT_ROWS.size)
    expected_marks = PARENT_ROWS
    require!(shared_window.rows_per_mark == expected_marks, "SharedVariant physical mark rows differ from parent P literal")
    offsets = shared_window.offsets
    bytes = shared_window.bytes

    size_role = data_bindings.keys.find { |role| role.ends_with?(".string_sizes") }
    size_window = nil.as(CrystalClick::CompressedMarkWindow?)
    if profile_name == "with_size_stream"
      size_key = size_role || raise(CrystalClick::CorruptPartError.new("with-size String profile has no size role"))
      size_window = source.read_window(physical.data_file_for(size_key, true), physical.marks_file_for(size_key, true), 0, PARENT_ROWS.size)
      require!(size_window.not_nil!.rows_per_mark == expected_marks, "SharedVariant size-lane physical mark rows differ from parent P")
    else
      require!(size_role.nil?, "single-stream profile unexpectedly has a String size lane")
    end

    expected_discriminators = Array(Array(UInt8)).new(fixed[:contents_by_mark].size)
    fixed[:contents_by_mark].each do |mark|
      expected_discriminators << mark.map { |content| content.nil? ? 0xff_u8 : 0_u8 }
    end
    discr_role = data_bindings.keys.find { |role| role.ends_with?(".discriminators") } ||
                 raise(CrystalClick::CorruptPartError.new("Dynamic discriminator lane is absent"))
    discr_window = source.read_window(
      physical.data_file_for(discr_role, true), physical.marks_file_for(discr_role, true),
      0, PARENT_ROWS.size, CrystalClick::BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
    )
    require!(discr_window.rows_per_mark == PARENT_ROWS, "Dynamic discriminator physical mark rows differ from parent P")
    discr_bytes = discr_window.bytes
    discr_offsets = discr_window.offsets
    require!(discr_bytes.size >= 8 && discr_bytes[0, 8].all? { |byte| byte == 0_u8 },
      "BASIC physical discriminator mode prefix is not the literal UInt64(0)")
    discriminators = Array(Array(UInt8)).new(fixed[:contents_by_mark].size)
    expected_discriminators.each_with_index do |wanted, mark_index|
      first = discr_offsets[mark_index].to_i
      following = discr_offsets[mark_index + 1].to_i
      actual = discr_bytes[first, following - first]
      require!(actual == byte_slice(wanted), "physical discriminator bytes differ; NULL is 255 and shared actual is 0")
      discriminators << actual.to_a
    end

    envelopes = Array(Array(String?)).new(fixed[:contents_by_mark].size)
    literals = Array(Array(String?)).new(fixed[:contents_by_mark].size)
    fixed[:contents_by_mark].each_with_index do |contents, mark_index|
      mark_envelopes = [] of String?
      mark_literals = [] of String?
      data_cursor = offsets[mark_index].to_i
      data_end = offsets[mark_index + 1].to_i
      if size_window
        size_bytes = size_window.not_nil!.bytes
        size_offsets = size_window.not_nil!.offsets
        size_cursor = size_offsets[mark_index].to_i
        size_end = size_offsets[mark_index + 1].to_i
        selected_count = contents.count { |content| !content.nil? }
        require!(size_end - size_cursor == selected_count * 8,
          "String size lane does not have one UInt64 per selected SharedVariant arm")
        contents.each do |content|
          if content.nil?
            mark_envelopes << nil
            mark_literals << nil
            next
          end
          length = 0_u64
          8.times { |index| length |= size_bytes[size_cursor + index].to_u64 << (index * 8) }
          size_cursor += 8
          require!(length <= (data_end - data_cursor).to_u64, "SharedVariant size escapes its mark")
          raw = bytes[data_cursor, length.to_i]
          data_cursor += length.to_i
          parsed = parse_envelope(raw, fixed[:case_id])
          ids = content.empty? ? [] of UInt8 : content.split(",").map(&.to_u8)
          expected = ids.map { |id| {id, id.to_i64 * 10_i64 + 1_i64} }
          require!(parsed == expected, "raw JSON envelope semantic map differs from literal IDs/counters")
          literal = literal_envelope(fixed[:case_id], content)
          literal_bytes = byte_slice(literal)
          if origin_library?(part)
            require!(raw == literal_bytes,
              "library SharedVariant envelope differs from independent canonical literal")
          end
          mark_envelopes << raw.hexstring
          mark_literals << literal_bytes.hexstring
        end
        require!(size_cursor == size_end, "String size lane has trailing selected-arm entries")
      else
        contents.each do |content|
          if content.nil?
            mark_envelopes << nil
            mark_literals << nil
            next
          end
          length, data_cursor = read_varuint(bytes, data_cursor)
          require!(length <= (data_end - data_cursor).to_u64, "SharedVariant VarUInt length escapes its mark")
          raw = bytes[data_cursor, length.to_i]
          data_cursor += length.to_i
          parsed = parse_envelope(raw, fixed[:case_id])
          ids = content.empty? ? [] of UInt8 : content.split(",").map(&.to_u8)
          expected = ids.map { |id| {id, id.to_i64 * 10_i64 + 1_i64} }
          require!(parsed == expected, "raw JSON envelope semantic map differs from literal IDs/counters")
          literal = literal_envelope(fixed[:case_id], content)
          literal_bytes = byte_slice(literal)
          if origin_library?(part)
            require!(raw == literal_bytes,
              "library SharedVariant envelope differs from independent canonical literal")
          end
          mark_envelopes << raw.hexstring
          mark_literals << literal_bytes.hexstring
        end
      end
      require!(data_cursor == data_end, "SharedVariant mark has trailing raw bytes")
      envelopes << mark_envelopes
      literals << mark_literals
    end

    # Report every physical .mrk2 file (including the key lane) and its third
    # word, preserving filenames for the parent runner's immutable manifest.
    mark_roster = Hash(String, Array(UInt64)).new
    checksums = CrystalClick::PartChecksums.open(part)
    checksums.entries.keys.sort.each do |name|
      next unless name.ends_with?(".mrk2")
      mark_roster[name] = mark_words(File.join(part, name))
    end
    {discriminators: discriminators, envelopes: envelopes, literal_envelopes: literals,
     mark_words: mark_roster, checksum_file_names: checksums.entries.keys.sort}
  end

  # Part paths distinguish the two independently owned consumers by the
  # helper's fixed generated subtree; no caller-supplied marker is trusted.
  private def origin_library?(part : String) : Bool
    part.includes?("/generated/")
  end

  private def reader_record(part : String, fixed : Fixture, profile_name : String, origin : String) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(
      part, COLUMN, fixed[:type], CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::CompressedStreamLimits.new,
    )
    require!(reader.schema_declaration == fixed[:type].name, "#{origin} nominal schema differs")
    require!(reader.row_count == 8_u64 && reader.mark_count == 4, "#{origin} row/mark census differs")
    require!(reader.mark_row_counts == PARENT_ROWS, "#{origin} parent row grid P differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} String profile differs")
    low_level_by_mark = reader.read_marks(0, reader.mark_count)
    marks = low_level_by_mark.map { |mark| mark.map { |value| signature(value) } }
    require!(marks == fixed[:expected_rows], "#{origin} row values differ from independent literals")
    [0, 1, 3].each do |mark_index|
      require!(reader.read_marks(mark_index, 1).map { |mark| mark.map { |value| signature(value) } } == [fixed[:expected_rows][mark_index]],
        "#{origin} first/middle/final mark selection differs")
    end
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin} EOF zero-mark selection is not empty")

    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    candidate_marks = [0, 1, 2, 3]
    table_values = Array(Array(String)).new(4) { [] of String }
    table.scan_typed_candidate_marks([candidate_marks]) do |batch|
      mark = batch.mark_index
      require!(batch.part_index == 0 && mark >= 0 && mark < 4, "#{origin} typed candidate identity escapes the fixed matrix")
      expected_offset = (mark * 2).to_u64
      require!(batch.mark_row_offset == 0_u64 && batch.part_row_offset == expected_offset && batch.source_row_offset == expected_offset,
        "#{origin} typed candidate offsets differ from P")
      require!(batch.values_for(KEY_NAME, UInt64).size == 2, "#{origin} key/Dynamic candidate counts differ")
      table_values[mark] = batch.dynamic_bulk_values_for(COLUMN).to_a.map { |value| signature(value) }
    end
    require!(table_values == fixed[:expected_rows], "#{origin} typed table candidate values differ")
    middle = [] of String
    table.scan_typed_window(1_u64, 6) do |batch|
      start = (batch.mark_index * 2).to_u64
      offset = batch.mark_index == 0 ? 1_u64 : 0_u64
      expected_offset = start + offset
      require!(batch.mark_row_offset == offset && batch.part_row_offset == expected_offset && batch.source_row_offset == expected_offset,
        "#{origin} typed window offsets differ")
      middle.concat(batch.dynamic_bulk_values_for(COLUMN).to_a.map { |value| signature(value) })
    end
    require!(middle == fixed[:expected_rows].flatten[1, 6], "#{origin} typed middle window differs")
    eof_callbacks = 0
    table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{origin} typed EOF window invoked a callback")

    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(fixed[:type], fixed[:structures], budget, profile(profile_name))
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, COLUMN, CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    physical_names = physical.stream_names.values.sort!
    validate_roster!(physical_names, fixed[:case_id], profile_name)
    require!(reader.physical_stream_names.sort == physical_names, "#{origin} columns_substreams differs from exact plan roster")
    raw = read_raw_shared_lane(part, fixed, physical, profile_name)
    checksums = CrystalClick::PartChecksums.open(part)
    selected_checksum_names = reader.selected_checksum_names.sort!
    selected_checksum_names.each { |name| require!(checksums.entries.has_key?(name), "#{origin} selected checksum file is absent: #{name}") }
    expected_file_names = physical_names.flat_map do |name|
      stem = CrystalClick::StreamName.hash(name)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end
    expected_file_names.each do |name|
      require!(checksums.entries.has_key?(name), "#{origin} physical stream file is absent from checksums.txt: #{name}")
    end
    mark_rows = raw[:mark_words]
    expected_site_words = PARENT_MARK_THIRD_WORDS
    physical_names.each do |name|
      next unless name.ends_with?("variant_discr") || name.ends_with?("SharedVariant") || name.ends_with?("SharedVariant.size")
      file = "#{CrystalClick::StreamName.hash(name)}.mrk2"
      require!(mark_rows[file]? == expected_site_words, "#{origin} physical mark third words differ for #{name}")
    end
    if fixed[:case_id] == "array_dynamic_array_json"
      file = "#{CrystalClick::StreamName.hash("payload.size0")}.mrk2"
      require!(mark_rows[file]? == PARENT_MARK_THIRD_WORDS, "#{origin} outer array size marks do not retain parent grid P")
    end
    require!(mark_rows.values.all? { |words| words == PARENT_MARK_THIRD_WORDS },
      "#{origin} physical mark third words differ from parent P")

    raw_hex = Array(Array(String?)).new(raw[:envelopes].size)
    raw[:envelopes].each { |mark| raw_hex << mark }
    record = {
      "schema_declaration"           => JSON::Any.new(reader.schema_declaration),
      "row_count"                    => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"                   => JSON::Any.new(reader.mark_count),
      "mark_row_counts"              => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "site_occurrence_counts"       => JSON::Any.new(fixed[:site_occurrence_rows].map { |count| JSON::Any.new(count.to_i64) }),
      "ordinary_profile"             => JSON::Any.new(profile_name),
      "rows_by_mark"                 => JSON::Any.new(marks.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names"        => JSON::Any.new(physical_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names"      => JSON::Any.new(selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "checksum_file_names"          => JSON::Any.new(checksums.entries.keys.sort.map { |name| JSON::Any.new(name) }),
      "mark_row_words_by_file"       => JSON::Any.new(mark_rows.to_a.sort_by(&.[0]).map { |name, words| JSON::Any.new({"file" => JSON::Any.new(name), "third_words" => JSON::Any.new(words.map { |word| JSON::Any.new(word.to_i64) })}) }),
      "discriminator_bytes_by_mark"  => JSON::Any.new(raw[:discriminators].map { |mark| JSON::Any.new(mark.map { |byte| JSON::Any.new(byte.to_i) }) }),
      "shared_envelope_hex_by_mark"  => JSON::Any.new(raw_hex.map { |mark| JSON::Any.new(mark.map { |hex| hex ? JSON::Any.new(hex) : JSON::Any.new(nil) }) }),
      "literal_envelope_hex_by_mark" => JSON::Any.new(raw[:literal_envelopes].map { |mark| JSON::Any.new(mark.map { |hex| hex ? JSON::Any.new(hex) : JSON::Any.new(nil) }) }),
      "windows"                      => JSON::Any.new(["full", "first", "middle", "final", "eof_zero"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any
    if origin == "source"
      observation = CrystalClick::DynamicOwnedValuesW220.materialize(
        part,
        COLUMN,
        fixed[:type],
        reader.row_count,
        reader.mark_row_counts,
        fixed[:granules],
        low_level_by_mark,
      )
      record["owned_values"] = CrystalClick::DynamicOwnedValuesW220.to_json(observation) do |value|
        signature(value)
      end
    end
    JSON::Any.new(record)
  end

  private def write_library_part!(path : String, fixed : Fixture, profile_name : String) : Nil
    keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      path, KEY_NAME, keys, COLUMN, fixed[:type], fixed[:structures], fixed[:granules],
      rows_per_mark: 2, profile: profile(profile_name), frame_bytes: 4096,
      metadata_version: 0_i64, limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    require!(result == path, "writer returned a different part path")
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String) : JSON::Any
    case_id = item["case_id"].as_s
    profile_name = item["profile_id"].as_s
    require!(CASE_IDS.includes?(case_id) && PROFILE_IDS.includes?(profile_name), "case/profile is outside the fixed roster")
    require!(item["capture_root"].as_s == capture_root, "capture root differs")
    source_part = item["source_part"].as_s
    library_part = item["library_part"].as_s
    validate_part_path!(source_part, capture_root, false)
    validate_part_path!(library_part, output_root, true)
    fixed = make_fixture(case_id)
    write_library_part!(library_part, fixed, profile_name)
    source = reader_record(source_part, fixed, profile_name, "source")
    library = reader_record(library_part, fixed, profile_name, "library")
    JSON::Any.new({
      "case_id"           => JSON::Any.new(case_id),
      "profile_id"        => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source"            => source,
      "library"           => library,
    } of String => JSON::Any)
  end

  private def self_test : Nil
    require!(CASE_IDS.size * PROFILE_IDS.size == 8, "fixed matrix count is not eight")
    CASE_IDS.each do |case_id|
      fixed = make_fixture(case_id)
      require!(fixed[:granules].size == 4 && fixed[:granules].all? { |mark| mark.size == 2 },
        "fixed parent P fixture differs")
      require!(fixed[:contents_by_mark].map(&.size) == fixed[:site_occurrence_rows],
        "fixed Dynamic Q fixture differs from the literal discriminator schedule")
    end
    require!(make_fixture("array_dynamic_array_json")[:site_occurrence_rows] == OUTER_ROWS,
      "outer Dynamic Q fixture differs from its explicit four-mark grid")
    null_contents = make_fixture("root_array_json")[:contents_by_mark][0]
    empty_json_contents = make_fixture("root_array_json")[:contents_by_mark][1]
    null_q = null_contents.size
    null_r = null_contents.count { |content| !content.nil? }
    empty_json_q = empty_json_contents.size
    empty_json_r = empty_json_contents.count { |content| !content.nil? }
    require!(null_q == 2 && null_r == 0 && empty_json_q == 2 && empty_json_r == 2,
      "logical Q occurrences must differ from compact selected-arm R for NULL but retain empty JSON arms")
    literal = literal_envelope("root_json", "31")
    parsed = parse_envelope(byte_slice(literal), "root_json")
    require!(parsed == [{31_u8, 311_i64}], "direct JSON literal self-test differs")
    row_bytes = literal[JSON_DESCRIPTOR.size, literal.size - JSON_DESCRIPTOR.size]
    reordered_descriptor = reordered_json_descriptor
    reordered_wire = reordered_descriptor + row_bytes
    require!(parse_envelope(byte_slice(reordered_wire), "root_json") == parsed &&
             byte_slice(canonicalize_envelope_descriptor(byte_slice(reordered_wire), "root_json")) == byte_slice(literal),
      "unordered typed-path descriptor order was not accepted and normalized")
    wrong_child_descriptor = reordered_descriptor.dup
    wrong_child_descriptor[16] = 0x02_u8
    rejected_typed_child = false
    begin
      parse_envelope(byte_slice(wrong_child_descriptor + row_bytes), "root_json")
    rescue ex : CrystalClick::CorruptPartError
      rejected_typed_child = true
    end
    require!(rejected_typed_child, "wrong typed-child descriptor mutation was accepted")
    tuple_literal = literal_envelope("root_tuple_json", "51,52")
    tuple_parsed = parse_envelope(byte_slice(tuple_literal), "root_tuple_json")
    require!(tuple_parsed == [{51_u8, 511_i64}, {52_u8, 521_i64}], "unnamed Tuple(JSON,JSON) literal self-test differs")
    tuple_row_offset = 2 + JSON_DESCRIPTOR.size * 2
    tuple_reordered = [0x1f_u8, 0x02_u8] + reordered_descriptor + reordered_descriptor +
                      tuple_literal[tuple_row_offset, tuple_literal.size - tuple_row_offset]
    require!(parse_envelope(byte_slice(tuple_reordered), "root_tuple_json") == tuple_parsed,
      "Tuple(JSON,JSON) did not accept semantically equivalent descriptor order")
    array_literal = literal_envelope("root_array_json", "41")
    array_descriptor_end = 1 + JSON_DESCRIPTOR.size
    array_reordered = [0x1e_u8] + reordered_descriptor +
                      array_literal[array_descriptor_end, array_literal.size - array_descriptor_end]
    require!(parse_envelope(byte_slice(array_reordered), "root_array_json") ==
             parse_envelope(byte_slice(array_literal), "root_array_json"),
      "Array(JSON) did not accept semantically equivalent descriptor order")
    empty_array = literal_envelope("root_array_json", "")
    require!(parse_envelope(byte_slice(empty_array), "root_array_json").empty?, "empty Array(JSON) literal self-test differs")
    mutated = literal.dup
    mutated[-1] = 0_u8
    rejected_semantics = false
    begin
      parse_envelope(byte_slice(mutated), "root_json")
    rescue ex : CrystalClick::CorruptPartError
      rejected_semantics = true
    end
    require!(rejected_semantics, "semantic mutation survived literal-envelope self-test")
    expected = expected_roster("root_json", "single_stream")
    validate_roster!(expected, "root_json", "single_stream")
    rejected_roster = false
    begin
      validate_roster!(expected + ["payload.object_structure"], "root_json", "single_stream")
    rescue ex : CrystalClick::CorruptPartError
      rejected_roster = true
    end
    require!(rejected_roster, "roster mutation survived fixed-roster self-test")
    puts "W213 self-test passed matrix_count=#{CASE_IDS.size * PROFILE_IDS.size} semantic_and_roster_mutations=rejected"
  end

  private def run(args : Array(String)) : Nil
    if args == ["--self-test"]
      self_test
      return
    end
    unless args.size == 2
      raise ArgumentError.new("usage: check_dynamic_shared_json_w213.cr INPUT.json OUTPUT_ROOT | --self-test")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "output root must be canonical and non-symlinked")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input must be a plain file below output root")
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    expected = CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile_name| "#{case_id}/#{profile_name}" } }
    observed = cases.map { |item| "#{item["case_id"].as_s}/#{item["profile_id"].as_s}" }
    require!(observed == expected, "case/profile order differs from the fixed eight-row matrix")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part"],
        "case input keys differ")
    end
    results = cases.map { |item| process_case(item, capture_root, output_root) }
    puts JSON::Any.new({
      "format"                       => JSON::Any.new(FORMAT_OUTPUT),
      "case_ids"                     => JSON::Any.new(CASE_IDS.map { |name| JSON::Any.new(name) }),
      "profile_ids"                  => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "parent_mark_rows"             => JSON::Any.new(PARENT_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "outer_site_occurrence_counts" => JSON::Any.new(OUTER_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "matrix_count"                 => JSON::Any.new(results.size),
      "cases"                        => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W213 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckDynamicSharedJSONW213.main(ARGV)
