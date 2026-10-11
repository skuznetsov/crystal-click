module CrystalClick
  # Reassembles one advanced SharedData parent from its source-scheduled
  # Compact callbacks. The callback tape supplies authenticated slices; this
  # owner only maps those exact slices into the existing bucket/Copy decoders.
  class ObjectSharedAdvancedInlineDecoder
    alias RoleParts = Tuple(
      Array(String),
      Array(String),
      Array(ObjectSharedInlineCallbackReadSlice),
    )

    def self.decode(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding)? = nil,
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair)? = nil,
    ) : Array(Array(ObjectSharedMapRow))
      prepared = prepare_inline(
        prefix,
        physical_plan,
        grid,
        budget,
        role_bindings,
        callback_pairs,
      )
      decode_prepared(prepared, budget)
    end

    # Authenticates and materializes one inline mark's raw shared-data roles,
    # Copy framing, and parser-observed StructurePrefix spans without decoding
    # any ObjectDocument or BinaryValue. The same operation budget continues
    # in decode_prepared; preparation is not independently replayable under a
    # fresh budget.
    def self.prepare_inline(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding)? = nil,
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair)? = nil,
    ) : ObjectSharedAdvancedInlinePrepared
      ObjectSharedAdvancedInlinePrepared.prepare_from_source(
        prefix,
        physical_plan,
        grid,
        budget,
        role_bindings,
        callback_pairs,
      )
    end

    # Returns raw parser products only. This helper cannot mint a prepared
    # holder; that is restricted to ObjectSharedAdvancedInlinePrepared's
    # source-only factory after this full validation path returns.
    def self.prepare_raw_inline(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding)? = nil,
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair)? = nil,
    ) : NamedTuple(
      logical_row_count: UInt64,
      bucket_parents: Array(Array(ObjectSharedPhysicalParentMark)),
      structure_spans_by_bucket: Array(Array(ObjectSharedChunkStructureReadSpan)),
      copies: Array(ObjectSharedCopyStreams),
    )
      context = prefix.nested_context
      if budget.writing? || context.writing?
        raise ArgumentError.new("inline advanced Object decoding requires read-direction contexts")
      end
      prefix.validate_physical_owner!(physical_plan)
      version = context.shared_data_version
      unless version == 2_u64 || version == 3_u64
        raise ArgumentError.new("inline advanced Object decoding requires SharedData v2 or v3")
      end
      unless prefix.plan.structures.object.shared_data_version == version
        raise CorruptPartError.new("inline advanced Object version differs from its inherited context")
      end
      unless physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("inline advanced shared callbacks require the source single-stream profile")
      end
      grid.validate_for!(1, budget)
      physical_rows = grid.physical_rows_at(0)
      logical_rows = grid.logical_occurrences_at(0)
      unless physical_rows > 0_u64 && physical_rows <= Int32::MAX.to_u64
        raise CorruptPartError.new("inline advanced Object requires a positive physical parent mark")
      end
      if logical_rows > Int32::MAX.to_u64
        raise CorruptPartError.new("inline advanced Object logical rows exceed Int32")
      end

      bucket_count = physical_plan.shared_bucket_count
      unless 1 <= bucket_count && bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i
        raise CorruptPartError.new("inline advanced Object bucket count is outside the supported range")
      end
      unless bucket_count.to_u64 == prefix.plan.structures.object.bucket_count
        raise CorruptPartError.new("inline advanced Object bucket count differs from its physical plan")
      end

      bindings, pairs = if inline_prefix = prefix.as?(ObjectDocumentInlinePrefix)
                          begin
                            {
                              role_bindings || prefix.body_role_bindings,
                              callback_pairs || prefix.body_callback_pairs,
                            }
                          rescue ex : ArgumentError
                            # Preserve the legacy four-argument path only for
                            # an inline leaf that retained its validated
                            # recursive owner registry. Static/keyless owners
                            # must carry or receive an explicit schedule.
                            unless inline_prefix.physical_plan.same?(physical_plan)
                              raise CorruptPartError.new("inline advanced callback schedule belongs to a different physical plan")
                            end
                            event_context = inline_prefix.event_schedule_context
                            fallback_bindings = ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
                              physical_plan,
                              prefix.plan,
                              context.profile,
                              budget,
                              event_context,
                              true,
                            )
                            fallback_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
                              physical_plan,
                              prefix.plan,
                              context.profile,
                              prefix.callback_prefix,
                              budget,
                              true,
                              true,
                              event_context,
                              true,
                            )
                            {
                              role_bindings || fallback_bindings,
                              callback_pairs || fallback_pairs,
                            }
                          end
                        else
                          {
                            role_bindings || prefix.body_role_bindings,
                            callback_pairs || prefix.body_callback_pairs,
                          }
                        end
      slice_count = prefix.body_callback_slice_count
      unless bindings.size == pairs.size && pairs.size == slice_count
        raise CorruptPartError.new("inline advanced callback schedule differs from captured body slices")
      end

      bucket_role_count = bucket_count.to_u64 * ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size.to_u64
      total_roles = checked_add(bucket_role_count, ObjectSharedAdvancedCopyLayout::COPY_LANES.size.to_u64)
      budget.ensure_future_nodes(total_roles + 1_u64)
      budget.ensure_future_elements(total_roles)
      budget.preflight_children(slice_count.to_u64)

      bucket_parts = Array(Hash(String, RoleParts)).new(bucket_count) do
        roles = Hash(String, RoleParts).new(initial_capacity: ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size)
        ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.each do |role|
          roles[role] = {
            [] of String,
            [] of String,
            [] of ObjectSharedInlineCallbackReadSlice,
          }
        end
        roles
      end
      copy_parts = Hash(String, RoleParts).new(initial_capacity: ObjectSharedAdvancedCopyLayout::COPY_LANES.size)
      ObjectSharedAdvancedCopyLayout::COPY_LANES.each do |role|
        copy_parts[role] = {
          [] of String,
          [] of String,
          [] of ObjectSharedInlineCallbackReadSlice,
        }
      end

      first_context = nil.as(ObjectSharedInlineCoordinateContext?)
      bindings.each_with_index do |binding, index|
        canonical_name, owner_kind, owner_path, role = binding
        pair = pairs[index]
        slice = prefix.body_callback_slice_at(index)
        unless pair[0] == canonical_name &&
               slice.canonical_name == canonical_name &&
               slice.callback_name == pair[1] &&
               slice.authenticated_context?
          raise CorruptPartError.new("inline callback identity differs from its authenticated source schedule")
        end
        slice_context = slice.context
        if existing = first_context
          unless slice_context.same_path?(existing)
            raise CorruptPartError.new("inline advanced roles do not share one authenticated Data path")
          end
        else
          first_context = slice_context
        end

        case owner_kind
        when :advanced_bucket
          bucket_index = parse_bucket_index(owner_path, bucket_count)
          parts = bucket_parts[bucket_index][role]? ||
                  raise(CorruptPartError.new("inline advanced bucket callback has an unknown role"))
          append_role_part!(parts, canonical_name, pair[1], slice, budget)
        when :advanced_copy
          unless owner_path == "copy"
            raise CorruptPartError.new("inline advanced Copy callback has an invalid owner")
          end
          parts = copy_parts[role]? || raise(CorruptPartError.new("inline advanced Copy callback has an unknown role"))
          append_role_part!(parts, canonical_name, pair[1], slice, budget)
        when :typed, :typed_dynamic, :root_dynamic
          # These callbacks were identity-checked above and are materialized
          # by ObjectDocumentInlineBodyMaterializer. This decoder owns only
          # the advanced bucket and Copy lanes.
          next
        else
          raise CorruptPartError.new("inline advanced callback has an unknown physical owner")
        end
      end

      budget.ensure_future_nodes(total_roles)
      total_roles.times { budget.charge_node }
      budget.charge_elements(total_roles) if total_roles > 0_u64

      bucket_parents = Array(Array(ObjectSharedPhysicalParentMark)).new(bucket_count)
      structure_spans_by_bucket = Array(Array(ObjectSharedChunkStructureReadSpan)).new(bucket_count)
      bucket_count.times do |bucket_index|
        role_views = Hash(String, ObjectSharedInlineRoleReadView).new(initial_capacity: ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size)
        ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.each do |role|
          parts = bucket_parts[bucket_index][role]
          role_views[role] = ObjectSharedInlineRoleReadView.from_captured_schedule(
            role,
            parts[0],
            parts[1],
            parts[2],
            budget,
          )
        end
        parent, structure_spans = ObjectSharedPhysicalBucketDecoder.decode_inline_with_spans(
          version.to_i,
          role_views,
          physical_rows,
          logical_rows,
          budget,
        )
        bucket_parents << [parent] of ObjectSharedPhysicalParentMark
        structure_spans_by_bucket << structure_spans
      end

      copy_views = Hash(String, ObjectSharedInlineRoleReadView).new(initial_capacity: ObjectSharedAdvancedCopyLayout::COPY_LANES.size)
      ObjectSharedAdvancedCopyLayout::COPY_LANES.each do |role|
        parts = copy_parts[role]
        copy_views[role] = ObjectSharedInlineRoleReadView.from_captured_schedule(
          role,
          parts[0],
          parts[1],
          parts[2],
          budget,
        )
      end
      copies_by_parent = ObjectSharedAdvancedCopyLayout.decode_inline(
        copy_views,
        bucket_parents,
        [physical_rows] of UInt64,
        budget,
      )
      unless copies_by_parent.size == 1
        raise CorruptPartError.new("inline advanced Copy decode returned an invalid physical parent count")
      end
      copies = copies_by_parent[0]
      parent_chunks = bucket_parents.map { |parents| parents[0] }
      chunk_count = parent_chunks[0].chunk_count
      unless copies.size == chunk_count
        raise CorruptPartError.new("inline advanced Copy chunks disagree with bucket chunk schedules")
      end
      budget.preflight_children(chunk_count.to_u64)

      observed_rows = 0_u64
      chunk_count.times do |chunk_index|
        chunk_rows = parent_chunks[0].chunk_at(chunk_index).row_count
        if observed_rows > logical_rows || chunk_rows > logical_rows - observed_rows
          raise CorruptPartError.new("inline advanced chunk rows exceed the parent occurrence grid")
        end
        observed_rows += chunk_rows
      end
      unless observed_rows == logical_rows
        raise CorruptPartError.new("inline advanced chunks disagree with the parent occurrence grid")
      end
      budget.preflight_children(logical_rows)

      {
        logical_row_count:         logical_rows,
        bucket_parents:            bucket_parents,
        structure_spans_by_bucket: structure_spans_by_bucket,
        copies:                    copies,
      }
    end

    # Decodes only the requested mark's Copy value envelopes and per-path
    # values. The prepared owner's exact physical plan and budget identity are
    # checked before the first value parser is entered.
    def self.decode_prepared(
      prepared : ObjectSharedAdvancedInlinePrepared,
      budget : BinaryCodecBudget,
    ) : Array(Array(ObjectSharedMapRow))
      prepared.validate_decode_operation!(budget)
      bucket_count = prepared.bucket_count
      chunk_count = prepared.chunk_count
      logical_rows = prepared.logical_row_count
      nested_context = prepared.nested_context_for_decode
      output_rows = [] of ObjectSharedMapRow
      chunk_count.times do |chunk_index|
        bucket_chunks = Array(ObjectSharedPhysicalChunk).new(bucket_count)
        bucket_count.times do |bucket_index|
          bucket_chunks << prepared.parent_for_decode(bucket_index).chunk_at(chunk_index)
        end
        rows = ObjectSharedAdvancedChunkCodec.decode(
          bucket_chunks,
          prepared.copy_for_decode(chunk_index),
          budget,
          nested_context.profile,
          nested_context,
        )
        expected_chunk_rows = bucket_chunks[0].row_count
        unless rows.size.to_u64 == expected_chunk_rows
          raise CorruptPartError.new("inline advanced chunk decoder returned the wrong row count")
        end
        rows.each { |row| output_rows << row }
      end
      unless output_rows.size.to_u64 == logical_rows
        raise CorruptPartError.new("inline advanced chunks disagree with the parent occurrence grid")
      end
      [output_rows] of Array(ObjectSharedMapRow)
    end

    private def self.append_role_part!(
      parts : RoleParts,
      canonical_name : String,
      callback_name : String,
      slice : ObjectSharedInlineCallbackReadSlice,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(3_u64)
      name_bytes = checked_add(canonical_name.bytesize.to_u64, callback_name.bytesize.to_u64)
      budget.ensure_wire_bytes(name_bytes)
      budget.charge_node
      budget.charge_elements(3_u64)
      budget.charge_wire_bytes(name_bytes) if name_bytes > 0_u64
      parts[0] << String.new(canonical_name.to_slice)
      parts[1] << String.new(callback_name.to_slice)
      parts[2] << slice
      nil
    end

    private def self.parse_bucket_index(path : String, bucket_count : Int32) : Int32
      index = path.to_i?
      unless index && index >= 0 && index < bucket_count && index.to_s == path
        raise CorruptPartError.new("inline advanced bucket owner is outside its canonical roster")
      end
      index
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("inline advanced role count overflows UInt64")
      end
      left + right
    end
  end
end
