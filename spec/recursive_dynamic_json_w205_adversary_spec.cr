require "./spec_helper"
require "file_utils"

private def w205a_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), " +
    "d Dynamic(max_types=1)))",
    limits,
  )
end

private def w205a_object_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)", limits
  )
end

private def w205a_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w205a_dynamic_plan(
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::BinaryDynamicBulkPlan
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String")
  )
  CrystalClick::BinaryDynamicBulkPlan.new(
    dynamic,
    {"root" => CrystalClick::DynamicStructure.new(
      [low_cardinality_string] of CrystalClick::BinaryDataType
    )},
    profile,
    limits: limits,
  )
end

private def w205a_dynamic_plans(
  plan : CrystalClick::BinaryDynamicBulkPlan,
) : Hash(String, CrystalClick::BinaryDynamicBulkPlan)
  {"root/array[0]/tuple[1]" => plan}
end

private def w205a_empty_granules : Array(Array(CrystalClick::StorageColumnValue))
  empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
  Array(Array(CrystalClick::StorageColumnValue)).new(4) do
    [empty, empty] of CrystalClick::StorageColumnValue
  end
end

private def w205a_with_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w205a-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w205a_write_varuint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

private def w205a_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  hash.each do |word|
    8.times { |byte| io.write_byte(((word >> (byte * 8)) & 0xff_u64).to_u8) }
  end
end

