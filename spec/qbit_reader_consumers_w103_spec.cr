require "./spec_helper"

describe "QBit selected-range reader consumers" do
  it "reads exact raw QBit rows and selected marks without losing nominal type" do
    parent = File.tempname("crystal-click-qbit-reader")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    type = CrystalClick::QBitType.new("Float32", 2_u64)
    raw_rows = [
      Bytes[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      Bytes[0_u8, 0_u8, 128_u8, 63_u8, 0_u8, 0_u8, 0_u8, 128_u8],
      Bytes[1_u8, 0_u8, 192_u8, 127_u8, 0_u8, 0_u8, 0_u8, 127_u8],
    ]
    values = raw_rows.map { |raw| CrystalClick::QBitValue.new(type, raw) }
    keys = [1_u64, 3_u64, 5_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_qbit_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        type.type_name,
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("QBit(Float32, 2)")
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      expect_raises(CrystalClick::BoundsError) { reader.read_qbit_mark_range("payload", -1, 1) }
      expect_raises(CrystalClick::BoundsError) { reader.read_qbit_mark_range("payload", 0, 0) }
      expect_raises(CrystalClick::BoundsError) { reader.read_qbit_mark_range("payload", UInt64::MAX, 1_u64) }
      expect_raises(CrystalClick::BoundsError) { reader.read_qbit_mark_range("payload", 0_u64, UInt64::MAX) }
      full = reader.read_qbit_mark_range("payload", 0, 2)
      full.map(&.type.type_name).should eq(Array.new(3, "QBit(Float32, 2)"))
      full.map(&.raw_bytes).should eq(raw_rows)
      reader.read_qbit_mark_range("payload", 1, 1).map(&.raw_bytes).should eq([raw_rows[2]])

      table = CrystalClick::WidePartTable.open_selected_typed([destination], ["pk", "payload"])
      observed = [] of Bytes
      table.scan_typed(batch_rows: 2) do |batch|
        batch.qbits_for("payload").each do |value|
          value.type.type_name.should eq("QBit(Float32, 2)")
          observed << value.raw_bytes
        end
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.qbits_for("pk") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_qbits_for("payload") }
        nil
      end
      observed.should eq(raw_rows)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads Nullable(QBit) null rows and dense raw placeholders independently" do
    parent = File.tempname("crystal-click-qbit-nullable-reader")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    type = CrystalClick::QBitType.new("Int8", 8_u64)
    value = CrystalClick::QBitValue.new(type, Bytes[1_u8, 0_u8, 255_u8, 128_u8, 7_u8, 6_u8, 5_u8, 4_u8])
    values = [nil, value, nil] of CrystalClick::QBitValue?
    keys = [2_u64, 4_u64, 6_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_qbit_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        "Nullable(QBit(Int8, 8))",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      result = reader.read_nullable_qbit_mark_range("payload", 0, 2)
      result.size.should eq(3)
      result[0].should be_nil
      result[1].not_nil!.type.type_name.should eq("QBit(Int8, 8)")
      result[1].not_nil!.raw_bytes.should eq(value.raw_bytes)
      result[2].should be_nil
      dense = reader.read_qbit_dense_mark_range("payload", 0, 2)
      dense.map(&.raw_bytes).should eq([
        Bytes.new(8, 0_u8),
        value.raw_bytes,
        Bytes.new(8, 0_u8),
      ])
      table = CrystalClick::WidePartTable.open_selected_typed([destination], ["pk", "payload"])
      nullable_observed = [] of CrystalClick::QBitValue?
      table.scan_typed(batch_rows: 2) do |batch|
        selected = batch.nullable_qbits_for("payload")
        selected.each { |entry| nullable_observed << entry }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.qbits_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_qbits_for("pk") }
        nil
      end
      nullable_observed.map { |entry| entry.try(&.raw_bytes) }.should eq([nil, value.raw_bytes, nil] of Bytes?)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_qbit_mark_range("payload", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_qbit_mark_range("payload", 0, 2)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an under-budget range before opening any selected plane payload" do
    parent = File.tempname("crystal-click-qbit-budget-reader")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Int8", 8_u64)
    values = [
      CrystalClick::QBitValue.new(type, Bytes.new(8, 1_u8)),
      CrystalClick::QBitValue.new(type, Bytes.new(8, 2_u8)),
    ]
    keys = [1_u64, 2_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_qbit_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        type.type_name,
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )
      reader = CrystalClick::WidePart.open_typed(destination, "payload")

      first_plane = "payload%2E1"
      File.delete(File.join(destination, "#{CrystalClick::StreamName.hash(first_plane)}.bin"))
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_qbit_mark_range("payload", 0, 1, max_materialized_bytes: 1_u64)
      end
      error.message.not_nil!.should contain("limit")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects serializer metadata outside the exact bounded QBit profile" do
    parent = File.tempname("crystal-click-qbit-serialization-profile")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Int8", 8_u64)
    values = [CrystalClick::QBitValue.new(type, Bytes.new(8, 0_u8))]
    keys = [1_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_qbit_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        type.type_name,
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      File.write(
        File.join(destination, "serialization.json"),
        %({"columns":[{"name":"payload","kind":"Default","num_defaults":0,"num_rows":1}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(destination, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe "QBit stream validation and whole-column budget guards" do
  it "rejects missing physical streams and unequal QBit mark schedules before payload reads" do
    plan = CrystalClick::QBitColumnType.new(CrystalClick::QBitType.new("Int8", 17_u64))
    missing_plane = ->(name : String, _first : Int32, _count : Int32, _width : Int32?) : Tuple(UInt64, Bytes?) {
      raise CrystalClick::CorruptPartError.new("missing QBit plane") if name == "payload%2E8"
      {3_u64, nil}
    }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::QBitStreamValidator.selected_row_count(plan, "payload", 0, 1, missing_plane)
    end

    nullable_plan = CrystalClick::QBitColumnType.new(CrystalClick::QBitType.new("Int8", 8_u64), true)
    missing_null_map = ->(name : String, _first : Int32, _count : Int32, _width : Int32?) : Tuple(UInt64, Bytes?) {
      raise CrystalClick::CorruptPartError.new("missing QBit null map") if name == "payload.null"
      {3_u64, nil}
    }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::QBitStreamValidator.selected_row_count(nullable_plan, "payload", 0, 1, missing_null_map)
    end

    unequal_schedule = ->(name : String, _first : Int32, _count : Int32, _width : Int32?) : Tuple(UInt64, Bytes?) {
      {name == "payload.null" ? 3_u64 : 2_u64, nil}
    }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::QBitStreamValidator.selected_row_count(nullable_plan, "payload", 0, 1, unequal_schedule)
    end
  end

  it "rejects null-map bytes outside zero and one" do
    CrystalClick::QBitStreamValidator.validate_null_map!(Bytes[0_u8, 1_u8]).should be_nil
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::QBitStreamValidator.validate_null_map!(Bytes[0_u8, 2_u8])
    end
  end

  it "charges whole-column OfflineColumnValue slots before materialization" do
    type = CrystalClick::QBitType.new("Int8", 8_u64)
    plan = CrystalClick::QBitColumnType.new(type)
    rows = 4_u64
    actual = CrystalClick::QBitValuesMaterializer.checked_expected_charge(rows, plan)
    expected = type.type_name.bytesize.to_u64 + 64_u64 +
               rows * (sizeof(CrystalClick::OfflineColumnValue).to_u64 + type.raw_row_bytes.to_u64)
    actual.should eq(expected)

    large_plan = CrystalClick::QBitColumnType.new(CrystalClick::QBitType.new("Int8", 65_536_u64))
    expect_raises(CrystalClick::BoundsError) do
      CrystalClick::QBitValuesMaterializer.checked_expected_charge(2_048_u64, large_plan)
    end
  end
end
