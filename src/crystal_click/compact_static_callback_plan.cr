module CrystalClick
  # Seals the ordered Compact callback schedule for one static BinaryBulk
  # column. Logical body roles remain owned by BinaryBulkTypePlan; generated
  # state prefixes are separate physical callback events over their source role.
  class CompactStaticCallbackPlan
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter column_name : String
    getter variant_discriminator_mode : CompactVariantDiscriminatorMode

    @callback_events : Array(CompactBinaryBulkCallback)
    @callback_roles : Array(String)
    @dictionary_prefix_roles : Array(String)
    @variant_discriminator_roles : Array(String)

    def initialize(
      input : CompactStaticColumnInput,
      limits : BinaryCodecLimits,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
    )
      @type = input.type
      @profile = input.profile
      @column_name = String.new(input.name.to_slice)
      @variant_discriminator_mode.wire_value

      raise ArgumentError.new("Compact static column name must be nonempty") if @column_name.empty?
      unless @profile.single_stream? || @profile.with_size_stream?
        raise UnsupportedFormatError.new("Compact static writer requires a supported String profile")
      end
      unless input.map_basic?
        raise UnsupportedFormatError.new("Compact static writer requires BASIC Map serialization")
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

      body_roles_by_name = Hash(String, String).new(initial_capacity: role_names.size)
      prefix_roles_by_name = Hash(String, Tuple(String, Int32)).new
      callback_names_by_role = Hash(String, String).new(initial_capacity: role_names.size)
      role_names.each do |role, name|
        if body_roles_by_name.has_key?(name) || prefix_roles_by_name.has_key?(name) ||
           callback_names_by_role.has_key?(role)
          raise UnsupportedFormatError.new("Compact static physical role plan is not unique")
        end
        body_roles_by_name[name] = role
        callback_names_by_role[role] = name

        prefix_size = physical.prefix_size_for(role)
        if prefix_size > 0
          unless prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
            raise UnsupportedFormatError.new("Compact static writer requires an admitted eight-byte state prefix")
          end
          prefix_name = PhysicalStreamName.append_literal(name, "_prefix")
          if body_roles_by_name.has_key?(prefix_name) || prefix_roles_by_name.has_key?(prefix_name)
            raise UnsupportedFormatError.new("Compact static physical prefix name is not unique")
          end
          prefix_roles_by_name[prefix_name] = {role, prefix_size}
        end
      end

      @callback_events = Array(CompactBinaryBulkCallback).new(callback_names.size)
      @callback_roles = [] of String
      @dictionary_prefix_roles = [] of String
      @variant_discriminator_roles = [] of String
      seen_body_roles = Set(String).new
      seen_prefix_roles = Set(String).new
      seen_names = Set(String).new
      callback_names.each do |callback_name|
        unless seen_names.add?(callback_name)
          raise UnsupportedFormatError.new("Compact static callback schedule repeats a physical callback")
        end

        if role = body_roles_by_name[callback_name]?
          unless seen_body_roles.add?(role)
            raise UnsupportedFormatError.new("Compact static callback schedule repeats a body role")
          end
          @callback_events << CompactBinaryBulkCallback.new(callback_name, role, 0)
          @callback_roles << String.new(role.to_slice)
        elsif prefix = prefix_roles_by_name[callback_name]?
          role, prefix_size = prefix
          if role.ends_with?(".dictionary")
            unless callback_name.ends_with?(".dict_prefix")
              raise UnsupportedFormatError.new("Compact LowCardinality prefix is not bound to a dictionary role")
            end
            @dictionary_prefix_roles << String.new(role.to_slice)
          elsif role.ends_with?(".discriminators")
            unless callback_name.ends_with?(".variant_discr_prefix")
              raise UnsupportedFormatError.new("Compact Variant prefix is not bound to a discriminator role")
            end
            @variant_discriminator_roles << String.new(role.to_slice)
          else
            raise UnsupportedFormatError.new("Compact static writer does not admit this state-prefix role")
          end
          unless seen_prefix_roles.add?(role)
            raise UnsupportedFormatError.new("Compact static callback schedule repeats a state prefix")
          end
          @callback_events << CompactBinaryBulkCallback.new(callback_name, role, prefix_size)
        else
          raise UnsupportedFormatError.new("Compact static callback is outside the physical role plan")
        end
      end

      unless seen_body_roles.size == role_names.size &&
             @callback_roles.size == role_names.size &&
             seen_prefix_roles.size == prefix_roles_by_name.size
        raise UnsupportedFormatError.new("Compact static callback schedule is incomplete")
      end
      seen_prefix_roles.each do |role|
        unless seen_body_roles.includes?(role) && callback_names_by_role.has_key?(role)
          raise UnsupportedFormatError.new("Compact state prefix has no matching body callback")
        end
      end
      if @type.contains_low_cardinality? != !@dictionary_prefix_roles.empty?
        raise UnsupportedFormatError.new("Compact LowCardinality type and dictionary prefix roster differ")
      end
      if @type.contains_variant? != !@variant_discriminator_roles.empty?
        raise UnsupportedFormatError.new("Compact Variant type and discriminator prefix roster differ")
      end
    end

    # Ordered logical roles corresponding only to body callbacks. Prefix events
    # intentionally share their source role and are not BinaryBulk lanes.
    def callback_roles : Array(String)
      @callback_roles.map { |role| String.new(role.to_slice) }
    end

    # Ordered physical stream names matching actual Compact callback events.
    # This roster drives MRK4 slots; MRK3 still has one slot per column.
    def callback_names : Array(String)
      @callback_events.map(&.name)
    end

    def callback_events : Array(CompactBinaryBulkCallback)
      @callback_events.dup
    end

    def dictionary_prefix_roles : Array(String)
      @dictionary_prefix_roles.map { |role| String.new(role.to_slice) }
    end

    def variant_discriminator_roles : Array(String)
      @variant_discriminator_roles.map { |role| String.new(role.to_slice) }
    end

    def dictionary_prefix_role?(role : String) : Bool
      @dictionary_prefix_roles.includes?(role)
    end

    def variant_discriminator_role?(role : String) : Bool
      @variant_discriminator_roles.includes?(role)
    end

    def includes_callback_event?(candidate : CompactBinaryBulkCallback) : Bool
      candidate_name = candidate.name
      candidate_role = candidate.role
      @callback_events.any? do |event|
        event.name == candidate_name && event.role == candidate_role &&
          event.prefix_size == candidate.prefix_size
      end
    end

    def each_callback_event(&block : CompactBinaryBulkCallback -> Nil) : Nil
      @callback_events.each do |callback|
        yield callback
      end
      nil
    end
  end
end
