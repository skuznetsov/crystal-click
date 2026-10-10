module CrystalClick
  # Validated owner tree used while flattening one inline Object callback
  # schedule. Leaf keys are local to their typed/root-Dynamic owner, so the
  # owning Object root and scope are part of every lookup.
  class ObjectDocumentInlineCallbackEvents
    alias CallbackOwner = Tuple(String, String, ObjectDocumentPhysicalPlan, ObjectDocumentPlan)
    alias Event = Tuple(String, String, String)
    alias ChildSite = Tuple(String, Symbol, String, BinaryDynamicJsonLeafKey)

    @owners : Hash(String, CallbackOwner)
    @owner_order : Array(String)
    @parents : Hash(String, String?)
    @children : Hash(ChildSite, String)
    @budget : BinaryCodecBudget

    def initialize(
      root_owner : CallbackOwner,
      descendants : Array(CallbackOwner),
      @budget : BinaryCodecBudget,
    )
      owner_count = descendants.size.to_u64 + 1_u64
      @budget.preflight_children(owner_count)
      @budget.ensure_future_nodes(owner_count)
      @budget.ensure_future_elements(owner_count)
      copied_bytes = 0_u64
      copied_bytes = checked_add(copied_bytes, root_owner[0].bytesize.to_u64)
      copied_bytes = checked_add(copied_bytes, root_owner[1].bytesize.to_u64)
      descendants.each do |owner|
        copied_bytes = checked_add(copied_bytes, owner[0].bytesize.to_u64)
        copied_bytes = checked_add(copied_bytes, owner[1].bytesize.to_u64)
      end
      @budget.ensure_wire_bytes(copied_bytes)
      owner_count.times { @budget.charge_node }
      @budget.charge_elements(owner_count)
      @budget.charge_wire_bytes(copied_bytes) if copied_bytes > 0_u64

      @owners = Hash(String, CallbackOwner).new(initial_capacity: owner_count.to_i)
      @owner_order = Array(String).new(owner_count.to_i)
      @parents = Hash(String, String?).new(initial_capacity: owner_count.to_i)
      @children = Hash(ChildSite, String).new
      register_owner!(root_owner)
      descendants.each { |owner| register_owner!(owner) }

      root_key = @owner_order.first? || raise(UnsupportedFormatError.new("inline callback root owner is missing"))
      root = @owners[root_key]
      expected_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(root[2])
      unless root[0] == expected_root
        raise UnsupportedFormatError.new("inline callback owner root differs from its canonical physical plan")
      end
      index_owner_tree!(root, nil, Hash(String, Bool).new)

      unless @parents.size == @owners.size
        raise UnsupportedFormatError.new("inline callback owner roster has an unreachable descendant")
      end
    end

    def owner_count : Int32
      @owner_order.size
    end

    def owner_at(index : Int, budget : BinaryCodecBudget) : CallbackOwner
      root = @owner_order[index]?
      owner = root.try { |value| @owners[value] } || raise(IndexError.new("inline callback owner index is outside its roster"))
      detached_owner(owner, budget)
    end

    def owner_for_root(root : String, budget : BinaryCodecBudget) : CallbackOwner
      owner = @owners[root]? || raise(UnsupportedFormatError.new("inline callback child owner is missing"))
      detached_owner(owner, budget)
    end

    def child_owner(
      owner_root : String,
      scope_kind : Symbol,
      scope_path : String,
      key : BinaryDynamicJsonLeafKey,
      budget : BinaryCodecBudget,
    ) : CallbackOwner
      child_root = @children[{owner_root, scope_kind, scope_path, key}]? ||
                   raise(UnsupportedFormatError.new("inline JSON leaf has no exact descendant callback owner"))
      owner_for_root(child_root, budget)
    end

    # All recursive descendants of `owner_root`, excluding the owner itself.
    # This preserves local leaf-key scopes when a child scheduler recurses.
    def descendants_for(owner_root : String, budget : BinaryCodecBudget) : Array(CallbackOwner)
      unless @owners.has_key?(owner_root)
        raise UnsupportedFormatError.new("inline callback subtree root is outside its owner roster")
      end
      count = 0_u64
      @owner_order.each do |candidate|
        next if candidate == owner_root
        if ancestor_of?(owner_root, candidate)
          count = checked_add(count, 1_u64)
        end
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      bytes = 0_u64
      @owner_order.each do |candidate|
        next if candidate == owner_root
        next unless ancestor_of?(owner_root, candidate)
        owner = @owners[candidate]
        bytes = checked_add(bytes, owner[0].bytesize.to_u64)
        bytes = checked_add(bytes, owner[1].bytesize.to_u64)
      end
      budget.ensure_wire_bytes(bytes)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      budget.charge_wire_bytes(bytes) if bytes > 0_u64
      result = Array(CallbackOwner).new(count.to_i)
      @owner_order.each do |candidate|
        next if candidate == owner_root
        next unless ancestor_of?(owner_root, candidate)
        result << detached_owner(@owners[candidate], budget, charge: false)
      end
      result
    end

    def root_for_canonical_name(name : String) : String
      selected : String? = nil
      @owner_order.each do |root|
        next unless callback_prefix_boundary?(name, root)
        if selected.nil? || root.bytesize > selected.not_nil!.bytesize
          selected = root
        end
      end
      selected || raise(UnsupportedFormatError.new("inline callback name is outside every Object owner"))
    end

    # The parent Object physical plan already counts ordinary descendant
    # streams. Only Compact's extra Structure split role must be added for
    # each advanced descendant.
    def descendant_advanced_bucket_roles(allow_advanced : Bool, budget : BinaryCodecBudget) : UInt64
      root = @owner_order.first? || return 0_u64
      descendant_advanced_bucket_roles(root, allow_advanced, budget)
    end

    def descendant_advanced_bucket_roles(owner_root : String, allow_advanced : Bool, budget : BinaryCodecBudget) : UInt64
      return 0_u64 unless allow_advanced
      unless @owners.has_key?(owner_root)
        raise UnsupportedFormatError.new("inline callback subtree root is outside its owner roster")
      end
      total = 0_u64
      @owner_order.each do |root|
        next unless ancestor_of?(owner_root, root)
        owner = @owners[root]
        next unless owner[3].structures.object.shared_data_version >= 2_u64
        count = owner[2].shared_bucket_count.to_u64
        total = checked_add(total, count)
      end
      budget.ensure_future_elements(total)
      total
    end

    private def register_owner!(owner : CallbackOwner) : Nil
      if @owners.has_key?(owner[0])
        raise UnsupportedFormatError.new("inline callback owner root is duplicated")
      end
      stored = snapshot_owner(owner)
      # Share the one private root snapshot as the tuple field, hash key, and
      # iteration token; none of these references escape mutable.
      @owners[stored[0]] = stored
      @owner_order << stored[0]
      nil
    end

    private def index_owner_tree!(owner : CallbackOwner, parent : String?, visiting : Hash(String, Bool)) : Nil
      root = owner[0]
      if visiting[root]?
        raise UnsupportedFormatError.new("inline callback owner tree contains a cycle")
      end
      if @parents.has_key?(root)
        raise UnsupportedFormatError.new("inline callback owner is reachable through multiple JSON leaves")
      end
      visiting[root] = true
      @parents[root] = parent

      direct_children = [] of Tuple(ChildSite, String)
      plan = owner[3]
      physical = owner[2]
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        next unless plan.has_typed_dynamic?(path)
        bindings = plan.typed_dynamic_json_object_leaf_plans_for(path, @budget)
        dynamic_physical = physical.typed_dynamic(path)
        append_scope_children!(direct_children, root, :typed_dynamic, path, bindings, dynamic_physical)
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        bindings = plan.root_dynamic_json_object_leaf_plans_for(path, @budget)
        has_physical = physical.has_root_dynamic_json?(path)
        if bindings.empty? && !has_physical
          next
        end
        unless has_physical
          raise UnsupportedFormatError.new("inline root Dynamic JSON bindings have no physical child plan")
        end
        dynamic_physical = physical.root_dynamic_json(path)
        append_scope_children!(direct_children, root, :root_dynamic, path, bindings, dynamic_physical)
      end

      direct_children.each do |entry|
        site_key, child_root = entry
        if @children.has_key?(site_key)
          raise UnsupportedFormatError.new("inline JSON leaf coordinate is duplicated in its owning scope")
        end
        # `child_root` is the one charged private copy created by
        # append_scope_children!; the private lookup table can share it.
        @children[site_key] = child_root
      end

      direct_children.each do |entry|
        child_root = entry[1]
        child = @owners[child_root]? || raise(UnsupportedFormatError.new("inline JSON leaf has no registered child owner"))
        index_owner_tree!(child, root, visiting)
      end
      visiting.delete(root)
      nil
    end

    private def append_scope_children!(
      output : Array(Tuple(ChildSite, String)),
      owner_root : String,
      scope_kind : Symbol,
      scope_path : String,
      bindings : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
      physical : BinaryDynamicBulkPhysicalPlan | ObjectDocumentRootDynamicJsonPhysicalPlan,
    ) : Nil
      site_count = physical.json_object_site_count
      unless site_count >= 0
        raise UnsupportedFormatError.new("inline JSON child-site count is negative")
      end
      unless bindings.size == site_count
        raise UnsupportedFormatError.new("inline JSON child bindings and physical sites differ")
      end
      site_count_u64 = site_count.to_u64
      @budget.preflight_children(site_count_u64) if site_count_u64 > 0_u64
      @budget.ensure_future_nodes(site_count_u64)
      @budget.ensure_future_elements(site_count_u64)
      if site_count > Int32::MAX - output.size
        raise UnsupportedFormatError.new("inline callback child-site roster exceeds the supported domain")
      end
      seen = Hash(BinaryDynamicJsonLeafKey, Bool).new(initial_capacity: bindings.size)
      bindings.each do |binding|
        key = binding[0]
        child_plan = binding[1]
        if seen.has_key?(key)
          raise UnsupportedFormatError.new("inline JSON child binding is duplicated")
        end
        seen[key] = true
        site = physical.json_object_site(key)
        unless site.binding.leaf_key == key && site.binding.plan.same?(child_plan)
          raise UnsupportedFormatError.new("inline JSON child binding differs from its exact physical site")
        end
        child_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(site.physical_plan)
        child = @owners[child_root]? || raise(UnsupportedFormatError.new("inline JSON physical child has no callback owner"))
        unless child[2].same?(site.physical_plan) && child[3].same?(child_plan)
          raise UnsupportedFormatError.new("inline JSON callback owner differs from its prepared child plan")
        end
        @budget.charge_node
        @budget.charge_elements(1_u64)
        path_count = key.descriptor_path_size.to_u64
        copied_elements = checked_add(path_count, 1_u64)
        @budget.ensure_future_elements(copied_elements)
        copied_key_bytes = checked_add(
          key.dynamic_site_bytesize.to_u64,
          checked_multiply(copied_elements, 4_u64),
        )
        copied_owner_bytes = checked_add(
          checked_add(
            checked_add(owner_root.bytesize.to_u64, scope_path.bytesize.to_u64),
            copied_key_bytes,
          ),
          child_root.bytesize.to_u64,
        )
        @budget.ensure_wire_bytes(copied_owner_bytes)
        @budget.charge_elements(copied_elements)
        @budget.charge_wire_bytes(copied_owner_bytes) if copied_owner_bytes > 0_u64
        scoped_key = BinaryDynamicJsonLeafKey.new(key.dynamic_site, key.canonical_arm_index, key.descriptor_child_path)
        scoped_site : ChildSite = {
          String.new(owner_root.to_slice),
          scope_kind,
          String.new(scope_path.to_slice),
          scoped_key,
        }
        # The child root copy is included in copied_owner_bytes. Keep one
        # private instance for both the traversal roster and later lookup.
        owned_child_root = String.new(child_root.to_slice)
        output << {scoped_site, owned_child_root}
      end
      nil
    end

    private def ancestor_of?(ancestor : String, candidate : String) : Bool
      current = candidate
      while parent = @parents[current]?
        return true if parent == ancestor
        current = parent
      end
      false
    end

    private def detached_owner(owner : CallbackOwner, budget : BinaryCodecBudget, charge : Bool = true) : CallbackOwner
      bytes = owner[0].bytesize.to_u64 + owner[1].bytesize.to_u64
      if charge
        budget.ensure_wire_bytes(bytes)
        budget.preflight_children(1_u64)
        budget.charge_node
        budget.charge_wire_bytes(bytes) if bytes > 0_u64
      end
      {String.new(owner[0].to_slice), String.new(owner[1].to_slice), owner[2], owner[3]}
    end

    private def snapshot_owner(owner : CallbackOwner) : CallbackOwner
      {String.new(owner[0].to_slice), String.new(owner[1].to_slice), owner[2], owner[3]}
    end

    private def callback_prefix_boundary?(name : String, prefix : String) : Bool
      return false unless name.starts_with?(prefix)
      return true if name.bytesize == prefix.bytesize
      next_byte = name.byte_at(prefix.bytesize)
      return true if next_byte == '.'.ord.to_u8
      return false if next_byte != '%'.ord.to_u8 || name.bytesize - prefix.bytesize < 3
      name.byte_at(prefix.bytesize + 1) == '2'.ord.to_u8 && name.byte_at(prefix.bytesize + 2) == 'E'.ord.to_u8
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("inline callback owner work size overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("inline callback owner work size overflows UInt64")
      end
      left * right
    end
  end
end
