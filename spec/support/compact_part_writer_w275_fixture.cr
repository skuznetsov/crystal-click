require "../../src/crystal_click"
require "./compact_part_writer_w264_fixture"
require "./compact_part_writer_w268_fixture"
require "./compact_part_writer_w273_fixture"

module CompactPartWriterW275Fixture
  extend self

  def static(
    part_path : String,
    mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
    compress_marks : Bool = false,
    transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
    reader_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  ) : String
    fixture = CompactPartWriterW264Fixture
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW264Fixture::KEY_NAME,
      fixture.keys,
      fixture.columns,
      rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      transport_limits: transport_limits,
      reader_limits: reader_limits,
      mark_format: mark_format,
      compress_marks: compress_marks,
    )
  end

  def dynamic(
    part_path : String,
    mark_format : CrystalClick::CompactMarkFormat,
    discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
    compress_marks : Bool = false,
  ) : String
    fixture = CompactPartWriterW268Fixture
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW268Fixture::KEY_NAME,
      fixture.keys,
      fixture.columns,
      rows_per_mark: CompactPartWriterW268Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW268Fixture::FRAME_BYTES,
      mark_format: mark_format,
      variant_discriminator_mode: discriminator_mode,
      compress_marks: compress_marks,
    )
  end

  def json(
    part_path : String,
    depth : Int,
    mark_format : CrystalClick::CompactMarkFormat,
    discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
    compress_marks : Bool = false,
  ) : String
    fixture = CompactPartWriterW273Fixture
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW273Fixture::KEY_NAME,
      CompactPartWriterW273Fixture::KEYS,
      [fixture.column(depth)] of CrystalClick::CompactPartColumn,
      rows_per_mark: CompactPartWriterW273Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW273Fixture::FRAME_BYTES,
      mark_format: mark_format,
      variant_discriminator_mode: discriminator_mode,
      compress_marks: compress_marks,
    )
  end

  def mark_name(
    mark_format : CrystalClick::CompactMarkFormat,
    compress_marks : Bool,
  ) : String
    case mark_format
    when .mrk3?
      compress_marks ? "data.cmrk3" : "data.mrk3"
    when .mrk4?
      compress_marks ? "data.cmrk4" : "data.mrk4"
    else
      raise ArgumentError.new("unsupported W275 mark format")
    end
  end

  def file_bytes(part_path : String, name : String) : Bytes
    File.read(File.join(part_path, name)).to_slice.dup
  end

  def file_snapshot(part_path : String) : Hash(String, String)
    snapshot = Hash(String, String).new
    Dir.children(part_path).each do |name|
      snapshot[name] = File.read(File.join(part_path, name))
    end
    snapshot
  end
end
