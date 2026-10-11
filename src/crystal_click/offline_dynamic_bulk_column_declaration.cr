module CrystalClick
  # Lexical-whitespace bridge from offline SQL DDL to the unchanged strict
  # Dynamic BinaryBulk declaration owner. It does not canonicalize aliases.
  class OfflineDynamicBulkColumnDeclaration
    DEFAULT_LIMITS = DynamicBulkColumnDeclaration::DEFAULT_LIMITS

    # Returns whether the neutral syntax tree contains Dynamic, together with
    # its strict admitted descriptor when the source differs from canonical
    # spelling only by whitespace outside quoted tokens. Exact bare Dynamic
    # remains on its existing specialized route and therefore has no result.
    def self.resolve(
      source : String,
      root_depth : Int32 = 1,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
    ) : Tuple(Bool, BinaryDataType?)
      dynamic_candidate : Bool = false
      begin
        return {false, nil} if source.bytesize.to_i64 > limits.max_bytes

        type = BinaryRecursiveDataTypeNameReader.new(source, limits).parse || return {false, nil}
        return {false, nil} unless type.contains_dynamic?
        dynamic_candidate = true
        return {true, nil} if source == "Dynamic"

        render_budget = BinaryCodecBudget.new(limits, true)
        bounds = BinaryTypeNameBudget.measure(type, render_budget, root_depth)
        canonical = BinaryTypeNameBudget.materialize(type, render_budget, bounds)
        return {true, nil} unless whitespace_only_difference?(source, canonical)

        declared = DynamicBulkColumnDeclaration.parse(canonical, root_depth, limits)
        {true, declared}
      rescue ex : ArgumentError | CorruptPartError | UnsupportedFormatError
        {dynamic_candidate, nil}
      end
    end

    private def self.whitespace_only_difference?(source : String, canonical : String) : Bool
      source_bytes = source.to_slice
      canonical_bytes = canonical.to_slice
      source_index = 0
      canonical_index = 0

      loop do
        source_index = skip_whitespace(source_bytes, source_index)
        canonical_index = skip_whitespace(canonical_bytes, canonical_index)
        source_done = source_index == source_bytes.size
        canonical_done = canonical_index == canonical_bytes.size
        return source_done && canonical_done if source_done || canonical_done

        source_byte = source_bytes[source_index]
        canonical_byte = canonical_bytes[canonical_index]
        return false unless source_byte == canonical_byte

        if quote_byte?(source_byte)
          quote = source_byte
          source_index += 1
          canonical_index += 1
          closed = false
          while source_index < source_bytes.size && canonical_index < canonical_bytes.size
            source_byte = source_bytes[source_index]
            canonical_byte = canonical_bytes[canonical_index]
            return false unless source_byte == canonical_byte

            if source_byte == '\\'.ord.to_u8
              return false if source_index + 1 >= source_bytes.size || canonical_index + 1 >= canonical_bytes.size
              return false unless source_bytes[source_index + 1] == canonical_bytes[canonical_index + 1]
              source_index += 2
              canonical_index += 2
            elsif source_byte == quote
              source_index += 1
              canonical_index += 1
              closed = true
              break
            else
              source_index += 1
              canonical_index += 1
            end
          end
          return false unless closed
        else
          source_index += 1
          canonical_index += 1
        end
      end
    end

    private def self.skip_whitespace(bytes : Bytes, start : Int32) : Int32
      index = start
      while byte = bytes[index]?
        break unless byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
        index += 1
      end
      index
    end

    private def self.quote_byte?(byte : UInt8) : Bool
      byte == '\''.ord.to_u8 || byte == '`'.ord.to_u8
    end
  end
end
