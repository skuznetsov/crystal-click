require "./spec_helper"

module CrystalClick::WidePartWriter
  # W112-only test seam. Production callers continue using the public writer;
  # this exposes the existing private stage hook for snapshot/hostile checks.
  def self.w112_test_write_with_hooks(
    destination : String,
    key_name : String,
    keys : Slice(UInt64),
    value_name : String,
    type_name : String,
    level_sizes : Array(Array(UInt64)),
    points : Array(WidePointValue),
    rows_per_mark : Int32,
    stage_factory : Proc(String, String),
    before_validation_hook : Proc(String, Nil),
  ) : String
    write_geo_array_pair_with_hooks(
      destination, key_name, keys, value_name, type_name, level_sizes, points,
      rows_per_mark, stage_factory, before_validation_hook
    )
  end

  def self.w112_stage_factory_for_spec(calls : Array(Int32)) : Proc(String, String)
    ->(parent : String) do
      calls << 1
      stage = File.tempname("crystal-click-multipoint-w112-stage", nil, dir: parent)
      Dir.mkdir(stage)
      stage
    end
  end

  def self.w112_substitute_multipoint_columns_for_spec : Proc(String, Nil)
    ->(stage : String) do
      checksums = PartChecksums.open(stage)
      checksums.entries.each do |name, entry|
        checksums.validate_selected_entries(stage, name)
        CityHashV1.file_hash(File.read(File.join(stage, name)).to_slice).should eq(entry.file_hash)
      end

      columns_path = File.join(stage, "columns.txt")
      columns = File.read(columns_path)
      original = "`z_geo` MultiPoint\n"
      unless columns.includes?(original)
        raise CorruptPartError.new("W112 test hook could not find exact MultiPoint declaration")
      end
      File.write(columns_path, columns.gsub(original, "`z_geo` LineString\n"))

      # columns.txt is plain metadata, not a checksummed payload. Confirm the
      # attack leaves every recorded payload checksum valid before readback.
      checksums.entries.each do |name, entry|
        checksums.validate_selected_entries(stage, name)
        CityHashV1.file_hash(File.read(File.join(stage, name)).to_slice).should eq(entry.file_hash)
      end
      nil
    end
  end
end

describe "W112 paired nominal MultiPoint writer" do
  it "writes and reads mixed sizes while isolating caller snapshots and preserving raw Point bits" do
    parent = File.tempname("crystal-click-multipoint-w112-mixed")
    Dir.mkdir(parent)
    destination = File.join(parent, "MultiPoint_1_1_0")
    keys = [1_u64, 2_u64, 3_u64]
    expected_keys = [1_u64, 2_u64, 3_u64]
    level_sizes = [[2_u64, 0_u64, 1_u64]]
    expected_level_sizes = [2_u64, 0_u64, 1_u64]
    points = [
      CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64),
      CrystalClick::WidePointValue.from_bits(0x3ff0_0000_0000_0000_u64, 0xfff0_0000_0000_0000_u64),
      CrystalClick::WidePointValue.from_bits(1_u64, 0x7ff0_0000_0000_0000_u64),
    ]
    expected_points = points.dup
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w112_stage_factory_for_spec(stage_calls)
    hook = ->(_stage : String) do
      # This runs only after bytes and expected snapshots have been staged.
      # Mutating the caller-owned values must not change staged validation.
      keys[0] = 99_u64
      level_sizes[0][0] = 0_u64
      points[0] = CrystalClick::WidePointValue.new(9.0, 9.0)
      nil
    end

    begin
      CrystalClick::WidePartWriter.w112_test_write_with_hooks(
        destination, "a_key", keys.to_unsafe.to_slice(keys.size), "z_geo", "MultiPoint",
        level_sizes, points, 1, stage_factory, hook
      ).should eq(destination)

      stage_calls.should eq([1])
      part = CrystalClick::WidePart.open_typed(destination, "z_geo")
      part.column_type.should eq("MultiPoint")
      part.row_count.should eq(expected_keys.size.to_u64)
      part.mark_row_counts.should eq([1_u64, 1_u64, 1_u64])
      data = part.read_geo_array_mark_range("z_geo", 0, part.mark_count)
      data.type_name.should eq("MultiPoint")
      data.row_count.should eq(expected_keys.size)
      data.point_count.should eq(expected_points.size)
      data.topology.sizes(0).should eq(expected_level_sizes)
      expected_points.each_with_index do |expected, index|
        data.point_at(index).same_bits?(expected).should be_true
      end

      key_part = CrystalClick::WidePart.open_typed(destination, "a_key")
      key_part.read_uint64_mark_range("a_key", 0, key_part.mark_count).should eq(expected_keys)
      File.read(File.join(destination, "columns.txt")).should contain("`z_geo` MultiPoint\n")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "roundtrips all-empty MultiPoint rows without losing the nominal type" do
    parent = File.tempname("crystal-click-multipoint-w112-empty")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    keys = [7_u64, 8_u64, 9_u64]
    begin
      CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "geo", "MultiPoint",
        [[0_u64, 0_u64, 0_u64]], [] of CrystalClick::WidePointValue, rows_per_mark: 2
      ).should eq(destination)

      part = CrystalClick::WidePart.open_typed(destination, "geo")
      part.column_type.should eq("MultiPoint")
      part.row_count.should eq(3_u64)
      part.mark_row_counts.should eq([2_u64, 1_u64])
      data = part.read_geo_array_mark_range("geo", 0, part.mark_count)
      data.type_name.should eq("MultiPoint")
      data.topology.sizes(0).should eq([0_u64, 0_u64, 0_u64])
      data.point_count.should eq(0)
      data.points.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-valid same-layout nominal sibling substitution before publish" do
    parent = File.tempname("crystal-click-multipoint-w112-nominal-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w112_stage_factory_for_spec(stage_calls)
    hook = CrystalClick::WidePartWriter.w112_substitute_multipoint_columns_for_spec
    keys = [1_u64, 2_u64]
    points = [CrystalClick::WidePointValue.new(1.5, -2.25)]

    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Geo Array columns metadata differs") do
        CrystalClick::WidePartWriter.w112_test_write_with_hooks(
          destination, "a_key", keys.to_unsafe.to_slice(keys.size), "z_geo", "MultiPoint",
          [[1_u64, 0_u64]], points, 1, stage_factory, hook
        )
      end
      stage_calls.should eq([1])
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
