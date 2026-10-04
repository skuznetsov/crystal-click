module CrystalClick
  module ObjectDocumentColumnWriter
    # Stateless composition of logical Object streams into their preflighted
    # physical lanes. The caller retains operation and budget ownership.
    private class LaneBinder
      def self.bind_lanes(
        physical_plan : ObjectDocumentPhysicalPlan,
        plan : ObjectDocumentPlan,
        streams : ObjectDocumentStreams,
      ) : Array(ObjectDocumentColumnLane)
        if streams.mark_count <= 0
          raise UnsupportedFormatError.new("Object document output has no real outer marks")
        end
        expected = Hash(String, Bool).new
        physical_plan.stream_names.each { |name| expected[name] = false }
        lanes = Array(ObjectDocumentColumnLane).new(expected.size)
        structures = streams.structures
        object_bytes = structures.borrowed_object
        object_offset = structures.object_statistics_offset ||
                        raise(UnsupportedFormatError.new("Object metadata encoder omitted its statistics offset"))
        add_lane!(lanes, expected, ObjectDocumentColumnLane.new(physical_plan.object_structure_stream, object_bytes, object_offset))

        object = plan.structures.object
        if structures.dynamic_statistics_offset_count != object.dynamic_path_count
          raise UnsupportedFormatError.new("Dynamic metadata statistics offsets do not match the Object path roster")
        end
        object.dynamic_path_count.times do |index|
          path = object.dynamic_path_at(index)
          name = physical_plan.dynamic_structure_stream(path)
          bytes = structures.borrowed_dynamic(path)
          offset = structures.dynamic_statistics_offset(path) ||
                   raise(UnsupportedFormatError.new("Dynamic metadata encoder omitted a statistics offset"))
          add_lane!(lanes, expected, ObjectDocumentColumnLane.new(name, bytes, offset))
        end

        if streams.dynamic_path_count != object.dynamic_path_count
          raise UnsupportedFormatError.new("Dynamic value lane paths do not match the Object metadata roster")
        end
        object.dynamic_path_count.times do |index|
          path = object.dynamic_path_at(index)
          dynamic_structure = plan.structures.dynamic_for(path)
          canonical_names = dynamic_structure.canonical_variant_names
          dynamic_streams = streams.dynamic_for(path)
          if dynamic_streams.arm_count != dynamic_structure.canonical_variant_count
            raise UnsupportedFormatError.new("Dynamic value arm roster does not match its descriptor metadata")
          end
          canonical_names.each do |arm_name|
            unless dynamic_streams.has_arm?(arm_name)
              raise UnsupportedFormatError.new("Dynamic value arm is missing from its descriptor roster")
            end
          end
          unless dynamic_streams.arm_names == canonical_names
            raise UnsupportedFormatError.new("Dynamic value arm names are not in the canonical descriptor order")
          end

          discriminator = dynamic_streams.discriminators
          if discriminator.mark_count != streams.mark_count + 1
            raise UnsupportedFormatError.new("Dynamic discriminator mark count does not match the outer grid")
          end
          add_lane!(lanes, expected, ObjectDocumentColumnLane.new(
            physical_plan.discriminator_stream(path),
            discriminator.borrowed_slice(0, discriminator.byte_size),
            nil,
            nil,
            discriminator,
            DynamicDiscriminatorCodec::HEADER_BYTES.to_i32
          ))

          canonical_names.each do |arm_name|
            add_bulk_lanes!(
              lanes,
              expected,
              physical_plan.dynamic_arm(path, arm_name),
              dynamic_streams.arm(arm_name),
              streams.mark_count
            )
          end
        end

        typed_paths = [] of String
        plan.typed_path_count.times do |index|
          path = plan.typed_path_at(index)
          next if plan.has_typed_dynamic?(path)
          typed_paths << path
        end
        unless streams.typed_paths == typed_paths
          raise UnsupportedFormatError.new("typed lane paths do not match the explicit non-Dynamic schema paths")
        end
        plan.typed_path_count.times do |index|
          path = plan.typed_path_at(index)
          next if plan.has_typed_dynamic?(path)
          add_bulk_lanes!(
            lanes,
            expected,
            physical_plan.typed(path),
            streams.typed_for(path),
            streams.mark_count,
            variant_prefix_roles: true
          )
        end

        typed_dynamic_paths = Array(String).new(plan.typed_dynamic_count)
        plan.typed_dynamic_count.times do |index|
          typed_dynamic_paths << plan.typed_dynamic_path_at(index)
        end
        unless streams.typed_dynamic_paths == typed_dynamic_paths
          raise UnsupportedFormatError.new("typed Dynamic lane paths do not match the explicit schema roster")
        end
        plan.typed_dynamic_count.times do |index|
          path = plan.typed_dynamic_path_at(index)
          typed_dynamic = streams.typed_dynamic_for(path)
          physical_dynamic = physical_plan.typed_dynamic(path)
          structures = typed_dynamic.structures
          unless structures.site_count == 1 && structures.site_paths == ["root"]
            raise UnsupportedFormatError.new("typed Dynamic structure lane must contain exactly the root site")
          end
          statistics_offset = streams.typed_dynamic_statistics_offset(path) ||
                              raise(UnsupportedFormatError.new("typed Dynamic metadata encoder omitted its statistics offset"))
          structure_bytes = structures.structure_bytes_for("root")
          add_lane!(lanes, expected, ObjectDocumentColumnLane.new(
            physical_dynamic.structure_name_for("root"),
            structure_bytes,
            statistics_offset
          ))
          add_typed_dynamic_data_lanes!(
            lanes, expected, physical_dynamic, typed_dynamic, streams.mark_count
          )
        end
        add_bulk_lanes!(lanes, expected, physical_plan.shared, streams.shared, streams.mark_count)

        unless lanes.size == expected.size && expected.each_value.all? { |seen| seen }
          raise UnsupportedFormatError.new("Object column lanes do not exactly cover the physical filename roster")
        end
        lanes
      end

      private def self.add_bulk_lanes!(
        lanes : Array(ObjectDocumentColumnLane),
        expected : Hash(String, Bool),
        physical : BinaryBulkPhysicalPlan,
        streams : BinaryBulkStreams,
        real_mark_count : Int32,
        variant_prefix_roles : Bool = false,
      ) : Nil
        physical_names = physical.stream_names
        if physical_names.size != streams.role_count
          raise UnsupportedFormatError.new("binary bulk roles do not match their physical binding")
        end
        unless physical_names.keys.sort == streams.roles
          raise UnsupportedFormatError.new("binary bulk role set does not match its physical binding")
        end
        streams.roles.each do |role|
          source = streams.stream(role)
          unless source.offset_count == real_mark_count + 1
            raise UnsupportedFormatError.new("binary bulk lane does not have the complete outer mark grid")
          end
          name = physical.stream_name_for(role)
          bytes = source.borrowed_slice(0, source.byte_size)
          variant_prefix_role = if variant_prefix_roles &&
                                   BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, physical.prefix_size_for(role))
                                  String.new(role.to_slice)
                                else
                                  nil
                                end
          add_lane!(lanes, expected, ObjectDocumentColumnLane.new(
            name,
            bytes,
            nil,
            source,
            nil,
            physical.prefix_size_for(role),
            variant_prefix_role
          ))
        end
        nil
      end

      private def self.add_typed_dynamic_data_lanes!(
        lanes : Array(ObjectDocumentColumnLane),
        expected : Hash(String, Bool),
        physical : BinaryDynamicBulkPhysicalPlan,
        streams : BinaryDynamicBulkStreams,
        real_mark_count : Int32,
      ) : Nil
        data = streams.data
        physical_names = physical.data_stream_names
        unless physical_names.keys.sort == data.roles
          raise UnsupportedFormatError.new("typed Dynamic value roles do not match their prepared descriptor roster")
        end
        data.roles.each do |role|
          source = data.stream(role)
          unless source.offset_count == real_mark_count + 1
            raise UnsupportedFormatError.new("typed Dynamic value lane does not have the complete outer mark grid")
          end
          prefix = physical.prefix_size_for(role)
          variant_prefix_role = if BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
                                  unless role == "root.discriminators"
                                    raise UnsupportedFormatError.new("typed Dynamic discriminator is not the admitted root site")
                                  end
                                  String.new(role.to_slice)
                                else
                                  unless prefix == 0
                                    raise UnsupportedFormatError.new("typed Dynamic value lane has an unsupported physical prefix")
                                  end
                                  nil
                                end
          add_lane!(lanes, expected, ObjectDocumentColumnLane.new(
            physical.stream_name_for(role),
            source.borrowed_slice(0, source.byte_size),
            nil,
            source,
            nil,
            prefix,
            variant_prefix_role
          ))
        end
        nil
      end

      def self.preflight_variant_prefixes!(
        physical_plan : ObjectDocumentPhysicalPlan,
        plan : ObjectDocumentPlan,
        streams : ObjectDocumentStreams,
        budget : BinaryCodecBudget,
      ) : Nil
        lanes = [] of Tuple(String, BinaryBulkStream, Int32)
        plan.typed_path_count.times do |index|
          path = plan.typed_path_at(index)
          next if plan.has_typed_dynamic?(path)
          physical = physical_plan.typed(path)
          typed_streams = streams.typed_for(path)
          typed_streams.roles.each do |role|
            prefix = physical.prefix_size_for(role)
            if BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
              lanes << {role, typed_streams.stream(role), prefix}
            end
          end
        end
        typed_dynamic_paths = Array(String).new(plan.typed_dynamic_count)
        plan.typed_dynamic_count.times do |index|
          typed_dynamic_paths << plan.typed_dynamic_path_at(index)
        end
        unless streams.typed_dynamic_paths == typed_dynamic_paths
          raise UnsupportedFormatError.new("typed Dynamic lane paths do not match the explicit schema roster")
        end
        plan.typed_dynamic_count.times do |index|
          path = plan.typed_dynamic_path_at(index)
          physical = physical_plan.typed_dynamic(path)
          typed_dynamic_streams = streams.typed_dynamic_for(path).data
          unless physical.data_stream_names.keys.sort == typed_dynamic_streams.roles
            raise UnsupportedFormatError.new("typed Dynamic value roles do not match their prepared descriptor roster")
          end
          typed_dynamic_streams.roles.each do |role|
            prefix = physical.prefix_size_for(role)
            if BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
              unless role == "root.discriminators"
                raise UnsupportedFormatError.new("typed Dynamic discriminator is not the admitted root site")
              end
              lanes << {role, typed_dynamic_streams.stream(role), prefix}
            elsif prefix != 0
              raise UnsupportedFormatError.new("typed Dynamic value lane has an unsupported physical prefix")
            end
          end
        end
        BinaryBulkPhysicalPrefixAdapter.preflight_write(lanes, budget) unless lanes.empty?
        nil
      end

      private def self.add_lane!(lanes : Array(ObjectDocumentColumnLane), expected : Hash(String, Bool), lane : ObjectDocumentColumnLane) : Nil
        unless expected.has_key?(lane.name)
          raise UnsupportedFormatError.new("encoded Object lane has no physical filename binding")
        end
        if expected[lane.name]
          raise UnsupportedFormatError.new("multiple encoded Object lanes share one physical filename")
        end
        expected[lane.name] = true
        lanes << lane
        nil
      end
    end
  end
end
