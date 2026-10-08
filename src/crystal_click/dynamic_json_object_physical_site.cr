module CrystalClick
  # One exact JSON leaf in a Dynamic actual descriptor bound to the existing
  # Object physical owner. The prefix is the full escaped leaf prefix, before
  # any Object-specific stream suffix; Array numbering is inherited unchanged.
  class DynamicJsonObjectPhysicalSite
    getter leaf_key : BinaryDynamicJsonLeafKey
    getter site_path : String
    getter canonical_arm_index : Int32
    getter escaped_prefix : String
    getter array_level : UInt64
    getter json_depth : Int32
    getter binding : DynamicJsonObjectBinding
    getter physical_plan : ObjectDocumentPhysicalPlan

    def initialize(
      leaf_key : BinaryDynamicJsonLeafKey,
      escaped_prefix : String,
      @array_level : UInt64,
      @binding : DynamicJsonObjectBinding,
      @physical_plan : ObjectDocumentPhysicalPlan,
      @json_depth : Int32 = 1_i32,
    )
      @leaf_key = leaf_key
      @site_path = String.new(leaf_key.dynamic_site.to_slice)
      @canonical_arm_index = leaf_key.canonical_arm_index
      @escaped_prefix = String.new(escaped_prefix.to_slice)
    end
  end
end
