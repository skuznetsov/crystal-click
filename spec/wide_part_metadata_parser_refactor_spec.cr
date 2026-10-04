require "./spec_helper"

# Characterization seam for the parser extraction. These wrappers deliberately
# call the private text-grammar owner from a normally opened WidePart instance.
class CrystalClick::WidePart
  def metadata_parser_spec_parse_columns(text : String) : Array({String, String})
    PartMetadataTextParser.parse_columns(text)
  end

  def metadata_parser_spec_metadata_line(bytes : Bytes, cursor : Int, file : String) : String
    PartMetadataTextParser.metadata_line(bytes, cursor, file)
  end

  def metadata_parser_spec_parse_substream_header(line : String) : {Int32, String}
    PartMetadataTextParser.parse_substream_header(line)
  end

  def metadata_parser_spec_parse_decimal(text : String, limit : UInt64) : UInt64
    PartMetadataTextParser.parse_decimal(text, limit, "count.txt")
  end

  def metadata_parser_spec_validate_opaque_name(name : String) : Nil
    PartMetadataTextParser.validate_opaque_name(name)
  end

  def metadata_parser_spec_validate_selected_stream_name(name : String) : Nil
    PartMetadataTextParser.validate_selected_stream_name(name)
  end
end

private def metadata_parser_spec_part : CrystalClick::WidePart
  CrystalClick::WidePart.open(FIXTURE)
end

describe "WidePart metadata parser refactor characterization" do
  it "decodes literal columns and escaped identifiers while preserving the empty parse result" do
    part = metadata_parser_spec_part
    text = "columns format version: 1\n3 columns:\n" +
           "`pre\\x41fix` String\n`mid``quote` UInt64\n`suf\\Nfix` Array(Nullable(String))\n"

    part.metadata_parser_spec_parse_columns(text).should eq([
      {"preAfix", "String"},
      {"mid`quote", "UInt64"},
      {"suffix", "Array(Nullable(String))"},
    ])
    part.metadata_parser_spec_parse_columns("columns format version: 1\n0 columns:\n").should be_empty

    with_fixture_copy do |path|
      File.write(File.join(path, "columns.txt"), "columns format version: 1\n0 columns:\n")
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open(path)
      end
      error.message.not_nil!.should eq("columns.txt contains no columns")
    end
  end

  it "keeps strict version, count, duplicate, truncation, and trailing-data failures" do
    part = metadata_parser_spec_part
    malformed = [
      "columns format version: 2\n0 columns:\n",
      "columns format version: 1\n00 columns:\n",
      "columns format version: 1\n4097 columns:\n",
      "columns format version: 1\n1 columns:\n",
      "columns format version: 1\n1 columns:\n`same` UInt64\n`same` String\n",
      "columns format version: 1\n2 columns:\n`same` UInt64\n`same` String\n",
      "columns format version: 1\n0 columns:\ntrailing\n",
      "columns format version: 1\n1 columns:\n`bad\\xG0` UInt64\n",
    ]

    malformed.each do |text|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.metadata_parser_spec_parse_columns(text)
      end
    end
  end

  it "preserves exact UInt64 counts and refuses overflow or noncanonical digits" do
    part = metadata_parser_spec_part
    part.metadata_parser_spec_parse_decimal("0", UInt64::MAX).should eq(0_u64)
    part.metadata_parser_spec_parse_decimal("18446744073709551615", UInt64::MAX).should eq(UInt64::MAX)
    {"", "01", "-1", "+1", "1 ", "18446744073709551616"}.each do |text|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.metadata_parser_spec_parse_decimal(text, UInt64::MAX)
      end
    end
  end

  it "enforces metadata line limits including the newline byte" do
    part = metadata_parser_spec_part
    maximum = CrystalClick::WidePart::MAX_METADATA_LINE_BYTES
    at_limit = ("x" * (maximum - 1)) + "\n"
    over_limit = ("x" * maximum) + "\n"

    part.metadata_parser_spec_metadata_line(at_limit.to_slice, 0, "columns.txt").bytesize.should eq(maximum - 1)
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      part.metadata_parser_spec_metadata_line(over_limit.to_slice, 0, "columns.txt")
    end
    error.message.not_nil!.should eq("line exceeds metadata limit in columns.txt")
  end

  it "parses bounded substream headers and rejects malformed count or identifier syntax" do
    part = metadata_parser_spec_part
    part.metadata_parser_spec_parse_substream_header(
      "17 substreams for column `pre\\x41fix`:"
    ).should eq({17, "preAfix"})
    part.metadata_parser_spec_parse_substream_header(
      "0 substreams for column `empty`:"
    ).should eq({0, "empty"})
    part.metadata_parser_spec_parse_substream_header(
      "65536 substreams for column `maximum`:"
    ).should eq({65_536, "maximum"})

    malformed = [
      "01 substreams for column `input`:",
      "1 substreams for column input:",
      "1 substreams for column `input`:extra",
      "65537 substreams for column `input`:",
    ]
    malformed.each do |line|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.metadata_parser_spec_parse_substream_header(line)
      end
    end
  end

  it "keeps opaque stream names distinct from selected filename components" do
    part = metadata_parser_spec_part
    part.metadata_parser_spec_validate_opaque_name("nested/input")
    part.metadata_parser_spec_validate_opaque_name("stream\\name")

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      part.metadata_parser_spec_validate_selected_stream_name("nested/input")
    end
    error.message.not_nil!.should eq("selected physical stream name is not a filename component")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      part.metadata_parser_spec_validate_selected_stream_name("stream\\name")
    end

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      part.metadata_parser_spec_validate_opaque_name("bad\tname")
    end
    error.message.not_nil!.should eq("invalid physical stream name")
  end
end
