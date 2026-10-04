module CrystalClick
  # Nominal Dynamic-site provenance for Object typed declarations. This owner
  # does not parse values, infer rosters, or widen the Object arm domain.
  module ObjectDeclaredDynamicSites
    struct SiteSpec
      getter path : String
      getter type : BinaryDataType
      getter object_depth : Int32

      def initialize(@path : String, @type : BinaryDataType, @object_depth : Int32)
      end

      def actual_root_depth : Int32
        @object_depth + 1
      end
    end

    struct Shape
      getter count : UInt64
      getter path_bytes : UInt64

      def initialize(@count : UInt64, @path_bytes : UInt64)
      end
    end

    # Count and byte-bound generated site keys without allocating them. The
    # plan owner aggregates these results across every typed field first.
    def self.shape_for(
      type : BinaryDataType,
      limits : BinaryCodecLimits = ObjectRecursiveDeclaration::DEFAULT_LIMITS,
      root_depth : Int = 2,
    ) : Shape
      unless ObjectRecursiveDeclaration.measure_descriptor(type, limits, root_depth)
        raise UnsupportedFormatError.new("typed JSON schema admits only supported Object recursive types")
      end
      measure_shape(type, "root".bytesize.to_u64)
    end

    # Materialize canonical generic site paths after complete-roster
    # preflight. Object depth is retained separately because generic Dynamic
    # plans use a different depth origin.
    def self.for_type(
      type : BinaryDataType,
      limits : BinaryCodecLimits = ObjectRecursiveDeclaration::DEFAULT_LIMITS,
      root_depth : Int = 2,
    ) : Array(SiteSpec)
      shape = shape_for(type, limits, root_depth)
      if shape.count > limits.max_nodes.to_u64 || shape.count > limits.max_elements.to_u64
        raise UnsupportedFormatError.new("typed Object Dynamic site count exceeds codec limits")
      end
      if shape.path_bytes > limits.max_bytes.to_u64
        raise UnsupportedFormatError.new("typed Object Dynamic site keys exceed codec byte limit")
      end
      return [] of SiteSpec if shape.count == 0_u64
      sites = Array(SiteSpec).new(shape.count.to_i)
      collect(type, "root", root_depth.to_i32, sites)
      unless sites.size.to_u64 == shape.count
        raise UnsupportedFormatError.new("typed Object Dynamic site preflight changed during materialization")
      end
      sites
    end

    def self.validate_roster!(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      limits : BinaryCodecLimits,
      root_depth : Int = 2,
      budget : BinaryCodecBudget? = nil,
    ) : Array(SiteSpec)
      if operation_budget = budget
        unless operation_budget.writing?
          raise ArgumentError.new("typed Object Dynamic roster validation requires a writing budget")
        end
      end
      sites = for_type(type, limits, root_depth)
      unless structures.size == sites.size
        raise UnsupportedFormatError.new("typed Object Dynamic structures must exactly match declared sites")
      end
      sites.each do |site|
        structure = structures[site.path]? || raise UnsupportedFormatError.new("typed Object Dynamic structure is missing site: #{site.path.inspect}")
        maximum = ObjectDeclaredDynamicDeclaration.max_types_for(site.type) ||
                  raise UnsupportedFormatError.new("typed Object Dynamic site is not canonical")
        if structure.type_count > maximum
          raise UnsupportedFormatError.new("typed Object Dynamic roster exceeds its declared max_types cap")
        end
        ObjectDeclaredDynamicDeclaration.validate_actual_structure!(structure, limits, site.actual_root_depth, budget)
      end
      sites
    end

    private def self.measure_shape(type : BinaryDataType, path_bytes : UInt64) : Shape
      if type.tag == BinaryDataType::TAG_DYNAMIC
        return Shape.new(1_u64, path_bytes)
      end
      case type.tag
      when BinaryDataType::TAG_ARRAY
        measure_shape(type.child_at(0), checked_add(path_bytes, ".elements".bytesize.to_u64))
      when BinaryDataType::TAG_NULLABLE
        measure_shape(type.child_at(0), checked_add(path_bytes, ".nested".bytesize.to_u64))
      when BinaryDataType::TAG_MAP
        measure_shape(type.child_at(1), checked_add(path_bytes, ".elements.field.1".bytesize.to_u64))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = 0_u64
        bytes = 0_u64
        type.child_count.times do |index|
          child_bytes = checked_add(path_bytes, checked_add(".field.".bytesize.to_u64, decimal_digits(index).to_u64))
          child_shape = measure_shape(type.child_at(index), child_bytes)
          count = checked_add(count, child_shape.count)
          bytes = checked_add(bytes, child_shape.path_bytes)
        end
        Shape.new(count, bytes)
      when BinaryDataType::TAG_VARIANT
        count = 0_u64
        bytes = 0_u64
        type.child_count.times do |index|
          child_bytes = checked_add(path_bytes, checked_add(".arm.".bytesize.to_u64, decimal_digits(index).to_u64))
          child_shape = measure_shape(type.child_at(index), child_bytes)
          count = checked_add(count, child_shape.count)
          bytes = checked_add(bytes, child_shape.path_bytes)
        end
        Shape.new(count, bytes)
      else
        Shape.new(0_u64, 0_u64)
      end
    end

    private def self.collect(type : BinaryDataType, path : String, object_depth : Int32, sites : Array(SiteSpec)) : Nil
      if type.tag == BinaryDataType::TAG_DYNAMIC
        sites << SiteSpec.new(path, type, object_depth)
        return nil
      end
      case type.tag
      when BinaryDataType::TAG_ARRAY
        child = type.child_at(0)
        collect(child, path + ".elements", object_depth + 1, sites) if child.contains_dynamic?
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        collect(child, path + ".nested", object_depth + 1, sites) if child.contains_dynamic?
      when BinaryDataType::TAG_MAP
        child = type.child_at(1)
        collect(child, path + ".elements.field.1", object_depth + 1, sites) if child.contains_dynamic?
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_dynamic?
          collect(child, path + ".field." + index.to_s, object_depth + 1, sites)
        end
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_dynamic?
          collect(child, path + ".arm." + index.to_s, object_depth + 1, sites)
        end
      end
      nil
    end

    private def self.decimal_digits(value : Int32) : Int32
      digits = 1
      while value >= 10
        value //= 10
        digits += 1
      end
      digits
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("typed Object Dynamic site metadata overflows UInt64")
      end
      left + right
    end
  end
end
