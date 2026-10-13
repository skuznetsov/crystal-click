module CrystalClick
  # Owns the exact staged physical mark sidecar and its checksum declaration.
  # Payload bytes never escape this owner: plain marks adopt a defensive
  # canonical snapshot, while compressed marks adopt encode_all's fresh output.
  class CompactPhysicalMarkOutput
    getter name : String
    getter checksum_record : PartWriterInfrastructure::ChecksumRecord

    @payload : Bytes

    private def initialize(
      @name : String,
      @payload : Bytes,
      @checksum_record : PartWriterInfrastructure::ChecksumRecord,
    )
    end

    def self.file_name(mark_format : CompactMarkFormat, compressed : Bool) : String
      case mark_format
      when CompactMarkFormat::Mrk3
        compressed ? "data.cmrk3" : "data.mrk3"
      when CompactMarkFormat::Mrk4
        compressed ? "data.cmrk4" : "data.mrk4"
      else
        raise UnsupportedFormatError.new("unsupported Compact mark format")
      end
    end

    def self.from_canonical_files(
      files : CompactStaticPartFiles,
      mark_format : CompactMarkFormat,
      compress_marks : Bool,
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : CompactPhysicalMarkOutput
      budget.ensure_direction(true)
      raw_size = files.marks_size.to_i64
      if raw_size <= 0 || raw_size > Int32::MAX.to_i64 ||
         raw_size > WidePart::MAX_MARK_FILE_BYTES.to_i64 ||
         raw_size > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("canonical Compact marks exceed their configured mark-size limit")
      end

      name = file_name(mark_format, compress_marks)
      physical_size = if compress_marks
                        CompressedMarkWriter.preflight_all(raw_size, frame_bytes, budget).to_i64
                      else
                        raw_size
                      end
      if physical_size <= 0 || physical_size > Int32::MAX.to_i64 ||
         physical_size > WidePart::MAX_MARK_FILE_BYTES.to_i64 ||
         physical_size > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("physical Compact marks exceed their configured mark-size limit")
      end
      physical_result_size = compress_marks ? physical_size : 0_i64
      if raw_size > Int64::MAX - physical_result_size
        raise UnsupportedFormatError.new("Compact physical mark result size overflows")
      end
      future_result_size = raw_size + physical_result_size
      # The canonical snapshot is allocated by files.marks below, and a
      # compressed result is allocated by encode_all. Check both together
      # before allocating either snapshot/sidecar in this owner.
      budget.preflight_result_bytes(future_result_size)
      budget.reserve_result_bytes(raw_size)
      canonical_marks = files.marks
      unless canonical_marks.size.to_i64 == raw_size && CityHashV1.file_hash(canonical_marks) == files.marks_hash
        raise UnsupportedFormatError.new("canonical Compact marks differ from their source checksum")
      end

      payload = if compress_marks
                  encoded = CompressedMarkWriter.encode_all(canonical_marks, frame_bytes, budget)
                  unless encoded.size.to_i64 == physical_size
                    raise UnsupportedFormatError.new("compressed Compact marks differ from their preflight")
                  end
                  encoded
                else
                  canonical_marks
                end
      physical_hash = CityHashV1.file_hash(payload)
      record = if compress_marks
                 PartWriterInfrastructure::ChecksumRecord.new(
                   name,
                   payload.size.to_u64,
                   physical_hash,
                   true,
                   raw_size.to_u64,
                   files.marks_hash,
                 )
               else
                 PartWriterInfrastructure::ChecksumRecord.new(
                   name,
                   payload.size.to_u64,
                   physical_hash,
                   false,
                 )
               end
      new(name, payload, record)
    end

    def write_to(stage : String) : Nil
      File.write(File.join(stage, @name), @payload)
      nil
    end
  end
end
