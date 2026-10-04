require "./spec_helper"

private alias W150ArrayOfStringMaps = Array(Array(Tuple(String, UInt64)))

describe "W150 WidePartWriter metadata owner" do
  it "pins literal String and Nullable metadata" do
    parent = File.tempname("crystal-click-w150-basic-metadata")
    Dir.mkdir(parent)
    string_part = File.join(parent, "string")
    nullable_part = File.join(parent, "nullable")
    keys = [1_u64, 2_u64]
    strings = ["x", ""]

    begin
      CrystalClick::WidePartWriter.write_uint64_string_pair(
        string_part, "pk", keys.to_unsafe.to_slice(keys.size),
        "payload", strings.to_unsafe.to_slice(strings.size), rows_per_mark: 1
      )
      File.read(File.join(string_part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` String\n"
      )
      File.read(File.join(string_part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "2 substreams for column `payload`:\n\tpayload.size\n\tpayload\n"
      )

      nullable = [nil, 9_u64] of UInt64?
      CrystalClick::WidePartWriter.write_uint64_nullable_uint64_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size),
        "payload", nullable.to_unsafe.to_slice(nullable.size), rows_per_mark: 1
      )
      File.read(File.join(nullable_part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Nullable(UInt64)\n"
      )
      File.read(File.join(nullable_part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
      )
      File.read(File.join(nullable_part, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "pins the Tuple default census and nested subcolumn JSON order" do
    parent = File.tempname("crystal-click-w150-tuple-metadata")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 3_u64, 8_u64]
    values = [{0_u64, ""}, {7_u64, "x"}, {0_u64, ""}]

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size),
        "payload", values, rows_per_mark: 2
      )
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Tuple(a UInt64, b String)\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[{"kind":"Default","name":"pk","num_defaults":1,"num_rows":3},{"kind":"Default","name":"payload","num_defaults":2,"num_rows":3,"subcolumns":[{"kind":"Default","num_defaults":2,"num_rows":3},{"kind":"Default","num_defaults":2,"num_rows":3}]}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "3 substreams for column `payload`:\n\tpayload%2Ea\n\tpayload%2Eb.size\n\tpayload%2Eb\n"
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "pins canonical JSON typed-path ordering independently of the reader" do
    parent = File.tempname("crystal-click-w150-json-order")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    paths = [
      CrystalClick::WidePartWriter::JSONTypedPathColumn.new("z", "String", ["tail", ""]),
      CrystalClick::WidePartWriter::JSONTypedPathColumn.new("a", "Int16", [-4_i16, 7_i16]),
      CrystalClick::WidePartWriter::JSONTypedPathColumn.new("m", "Float32", [2_f32, -1_f32]),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_paths(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "j", paths, rows_per_mark: 1
      )
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`j` JSON(a Int16, m Float32, z String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "8 substreams for column `j`:\n\tj.object_structure\n\tj.a\n\tj.m\n\tj.z.size\n\tj.z\n" +
        "\tj.object_shared_data.0.size0\n\tj.object_shared_data.0%2Epaths\n\tj.object_shared_data.0%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":2}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      structure_path = File.join(destination, "#{CrystalClick::StreamName.hash("j.object_structure")}.bin")
      CrystalClick::CompressedBlock.decode_all(File.read(structure_path).to_slice).to_a.should eq([
        0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 0_u8,
      ])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "pins Variant and Dynamic empty-arm rosters and serializer versions" do
    parent = File.tempname("crystal-click-w150-variant-metadata")
    Dir.mkdir(parent)
    variant_part = File.join(parent, "variant")
    dynamic_part = File.join(parent, "dynamic")
    keys = [1_u64, 2_u64]
    strings_only = ["a", ""] of CrystalClick::VariantStringUInt64Value
    dynamic_values = ["a", 7_u64] of CrystalClick::VariantStringUInt64Value

    begin
      CrystalClick::WidePartWriter.write_uint64_variant_string_uint64_pair(
        variant_part, "pk", keys.to_unsafe.to_slice(keys.size),
        "payload", strings_only.to_unsafe.to_slice(strings_only.size), rows_per_mark: 1
      )
      File.read(File.join(variant_part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Variant(String, UInt64)\n"
      )
      File.read(File.join(variant_part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "4 substreams for column `payload`:\n\tpayload.variant_discr\n\tpayload.String.size\n\tpayload.String\n\tpayload.UInt64\n"
      )
      File.read(File.join(variant_part, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.size(File.join(variant_part, "#{CrystalClick::StreamName.hash("payload.UInt64")}.bin")).should eq(0_i64)

      CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
        dynamic_part, "pk", keys.to_unsafe.to_slice(keys.size),
        "payload", dynamic_values.to_unsafe.to_slice(dynamic_values.size), rows_per_mark: 1
      )
      File.read(File.join(dynamic_part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Dynamic\n"
      )
      File.read(File.join(dynamic_part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "7 substreams for column `payload`:\n\tpayload.dynamic_structure\n\tpayload.variant_discr\n" +
        "\tpayload.SharedVariant.size\n\tpayload.SharedVariant\n\tpayload.String.size\n" +
        "\tpayload.String\n\tpayload.UInt64\n"
      )
      File.read(File.join(dynamic_part, "serialization.json")).should eq(
        %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":2}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      {"payload.SharedVariant.size", "payload.SharedVariant"}.each do |stream|
        File.size(File.join(dynamic_part, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "pins the plan-backed nested Array(Map(String, UInt64)) roster" do
    parent = File.tempname("crystal-click-w150-array-map-metadata")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    values = [[[{"k", 9_u64}] of Tuple(String, UInt64)]] of W150ArrayOfStringMaps

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size),
        "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
      )
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Map(String, UInt64))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "5 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n" +
        "\tpayload%2Ekeys.size\n\tpayload%2Ekeys\n\tpayload%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
