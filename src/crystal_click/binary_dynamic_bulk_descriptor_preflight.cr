module CrystalClick
  # One-shot proof that the exact descriptor was already bounded and had its
  # display-name metadata materialized under the caller's shared budget.
  # Recursive physical-site readers use this instead of a Boolean validation
  # bypass, preserving one owner per class and one aggregate descriptor walk.
  class BinaryDynamicBulkDescriptorPreflight
    @type : BinaryDataType
    @budget : BinaryCodecBudget
    @initial_depth : Int32
    @consumed : Bool

    private def initialize(@type : BinaryDataType, @budget : BinaryCodecBudget, @initial_depth : Int32)
      @consumed = false
    end

    def self.admit(
      type : BinaryDataType,
      budget : BinaryCodecBudget,
      initial_depth : Int32 = 1,
    ) : BinaryDynamicBulkDescriptorPreflight
      bounds = BinaryTypeNameBudget.measure(type, budget, initial_depth)
      BinaryTypeNameBudget.materialize(type, budget, bounds)
      new(type, budget, initial_depth)
    end

    def consume!(type : BinaryDataType, budget : BinaryCodecBudget, initial_depth : Int32) : Nil
      unless !@consumed && @type.same?(type) && @budget.same?(budget) && @initial_depth == initial_depth
        raise ArgumentError.new("Dynamic descriptor preflight does not match this site decode")
      end
      @consumed = true
    end
  end
end
