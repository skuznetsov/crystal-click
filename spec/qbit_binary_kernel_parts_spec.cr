require "./spec_helper"
require "json"

private W179_QBIT_CARRIERS = [
  {"Int8", 1},
  {"BFloat16", 2},
  {"Float32", 4},
  {"Float64", 8},
]

private W179_QBIT_SHAPES = [
  {"dim3", 3_u64, nil.as(UInt64?)},
  {"dim9", 9_u64, nil.as(UInt64?)},
  {"stride16-8", 16_u64, 8_u64.as(UInt64?)},
]

private def w179_qbit_type(element : String, dimension : UInt64, stride : UInt64?) : CrystalClick::QBitType
  CrystalClick::QBitType.new(element, dimension, stride)
end

private def w179_qbit_profile_id(element : String, shape : String, nullable : Bool) : String
  id = "#{element.downcase}-#{shape}"
  nullable ? "#{id}-nullable" : id
end

# First three elements are direct little-endian literals: Int8 -1/0/-128,
# BFloat16 and IEEE float negative zero plus two distinct quiet-NaN payloads.
# No QBit scalar or plane codec participates in this fixture oracle.
private def w179_qbit_pattern(element : String, row_index : Int32) : Bytes
  patterns = case element
             when "Int8"
               [
                 Bytes[0xff_u8, 0x00, 0x80],
                 Bytes[0x00_u8, 0x80, 0xff],
                 Bytes[0x80_u8, 0xff, 0x00],
               ]
             when "BFloat16"
               [
                 Bytes[0x00_u8, 0x80, 0xc1, 0x7f, 0xc2, 0x7f],
                 Bytes[0xc1_u8, 0x7f, 0xc2, 0x7f, 0x00, 0x80],
                 Bytes[0xc2_u8, 0x7f, 0x00, 0x80, 0xc1, 0x7f],
               ]
             when "Float32"
               [
                 Bytes[0x00_u8, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f],
                 Bytes[0x01_u8, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80],
                 Bytes[0x02_u8, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f],
               ]
             when "Float64"
               [
                 Bytes[0x00_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
                   0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
                   0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f],
                 Bytes[0x01_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
                   0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
                   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80],
                 Bytes[0x02_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
                   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
                   0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f],
               ]
             else
               raise "unknown W179 QBit carrier"
             end
  patterns[row_index % 3]
end

# Remaining elements are deterministic filler. The Ruby native runner has an
# independently implemented copy of this rule and the literal prefixes above.
private def w179_qbit_raw(type : CrystalClick::QBitType, carrier_index : Int32, row_index : Int32) : Bytes
  first_three = w179_qbit_pattern(type.element_type, row_index)
  Bytes.new(type.raw_row_bytes) do |index|
    if index // type.element_width < 3
      first_three[index]
    else
      ((row_index * 67 + index * 31 + carrier_index * 19 + type.dimension.to_i * 11 + type.stride.to_i * 7) & 0xff).to_u8
    end
  end
end

private def w179_qbit_binary_value(type : CrystalClick::QBitType, raw : Bytes) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w179_qbit_profiles : Array(NamedTuple(id: String, element: String, shape: String, dimension: UInt64, stride: UInt64?, nullable: Bool, type: String))
  profiles = [] of NamedTuple(id: String, element: String, shape: String, dimension: UInt64, stride: UInt64?, nullable: Bool, type: String)
  W179_QBIT_CARRIERS.each do |(element, _width)|
    W179_QBIT_SHAPES.each do |(shape, dimension, stride)|
      [false, true].each do |nullable|
        value_type = w179_qbit_type(element, dimension, stride)
        type_name = nullable ? "Nullable(#{value_type.type_name})" : value_type.type_name
        profiles << {
          id: w179_qbit_profile_id(element, shape, nullable), element: element, shape: shape,
          dimension: dimension, stride: stride, nullable: nullable, type: type_name,
        }
      end
    end
  end
  profiles
end

