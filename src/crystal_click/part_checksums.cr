module CrystalClick
  # Read-only, bounded parsing for the ClickHouse v4 checksums envelope.
  #
  # The parser consumes the v4 compressed-v3 payload and retains declared
  # physical sizes and file hashes. Selected-entry validation remains size-only:
  # it proves presence and file length, not content integrity.
  class PartChecksums
    CHECKSUMS_HEADER             = "checksums format version: 4\n"
    MAX_CHECKSUM_FILE_BYTES      = 64_i64 * 1024 * 1024
    MAX_FRAME_COMPRESSED_BYTES   = 64_i64 * 1024 * 1024
    MAX_FRAME_DECOMPRESSED_BYTES = 64_i64 * 1024 * 1024
    MAX_PAYLOAD_BYTES            = 64_i64 * 1024 * 1024
    MAX_ENTRIES                  = 65_536
    MAX_NAME_BYTES               =   4096

    struct Entry
      getter physical_size : UInt64
      getter file_hash : {UInt64, UInt64}
      getter compressed : Bool
      getter uncompressed_size : UInt64?
      getter uncompressed_hash : {UInt64, UInt64}?

      def initialize(
        @physical_size : UInt64,
        @compressed : Bool,
        @uncompressed_size : UInt64?,
        @file_hash : {UInt64, UInt64} = {0_u64, 0_u64},
        @uncompressed_hash : {UInt64, UInt64}? = nil,
      )
      end
    end

    getter entries : Hash(String, Entry)

    def self.open(part_path : String) : PartChecksums
      checksum_path = File.join(part_path, "checksums.txt")
      raise CorruptPartError.new("checksums.txt must not be a symbolic link") if File.symlink?(checksum_path)

      size = File.size(checksum_path)
      raise CorruptPartError.new("checksums.txt exceeds limit") if size > MAX_CHECKSUM_FILE_BYTES
      new(File.read(checksum_path).to_slice)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read checksums.txt")
    end

    def self.parse(bytes : Bytes) : PartChecksums
      new(bytes)
    end

    def entry(name : String) : Entry?
      @entries[name]?
    end

    # Validate only the selected files. The result deliberately does not imply
    # hash or compressed-frame checksum verification.
    def validate_selected_entries(part_path : String, *names : String) : ChecksumVerification
      raise CorruptPartError.new("no selected checksum entries") if names.empty?

      selected = [] of String
      names.each do |name|
        validate_file_name(name)
        raise CorruptPartError.new("duplicate selected checksum entry") if selected.includes?(name)
        selected << name

        entry = @entries[name]?
        raise CorruptPartError.new("selected checksum entry is missing") unless entry

        file_path = File.join(part_path, name)
        raise CorruptPartError.new("selected checksum file must not be a symbolic link") if File.symlink?(file_path)
        raise CorruptPartError.new("selected checksum file is missing") unless File.file?(file_path)

        actual_size = File.size(file_path)
        raise CorruptPartError.new("selected checksum file size does not match") unless actual_size.to_u64 == entry.not_nil!.physical_size
      rescue ex : IO::Error
        raise CorruptPartError.new(ex.message || "cannot read selected checksum file")
      end

      ChecksumVerification::SizeChecked
    end

    private def initialize(bytes : Bytes)
      raise CorruptPartError.new("checksums.txt exceeds limit") if bytes.size.to_i64 > MAX_CHECKSUM_FILE_BYTES
      header_size = CHECKSUMS_HEADER.bytesize
      raise UnsupportedFormatError.new("unsupported checksums format") if bytes.size < header_size
      header_size.times do |index|
        raise UnsupportedFormatError.new("unsupported checksums format") unless bytes[index] == CHECKSUMS_HEADER.to_slice[index]
      end

      payload = bytes[header_size, bytes.size - header_size]
      decoded = CompressedBlock.decode_all(
        payload,
        MAX_FRAME_COMPRESSED_BYTES,
        MAX_FRAME_DECOMPRESSED_BYTES,
        MAX_PAYLOAD_BYTES
      )
      @entries = parse_payload(decoded)
    end

    private def parse_payload(bytes : Bytes) : Hash(String, Entry)
      cursor = 0
      count, cursor = read_var_uint(bytes, cursor)
      raise CorruptPartError.new("checksums entry count is empty") if count == 0
      raise CorruptPartError.new("checksums entry count exceeds limit") if count > MAX_ENTRIES

      entries = Hash(String, Entry).new
      count.to_i.times do
        name_length, cursor = read_var_uint(bytes, cursor)
        raise CorruptPartError.new("checksums entry name exceeds limit") if name_length > MAX_NAME_BYTES
        name_end = checked_end(cursor, name_length.to_i, bytes.size)
        name = String.new(bytes[cursor, name_length.to_i])
        cursor = name_end
        validate_file_name(name)
        raise CorruptPartError.new("duplicate checksums entry") if entries.has_key?(name)

        physical_size, cursor = read_var_uint(bytes, cursor)
        hash_end = checked_end(cursor, 16, bytes.size)
        file_hash = {
          read_uint64_le(bytes, cursor),
          read_uint64_le(bytes, cursor + 8),
        }
        cursor = hash_end

        compressed_flag = bytes[cursor]? || raise CorruptPartError.new("truncated checksums entry")
        cursor += 1
        compressed : Bool
        uncompressed_size : UInt64?
        uncompressed_hash : {UInt64, UInt64}?
        case compressed_flag
        when 0_u8
          compressed = false
          uncompressed_size = nil
          uncompressed_hash = nil
        when 1_u8
          value, next_cursor = read_var_uint(bytes, cursor)
          cursor = next_cursor
          compressed = true
          uncompressed_size = value
          hash_end = checked_end(cursor, 16, bytes.size)
          uncompressed_hash = {
            read_uint64_le(bytes, cursor),
            read_uint64_le(bytes, cursor + 8),
          }
          cursor = hash_end
        else
          raise CorruptPartError.new("invalid checksums compression flag")
        end
        entries[name] = Entry.new(physical_size, compressed, uncompressed_size, file_hash, uncompressed_hash)
      end

      raise CorruptPartError.new("trailing checksums payload") unless cursor == bytes.size
      entries
    end

    private def read_uint64_le(bytes : Bytes, offset : Int32) : UInt64
      value = 0_u64
      8.times do |byte_index|
        value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
      end
      value
    end

    private def read_var_uint(bytes : Bytes, cursor : Int32) : {UInt64, Int32}
      value = 0_u64
      index = 0
      loop do
        raise CorruptPartError.new("truncated checksums varUInt") if cursor >= bytes.size
        byte = bytes[cursor]
        cursor += 1
        payload = (byte & 0x7f).to_u64
        if index == 9
          raise CorruptPartError.new("checksums varUInt overflows UInt64") if payload > 1 || (byte & 0x80) != 0
        end
        value |= payload << (index * 7)
        if (byte & 0x80) == 0
          if index > 0 && value < (1_u64 << (index * 7))
            raise CorruptPartError.new("non-canonical checksums varUInt")
          end
          return {value, cursor}
        end
        index += 1
        raise CorruptPartError.new("checksums varUInt is too long") if index > 9
      end
    end

    private def checked_end(cursor : Int32, length : Int32, size : Int32) : Int32
      raise CorruptPartError.new("checksums payload is truncated") if cursor < 0 || length < 0 || cursor > size - length
      cursor + length
    end

    private def validate_file_name(name : String)
      raise CorruptPartError.new("checksums file name is empty") if name.empty?
      raise CorruptPartError.new("checksums file name exceeds limit") if name.bytesize > MAX_NAME_BYTES
      raise CorruptPartError.new("checksums file name is absolute") if name.starts_with?("/") || name.starts_with?("\\")

      name.each_byte do |byte|
        raise CorruptPartError.new("checksums file name contains unsafe bytes") if byte < 0x20 || byte == 0x7f || byte == 0
        raise CorruptPartError.new("checksums file name contains a backslash") if byte == '\\'.ord
      end

      components = name.split('/')
      raise CorruptPartError.new("checksums file name contains an empty path component") if components.any?(&.empty?)
      raise CorruptPartError.new("checksums file name escapes its part") if components.any? { |component| component == "." || component == ".." }
    end
  end
end
