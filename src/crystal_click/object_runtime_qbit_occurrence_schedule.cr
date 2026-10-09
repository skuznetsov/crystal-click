module CrystalClick
  # Bridges QBit leaf schedules into Object's two runtime authorities:
  # prepared typed-Dynamic plans and inferred Object Dynamic arm rosters.
  # Values continue through the existing bulk/QBit codecs; this owner only
  # validates complete all-mark occurrence shape before a reader is published.
  module ObjectRuntimeQBitOccurrenceSchedule
    alias RoleSet = Hash(String, Bool)

    def self.shape_result_role?(role : String) : Bool
      role.ends_with?(BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX) || role.ends_with?(".discriminators")
    end

    # The reader gathers each retained shape grid once by physical data name,
    # across typed and inferred Dynamic sites, before asking any visitor for a
    # positive window. This prevents a later site from exhausting the shared
    # result allowance after an earlier site's shape bytes were already read.
    # The caller also supplies separate header-prefix reads that precede the
    # census, including headers outside the retained QBit shape roster.
    def self.preflight_shape_results!(
      grids : Hash(String, CompressedMarkGrid),
      budget : CompressedStreamBudget,
      additional_result_bytes : UInt64 = 0_u64,
    ) : Nil
      total = additional_result_bytes
      grids.each_value do |grid|
        unless grid.logical_size >= 0
          raise CorruptPartError.new("Object QBit shape result has a negative logical size")
        end
        total = checked_add(total, grid.logical_size.to_u64)
      end
      if total > Int64::MAX.to_u64
        raise CorruptPartError.new("Object QBit shape result exceeds the bounded transport domain")
      end
      budget.preflight_result_bytes(total.to_i64)
      nil
    end

    def self.typed_dynamic_roles(plan : BinaryDynamicBulkPlan) : RoleSet
      sites = plan.qbit_sites
      return RoleSet.new if sites.empty?
      paths = sites.map(&.path)
      plane_roles = RoleSet.new
      sites.each do |site|
        site.plane_roles.each { |role| plane_roles[role] = true }
      end
      qbit_shape_roles(plan.data_roles, paths, plane_roles)
    end

    def self.static_dynamic_roles(
      type : BinaryDataType,
      physical : BinaryBulkPhysicalPlan,
      limits : BinaryCodecLimits,
    ) : RoleSet
      sites = static_sites(type, limits)
      return RoleSet.new if sites.empty?
      paths = sites.map(&.path)
      plane_roles = RoleSet.new
      sites.each do |site|
        site.plane_roles.each { |role| plane_roles[role] = true }
      end
      qbit_shape_roles(physical.stream_names.keys, paths, plane_roles)
    end

    def self.validate_typed_dynamic!(
      plan : BinaryDynamicBulkPlan,
      type : BinaryDataType,
      physical : BinaryDynamicBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      modes : Hash(String, UInt64),
      parent_rows : Array(UInt64),
      site_grid : StorageOccurrenceGrid,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      shared_totals : BinaryQBitOccurrenceTotals? = nil,
    ) : Nil
      return nil if plan.qbit_sites.empty?
      BinaryDynamicQBitOccurrenceSchedule.validate!(
        plan,
        type,
        physical,
        source,
        grids,
        modes,
        parent_rows,
        site_grid,
        codec_budget,
        transport_budget,
        shared_totals,
      )
    end

    def self.validate_inferred_dynamic!(
      path : String,
      structure : DynamicStructure,
      physical : ObjectDocumentPhysicalPlan,
      source : PartStreamSource,
      discriminator_data_name : String,
      discriminator_marks_name : String,
      discriminator_grid : CompressedMarkGrid,
      arm_grids : Hash(String, Hash(String, CompressedMarkGrid)),
      parent_rows : Array(UInt64),
      site_grid : StorageOccurrenceGrid?,
      limits : BinaryCodecLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      shared_totals : BinaryQBitOccurrenceTotals? = nil,
    ) : Nil
      qbit_arms = [] of Tuple(Int32, BinaryDataType)
      structure.type_count.times do |type_index|
        type = structure.type_at(type_index)
        next unless type.contains_qbit?
        qbit_arms << {structure.canonical_index_for(type), type}
      end
      return nil if qbit_arms.empty?

      schedules = read_full_discriminator_schedules(
        structure,
        source,
        discriminator_data_name,
        discriminator_marks_name,
        discriminator_grid,
        parent_rows,
        site_grid,
        codec_budget,
        transport_budget,
      )
      unless schedules.size == parent_rows.size
        raise CorruptPartError.new("Object Dynamic QBit discriminator schedule has the wrong mark domain")
      end

      qbit_arms.each do |arm_index, type|
        arm_name = structure.canonical_variant_names[arm_index]
        arm_physical = physical.dynamic_arm(path, arm_name)
        sites = static_sites(type, limits)
        unless !sites.empty?
          raise CorruptPartError.new("Object Dynamic QBit arm has no static leaf sites")
        end
        grids = arm_grids[arm_name]? || Hash(String, CompressedMarkGrid).new
        count_reader = ->(mark : Int32) { schedules[mark].arm_count_at(arm_index) }
        BinaryQBitStaticOccurrenceSchedule.validate!(
          type,
          sites,
          arm_physical,
          source,
          grids,
          parent_rows,
          limits,
          transport_budget,
          count_reader,
          shared_totals,
          codec_budget,
        )
      end
      nil
    end

    # Role filtering retains each qbit plane plus only shape lanes that are an
    # ancestor of a planned QBit path. Unrelated ordinary sibling value lanes
    # and their grids are not duplicated into this occurrence owner.
    private def self.qbit_shape_roles(
      all_roles : Array(String),
      qbit_paths : Array(String),
      plane_roles : RoleSet,
    ) : RoleSet
      roles = RoleSet.new(initial_capacity: plane_roles.size + qbit_paths.size)
      plane_roles.each_key { |role| roles[String.new(role.to_slice)] = true }
      all_roles.each do |role|
        suffix = if role.ends_with?(BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX)
                   BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX
                 elsif role.ends_with?(BinaryQBitBulkCodec::NULL_ROLE_SUFFIX)
                   BinaryQBitBulkCodec::NULL_ROLE_SUFFIX
                 elsif role.ends_with?(".discriminators")
                   ".discriminators"
                 else
                   next
                 end
        base = role[0, role.bytesize - suffix.bytesize]
        matches = qbit_paths.any? do |path|
          if suffix == BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX
            path.starts_with?("#{base}#{BinaryQBitBulkCodec::ARRAY_PATH_SUFFIX}")
          elsif suffix == BinaryQBitBulkCodec::NULL_ROLE_SUFFIX
            path.starts_with?("#{base}#{BinaryQBitBulkCodec::NESTED_ROLE_SUFFIX}")
          else
            path.starts_with?("#{base}.arm.")
          end
        end
        roles[String.new(role.to_slice)] = true if matches
      end
      roles
    end

    private def self.static_sites(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
    ) : Array(BinaryQBitRecursiveAdmission::StaticSite)
      return [] of BinaryQBitRecursiveAdmission::StaticSite unless type.contains_qbit?
      sites = BinaryQBitRecursiveAdmission.static_sites(type, limits, false)
      return sites unless sites.empty? && type.tag == BinaryDataType::TAG_QBIT

      qbit_type = type.qbit_type || raise(CorruptPartError.new("Object Dynamic QBit type has no nominal type"))
      column = QBitColumnType.new(qbit_type)
      planes = BinaryQBitBulkCodec.plane_roles(column, "root", limits, false)
      [BinaryQBitRecursiveAdmission::StaticSite.new(
        "root",
        column,
        planes,
        [] of String,
        [] of String,
        nil,
      )] of BinaryQBitRecursiveAdmission::StaticSite
    end

    private def self.read_full_discriminator_schedules(
      structure : DynamicStructure,
      source : PartStreamSource,
      data_name : String,
      marks_name : String,
      grid : CompressedMarkGrid,
      parent_rows : Array(UInt64),
      site_grid : StorageOccurrenceGrid?,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Array(DynamicMarkSchedule)
      mark_count = parent_rows.size
      unless grid.mark_count == mark_count
        raise CorruptPartError.new("Object Dynamic QBit discriminator grid has the wrong mark domain")
      end
      transport_budget.preflight_result_bytes(grid.logical_size)
      window = source.read_window(
        data_name,
        marks_name,
        0,
        mark_count,
        DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
        transport_budget,
      )
      validate_discriminator_window!(window, grid, parent_rows, mark_count)

      marks = Array(DynamicDiscriminatorMark).new(mark_count + 1)
      mark_count.times do |mark|
        rows = site_grid ? site_grid.logical_occurrences_at(mark) : parent_rows[mark]
        marks << DynamicDiscriminatorMark.new(window.offsets[mark], rows)
      end
      marks << DynamicDiscriminatorMark.new(window.offsets.last, 0_u64)
      stream = DynamicDiscriminatorStream.new(window.bytes, marks)
      schedules = if grid_for_site = site_grid
                    DynamicDiscriminatorCodec.decode_child_site_with_budget(
                      structure,
                      stream,
                      grid_for_site,
                      codec_budget,
                    )
                  else
                    DynamicDiscriminatorCodec.decode_with_budget(structure, stream, codec_budget)
                  end
      schedules
    end

    private def self.validate_discriminator_window!(
      window : CompressedMarkWindow,
      grid : CompressedMarkGrid,
      parent_rows : Array(UInt64),
      mark_count : Int32,
    ) : Nil
      prefix = DynamicDiscriminatorCodec::HEADER_BYTES.to_i
      unless window.first_mark == 0 && window.prefix_size == prefix &&
             window.rows_per_mark == parent_rows && window.offsets.size == mark_count + 1 &&
             window.offsets.first? == prefix.to_u64 &&
             window.offsets.last? == window.bytes.size.to_u64
        raise CorruptPartError.new("Object Dynamic QBit discriminator window differs from its inspected grid")
      end
      first_position = grid.position_at(0)
      (0..mark_count).each do |index|
        position = grid.position_at(index)
        unless position >= first_position
          raise CorruptPartError.new("Object Dynamic QBit discriminator grid precedes its prefix")
        end
        expected_offset = prefix.to_u64 + (position - first_position).to_u64
        unless window.offsets[index] == expected_offset
          raise CorruptPartError.new("Object Dynamic QBit discriminator offsets changed after inspection")
        end
      end
      unless window.bytes.size.to_u64 == grid.logical_size.to_u64
        raise CorruptPartError.new("Object Dynamic QBit discriminator bytes changed after inspection")
      end
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Object QBit shape result size overflows UInt64")
      end
      left + right
    end
  end
end
