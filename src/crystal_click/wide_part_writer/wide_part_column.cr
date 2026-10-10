module CrystalClick
  # Typed facade for one value column in a schema-wide publication. Each
  # factory retains the nominal owner inputs; raw physical files are not a
  # public construction path.
  class WidePartColumn
    @prepare : Proc(WidePartWriter::WidePartOperationContext, WidePartWriter::WidePartPreparedColumn)

    private def initialize(
      @prepare : Proc(WidePartWriter::WidePartOperationContext, WidePartWriter::WidePartPreparedColumn),
    )
    end

    def self.binary_bulk(
      name : String,
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
    ) : WidePartColumn
      retained_name = String.new(name.to_slice)
      retained_granules = detach_binary_granules(granules)
      new(->(context : WidePartWriter::WidePartOperationContext) {
        WidePartWriter.prepare_static_wide_part_column(retained_name, type, retained_granules, context)
      })
    end

    def self.dynamic_bulk(
      name : String,
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      granules : Array(Array(BinaryValue)),
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : WidePartColumn
      retained_name = String.new(name.to_slice)
      retained_structures = Hash(String, DynamicStructure).new(initial_capacity: structures.size)
      structures.each { |path, structure| retained_structures[String.new(path.to_slice)] = structure }
      retained_granules = detach_binary_granules(granules)
      retained_json_plans = json_object_plans.try(&.dup)
      retained_json_leaf_plans = json_object_leaf_plans.try(&.dup)
      new(->(context : WidePartWriter::WidePartOperationContext) {
        WidePartWriter.prepare_dynamic_wide_part_column(
          retained_name, type, retained_structures, retained_granules,
          retained_json_plans, retained_json_leaf_plans, context
        )
      })
    end

    def self.object(
      name : String,
      schema : ObjectDocumentSchema,
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      shared_target_chunk_rows : Int32? = nil,
    ) : WidePartColumn
      retained_name = String.new(name.to_slice)
      retained_granules = detach_document_granules(granules)
      new(->(context : WidePartWriter::WidePartOperationContext) {
        WidePartWriter.prepare_object_wide_part_column(
          retained_name, schema, plan, retained_granules,
          shared_json_policy, shared_target_chunk_rows, context
        )
      })
    end

    def self.recursive(
      name : String,
      schema : StorageColumnSchema,
      object_plans : Hash(String, ObjectDocumentPlan),
      granules : Array(Array(StorageColumnValue)),
      dynamic_plans : Hash(String, BinaryDynamicBulkPlan)? = nil,
    ) : WidePartColumn
      retained_name = String.new(name.to_slice)
      retained_plans = Hash(String, ObjectDocumentPlan).new(initial_capacity: object_plans.size)
      object_plans.each { |site, plan| retained_plans[String.new(site.to_slice)] = plan }
      retained_granules = detach_storage_granules(granules)
      retained_dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new
      if plans = dynamic_plans
        plans.each { |site, plan| retained_dynamic_plans[String.new(site.to_slice)] = plan }
      end
      new(->(context : WidePartWriter::WidePartOperationContext) {
        WidePartWriter.prepare_recursive_wide_part_column(
          retained_name, schema, retained_plans, retained_granules,
          dynamic_plans.nil? ? nil : retained_dynamic_plans, context
        )
      })
    end

    def prepare(
      context : WidePartWriter::WidePartOperationContext,
    ) : WidePartWriter::WidePartPreparedColumn
      @prepare.call(context)
    end

    private def self.detach_binary_granules(
      granules : Array(Array(BinaryValue)),
    ) : Array(Array(BinaryValue))
      detached = Array(Array(BinaryValue)).new(granules.size)
      granules.each { |granule| detached << granule.dup }
      detached
    end

    private def self.detach_document_granules(
      granules : Array(Array(ObjectDocument)),
    ) : Array(Array(ObjectDocument))
      detached = Array(Array(ObjectDocument)).new(granules.size)
      granules.each { |granule| detached << granule.dup }
      detached
    end

    private def self.detach_storage_granules(
      granules : Array(Array(StorageColumnValue)),
    ) : Array(Array(StorageColumnValue))
      detached = Array(Array(StorageColumnValue)).new(granules.size)
      granules.each { |granule| detached << granule.dup }
      detached
    end
  end
end

module CrystalClick
  module WidePartWriter
    # Publicly callable bridge from the public typed facade into private
    # per-owner adapters. These methods do not broaden any owner's admission.
    def self.prepare_dynamic_wide_part_column(
      name : String,
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      granules : Array(Array(BinaryValue)),
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))?,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))?,
      context : WidePartOperationContext,
    ) : WidePartPreparedColumn
      DynamicWidePartColumnInput.prepare(
        name, type, structures, granules, json_object_plans,
        json_object_leaf_plans, context
      )
    end

    def self.prepare_static_wide_part_column(
      name : String,
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      context : WidePartOperationContext,
    ) : WidePartPreparedColumn
      StaticWidePartColumnInput.prepare(name, type, granules, context)
    end

    def self.prepare_object_wide_part_column(
      name : String,
      schema : ObjectDocumentSchema,
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy?,
      shared_target_chunk_rows : Int32?,
      context : WidePartOperationContext,
    ) : WidePartPreparedColumn
      ObjectWidePartColumnInput.prepare(
        name, schema, plan, granules, shared_json_policy,
        shared_target_chunk_rows, context
      )
    end

    def self.prepare_recursive_wide_part_column(
      name : String,
      schema : StorageColumnSchema,
      object_plans : Hash(String, ObjectDocumentPlan),
      granules : Array(Array(StorageColumnValue)),
      dynamic_plans : Hash(String, BinaryDynamicBulkPlan)?,
      context : WidePartOperationContext,
    ) : WidePartPreparedColumn
      RecursiveWidePartColumnInput.prepare(
        name, schema, object_plans, granules, dynamic_plans, context
      )
    end
  end
end
