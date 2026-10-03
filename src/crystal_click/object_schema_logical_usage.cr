module CrystalClick
  # Bounded logical estimate for an Object schema retained by catalog value
  # materialization. This models descriptor owners and their metadata; it is
  # not an allocator, pre-decode, or process-RSS guarantee.
  module ObjectSchemaLogicalUsage
    struct Estimate
      getter bytes : UInt64
      getter nodes : UInt64
      getter elements : UInt64

      def initialize(@bytes : UInt64, @nodes : UInt64, @elements : UInt64)
      end
    end

    private struct TreeUsage
      getter bytes : UInt64
      getter nodes : UInt64
      getter elements : UInt64

      def initialize(@bytes : UInt64 = 0_u64, @nodes : UInt64 = 0_u64, @elements : UInt64 = 0_u64)
      end

      def add(bytes : UInt64 = 0_u64, nodes : UInt64 = 0_u64, elements : UInt64 = 0_u64) : TreeUsage
        TreeUsage.new(
          checked_add(@bytes, bytes),
          checked_add(@nodes, nodes),
          checked_add(@elements, elements),
        )
      end

      private def checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Object catalog logical charge overflows UInt64") if right > UInt64::MAX - left
        left + right
      end
    end

    # `fields` is the detached typed-path snapshot already used by the caller.
    # The byte estimate preserves the prior conservative scalar baseline,
    # including its doubled schema/path/type-name charge. Recursive descriptor
    # owners are then added once because that snapshot shares the type objects.
    # Nodes count the schema, path strings, type descriptors, tuple-name
    # strings, and enum owner/label strings. Elements count the path-list and
    # map slots, descriptor child edges, tuple-name slots, and enum entries.
    def self.measure(
      schema : ObjectDocumentSchema,
      fields : Hash(String, BinaryDataType),
    ) : Estimate
      field_count = fields.size.to_u64
      bytes = instance_sizeof(ObjectDocumentSchema).to_u64
      bytes = checked_add(bytes, instance_sizeof(Hash(String, BinaryDataType)).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, instance_sizeof(String).to_u64 + schema.declaration_byte_size.to_u64 + 1_u64)
      bytes = checked_add(bytes, checked_multiply(field_count, sizeof(Pointer(String)).to_u64))
      bytes = checked_add(
        bytes,
        checked_multiply(field_count, sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryDataType)).to_u64 + 8_u64),
      )

      nodes = checked_add(1_u64, checked_multiply(field_count, 2_u64)) # schema, each path, each root descriptor
      elements = checked_multiply(field_count, 2_u64)                  # typed-path list and Hash slot
      tree_bytes = 0_u64

      fields.each do |path, type|
        type_name_bytes = ObjectTypedFieldType.byte_size_for(type, schema.limits, 2) ||
                          raise UnsupportedFormatError.new("Object catalog schema descriptor has no canonical type size")
        bytes = checked_add(bytes, instance_sizeof(String).to_u64 + path.bytesize.to_u64 + 1_u64)
        bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(BinaryDataType)).to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
        # This keeps the old leaf charge without materializing type.name. For a
        # recursive root, byte_size_for measures the same canonical spelling.
        bytes = checked_add(bytes, instance_sizeof(String).to_u64 + type_name_bytes + 1_u64)
        if temporal = type.temporal_type
          bytes = checked_add(bytes, instance_sizeof(BinaryTemporalType).to_u64)
          if zone = temporal.time_zone?
            bytes = checked_add(bytes, zone.logical_charge)
          end
        end

        # The schema/path owner begins at depth 1, so an Object field type is
        # rooted at depth 2 in the same budget convention as schema preflight.
        tree = measure_tree(type, schema.limits, 2, false)
        tree_bytes = checked_add(tree_bytes, tree.bytes)
        nodes = checked_add(nodes, tree.nodes)
        elements = checked_add(elements, tree.elements)
      end

      doubled_baseline = checked_multiply(bytes, 2_u64)
      Estimate.new(checked_add(doubled_baseline, tree_bytes), nodes, elements)
    end

    # The root's descriptor header, field arrays, canonical name, and temporal
    # owner are part of the preserved baseline above. This walk adds its child
    # edges and metadata, then charges each descendant descriptor exactly once.
    private def self.measure_tree(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      depth : Int32,
      include_descriptor : Bool,
    ) : TreeUsage
      ensure_depth!(depth, limits)
      child_count = type.child_count.to_u64
      usage = TreeUsage.new(
        bytes: checked_multiply(child_count, sizeof(Pointer(BinaryDataType)).to_u64),
        elements: child_count,
      )

      if include_descriptor
        descriptor_bytes = instance_sizeof(BinaryDataType).to_u64
        descriptor_bytes = checked_add(descriptor_bytes, instance_sizeof(Array(BinaryDataType)).to_u64)
        descriptor_bytes = checked_add(descriptor_bytes, instance_sizeof(Array(String)).to_u64)
        usage = usage.add(bytes: descriptor_bytes, nodes: 1_u64)

        if primitive_type?(type.tag)
          name_bytes = ObjectTypedFieldType.byte_size_for(type, limits, depth) ||
                       raise UnsupportedFormatError.new("Object catalog primitive descriptor has no canonical type size")
          usage = usage.add(bytes: instance_sizeof(String).to_u64 + name_bytes + 1_u64)
        end

        if temporal = type.temporal_type
          usage = usage.add(bytes: instance_sizeof(BinaryTemporalType).to_u64)
          if zone = temporal.time_zone?
            usage = usage.add(bytes: zone.logical_charge)
          end
        end
      end

      if type.named_tuple?
        usage = usage.add(
          bytes: checked_multiply(child_count, sizeof(Pointer(String)).to_u64),
          elements: child_count,
        )
        type.child_count.times do |index|
          name_bytes = type.field_name_byte_size(index).to_u64
          usage = usage.add(
            bytes: instance_sizeof(String).to_u64 + name_bytes + 1_u64,
            nodes: 1_u64,
          )
        end
      end

      if type.decimal_type
        # The decimal parameters are owned by the descriptor but were absent
        # from the old catalog estimate.
        usage = usage.add(bytes: instance_sizeof(BinaryDecimalType).to_u64)
      end

      if definition = type.enum_definition
        entry_count = definition.size.to_u64
        enum_bytes = instance_sizeof(BinaryEnumDefinition).to_u64
        enum_bytes = checked_add(enum_bytes, instance_sizeof(Array(BinaryEnumDefinition::Entry)).to_u64)
        enum_bytes = checked_add(enum_bytes, checked_multiply(entry_count, sizeof(BinaryEnumDefinition::Entry).to_u64))
        definition.size.times do |index|
          label_bytes = definition.label_byte_size(index).to_u64
          enum_bytes = checked_add(enum_bytes, instance_sizeof(String).to_u64 + label_bytes + 1_u64)
        end
        usage = usage.add(
          bytes: enum_bytes,
          nodes: checked_add(entry_count, 1_u64),
          elements: entry_count,
        )
      end

      type.child_count.times do |index|
        child = type.child_at(index)
        child_usage = measure_tree(child, limits, depth + 1, true)
        usage = usage.add(bytes: child_usage.bytes, nodes: child_usage.nodes, elements: child_usage.elements)
      end
      usage
    end

    private def self.primitive_type?(tag : UInt8) : Bool
      case tag
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64, BinaryDataType::TAG_UINT128,
           BinaryDataType::TAG_UINT256, BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64, BinaryDataType::TAG_INT128,
           BinaryDataType::TAG_INT256, BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_STRING, BinaryDataType::TAG_UUID, BinaryDataType::TAG_IPV4,
           BinaryDataType::TAG_IPV6, BinaryDataType::TAG_BOOL, BinaryDataType::TAG_BFLOAT16,
           BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32, BinaryDataType::TAG_TIME
        true
      else
        false
      end
    end

    private def self.ensure_depth!(depth : Int32, limits : BinaryCodecLimits) : Nil
      if depth <= 0 || depth > limits.max_depth
        raise BoundsError.new("Object catalog schema exceeds recursive depth limit")
      end
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Object catalog logical charge overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Object catalog logical charge overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
