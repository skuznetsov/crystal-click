require "./spec_helper"

describe CrystalClick::WidePart do
  it "rejects a deep Tuple child-count mismatch before yielding any mark" do
    parent = File.tempname("crystal-click-wide-reader-nested-metadata-w106")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    type_name = "Tuple(outer Tuple(inner Tuple(value UInt8)), tail UInt8)"
    keys = [10_u64, 11_u64]
    columns = [
      CrystalClick::WideTupleLeafColumn.new("outer.inner.value", [0_u8, 0_u8] of UInt8),
      CrystalClick::WideTupleLeafColumn.new("tail", [0_u8, 0_u8] of UInt8),
    ] of CrystalClick::WideTupleLeafColumn

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2
      ).should eq(part)

      metadata_path = File.join(part, "serialization.json")
      original = File.read(metadata_path)
      # This otherwise-valid serializer tree omits the terminal child below
      # outer.inner. The spaces preserve the writer-declared file size, so the
      # failure isolates recursive schema matching rather than checksum sizing.
      valid_inner = %({"kind":"Default","num_defaults":2,"num_rows":2,"subcolumns":[{"kind":"Default","num_defaults":2,"num_rows":2}]})
      invalid_inner = %({"kind":"Default","num_defaults":2,"num_rows":2,"subcolumns":[]})
      original.includes?(valid_inner).should be_true
      malformed = original.sub(valid_inner, invalid_inner)
      malformed.should_not eq(original)
      malformed.bytesize.should be < original.bytesize
      malformed += " " * (original.bytesize - malformed.bytesize)
      File.write(metadata_path, malformed)
      File.size(metadata_path).should eq(original.bytesize)

      checksums = CrystalClick::PartChecksums.open(part)
      checksums.validate_selected_entries(part, "serialization.json").should eq(CrystalClick::ChecksumVerification::SizeChecked)
      payload_column = JSON.parse(malformed)["columns"].as_a.find do |column|
        column["name"].as_s == "payload"
      end.not_nil!
      nested_children = payload_column["subcolumns"].as_a[0]["subcolumns"].as_a[0]["subcolumns"].as_a
      nested_children.should be_empty

      callbacks = [] of Int32
      expect_raises(CrystalClick::UnsupportedFormatError, "Tuple child serializer count does not match schema") do
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        reader.each_tuple_mark_range("payload", 0, 1) do |_data, mark_index|
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
