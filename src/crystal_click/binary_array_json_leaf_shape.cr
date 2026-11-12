module CrystalClick
  # Recognizes an exact descriptor path made only of one-child Array wrappers
  # ending at a JSON leaf. Owner/site and canonical-arm identity stay with the
  # caller; this helper only validates the type shape and path indices.
  class BinaryArrayJsonLeafShape
    private def initialize
    end

    # Return the exact number of Array wrappers, including zero for a direct
    # JSON actual. A nil result means the descriptor path is not Array* -> JSON
    # or exceeds the active codec path bound.
    def self.wrapper_count?(
      actual_type : BinaryDataType,
      key : BinaryDynamicJsonLeafKey,
      max_path_depth : Int32,
    ) : Int32?
      return nil if max_path_depth < 0
      wrapper_count = key.descriptor_path_size
      return nil if wrapper_count > max_path_depth

      leaf_type = actual_type
      wrapper_count.times do |path_index|
        return nil unless key.descriptor_child_at(path_index) == 0 &&
                           leaf_type.tag == BinaryDataType::TAG_ARRAY &&
                           leaf_type.child_count == 1
        leaf_type = leaf_type.child_at(0)
      end

      leaf_type.tag == BinaryDataType::TAG_JSON ? wrapper_count : nil
    end
  end
end
