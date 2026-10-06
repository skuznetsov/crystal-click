require "./spec_helper"

describe "W180 JSON binary profile admission boundaries" do
  it "refuses an empty JSON descriptor at both ordinary and escaped physical-bulk entry points" do
    empty_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
    )

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(empty_json, "payload")
    end
    error.message.to_s.should contain("JSON")

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      # '%' is invalid escaped-prefix syntax; the JSON-specific guard must win
      # before the prefix parser can reject it for an unrelated reason.
      CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(empty_json, "%")
    end
    error.message.to_s.should contain("JSON")
  end

  it "refuses raw JSON schemas in inspect and zero-window read before opening a missing part" do
    missing_part = File.tempname("crystal-click-json-w180-missing")
    File.exists?(missing_part).should be_false

    schema = {
      "empty" => CrystalClick::BinaryDataType.json(
        max_dynamic_paths: 0,
        max_dynamic_types: 0,
      ),
    } of String => CrystalClick::BinaryDataType

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentFileReader.inspect(missing_part, "payload", schema)
    end
    error.message.to_s.should contain("JSON")

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentFileReader.read(
        missing_part,
        "payload",
        schema,
        first_mark: 0,
        mark_count: 0,
      )
    end
    error.message.to_s.should contain("JSON")
  end
end
