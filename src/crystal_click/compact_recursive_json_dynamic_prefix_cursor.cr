module CrystalClick
  # Ledger-owned variable-width Dynamic prefix adapter. It never exposes the
  # parent cursor: the structure parser must return a bounded extent before
  # the ledger commits the physical callback/tape position.
  class CompactRecursiveJsonDynamicPrefixCursor
    def self.capture_structure!(
      site : CompactRecursiveJsonDynamicBulkSite,
      ledger : CompactRecursiveJsonParentMarkLedger,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      prepared_plan : CompactRecursiveJsonDynamicBulkCapturePlan? = nil,
    ) : DynamicStructure
      first_mark = ledger.mark_index == 0
      if first_mark == !prepared_plan.nil?
        raise CorruptPartError.new("recursive Compact Dynamic structure plan has an invalid first-mark lifecycle")
      end
      callback = structure_callback_name(site, limits, budget)
      structure, _capture = ledger.with_bulk_prefix_grammar_extent(callback) do |bytes|
        context = BinaryCodecContext.new(limits, bytes, false, budget, false, false)
        structure, _statistics_offset = DynamicStructureCodec.read_with_statistics_offset(
          context,
          site.descriptor_depth,
          checked_depth(site.descriptor_depth),
          true,
        )
        if structure.version == DynamicStructure::VERSION_V3
          if first_mark == structure.statistics.nil?
            raise CorruptPartError.new("recursive Compact Dynamic V3 statistics suffix differs from its first/later mark placement")
          end
        end
        if prior = prepared_plan
          unless prior.same_structure_roster?(structure)
            raise CorruptPartError.new("recursive Compact Dynamic actual structure roster changed between parent marks")
          end
        end
        consumed = context.input_offset
        budget.ensure_wire_bytes(consumed.to_u64)
        {structure, consumed}
      end
      structure
    end

    def self.capture_mode_prefix!(
      plan : CompactRecursiveJsonDynamicBulkCapturePlan,
      mark : CompactRecursiveJsonDynamicBulkMark,
      ledger : CompactRecursiveJsonParentMarkLedger,
    ) : Nil
      role = "root.discriminators"
      callback = plan.root_discriminator_mode_callback
      prefix, _capture = ledger.with_bulk_prefix_grammar_extent(callback) do |bytes|
        mode = BinaryBulkDiscriminatorFramingAdapter.validate_header(
          role,
          bytes,
          BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
        )
        unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
               mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
          raise CorruptPartError.new("unknown recursive Compact Dynamic discriminator mode")
        end
        {Bytes.new(bytes.to_unsafe, BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES, read_only: true),
         BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES}
      end
      mark.capture_state_prefix!(
        role,
        CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode,
        prefix,
      )
      nil
    end

    private def self.structure_callback_name(
      site : CompactRecursiveJsonDynamicBulkSite,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : String
      context = PhysicalStreamPlanContext.new(limits)
      resolver = BinaryDynamicBulkSiteNameResolver.from_escaped_prefix(
        site.type,
        site.physical_prefix,
        site.initial_array_level,
        limits,
        budget,
        context,
        initial_descriptor_depth: site.descriptor_depth,
      )
      resolver.structure_stream_name("root", Hash(String, DynamicStructure).new)
    end

    private def self.checked_depth(depth : Int32) : Int32
      if depth == Int32::MAX
        raise UnsupportedFormatError.new("recursive Compact Dynamic prefix depth overflows Int32")
      end
      depth + 1
    end
  end
end
