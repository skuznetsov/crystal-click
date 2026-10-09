module CrystalClick
  module BinaryAggregateMinMaxArgumentPolicy
    # The normalized input and dispatched state family are operation metadata;
    # the AggregateFunction descriptor continues to retain the nominal type.
    class Profile
      getter input_type : BinaryDataType
      getter state_kind : StateKind
      getter? nullable_argument : Bool

      def initialize(@input_type : BinaryDataType, @state_kind : StateKind, @nullable_argument : Bool)
      end
    end
  end
end
