module CrystalClick
  # Immutable paired Object metadata and the exact Dynamic child set named by
  # its path roster.
  class ObjectDynamicStructureSet
    @object : ObjectStructure
    @dynamics : Hash(String, DynamicStructure)

    def initialize(object : ObjectStructure, dynamics : Hash(String, DynamicStructure))
      unless dynamics.size == object.dynamic_path_count
        raise ArgumentError.new("Dynamic structure keys must exactly match the Object path roster")
      end

      @object = object
      @dynamics = Hash(String, DynamicStructure).new
      dynamics.each do |path, structure|
        detached_path = String.new(path.to_slice)
        if @dynamics.has_key?(detached_path)
          raise ArgumentError.new("Dynamic structure path keys must be unique by raw bytes")
        end
        @dynamics[detached_path] = structure
      end

      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        unless @dynamics.has_key?(path)
          raise ArgumentError.new("Dynamic structure keys must exactly match the Object path roster")
        end
      end
    end

    def object : ObjectStructure
      @object
    end

    def dynamics : Hash(String, DynamicStructure)
      detached = Hash(String, DynamicStructure).new
      @dynamics.each do |path, structure|
        detached[String.new(path.to_slice)] = structure
      end
      detached
    end

    def dynamic_count : Int32
      @dynamics.size
    end

    def dynamic_for(path : String) : DynamicStructure
      @dynamics[path]? || raise ArgumentError.new("Dynamic structure is missing Object path #{path.inspect}")
    end
  end
end
