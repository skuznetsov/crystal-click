require "./spec_helper"

describe CrystalClick::ObjectDocumentDecodeWorkspace do
  it "keeps returned documents detached across reuse and large-row fallback" do
    workspace = CrystalClick::ObjectDocumentDecodeWorkspace.new

    retained_hash_id = 0_u64
    first = workspace.with_fields(2_u64) do |fields|
      retained_hash_id = fields.object_id
      fields["id"] = CrystalClick::BinaryValue.uint64(17_u64)
      fields["title"] = CrystalClick::BinaryValue.string("before")
      CrystalClick::ObjectDocument.new(fields)
    end

    fallback_hash_id = 0_u64
    fallback = workspace.with_fields(17_u64) do |fields|
      fallback_hash_id = fields.object_id
      17.times do |index|
        fields["p#{index}"] = CrystalClick::BinaryValue.uint64(index.to_u64)
      end
      CrystalClick::ObjectDocument.new(fields)
    end

    second = workspace.with_fields(2_u64) do |fields|
      fields.object_id.should eq(retained_hash_id)
      fields.size.should eq(0)
      fields["id"] = CrystalClick::BinaryValue.uint64(29_u64)
      fields["title"] = CrystalClick::BinaryValue.string("after")
      CrystalClick::ObjectDocument.new(fields)
    end

    fallback_hash_id.should_not eq(retained_hash_id)
    fallback.path_count.should eq(17)
    first.value_for("id").as_uint64.should eq(17_u64)
    first.value_for("title").as_string.should eq("before")
    first.path_at(0).to_unsafe[0] = 0_u8
    first.value_at(0).as_uint64.should eq(17_u64)
    first.value_at(1).as_string.should eq("before")
    expect_raises(IndexError) { first.value_at(2) }
    second.value_for("id").as_uint64.should eq(29_u64)
    second.value_for("title").as_string.should eq("after")
  end

  it "clears retained references after a failing row assembly" do
    workspace = CrystalClick::ObjectDocumentDecodeWorkspace.new
    retained_hash_id = 0_u64

    expect_raises(ArgumentError) do
      workspace.with_fields(1_u64) do |fields|
        retained_hash_id = fields.object_id
        fields["failed"] = CrystalClick::BinaryValue.string("transient")
        raise ArgumentError.new("injected row failure")
      end
    end

    next_document = workspace.with_fields(1_u64) do |fields|
      fields.object_id.should eq(retained_hash_id)
      fields.size.should eq(0)
      fields["next"] = CrystalClick::BinaryValue.uint64(1_u64)
      CrystalClick::ObjectDocument.new(fields)
    end
    next_document.value_for("next").as_uint64.should eq(1_u64)
  end
end
