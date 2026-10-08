module CrystalClick
  # Contextual admission for AggregateFunction leaves in static DataType
  # compositions. AggregateFunction arguments remain nominal descriptor
  # metadata; this visitor follows only ordinary composition children.
  module BinaryAggregateFunctionRecursiveAdmission
    # AF-free siblings are intentionally skipped, so a LowCardinality or
    # Variant sibling does not invalidate an otherwise static AF branch.
    # A containing wrapper is accepted only when every AF-containing path
    # stays within the static composition grammar.
    def self.admitted_static_tree?(type : BinaryDataType) : Bool
      return true unless type.contains_aggregate_function?

      stack = [] of Frame
      stack << Frame.new(type)

      until stack.empty?
        frame = stack.last
        current = frame.type

        unless current.contains_aggregate_function?
          stack.pop
          next
        end

        case current.tag
        when BinaryDataType::TAG_AGGREGATE_FUNCTION
          stack.pop
        when BinaryDataType::TAG_ARRAY
          stack.pop
          child = current.child_at(0)
          stack << Frame.new(child) if child.contains_aggregate_function?
        when BinaryDataType::TAG_NESTED
          stack.pop
          tuple = current.child_at(0)
          stack << Frame.new(tuple) if tuple.contains_aggregate_function?
        when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_VARIANT
          if frame.next_child >= current.child_count
            stack.pop
          else
            child = current.child_at(frame.next_child)
            frame.next_child += 1
            if child.contains_aggregate_function?
              stack << Frame.new(child)
            end
          end
        when BinaryDataType::TAG_MAP
          stack.pop
          key = current.child_at(0)
          return false if key.contains_aggregate_function?
          value = current.child_at(1)
          stack << Frame.new(value) if value.contains_aggregate_function?
        when BinaryDataType::TAG_NULLABLE
          stack.pop
          child = current.child_at(0)
          return false unless child.tag == BinaryDataType::TAG_UNNAMED_TUPLE ||
                              child.tag == BinaryDataType::TAG_NAMED_TUPLE
          stack << Frame.new(child) if child.contains_aggregate_function?
        else
          # LowCardinality, Dynamic, JSON, SimpleAggregateFunction, and every
          # non-static/custom route stay closed when they contain an
          # AggregateFunction state. Variant alternatives are handled like
          # tuple fields above: every state-bearing path must independently
          # satisfy this static grammar, while AF-free siblings are neutral.
          return false
        end
      end

      true
    end

    def self.require_static_tree!(type : BinaryDataType) : Nil
      unless admitted_static_tree?(type)
        raise ArgumentError.new("AggregateFunction is outside the admitted static composition path")
      end
      nil
    end
  end
end
