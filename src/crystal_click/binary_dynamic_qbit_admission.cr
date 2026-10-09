module CrystalClick
  # Scoped actual-type profile for recursive QBit values selected by Dynamic.
  # It reuses the static-product grammar but keeps Dynamic's root roster law
  # and every runtime-owned sibling boundary independent.
  module BinaryDynamicQBitAdmission
    def self.admitted_actual_type?(type : BinaryDataType) : Bool
      return true unless type.contains_qbit?
      return true if type.tag == BinaryDataType::TAG_QBIT

      # Dynamic V3 rejects these as immediate actuals even when their static
      # descendants are otherwise representable. They may occur below a
      # legal Array/Tuple/Map wrapper where the source grammar permits them.
      return false if type.tag == BinaryDataType::TAG_NULLABLE || type.tag == BinaryDataType::TAG_VARIANT

      # These nominal owners carry independent physical representations. A
      # QBit-bearing product cannot use the static visitor to bypass them, nor
      # can a QBit-free sibling bring one into the newly admitted profile.
      return false if type.contains_dynamic? ||
                      type.contains_low_cardinality? ||
                      type.contains_aggregate_function? ||
                      type.contains_json?
      return false unless BinaryDataType.admitted_qbit_static_composition?(type)

      simple_aggregate_free?(type)
    end

    private def self.simple_aggregate_free?(type : BinaryDataType) : Bool
      # SimpleAggregateFunction is not covered by a cached whole-tree summary
      # because it owns its storage child nominally. Walk every child (not just
      # QBit-bearing branches) so an unrelated sibling cannot be overlooked.
      # Keep auxiliary storage proportional to descriptor depth rather than
      # tuple width: a wide QBit-bearing tuple must not allocate a second
      # roster-sized list merely to inspect its siblings.
      frames = [] of Tuple(BinaryDataType, Int32)
      frames << {type, 0}
      until frames.empty?
        frame_index = frames.size - 1
        current = frames[frame_index][0]
        return false if current.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE

        next_child = frames[frame_index][1]
        if next_child < current.child_count
          frames[frame_index] = {current, next_child + 1}
          frames << {current.child_at(next_child), 0}
        else
          frames.pop
        end
      end
      true
    end
  end
end
