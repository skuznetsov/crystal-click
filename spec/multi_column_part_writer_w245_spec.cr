require "./spec_helper"
require "../scripts/support/schema_wide_part_w245_fixture"
require "file_utils"

private def w245_with_parent(&)
  parent = File.tempname("crystal-click-w245-wide-part-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w245_state_type : CrystalClick::BinaryDataType
  label = CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String")
  )
  total = CrystalClick::BinaryDataType.aggregate_function(
    "sum", CrystalClick::BinaryDataType.primitive("UInt8")
  )
  CrystalClick::BinaryDataType.tuple(
    [label, total] of CrystalClick::BinaryDataType,
    ["label", "total"] of String,
  )
end

private def w245_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w245_write(
  destination : String,
  columns : Array(CrystalClick::WidePartColumn),
  keys : Array(UInt64),
  rows_per_mark : Int32 = 2,
  transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
) : String
  CrystalClick::WidePartWriter.write_uint64_columns(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    columns,
    rows_per_mark: rows_per_mark,
    profile: CrystalClick::BinaryBulkProfile.single_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
    frame_bytes: 32,
    transport_limits: transport_limits,
  )
end

private def w245_expected_columns : String
  String.build do |io|
    roster = SchemaWidePartW245Fixture.column_roster
    io << "columns format version: 1\n" << (roster.size + 1) << " columns:\n"
    io << "`pk` UInt64\n"
    roster.each do |column|
      io << '`' << column["name"] << "` " << column["type"] << '\n'
    end
  end
end

private def w245_expected_substreams(rosters : Array(Tuple(String, Array(String)))) : String
  String.build do |io|
    io << "columns substreams version: 1\n" << (rosters.size + 1) << " columns:\n"
    io << "1 substreams for column `pk`:\n\tpk\n"
    rosters.each do |name, streams|
      io << streams.size << " substreams for column `" << name << "`:\n"
      streams.each { |stream| io << '\t' << stream << '\n' }
    end
  end
end

private def w245_expected_physical_pair(logical_name : String) : Array(String)
  base = CrystalClick::StreamName.hash(logical_name)
  ["#{base}.bin", "#{base}.mrk2"]
end

private def w245_assert_no_publication(parent : String, destination : String) : Nil
  File.exists?(destination).should be_false
  Dir.children(parent).should be_empty
end

private def w245_assert_dynamic(
  value : CrystalClick::BinaryValue,
  kind : String,
  integer : UInt64? = nil,
  string : String? = nil,
) : Nil
  value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
  case kind
  when "null"
    value.is_null?.should be_true
    value.child_count.should eq(0)
  when "uint64"
    value.is_null?.should be_false
    value.child_count.should eq(1)
    value.child_at(0).as_uint64.should eq(integer.not_nil!)
  when "string"
    value.is_null?.should be_false
    value.child_count.should eq(1)
    value.child_at(0).as_string.should eq(string.not_nil!)
  else
    raise "unknown W245 expected Dynamic kind: #{kind}"
  end
  nil
end

