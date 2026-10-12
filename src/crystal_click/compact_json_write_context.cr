module CrystalClick
  # Detached first-block authority for every declared JSON site in one
  # Compact column. ObjectDocumentPlans and their structures are immutable;
  # this owner copies only the structural site map and its keys.
  class CompactJsonWriteContext
    @site_plans : Hash(String, ObjectDocumentPlan)

    def initialize(site_plans : Hash(String, ObjectDocumentPlan))
      if site_plans.empty?
        raise ArgumentError.new("Compact JSON write context requires at least one Object site")
      end

      @site_plans = Hash(String, ObjectDocumentPlan).new(initial_capacity: site_plans.size)
      site_plans.each do |path, plan|
        if path.empty?
          raise ArgumentError.new("Compact JSON write context site paths must be nonempty")
        end
        object = plan.structures.object
        unless object.statistics
          raise ArgumentError.new("Compact JSON first-prefix Object structure requires full statistics")
        end
        object.dynamic_path_count.times do |index|
          dynamic = plan.structures.dynamic_for(object.dynamic_path_at(index))
          unless dynamic.statistics
            raise ArgumentError.new("Compact JSON first-prefix Dynamic structure requires full statistics at every path")
          end
        end
        plan.typed_dynamic_count.times do |index|
          typed_path = plan.typed_dynamic_path_at(index)
          plan.typed_dynamic_site_count_for(typed_path).times do |site_index|
            site_path = plan.typed_dynamic_site_path_at(typed_path, site_index)
            dynamic = plan.typed_dynamic_site_structure_for(typed_path, site_path)
            unless dynamic.statistics
              raise ArgumentError.new("Compact JSON first-prefix typed Dynamic structure requires full statistics at every site")
            end
          end
        end

        detached_path = String.new(path.to_slice)
        if @site_plans.has_key?(detached_path)
          raise ArgumentError.new("Compact JSON write context site paths must be unique")
        end
        @site_plans[detached_path] = plan
      end
    end

    def site_plans : Hash(String, ObjectDocumentPlan)
      detached = Hash(String, ObjectDocumentPlan).new(initial_capacity: @site_plans.size)
      @site_plans.each do |path, plan|
        detached[String.new(path.to_slice)] = plan
      end
      detached
    end

    def site_count : Int32
      @site_plans.size
    end

    def has_site?(path : String) : Bool
      @site_plans.has_key?(path)
    end

    def site_plan_for(path : String) : ObjectDocumentPlan
      @site_plans[path]? || raise(UnsupportedFormatError.new("Compact JSON context is missing a declared Object site"))
    end

    # Read-only traversal avoids allocating an uncharged detached Hash when a
    # callback plan validates the exact schema-owned site roster.
    def each_site_plan(&block : String, ObjectDocumentPlan -> Nil) : Nil
      @site_plans.each { |path, plan| yield path, plan }
      nil
    end

    # The callback plan verifies exact schema ownership before this predicate
    # is used to bind the operation's retained input to its preflight plan.
    def same_context?(other : CompactJsonWriteContext) : Bool
      return false unless @site_plans.size == other.@site_plans.size
      @site_plans.each do |path, plan|
        candidate = other.@site_plans[path]?
        return false unless candidate && candidate.same?(plan)
      end
      true
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactJsonWriteContext).to_u64
      bytes = checked_add(bytes, instance_sizeof(Hash(String, ObjectDocumentPlan)).to_u64)
      bytes = checked_add(
        bytes,
        checked_multiply(@site_plans.size.to_u64, sizeof({String, ObjectDocumentPlan}).to_u64),
      )
      @site_plans.each_key do |path|
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, path.bytesize.to_u64 + 1_u64)
      end
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact JSON context workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact JSON context workspace overflows UInt64")
      end
      left * right
    end
  end
end
