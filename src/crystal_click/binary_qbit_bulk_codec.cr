module CrystalClick
  # Shared narrow bridge between nominal QBit rows and the generic recursive
  # bulk lane plan. This admits only a root QBit or Nullable(QBit); it is not a
  # general column/part serializer and does not infer container support.
  module BinaryQBitBulkCodec
    ROLE_SUFFIX        = ".qbit_plane."
    NULL_ROLE_SUFFIX   = ".nulls"
    NESTED_ROLE_SUFFIX = ".nested"

    def self.column_type(type : BinaryDataType) : QBitColumnType?
      case type.tag
      when BinaryDataType::TAG_QBIT
        value_type = type.qbit_type || unsupported_type!
        qbit_column(value_type, false)
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        if child.tag == BinaryDataType::TAG_QBIT
          value_type = child.qbit_type || unsupported_type!
          qbit_column(value_type, true)
        elsif type.contains_qbit?
          unsupported_type!
        else
          nil
        end
      else
        unsupported_type! if type.contains_qbit?
        nil
      end
    end

    # Bound generated role count and exact role-name bytes before callers
    # create Strings, arrays, hashes, or buffers. This is retained metadata
    # preflight, distinct from BinaryCodecBudget's wire-byte accounting.
    def self.preflight_role_metadata!(
      column : QBitColumnType,
      path : String,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      plane_count = column.value_type.plane_count.to_u64
      role_count = checked_add(plane_count, column.nullable ? 1_u64 : 0_u64)
      if role_count > Int32::MAX.to_u64 || role_count > limits.max_elements.to_u64
        fail_limit!(writing, "QBit bulk role count exceeds configured limit")
      end

      total = 0_u64
      if column.nullable
        total = checked_add(path.bytesize.to_u64, NULL_ROLE_SUFFIX.bytesize.to_u64)
      end
      plane_path_bytes = path.bytesize.to_u64
      if column.nullable
        plane_path_bytes = checked_add(plane_path_bytes, NESTED_ROLE_SUFFIX.bytesize.to_u64)
      end
      index = 0_u64
      while index < plane_count
        total = checked_add(total, plane_path_bytes)
        total = checked_add(total, ROLE_SUFFIX.bytesize.to_u64)
        total = checked_add(total, digit_count(index))
        index += 1_u64
      end
      if total > limits.max_bytes.to_u64
        fail_limit!(writing, "QBit bulk role names exceed configured byte limit")
      end
      nil
    end

    def self.roles(
      column : QBitColumnType,
      path : String,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
      writing : Bool = true,
    ) : Array(String)
      preflight_role_metadata!(column, path, limits, writing)
      role_count = column.value_type.plane_count + (column.nullable ? 1 : 0)
      generated = Array(String).new(role_count)
      if column.nullable
        generated << "#{path}#{NULL_ROLE_SUFFIX}"
        path = "#{path}#{NESTED_ROLE_SUFFIX}"
      end
      plane = 0
      while plane < column.value_type.plane_count
        generated << plane_role(path, plane)
        plane += 1
      end
      generated
    end

    # The public role roster is lexically sorted for compatibility with the
    # generic bulk-plan API. Plane traversal instead uses a detached,
    # group-major roster so callers cannot mutate the role-plan names.
    def self.plane_roles(
      column : QBitColumnType,
      path : String,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Array(String)
      preflight_role_metadata!(column, path, limits, writing)
      if column.nullable
        path = "#{path}#{NESTED_ROLE_SUFFIX}"
      end
      planes = Array(String).new(column.value_type.plane_count)
      column.value_type.plane_count.times do |plane|
        planes << plane_role(path, plane)
      end
      planes
    end

    def self.plane_role(path : String, plane : Int32) : String
      "#{path}#{ROLE_SUFFIX}#{plane}"
    end

    # One reusable plane-width scratch buffer is supplied by the encoder, so
    # the per-row path transposition does not allocate raw-row or plane copies.
    def self.append_plane_row(
      value : QBitValue,
      roles : Array(String),
      role_offset : Int32,
      scratch : Bytes,
      &write_byte : String, UInt8 -> Nil
    ) : Nil
      qbit_type = value.type
      validate_scratch!(qbit_type, roles, role_offset, scratch)
      plane = 0
      while plane < qbit_type.plane_count
        QBitPlaneCodec.encode_plane_row(value, plane, scratch)
        role = roles[role_offset + plane]
        qbit_type.plane_width.times do |byte_index|
          yield role, scratch[byte_index]
        end
        plane += 1
      end
      nil
    end

    def self.append_zero_planes(
      column : QBitColumnType,
      roles : Array(String),
      role_offset : Int32,
      scratch : Bytes,
      &write_byte : String, UInt8 -> Nil
    ) : Nil
      qbit_type = column.value_type
      validate_scratch!(qbit_type, roles, role_offset, scratch)
      plane = 0
      while plane < qbit_type.plane_count
        QBitPlaneCodec.encode_zero_plane_row(qbit_type, plane, scratch)
        role = roles[role_offset + plane]
        qbit_type.plane_width.times do |byte_index|
          yield role, scratch[byte_index]
        end
        plane += 1
      end
      nil
    end

    # The input wire lanes and output retained QBit objects are separate
    # budgets: selected plane bytes are charged to the wire budget once by the
    # decoder, while this guard bounds raw rows, plane work buffers, and slots.
    def self.preflight_materialization!(
      column : QBitColumnType,
      rows : UInt64,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      charge = begin
        column.materialization_charge(rows)
      rescue ex : ArgumentError
        fail_limit!(writing, "QBit bulk materialization exceeds its bounded range")
      end
      if charge > limits.max_bytes.to_u64
        fail_limit!(writing, "QBit bulk materialization exceeds configured byte limit")
      end
      nil
    end

    private def self.qbit_column(value_type : QBitType, nullable : Bool) : QBitColumnType
      QBitColumnType.new(value_type, nullable)
    rescue ex : ArgumentError
      unsupported_type!
    end

    private def self.validate_scratch!(
      type : QBitType,
      roles : Array(String),
      role_offset : Int32,
      scratch : Bytes,
    ) : Nil
      if role_offset < 0 || role_offset > roles.size - type.plane_count
        raise UnsupportedFormatError.new("QBit bulk plane roles do not match their descriptor")
      end
      unless scratch.size == type.plane_width
        raise UnsupportedFormatError.new("QBit bulk plane scratch width does not match its descriptor")
      end
      nil
    end

    private def self.digit_count(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("QBit bulk role metadata overflows UInt64")
      end
      left + right
    end

    private def self.fail_limit!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end

    private def self.unsupported_type! : NoReturn
      raise UnsupportedFormatError.new("binary bulk QBit supports only root QBit and Nullable(QBit)")
    end
  end
end
