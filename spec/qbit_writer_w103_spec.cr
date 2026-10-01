require "./spec_helper"

module CrystalClick
  module WidePartWriter
    # The production API deliberately does not expose staging hooks. These
    # helpers keep the hostile staged-part seam local to this spec file.
    def self.write_qbit_pair_with_hooks_for_spec(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      values : Slice(QBitValue),
      stage_factory : Proc(String, String),
      before_validation_hook : Proc(String, QBitPartWriteInput, Nil),
    ) : String
      value_at = ->(index : Int32) { values[index].as(QBitValue?) }
      write_qbit_pair_with_hooks(
        destination, key_name, keys, value_name, type_name, values.size, false,
        value_at, 8192, stage_factory, before_validation_hook
      )
    end

    def self.tamper_qbit_plane_for_spec(
      logical_name : String,
      encoded_row : Bytes,
    ) : Proc(String, QBitPartWriteInput, Nil)
      ->(stage : String, _input : QBitPartWriteInput) {
        frame = StreamEncoding.encode_lz4_frame(encoded_row)
        File.write(File.join(stage, "#{StreamName.hash(logical_name)}.bin"), frame)
        nil
      }
    end

    def self.tamper_qbit_uncompressed_hash_declaration_for_spec(
      logical_name : String,
    ) : Proc(String, QBitPartWriteInput, Nil)
      ->(stage : String, _input : QBitPartWriteInput) {
        checksums_path = File.join(stage, "checksums.txt")
        checksum_text = File.read(checksums_path)
        bytes = checksum_text.to_slice
        header_size = PartChecksums::CHECKSUMS_HEADER.bytesize
        payload = CompressedBlock.decode_all(
          bytes[header_size, bytes.size - header_size],
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )

        entry_name = "#{StreamName.hash(logical_name)}.bin"
        original_entry = PartChecksums.open(stage).entry(entry_name) ||
                         raise "target checksum entry is missing in spec seam"
        cursor = 0
        count, cursor = read_qbit_spec_var_uint(payload, cursor)
        found = false
        count.to_i.times do
          name_length, cursor = read_qbit_spec_var_uint(payload, cursor)
          name = String.new(payload[cursor, name_length.to_i])
          cursor += name_length.to_i
          _physical_size, cursor = read_qbit_spec_var_uint(payload, cursor)
          cursor += 16 # physical file hash remains unchanged
          compressed = payload[cursor] == 1_u8
          cursor += 1
          if compressed
            _uncompressed_size, cursor = read_qbit_spec_var_uint(payload, cursor)
            if name == entry_name
              payload[cursor] = payload[cursor] ^ 1_u8
              found = true
              break
            end
            cursor += 16
          elsif name == entry_name
            raise "target checksum entry is unexpectedly uncompressed"
          end
        end
        raise "target uncompressed hash was not found in spec seam" unless found

        frame = StreamEncoding.encode_lz4_frame(payload)
        File.open(checksums_path, "wb") do |file|
          file << PartChecksums::CHECKSUMS_HEADER
          file.write(frame)
        end
        rewritten_entry = PartChecksums.open(stage).entry(entry_name) ||
                          raise "target checksum entry disappeared in spec seam"
        unless rewritten_entry.physical_size == original_entry.physical_size &&
               rewritten_entry.file_hash == original_entry.file_hash &&
               rewritten_entry.compressed == original_entry.compressed &&
               rewritten_entry.uncompressed_size == original_entry.uncompressed_size
          raise "spec seam changed plane size or physical hash declarations"
        end
        nil
      }
    end

    private def self.read_qbit_spec_var_uint(bytes : Bytes, cursor : Int32) : {UInt64, Int32}
      value = 0_u64
      index = 0
      loop do
        byte = bytes[cursor]
        cursor += 1
        value |= (byte & 0x7f).to_u64 << (index * 7)
        return {value, cursor} if (byte & 0x80) == 0
        index += 1
      end
    end

    def self.no_op_qbit_validation_hook_for_spec : Proc(String, QBitPartWriteInput, Nil)
      ->(_stage : String, _input : QBitPartWriteInput) { nil }
    end

    def self.tamper_qbit_schema_for_spec(
      original_type : String,
      replacement_type : String,
    ) : Proc(String, QBitPartWriteInput, Nil)
      ->(stage : String, _input : QBitPartWriteInput) {
        columns_path = File.join(stage, "columns.txt")
        columns = File.read(columns_path)
        original_declaration = "`payload` #{original_type}"
        replacement_declaration = "`payload` #{replacement_type}"
        raise "canonical QBit schema was not found in staged metadata" unless columns.includes?(original_declaration)
        File.write(columns_path, columns.sub(original_declaration, replacement_declaration))
        nil
      }
    end

    def self.replace_qbit_columns_with_matching_symlink_for_spec(
      target_path : String,
    ) : Proc(String, QBitPartWriteInput, Nil)
      ->(stage : String, input : QBitPartWriteInput) {
        File.write(target_path, input.columns_metadata)
        columns_path = File.join(stage, "columns.txt")
        File.delete(columns_path)
        File.symlink(target_path, columns_path)
        nil
      }
    end

    def self.replace_qbit_metadata_version_with_matching_symlink_for_spec(
      target_path : String,
    ) : Proc(String, QBitPartWriteInput, Nil)
      ->(stage : String, _input : QBitPartWriteInput) {
        File.write(target_path, "0")
        metadata_version_path = File.join(stage, "metadata_version.txt")
        File.delete(metadata_version_path)
        File.symlink(target_path, metadata_version_path)
        nil
      }
    end

    def self.append_qbit_columns_byte_for_spec : Proc(String, QBitPartWriteInput, Nil)
      ->(stage : String, _input : QBitPartWriteInput) {
        columns_path = File.join(stage, "columns.txt")
        File.write(columns_path, File.read(columns_path) + "x")
        nil
      }
    end

    def self.forbidden_qbit_stage_factory_for_spec(calls : Array(Int32)) : Proc(String, String)
      ->(_parent : String) do
        calls << 1
        raise "stage factory must not run for an over-budget QBit batch"
      end
    end
  end
