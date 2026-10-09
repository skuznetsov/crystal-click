module CrystalClick
  # Owns normal Variant roster canonicalization. It is deliberately only a
  # descriptor policy: arm values continue through BinaryValueCodec's single
  # recursive visitor rather than per-arm or per-container facades.
  module BinaryVariantRoster
    MAX_ARMS = 255

    alias NamedArm = Tuple(String, BinaryDataType)
    alias MeasuredArm = Tuple(BinaryDataType, BinaryTypeNameBudget::Bounds)

    def self.normalize(
      arms : Array(BinaryDataType),
      budget : BinaryCodecBudget,
      variant_depth : Int,
      account_variant_node : Bool,
      account_roster_edges : Bool,
      strict_wire : Bool,
    ) : Array(BinaryDataType)
      budget.visit_node(variant_depth) if account_variant_node
      raise ArgumentError.new("Variant has no non-Nothing arms") if arms.empty?
      budget.preflight_children(arms.size.to_u64) if account_roster_edges
      budget.ensure_depth(variant_depth + 1)

      measured_count = 0
      arms.each do |arm|
        validate_direct_arm!(arm)
        measured_count += 1 unless arm.tag == BinaryDataType::TAG_NOTHING
      end
      if measured_count == 0
        raise ArgumentError.new("Variant has no non-Nothing arms")
      end

      # These scratch arrays are sized only after roster edge/node preflight;
      # name traversal itself adds its visits to the same operation budget.
      budget.ensure_future_nodes(measured_count.to_u64)
      measured = Array(MeasuredArm).new(measured_count)
      total_name_work = 0_u64
      arms.each do |arm|
        next if arm.tag == BinaryDataType::TAG_NOTHING
        bounds = BinaryTypeNameBudget.measure(arm, budget, variant_depth + 1)
        total_name_work = BinaryTypeNameBudget.add(total_name_work, bounds[1])
        measured << {arm, bounds}
      end

      # Reserve all recursive name work before materializing the first SQL
      # name, so a later arm cannot fail after earlier unbounded work occurred.
      budget.ensure_wire_bytes(total_name_work)
      named = Array(NamedArm).new(measured_count)
      measured.each do |arm, bounds|
        named << {BinaryTypeNameBudget.materialize(arm, budget, bounds), arm}
      end
      named.sort! { |left, right| left[0] <=> right[0] }

      canonical = Array(BinaryDataType).new([named.size, MAX_ARMS].min)
      last_name : String? = nil
      last_type : BinaryDataType? = nil
      named.each do |name, arm|
        if previous_name = last_name
          if name == previous_name
            previous_type = last_type.not_nil!
            unless arm == previous_type
              raise ArgumentError.new("Variant alternatives with equal SQL names have unequal nominal descriptors")
            end
            next
          end
        end
        canonical << arm
        last_name = name
        last_type = arm
      end

      if canonical.empty? || canonical.size > MAX_ARMS
        raise ArgumentError.new("Variant must contain between 1 and 255 normalized arms")
      end

      if strict_wire
        canonical_order = arms.size == canonical.size
        if canonical_order
          arms.each_with_index do |arm, index|
            unless arm == canonical[index]
              canonical_order = false
              break
            end
          end
        end
        unless canonical_order
          raise ArgumentError.new("Variant wire roster is not in strict canonical order")
        end
      end

      canonical
    end

    private def self.validate_direct_arm!(arm : BinaryDataType) : Nil
      if arm.contains_qbit? && !BinaryDataType.admitted_qbit_static_composition?(arm)
        raise ArgumentError.new("QBit is outside the admitted static Variant composition path")
      end
      if arm.tag == BinaryDataType::TAG_DYNAMIC
        raise ArgumentError.new("Variant cannot directly contain Dynamic")
      end
      if arm.tag == BinaryDataType::TAG_NULLABLE
        raise ArgumentError.new("Variant cannot directly contain Nullable")
      end
      if arm.variant_type_id?
        raise ArgumentError.new("Variant cannot directly contain Variant")
      end
      if arm.tag == BinaryDataType::TAG_LOW_CARDINALITY && arm.child_at(0).tag == BinaryDataType::TAG_NULLABLE
        raise ArgumentError.new("Variant cannot directly contain LowCardinality(Nullable(...))")
      end
    end
  end
end
