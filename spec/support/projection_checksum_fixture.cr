module ProjectionChecksumFixture
  extend self

  alias ChecksumRecord = CrystalClick::PartWriterInfrastructure::ChecksumRecord
  alias ChecksumsWriter = CrystalClick::PartWriterInfrastructure::PartChecksumsWriter

  # Seal a synthetic projection child into its parent's checksum envelope.
  # This deliberately recomputes the manifest summary in spec code so fixtures
  # do not depend on the production projection-summary implementation.
  def rebind!(parent_path : String, projection_name : String) : Nil
    entry_name = projection_name.ends_with?(".proj") ? projection_name : "#{projection_name}.proj"
    child_path = File.join(parent_path, entry_name)
    size, hash = summarize_child(child_path)

    records = [] of ChecksumRecord
    CrystalClick::PartChecksums.open(parent_path).entries.each do |name, entry|
      next if name == entry_name
      records << ChecksumRecord.new(
        name,
        entry.physical_size,
        entry.file_hash,
        entry.compressed,
        entry.uncompressed_size,
        entry.uncompressed_hash,
      )
    end
    records << ChecksumRecord.new(entry_name, size, hash, false)
    ChecksumsWriter.write(parent_path, records)
  end

  private def summarize_child(child_path : String) : {UInt64, {UInt64, UInt64}}
    checksums = CrystalClick::PartChecksums.open(child_path)
    input = IO::Memory.new
    total_size = 0_u64
    checksums.entries.keys.sort.each do |name|
      entry = checksums.entries[name]
      total_size += entry.physical_size
      input.write_bytes(name.bytesize.to_u64, IO::ByteFormat::LittleEndian)
      input.write(name.to_slice)
      input.write_bytes(entry.file_hash[0], IO::ByteFormat::LittleEndian)
      input.write_bytes(entry.file_hash[1], IO::ByteFormat::LittleEndian)
    end
    {total_size, CrystalClick::ClickHouseSipHash.hash128(input.to_slice)}
  end
end
