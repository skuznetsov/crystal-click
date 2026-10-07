require "./spec_helper"

private def w200_public_qbit_profiles : Array(Tuple(String, String, Int64, Int64, Bool, Int64, Int32))
  profiles = [] of Tuple(String, String, Int64, Int64, Bool, Int64, Int32)
  carriers = ["Int8", "BFloat16", "Float32", "Float64"]
  shapes = [
    {"dim3", 3_i64, 3_i64, false},
    {"dim9", 9_i64, 9_i64, false},
    {"stride16_8", 16_i64, 8_i64, true},
  ]
  carriers.each do |carrier|
    shapes.each do |shape|
      {2_i64, 3_i64}.each do |shared_version|
        {0, 1}.each do |string_profile|
          id = "#{carrier.downcase}_#{shape[0]}_v#{shared_version}_s#{string_profile}"
          profiles << {id, carrier, shape[1], shape[2], shape[3], shared_version, string_profile}
        end
      end
    end
  end
  profiles
end

private def w200_public_qbit_type(profile : Tuple(String, String, Int64, Int64, Bool, Int64, Int32)) : CrystalClick::QBitType
  carrier = profile[1]
  dimension = profile[2].to_u64
  if profile[4]
    CrystalClick::QBitType.new(carrier, dimension, profile[3].to_u64)
  else
    CrystalClick::QBitType.new(carrier, dimension)
  end
end

private def w200_public_qbit_raw(
  profile : Tuple(String, String, Int64, Int64, Bool, Int64, Int32),
  row : Int32,
) : Bytes
  carrier = profile[1]
  carrier_index = {"Int8" => 0, "BFloat16" => 1, "Float32" => 2, "Float64" => 3}[carrier]
  prefixes = case carrier
             when "Int8"
               [Bytes[0xff_u8, 0x00_u8, 0x80_u8], Bytes[0x00_u8, 0x80_u8, 0xff_u8]]
             when "BFloat16"
               [Bytes[0x00_u8, 0x80_u8, 0xc1_u8, 0x7f_u8, 0xc2_u8, 0x7f_u8], Bytes[0xc1_u8, 0x7f_u8, 0xc2_u8, 0x7f_u8, 0x00_u8, 0x80_u8]]
             when "Float32"
               [
                 Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x01_u8, 0x00_u8, 0xc0_u8, 0x7f_u8, 0x02_u8, 0x00_u8, 0xc0_u8, 0x7f_u8],
                 Bytes[0x01_u8, 0x00_u8, 0xc0_u8, 0x7f_u8, 0x02_u8, 0x00_u8, 0xc0_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8],
               ]
             when "Float64"
               [
                 Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf8_u8, 0x7f_u8, 0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf8_u8, 0x7f_u8],
                 Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf8_u8, 0x7f_u8, 0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf8_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8],
               ]
             else
               raise ArgumentError.new("unknown W200 QBit carrier")
             end
  widths = {"Int8" => 1, "BFloat16" => 2, "Float32" => 4, "Float64" => 8}
  dimension = profile[2].to_i
  width = widths[carrier]
  prefix = prefixes[row]
  Bytes.new(dimension * width) do |index|
    if index < prefix.size
      prefix[index]
    else
      ((row.to_i64 * 67_i64 + index.to_i64 * 31_i64 + carrier_index.to_i64 * 19_i64 + dimension * 11_i64 + profile[3] * 7_i64) & 0xff_i64).to_u8
    end
  end
end

private def w200_public_qbit_value(
  type : CrystalClick::QBitType,
  raw : Bytes,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w200_public_qbit_document(value : CrystalClick::BinaryValue? = nil) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new
  fields["q"] = value if value
  CrystalClick::ObjectDocument.new(fields)
end

private def w200_public_qbit_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {} of String => CrystalClick::BinaryDataType,
    max_dynamic_types: 1,
    max_dynamic_paths: 0,
  )
end

private def w200_public_qbit_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  type : CrystalClick::QBitType,
  shared_version : Int64,
) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_version.to_u64,
    bucket_count: 2_u64,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
end

private def w200_public_qbit_profile(value : Int32) : CrystalClick::BinaryBulkProfile
  case value
  when 0 then CrystalClick::BinaryBulkProfile.single_stream
  when 1 then CrystalClick::BinaryBulkProfile.with_size_stream
  else        raise ArgumentError.new("W200 String profile must be 0 or 1")
  end
