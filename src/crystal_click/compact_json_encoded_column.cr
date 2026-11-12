module CrystalClick
  # Detached per-mark callback bytes for one schema-bound static JSON input.
  # Logical Object/Dynamic codecs produce the fragments; the normal Compact
  # writer remains the only owner of physical marks and assembly.
  class CompactJsonEncodedColumn
    private class ValuePlanNode
      getter schema : StorageColumnSchema
      getter site_index : Int32
      getter children : Array(ValuePlanNode)

      def initialize(@schema : StorageColumnSchema, @site_index : Int32, @children : Array(ValuePlanNode))
      end
    end

    private class SiteCursor
      property json : Int32 = 0
      property array : Int32 = 0
      property uint8 : Int32 = 0
      property bulk : Int32 = 0
    end

    @plan : CompactJsonCallbackPlan
    @callback_names : Array(String)
    @callback_fragments : Array(Array(Bytes))
    @callback_relocations : Array(Array(ObjectSharedInlineCallbackRelocation))?
    @structure_prefixes : Array(Tuple(Bytes, Bytes)?)
    @mark_count : Int32

    private def initialize(plan : CompactJsonCallbackPlan, budget : BinaryCodecBudget)
      unless budget.writing?
        raise ArgumentError.new("Compact JSON encoding requires a write-direction codec budget")
      end
      plan.validate_bound_input!
      @plan = plan
      @mark_count = plan.bound_mark_count
      @callback_relocations = nil
      if @mark_count <= 0
        raise UnsupportedFormatError.new("Compact JSON writer requires at least one physical mark")
      end

      callback_count = plan.callback_event_count
      if callback_count == 0
        raise UnsupportedFormatError.new("Compact JSON callback plan has no physical callbacks")
      end
      fragment_slots = checked_multiply(callback_count.to_u64, @mark_count.to_u64)
      owner_nodes = checked_add(2_u64, callback_count.to_u64) # name array, fragment outer array, mark arrays
      owner_elements = checked_add(
        checked_multiply(callback_count.to_u64, 2_u64), # name references and fragment-array references
        fragment_slots,
      )
      budget.ensure_future_nodes(owner_nodes)
      budget.ensure_future_elements(owner_elements)
      owner_nodes.times { budget.charge_node }
      budget.charge_elements(owner_elements)
      @callback_names = Array(String).new(callback_count)
      plan.each_callback_event { |event| @callback_names << event.name }
      unless @callback_names.size == callback_count
        raise UnsupportedFormatError.new("Compact JSON callback event count changed after planning")
      end

      @callback_fragments = Array(Array(Bytes)).new(callback_count)
      callback_count.times do
        @callback_fragments << Array(Bytes).new(@mark_count) { Bytes.new(0) }
      end
      # One slot per scheduled callback. Object/Dynamic structure callbacks
      # share their two immutable prefix owners across all marks.
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(callback_count.to_u64)
      budget.charge_node
      budget.charge_elements(callback_count.to_u64)
      @structure_prefixes = Array(Tuple(Bytes, Bytes)?).new(callback_count) { nil }

      json_site_count = plan.json_site_count
      array_site_count = plan.array_site_count
      uint8_site_count = plan.uint8_site_count
      bulk_site_count = plan.bulk_site_count
      site_slots = checked_add(
        checked_add(json_site_count.to_u64, array_site_count.to_u64),
        checked_add(uint8_site_count.to_u64, bulk_site_count.to_u64),
      )
      unless json_site_count > 0
        raise UnsupportedFormatError.new("Compact JSON callback plan has an inconsistent schema-site roster")
      end
      budget.ensure_future_nodes(4_u64)
      budget.ensure_future_elements(site_slots)
      4.times { budget.charge_node }
      budget.charge_elements(site_slots) if site_slots > 0_u64
      json_sites = plan.json_sites
      array_sites = plan.array_sites
      uint8_sites = plan.uint8_sites
      bulk_sites = plan.bulk_sites
      unless json_sites.size == json_site_count && array_sites.size == array_site_count &&
             uint8_sites.size == uint8_site_count && bulk_sites.size == bulk_site_count
        raise UnsupportedFormatError.new("Compact JSON schema-site roster changed after planning")
      end

      schema_nodes, schema_edges = value_plan_cost(plan.bound_schema)
      plan_nodes = checked_multiply(schema_nodes, 2_u64) # node owners plus child arrays
      plan_nodes = checked_add(plan_nodes, 1_u64)        # mutable site cursor
      plan_elements = checked_add(schema_edges, 3_u64)   # child references plus cursor slots
      budget.ensure_future_nodes(plan_nodes)
      budget.ensure_future_elements(plan_elements)
      plan_nodes.times { budget.charge_node }
      budget.charge_elements(plan_elements)
      cursor = SiteCursor.new
      root_node = build_value_plan_node(plan.bound_schema, cursor)
      unless cursor.json == json_sites.size && cursor.array == array_sites.size &&
             cursor.uint8 == uint8_sites.size && cursor.bulk == bulk_sites.size
        raise UnsupportedFormatError.new("Compact JSON value traversal differs from its schema-owned site roster")
      end
      prepare_structure_prefixes!(budget)

      @mark_count.times do |mark_index|
        json_documents, array_sizes, uint8_values, bulk_values = collect_mark_values(
          root_node,
          json_sites.size,
          array_sites.size,
          uint8_sites.size,
          bulk_sites.size,
          mark_index,
          budget,
        )
        filled = new_filled_roster(callback_count, budget)

        json_sites.each_with_index do |site, site_index|
          binding = plan.site_binding(site.key)
          encode_object_site!(
            binding,
            json_documents[site_index],
            plan.bound_row_count(mark_index).to_u64,
            mark_index,
            filled,
            budget,
          )
        end

        array_sites.each_with_index do |site, site_index|
          bytes = encode_binary_lane!(BinaryDataType.primitive("UInt64"), array_sizes[site_index], budget)
          append_fragment!(site.callback_name, bytes, mark_index, filled)
        end

        uint8_sites.each_with_index do |site, site_index|
          bytes = encode_binary_lane!(site.type, uint8_values[site_index], budget)
          append_fragment!(site.callback_name, bytes, mark_index, filled)
        end

        bulk_sites.each_with_index do |site, site_index|
          encode_bulk_site!(site, bulk_values[site_index], mark_index, filled, budget)
        end

        filled.each_with_index do |value, callback_index|
          unless value
            raise UnsupportedFormatError.new("Compact JSON encoder omitted a planned callback for one mark")
          end
        end
      end
    end

    def self.encode(plan : CompactJsonCallbackPlan, budget : BinaryCodecBudget) : CompactJsonEncodedColumn
      new(plan, budget)
    end

    def each_callback_event(&block : CompactBinaryBulkCallback -> Nil) : Nil
      @plan.each_callback_event { |event| yield event }
      nil
    end

    def callback_bytes(callback : CompactBinaryBulkCallback, mark_index : Int) : Bytes
      unless @plan.includes_callback_event?(callback)
        raise UnsupportedFormatError.new("Compact JSON callback is outside its encoded event roster")
      end
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact JSON callback mark is outside its encoded grid")
      end
      callback_index = index_for_callback(callback.name)
      @callback_fragments[callback_index][mark_index]
    end

    def callback_relocation_count_at(mark_index : Int) : Int32
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact JSON relocation mark is outside its encoded grid")
      end
      @callback_relocations.try { |marks| marks[mark_index].size } || 0
    end

    def callback_event_count : Int32
      @callback_names.size
    end

    def each_callback_relocation_at(mark_index : Int, &block : ObjectSharedInlineCallbackRelocation -> Nil) : Nil
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact JSON relocation mark is outside its encoded grid")
      end
      if marks = @callback_relocations
        marks[mark_index].each { |relocation| yield relocation }
      end
      nil
    end

    # Borrow final physical callback names and fragments for the Compact
    # granule relocation owner. These names already include the exact escaped
    # site binding and the bytes include every callback-local splice.
    def each_callback_fragment_at(mark_index : Int, &block : String, Bytes -> Nil) : Nil
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact JSON callback mark is outside its encoded grid")
      end
      @callback_names.each_with_index do |name, callback_index|
        yield name, @callback_fragments[callback_index][mark_index]
      end
      nil
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactJsonEncodedColumn).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@callback_names.size.to_u64, sizeof(String).to_u64))

      bytes = checked_add(bytes, instance_sizeof(Array(Array(Bytes))).to_u64)
      bytes = checked_add(bytes, checked_multiply(@callback_fragments.size.to_u64, sizeof(Array(Bytes)).to_u64))
      @callback_fragments.each_with_index do |fragments, callback_index|
        bytes = checked_add(bytes, instance_sizeof(Array(Bytes)).to_u64)
        bytes = checked_add(bytes, checked_multiply(fragments.size.to_u64, sizeof(Bytes).to_u64))
        has_shared_prefix = @structure_prefixes[callback_index]?
        fragments.each do |fragment|
          # Structure callback fragments point at the two prefix owners below;
          # every other retained fragment has a mark-local detached payload.
          bytes = checked_add(bytes, fragment.size.to_u64) unless has_shared_prefix
        end
      end

      bytes = checked_add(bytes, instance_sizeof(Array(Tuple(Bytes, Bytes)?)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@structure_prefixes.size.to_u64, sizeof(Tuple(Bytes, Bytes)?).to_u64))
      @structure_prefixes.each do |prefixes|
        next unless value = prefixes
        bytes = checked_add(bytes, value[0].size.to_u64)
        bytes = checked_add(bytes, value[1].size.to_u64)
      end

      if marks = @callback_relocations
        bytes = checked_add(bytes, instance_sizeof(Array(Array(ObjectSharedInlineCallbackRelocation))).to_u64)
        bytes = checked_add(
          bytes,
          checked_multiply(marks.size.to_u64, sizeof(Array(ObjectSharedInlineCallbackRelocation)).to_u64),
        )
        marks.each do |relocations|
          bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedInlineCallbackRelocation)).to_u64)
          bytes = checked_add(
            bytes,
            checked_multiply(relocations.size.to_u64, sizeof(Pointer(ObjectSharedInlineCallbackRelocation)).to_u64),
          )
          relocations.each do |relocation|
            bytes = checked_add(bytes, instance_sizeof(ObjectSharedInlineCallbackRelocation).to_u64)
            bytes = checked_add(bytes, checked_multiply(2_u64, instance_sizeof(String).to_u64))
            bytes = checked_add(
              bytes,
              checked_add(relocation.source_callback_byte_size.to_u64, 1_u64),
            )
            bytes = checked_add(
              bytes,
              checked_add(relocation.target_callback_byte_size.to_u64, 1_u64),
            )
          end
        end
      end
      bytes
    end

    private def build_value_plan_node(schema : StorageColumnSchema, cursor : SiteCursor) : ValuePlanNode
      site_index = -1
      if schema.object?
        site_index = cursor.json
        cursor.json += 1
      elsif schema.array?
        site_index = cursor.array
        cursor.array += 1
      elsif schema.bulk?
        if schema.bulk_type.tag == BinaryDataType::TAG_UINT8
          site_index = cursor.uint8
          cursor.uint8 += 1
        else
          site_index = cursor.bulk
          cursor.bulk += 1
        end
      end

      children = Array(ValuePlanNode).new(schema.child_count)
      schema.child_count.times do |index|
        children << build_value_plan_node(schema.child_at(index), cursor)
      end
      ValuePlanNode.new(schema, site_index, children)
    end

    private def value_plan_cost(schema : StorageColumnSchema) : Tuple(UInt64, UInt64)
      nodes = 1_u64
      edges = schema.child_count.to_u64
      schema.child_count.times do |index|
        child_nodes, child_edges = value_plan_cost(schema.child_at(index))
        nodes = checked_add(nodes, child_nodes)
        edges = checked_add(edges, child_edges)
      end
      {nodes, edges}
    end

    private def collect_mark_values(
      root : ValuePlanNode,
      json_site_count : Int32,
      array_site_count : Int32,
      uint8_site_count : Int32,
      bulk_site_count : Int32,
      mark_index : Int32,
      budget : BinaryCodecBudget,
    ) : Tuple(Array(Array(ObjectDocument)), Array(Array(BinaryValue)), Array(Array(BinaryValue)), Array(Array(BinaryValue)))
      budget.ensure_future_nodes(4_u64)
      site_count = (json_site_count + array_site_count + uint8_site_count + bulk_site_count).to_u64
      budget.ensure_future_elements(site_count)
      4.times { budget.charge_node }
      budget.charge_elements(site_count)
      json_counts = Array(Int32).new(json_site_count, 0)
      array_counts = Array(Int32).new(array_site_count, 0)
      uint8_counts = Array(Int32).new(uint8_site_count, 0)
      bulk_counts = Array(Int32).new(bulk_site_count, 0)

      row_count = @plan.bound_row_count(mark_index)
      row_count.times do |row_index|
        count_value!(
          root,
          @plan.bound_value_at(mark_index, row_index),
          json_counts,
          array_counts,
          uint8_counts,
          bulk_counts,
          budget,
          1,
        )
      end

      json_total = total_counts(json_counts)
      array_total = total_counts(array_counts)
      uint8_total = total_counts(uint8_counts)
      bulk_total = total_counts(bulk_counts)
      all_sites = site_count
      reference_slots = checked_add(checked_add(checked_add(json_total, array_total), uint8_total), bulk_total)
      generated_size_values = array_total
      output_nodes = checked_add(checked_add(all_sites, generated_size_values), 4_u64)
      output_elements = checked_add(
        checked_add(all_sites, reference_slots),
        checked_multiply(generated_size_values, 8_u64),
      )
      generated_size_bytes = checked_multiply(generated_size_values, 8_u64)
      budget.ensure_future_nodes(output_nodes)
      budget.ensure_future_elements(output_elements)
      budget.ensure_wire_bytes(generated_size_bytes)
      output_nodes.times { budget.charge_node }
      budget.charge_elements(output_elements)
      budget.charge_wire_bytes(generated_size_bytes) if generated_size_bytes > 0_u64

      json_documents = Array(Array(ObjectDocument)).new(json_site_count)
      json_counts.each { |count| json_documents << Array(ObjectDocument).new(count) }
      array_sizes = Array(Array(BinaryValue)).new(array_site_count)
      array_counts.each { |count| array_sizes << Array(BinaryValue).new(count) }
      uint8_values = Array(Array(BinaryValue)).new(uint8_site_count)
      uint8_counts.each { |count| uint8_values << Array(BinaryValue).new(count) }
      bulk_values = Array(Array(BinaryValue)).new(bulk_site_count)
      bulk_counts.each { |count| bulk_values << Array(BinaryValue).new(count) }

      row_count.times do |row_index|
        fill_value!(root, @plan.bound_value_at(mark_index, row_index), json_documents, array_sizes, uint8_values, bulk_values)
      end
      unless json_documents.each_with_index.all? { |values, index| values.size == json_counts[index] } &&
             array_sizes.each_with_index.all? { |values, index| values.size == array_counts[index] } &&
             uint8_values.each_with_index.all? { |values, index| values.size == uint8_counts[index] } &&
             bulk_values.each_with_index.all? { |values, index| values.size == bulk_counts[index] }
        raise UnsupportedFormatError.new("Compact JSON value grid changed during bounded projection")
      end
      {json_documents, array_sizes, uint8_values, bulk_values}
    end

    private def count_value!(
      node : ValuePlanNode,
      value : StorageColumnValue,
      json_counts : Array(Int32),
      array_counts : Array(Int32),
      uint8_counts : Array(Int32),
      bulk_counts : Array(Int32),
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      budget.visit_node(depth)
      schema = node.schema
      if schema.object?
        unless value.object?
          raise UnsupportedFormatError.new("Compact JSON row value differs from its declared Object site")
        end
        increment_count!(json_counts, node.site_index)
      elsif schema.array?
        unless value.array?
          raise UnsupportedFormatError.new("Compact JSON row value differs from its declared Array site")
        end
        increment_count!(array_counts, node.site_index)
        budget.preflight_children(value.child_count.to_u64)
        value.child_count.times do |index|
          count_value!(node.children[0], value.child_at(index), json_counts, array_counts, uint8_counts, bulk_counts, budget, depth + 1)
        end
      elsif schema.tuple?
        unless value.tuple? && value.child_count == schema.child_count
          raise UnsupportedFormatError.new("Compact JSON row value differs from its declared Tuple site")
        end
        budget.preflight_children(schema.child_count.to_u64)
        schema.child_count.times do |index|
          count_value!(node.children[index], value.child_at(index), json_counts, array_counts, uint8_counts, bulk_counts, budget, depth + 1)
        end
      elsif schema.bulk?
        unless value.bulk?
          raise UnsupportedFormatError.new("Compact JSON row value differs from its declared BinaryBulk leaf")
        end
        binary = value.bulk_value
        type_context = BinaryCodecContext.new(budget.limits, nil, true, budget)
        type_context.validate_type_tree(binary.type, depth)
        unless binary.type == schema.bulk_type
          raise UnsupportedFormatError.new("Compact JSON BinaryBulk leaf differs from its canonical declaration")
        end
        if schema.bulk_type.tag == BinaryDataType::TAG_UINT8
          increment_count!(uint8_counts, node.site_index)
        else
          increment_count!(bulk_counts, node.site_index)
        end
      else
        raise UnsupportedFormatError.new("Compact JSON value traversal encountered an unknown schema node")
      end
      nil
    end

    private def fill_value!(
      node : ValuePlanNode,
      value : StorageColumnValue,
      json_documents : Array(Array(ObjectDocument)),
      array_sizes : Array(Array(BinaryValue)),
      uint8_values : Array(Array(BinaryValue)),
      bulk_values : Array(Array(BinaryValue)),
    ) : Nil
      schema = node.schema
      if schema.object?
        json_documents[node.site_index] << value.object_document
      elsif schema.array?
        array_sizes[node.site_index] << BinaryValue.uint64(value.child_count.to_u64)
        value.child_count.times do |index|
          fill_value!(node.children[0], value.child_at(index), json_documents, array_sizes, uint8_values, bulk_values)
        end
      elsif schema.tuple?
        schema.child_count.times do |index|
          fill_value!(node.children[index], value.child_at(index), json_documents, array_sizes, uint8_values, bulk_values)
        end
      elsif schema.bulk?
        if schema.bulk_type.tag == BinaryDataType::TAG_UINT8
          uint8_values[node.site_index] << value.bulk_value
        else
          bulk_values[node.site_index] << value.bulk_value
        end
      else
        raise UnsupportedFormatError.new("Compact JSON value projection encountered an unknown schema node")
      end
      nil
    end

    private def encode_object_site!(
      binding : CompactJsonCallbackPlan::SiteBinding,
      documents : Array(ObjectDocument),
      physical_rows : UInt64,
      mark_index : Int32,
      filled : Array(Bool),
      budget : BinaryCodecBudget,
    ) : Nil
      budget.preflight_children(1_u64)
      budget.charge_node
      document_grid = Array(Array(ObjectDocument)).new(1)
      document_grid << documents

      budget.ensure_future_nodes(2_u64)
      budget.ensure_future_elements(2_u64)
      2.times { budget.charge_node }
      budget.charge_elements(2_u64)
      physical_grid = Array(UInt64).new(1)
      physical_grid << physical_rows
      logical_grid = Array(UInt64).new(1)
      logical_grid << documents.size.to_u64
      grid = StorageOccurrenceGrid.new(physical_grid, logical_grid, budget)

      site = binding.site
      mode = @plan.variant_discriminator_mode.wire_value
      streams = ObjectDocumentCodec.encode_child_site_with_budget(
        binding.object_plan,
        document_grid,
        grid,
        budget,
        mode,
        @plan.profile,
        BinaryBulkProfile.single_stream,
        site.descriptor_depth + 1,
        site.descriptor_depth + 1,
      )
      nested = ObjectSharedNestedSerializationContext.for_write(
        binding.object_plan.structures.object.shared_data_version,
        1,
        @plan.profile,
      )
      layout = ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
        binding.physical_plan,
        binding.object_plan,
        streams,
        grid,
        budget,
        nested,
        callback_root_prefix: site.callback_prefix,
      )
      unless layout.prefix_callback_count == binding.prefix_callback_count &&
             layout.body_callback_count == binding.body_callback_count
        raise UnsupportedFormatError.new("Compact JSON raw Object callback roster differs from its sealed plan")
      end
      retain_relocations!(layout, binding, mark_index, budget)
      layout.prefix_callback_count.times do |index|
        callback = layout.prefix_callback_at(index, budget)
        callback_name = callback[0]
        unless binding.has_prefix_callback?(callback_name)
          raise UnsupportedFormatError.new("Compact JSON Object prefix callback is outside its sealed plan")
        end
        bytes = callback[1]
        if callback_index = index_for_callback?(callback_name)
          if structure_prefixes = @structure_prefixes[callback_index]?
            bytes = mark_index == 0 ? structure_prefixes[0] : structure_prefixes[1]
          end
        end
        append_fragment!(callback_name, bytes, mark_index, filled)
      end
      layout.body_callback_count.times do |index|
        callback = layout.body_callback_at(index, budget)
        callback_name = callback[0]
        unless binding.has_body_callback?(callback_name)
          raise UnsupportedFormatError.new("Compact JSON Object body callback is outside its sealed plan")
        end
        append_fragment!(callback_name, callback[1], mark_index, filled)
      end
      nil
    end

    private def encode_bulk_site!(
      site : CompactRecursiveJsonBulkSite,
      values : Array(BinaryValue),
      mark_index : Int32,
      filled : Array(Bool),
      budget : BinaryCodecBudget,
    ) : Nil
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(1_u64)
      budget.charge_node
      budget.charge_elements(1_u64)
      granules = Array(Array(BinaryValue)).new(1)
      granules << values
      streams = BinaryBulkEncoder.encode(
        site.type,
        granules,
        budget,
        site.physical_plan.profile,
        low_cardinality_policy: BinaryLowCardinalityStoragePolicy::AdditionalKeysOnly,
      )
      unless streams.mark_count == 1 && streams.role_count == site.role_count
        raise UnsupportedFormatError.new("Compact JSON opaque Bulk callback roster differs from its physical plan")
      end

      variant_prefix_count = 0_u64
      site.prefix_role_count.times do |prefix_index|
        prefix_role = site.prefix_role_at(prefix_index)
        if prefix_role.kind == CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode
          variant_prefix_count = checked_add(variant_prefix_count, 1_u64)
        end
      end
      variant_lanes = [] of Tuple(String, BinaryBulkStream, UInt64)
      if variant_prefix_count > 0_u64
        budget.ensure_future_nodes(1_u64)
        budget.ensure_future_elements(variant_prefix_count)
        budget.charge_node
        budget.charge_elements(variant_prefix_count)
        variant_lanes = Array(Tuple(String, BinaryBulkStream, UInt64)).new(variant_prefix_count.to_i)
        variant_mode = @plan.variant_discriminator_mode.wire_value
        site.prefix_role_count.times do |prefix_index|
          prefix_role = site.prefix_role_at(prefix_index)
          next unless prefix_role.kind == CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode
          role = site.role_at(prefix_role.role_index).name
          unless streams.has_role?(role)
            raise UnsupportedFormatError.new("Compact JSON opaque Bulk encoder omitted a Variant discriminator role")
          end
          variant_lanes << {role, streams.stream(role), variant_mode}
        end
        unless variant_lanes.size.to_u64 == variant_prefix_count
          raise UnsupportedFormatError.new("Compact JSON Variant framing roster changed after planning")
        end
        BinaryBulkDiscriminatorFramingAdapter.preflight_write(variant_lanes, budget)
      end

      site.prefix_role_count.times do |prefix_index|
        prefix_role = site.prefix_role_at(prefix_index)
        role = site.role_at(prefix_role.role_index).name
        unless streams.has_role?(role)
          raise UnsupportedFormatError.new("Compact JSON opaque Bulk encoder omitted a stateful physical role")
        end
        stream = streams.stream(role)
        case prefix_role.kind
        when CompactRecursiveJsonBulkSite::StatePrefixKind::LowCardinalityDictionaryV1
          unless stream.offset_at(0) == 8_u64 && stream.offset_at(1) == 8_u64 && stream.byte_size == 8
            raise UnsupportedFormatError.new("Compact JSON opaque Bulk dictionary prefix lane has an unexpected extent")
          end
          prefix = stream.borrowed_slice(0_u64, 8_u64)
          budget.ensure_future_nodes(1_u64)
          budget.ensure_future_elements(8_u64)
          budget.ensure_wire_bytes(8_u64)
          budget.charge_node
          budget.charge_elements(8_u64)
          budget.charge_wire_bytes(8_u64)
          detached = Bytes.new(8) { |index| prefix[index] }
          append_fragment!(prefix_role.callback_name, detached, mark_index, filled)
        when CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode
          lane = variant_lanes.find { |candidate| candidate[0] == role } ||
                 raise(UnsupportedFormatError.new("Compact JSON Variant framing lane is missing from its preflight roster"))
          physical, offsets, physical_prefix = BinaryBulkDiscriminatorFramingAdapter.write_lane(
            lane[0], lane[1], lane[2],
          )
          unless physical_prefix == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES &&
                 offsets.size == 2 && offsets[0] == physical_prefix.to_u64 &&
                 offsets[1] == physical.size.to_u64
            raise UnsupportedFormatError.new("Compact JSON Variant physical lane has an unexpected one-mark extent")
          end
          prefix_bytes = Bytes.new(physical.to_unsafe, physical_prefix, read_only: true)
          body_size = physical.size - physical_prefix
          body_bytes = Bytes.new(physical.to_unsafe + physical_prefix, body_size, read_only: true)
          append_fragment!(prefix_role.callback_name, prefix_bytes, mark_index, filled)
          append_fragment!(site.callback_name_for(role), body_bytes, mark_index, filled)
        end
      end
      site.each_role do |role|
        unless streams.has_role?(role.name)
          raise UnsupportedFormatError.new("Compact JSON opaque Bulk encoder omitted a physical role")
        end
        stream = streams.stream(role.name)
        if prefix_index = site.prefix_role_index(role.name)
          prefix_role = site.prefix_role_at(prefix_index)
          if prefix_role.kind == CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode
            # The adapter emitted both the schema-DFS mode prefix and this
            # physical body callback from one validated mark lane above.
            next
          end
        end
        first = stream.offset_at(0)
        last = stream.offset_at(1)
        if last < first
          raise UnsupportedFormatError.new("Compact JSON opaque Bulk stream has a reversed mark range")
        end
        bytes = stream.borrowed_slice(first, last - first)
        budget.ensure_future_nodes(1_u64)
        budget.ensure_future_elements(bytes.size.to_u64)
        budget.ensure_wire_bytes(bytes.size.to_u64)
        budget.charge_node
        budget.charge_elements(bytes.size.to_u64) if bytes.size > 0
        budget.charge_wire_bytes(bytes.size.to_u64) if bytes.size > 0
        detached = Bytes.new(bytes.size) { |index| bytes[index] }
        append_fragment!(site.callback_name_for(role.name), detached, mark_index, filled)
      end
      nil
    end

    private def retain_relocations!(
      layout : ObjectSharedAdvancedInlineRawLayout,
      binding : CompactJsonCallbackPlan::SiteBinding,
      mark_index : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      count = layout.relocation_count
      return nil if count == 0
      unless count > 0 && mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact JSON relocation roster has an invalid mark or count")
      end

      marks = @callback_relocations
      unless marks
        mark_slots = @mark_count.to_u64
        owner_nodes = checked_add(mark_slots, 1_u64)
        budget.ensure_future_nodes(owner_nodes)
        budget.ensure_future_elements(mark_slots)
        owner_nodes.times { budget.charge_node }
        budget.charge_elements(mark_slots) if mark_slots > 0_u64
        marks = Array(Array(ObjectSharedInlineCallbackRelocation)).new(@mark_count) do
          [] of ObjectSharedInlineCallbackRelocation
        end
        @callback_relocations = marks
      end

      relocation_count = count.to_u64
      name_bytes = 0_u64
      count.times do |index|
        relocation = layout.relocation_at(index)
        name_bytes = checked_add(name_bytes, relocation.source_callback_byte_size.to_u64)
        name_bytes = checked_add(name_bytes, relocation.target_callback_byte_size.to_u64)
      end
      budget.ensure_future_nodes(relocation_count * 2_u64)
      budget.ensure_future_elements(relocation_count * 2_u64)
      budget.ensure_wire_bytes(name_bytes)
      (relocation_count * 2_u64).times { budget.charge_node }
      budget.charge_elements(relocation_count * 2_u64)
      budget.charge_wire_bytes(name_bytes) if name_bytes > 0_u64

      retained = marks[mark_index]
      budget.ensure_future_elements(relocation_count)
      count.times do |index|
        relocation = layout.relocation_at(index)
        source_name = relocation.source_callback
        target_name = relocation.target_callback
        source_bound = binding.has_prefix_callback?(source_name) || binding.has_body_callback?(source_name)
        target_bound = binding.has_prefix_callback?(target_name) || binding.has_body_callback?(target_name)
        unless source_bound && target_bound && index_for_callback?(source_name) && index_for_callback?(target_name)
          raise UnsupportedFormatError.new("Compact JSON relocation callback is outside its exact escaped site binding")
        end
        retained << relocation
        budget.charge_elements(1_u64)
      end
      nil
    end

    private def prepare_structure_prefixes!(budget : BinaryCodecBudget) : Nil
      @callback_names.each_with_index do |name, callback_index|
        source = @plan.structure_source_for_callback(name)
        next unless source
        full, empty = structure_prefix_pair(source, budget)
        @structure_prefixes[callback_index] = {full, empty}
      end
      nil
    end

    private def structure_prefix_pair(
      source : CompactJsonCallbackPlan::StructureSource,
      budget : BinaryCodecBudget,
    ) : Tuple(Bytes, Bytes)
      structures = source.owner_plan.structures
      context = BinaryCodecContext.new(budget.limits, nil, true, budget)
      case source.kind
      when :object
        object = structures.object
        ObjectStructureCodec.write_to(object, context)
        full = context.finish_bytes
        empty_context = BinaryCodecContext.new(budget.limits, nil, true, budget)
        empty_object = ObjectStructure.new(
          object.dynamic_paths,
          object.version,
          object.shared_data_version,
          object.bucket_count,
          nil,
          nil,
        )
        ObjectStructureCodec.write_to(empty_object, empty_context)
        {full, empty_context.finish_bytes}
      when :object_dynamic, :typed_dynamic
        dynamic = if source.kind == :object_dynamic
                    structures.dynamic_for(source.owner_path)
                  else
                    source.owner_plan.typed_dynamic_site_structure_for(source.owner_path, source.structure_path)
                  end
        depth = dynamic_type_depth(source, budget.limits)
        DynamicStructureCodec.write_to(dynamic, context, 1, depth)
        full = context.finish_bytes
        empty_statistics = if dynamic.version == DynamicStructure::VERSION_V3
                             nil
                           else
                             empty_dynamic_statistics(dynamic, budget)
                           end
        empty_dynamic = DynamicStructure.new(
          dynamic.types,
          empty_statistics,
          dynamic.version,
          dynamic.legacy_max_dynamic_types,
        )
        empty_context = BinaryCodecContext.new(budget.limits, nil, true, budget)
        DynamicStructureCodec.write_to(empty_dynamic, empty_context, 1, depth)
        {full, empty_context.finish_bytes}
      else
        raise UnsupportedFormatError.new("Compact JSON structure callback has an unknown source kind")
      end
    end

    private def empty_dynamic_statistics(
      dynamic : DynamicStructure,
      budget : BinaryCodecBudget,
    ) : StructureStatistics
      count = dynamic.canonical_variant_count.to_u64
      count_elements = checked_multiply(count, 2_u64)
      # The zero-count array is copied into StructureStatistics, which also
      # creates its empty shared-array and name-index owners. Admit those
      # bounded owners and both positional reference arrays before allocation.
      budget.ensure_future_nodes(5_u64)
      budget.ensure_future_elements(count_elements)
      5.times { budget.charge_node }
      budget.charge_elements(count_elements) if count_elements > 0_u64

      StructureStatistics.new(
        Array(UInt64).new(dynamic.canonical_variant_count) { 0_u64 },
        [] of StructureStatistic,
      )
    end

    private def dynamic_type_depth(
      source : CompactJsonCallbackPlan::StructureSource,
      limits : BinaryCodecLimits,
    ) : Int32
      actual_depth = if source.kind == :object_dynamic
                       source.owner_physical_plan.inferred_actual_root_depth.to_i64
                     else
                       object_depth = source.owner_plan.typed_dynamic_site_object_depth_for(
                         source.owner_path,
                         source.structure_path,
                       ).to_i64
                       source.owner_physical_plan.typed_descriptor_root_depth.to_i64 - 1_i64 +
                         object_depth + 1_i64
                     end
      unless actual_depth > 0_i64 && actual_depth <= limits.max_depth.to_i64 &&
             actual_depth <= Int32::MAX.to_i64
        raise UnsupportedFormatError.new("Compact JSON Dynamic prefix depth is outside the admitted descriptor bounds")
      end
      actual_depth.to_i32
    end

    private def encode_binary_lane!(
      type : BinaryDataType,
      values : Array(BinaryValue),
      budget : BinaryCodecBudget,
    ) : Bytes
      budget.preflight_children(1_u64)
      budget.charge_node
      granules = Array(Array(BinaryValue)).new(1)
      granules << values
      streams = BinaryBulkCodec.encode_with_budget(type, granules, budget, BinaryBulkProfile.single_stream)
      unless streams.mark_count == 1 && streams.role_count == 1 && streams.has_role?("root.data")
        raise UnsupportedFormatError.new("Compact JSON scalar callback did not produce one single-stream data lane")
      end
      stream = streams.stream("root.data")
      first = stream.offset_at(0)
      last = stream.offset_at(1)
      if last < first
        raise UnsupportedFormatError.new("Compact JSON scalar lane has a reversed mark range")
      end
      bytes = stream.borrowed_slice(first, last - first)
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(bytes.size.to_u64)
      budget.ensure_wire_bytes(bytes.size.to_u64)
      budget.charge_node
      budget.charge_elements(bytes.size.to_u64) if bytes.size > 0
      budget.charge_wire_bytes(bytes.size.to_u64) if bytes.size > 0
      Bytes.new(bytes.size) { |index| bytes[index] }
    end

    private def new_filled_roster(callback_count : Int32, budget : BinaryCodecBudget) : Array(Bool)
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(callback_count.to_u64)
      budget.charge_node
      budget.charge_elements(callback_count.to_u64)
      Array(Bool).new(callback_count, false)
    end

    private def append_fragment!(name : String, bytes : Bytes, mark_index : Int32, filled : Array(Bool)) : Nil
      index = index_for_callback(name)
      if filled[index]
        raise UnsupportedFormatError.new("Compact JSON callback was emitted more than once for one mark")
      end
      @callback_fragments[index][mark_index] = bytes
      filled[index] = true
      nil
    end

    private def index_for_callback(name : String) : Int32
      index_for_callback?(name) || raise(UnsupportedFormatError.new("Compact JSON callback is outside its encoded event roster"))
    end

    private def index_for_callback?(name : String) : Int32?
      @callback_names.each_with_index do |candidate, index|
        return index if candidate == name
      end
      nil
    end

    private def increment_count!(counts : Array(Int32), index : Int32) : Nil
      unless index >= 0 && index < counts.size && counts[index] < Int32::MAX
        raise UnsupportedFormatError.new("Compact JSON occurrence count is outside the supported domain")
      end
      counts[index] += 1
      nil
    end

    private def total_counts(counts : Array(Int32)) : UInt64
      total = 0_u64
      counts.each { |count| total = checked_add(total, count.to_u64) }
      total
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact JSON workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact JSON workspace overflows UInt64")
      end
      left * right
    end
  end
end