private def w205a_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w205a_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w205a_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w205a_write_varuint(payload, bytes.size.to_u64)
    w205a_write_hash(payload, CrystalClick::CityHashV1.file_hash(bytes))
    payload.write_byte(entry.compressed ? 1_u8 : 0_u8)
    if entry.compressed
      raw = bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(bytes)
      w205a_write_varuint(payload, raw.size.to_u64)
      w205a_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(CrystalClick::CompressedMarkWriter.encode_all(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w205a_replace_pair(part : String, logical_name : String, files : CrystalClick::CompressedMarkFiles) : Nil
  hashed = CrystalClick::StreamName.hash(logical_name)
  File.write(File.join(part, "#{hashed}.bin"), files.data)
  File.write(File.join(part, "#{hashed}.mrk2"), files.marks)
  w205a_refresh_checksums(part)
end

private def w205a_write_zero_site_part(part : String) : CrystalClick::RecursiveStorageColumnPlan
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  schema = w205a_schema(limits)
  object_schema = w205a_object_schema(limits)
  objects = {"root/array[0]/tuple[0]" => w205a_object_plan(object_schema)}
  dynamic_plans = w205a_dynamic_plans(w205a_dynamic_plan(limits: limits))
  plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
    "payload", schema, objects, hashed: true, dynamic_plans: dynamic_plans
  )
  CrystalClick::WidePartWriter.write_uint64_recursive_pair(
    part,
    "pk",
    Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
    "payload",
    schema,
    objects,
    w205a_empty_granules,
    rows_per_mark: 2,
    limits: limits,
    dynamic_plans: dynamic_plans,
  )
  plan
end

describe "W205 zero-occurrence LC roster adversaries" do
  it "rejects a prepared LC plan from another Dynamic String profile before publication" do
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    schema = w205a_schema(limits)
    object_schema = w205a_object_schema(limits)
    objects = {"root/array[0]/tuple[0]" => w205a_object_plan(object_schema)}
    wrong_profile = w205a_dynamic_plan(
      CrystalClick::BinaryBulkProfile.with_size_stream, limits
    )
    dynamic_plans = w205a_dynamic_plans(wrong_profile)

    error = expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", schema, objects, dynamic_plans: dynamic_plans
      )
    end
    error.message.should eq("recursive Dynamic prepared plan differs from its declared type or profile")

    w205a_with_parent("wrong-profile-no-publish") do |parent|
      destination = File.join(parent, "part")
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          destination,
          "pk",
          Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
          "payload",
          schema,
          objects,
          w205a_empty_granules,
          rows_per_mark: 2,
          profile: CrystalClick::BinaryBulkProfile.single_stream,
          limits: limits,
          dynamic_plans: dynamic_plans,
        )
      end
      error.message.should eq("recursive Dynamic prepared plan differs from its declared type or profile")
      Dir.children(parent).should be_empty
    end
  end

  it "does not invoke a public table callback when the unused Dynamic structure lane is absent" do
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    schema = w205a_schema(limits)
    object_schema = w205a_object_schema(limits)
    objects = {"root/array[0]/tuple[0]" => w205a_object_plan(object_schema)}
    dynamic_plans = w205a_dynamic_plans(w205a_dynamic_plan(limits: limits))
    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, objects, hashed: true, dynamic_plans: dynamic_plans
    )

    w205a_with_parent("missing-unused-structure") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
        "payload",
        schema,
        objects,
        w205a_empty_granules,
        rows_per_mark: 2,
        limits: limits,
        dynamic_plans: dynamic_plans,
      )

      logical_name = plan.dynamic_site_at(0).physical.structure_name_for("root")
      data_file = plan.file_roster[logical_name][0]
      File.file?(File.join(part, data_file)).should be_true
      File.delete(File.join(part, data_file))

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0, 1, 2, 3]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects a checksum-valid Array size lane that invents children in an all-zero-Q part before a table callback" do
    w205a_with_parent("invented-zero-q-child") do |parent|
      part = File.join(parent, "all_1_1_0")
      plan = w205a_write_zero_site_part(part)
      array_site = plan.array_site_at(0)
      size_file = "#{CrystalClick::StreamName.hash(array_site.size_name)}.bin"
      source = CrystalClick::PartStreamSource.new(part)
      raw = source.read_all(size_file).dup
      raw.size.should eq(8 * 8)
      raw[0] = 1_u8 # little-endian UInt64(1) instead of the first zero length.

      # Keep the complete P mark grid unchanged. Only one parent Array count
      # now implies a Dynamic child Q occurrence. The Dynamic plan has an
      # unused LowCardinality(String) actual arm, so its schedule census must
      # read one discriminator byte for that child, but the logical
      # discriminator lane was encoded for Q=0 and has none.
      files = CrystalClick::CompressedMarkWriter.encode(
        raw,
        [0_u64, 16_u64, 32_u64, 48_u64, 64_u64],
        [2_u64, 2_u64, 2_u64, 2_u64],
      )
      w205a_replace_pair(part, array_site.size_name, files)

      checksums = CrystalClick::PartChecksums.open(part)
      marks_file = "#{CrystalClick::StreamName.hash(array_site.size_name)}.mrk2"
      {size_file, marks_file}.each do |name|
        entry = checksums.entry(name) || raise("resealed checksum entry is missing")
        bytes = File.read(File.join(part, name)).to_slice
        entry.physical_size.should eq(bytes.size.to_u64)
        entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(bytes))
      end

      # Reopen after resealing the part so this is a semantic schedule
      # contradiction, not a stale checksum or file-size rejection. The
      # checksum manifest now agrees with both changed physical files; the
      # stream source itself independently checks declared file sizes only.
      resealed = CrystalClick::PartStreamSource.new(part)
      resealed.read_all(size_file).should eq(raw)
      resealed.inspect_grid(
        size_file,
        "#{CrystalClick::StreamName.hash(array_site.size_name)}.mrk2",
        0,
      ).rows_per_mark.should eq([2_u64, 2_u64, 2_u64, 2_u64])

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0, 1, 2, 3]]) { |_batch| callbacks += 1 }
      end
      # This is the earliest guard: Dynamic LC occurrence census checks the
      # discriminator lane's minimum byte count before ordinary value decode.
      error.message.should eq("binary codec input is too short for declared metadata count")
      callbacks.should eq(0)
    end
  end
end
