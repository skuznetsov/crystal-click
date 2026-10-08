module CrystalClick
  # Exact physical children for one inferred Object Dynamic path. The
  # Dynamic discriminator/data lanes remain owned by the parent Object plan;
  # this small index only exposes the independently planned JSON Object
  # children bound to root actual leaves.
  class ObjectDocumentRootDynamicJsonPhysicalPlan
    @sites : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectPhysicalSite)

    def initialize(@sites : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectPhysicalSite))
    end

    def json_object_site_count : Int32
      @sites.size
    end

    def json_object_site(key : BinaryDynamicJsonLeafKey) : DynamicJsonObjectPhysicalSite
      @sites[key]? || raise(KeyError.new("root Dynamic JSON Object physical leaf not found"))
    end

    def each_site(&block : DynamicJsonObjectPhysicalSite ->) : Nil
      @sites.each_value { |site| yield site }
      nil
    end
  end
end
