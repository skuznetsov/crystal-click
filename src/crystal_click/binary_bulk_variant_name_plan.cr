module CrystalClick
  # Bounded, occurrence-specific SQL names for the sparse physical Variant
  # roster. A descriptor reused at two Variant occurrences is measured twice:
  # each physical arm-name occurrence owns its own name work and retained name.
  class BinaryBulkVariantNamePlan
    alias NameBounds = BinaryTypeNameBudget::Bounds

    @name_types : Array(BinaryDataType)
    @name_bounds : Array(NameBounds)
    @site_offsets : Array(Int32)
    @site_counts : Array(Int32)
    @names : Array(String)
    @budget : BinaryCodecBudget
    @context : PhysicalStreamPlanContext
    @materialized : Bool
    @measure_site_cursor : Int32
    @append_site_cursor : Int32
    @name_work_bytes : UInt64

    getter site_count : UInt64
    getter arm_occurrence_count : UInt64

    def initialize(type : BinaryDataType, limits : BinaryCodecLimits, context : PhysicalStreamPlanContext)
      unless same_limits?(limits, context.limits)
        raise ArgumentError.new("Variant name plan and physical context limits differ")
      end

      # This helper is also a public type. Validate the descriptor before any
      # recursive occurrence counting or count-derived roster allocation, even
      # when a caller constructs it outside BinaryBulkPhysicalPlan.
      descriptor_guard = PhysicalStreamPlanContext.new(context.limits)
      validate_descriptor!(type, 0, descriptor_guard)

      @site_count = count_variant_sites(type)
      @arm_occurrence_count = count_arm_occurrences(type)
      if @site_count > Int32::MAX.to_u64 || @arm_occurrence_count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Variant physical name roster exceeds the supported in-memory domain")
      end

      # These entries are retained occurrence metadata, distinct from the
      # ordinary physical role roster. Admit them before allocating the flat
      # site/name tables below.
      context.record_elements(add_size(@site_count, @arm_occurrence_count))

      @name_types = Array(BinaryDataType).new(@arm_occurrence_count.to_i)
      @name_bounds = Array(NameBounds).new(@arm_occurrence_count.to_i)
      @site_offsets = Array(Int32).new(@site_count.to_i)
      @site_counts = Array(Int32).new(@site_count.to_i)
      @names = Array(String).new(@arm_occurrence_count.to_i)
      @budget = BinaryCodecBudget.new(context.limits, true)
      @context = context
      @materialized = false
      @measure_site_cursor = 0
      @append_site_cursor = 0
      @name_work_bytes = 0_u64

      collect(type, 0)
      unless @site_offsets.size.to_u64 == @site_count && @name_bounds.size.to_u64 == @arm_occurrence_count
        raise UnsupportedFormatError.new("Variant SQL name occurrence roster changed after preflight")
      end

      # This shared auxiliary budget covers all arm-name renderings before the
      # first one is materialized. BinaryTypeNameBudget's second bound includes
      # conservative output copies plus recursive formatting temporaries.
      @budget.ensure_wire_bytes(@name_work_bytes)
    end

    def name_work_bytes : UInt64
      @name_work_bytes
    end

    def next_measure_site : Int32
      site = @measure_site_cursor
      if site >= @site_offsets.size
        raise UnsupportedFormatError.new("Variant physical SQL name measurement lost its site roster")
      end
      @measure_site_cursor += 1
      site
    end

    def bounds_for(site : Int32, arm_index : Int) : NameBounds
      offset = @site_offsets[site]?
      count = @site_counts[site]?
      unless offset && count && arm_index >= 0 && arm_index < count
        raise UnsupportedFormatError.new("Variant physical SQL name measurement lost its arm roster")
      end
      @name_bounds[offset + arm_index]
    end

    def finish_measurement! : Nil
      unless @measure_site_cursor == @site_offsets.size
        raise UnsupportedFormatError.new("Variant physical SQL name measurement did not consume every site")
      end
      nil
    end

    # Called only after the enclosing physical planner has preflighted the
    # combined SQL work and complete conservative physical roster. This helper
    # also charges its shared physical context before any SQL name is rendered,
    # so direct construction cannot bypass aggregate name-byte limits.
    def materialize! : Nil
      if @materialized
        raise UnsupportedFormatError.new("Variant physical SQL names were materialized more than once")
      end
      @budget.ensure_wire_bytes(@name_work_bytes)
      @context.charge_name_bytes(@name_work_bytes)
      @name_types.each_with_index do |type, index|
        @names << BinaryTypeNameBudget.materialize(type, @budget, @name_bounds[index])
      end
      @materialized = true
      nil
    end

    def next_append_site : Int32
      site = @append_site_cursor
      if site >= @site_offsets.size
        raise UnsupportedFormatError.new("Variant physical binding lost its site roster")
      end
      @append_site_cursor += 1
      site
    end

    # Append one cached SQL component without returning or exposing the
    # retained mutable String that backs this occurrence roster.
    def append_escaped_arm_prefix(prefix : String, site : Int32, arm_index : Int) : String
      offset = @site_offsets[site]?
      count = @site_counts[site]?
      unless offset && count && arm_index >= 0 && arm_index < count && @names.size == @name_bounds.size
        raise UnsupportedFormatError.new("Variant physical binding lost its materialized arm name")
      end
      PhysicalStreamName.append_escaped_component(prefix, @names[offset + arm_index], @context)
    end

    def finish_binding! : Nil
      unless @append_site_cursor == @site_offsets.size
        raise UnsupportedFormatError.new("Variant physical binding did not consume every site")
      end
      nil
    end

    private def collect(type : BinaryDataType, depth : Int) : Nil
      # Generic physical lanes stop at LC; its admitted child grammar contains
      # no Variant, and no hidden child is given a role/name occurrence here.
      return nil if type.tag == BinaryDataType::TAG_LOW_CARDINALITY

      if type.tag == BinaryDataType::TAG_VARIANT
        @site_offsets << @name_bounds.size
        @site_counts << type.child_count
        type.child_count.times do |index|
          arm = type.child_at(index)
          bounds = BinaryTypeNameBudget.measure(arm, @budget, depth + 1)
          @name_types << arm
          @name_bounds << bounds
          @name_work_bytes = BinaryTypeNameBudget.add(@name_work_bytes, bounds[1])
        end
      end

      type.child_count.times do |index|
        collect(type.child_at(index), depth + 1)
      end
      nil
    end

    private def validate_descriptor!(
      type : BinaryDataType,
      depth : Int,
      context : PhysicalStreamPlanContext,
    ) : Nil
      context.record_type_node(depth)
      metadata = type.metadata_entry_count
      context.record_elements(metadata.to_u64) if metadata > 0
      child_count = type.child_count
      context.record_elements(child_count.to_u64) if child_count > 0
      child_count.times do |index|
        validate_descriptor!(type.child_at(index), depth + 1, context)
      end
      nil
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth &&
        left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements &&
        left.max_bytes == right.max_bytes
    end

    private def count_variant_sites(type : BinaryDataType) : UInt64
      return 0_u64 if type.tag == BinaryDataType::TAG_LOW_CARDINALITY

      count = type.tag == BinaryDataType::TAG_VARIANT ? 1_u64 : 0_u64
      type.child_count.times do |index|
        count = add_size(count, count_variant_sites(type.child_at(index)))
      end
      count
    end

    private def count_arm_occurrences(type : BinaryDataType) : UInt64
      return 0_u64 if type.tag == BinaryDataType::TAG_LOW_CARDINALITY

      count = type.tag == BinaryDataType::TAG_VARIANT ? type.child_count.to_u64 : 0_u64
      type.child_count.times do |index|
        count = add_size(count, count_arm_occurrences(type.child_at(index)))
      end
      count
    end

    private def add_size(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Variant physical SQL name roster overflows UInt64")
      end
      left + right
    end
  end
end
