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
        raise UnsupportedFormatError.new("recursive Compact Bulk site is outside the stateless UInt8/Array/Tuple grammar")
      end
      @key = String.new(key.to_slice)
      @physical_prefix = String.new(physical_prefix.to_slice)
      role_count = self.class.measure_role_count(@type)
      role_bytes = self.class.measure_role_name_bytes(@type, 4_u64)
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
      @roles = [] of Role
      @size_lane_count = 0
      append_roles(@type, "root", @roles)
      unless @roles.size == @physical_plan.stream_count
        raise UnsupportedFormatError.new("recursive Compact Bulk role DFS differs from its physical plan")
      end
      @roles.each do |role|
        @physical_plan.stream_name_for(role.name)
      end
    end

    def self.measure_role_count(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_UINT8
        1_u64
      when BinaryDataType::TAG_ARRAY
        checked_measure_add(1_u64, measure_role_count(type.child_at(0)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        total = 0_u64
        type.child_count.times do |index|
          total = checked_measure_add(total, measure_role_count(type.child_at(index)))
        end
        total
      else
        0_u64
      end
    end

    def self.measure_role_name_bytes(type : BinaryDataType, prefix_bytes : UInt64) : UInt64
      case type.tag
      when BinaryDataType::TAG_UINT8
        checked_measure_add(prefix_bytes, 5_u64) # .data
      when BinaryDataType::TAG_ARRAY
        own = checked_measure_add(prefix_bytes, 6_u64)          # .sizes
        child_prefix = checked_measure_add(prefix_bytes, 9_u64) # .elements
        checked_measure_add(own, measure_role_name_bytes(type.child_at(0), child_prefix))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        total = 0_u64
        type.child_count.times do |index|
          field_prefix = checked_measure_add(prefix_bytes, 7_u64 + decimal_digits(index.to_u64)) # .field.N
          total = checked_measure_add(total, measure_role_name_bytes(type.child_at(index), field_prefix))
        end
        total
      else
        0_u64
      end
    end

    private def self.decimal_digits(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def self.checked_measure_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact Bulk role workspace exceeds UInt64")
      end
      left + right
    end

    def self.admitted_type?(type : BinaryDataType, depth : Int32, limits : BinaryCodecLimits) : Bool
      return false if depth <= 0 || depth > limits.max_depth
      case type.tag
      when BinaryDataType::TAG_UINT8
        true
      when BinaryDataType::TAG_ARRAY
        admitted_type?(type.child_at(0), depth + 1, limits)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        return false if type.child_count == 0
        type.child_count.times do |index|
          return false unless admitted_type?(type.child_at(index), depth + 1, limits)
        end
        true
      else
        false
      end
    rescue ex : ArgumentError | UnsupportedFormatError
      false
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

    private def append_roles(type : BinaryDataType, role_name : String, output : Array(Role)) : Nil
      case type.tag
      when BinaryDataType::TAG_UINT8
        output << Role.new("#{role_name}.data", false)
      when BinaryDataType::TAG_ARRAY
        output << Role.new("#{role_name}.sizes", true)
        @size_lane_count += 1
        append_roles(type.child_at(0), "#{role_name}.elements", output)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_roles(type.child_at(index), "#{role_name}.field.#{index}", output)
        end
      else
        raise UnsupportedFormatError.new("recursive Compact Bulk role visitor encountered an unsupported type")
      end
      nil
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
