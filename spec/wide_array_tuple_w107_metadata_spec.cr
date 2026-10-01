require "./spec_helper"
require "file_utils"

module CrystalClick::WidePartWriter
  # Rebuild the test part's checksums after serializer-only mutations. This
  # keeps the negative case isolated to metadata admission rather than the
  # selected-file length precheck.
  def self.w107_test_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CompressedBlock.decode_all(bytes)
        records << ChecksumRecord.new(
          name, bytes.size.to_u64, file_hash, true, raw.size.to_u64, CityHashV1.file_hash(raw)
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    write_checksums(part, records)
  end
end

private def w107m_write_part(parent : String, label : String = "part-container") : {String, String}
  type_name = "Array(Tuple(note String))"
  columns = [CrystalClick::WideTupleLeafColumn.new("note", ["one", "two"] of String)] of CrystalClick::WideTupleLeafColumn
  container = File.join(parent, label)
  Dir.mkdir(container)
  part = File.join(container, "all_1_1_0")
  keys = [1_u64, 2_u64]
  sizes = [1_u64, 1_u64]
  CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name,
    sizes.to_unsafe.to_slice(sizes.size), columns, 1
  )
  {part, type_name}
end

private def w107m_replace_serialization(part : String, value : String) : Nil
  File.write(File.join(part, "serialization.json"), value)
  CrystalClick::WidePartWriter.w107_test_refresh_checksums(part)
end

private def w107m_valid_header(columns_json : String) : String
  "{\"columns\":#{columns_json},\"propagate_types_serialization_versions_to_nested_types\":true," +
    "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
end

describe CrystalClick::WidePart do
  it "retains the inherited empty-columns Array(Tuple) metadata profile for the two-column key/payload shape" do
    parent = File.tempname("crystal-click-array-tuple-w107-metadata-empty-columns")
    Dir.mkdir(parent)
    begin
      part, _type_name = w107m_write_part(parent, "payload-serializer")
      w107m_replace_serialization(part, w107m_valid_header("[]"))
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      data = reader.read_array_tuple_mark_range("payload", 0, reader.mark_count)
      data.row_count.should eq(2)
      data.element_count.should eq(2)
      data.row(0)[0]["note"].should eq("one")
      data.row(1)[0]["note"].should eq("two")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects payload-named and recursive serializer records before a mark callback" do
    parent = File.tempname("crystal-click-array-tuple-w107-metadata-invalid")
    Dir.mkdir(parent)
    begin
      part, _type_name = w107m_write_part(parent, "recursive-serializer")
      payload_record = %([{"kind":"Default","name":"payload","num_defaults":0,"num_rows":2}])
      w107m_replace_serialization(part, w107m_valid_header(payload_record))
      callbacks = [] of Int32
      expect_raises(CrystalClick::UnsupportedFormatError, "array serializer must identify a UInt64 key column") do
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        reader.each_array_tuple_mark_range("payload", 0, 1) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty

      part, _type_name = w107m_write_part(parent)
      recursive_record = %([{"kind":"Default","name":"pk","num_defaults":0,"num_rows":2,"subcolumns":[]}])
      w107m_replace_serialization(part, w107m_valid_header(recursive_record))
      callbacks.clear
      expect_raises(CrystalClick::UnsupportedFormatError, "array column serializer fields are unsupported") do
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        reader.each_array_tuple_mark_range("payload", 0, 1) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
