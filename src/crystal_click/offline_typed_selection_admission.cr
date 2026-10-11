module CrystalClick
  # Selection-aware bridge from OfflineTable DDL names to the existing typed
  # storage owners. This class only chooses an owner; it does not add a codec
  # or widen any owner's declaration grammar.
  class OfflineTypedSelectionAdmission
    def self.admitted?(source_type : String, selected_type : String, json_path : Bool) : Bool
      return existing_leaf_admitted?(selected_type) if json_path

      if WidePart.json_type?(source_type)
        schema = ObjectDocumentSchema.parse_declaration(source_type)
        return schema.declaration == selected_type
      end

      if type = BinaryRecursiveDataTypeNameReader.parse_canonical(source_type)
        if type.contains_json?
          schema = StorageColumnSchema.parse(source_type)
          return schema.has_json? && schema.declaration == source_type && schema.declaration == selected_type
        end

        if type.contains_dynamic?
          # The unparameterized spelling keeps its existing specialized
          # Dynamic route. Other declarations pass the offline lexical bridge
          # and then the unchanged strict DynamicBulk owner.
          return existing_leaf_admitted?(selected_type) if source_type == "Dynamic"
          candidate, dynamic_type = OfflineDynamicBulkColumnDeclaration.resolve(source_type)
          return false unless candidate
          dynamic_type = dynamic_type || return false
          return dynamic_type.name == selected_type
        end
      end

      # Offline CREATE TABLE parsing retains the source spelling, while
      # selected_type is the canonical physical declaration. Admit only a
      # Dynamic-bearing source whose neutral parse proves whitespace-only
      # lexical normalization; aliases and other semantic rewrites stay out.
      candidate, dynamic_type = OfflineDynamicBulkColumnDeclaration.resolve(source_type)
      if candidate
        dynamic_type = dynamic_type || return false
        return dynamic_type.name == selected_type
      end

      existing_leaf_admitted?(selected_type)
    end

    private def self.existing_leaf_admitted?(type : String) : Bool
      WidePart.supports_typed_type?(type) || WidePart.supports_generic_static_binary_bulk_type?(type)
    end
  end
end
