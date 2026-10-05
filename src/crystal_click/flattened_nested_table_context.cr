module CrystalClick
  # Detached caller binding for the bounded flattened-Nested table view.
  # W173 remains the only owner of physical roster and stream validation.
  class FlattenedNestedTableContext
    @key_name : String
    @group_name : String
    @type_name : String

    def initialize(key_name : String, group_name : String, type_name : String)
      # The expected key is caller-bound too, including key-only selection.
      # Reject oversized names before retaining them; then W173 owns parsing
      # the declaration and the exact physical roster/axis validation.
      if key_name.empty? || key_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES ||
         group_name.empty? || group_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("column name is empty or exceeds limit")
      end

      unless /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(key_name) && key_name != group_name
        raise UnsupportedFormatError.new("flattened Nested expected key must be a distinct simple column name")
      end

      plan = WidePart::FlattenedNestedStoragePlan.for_type(group_name, type_name) ||
             raise UnsupportedFormatError.new("unsupported flattened Nested declaration or group name")

      # Snapshot only after bounds and W173 parsing have admitted the caller's
      # values; use the plan's canonical declaration, not the input spelling.
      @key_name = String.new(key_name.to_slice)
      @group_name = String.new(group_name.to_slice)
      @type_name = String.new(plan.type_name.to_slice)
    end

    def key_name : String
      String.new(@key_name.to_slice)
    end

    def group_name : String
      String.new(@group_name.to_slice)
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    # Open the expected key first, even for group-only selection. This binds
    # the caller's key name to W173's complete physical roster and axis checks.
    def open_reader(path : String, column : String) : WidePart
      unless column == @key_name || column == @group_name
        raise UnsupportedFormatError.new("flattened Nested table selection must name only its key or logical root")
      end

      key_reader = WidePart.open_flattened_nested(path, @group_name, @type_name, @key_name)
      return key_reader if column == @key_name

      WidePart.open_flattened_nested(path, @group_name, @type_name, @group_name)
    end
  end
end
