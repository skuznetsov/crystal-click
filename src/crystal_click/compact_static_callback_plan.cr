module CrystalClick
  # Seals the ordered, stateless Compact callback schedule for one static
  # BinaryBulk column. Logical role keys remain owned by BinaryBulkTypePlan;
  # this owner only binds the serializer's callback order to physical lanes.
  class CompactStaticCallbackPlan
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter column_name : String

    @callback_names : Array(String)
    @callback_roles : Array(String)

    def initialize(input : CompactStaticColumnInput, limits : BinaryCodecLimits)
      @type = input.type
      @profile = input.profile
      @column_name = String.new(input.name.to_slice)

      raise ArgumentError.new("Compact static column name must be nonempty") if @column_name.empty?
      unless @profile.single_stream?
        raise UnsupportedFormatError.new("Compact static writer requires the single-stream profile")
      end
      unless input.map_basic?
        raise UnsupportedFormatError.new("Compact static writer requires BASIC Map serialization")
      end
      if @type.contains_low_cardinality?
        raise UnsupportedFormatError.new("Compact static writer does not admit LowCardinality state")
      end
      if @type.contains_variant?
        raise UnsupportedFormatError.new("Compact static writer does not admit Variant state")
      end
      if @type.contains_dynamic?
        raise UnsupportedFormatError.new("Compact static writer does not admit Dynamic state")
      end
      if @type.contains_json?
        raise UnsupportedFormatError.new("Compact static writer does not admit JSON state")
      end
      unless BinaryValueTypedBatchAdapter.admitted?(@type)
        raise UnsupportedFormatError.new("Compact selected type has no established typed batch carrier")
      end

      # Keep nominal and context-owned serializers behind their existing
      # declaration owners instead of inferring support from a rendered name.
      StaticBinaryBulkColumnDeclaration.new(@type, limits)

      physical = BinaryBulkPhysicalPlan.new(@type, @column_name, @profile, limits)
      normalizer = CompactBinaryBulkNormalizer.new(@type, @column_name, @profile, limits)
      callback_names = normalizer.expected_physical_callback_roster
      role_names = physical.stream_names
      if callback_names.empty? || role_names.empty?
        raise UnsupportedFormatError.new("Compact static column has no physical callbacks")
      end
      reverse_names = Hash(String, String).new(initial_capacity: role_names.size)
      role_names.each do |role, name|
        if reverse_names.has_key?(name)
          raise UnsupportedFormatError.new("Compact static physical names are not unique")
        end
        reverse_names[name] = role
      end

      @callback_names = Array(String).new(callback_names.size)
      @callback_roles = Array(String).new(callback_names.size)
      seen_roles = Set(String).new
      callback_names.each do |callback_name|
        role = reverse_names[callback_name]? ||
               raise(UnsupportedFormatError.new("Compact static callback is outside the physical role plan"))
        unless seen_roles.add?(role)
          raise UnsupportedFormatError.new("Compact static callback schedule repeats a physical role")
        end
        @callback_names << String.new(callback_name.to_slice)
        @callback_roles << String.new(role.to_slice)
      end
      unless @callback_roles.size == role_names.size && seen_roles.size == role_names.size
        raise UnsupportedFormatError.new("Compact static callback schedule is incomplete")
      end
    end

    # Ordered logical roles corresponding to physical serializer callbacks.
    # This is intentionally not sorted: Compact writes callbacks in serializer
    # order while BinaryBulkStreams.roles is a lexical lookup roster.
    def callback_roles : Array(String)
      @callback_roles.map { |role| String.new(role.to_slice) }
    end

    # Ordered physical stream names matching callback_roles. This is the
    # persisted MRK4 substream identity roster, not a lexical role lookup list.
    def callback_names : Array(String)
      @callback_names.map { |name| String.new(name.to_slice) }
    end
  end
end