private def w179_qbit_manifest_json(profiles : Array(NamedTuple(id: String, element: String, shape: String, dimension: UInt64, stride: UInt64?, nullable: Bool, type: String))) : String
  entries = profiles.map do |profile|
    %({"id":"#{profile[:id]}","type":"#{profile[:type]}","nullable":#{profile[:nullable]},"rows":3,"part":"#{profile[:id]}/all_1_1_0"})
  end
  %({"version":1,"profiles":[#{entries.join(",")}]})
end

private def w179_library_fixture_root : String?
  return nil unless root = ENV["W179_LIBRARY_PART_ROOT"]?
  raise "W179_LIBRARY_PART_ROOT must not be a symbolic link" if File.symlink?(root)
  raise "W179_LIBRARY_PART_ROOT must be an existing directory" unless Dir.exists?(root)
  raise "W179_LIBRARY_PART_ROOT must be empty before export" unless Dir.children(root).empty?
  root
end

private def w179_write_qbit_part(
  destination : String,
  profile : NamedTuple(id: String, element: String, shape: String, dimension: UInt64, stride: UInt64?, nullable: Bool, type: String),
  carrier_index : Int32,
) : Nil
  value_type = w179_qbit_type(profile[:element], profile[:dimension], profile[:stride])
  keys = [11_u64, 22_u64, 33_u64]
  if profile[:nullable]
    values = [
      CrystalClick::QBitValue.new(value_type, w179_qbit_raw(value_type, carrier_index, 0)),
      nil,
      CrystalClick::QBitValue.new(value_type, w179_qbit_raw(value_type, carrier_index, 2)),
    ] of CrystalClick::QBitValue?
    CrystalClick::WidePartWriter.write_uint64_nullable_qbit_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", profile[:type],
      values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
  else
    values = [
      CrystalClick::QBitValue.new(value_type, w179_qbit_raw(value_type, carrier_index, 0)),
      CrystalClick::QBitValue.new(value_type, w179_qbit_raw(value_type, carrier_index, 1)),
      CrystalClick::QBitValue.new(value_type, w179_qbit_raw(value_type, carrier_index, 2)),
    ]
    CrystalClick::WidePartWriter.write_uint64_qbit_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", profile[:type],
      values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
  end
  nil
end

private def w179_offline_qbit_table(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "b93dd646-a665-4a2b-a64a-79f3c1c52e1a"
  table_uuid = "3bc828c7-0995-4538-8d7c-3d848767f72a"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` QBit(Float32, 9)\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
end

describe "W179 QBit normalized bulk kernel and physical roles" do
  it "round-trips the bounded carrier/shape/nullability matrix through all, nonzero and empty mark windows" do
    W179_QBIT_CARRIERS.each_with_index do |(element, _width), carrier_index|
      W179_QBIT_SHAPES.each do |(_shape, dimension, stride)|
        qbit_type = w179_qbit_type(element, dimension, stride)
        qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
        [false, true].each do |nullable|
          descriptor = nullable ? CrystalClick::BinaryDataType.nullable(qbit_descriptor) : qbit_descriptor
          profile_name = nullable ? "Nullable(#{qbit_type.type_name})" : qbit_type.type_name
          raws = [0, 1, 2].map { |row| w179_qbit_raw(qbit_type, carrier_index, row) }
          qbit_values = raws.map { |raw| w179_qbit_binary_value(qbit_type, raw) }
          values = if nullable
                     [
                       CrystalClick::BinaryValue.nullable(descriptor, qbit_values[0]),
                       CrystalClick::BinaryValue.nullable(descriptor),
                       CrystalClick::BinaryValue.nullable(descriptor, qbit_values[2]),
                     ]
                   else
                     qbit_values
                   end

          encoded = CrystalClick::BinaryBulkCodec.encode(descriptor, [values[0..1], values[2..2]])
          plan = CrystalClick::BinaryBulkPhysicalPlan.new(descriptor, "payload")
          plane_roles = CrystalClick::BinaryBulkTypePlan.new(descriptor, CrystalClick::BinaryBulkProfile.single_stream).qbit_plane_roles
          expected_plane_prefix = nullable ? "root.nested.qbit_plane." : "root.qbit_plane."
          plane_roles.not_nil!.should eq((0...qbit_type.plane_count).map { |plane| "#{expected_plane_prefix}#{plane}" })
          encoded.mark_count.should eq(2)
          encoded.roles.size.should eq(qbit_type.plane_count + (nullable ? 1 : 0))
          qbit_type.plane_count.times do |plane|
            role = "#{expected_plane_prefix}#{plane}"
            expected_name = "payload%2E#{plane + 1}"
            plan.stream_name_for(role).should eq(expected_name)
            plane_bytes = encoded.stream(role).bytes
            if nullable
              # The middle row is NULL and every hidden child-plane lane uses
              # its canonical all-zero default instead of stale raw bits.
              (0...qbit_type.plane_width).each do |lane|
                plane_bytes[qbit_type.plane_width + lane].should eq(0_u8)
              end
            end
            if dimension == 9_u64
              # Element eight occupies the low bit of the first byte in each
              # two-byte plane row; the other seven bits stay zero.
              first_byte_of_last_row = 2 * qbit_type.plane_width
              (plane_bytes[first_byte_of_last_row] & 0xfe_u8).should eq(0_u8)
            end
          end
          if nullable
            plan.stream_name_for("root.nulls").should eq("payload.null")
            encoded.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8, 0_u8])
          end

          decoded = CrystalClick::BinaryBulkCodec.decode(descriptor, encoded, [2_u64, 1_u64])
          decoded.should eq([values[0..1], values[2..2]])
          selected = CrystalClick::BinaryBulkCodec.decode(
            descriptor, encoded, [2_u64, 1_u64], first_mark: 1, mark_count: 1
          )
          selected.should eq([values[2..2]])
          empty = CrystalClick::BinaryBulkCodec.decode(
            descriptor, encoded, [2_u64, 1_u64], first_mark: 2, mark_count: 0
          )
          empty.should be_empty
          decoded.flatten.each do |value|
            value.type.name.should eq(profile_name)
          end
        end
      end
    end
  end

  it "refuses equal physical plane shapes when nominal element or dimension differs" do
    float32 = CrystalClick::QBitType.new("Float32", 32_u64, 8_u64)
    float64 = CrystalClick::QBitType.new("Float64", 16_u64, 8_u64)
    left_type = CrystalClick::BinaryDataType.qbit(float32)
    right_type = CrystalClick::BinaryDataType.qbit(float64)
    left_plan = CrystalClick::BinaryBulkPhysicalPlan.new(left_type, "payload")
    right_plan = CrystalClick::BinaryBulkPhysicalPlan.new(right_type, "payload")
    left_plan.stream_names.should eq(right_plan.stream_names)
    float64_value = CrystalClick::BinaryValue.qbit(
      CrystalClick::QBitValue.new(float64, Bytes.new(float64.raw_row_bytes, 0x5a_u8))
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(left_type, [[float64_value]])
    end
    parent = File.tempname("crystal-click-w179-nominal-reject")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_qbit_pair(
          destination, "pk", Slice[1_u64], "payload", left_type.name, Slice[float64_value.qbit_value]
        )
      end
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "bounds hidden plane grids, generated role names, and retained selected outputs before allocation" do
    hidden_grid = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 8192_u64, 8_u64))
    role_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 32, max_bytes: 64 * 1024 * 1024)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(hidden_grid, "payload", limits: role_limited)
    end

    ordinary = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    depth_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 0, max_nodes: 8, max_elements: 128, max_bytes: 1024)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(ordinary, "payload", limits: depth_limited)
    end
    node_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 1, max_elements: 128, max_bytes: 1024)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(ordinary, "payload", limits: node_limited)
    end

    name_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 128, max_bytes: 8)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(ordinary, "payload", limits: name_limited)
    end

    value_type = ordinary.qbit_type.not_nil!
    values = [
      w179_qbit_binary_value(value_type, Bytes[1_u8, 2_u8, 3_u8]),
      w179_qbit_binary_value(value_type, Bytes[4_u8, 5_u8, 6_u8]),
      w179_qbit_binary_value(value_type, Bytes[7_u8, 8_u8, 9_u8]),
    ]
    encoded = CrystalClick::BinaryBulkCodec.encode(ordinary, [values])
    materialization_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1_000_000, max_elements: 1_000_000, max_bytes: 500)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(ordinary, encoded, [3_u64], limits: materialization_limited)
    end
  end
end

describe "W179 QBit part/table/offline adapters and stock fixtures" do
  it "exports exact 24-profile library parts under the explicit empty-root boundary" do
    profiles = w179_qbit_profiles
    profiles.size.should eq(24)
    if root = w179_library_fixture_root
      profiles.each_with_index do |profile, index|
        profile_root = File.join(root, profile[:id])
        FileUtils.mkdir_p(profile_root)
        w179_write_qbit_part(File.join(profile_root, "all_1_1_0"), profile, index // 6)
      end
      File.write(File.join(root, "manifest.json"), w179_qbit_manifest_json(profiles))
      parsed = JSON.parse(File.read(File.join(root, "manifest.json"))).as_h
      parsed["profiles"].as_a.size.should eq(24)
    end
  end

  it "bridges BinaryValue through the dedicated writer, reader, table and OfflineTable windows" do
    parent = File.tempname("crystal-click-w179-qbit-adapters")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    type = CrystalClick::QBitType.new("Float32", 9_u64)
    raws = [0, 1, 2].map { |row| w179_qbit_raw(type, 2, row) }
    binary_values = raws.map { |raw| w179_qbit_binary_value(type, raw) }
    bridged_values = binary_values.map(&.qbit_value)
    keys = [11_u64, 22_u64, 33_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_qbit_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
        bridged_values.to_unsafe.to_slice(bridged_values.size), rows_per_mark: 2
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_qbit_mark_range("payload", 0, reader.mark_row_counts.size).map(&.raw_bytes).should eq(raws)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      selected_rows = [] of Bytes
      table.scan_typed_window(1_u64, 1) do |batch|
        batch.qbits_for("payload").each { |value| selected_rows << value.raw_bytes }
      end
      selected_rows.should eq([raws[1]])
      empty_callbacks = 0
      table.scan_typed_window(3_u64, 1) { |_batch| empty_callbacks += 1 }
      empty_callbacks.should eq(0)

      offline_root = File.join(parent, "offline")
      offline = w179_offline_qbit_table(offline_root, part)
      offline_rows = [] of Bytes
      offline.scan_typed(["payload"], batch_rows: 2) do |batch|
        batch.qbits_for("payload").each { |value| offline_rows << value.raw_bytes }
      end
      offline_rows.should eq(raws)
      offline_window = [] of Bytes
      offline.scan_typed_window(["payload"], 1_u64, 1) do |batch|
        batch.qbits_for("payload").each { |value| offline_window << value.raw_bytes }
      end
      offline_window.should eq([raws[1]])
      offline_empty_callbacks = 0
      offline.scan_typed_window(["payload"], 3_u64, 1) { |_batch| offline_empty_callbacks += 1 }
      offline_empty_callbacks.should eq(0)

      read_back = reader.read_qbit_mark_range("payload", 0, reader.mark_row_counts.size).map do |value|
        CrystalClick::BinaryValue.qbit(value)
      end
      read_back.should eq(binary_values)
      read_back.each { |value| value.type.should eq(binary_values.first.type) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  if stock_root = ENV["W179_STOCK_ROOT"]?
    it "consumes native-created parts for every nominal profile and verifies selected/empty table windows" do
      profiles = w179_qbit_profiles
      manifest_path = File.join(stock_root, "manifest.json")
      raise "W179_STOCK_ROOT manifest is missing" unless File.file?(manifest_path)
      manifest = JSON.parse(File.read(manifest_path)).as_h
      records = manifest["profiles"].as_a
      records.size.should eq(24)
      records.map { |entry| entry.as_h["id"].as_s }.sort.should eq(profiles.map { |profile| profile[:id] }.sort)

      profiles.each_with_index do |profile, profile_index|
        record = records.find { |entry| entry.as_h["id"].as_s == profile[:id] }.not_nil!.as_h
        record["type"].as_s.should eq(profile[:type])
        record["nullable"].as_bool.should eq(profile[:nullable])
        record["rows"].as_i.should eq(3)
        relative_part = "#{profile[:id]}/all_1_1_0"
        record["part"].as_s.should eq(relative_part)
        profile_root = File.join(stock_root, profile[:id])
        part = File.join(profile_root, "all_1_1_0")
        raise "stock fixture profile directory is a symlink" if File.symlink?(profile_root) || File.symlink?(part)
        raise "stock fixture part is missing" unless Dir.exists?(part)

        value_type = w179_qbit_type(profile[:element], profile[:dimension], profile[:stride])
        expected_raws = [0, 1, 2].map { |row| w179_qbit_raw(value_type, profile_index // 6, row) }
        native_planes_path = File.join(profile_root, "planes.rowbinary")
        raise "stock fixture native plane witness is missing" unless File.file?(native_planes_path)
        native_planes = File.read(native_planes_path).to_slice
        descriptor = CrystalClick::BinaryDataType.qbit(value_type)
        nullable_descriptor = CrystalClick::BinaryDataType.nullable(descriptor)
        qbit_values = expected_raws.map { |raw| w179_qbit_binary_value(value_type, raw) }
        bulk_values = if profile[:nullable]
                        [
                          CrystalClick::BinaryValue.nullable(nullable_descriptor, qbit_values[0]),
                          CrystalClick::BinaryValue.nullable(nullable_descriptor),
                          CrystalClick::BinaryValue.nullable(nullable_descriptor, qbit_values[2]),
                        ]
                      else
                        qbit_values
                      end
        generic = CrystalClick::BinaryBulkCodec.encode(
          profile[:nullable] ? nullable_descriptor : descriptor,
          [bulk_values[0..1], bulk_values[2..2]]
        )
        plane_prefix = profile[:nullable] ? "root.nested.qbit_plane." : "root.qbit_plane."
        generic_plane_rows = IO::Memory.new
        [0, 1, 2].each do |row|
          next if profile[:nullable] && row == 1
          value_type.plane_count.times do |plane|
            stream = generic.stream("#{plane_prefix}#{plane}").bytes
            value_type.plane_width.times do |lane|
              generic_plane_rows.write_byte(stream[row * value_type.plane_width + lane])
            end
          end
        end
        # Native FixedString subcolumns are an independent transposition
        # oracle for the generic encoder, not a second self-round-trip.
        generic_plane_rows.to_slice.should eq(native_planes)

        reader = CrystalClick::WidePart.open_typed(part, "payload")
        reader.column_type.should eq(profile[:type])
        if profile[:nullable]
          observed = reader.read_nullable_qbit_mark_range("payload", 0, reader.mark_row_counts.size)
          observed.map { |value| value.try(&.raw_bytes) }.should eq([expected_raws[0], nil, expected_raws[2]] of Bytes?)
          dense = reader.read_qbit_dense_mark_range("payload", 0, reader.mark_row_counts.size)
          dense.map(&.raw_bytes).should eq([expected_raws[0], Bytes.new(value_type.raw_row_bytes, 0_u8), expected_raws[2]])
        else
          reader.read_qbit_mark_range("payload", 0, reader.mark_row_counts.size).map(&.raw_bytes).should eq(expected_raws)
        end

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        window = [] of Bytes?
        table.scan_typed_window(1_u64, 1) do |batch|
          if profile[:nullable]
            batch.nullable_qbits_for("payload").each { |value| window << value.try(&.raw_bytes) }
          else
            batch.qbits_for("payload").each { |value| window << value.raw_bytes }
          end
        end
        expected_window = profile[:nullable] ? [nil] of Bytes? : [expected_raws[1]] of Bytes?
        window.should eq(expected_window)
        callbacks = 0
        table.scan_typed_window(3_u64, 1) { |_batch| callbacks += 1 }
        callbacks.should eq(0)
      end
    end
  end
end
