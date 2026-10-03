module CrystalClick
  # Aggregate owner for retained ObjectDocument results and one active part's
  # logical read workspace. This is a typed logical accounting model, not an
  # allocator or process-RSS bound.
  class ObjectValuesMaterializationBudget
    DEFAULT_LOGICAL_LIMIT = 64_u64 * 1024 * 1024
    DEFAULT_MAX_DEPTH     = 64

    getter logical_limit : UInt64
    getter max_string_bytes : UInt64
    getter max_tuple_cells : UInt64
    getter max_nodes : UInt64
    getter max_elements : UInt64
    getter retained_logical_bytes : UInt64
    getter string_payload_bytes : UInt64
    getter tuple_cells : UInt64
    getter node_count : UInt64
    getter element_count : UInt64

    @base_reserved : Bool

    def initialize(
      @logical_limit : UInt64 = DEFAULT_LOGICAL_LIMIT,
      @max_string_bytes : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES,
      @max_tuple_cells : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_TUPLE_CELLS,
      @max_nodes : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS,
      @max_elements : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS,
      @max_depth : Int32 = DEFAULT_MAX_DEPTH,
    )
      @retained_logical_bytes = 0_u64
      @string_payload_bytes = 0_u64
      @tuple_cells = 0_u64
      @node_count = 0_u64
      @element_count = 0_u64
      @base_reserved = false
    end

    # Reserve the result array, the caller-supplied schema descriptor, and the
    # peak workspace needed by the largest single part before result allocation.
    # This owner admits exactly one successful base reservation.
    def reserve_base(
      rows : UInt64,
      descriptor_bytes : UInt64,
      workspace_bytes : UInt64 = 0_u64,
      descriptor_nodes : UInt64 = 1_u64,
      descriptor_elements : UInt64 = 0_u64,
    ) : Nil
      raise BoundsError.new("Object materialization base was already reserved") if @base_reserved

      array_header = instance_sizeof(Array(OfflineColumnValue)).to_u64
      slot_bytes = checked_multiply(rows, sizeof(OfflineColumnValue).to_u64)
      retained = checked_add(array_header, checked_add(slot_bytes, descriptor_bytes))
      new_elements = checked_add(@element_count, checked_add(rows, descriptor_elements))
      new_nodes = checked_add(1_u64, descriptor_nodes) # result and schema descriptors
      ensure_limit!(new_elements, @max_elements, "Object result element")
      ensure_limit!(new_nodes, @max_nodes, "Object retained descriptor node")
      ensure_logical_peak!(retained, workspace_bytes)

      @retained_logical_bytes = retained
      @element_count = new_elements
      @node_count = new_nodes
      @base_reserved = true
      nil
    end

    # Check a reader's workspace before payload decoding, then recheck it after
    # the complete returned mark has been charged and before retaining it.
    def ensure_workspace(workspace_bytes : UInt64) : Nil
      ensure_base_reserved!
      ensure_logical_peak!(@retained_logical_bytes, workspace_bytes)
      nil
    end

    # Charge one already-decoded document atomically. A failed check leaves all
    # counters unchanged, so callers can safely test and retry a smaller owner.
    def charge_document(document : ObjectDocument, workspace_bytes : UInt64 = 0_u64) : Nil
      ensure_base_reserved!
      usage = measure_document(document, Usage.new)
      admit_usage(usage, workspace_bytes)
    end

    # Admit a complete decoded mark before any of its documents are appended
    # to the retained result. Pending document owners are summed together with
    # the active reader workspace and all counters commit atomically.
    def charge_documents(documents : Array(ObjectDocument), workspace_bytes : UInt64 = 0_u64) : Nil
      ensure_base_reserved!
      usage = Usage.new
      documents.each do |document|
        usage = measure_document(document, usage)
      end
      admit_usage(usage, workspace_bytes)
    end

    private def admit_usage(usage : Usage, workspace_bytes : UInt64) : Nil
      retained = checked_add(@retained_logical_bytes, usage.bytes)
      strings = checked_add(@string_payload_bytes, usage.string_bytes)
      cells = checked_add(@tuple_cells, usage.cells)
      nodes = checked_add(@node_count, usage.nodes)
      elements = checked_add(@element_count, usage.elements)

      ensure_limit!(strings, @max_string_bytes, "Object String payload")
      ensure_limit!(cells, @max_tuple_cells, "Object Tuple cell")
      ensure_limit!(nodes, @max_nodes, "Object recursive node")
      ensure_limit!(elements, @max_elements, "Object recursive element")
      ensure_logical_peak!(retained, workspace_bytes)

      @retained_logical_bytes = retained
      @string_payload_bytes = strings
      @tuple_cells = cells
      @node_count = nodes
      @element_count = elements
      nil
    end

    # Immutable accumulator threaded through recursive measurements so rejected
    # charges cannot mutate the budget's counters before all checks pass.
    private struct Usage
      getter bytes : UInt64
      getter string_bytes : UInt64
      getter cells : UInt64
      getter nodes : UInt64
      getter elements : UInt64

      def initialize(
        @bytes : UInt64 = 0_u64,
        @string_bytes : UInt64 = 0_u64,
        @cells : UInt64 = 0_u64,
        @nodes : UInt64 = 0_u64,
        @elements : UInt64 = 0_u64,
      )
      end

      def add(
        bytes : UInt64 = 0_u64,
        string_bytes : UInt64 = 0_u64,
        cells : UInt64 = 0_u64,
        nodes : UInt64 = 0_u64,
        elements : UInt64 = 0_u64,
      ) : Usage
        Usage.new(
          checked_add(@bytes, bytes),
          checked_add(@string_bytes, string_bytes),
          checked_add(@cells, cells),
          checked_add(@nodes, nodes),
          checked_add(@elements, elements),
        )
      end

      private def checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Object retained owner accounting overflows UInt64") if right > UInt64::MAX - left
        left + right
      end
    end

    private def measure_document(document : ObjectDocument, usage : Usage) : Usage
      path_count = document.path_count.to_u64
      usage = usage.add(
        bytes: instance_sizeof(ObjectDocument).to_u64 +
               instance_sizeof(Hash(String, BinaryValue)).to_u64 +
               instance_sizeof(Array(String)).to_u64,
      )
      usage = usage.add(
        bytes: checked_add(
          checked_multiply(path_count, sizeof(Pointer(String)).to_u64),
          checked_multiply(path_count, hash_entry_bytes),
        ),
        cells: path_count,
        elements: checked_multiply(path_count, 2_u64), # path list and Hash entry
        nodes: checked_add(path_count, 1_u64),         # path String owners and document
      )

      document.path_count.times do |index|
        path_bytes = document.path_byte_size_at(index).to_u64
        usage = usage.add(bytes: checked_add(instance_sizeof(String).to_u64, checked_add(path_bytes, 1_u64)))
        path = document.path_at(index)
        usage = measure_value(document.value_for(path), 1, usage)
      end
      usage
    end

    private def measure_value(value : BinaryValue, depth : Int32, usage : Usage) : Usage
      ensure_depth!(depth)
      children = value.element_count.to_u64
      payload_bytes = value.byte_size.to_u64
      usage = usage.add(
        bytes: checked_add(
          instance_sizeof(BinaryValue).to_u64 + instance_sizeof(Array(BinaryValue)).to_u64,
          checked_add(checked_multiply(children, sizeof(Pointer(BinaryValue)).to_u64), payload_bytes),
        ),
        string_bytes: value.type.tag == BinaryDataType::TAG_STRING ? payload_bytes : 0_u64,
        cells: children,
        nodes: 1_u64,
        elements: children,
      )
      usage = measure_type(value.type, depth, usage)

      value.element_count.times do |index|
        usage = measure_value(value.element_at(index), depth + 1, usage)
      end
      usage
    end

    private def measure_type(type : BinaryDataType, depth : Int32, usage : Usage) : Usage
      ensure_depth!(depth)
      child_count = type.child_count.to_u64
      type_bytes = instance_sizeof(BinaryDataType).to_u64 +
                   instance_sizeof(Array(BinaryDataType)).to_u64 +
                   instance_sizeof(Array(String)).to_u64 +
                   checked_multiply(child_count, sizeof(Pointer(BinaryDataType)).to_u64)
      usage = usage.add(bytes: type_bytes, nodes: 1_u64, elements: child_count)

      if primitive_type?(type.tag)
        name = type.name
        usage = usage.add(
          bytes: checked_add(instance_sizeof(String).to_u64, checked_add(name.bytesize.to_u64, 1_u64)),
          nodes: 1_u64,
        )
      end

      if type.named_tuple?
        usage = usage.add(bytes: checked_multiply(child_count, sizeof(Pointer(String)).to_u64))
        child_count.to_i.times do |index|
          name_bytes = type.field_name_byte_size(index).to_u64
          usage = usage.add(
            bytes: checked_add(instance_sizeof(String).to_u64, checked_add(name_bytes, 1_u64)),
            nodes: 1_u64,
          )
        end
      end

      if temporal = type.temporal_type
        usage = usage.add(bytes: instance_sizeof(BinaryTemporalType).to_u64)
        if zone = temporal.time_zone?
          usage = usage.add(bytes: zone.logical_charge)
        end
      end
      if type.decimal_type
        usage = usage.add(bytes: instance_sizeof(BinaryDecimalType).to_u64)
      end
      if definition = type.enum_definition
        entry_count = definition.size.to_u64
        enum_bytes = checked_add(
          checked_add(
            instance_sizeof(BinaryEnumDefinition).to_u64,
            instance_sizeof(Array(BinaryEnumDefinition::Entry)).to_u64,
          ),
          checked_multiply(entry_count, sizeof(BinaryEnumDefinition::Entry).to_u64),
        )
        definition.size.times do |index|
          label_bytes = definition.label_byte_size(index).to_u64
          enum_bytes = checked_add(
            enum_bytes,
            checked_add(instance_sizeof(String).to_u64, checked_add(label_bytes, 1_u64)),
          )
        end
        usage = usage.add(
          bytes: enum_bytes,
          elements: entry_count,
          nodes: checked_add(entry_count, 1_u64),
        )
      end

      type.child_count.times do |index|
        usage = measure_type(type.child_at(index), depth + 1, usage)
      end
      usage
    end

    private def primitive_type?(tag : UInt8) : Bool
      case tag
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64, BinaryDataType::TAG_UINT128,
           BinaryDataType::TAG_UINT256, BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64, BinaryDataType::TAG_INT128,
           BinaryDataType::TAG_INT256, BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_STRING, BinaryDataType::TAG_UUID, BinaryDataType::TAG_IPV4,
           BinaryDataType::TAG_IPV6, BinaryDataType::TAG_BOOL, BinaryDataType::TAG_BFLOAT16,
           BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32, BinaryDataType::TAG_DATETIME,
           BinaryDataType::TAG_DATETIME_ZONE, BinaryDataType::TAG_DATETIME64,
           BinaryDataType::TAG_DATETIME64_ZONE, BinaryDataType::TAG_TIME
        true
      else
        false
      end
    end

    private def hash_entry_bytes : UInt64
      # String and BinaryValue are reference owners; reserve their two pointer
      # slots plus a fixed control/hash word for each logical Hash entry.
      sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryValue)).to_u64 + 8_u64
    end

    private def ensure_depth!(depth : Int32) : Nil
      raise BoundsError.new("Object retained value exceeds recursive depth limit") if depth <= 0 || depth > @max_depth
    end

    private def ensure_base_reserved! : Nil
      raise BoundsError.new("Object materialization base has not been reserved") unless @base_reserved
      nil
    end

    private def ensure_limit!(value : UInt64, limit : UInt64, label : String) : Nil
      raise BoundsError.new("#{label} limit exceeded") if value > limit
    end

    private def ensure_logical_peak!(retained : UInt64, workspace : UInt64) : Nil
      peak = checked_add(retained, workspace)
      raise BoundsError.new("Object catalog exceeds logical materialization limit") if peak > @logical_limit
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Object retained owner accounting overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Object retained owner accounting overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
