module CrystalClick
  # Structured RowBinary profile for one JSON scalar value. This is intentionally
  # separate from persisted Object shared-map and physical bulk encodings.
  # Value callbacks re-enter BinaryValueCodec's private scalar visitor with
  # the same budget and rebased depth.
  private class BinaryJsonValueCodec
    def self.write(
      row : BinaryJsonRow,
      context : BinaryCodecContext,
      depth : Int,
      &write_value : BinaryValue, Int32 -> Nil
    ) : Nil
      count = row.path_count.to_u64
      if count > 0_u64
        # One metadata node and one value edge per flattened path. Preflight
        # the aggregate path bytes before calling any copying path accessor.
        context.preflight_children(count)
        context.visit_metadata_nodes(count, depth)
        context.preflight_children(count)
        context.ensure_depth(depth + 1)
        path_wire_bytes = 0_u64
        row.path_count.times do |index|
          path_wire_bytes = checked_add(
            path_wire_bytes,
            BinaryJsonType.path_wire_size(row.path_byte_size(index).to_u64),
            context,
          )
        end
        context.ensure_output_bytes(path_wire_bytes)
      end

      context.write_var_uint(count)
      descriptor = row.type.json_type || context.unsupported!("JSON descriptor metadata is missing")
      row.path_count.times do |index|
        path_size = row.path_byte_size(index)
        path = row.path_at(index) # materialize only after aggregate preflight
        context.write_var_uint(path_size.to_u64)
        path_size.times do |byte_index|
          context.write_byte(row.path_byte_at(index, byte_index))
        end

        value = row.value_at(index)
        # A runtime JSON path serializes its nominal descriptor in the row;
        # both it and the following scalar must remain inside the JSON ancestry
        # fence. Typed paths are fenced by their descriptor metadata above.
        context.with_shared_json_payload_scope do
          if descriptor.typed_type_for(path).nil?
            BinaryDataTypeCodec.write_to(value.type, context, depth + 1)
          end
          yield value, depth + 1
        end
      end
      nil
    end

    def self.read(
      type : BinaryDataType,
      context : BinaryCodecContext,
      depth : Int,
      &read_value : BinaryDataType, Int32 -> BinaryValue
    ) : BinaryJsonRow
      descriptor = type.json_type || context.unsupported!("JSON descriptor metadata is missing")
      raw_count = context.read_var_uint
      count = context.preflight_metadata(
        raw_count,
        2_u64, # path-length prefix and at least one path byte
        context.limits.max_elements.to_u64,
        "JSON row path count",
      )
      if raw_count > 0_u64
        context.visit_metadata_nodes(raw_count, depth)
        context.preflight_children(raw_count) # one value edge per path
        context.ensure_depth(depth + 1)
      end

      entries = Array(Tuple(String, BinaryValue)).new(count)
      seen_paths = Set(String).new
      supplied_typed = Set(String).new
      count.times do
        raw_path_size = context.read_var_uint
        if raw_path_size == 0_u64 || raw_path_size > BinaryJsonType::MAX_PATH_BYTES.to_u64
          context.unsupported!("JSON row path is empty or exceeds the embedded raw-name byte limit")
        end
        raw_path = context.read_slice(raw_path_size)
        unless BinaryJsonType.valid_path_bytes?(raw_path)
          context.unsupported!("JSON row path is empty or exceeds the embedded raw-name byte limit")
        end
        path = String.new(raw_path)
        unless seen_paths.add?(path)
          context.corrupt!("JSON row contains a duplicate raw path")
        end

        value = context.with_shared_json_payload_scope do
          if path_type = descriptor.typed_type_for(path)
            supplied_typed.add(path)
            yield path_type, depth + 1
          else
            path_type = BinaryDataTypeCodec.read_from(context, depth + 1)
            if path_type.tag == BinaryDataType::TAG_NOTHING
              # Runtime Nothing is the descriptor-only NULL sentinel. The row
              # owner normalizes it to absence after raw duplicate validation.
              context.visit_node(depth + 1)
              BinaryValue.null(path_type)
            else
              if path_type.tag == BinaryDataType::TAG_NULLABLE
                context.unsupported!("top-level Nullable is outside the admitted JSON runtime-value profile")
              end
              begin
                BinaryJsonType.validate_runtime_type!(path_type)
              rescue ex : ArgumentError
                context.unsupported!("JSON runtime DataType is outside the admitted scalar/container profile")
              end
              yield path_type, depth + 1
            end
          end
        end
        # Skipped runtime lanes are still fully decoded under the shared
        # operation budget above. Only their retained row entry is omitted.
        unless descriptor.binary_path_skipped?(path)
          entries << {path, value}
        end
      end

      descriptor.typed_path_count.times do |index|
        path = descriptor.typed_path_at(index)
        unless supplied_typed.includes?(path)
          context.unsupported!("JSON row is missing an explicitly declared typed path")
        end
      end

      begin
        BinaryJsonRow.new(type, entries, context.limits)
      rescue ex : UnsupportedFormatError
        # The row owner uses a write-direction preflight context during public
        # construction. On wire decode, the same limit failure is corruption.
        context.corrupt!("JSON row exceeds the selected codec limits")
      rescue ex : ArgumentError
        context.corrupt!("JSON row is inconsistent with its descriptor: #{ex.message}")
      end
    end

    private def self.checked_add(left : UInt64, right : UInt64, context : BinaryCodecContext) : UInt64
      if left > UInt64::MAX - right
        context.unsupported!("JSON row path metadata size overflows UInt64")
      end
      left + right
    end
  end
end
