module CrystalClick
  module BinaryBulkDecoder
    # A Dynamic arm's mark-local role strings and cursors. Contexts borrow only
    # the current mark's slices and are never retained by the shared plan.
    private struct DynamicArmReadBinding
      getter path : String
      getter path_work : UInt64
      getter type : BinaryDataType
      getter data_path_work : UInt64?
      getter data_context : BinaryCodecContext?
      getter string_sizes_path_work : UInt64?
      getter string_sizes_context : BinaryCodecContext?
      getter json_leaf_key : BinaryDynamicJsonLeafKey?

      def initialize(
        @path : String,
        @path_work : UInt64,
        @type : BinaryDataType,
        @data_path_work : UInt64?,
        @data_context : BinaryCodecContext?,
        @string_sizes_path_work : UInt64?,
        @string_sizes_context : BinaryCodecContext?,
        @json_leaf_key : BinaryDynamicJsonLeafKey?,
      )
      end
    end

    private class DynamicSiteReadBinding
      getter discriminator_path_work : UInt64
      getter discriminator_context : BinaryCodecContext?
      getter shared_index : Int32

      @arms : Array(DynamicArmReadBinding)

      def initialize(
        @discriminator_path_work : UInt64,
        @discriminator_context : BinaryCodecContext?,
        @shared_index : Int32,
        @arms : Array(DynamicArmReadBinding),
      )
      end

      def arm(index : Int) : DynamicArmReadBinding?
        return nil if index < 0 || index >= @arms.size
        @arms[index]?
      end

      def arm_count : Int32
        @arms.size
      end
    end

    # Rebound for each selected mark so no borrowed cursor can outlive its
    # per-mark slice. Construction is bounded by the validated Dynamic
    # site/arm roster and deliberately leaves missing lanes optional.
    private class DynamicMarkReadBindings
      @sites : Hash(String, DynamicSiteReadBinding)

      def initialize(plan : BinaryDynamicBulkPlan, contexts : Hash(String, BinaryCodecContext), profile : BinaryBulkProfile)
        @sites = Hash(String, DynamicSiteReadBinding).new(initial_capacity: plan.site_count)
        plan.each_site_path do |path|
          discriminator_role = role_path(path, ".discriminators")
          discriminator_path_work = discriminator_role.bytesize.to_u64 * 2_u64
          arms = Array(DynamicArmReadBinding).new(plan.arm_count(path)) do |index|
            type = plan.arm_type(path, index)
            arm_path = indexed_role_path(path, ".arm.", index)
            arm_path_work = arm_path.bytesize.to_u64 * 2_u64

            data_path_work = nil.as(UInt64?)
            data_context = nil.as(BinaryCodecContext?)
            string_sizes_path_work = nil.as(UInt64?)
            string_sizes_context = nil.as(BinaryCodecContext?)
            if direct_scalar_type?(type)
              data_role = role_path(arm_path, ".data")
              data_path_work = (arm_path.bytesize.to_u64 + ".data".bytesize.to_u64) * 2_u64
              data_context = contexts[data_role]?
              if direct_string_type?(type) && profile.with_size_stream?
                string_sizes_role = role_path(arm_path, ".string_sizes")
                string_sizes_path_work = (arm_path.bytesize.to_u64 + ".string_sizes".bytesize.to_u64) * 2_u64
                string_sizes_context = contexts[string_sizes_role]?
              end
            end

            json_leaf_key = type.contains_json? ? BinaryDynamicJsonLeafKey.new(path, index, [] of Int32) : nil
            DynamicArmReadBinding.new(
              arm_path,
              arm_path_work,
              type,
              data_path_work,
              data_context,
              string_sizes_path_work,
              string_sizes_context,
              json_leaf_key,
            )
          end
          @sites[path] = DynamicSiteReadBinding.new(
            discriminator_path_work,
            contexts[discriminator_role]?,
            plan.shared_index(path),
            arms,
          )
        end
      end

      def site(path : String) : DynamicSiteReadBinding?
        @sites[path]?
      end

      private def role_path(path : String, suffix : String) : String
        String.build { |builder| builder << path << suffix }
      end

      private def indexed_role_path(path : String, suffix : String, index : Int32) : String
        String.build { |builder| builder << path << suffix << index.to_s }
      end

      private def direct_scalar_type?(type : BinaryDataType) : Bool
        case type.tag
        when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
          direct_scalar_type?(type.child_at(0))
        when BinaryDataType::TAG_STRING, BinaryDataType::TAG_BOOL, BinaryDataType::TAG_NOTHING
          true
        when BinaryDataType::TAG_QBIT, BinaryDataType::TAG_AGGREGATE_FUNCTION
          false
        else
          !type.fixed_width.nil?
        end
      end

      private def direct_string_type?(type : BinaryDataType) : Bool
        case type.tag
        when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
          direct_string_type?(type.child_at(0))
        else
          type.tag == BinaryDataType::TAG_STRING
        end
      end
    end
  end
end