end

private def w200_public_qbit_assert_row(
  document : CrystalClick::ObjectDocument,
  type : CrystalClick::QBitType,
  raw : Bytes?,
) : Nil
  if expected = raw
    document.has_path?("q").should be_true
    actual = document.value_for("q")
    actual.type.should eq(CrystalClick::BinaryDataType.qbit(type))
    actual.type.name.should eq(type.type_name)
    actual.qbit_value.type.should eq(type)
    actual.qbit_value.raw_bytes.should eq(expected)
  else
    document.has_path?("q").should be_false
  end
end

private def with_w200_public_qbit_part(label : String, & : String ->)
  parent = File.tempname("crystal-click-w200-qbit-#{label}-")
  created = false
  Dir.mkdir(parent)
  created = true
  yield parent
ensure
  FileUtils.rm_rf(parent) if created && parent && Dir.exists?(parent)
end

describe "W200 complete-part QBit Object paths" do
  it "writes and reads the fixed 48-profile matrix through the public complete-part API" do
    schema = w200_public_qbit_schema
    profiles = w200_public_qbit_profiles
    profiles.size.should eq(48)
    profiles.map { |profile| profile[0] }.uniq.size.should eq(48)

    profiles.each do |profile|
      id, _carrier, _dimension, _stride, _explicit_stride, shared_version, string_profile = profile
      type = w200_public_qbit_type(profile)
      type.type_name.should eq(
        profile[4] ? "QBit(#{profile[1]}, #{profile[2]}, #{profile[3]})" : "QBit(#{profile[1]}, #{profile[2]})"
      )
      raw_a = w200_public_qbit_raw(profile, 0)
      raw_zero = Bytes.new(type.raw_row_bytes, 0_u8)
      raw_b = w200_public_qbit_raw(profile, 1)
      rows = [
        w200_public_qbit_document(w200_public_qbit_value(type, raw_a)),
        w200_public_qbit_document,
        w200_public_qbit_document(w200_public_qbit_value(type, raw_zero)),
        w200_public_qbit_document(w200_public_qbit_value(type, raw_b)),
      ] of CrystalClick::ObjectDocument
      granules = [
        [rows[0], rows[1]] of CrystalClick::ObjectDocument,
        [rows[2], rows[3]] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument)

      with_w200_public_qbit_part(id) do |parent|
        part = File.join(parent, "all_1_1_0")
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          part,
          "pk",
          Slice[1_u64, 2_u64, 3_u64, 4_u64],
          "j",
          schema,
          w200_public_qbit_plan(schema, type, shared_version),
          granules,
          rows_per_mark: 2,
          profile: w200_public_qbit_profile(string_profile),
        ).should eq(part)

        reader = CrystalClick::ObjectColumnReader.open(part, "j", schema)
        reader.row_count.should eq(4_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64])
        reader.ordinary_profile.should eq(w200_public_qbit_profile(string_profile))
        reader.source_declaration.should eq(schema.declaration)

        descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
          part,
          "j",
          schema.typed_paths,
          reader.ordinary_profile,
          CrystalClick::BinaryBulkProfile.single_stream,
          true,
        )
        descriptor.plan.structures.object.shared_data_version.should eq(shared_version.to_u64)
        descriptor.plan.structures.object.bucket_count.should eq(2_u64)

        full = reader.read_marks(0, 2)
        full.size.should eq(2)
        full[0].size.should eq(2)
        full[1].size.should eq(2)
        w200_public_qbit_assert_row(full[0][0], type, raw_a)
        w200_public_qbit_assert_row(full[0][1], type, nil)
        w200_public_qbit_assert_row(full[1][0], type, raw_zero)
        w200_public_qbit_assert_row(full[1][1], type, raw_b)

        middle = reader.read_marks(1, 1)
        middle.size.should eq(1)
        middle[0].size.should eq(2)
        w200_public_qbit_assert_row(middle[0][0], type, raw_zero)
        w200_public_qbit_assert_row(middle[0][1], type, raw_b)

        reader.read_marks(2, 0).should be_empty
      end
    end
  end
end
