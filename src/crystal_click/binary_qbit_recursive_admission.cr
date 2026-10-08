module CrystalClick
  # The one static composition bridge for QBit in the recursive bulk visitor.
  # Admission is deliberately limited to Array^n(QBit) and
  # Array^n(Nullable(QBit)); it does not authorize other QBit wrappers.
  module BinaryQBitRecursiveAdmission
    # Reuses the root codec's existing narrow bridge except for the cached,
    # exact Array-chain shape admitted above. Call after the normal type-tree
    # budget validation when the descriptor may be caller supplied.
    def self.validate_static_type!(type : BinaryDataType) : Nil
      return nil if type.qbit_array_chain?

      BinaryQBitBulkCodec.column_type(type)
      nil
    end

    def self.static_array_site(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : StaticArraySite?
      return nil unless type.qbit_array_chain?

      current = type
      array_depth = 0
      while current.tag == BinaryDataType::TAG_ARRAY
        array_depth += 1
        current = current.child_at(0)
      end

      nullable = false
      if current.tag == BinaryDataType::TAG_NULLABLE
        nullable = true
        current = current.child_at(0)
      end
      unless current.tag == BinaryDataType::TAG_QBIT
        raise UnsupportedFormatError.new("recursive QBit site is outside the admitted Array chain")
      end
      qbit_type = current.qbit_type || raise(UnsupportedFormatError.new("recursive QBit site is missing its nominal type"))
      column = QBitColumnType.new(qbit_type, nullable)

      # Account for every Array size role, nullable map, and QBit plane before
      # building any per-occurrence path or role-name Strings.
      BinaryQBitBulkCodec.preflight_recursive_role_metadata!(
        column,
        "root".bytesize.to_u64,
        array_depth.to_u64,
        limits,
        writing,
      )

      size_roles = Array(String).new(array_depth)
      path = "root"
      array_depth.times do
        size_roles << "#{path}#{BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX}"
        path = "#{path}#{BinaryQBitBulkCodec::ARRAY_PATH_SUFFIX}"
      end
      nullable_role = nullable ? "#{path}#{BinaryQBitBulkCodec::NULL_ROLE_SUFFIX}" : nil
      planes = BinaryQBitBulkCodec.plane_roles(column, path, limits, writing)
      StaticArraySite.new(column, size_roles, nullable_role, planes)
    end
  end
end
