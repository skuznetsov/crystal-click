module CrystalClick
  # Complete, collision-checked physical roster for the recursive Tuple/Array
  # storage profile. JSON sites retain their Object owner; JSON-free leaves
  # retain their BinaryBulk or Dynamic owner. The plan binds every structural
  # site before any row payload is encoded.
  class RecursiveStorageColumnPlan
    struct ObjectSite
      getter key : String
      getter prefix : String
      getter schema : ObjectDocumentSchema
      getter object_plan : ObjectDocumentPlan
      getter physical : ObjectDocumentPhysicalPlan
      getter array_level : UInt64

      def initialize(@key : String, @prefix : String, @schema : ObjectDocumentSchema, @object_plan : ObjectDocumentPlan, @physical : ObjectDocumentPhysicalPlan, @array_level : UInt64)
      end
    end

    struct BulkSite
      getter key : String
      getter prefix : String
      getter type : BinaryDataType
      getter physical : BinaryBulkPhysicalPlan
      getter array_level : UInt64

      def initialize(@key : String, @prefix : String, @type : BinaryDataType, @physical : BinaryBulkPhysicalPlan, @array_level : UInt64)
      end
    end

    struct DynamicSite
      getter key : String
      getter prefix : String
      getter type : BinaryDataType
      getter plan : BinaryDynamicBulkPlan
      getter physical : BinaryDynamicBulkPhysicalPlan
      getter array_level : UInt64
      getter descriptor_depth : Int32

      def initialize(
        @key : String,
        @prefix : String,
        @type : BinaryDataType,
        @plan : BinaryDynamicBulkPlan,
        @physical : BinaryDynamicBulkPhysicalPlan,
        @array_level : UInt64,
        @descriptor_depth : Int32,
      )
      end
    end

    struct ArraySite
      getter key : String
      getter prefix : String
      getter array_level : UInt64
      getter size_name : String

      def initialize(@key : String, @prefix : String, @array_level : UInt64, @size_name : String)
      end
    end

    @column_name : String
    @schema : StorageColumnSchema
    @object_sites : Array(ObjectSite)
    @bulk_sites : Array(BulkSite)
    @dynamic_sites : Array(DynamicSite)
    @array_sites : Array(ArraySite)
    @physical_stream_names : Array(String)
    @file_names : Array(String)
    @file_roster : Hash(String, Tuple(String, String))
    @profile : BinaryBulkProfile
    @shared_profile : BinaryBulkProfile
    @hashed : Bool
    @mode : UInt64
    @frame_bytes : Int32
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @dynamic_readers : Hash(String, DynamicBulkSiteReader)?

    def self.for_column(
      column_name : String,
      schema : StorageColumnSchema,
      object_plans : Hash(String, ObjectDocumentPlan),
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
      frame_bytes : Int = 4096,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      dynamic_plans : Hash(String, BinaryDynamicBulkPlan) = Hash(String, BinaryDynamicBulkPlan).new,
    ) : RecursiveStorageColumnPlan
      new(column_name, schema, object_plans, profile, shared_profile, hashed, mode, frame_bytes, limits, transport_limits, dynamic_plans, nil, nil)
    end

    # Reader-only composition path. It preserves the already discovered
    # physical bindings and validates them against schema-derived site facts;
    # writer callers cannot supply arbitrary prebound plans through for_column.
    def self.for_column_with_dynamic_readers(
      column_name : String,
      schema : StorageColumnSchema,
      object_plans : Hash(String, ObjectDocumentPlan),
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      hashed : Bool,
      mode : UInt64,
      frame_bytes : Int,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      dynamic_readers : Hash(String, DynamicBulkSiteReader),
      name_context : PhysicalStreamPlanContext,
    ) : RecursiveStorageColumnPlan
      dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new(initial_capacity: dynamic_readers.size)
      dynamic_readers.each do |key, reader|
        dynamic_plans[String.new(key.to_slice)] = reader.plan
      end
      new(
        column_name, schema, object_plans, profile, shared_profile, hashed,
        mode, frame_bytes, limits, transport_limits, dynamic_plans,
        dynamic_readers, name_context
      )
    end

    def initialize(
      column_name : String,
      @schema : StorageColumnSchema,
      object_plans : Hash(String, ObjectDocumentPlan),
      @profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      @shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      @hashed : Bool = false,
      @mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
      frame_bytes : Int = 4096,
      @limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      @transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      dynamic_plans : Hash(String, BinaryDynamicBulkPlan) = Hash(String, BinaryDynamicBulkPlan).new,
      dynamic_readers : Hash(String, DynamicBulkSiteReader)? = nil,
      shared_name_context : PhysicalStreamPlanContext? = nil,
    )
      @dynamic_readers = if readers = dynamic_readers
                           detached_readers = Hash(String, DynamicBulkSiteReader).new(initial_capacity: readers.size)
                           readers.each do |key, reader|
                             detached_key = String.new(key.to_slice)
                             if detached_readers.has_key?(detached_key)
                               raise ArgumentError.new("discovered Dynamic site keys must be unique")
                             end
                             detached_readers[detached_key] = reader
                           end
                           detached_readers
                         end
      raise ArgumentError.new("recursive storage column name must be nonempty") if column_name.empty?
      unless frame_bytes > 0 && frame_bytes <= Int32::MAX && frame_bytes >= DynamicDiscriminatorCodec::HEADER_BYTES
        raise ArgumentError.new("frame size must contain the complete Dynamic discriminator prefix")
      end
      unless @mode == DynamicDiscriminatorCodec::BASIC_MODE || @mode == DynamicDiscriminatorCodec::COMPACT_MODE
        raise ArgumentError.new("unsupported Dynamic discriminator write mode")
      end
      @frame_bytes = frame_bytes.to_i32
      @column_name = String.new(column_name.to_slice)

      @schema.validate_source_tree!(@limits)
      # Inspect actual admitted Object leaves rather than inventing a separate
      # aggregate schema limit.
      @schema.each_json_site do |_key, object_schema|
        unless same_limits?(object_schema.limits, @limits)
          raise ArgumentError.new("recursive writer and Object schema codec limits must match")
        end
      end

      expected_sites = @schema.json_site_keys.sort!
      supplied_sites = object_plans.keys
      unless supplied_sites.sort == expected_sites
        raise ArgumentError.new("Object plan keys must exactly match recursive JSON site keys")
      end
      if expected_sites.empty?
        raise UnsupportedFormatError.new("recursive storage requires at least one JSON leaf")
      end

      detached_plans = Hash(String, ObjectDocumentPlan).new(initial_capacity: object_plans.size)
      object_plans.each do |key, object_plan|
        detached_key = String.new(key.to_slice)
        if detached_plans.has_key?(detached_key)
          raise ArgumentError.new("recursive JSON site keys must be unique")
        end
        detached_plans[detached_key] = object_plan
      end

      expected_dynamic_sites = dynamic_site_keys(@schema, "root")
      supplied_dynamic_sites = dynamic_plans.keys
      unless supplied_dynamic_sites.sort == expected_dynamic_sites.sort
        raise ArgumentError.new("Dynamic plan keys must exactly match recursive Dynamic site keys")
      end
      if readers = @dynamic_readers
        unless readers.keys.sort == expected_dynamic_sites.sort
          raise ArgumentError.new("discovered Dynamic reader keys must exactly match recursive Dynamic site keys")
        end
      end
      detached_dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new(initial_capacity: dynamic_plans.size)
      dynamic_plans.each do |key, dynamic_plan|
        detached_key = String.new(key.to_slice)
        if detached_dynamic_plans.has_key?(detached_key)
          raise ArgumentError.new("recursive Dynamic site keys must be unique")
        end
        detached_dynamic_plans[detached_key] = dynamic_plan
      end

      context = shared_name_context || PhysicalStreamPlanContext.new(@limits)
      unless same_limits?(context.limits, @limits)
        raise ArgumentError.new("recursive physical context differs from its codec limits")
      end
      dynamic_depth_budget = BinaryCodecBudget.new(@limits, true)
      context.preflight_name_bytes(PhysicalStreamName.escaped_size(@column_name))
      root_prefix = PhysicalStreamName.escape(@column_name, context)
      object_sites = [] of ObjectSite
      bulk_sites = [] of BulkSite
      dynamic_sites = [] of DynamicSite
      array_sites = [] of ArraySite
      unless @schema.tuple? || @schema.array?
        raise UnsupportedFormatError.new("recursive storage root must be a Tuple or Array")
      end
      build_sites(
        @schema, root_prefix, "root", 0_u64, 1_i32, detached_plans,
        detached_dynamic_plans, context, dynamic_depth_budget, object_sites, bulk_sites,
        dynamic_sites, array_sites
      )

      unless object_sites.map(&.key).sort! == expected_sites
        raise UnsupportedFormatError.new("recursive physical Object site roster differs from its schema")
      end
      @object_sites = object_sites
      @bulk_sites = bulk_sites
      @dynamic_sites = dynamic_sites
      @array_sites = array_sites
      unless @array_sites.map(&.key).sort! == @schema.array_site_keys.sort!
        raise UnsupportedFormatError.new("recursive physical Array site roster differs from its schema")
      end

      logical_names = [] of String
      seen_logical = Hash(String, Bool).new
      @array_sites.each do |site|
        append_unique_logical!(logical_names, seen_logical, site.size_name)
      end
      @object_sites.each do |site|
        site.physical.stream_names.each do |name|
          append_unique_logical!(logical_names, seen_logical, name)
        end
      end
      @bulk_sites.each do |site|
        site.physical.stream_names.each_value do |name|
          append_unique_logical!(logical_names, seen_logical, name)
        end
      end
      @dynamic_sites.each do |site|
        site.physical.stream_names.each_value do |name|
          append_unique_logical!(logical_names, seen_logical, name)
        end
      end
      if logical_names.empty?
        raise UnsupportedFormatError.new("recursive physical stream roster cannot be empty")
      end
      if logical_names.size > WidePart::MAX_METADATA_SUBSTREAMS
        raise UnsupportedFormatError.new("recursive physical roster exceeds metadata substream limit")
      end

      logical_names.sort!
      filenames = Hash(String, Bool).new
      file_roster = Hash(String, Tuple(String, String)).new(initial_capacity: logical_names.size)
      file_names = [] of String
      logical_names.each do |name|
        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
          raise UnsupportedFormatError.new("recursive physical stream name exceeds metadata line limit")
        end
        base = @hashed ? StreamName.hash(name) : name
        if base.bytesize > PartChecksums::MAX_NAME_BYTES - ".mrk2".bytesize
          raise UnsupportedFormatError.new("recursive physical filename exceeds checksums name limit")
        end
        data_name = PhysicalStreamName.append_literal(base, ".bin")
        marks_name = PhysicalStreamName.append_literal(base, ".mrk2")
        {data_name, marks_name}.each do |file_name|
          if file_name.bytesize > PartChecksums::MAX_NAME_BYTES || filenames.has_key?(file_name)
            raise UnsupportedFormatError.new("recursive physical filenames collide or exceed checksum limits")
          end
          filenames[file_name] = true
          file_names << String.new(file_name.to_slice)
        end
        file_roster[String.new(name.to_slice)] = {data_name, marks_name}
      end
      if file_roster.size * 2 + 5 > PartChecksums::MAX_ENTRIES
        raise UnsupportedFormatError.new("recursive part exceeds checksums entry limit")
      end
      @physical_stream_names = logical_names.map { |name| String.new(name.to_slice) }
      @file_names = file_names.sort!
      @file_roster = file_roster
    end

    def column_name : String
      String.new(@column_name.to_slice)
    end

    def schema : StorageColumnSchema
      @schema
    end

    def object_site_count : Int32
      @object_sites.size
    end

    def object_site_at(index : Int) : ObjectSite
      site = @object_sites[index]
      ObjectSite.new(String.new(site.key.to_slice), String.new(site.prefix.to_slice), site.schema, site.object_plan, site.physical, site.array_level)
    end

    def bulk_site_count : Int32
      @bulk_sites.size
    end

    def bulk_site_at(index : Int) : BulkSite
      site = @bulk_sites[index]
      BulkSite.new(String.new(site.key.to_slice), String.new(site.prefix.to_slice), site.type, site.physical, site.array_level)
    end

    def dynamic_site_count : Int32
      @dynamic_sites.size
    end

    def dynamic_site_at(index : Int) : DynamicSite
      site = @dynamic_sites[index]
      DynamicSite.new(
        String.new(site.key.to_slice), String.new(site.prefix.to_slice), site.type,
        site.plan, site.physical, site.array_level, site.descriptor_depth
      )
    end

    def array_site_count : Int32
      @array_sites.size
    end

    def array_site_at(index : Int) : ArraySite
      site = @array_sites[index]
      ArraySite.new(String.new(site.key.to_slice), String.new(site.prefix.to_slice), site.array_level, String.new(site.size_name.to_slice))
    end

    def physical_stream_names : Array(String)
      @physical_stream_names.map { |name| String.new(name.to_slice) }
    end

    def file_names : Array(String)
      @file_names.map { |name| String.new(name.to_slice) }
    end

    def file_roster : Hash(String, Tuple(String, String))
      detached = Hash(String, Tuple(String, String)).new(initial_capacity: @file_roster.size)
      @file_roster.each do |name, pair|
        detached[String.new(name.to_slice)] = {String.new(pair[0].to_slice), String.new(pair[1].to_slice)}
      end
      detached
    end

    def profile : BinaryBulkProfile
      @profile
    end

    def shared_profile : BinaryBulkProfile
      @shared_profile
    end

    def hashed? : Bool
      @hashed
    end

    def mode : UInt64
      @mode
    end

    def frame_bytes : Int32
      @frame_bytes
    end

    def limits : BinaryCodecLimits
      @limits
    end

    def transport_limits : CompressedStreamLimits
      @transport_limits
    end

    private def build_sites(
      schema : StorageColumnSchema,
      prefix : String,
      site_key : String,
      array_level : UInt64,
      descriptor_depth : Int32,
      object_plans : Hash(String, ObjectDocumentPlan),
      dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      context : PhysicalStreamPlanContext,
      dynamic_depth_budget : BinaryCodecBudget,
      objects : Array(ObjectSite),
      bulk : Array(BulkSite),
      dynamic : Array(DynamicSite),
      arrays : Array(ArraySite),
    ) : Nil
      if object_schema = schema.object_schema_or_nil
        object_plan = object_plans[site_key]? || raise(ArgumentError.new("recursive JSON site has no Object plan"))
        object_schema.validate_plan(object_plan)
        physical = ObjectDocumentPhysicalPlan.from_escaped_prefix(
          prefix, object_plan, @profile, @shared_profile, @limits, array_level, context
        )
        objects << ObjectSite.new(String.new(site_key.to_slice), String.new(prefix.to_slice), object_schema, object_plan, physical, array_level)
        return nil
      end
      if bulk_type = schema.bulk_type_or_nil
        if bulk_type.contains_dynamic?
          dynamic_plan = dynamic_plans[site_key]? || raise(ArgumentError.new("recursive Dynamic site has no prepared plan"))
          unless dynamic_plan.type == bulk_type && dynamic_plan.profile == @profile
            raise ArgumentError.new("recursive Dynamic prepared plan differs from its declared type or profile")
          end
          if dynamic_plan.type.contains_json?
            raise UnsupportedFormatError.new("JSON is outside the admitted recursive Dynamic profile")
          end
          unless @dynamic_readers
            dynamic_plan.validate_inherited_depth!(descriptor_depth, dynamic_depth_budget)
          end
          physical = if readers = @dynamic_readers
                       reader = readers[site_key]? || raise(ArgumentError.new("discovered Dynamic site reader is missing"))
                       unless reader.matches_site?(
                                bulk_type, prefix, site_key, array_level, descriptor_depth,
                                @profile, dynamic_plan, @limits, @transport_limits
                              )
                         raise CorruptPartError.new("discovered Dynamic reader identity differs from its recursive schema site")
                       end
                       reader.physical
                     else
                       BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(
                         dynamic_plan, prefix, @limits, context, array_level
                       )
                     end
          dynamic << DynamicSite.new(
            String.new(site_key.to_slice), String.new(prefix.to_slice), bulk_type,
            dynamic_plan, physical, array_level, descriptor_depth
          )
          return nil
        end
        physical = BinaryBulkPhysicalPlan.from_escaped_prefix(
          bulk_type, prefix, @profile, @limits, context, array_level
        )
        bulk << BulkSite.new(String.new(site_key.to_slice), String.new(prefix.to_slice), bulk_type, physical, array_level)
        return nil
      end

      if schema.array?
        if array_level > UInt64::MAX - 1_u64
          raise UnsupportedFormatError.new("recursive Array-level coordinate overflows UInt64")
        end
        suffix = String.build { |io| io << ".size" << array_level }
        size_name = PhysicalStreamName.append_literal(prefix, suffix, context)
        context.charge_name_bytes(size_name.bytesize.to_u64)
        arrays << ArraySite.new(String.new(site_key.to_slice), String.new(prefix.to_slice), array_level, size_name)
        child_key = String.build { |io| io << site_key << "/array[0]" }
        build_sites(schema.child_at(0), prefix, child_key, array_level + 1_u64, descriptor_depth + 1, object_plans, dynamic_plans, context, dynamic_depth_budget, objects, bulk, dynamic, arrays)
        return nil
      end

      unless schema.tuple?
        raise UnsupportedFormatError.new("recursive storage site has no admitted owner")
      end
      schema.child_count.times do |index|
        raw_field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
        child_prefix = PhysicalStreamName.append_escaped_field(prefix, raw_field, context)
        child_key = String.build { |io| io << site_key << "/tuple[" << index << ']' }
        build_sites(schema.child_at(index), child_prefix, child_key, array_level, descriptor_depth + 1, object_plans, dynamic_plans, context, dynamic_depth_budget, objects, bulk, dynamic, arrays)
      end
      nil
    end

    private def dynamic_site_keys(schema : StorageColumnSchema, key : String) : Array(String)
      output = [] of String
      append_dynamic_site_keys(schema, key, output)
      output
    end

    private def append_dynamic_site_keys(schema : StorageColumnSchema, key : String, output : Array(String)) : Nil
      if type = schema.bulk_type_or_nil
        output << String.new(key.to_slice) if type.contains_dynamic?
      elsif schema.array?
        append_dynamic_site_keys(schema.child_at(0), String.build { |io| io << key << "/array[0]" }, output)
      elsif schema.tuple?
        schema.child_count.times do |index|
          append_dynamic_site_keys(
            schema.child_at(index), String.build { |io| io << key << "/tuple[" << index << ']' }, output
          )
        end
      end
      nil
    end

    private def append_unique_logical!(names : Array(String), seen : Hash(String, Bool), name : String) : Nil
      if seen.has_key?(name)
        raise UnsupportedFormatError.new("recursive physical stream names collide across structural sites")
      end
      seen[name] = true
      names << String.new(name.to_slice)
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end
  end
end
