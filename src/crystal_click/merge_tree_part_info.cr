module CrystalClick
  # The bounded physical identity encoded by a modern MergeTree part name.
  #
  # This is deliberately only name metadata.  It does not infer whether a
  # part is active, outdated, or otherwise authoritative for a table.
  struct MergeTreePartInfo
    include Comparable(MergeTreePartInfo)

    MAX_NAME_BYTES   =             255
    MAX_LEVEL        = 999_999_999_u32
    LEGACY_MAX_LEVEL = UInt32::MAX

    getter partition_id : String
    getter min_block : Int64
    getter max_block : Int64
    getter level : UInt32
    getter mutation : UInt32
    getter name : String

    def self.parse(name : String) : MergeTreePartInfo?
      return nil if name.empty? || name.bytesize > MAX_NAME_BYTES
      return nil if name.starts_with?("_") || name.ends_with?("_") || name.includes?("__")

      fields = name.split('_')
      return nil unless fields.size == 4 || fields.size == 5

      partition_id = fields[0]
      return nil unless valid_partition_id?(partition_id)

      min_block = parse_signed_int64(fields[1])
      max_block = parse_signed_int64(fields[2])
      level = parse_uint32(fields[3])
      return nil unless min_block && max_block && level
      return nil if min_block.not_nil! > max_block.not_nil!

      # ClickHouse used UInt32::MAX for virtual parts before 21.6 and now
      # normalizes that legacy spelling for containment and comparison while
      # preserving the original directory name.
      normalized_level = level == LEGACY_MAX_LEVEL ? MAX_LEVEL : level

      mutation = if fields.size == 5
                   parse_uint32(fields[4])
                 else
                   0_u32
                 end
      return nil unless mutation

      new(
        partition_id,
        min_block.not_nil!,
        max_block.not_nil!,
        normalized_level,
        mutation,
        name
      )
    end

    def self.part_like?(name : String) : Bool
      return false if name.empty?
      return false unless name.includes?('_')
      name.split('_').size >= 4
    end

    def initialize(
      @partition_id : String,
      @min_block : Int64,
      @max_block : Int64,
      @level : UInt32,
      @mutation : UInt32,
      @name : String,
    )
    end

    def patch? : Bool
      @partition_id.starts_with?("patch-")
    end

    # MergeTree block ranges are inclusive.  Parts from different partitions
    # are disjoint even when their numeric ranges are equal.
    def overlaps?(other : MergeTreePartInfo) : Bool
      @partition_id == other.partition_id &&
        @min_block <= other.max_block &&
        other.min_block <= @max_block
    end

    def <=>(other : MergeTreePartInfo) : Int32
      comparison = @partition_id <=> other.partition_id
      return comparison unless comparison == 0

      comparison = @min_block <=> other.min_block
      return comparison unless comparison == 0

      comparison = @max_block <=> other.max_block
      return comparison unless comparison == 0

      comparison = @level <=> other.level
      return comparison unless comparison == 0

      comparison = compare_mutation(@mutation, other.mutation)
      return comparison unless comparison == 0

      @name <=> other.name
    end

    private def self.valid_partition_id?(partition_id : String) : Bool
      return false if partition_id.empty?
      partition_id.each_byte do |byte|
        valid = byte >= 'a'.ord && byte <= 'z'.ord ||
                byte >= 'A'.ord && byte <= 'Z'.ord ||
                byte >= '0'.ord && byte <= '9'.ord ||
                byte == '-'.ord
        return false unless valid
      end
      true
    end

    private def self.parse_uint32(text : String) : UInt32?
      value = parse_unsigned(text, UInt32::MAX.to_u64)
      value.try(&.to_u32)
    end

    private def self.parse_signed_int64(text : String) : Int64?
      return nil if text.empty?
      negative = text.starts_with?('-')
      digits = negative ? text[1..] : text
      return nil if digits.empty?
      return nil if digits.size > 1 && digits.starts_with?('0')

      limit = negative ? Int64::MAX.to_u64 + 1_u64 : Int64::MAX.to_u64
      magnitude = parse_unsigned(digits, limit)
      return nil unless magnitude
      return Int64::MIN if negative && magnitude == Int64::MAX.to_u64 + 1_u64
      negative ? -magnitude.not_nil!.to_i64 : magnitude.not_nil!.to_i64
    end

    private def self.parse_unsigned(text : String, limit : UInt64) : UInt64?
      return nil if text.empty?
      return nil if text.size > 1 && text.starts_with?('0')

      value = 0_u64
      text.each_byte do |byte|
        return nil unless byte >= '0'.ord && byte <= '9'.ord
        digit = (byte - '0'.ord).to_u64
        return nil if value > (limit - digit) // 10
        value = value * 10 + digit
      end
      value
    end

    private def compare_mutation(left : UInt32, right : UInt32) : Int32
      left <=> right
    end
  end
end
