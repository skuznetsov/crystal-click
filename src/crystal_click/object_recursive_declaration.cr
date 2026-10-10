module CrystalClick
  # The Object JSON typed-field recursive grammar and its Object-specific
  # policy. BinaryDataType remains a more general descriptor grammar; in
  # particular, this owner requires String Map keys without changing the
  # general BinaryDataType.map constructor.
  module ObjectRecursiveDeclaration
    DEFAULT_LIMITS = ObjectDocumentCodec::DEFAULT_LIMITS

    # The Object JSON declaration grammar stays the default. Dynamic BinaryBulk
    # callers opt into only the recursive Nested and static Map-key edges owned
    # by that storage route.
    enum AdmissionProfile
      ObjectJson
      DynamicBulk
    end

    struct Metrics
      getter byte_size : UInt64
      getter descriptor_node_count : UInt64
      getter child_edge_count : UInt64
      getter metadata_edge_count : UInt64
      getter enum_entry_count : UInt64
      getter decoded_label_bytes : UInt64
      getter explicit_zone_bytes : UInt64
      getter tuple_name_count : UInt64
      getter tuple_name_bytes : UInt64
      getter max_depth : Int32

      def initialize(
        @byte_size : UInt64,
        @descriptor_node_count : UInt64,
        @child_edge_count : UInt64,
        @metadata_edge_count : UInt64,
        @enum_entry_count : UInt64,
        @decoded_label_bytes : UInt64,
        @explicit_zone_bytes : UInt64,
        @tuple_name_count : UInt64,
        @tuple_name_bytes : UInt64,
        @max_depth : Int32,
      )
      end

      def total_edge_count : UInt64
        ObjectRecursiveDeclaration.checked_add(@child_edge_count, @metadata_edge_count)
      end

      def total_node_count : UInt64
        ObjectRecursiveDeclaration.checked_add(@descriptor_node_count, @metadata_edge_count)
      end
    end

    # Publicly constructible like the leaf preflights. Materialization and
    # accounting always rescan borrowed bytes and compare every advertised
    # aggregate before trusting it. Same-size edits that remain canonical and
    # have identical metrics are intentionally treated as the current source.
    struct Preflight
      getter byte_size : UInt64
      getter descriptor_node_count : UInt64
      getter child_edge_count : UInt64
      getter metadata_edge_count : UInt64
      getter enum_entry_count : UInt64
      getter decoded_label_bytes : UInt64
      getter explicit_zone_bytes : UInt64
      getter tuple_name_count : UInt64
      getter tuple_name_bytes : UInt64
      getter max_depth : Int32
      getter root_depth : Int32
      getter source : Bytes
      getter first : Int32
      getter after : Int32
      getter limits : BinaryCodecLimits
      getter profile : AdmissionProfile

      def initialize(
        @byte_size : UInt64,
        @descriptor_node_count : UInt64,
        @child_edge_count : UInt64,
        @metadata_edge_count : UInt64,
        @enum_entry_count : UInt64,
        @decoded_label_bytes : UInt64,
        @explicit_zone_bytes : UInt64,
        @tuple_name_count : UInt64,
        @tuple_name_bytes : UInt64,
        @max_depth : Int32,
        @root_depth : Int32,
        @source : Bytes,
        @first : Int32,
        @after : Int32,
        @limits : BinaryCodecLimits,
        @profile : AdmissionProfile = AdmissionProfile::ObjectJson,
      )
      end

      def metrics : Metrics
        Metrics.new(
          @byte_size,
          @descriptor_node_count,
          @child_edge_count,
          @metadata_edge_count,
          @enum_entry_count,
          @decoded_label_bytes,
          @explicit_zone_bytes,
          @tuple_name_count,
          @tuple_name_bytes,
          @max_depth,
        )
      end

      # Charge all descriptor descendants and metadata before the caller
      # allocates any corresponding BinaryDataType tree.
      def account(budget : BinaryCodecBudget) : Nil
        ObjectRecursiveDeclaration.account_slice(self, budget)
      end

      # Revalidate borrowed source and the public aggregate fields before any
      # proportional type/name allocation. The original caller limits remain
      # attached to this preflight, including when they exceed defaults.
      def materialize : BinaryDataType
        ObjectRecursiveDeclarationText.materialize_preflight(self)
      end
    end

    # Mutable accumulator shared by recursive calls. A struct would be copied
    # at each method boundary in Crystal and silently lose descendant charges.
    class ScanTotals
      getter nodes : UInt64
      getter child_edges : UInt64
      getter metadata_edges : UInt64
      getter enum_entries : UInt64
      getter label_bytes : UInt64
      getter zone_bytes : UInt64
      getter tuple_names : UInt64
      getter tuple_name_bytes : UInt64
      getter max_depth : Int32

      def initialize
        @nodes = 0_u64
        @child_edges = 0_u64
        @metadata_edges = 0_u64
        @enum_entries = 0_u64
        @label_bytes = 0_u64
        @zone_bytes = 0_u64
        @tuple_names = 0_u64
        @tuple_name_bytes = 0_u64
        @max_depth = 0_i32
      end

      def visit_node(depth : Int32, limits : BinaryCodecLimits) : Nil
        ObjectRecursiveDeclaration.ensure_depth(depth, limits)
        ObjectRecursiveDeclaration.ensure_count(@nodes, 1_u64, limits.max_nodes.to_u64, "node")
        @nodes += 1_u64
        @max_depth = depth if depth > @max_depth
      end

      def child_edge(limits : BinaryCodecLimits) : Nil
        ObjectRecursiveDeclaration.ensure_count(@child_edges + @metadata_edges, 1_u64, limits.max_elements.to_u64, "element")
        @child_edges += 1_u64
      end

      def enum_metadata(count : UInt64, label_bytes : UInt64, depth : Int32, limits : BinaryCodecLimits) : Nil
        metadata(count, depth, limits)
        @enum_entries = ObjectRecursiveDeclaration.checked_add(@enum_entries, count)
        @label_bytes = ObjectRecursiveDeclaration.checked_add(@label_bytes, label_bytes)
      end

      def tuple_metadata(count : UInt64, name_bytes : UInt64, depth : Int32, limits : BinaryCodecLimits) : Nil
        metadata(count, depth, limits)
        @tuple_names = ObjectRecursiveDeclaration.checked_add(@tuple_names, count)
        @tuple_name_bytes = ObjectRecursiveDeclaration.checked_add(@tuple_name_bytes, name_bytes)
      end

      private def metadata(count : UInt64, depth : Int32, limits : BinaryCodecLimits) : Nil
        ObjectRecursiveDeclaration.ensure_depth(depth, limits)
        ObjectRecursiveDeclaration.ensure_count(@child_edges + @metadata_edges, count, limits.max_elements.to_u64, "element")
        ObjectRecursiveDeclaration.ensure_count(@nodes, count, limits.max_nodes.to_u64, "node")
        @metadata_edges += count
        @nodes += count
        @max_depth = depth if depth > @max_depth
      end

      def metrics(byte_size : UInt64) : Metrics
        Metrics.new(
          byte_size,
          @nodes - @metadata_edges,
          @child_edges,
          @metadata_edges,
          @enum_entries,
          @label_bytes,
          @zone_bytes,
          @tuple_names,
          @tuple_name_bytes,
          @max_depth,
        )
      end

      def add_zone_bytes(count : UInt64) : Nil
        @zone_bytes = ObjectRecursiveDeclaration.checked_add(@zone_bytes, count)
      end
    end

    def self.preflight_slice(
      bytes : Bytes,
      first : Int32,
      after : Int32,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      root_depth : Int = 1,
      profile : AdmissionProfile = AdmissionProfile::ObjectJson,
    ) : Preflight?
      ObjectRecursiveDeclarationText.preflight_slice(bytes, first, after, limits, root_depth, profile)
    end

    # Bounded direct-descriptor walk used before schema path/declaration
    # copies. root_depth=1 is for standalone helper calls; schema owners pass
    # their actual Object path depth (2).
    def self.measure_descriptor(
      type : BinaryDataType,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      root_depth : Int = 1,
    ) : Metrics?
      raise UnsupportedFormatError.new("binary codec depth limit exceeded") if root_depth <= 0 || root_depth > Int32::MAX
      totals = ScanTotals.new
      byte_size = measure_type(type, root_depth.to_i32, limits, totals, true) || return nil
      metadata_bytes = checked_add(totals.tuple_name_bytes, checked_add(totals.label_bytes, totals.zone_bytes))
      raise UnsupportedFormatError.new("binary codec byte limit exceeded") if checked_add(byte_size, checked_multiply(metadata_bytes, 2_u64)) > limits.max_bytes.to_u64
      totals.metrics(byte_size)
    end

    # Charge the descriptor's descendants/metadata into an existing schema
    # budget. Its root is already represented by the field/argument node.
    def self.account_descriptor(
      type : BinaryDataType,
      budget : BinaryCodecBudget,
      limits : BinaryCodecLimits,
      root_depth : Int = 2,
    ) : Metrics?
      metrics = measure_descriptor(type, limits, root_depth) || return nil
      account_metrics(metrics, budget)
      charge_descriptor_nodes(type, budget, root_depth.to_i32)
      metrics
    end

    def self.byte_size_for(
      type : BinaryDataType,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      root_depth : Int = 1,
    ) : UInt64?
      measure_descriptor(type, limits, root_depth).try(&.byte_size)
    end

    # Object's declared LowCardinality intersection is narrower than either
    # the general Object leaf grammar or the source LC grammar by itself.
    # Keep the policy here so descriptor and borrowed-text paths share it.
    def self.low_cardinality_child_admitted?(type : BinaryDataType) : Bool
      return false unless type.tag == BinaryDataType::TAG_LOW_CARDINALITY && type.child_count == 1

      child = type.child_at(0)
      leaf = if child.tag == BinaryDataType::TAG_NULLABLE
               return false unless child.child_count == 1
               child.child_at(0)
             else
               child
             end
      return false unless leaf.child_count == 0 && low_cardinality_leaf_tag_admitted?(leaf.tag)
      return false unless BinaryLowCardinalityTypePolicy.admitted_child?(child)

      !ObjectTypedFieldType.leaf_byte_size_for(leaf).nil?
    end

    # The parser's scalar resolution carries a tag but deliberately does not
    # materialize a BinaryDataType before aggregate budget admission.
    def self.low_cardinality_leaf_tag_admitted?(tag : UInt8) : Bool
      return true if tag >= BinaryDataType::TAG_UINT8 && tag <= BinaryDataType::TAG_FLOAT64

      case tag
      when BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
           BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_STRING, BinaryDataType::TAG_FIXED_STRING,
           BinaryDataType::TAG_UUID, BinaryDataType::TAG_IPV4,
           BinaryDataType::TAG_IPV6, BinaryDataType::TAG_BOOL,
           BinaryDataType::TAG_TIME
        true
      else
        false
      end
    end

    # Validate the whole tree before writing anything. This matters for IOs
    # with observable side effects and keeps a rejected deep tree from leaving
    # a partial declaration behind.
    def self.append_name(
      io : IO,
      type : BinaryDataType,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      root_depth : Int = 1,
    ) : Nil
      measure_descriptor(type, limits, root_depth) ||
        raise ArgumentError.new("typed JSON schema admits only supported Object recursive types")
      append_type_name(io, type)
      nil
    end

    def self.account_slice(preflight : Preflight, budget : BinaryCodecBudget) : Nil
      ObjectRecursiveDeclarationText.account_slice(preflight, budget)
    end

    def self.validate_tuple_names(bytes : Bytes, first : Int32, after : Int32, depth : Int32, limits : BinaryCodecLimits) : Nil
      ObjectRecursiveDeclarationText.validate_tuple_names(bytes, first, after, depth, limits)
    end

    def self.materialize_slice(bytes : Bytes, first : Int32, after : Int32, depth : Int32, limits : BinaryCodecLimits) : BinaryDataType
      ObjectRecursiveDeclarationText.materialize_slice(bytes, first, after, depth, limits)
    end

    private def self.measure_type(
      type : BinaryDataType,
      depth : Int32,
      limits : BinaryCodecLimits,
      totals : ScanTotals,
      allow_declared_dynamic : Bool,
    ) : UInt64?
      totals.visit_node(depth, limits)
      if type.tag == BinaryDataType::TAG_DYNAMIC
        return nil unless allow_declared_dynamic
        return ObjectDeclaredDynamicDeclaration.byte_size_for(type)
      end
      case type.tag
      when BinaryDataType::TAG_ARRAY
        return nil unless type.child_count == 1
        totals.child_edge(limits)
        child_size = measure_type(type.child_at(0), depth + 1, limits, totals, allow_declared_dynamic) || return nil
        checked_add("Array(".bytesize.to_u64 + 1_u64, child_size)
      when BinaryDataType::TAG_NULLABLE
        return nil unless type.child_count == 1
        child = type.child_at(0)
        return nil if child.tag == BinaryDataType::TAG_ARRAY || child.tag == BinaryDataType::TAG_MAP ||
                      child.tag == BinaryDataType::TAG_NULLABLE || child.tag == BinaryDataType::TAG_LOW_CARDINALITY ||
                      child.tag == BinaryDataType::TAG_VARIANT || child.tag == BinaryDataType::TAG_DYNAMIC ||
                      child.tag == BinaryDataType::TAG_NESTED
        totals.child_edge(limits)
        child_size = measure_type(child, depth + 1, limits, totals, allow_declared_dynamic) || return nil
        checked_add("Nullable(".bytesize.to_u64 + 1_u64, child_size)
      when BinaryDataType::TAG_LOW_CARDINALITY
        return nil unless low_cardinality_child_admitted?(type)
        totals.child_edge(limits)
        child_size = measure_type(type.child_at(0), depth + 1, limits, totals, false) || return nil
        checked_add("LowCardinality(".bytesize.to_u64 + 1_u64, child_size)
      when BinaryDataType::TAG_MAP
        return nil unless type.child_count == 2
        key = type.child_at(0)
        return nil unless key.tag == BinaryDataType::TAG_STRING
        totals.child_edge(limits)
        key_size = measure_type(key, depth + 1, limits, totals, false) || return nil
        totals.child_edge(limits)
        value_size = measure_type(type.child_at(1), depth + 1, limits, totals, allow_declared_dynamic) || return nil
        checked_add(checked_add("Map(".bytesize.to_u64, key_size), checked_add(", ".bytesize.to_u64 + value_size, 1_u64))
      when BinaryDataType::TAG_NESTED
        return nil unless type.child_count == 1
        tuple = type.child_at(0)
        return nil unless tuple.tag == BinaryDataType::TAG_NAMED_TUPLE && tuple.child_count > 0
        # Nested's implicit named Tuple is a distinct descriptor node and edge.
        # Its descendants cannot contain Dynamic even when an enclosing Object
        # JSON path admits Dynamic at other static locations.
        totals.child_edge(limits)
        tuple_size = measure_type(tuple, depth + 1, limits, totals, false) || return nil
        # Nested(field ...) and Tuple(field ...) share the same body; only the
        # wrapper spelling differs by one byte (Nested vs Tuple).
        checked_add(tuple_size, 1_u64)
      when BinaryDataType::TAG_VARIANT
        count = type.child_count
        return nil if count == 0 || count > BinaryVariantRoster::MAX_ARMS
        total = "Variant(".bytesize.to_u64 + 1_u64
        count.times do |index|
          arm = type.child_at(index)
          return nil if arm.tag == BinaryDataType::TAG_NOTHING ||
                        arm.tag == BinaryDataType::TAG_NULLABLE ||
                        arm.tag == BinaryDataType::TAG_VARIANT ||
                        arm.tag == BinaryDataType::TAG_DYNAMIC
          if arm.tag == BinaryDataType::TAG_LOW_CARDINALITY && arm.child_count == 1 &&
             arm.child_at(0).tag == BinaryDataType::TAG_NULLABLE
            return nil
          end
          totals.child_edge(limits)
          arm_size = measure_type(arm, depth + 1, limits, totals, allow_declared_dynamic) || return nil
          total = checked_add(total, 2_u64) if index > 0
          total = checked_add(total, arm_size)
        end
        total
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        named = type.tag == BinaryDataType::TAG_NAMED_TUPLE
        return nil if named && count == 0
        total = "Tuple()".bytesize.to_u64
        if count > 0
          total = "Tuple(".bytesize.to_u64 + 1_u64
          count.times do |index|
            total = checked_add(total, 2_u64) if index > 0
            if named
              name_bytes = type.field_name_byte_size(index)
              return nil if name_bytes <= 0
              rendered_name_size = ObjectTupleFieldName.rendered_size(type, index)
              totals.tuple_metadata(1_u64, name_bytes.to_u64, depth, limits)
              total = checked_add(total, rendered_name_size.to_u64)
              total = checked_add(total, 1_u64)
            end
            totals.child_edge(limits)
            child_size = measure_type(type.child_at(index), depth + 1, limits, totals, allow_declared_dynamic) || return nil
            total = checked_add(total, child_size)
          end
        end
        total
      else
        return nil if type.tag == BinaryDataType::TAG_DYNAMIC
        size = ObjectTypedFieldType.leaf_byte_size_for(type) || return nil
        if type.tag == BinaryDataType::TAG_ENUM8 || type.tag == BinaryDataType::TAG_ENUM16
          definition = type.enum_definition || return nil
          totals.enum_metadata(definition.size.to_u64, enum_label_bytes(definition), depth, limits)
        end
        if temporal = type.temporal_type
          if zone = temporal.time_zone?
            totals.add_zone_bytes(zone.name_byte_size.to_u64)
          end
        end
        size
      end
    end

    private def self.account_metrics(metrics : Metrics, budget : BinaryCodecBudget) : Nil
      budget.preflight_children(metrics.total_edge_count) if metrics.total_edge_count > 0_u64
      nil
    end

    private def self.charge_descriptor_nodes(type : BinaryDataType, budget : BinaryCodecBudget, depth : Int32) : Nil
      if type.tag == BinaryDataType::TAG_ENUM8 || type.tag == BinaryDataType::TAG_ENUM16
        type.metadata_entry_count.times { budget.visit_node(depth) }
      end
      if type.tag == BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times { budget.visit_node(depth) }
      end
      type.child_count.times do |index|
        child_depth = depth + 1
        budget.visit_node(child_depth)
        charge_descriptor_nodes(type.child_at(index), budget, child_depth)
      end
      nil
    end

    private def self.append_type_name(io : IO, type : BinaryDataType) : Nil
      case type.tag
      when BinaryDataType::TAG_ARRAY
        io << "Array("
        append_type_name(io, type.child_at(0))
        io << ')'
      when BinaryDataType::TAG_NESTED
        tuple = type.child_at(0)
        io << "Nested("
        tuple.child_count.times do |index|
          io << ", " unless index == 0
          ObjectTupleFieldName.append(io, tuple, index)
          io << ' '
          append_type_name(io, tuple.child_at(index))
        end
        io << ')'
      when BinaryDataType::TAG_NULLABLE
        io << "Nullable("
        append_type_name(io, type.child_at(0))
        io << ')'
      when BinaryDataType::TAG_LOW_CARDINALITY
        io << "LowCardinality("
        append_type_name(io, type.child_at(0))
        io << ')'
      when BinaryDataType::TAG_MAP
        io << "Map("
        append_type_name(io, type.child_at(0))
        io << ", "
        append_type_name(io, type.child_at(1))
        io << ')'
      when BinaryDataType::TAG_VARIANT
        io << "Variant("
        type.child_count.times do |index|
          io << ", " unless index == 0
          append_type_name(io, type.child_at(index))
        end
        io << ')'
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        io << "Tuple("
        type.child_count.times do |index|
          io << ", " unless index == 0
          if type.named_tuple?
            ObjectTupleFieldName.append(io, type, index)
            io << ' '
          end
          append_type_name(io, type.child_at(index))
        end
        io << ')'
      else
        if type.tag == BinaryDataType::TAG_DYNAMIC
          ObjectDeclaredDynamicDeclaration.append_name(io, type)
        else
          ObjectTypedFieldType.append_leaf_name(io, type)
        end
      end
      nil
    end

    private def self.enum_label_bytes(definition : BinaryEnumDefinition) : UInt64
      total = 0_u64
      definition.size.times do |index|
        total = checked_add(total, definition.label_byte_size(index).to_u64)
      end
      total
    end

    def self.checked_add(left : UInt64, right : UInt64) : UInt64
      raise UnsupportedFormatError.new("JSON schema size overflows UInt64") if left > UInt64::MAX - right
      left + right
    end

    def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise UnsupportedFormatError.new("JSON schema size overflows UInt64") if right != 0_u64 && left > UInt64::MAX // right
      left * right
    end

    def self.ensure_depth(depth : Int32, limits : BinaryCodecLimits) : Nil
      if depth <= 0 || depth > limits.max_depth
        raise UnsupportedFormatError.new("binary codec depth limit exceeded")
      end
    end

    def self.ensure_count(current : UInt64, additional : UInt64, limit : UInt64, kind : String) : Nil
      if current > limit || additional > limit - current
        raise UnsupportedFormatError.new("binary codec #{kind} limit exceeded")
      end
    end

    def self.same_metrics?(left : Metrics, right : Metrics) : Bool
      left.byte_size == right.byte_size &&
        left.descriptor_node_count == right.descriptor_node_count &&
        left.child_edge_count == right.child_edge_count &&
        left.metadata_edge_count == right.metadata_edge_count &&
        left.enum_entry_count == right.enum_entry_count &&
        left.decoded_label_bytes == right.decoded_label_bytes &&
        left.explicit_zone_bytes == right.explicit_zone_bytes &&
        left.tuple_name_count == right.tuple_name_count &&
        left.tuple_name_bytes == right.tuple_name_bytes &&
        left.max_depth == right.max_depth
    end
  end
end