end

describe "bounded QBit Wide-part writer" do
  it "writes and reads back exact raw scalar element bits" do
    parent = File.tempname("crystal-click-qbit-writer-scalar")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Float64", 2_u64)
    raw_rows = [
      Bytes[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 128_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 240_u8, 127_u8],
      Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 248_u8, 127_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
    ]
    values = raw_rows.map { |raw| CrystalClick::QBitValue.new(type, raw) }
    keys = [4_u64, 9_u64]

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

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq(type.type_name)
      reader.mark_row_counts.should eq([1_u64, 1_u64])
      reader.read_qbit_mark_range("payload", 0, 2).map(&.raw_bytes).should eq(raw_rows)
      File.read(File.join(destination, "columns.txt")).should contain("`payload` #{type.type_name}")
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes nullable values with a verified null map and zero dense placeholders" do
    parent = File.tempname("crystal-click-qbit-writer-nullable")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("BFloat16", 16_u64, 8_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0xA5_u8))
    values = [nil, value, nil] of CrystalClick::QBitValue?
    keys = [1_u64, 2_u64, 3_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_qbit_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        "Nullable(#{type.type_name})",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Nullable(#{type.type_name})")
      reader.read_nullable_qbit_mark_range("payload", 0, 2).should eq(values)
      dense = reader.read_qbit_dense_mark_range("payload", 0, 2)
      dense.map(&.raw_bytes).should eq([
        Bytes.new(type.raw_row_bytes, 0_u8),
        value.raw_bytes,
        Bytes.new(type.raw_row_bytes, 0_u8),
      ])
      physical = CrystalClick::QBitColumnType.new(type, true).physical_streams("payload")
      physical.map { |stream| stream[0] }.should eq(["payload.null"] + (1..32).map { |plane| "payload%2E#{plane}" })
      physical.each do |name, width|
        File.size(File.join(destination, "#{CrystalClick::StreamName.hash(name)}.bin")).should be > 0
        width.should eq(1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects noncanonical declarations and mismatched exact types before staging" do
    parent = File.tempname("crystal-click-qbit-writer-preflight")
    Dir.mkdir(parent)
    type = CrystalClick::QBitType.new("Float32", 2_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [1_u64]

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_qbit_pair(
          File.join(parent, "noncanonical"), "pk", keys.to_unsafe.to_slice(1),
          "payload", "QBit(Float32, 02)", values.to_unsafe.to_slice(1)
        )
      end
      Dir.children(parent).should be_empty

      other_type = CrystalClick::QBitType.new("Float64", 2_u64)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_qbit_pair(
          File.join(parent, "wrong-exact-type"), "pk", keys.to_unsafe.to_slice(1),
          "payload", other_type.type_name, values.to_unsafe.to_slice(1)
        )
      end
      Dir.children(parent).should be_empty

      decreasing_keys = [2_u64, 1_u64]
      two_values = [value, value]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_qbit_pair(
          File.join(parent, "decreasing-keys"), "pk", decreasing_keys.to_unsafe.to_slice(2),
          "payload", type.type_name, two_values.to_unsafe.to_slice(2)
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-width staged plane corruption and removes the stage before publish" do
    parent = File.tempname("crystal-click-qbit-writer-tampered-stage")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Float32", 1_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [7_u64]
    stage_factory = ->(stage_parent : String) {
      stage = File.join(stage_parent, "qbit-test-stage")
      Dir.mkdir(stage)
      stage
    }
    # Plane 1 carries Float32's sign bit. A valid same-size LZ4 frame changes
    # +0 to -0 without disturbing the rest of the staged part.
    tamper_plane = CrystalClick::WidePartWriter.tamper_qbit_plane_for_spec("payload%2E1", Bytes[1_u8])

    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, tamper_plane
        )
      end
      error.message.not_nil!.should contain("raw value bits")
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a valid same-width alternate QBit schema before publish" do
    parent = File.tempname("crystal-click-qbit-writer-schema-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Float32", 32_u64, 8_u64)
    alternate_type = CrystalClick::QBitType.new("Float64", 16_u64, 8_u64)
    type.raw_row_bytes.should eq(alternate_type.raw_row_bytes)
    type.plane_count.should eq(alternate_type.plane_count)
    type.plane_width.should eq(alternate_type.plane_width)
    type.type_name.bytesize.should eq(alternate_type.type_name.bytesize)
    CrystalClick::QBitColumnType.new(type).physical_streams("payload").should eq(
      CrystalClick::QBitColumnType.new(alternate_type).physical_streams("payload")
    )

    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [7_u64]
    stage_factory = ->(stage_parent : String) {
      stage = File.join(stage_parent, "qbit-test-stage")
      Dir.mkdir(stage)
      stage
    }
    replace_schema = CrystalClick::WidePartWriter.tamper_qbit_schema_for_spec(type.type_name, alternate_type.type_name)

    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, replace_schema
        )
      end
      error.message.not_nil!.should eq("staged QBit columns metadata differs")
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an altered plane uncompressed-hash declaration before publish" do
    parent = File.tempname("crystal-click-qbit-writer-uncompressed-hash-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Float32", 1_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [7_u64]
    stage_factory = ->(stage_parent : String) {
      stage = File.join(stage_parent, "qbit-test-stage")
      Dir.mkdir(stage)
      stage
    }
    tamper_hash = CrystalClick::WidePartWriter.tamper_qbit_uncompressed_hash_declaration_for_spec("payload%2E1")

    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, tamper_hash
        )
      end
      error.message.not_nil!.should contain("checksums.txt")
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects matching staged columns metadata reached through a symlink before publish" do
    parent = File.tempname("crystal-click-qbit-writer-metadata-symlink")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    external_metadata = File.join(parent, "matching-columns.txt")
    type = CrystalClick::QBitType.new("Float32", 1_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [7_u64]
    stage_factory = ->(stage_parent : String) {
      stage = File.join(stage_parent, "qbit-test-stage")
      Dir.mkdir(stage)
      stage
    }
    replace_columns = CrystalClick::WidePartWriter.replace_qbit_columns_with_matching_symlink_for_spec(external_metadata)

    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, replace_columns
        )
      end
      error.message.not_nil!.should contain("columns metadata must not be a symbolic link")
      File.exists?(destination).should be_false
      File.symlink?(external_metadata).should be_false
      File.read(external_metadata).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type.type_name}\n"
      )
      Dir.children(parent).sort.should eq(["matching-columns.txt"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects matching staged metadata version reached through a symlink before publish" do
    parent = File.tempname("crystal-click-qbit-writer-metadata-version-symlink")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    external_metadata = File.join(parent, "matching-metadata-version.txt")
    type = CrystalClick::QBitType.new("Float32", 1_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [7_u64]
    stage_factory = ->(stage_parent : String) {
      stage = File.join(stage_parent, "qbit-test-stage")
      Dir.mkdir(stage)
      stage
    }
    replace_metadata_version = CrystalClick::WidePartWriter.replace_qbit_metadata_version_with_matching_symlink_for_spec(external_metadata)

    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, replace_metadata_version
        )
      end
      error.message.not_nil!.should eq("staged QBit metadata version metadata must not be a symbolic link")
      File.exists?(destination).should be_false
      File.symlink?(external_metadata).should be_false
      File.read(external_metadata).should eq("0")
      Dir.children(parent).should eq(["matching-metadata-version.txt"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects staged metadata size mismatch before content comparison and publish" do
    parent = File.tempname("crystal-click-qbit-writer-metadata-size")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    type = CrystalClick::QBitType.new("Float32", 1_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [7_u64]
    stage_factory = ->(stage_parent : String) {
      stage = File.join(stage_parent, "qbit-test-stage")
      Dir.mkdir(stage)
      stage
    }
    append_metadata_byte = CrystalClick::WidePartWriter.append_qbit_columns_byte_for_spec

    begin
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, append_metadata_byte
        )
      end
      error.message.not_nil!.should contain("columns metadata size differs")
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects aggregate materialization above 64 MiB before invoking the stage factory" do
    parent = File.tempname("crystal-click-qbit-writer-aggregate-budget")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    # One logical row is 32 MiB, and its QBit planes also occupy 32 MiB;
    # metadata plus result slots put the declared aggregate above the cap.
    type = CrystalClick::QBitType.new("Float64", 4_194_304_u64, 16_384_u64)
    value = CrystalClick::QBitValue.new(type, Bytes.new(type.raw_row_bytes, 0_u8))
    values = [value]
    keys = [1_u64]
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.forbidden_qbit_stage_factory_for_spec(stage_calls)
    no_op_hook = CrystalClick::WidePartWriter.no_op_qbit_validation_hook_for_spec

    begin
      expect_raises(ArgumentError, "QBit materialization exceeds 64 MiB per-range limit") do
        CrystalClick::WidePartWriter.write_qbit_pair_with_hooks_for_spec(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type.type_name,
          values.to_unsafe.to_slice(values.size), stage_factory, no_op_hook
        )
      end
      stage_calls.should be_empty
      Dir.children(parent).should be_empty
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
