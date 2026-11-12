module CrystalClick
  # Bounded public entry point for the first complete-part Compact writer.
  # This API intentionally has no ignored Wide-only options.
  module CompactPartWriter
    # Type-only Compact owner admission used by catalog transforms before
    # invoking caller code. The full writer still validates concrete owner
    # contexts, values, budgets, and physical callback schedules.
    def self.validate_target_declaration!(
      declaration : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : Nil
      type = BinaryRecursiveDataTypeNameReader.parse_canonical(declaration, limits)
      unless type
        if schema = CompactJsonColumnAdapter.schema_for_json_declaration(declaration, limits)
          return validate_json_target_schema!(declaration, schema, limits)
        end
        raise UnsupportedFormatError.new("Compact target declaration is not a canonical BinaryDataType")
      end

      if type.contains_json?
        schema = CompactJsonColumnAdapter.schema_for_json_declaration(declaration, limits) ||
                 raise UnsupportedFormatError.new("Compact JSON target declaration has no admitted schema owner")
        validate_json_target_schema!(declaration, schema, limits)
      elsif type.contains_dynamic?
        CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(type, limits)
      else
        CompactStaticCallbackPlan.validate_declaration!(type, limits)
      end
      nil
    end

    private def self.validate_json_target_schema!(
      declaration : String,
      schema : StorageColumnSchema,
      limits : BinaryCodecLimits,
    ) : Nil
      unless schema.declaration == declaration && CompactRecursiveJsonSchemaPlan.admitted_schema?(schema, limits)
        raise UnsupportedFormatError.new("Compact JSON target declaration is outside the admitted exact schema subset")
      end
      nil
    end

    def self.write_uint64_columns(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      columns : Array(CompactPartColumn),
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      reader_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      mark_format : CompactMarkFormat = CompactMarkFormat::Mrk3,
      variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
      compress_marks : Bool = false,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      schema_binding : PartSchemaBinding? = nil,
      projections : Indexable(WidePartProjection | CompactPartProjection) = [] of WidePartProjection,
    ) : String
      CompactPartOperation.write_uint64_columns(
        destination,
        key_name,
        keys,
        columns,
        rows_per_mark,
        frame_bytes,
        limits,
        transport_limits,
        reader_limits,
        mark_format,
        variant_discriminator_mode,
        compress_marks,
        profile,
        schema_binding,
        projections,
      )
    end
  end
end
