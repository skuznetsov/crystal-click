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
          # Dynamic route. Parameterized/recursive declarations must pass the
          # stricter DynamicBulk owner rather than falling through to a broad
          # nominal type predicate.
          return existing_leaf_admitted?(selected_type) if source_type == "Dynamic"
          dynamic_type = DynamicBulkColumnDeclaration.parse(source_type) || return false
          return dynamic_type.name == selected_type
        end
      end

      existing_leaf_admitted?(selected_type)
    end

    private def self.existing_leaf_admitted?(type : String) : Bool
      WidePart.supports_typed_type?(type) || WidePart.supports_generic_static_binary_bulk_type?(type)
    end
  end
end
