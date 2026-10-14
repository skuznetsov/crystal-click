module CrystalClick
  # One opaque, stateless JSON-free recursive Bulk subtree owned by a
  # Compact recursive JSON schema plan. Logical role order is the serializer
  # DFS order, not BinaryBulkPhysicalPlan's set-oriented role roster.
  class CompactRecursiveJsonBulkSite
    struct Role
      getter name : String
      getter size_lane : Bool

      def initialize(name : String, @size_lane : Bool)
        @name = String.new(name.to_slice)
      end
    end

    getter key : String
    getter physical_prefix : String
    getter descriptor_depth : Int32
    getter initial_array_level : UInt64
    getter type : BinaryDataType
    getter physical_plan : BinaryBulkPhysicalPlan

    @roles : Array(Role)
    @size_lane_count : Int32

    def initialize(
      key : String,
      physical_prefix : String,
      @descriptor_depth : Int32,
      @initial_array_level : UInt64,
      @type : BinaryDataType,
      @physical_plan : BinaryBulkPhysicalPlan,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    )
      unless self.class.admitted_type?(@type, @descriptor_depth, limits)
        raise UnsupportedFormatError.new("recursive Compact Bulk site is outside the prefix-free static grammar")
      end
      @key = String.new(key.to_slice)
      @physical_prefix = String.new(physical_prefix.to_slice)
      role_count = self.class.measure_role_count(@type, @physical_plan.profile)
      role_bytes = self.class.measure_role_name_bytes(@type, 4_u64, @physical_plan.profile)
      unless role_count == @physical_plan.stream_count.to_u64
        raise UnsupportedFormatError.new("recursive Compact Bulk role DFS differs from its physical plan")
      end
      budget.ensure_future_nodes(role_count + 1_u64)
      budget.ensure_future_elements(role_count * 2_u64)
      budget.ensure_wire_bytes(role_bytes)
      # The schema plan already charged this site node; this owner charges
      # the private role roster plus its logical role records.
      budget.charge_node
      role_count.times { budget.charge_node }
      budget.charge_elements(role_count * 2_u64) if role_count > 0_u64
      budget.charge_wire_bytes(role_bytes) if role_bytes > 0_u64
      @roles = CompactRecursiveJsonStaticBulkGrammar.ordered_roles(@type, @physical_plan.profile)
      unless @roles.size == @physical_plan.stream_count
        raise UnsupportedFormatError.new("recursive Compact Bulk role DFS differs from its physical plan")
      end
      @size_lane_count = CompactRecursiveJsonStaticBulkGrammar.size_lane_count(@type).to_i32
      @roles.each do |role|
        @physical_plan.stream_name_for(role.name)
      end
    end

    def self.measure_role_count(
      type : BinaryDataType,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : UInt64
      CompactRecursiveJsonStaticBulkGrammar.measure_role_count(type, profile)
    end

    def self.measure_role_name_bytes(
      type : BinaryDataType,
      prefix_bytes : UInt64,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : UInt64
      CompactRecursiveJsonStaticBulkGrammar.measure_role_name_bytes(type, profile, prefix_bytes)
    end

    def self.admitted_type?(type : BinaryDataType, depth : Int32, limits : BinaryCodecLimits) : Bool
      CompactRecursiveJsonStaticBulkGrammar.admitted_type?(type, depth, limits)
    end

    def role_count : Int32
      @roles.size
    end

    def size_lane_count : Int32
      @size_lane_count
    end

    def each_role(&block : Role -> Nil) : Nil
      @roles.each { |role| yield role }
      nil
    end

    def role_at(index : Int) : Role
      @roles[index]
    end

    def callback_name_for(role_name : String) : String
      @physical_plan.stream_name_for(role_name)
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveJsonBulkSite).to_u64
      bytes = checked_add(bytes, string_owner_bytes(@key))
      bytes = checked_add(bytes, string_owner_bytes(@physical_prefix))
      bytes = checked_add(bytes, instance_sizeof(Array(Role)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@roles.size.to_u64, sizeof(Role).to_u64))
      @roles.each { |role| bytes = checked_add(bytes, string_owner_bytes(role.name)) }
      checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact Bulk site workspace exceeds UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("recursive Compact Bulk site workspace exceeds UInt64")
      end
      left * right
    end
  end
end