describe "W245 schema-wide part publication" do
  it "publishes and reads four admitted value owners under one profile, grid, metadata envelope and checksum roster" do
    ["single", "sized"].each do |profile_name|
      ["basic", "compact"].each do |mode_name|
        profile = SchemaWidePartW245Fixture.profile(profile_name)
        mode = SchemaWidePartW245Fixture.mode(mode_name)
        columns = SchemaWidePartW245Fixture.columns(profile, mode)
        keys = SchemaWidePartW245Fixture::KEYS

        w245_with_parent do |parent|
          destination = File.join(parent, "part")
          CrystalClick::WidePartWriter.write_uint64_columns(
            destination,
            SchemaWidePartW245Fixture::KEY_NAME,
            keys.to_unsafe.to_slice(keys.size),
            columns,
            rows_per_mark: SchemaWidePartW245Fixture::ROWS_PER_MARK,
            profile: profile,
            shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
            mode: mode,
            frame_bytes: SchemaWidePartW245Fixture::FRAME_BYTES,
          ).should eq(destination)

          state_type = w245_state_type
          object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(
            SchemaWidePartW245Fixture::OBJECT_DECLARATION
          )
          recursive_schema = CrystalClick::StorageColumnSchema.parse(
            SchemaWidePartW245Fixture::RECURSIVE_DECLARATION
          )
          state_reader = CrystalClick::BinaryBulkColumnReader.open(destination, "state", state_type)
          dynamic_reader = CrystalClick::DynamicBulkColumnReader.open(
            destination,
            "dyn",
            CrystalClick::BinaryDataType.dynamic(max_types: 1),
          )
          object_reader = CrystalClick::ObjectColumnReader.open(destination, "object", object_schema)
          recursive_reader = CrystalClick::RecursiveStorageColumnReader.open(
            destination, "recursive", recursive_schema
          )

          expected_grid = SchemaWidePartW245Fixture::MARK_ROW_COUNTS
          state_reader.mark_row_counts.should eq(expected_grid)
          dynamic_reader.mark_row_counts.should eq(expected_grid)
          object_reader.mark_row_counts.should eq(expected_grid)
          recursive_reader.mark_row_counts.should eq(expected_grid)

          key_part = CrystalClick::WidePart.open(destination, "pk")
          key_part.row_count.should eq(keys.size.to_u64)
          key_part.mark_row_counts.should eq(expected_grid)
          key_part.read_uint64_mark_range("pk", 0, expected_grid.size).should eq(keys)

          state_rows = state_reader.read_marks(0, state_reader.mark_count).flat_map { |mark| mark }
          state_rows.size.should eq(5)
          ["red", "red", "blue", "red", "blue"].each_with_index do |label, index|
            state = state_rows[index]
            state.type.should eq(state_type)
            state.child_at(0).type.tag.should eq(CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY)
            state.child_at(0).child_at(0).as_string.should eq(label)
            state.child_at(1).aggregate_function_state_bytes.should eq(
              w245_u64_bytes([0_u64, 42_u64, 200_u64, 255_u64, 1000_u64][index])
            )
          end

          dynamic_rows = dynamic_reader.read_marks(0, dynamic_reader.mark_count).flat_map { |mark| mark }
          dynamic_rows.size.should eq(5)
          w245_assert_dynamic(dynamic_rows[0], "uint64", 7_u64)
          w245_assert_dynamic(dynamic_rows[1], "string", nil, "spill")
          w245_assert_dynamic(dynamic_rows[2], "null")
          w245_assert_dynamic(dynamic_rows[3], "uint64", 42_u64)
          w245_assert_dynamic(dynamic_rows[4], "string", nil, "tail-spill")

          object_rows = object_reader.read_marks(0, object_reader.mark_row_counts.size).flat_map { |mark| mark }
          object_rows.size.should eq(5)
          ["doc-1", "doc-2", "doc-3", "doc-4", "doc-5"].each_with_index do |label, index|
            document = object_rows[index]
            document.value_for("label").as_string.should eq(label)
            if index == 2
              document.has_path?("shape").should be_false
            else
              shape = document.value_for("shape")
              case index
              when 0
                shape.as_uint64.should eq(7_u64)
              when 1
                shape.as_string.should eq("spill")
              when 3
                shape.as_uint64.should eq(42_u64)
              when 4
                shape.as_string.should eq("object-spill")
              end
            end
          end

          recursive_rows = recursive_reader.read_marks(0, recursive_reader.mark_count).flat_map { |mark| mark }
          recursive_rows.size.should eq(5)
          recursive_rows.map(&.array_values.size).should eq([0, 0, 1, 1, 3])
          expected_tags = [
            [] of UInt8,
            [] of UInt8,
            [31_u8],
            [41_u8],
            [51_u8, 52_u8, 53_u8],
          ]
          expected_samples = [
            [] of Tuple(String, UInt64),
            [] of Tuple(String, UInt64),
            [{"uint64", 7_u64}],
            [{"string:recursive-spill", 0_u64}],
            [{"uint64", 42_u64}, {"string:tail-recursive", 0_u64}, {"null", 0_u64}],
          ]
          recursive_rows.each_with_index do |root_value, row_index|
            children = root_value.array_values
            children.each_with_index do |child, child_index|
              tuple = child.tuple_values
              document = tuple[0].object_document
              document.value_for("t").byte_at(0).should eq(expected_tags[row_index][child_index])
              dynamic = tuple[1].bulk_value
              sample = expected_samples[row_index][child_index]
              if sample[0] == "string:recursive-spill"
                w245_assert_dynamic(dynamic, "string", nil, "recursive-spill")
              elsif sample[0] == "string:tail-recursive"
                w245_assert_dynamic(dynamic, "string", nil, "tail-recursive")
              else
                w245_assert_dynamic(dynamic, sample[0], sample[1])
              end
            end
          end

          state_reader.read_marks(1, 1)[0][0].child_at(1).aggregate_function_state_bytes.should eq(
            w245_u64_bytes(200_u64)
          )
          dynamic_reader.read_marks(1, 1)[0][0].is_null?.should be_true
          object_reader.read_marks(1, 1)[0][0].value_for("label").as_string.should eq("doc-3")
          recursive_reader.read_marks(1, 1)[0][0].array_values[0].child_at(0)
            .object_document.value_for("t").byte_at(0).should eq(31_u8)
          state_reader.read_marks(3, 0).should be_empty
          dynamic_reader.read_marks(3, 0).should be_empty
          object_reader.read_marks(3, 0).should be_empty
          recursive_reader.read_marks(3, 0).should be_empty

          File.read(File.join(destination, "columns.txt")).should eq(w245_expected_columns)
          value_rosters = [
            {"state", state_reader.physical_stream_names.sort!},
            {"dyn", dynamic_reader.physical_stream_names.sort!},
            {"object", object_reader.physical_stream_names.sort!},
            {"recursive", recursive_reader.physical_stream_names.sort!},
          ] of Tuple(String, Array(String))
          File.read(File.join(destination, "columns_substreams.txt")).should eq(
            w245_expected_substreams(value_rosters)
          )
          string_version = profile_name == "single" ? 0 : 1
          File.read(File.join(destination, "serialization.json")).should eq(
            %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":#{string_version}},"version":1})
          )
          File.read(File.join(destination, "count.txt")).should eq("5")
          File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
          File.read(File.join(destination, "metadata_version.txt")).should eq("0")

          logical_names = ["pk"] of String
          value_rosters.each { |_name, streams| logical_names.concat(streams) }
          expected_checksums = [] of String
          logical_names.each do |logical_name|
            expected_checksums.concat(w245_expected_physical_pair(logical_name))
          end
          expected_checksums.concat(["primary.idx", "count.txt", "serialization.json"])
          expected_checksums = expected_checksums.uniq
          checksums = CrystalClick::PartChecksums.open(destination)
          checksums.entries.keys.sort.should eq(expected_checksums.sort)

          expected_files = expected_checksums.dup
          expected_files.concat([
            "columns.txt", "columns_substreams.txt", "default_compression_codec.txt",
            "metadata_version.txt", "checksums.txt",
          ])
          Dir.children(destination).sort.should eq(expected_files.sort)
        end
      end
    end
  end

  it "rejects duplicate names, key collisions, mismatched parent grids, and existing targets before staging" do
    value_type = CrystalClick::BinaryDataType.primitive("UInt64")
    marks = [
      [CrystalClick::BinaryValue.uint64(10_u64), CrystalClick::BinaryValue.uint64(20_u64)] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.uint64(30_u64), CrystalClick::BinaryValue.uint64(40_u64)] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.uint64(50_u64)] of CrystalClick::BinaryValue,
    ]
    keys = SchemaWidePartW245Fixture::KEYS

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      duplicate = [
        CrystalClick::WidePartColumn.binary_bulk("same", value_type, marks),
        CrystalClick::WidePartColumn.binary_bulk("same", value_type, marks),
      ]
      expect_raises(ArgumentError) { w245_write(destination, duplicate, keys) }
      w245_assert_no_publication(parent, destination)
    end

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      collision = [CrystalClick::WidePartColumn.binary_bulk("pk", value_type, marks)]
      expect_raises(ArgumentError) { w245_write(destination, collision, keys) }
      w245_assert_no_publication(parent, destination)
    end

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      mismatched = [
        [CrystalClick::BinaryValue.uint64(1_u64), CrystalClick::BinaryValue.uint64(2_u64)] of CrystalClick::BinaryValue,
        [CrystalClick::BinaryValue.uint64(3_u64), CrystalClick::BinaryValue.uint64(4_u64)] of CrystalClick::BinaryValue,
        [CrystalClick::BinaryValue.uint64(5_u64), CrystalClick::BinaryValue.uint64(6_u64)] of CrystalClick::BinaryValue,
      ]
      columns = [CrystalClick::WidePartColumn.binary_bulk("value", value_type, mismatched)]
      expect_raises(ArgumentError) { w245_write(destination, columns, keys) }
      w245_assert_no_publication(parent, destination)
    end

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      File.write(destination, "keep-existing-target")
      columns = [CrystalClick::WidePartColumn.binary_bulk("value", value_type, marks)]
      expect_raises(ArgumentError) { w245_write(destination, columns, keys) }
      File.read(destination).should eq("keep-existing-target")
      Dir.children(parent).sort.should eq(["part"])
    end
  end

  it "admits root Tuple Dynamic and static Nested descendants while retaining contextual ownership" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [dynamic_type] of CrystalClick::BinaryDataType,
      ["item"] of String,
    )
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
    )

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      structures = {
        "root.field.0" => CrystalClick::DynamicStructure.new(
          [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
        ),
      } of String => CrystalClick::DynamicStructure
      columns = [CrystalClick::WidePartColumn.dynamic_bulk(
        "tuple_dynamic",
        tuple_type,
        structures,
        [[tuple_value] of CrystalClick::BinaryValue],
      )]
      w245_write(destination, columns, [1_u64], rows_per_mark: 1).should eq(destination)

      reader = CrystalClick::DynamicBulkColumnReader.open(destination, "tuple_dynamic", tuple_type)
      reader.mark_row_counts.should eq([1_u64])
      row = reader.read_marks(0, 1)[0][0]
      row.type.should eq(tuple_type)
      row.child_count.should eq(1)
      w245_assert_dynamic(row.child_at(0), "uint64", 7_u64)
    end

    nested = CrystalClick::BinaryDataType.nested(
      [CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))] of CrystalClick::BinaryDataType,
      ["values"] of String,
    )
    nested_tuple = nested.child_at(0)
    nested_array = CrystalClick::BinaryValue.array(
      nested_tuple.child_at(0),
      [CrystalClick::BinaryValue.uint64(9_u64)] of CrystalClick::BinaryValue,
    )
    nested_value = CrystalClick::BinaryValue.nested(
      nested,
      [CrystalClick::BinaryValue.tuple(
        nested_tuple,
        [nested_array] of CrystalClick::BinaryValue,
      )] of CrystalClick::BinaryValue,
    )
    tuple_with_nested = CrystalClick::BinaryDataType.tuple(
      [nested] of CrystalClick::BinaryDataType,
      ["items"] of String,
    )
    value_with_nested = CrystalClick::BinaryValue.tuple(
      tuple_with_nested,
      [nested_value] of CrystalClick::BinaryValue,
    )

    w245_with_parent do |parent|
      destination = File.join(parent, "all_1_1_0")
      columns = [CrystalClick::WidePartColumn.binary_bulk(
        "nested_child",
        tuple_with_nested,
        [[value_with_nested] of CrystalClick::BinaryValue],
      )]
      w245_write(destination, columns, [1_u64], rows_per_mark: 1).should eq(destination)

      table = CrystalClick::WidePartTable.open_selected_typed(
        [destination], ["pk", "nested_child"]
      )
      table.column_types.should eq([
        {"pk", "UInt64"}, {"nested_child", tuple_with_nested.name},
      ])
      observed = [] of CrystalClick::BinaryValue
      table.scan_typed do |batch|
        observed.concat(batch.binary_bulk_values_for("nested_child"))
      end
      observed.size.should eq(1)
      observed[0].type.name.should eq(tuple_with_nested.name)
      restored_nested = observed[0].child_at(0)
      restored_nested.type.name.should eq(nested.name)
      restored_nested.element_count.should eq(1)
      restored_nested.element_at(0).child_at(0).element_at(0).as_uint64.should eq(9_u64)
    end

    schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(doc JSON(x UInt8), items Nested(vals Array(UInt64)))"
    )
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(x UInt8)")
    object_plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        Hash(String, CrystalClick::DynamicStructure).new,
      ),
      object_schema.typed_paths,
    )
    nested_descriptor = schema.child_at(1).bulk_type
    nested_record_type = nested_descriptor.child_at(0)
    nested_record_array = CrystalClick::BinaryValue.array(
      nested_record_type.child_at(0),
      [CrystalClick::BinaryValue.uint64(9_u64)] of CrystalClick::BinaryValue,
    )
    recursive_nested = CrystalClick::BinaryValue.nested(
      nested_descriptor,
      [CrystalClick::BinaryValue.tuple(
        nested_record_type,
        [nested_record_array] of CrystalClick::BinaryValue,
      )] of CrystalClick::BinaryValue,
    )
    document = CrystalClick::ObjectDocument.new({
      "x" => CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[3_u8]
      ),
    } of String => CrystalClick::BinaryValue)
    recursive_value = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document),
      CrystalClick::StorageColumnValue.bulk(recursive_nested),
    ] of CrystalClick::StorageColumnValue)

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      columns = [CrystalClick::WidePartColumn.recursive(
        "recursive_nested",
        schema,
        {"root/tuple[0]" => object_plan},
        [[recursive_value] of CrystalClick::StorageColumnValue],
      )]
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        w245_write(destination, columns, [1_u64], rows_per_mark: 1)
      end
      error.message.should eq("recursive Nested BinaryBulk requires its exact nominal Nested storage plan")
      w245_assert_no_publication(parent, destination)
    end
  end

  it "rejects sized recursive shared data before publication while global String profile remains independent" do
    columns = SchemaWidePartW245Fixture.columns(
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
    )
    recursive_column = [columns.last] of CrystalClick::WidePartColumn
    keys = SchemaWidePartW245Fixture::KEYS

    w245_with_parent do |parent|
      destination = File.join(parent, "part")
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          destination,
          SchemaWidePartW245Fixture::KEY_NAME,
          keys.to_unsafe.to_slice(keys.size),
          recursive_column,
          rows_per_mark: SchemaWidePartW245Fixture::ROWS_PER_MARK,
          profile: CrystalClick::BinaryBulkProfile.single_stream,
          shared_profile: CrystalClick::BinaryBulkProfile.with_size_stream,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
          frame_bytes: SchemaWidePartW245Fixture::FRAME_BYTES,
        )
      end
      error.message.should eq("recursive Object shared data requires the stock single-stream profile")
      w245_assert_no_publication(parent, destination)
    end
  end

  it "shares the read-validation decoded-byte budget across staged value columns and removes its stage on failure" do
    type = CrystalClick::BinaryDataType.primitive("UInt64")
    first = [
      [1_u64, 2_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
      [3_u64, 4_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
      [5_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
    ]
    second = [
      [11_u64, 12_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
      [13_u64, 14_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
      [15_u64].map { |value| CrystalClick::BinaryValue.uint64(value) },
    ]
    limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 120)
    keys = SchemaWidePartW245Fixture::KEYS

    w245_with_parent do |parent|
      destination = File.join(parent, "one-column")
      columns = [CrystalClick::WidePartColumn.binary_bulk("left", type, first)]
      w245_write(destination, columns, keys, transport_limits: limits).should eq(destination)
      File.exists?(destination).should be_true
    end

    w245_with_parent do |parent|
      destination = File.join(parent, "two-columns")
      columns = [
        CrystalClick::WidePartColumn.binary_bulk("left", type, first),
        CrystalClick::WidePartColumn.binary_bulk("right", type, second),
      ]
      expect_raises(CrystalClick::CorruptPartError) do
        w245_write(destination, columns, keys, transport_limits: limits)
      end
      w245_assert_no_publication(parent, destination)
    end
  end
end
