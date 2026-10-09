require "../src/crystal_click"
require "json"

module CheckObjectRecursiveQBitW234
  extend self

  INPUT_FORMAT   = "object_recursive_qbit_w234_input_v1"
  OUTPUT_FORMAT  = "object_recursive_qbit_w234_helper_v1"
  COLUMN         = "j"
  KEY_NAME       = "id"
  ROW_COUNT      = 6_u64
  MARK_ROWS      = [2_u64, 2_u64, 2_u64]
  PROFILE_IDS    = ["typed_dynamic", "inferred_dynamic", "forced_shared"]
  DIRECT_ROW_HEX = [
    "1e360709020901020304050607080909000000000000000000",
    "1e36070900",
    "20020171360709016e0109ff000102040810204007",
    "271536070902016109010203040506070809046c6f6e6709090807060504030201",
    "1e3607090109000000000000000000",
    "00",
  ]
  EXPECTED_TYPES = [
    "Array(QBit(Int8, 9))",
    "Map(String, QBit(Int8, 9))",
    "Tuple(q QBit(Int8, 9), n UInt8)",
  ].sort!
  EXPECTED_QBIT_HEX = [
    ["010203040506070809", "000000000000000000"],
    [] of String,
    ["ff0001020408102040"],
    ["010203040506070809", "090807060504030201"],
    ["000000000000000000"],
    [] of String,
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W234: #{message}") unless condition
  end

  private def raw_bytes(hex : String) : Bytes
    unless hex.bytesize.even? && hex.matches?(/\A(?:[0-9a-f]{2})*\z/)
      raise ArgumentError.new("W234 QBit literal is not lowercase even-width hex")
    end
    Bytes.new(hex.bytesize // 2) do |index|
      hex.byte_slice(index * 2, 2).to_u8(16)
    end
  end

  private def qtype : CrystalClick::QBitType
    CrystalClick::QBitType.new("Int8", 9_u64)
  end

  private def qvalue(type : CrystalClick::QBitType, hex : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw_bytes(hex)))
  end

  private def actual_values : Array(CrystalClick::BinaryValue)
    q = CrystalClick::BinaryDataType.qbit(qtype)
    array = CrystalClick::BinaryDataType.array(q)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple = CrystalClick::BinaryDataType.tuple(
      [q, uint8] of CrystalClick::BinaryDataType,
      ["q", "n"] of String,
    )
    string = CrystalClick::BinaryDataType.primitive("String")
    map = CrystalClick::BinaryDataType.map(string, q)
    [
      CrystalClick::BinaryValue.array(array, [
        qvalue(qtype, "010203040506070809"),
        qvalue(qtype, "000000000000000000"),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.tuple(tuple, [
        qvalue(qtype, "ff0001020408102040"),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(map, [
        CrystalClick::BinaryValue.string("a"), qvalue(qtype, "010203040506070809"),
        CrystalClick::BinaryValue.string("long"), qvalue(qtype, "090807060504030201"),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [
        qvalue(qtype, "000000000000000000"),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  end

  private def profile_schema(id : String) : CrystalClick::ObjectDocumentSchema
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 3)
    case id
    when "typed_dynamic"
      CrystalClick::ObjectDocumentSchema.new(
        {"q" => dynamic} of String => CrystalClick::BinaryDataType,
        max_dynamic_paths: 0,
      )
    when "inferred_dynamic"
      CrystalClick::ObjectDocumentSchema.new(
        {} of String => CrystalClick::BinaryDataType,
        max_dynamic_paths: 1,
        max_dynamic_types: 3,
      )
    when "forced_shared"
      CrystalClick::ObjectDocumentSchema.new(
        {} of String => CrystalClick::BinaryDataType,
        max_dynamic_paths: 0,
        max_dynamic_types: 3,
      )
    else
      raise ArgumentError.new("W234 profile is outside the fixed roster")
    end
  end

  private def expected_documents(id : String, actuals : Array(CrystalClick::BinaryValue)) : Array(CrystalClick::ObjectDocument)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 3)
    Array(CrystalClick::ObjectDocument).new(6) do |index|
      values = Hash(String, CrystalClick::BinaryValue).new
      if id == "typed_dynamic"
        child = index < actuals.size ? actuals[index] : nil
        values["q"] = CrystalClick::BinaryValue.dynamic(dynamic, child)
      elsif index < actuals.size
        values["q"] = actuals[index]
      end
      CrystalClick::ObjectDocument.new(values)
    end
  end

  private def same_value?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
    left.type == right.type &&
      CrystalClick::BinaryValueCodec.encode(left) == CrystalClick::BinaryValueCodec.encode(right)
  end

  private def compare_documents!(actual : Array(Array(CrystalClick::ObjectDocument)), expected : Array(Array(CrystalClick::ObjectDocument)), label : String) : Nil
    require!(actual.size == expected.size, "mark count differs for #{label}")
    actual.each_with_index do |rows, mark|
      expected_rows = expected[mark]
      require!(rows.size == expected_rows.size, "row count differs for #{label}/#{mark}")
      rows.each_with_index do |document, row|
        expected_document = expected_rows[row]
        require!(document.has_path?("q") == expected_document.has_path?("q"), "q path presence differs for #{label}/#{mark}/#{row}")
        next unless expected_document.has_path?("q")
        value = document.value_for("q")
        expected_value = expected_document.value_for("q")
        require!(same_value?(value, expected_value), "nominal type or exact value differs for #{label}/#{mark}/#{row}")
      end
    end
  end

  private def collect_qbits(value : CrystalClick::BinaryValue, output : Array(String)) : Nil
    if value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
      collect_qbits(value.child_at(0), output) if value.element_count > 0
    elsif value.type.tag == CrystalClick::BinaryDataType::TAG_QBIT
      output << value.qbit_value.raw_bytes.hexstring.downcase
    else
      value.element_count.times { |index| collect_qbits(value.element_at(index), output) }
    end
  end

  private def row_direct_value(document : CrystalClick::ObjectDocument) : CrystalClick::BinaryValue
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 3)
    return CrystalClick::BinaryValue.dynamic(dynamic) unless document.has_path?("q")
    value = document.value_for("q")
    return value if value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
    CrystalClick::BinaryValue.dynamic(dynamic, value)
  end

  private def profile_roster(id : String, plan : CrystalClick::ObjectDocumentPlan) : JSON::Any
    structures = plan.structures
    object = structures.object
    object_paths = object.dynamic_paths.sort!
    typed_paths = plan.typed_paths.keys.sort!
    typed_dynamic_paths = plan.typed_dynamics.keys.sort!
    dynamic_rosters = Hash(String, Array(String)).new
    object_paths.each do |path|
      dynamic_rosters[path] = structures.dynamic_for(path).types.map(&.name).sort!
    end
    typed_rosters = Hash(String, Array(String)).new
    typed_dynamic_paths.each do |path|
      typed_rosters[path] = plan.typed_dynamic_for(path).types.map(&.name).sort!
    end

    expected_object_paths, expected_typed_paths, expected_typed_dynamic = case id
                                                                          when "typed_dynamic"    then {[] of String, ["q"], ["q"]}
                                                                          when "inferred_dynamic" then {["q"], [] of String, [] of String}
                                                                          when "forced_shared"    then {[] of String, [] of String, [] of String}
                                                                          else                         raise ArgumentError.new("W234 route profile is outside the fixed roster")
                                                                          end
    require!(object_paths == expected_object_paths && typed_paths == expected_typed_paths &&
             typed_dynamic_paths == expected_typed_dynamic, "Object/Dynamic structure route differs for #{id}")
    # Object V3 is stored as tag 4. ADVANCED_CHUNKED is a separate shared-data
    # version (3); Wide parts with no shared-data paths persist one bucket even
    # when the configured target is two. Only forced_shared has shared paths.
    expected_bucket_count = id == "forced_shared" ? 2_u64 : 1_u64
    require!(object.version == 4_u64 && object.shared_data_version == 3_u64 &&
             object.bucket_count == expected_bucket_count,
      "persisted Object V3/advanced_chunked layout differs for #{id}")

    if id == "inferred_dynamic"
      require!(dynamic_rosters == {"q" => EXPECTED_TYPES}, "inferred q Dynamic roster differs")
    elsif id == "typed_dynamic"
      require!(typed_rosters == {"q" => EXPECTED_TYPES}, "typed q Dynamic roster differs")
    else
      require!(dynamic_rosters.empty? && typed_rosters.empty?, "forced-shared route unexpectedly has Dynamic structure metadata")
    end

    JSON::Any.new({
      "object_version"       => JSON::Any.new(object.version.to_i64),
      "object_dynamic_paths" => JSON::Any.new(object_paths.map { |value| JSON::Any.new(value) }),
      "typed_paths"          => JSON::Any.new(typed_paths.map { |value| JSON::Any.new(value) }),
      "typed_dynamic_paths"  => JSON::Any.new(typed_dynamic_paths.map { |value| JSON::Any.new(value) }),
      "dynamic_type_rosters" => JSON::Any.new(dynamic_rosters.map { |path, types| JSON::Any.new({
        "path" => JSON::Any.new(path), "types" => JSON::Any.new(types.map { |value| JSON::Any.new(value) }),
      } of String => JSON::Any) }),
      "typed_dynamic_type_rosters" => JSON::Any.new(typed_rosters.map { |path, types| JSON::Any.new({
        "path" => JSON::Any.new(path), "types" => JSON::Any.new(types.map { |value| JSON::Any.new(value) }),
      } of String => JSON::Any) }),
      "shared_data_version" => JSON::Any.new(object.shared_data_version.to_i64),
      "bucket_count"        => JSON::Any.new(object.bucket_count.to_i64),
    } of String => JSON::Any)
  end

  private def canonical_part!(path : String, root : String, generated : Bool) : String
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part path escaped its fixed root")
    if generated
      require!(!File.exists?(full) && !File.symlink?(full), "library destination is not fresh")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "library destination parent is absent or noncanonical")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock source part is absent or noncanonical")
    end
    full
  end

  private def reader_record(part : String, schema : CrystalClick::ObjectDocumentSchema, id : String, origin : String) : Tuple(JSON::Any, Array(Array(CrystalClick::ObjectDocument)), CrystalClick::ObjectColumnReader, CrystalClick::ObjectDocumentPlan)
    reader = CrystalClick::ObjectColumnReader.open(part, COLUMN, schema)
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      COLUMN,
      schema.typed_paths,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    require!(reader.source_declaration == schema.declaration && reader.schema_declaration == schema.declaration,
      "declared/source Object schema differs for #{origin}")
    require!(reader.row_count == ROW_COUNT && reader.mark_row_counts == MARK_ROWS,
      "fixed six-row/three-mark grid differs for #{origin}")
    require!(reader.ordinary_profile == CrystalClick::BinaryBulkProfile.single_stream,
      "ordinary String bulk profile differs for #{origin}")
    stream_names = reader.physical_stream_names.sort!
    expected_names = descriptor.physical_stream_names.sort!
    require!(stream_names == expected_names && stream_names.uniq == stream_names,
      "physical stream roster differs for #{origin}")

    expected = expected_documents(id, actual_values)
    full = reader.read_marks(0, MARK_ROWS.size)
    expected_marks = [expected[0, 2], expected[2, 2], expected[4, 2]]
    compare_documents!(full, expected_marks, "#{origin} full")
    middle = reader.read_marks(1, 1)
    compare_documents!(middle, [expected_marks[1]], "#{origin} middle")
    zero = reader.read_marks(3, 0)
    eof = reader.read_marks(reader.mark_row_counts.size, 0)
    require!(zero.empty? && eof.empty?, "zero/EOF public reads are not empty for #{origin}")

    direct_hex = full.flatten.map do |document|
      CrystalClick::BinaryValueCodec.encode_value(row_direct_value(document)).hexstring.downcase
    end
    require!(direct_hex == DIRECT_ROW_HEX, "direct-path Dynamic RowBinary literals differ for #{origin}")
    actual_rows = full.flatten.each_with_index.map do |document, index|
      path_present = document.has_path?("q")
      value = path_present ? document.value_for("q") : nil
      selected = if value && value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
                   value.is_null? ? nil : value.child_at(0)
                 else
                   value
                 end
      qbits = [] of String
      collect_qbits(selected, qbits) if selected
      actual_type = selected ? selected.type.name : "None"
      require!(qbits == EXPECTED_QBIT_HEX[index], "nested QBit raw bytes differ on #{origin} row #{index + 1}")
      JSON::Any.new({
        "id"                   => JSON::Any.new((index + 1).to_i64),
        "path_present"         => JSON::Any.new(path_present),
        "dynamic_type"         => JSON::Any.new(actual_type),
        "qbit_raw_hex"         => JSON::Any.new(qbits.map { |hex| JSON::Any.new(hex) }),
        "direct_rowbinary_hex" => JSON::Any.new(direct_hex[index]),
      } of String => JSON::Any)
    end.to_a
    roster = profile_roster(id, descriptor.plan)

    windows = JSON::Any.new({
      "full"               => JSON::Any.new(direct_hex.map { |value| JSON::Any.new(value) }),
      "middle"             => JSON::Any.new(direct_hex[2, 2].map { |value| JSON::Any.new(value) }),
      "zero"               => JSON::Any.new([] of JSON::Any),
      "eof_returned_marks" => JSON::Any.new(eof.size.to_i64),
    } of String => JSON::Any)
    record = JSON::Any.new({
      "row_count"                             => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"                       => JSON::Any.new(reader.mark_row_counts.map { |value| JSON::Any.new(value.to_i64) }),
      "schema_declaration"                    => JSON::Any.new(reader.schema_declaration),
      "ordinary_string_profile"               => JSON::Any.new("single_stream"),
      "physical_stream_names"                 => JSON::Any.new(stream_names.map { |value| JSON::Any.new(value) }),
      "structure"                             => roster,
      "rows"                                  => JSON::Any.new(actual_rows),
      "windows"                               => windows,
      "exact_nominal_and_qbit_literal_checks" => JSON::Any.new(true),
    } of String => JSON::Any)
    {record, full, reader, descriptor.plan}
  end

  private def write_library_part!(path : String, schema : CrystalClick::ObjectDocumentSchema, plan : CrystalClick::ObjectDocumentPlan, reader : CrystalClick::ObjectColumnReader, rows : Array(Array(CrystalClick::ObjectDocument))) : Nil
    result = CrystalClick::WidePartWriter.write_uint64_object_pair(
      path,
      KEY_NAME,
      Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64],
      COLUMN,
      schema,
      plan,
      rows,
      rows_per_mark: 2,
      profile: reader.ordinary_profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
      metadata_version: 0_i64,
    )
    require!(result == path, "public Object writer returned a different path")
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_recursive_qbit_w234.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    require!(Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root,
      "output root must be canonical and non-symlinked")
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR),
      "helper input must be a plain file below output root")

    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["format", "profiles", "stock_root"] && input["format"].as_s == INPUT_FORMAT,
      "helper input envelope differs")
    stock_root = File.expand_path(input["stock_root"].as_s)
    require!(Dir.exists?(stock_root) && !File.symlink?(stock_root) && File.realpath(stock_root) == stock_root,
      "stock root is absent, symlinked, or noncanonical")
    profiles = input["profiles"].as_a
    require!(profiles.map { |item| item["id"].as_s } == PROFILE_IDS, "profile roster or order differs")

    actuals = actual_values
    output = profiles.map do |item|
      require!(item.as_h.keys.sort == ["id", "library_part", "source_part"], "profile input fields differ")
      id = item["id"].as_s
      schema = profile_schema(id)
      source_part = canonical_part!(item["source_part"].as_s, stock_root, false)
      library_part = canonical_part!(item["library_part"].as_s, output_root, true)

      source_record, source_rows, source_reader, source_plan = reader_record(source_part, schema, id, "stock/#{id}")
      write_library_part!(library_part, schema, source_plan, source_reader, source_rows)
      library_record, _library_rows, _library_reader, _library_plan = reader_record(library_part, schema, id, "library/#{id}")
      require!(source_record == library_record, "public reader source/library evidence differs for #{id}")

      JSON::Any.new({
        "id"                => JSON::Any.new(id),
        "column"            => JSON::Any.new(COLUMN),
        "declared_type"     => JSON::Any.new(schema.declaration),
        "source_part_path"  => JSON::Any.new(source_part),
        "library_part_path" => JSON::Any.new(library_part),
        "source"            => source_record,
        "library"           => library_record,
      } of String => JSON::Any)
    end

    puts JSON::Any.new({
      "format"      => JSON::Any.new(OUTPUT_FORMAT),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |id| JSON::Any.new(id) }),
      "profiles"    => JSON::Any.new(output),
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W234 Crystal public Object helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectRecursiveQBitW234.main(ARGV)
