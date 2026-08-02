# ===========================================================================
# treelist module: Racket-style treelists backed by an RRB tree.
#
# A treelist is an immutable sequence (like a vector for random access, but
# with fast add/insert/append) backed by a Relaxed Radix Balanced (RRB) tree,
# so treelist-ref/-set/-add/-append/-take/-drop/-insert/-delete are all
# O(log n). See https://docs.racket-lang.org/reference/treelist.html.
#
# Two value types are provided: an immutable `SchemeTreelist` and a mutable
# `SchemeMutableTreelist`. The mutable variant is just a box around an
# immutable RRB tree that it replaces on each `!` op — so mutable ops are
# also O(log n) and `mutable-treelist-snapshot` is O(1) (it shares the tree,
# which is safe because the tree itself is persistent/immutable).
#
# Implementation note: every internal branch node carries a cumulative size
# table (i.e. every node is treated as "relaxed"). This is a valid
# specialization of the RRB structure — indexing does a bounded (<= WIDTH)
# size-table scan per level instead of pure radix bit-masking, which keeps
# the code far simpler while preserving the O(log n) guarantees. Concatenation
# rebalances the merge zone (repacking to full WIDTH-sized nodes) so repeated
# appends can't degrade the tree's height.
#
# Not implemented (Racket features that don't map onto this interpreter):
# chaperones/impersonators, the sequence protocol (in-treelist,
# sequence->treelist), and the for/treelist & for*/treelist macros.
# ===========================================================================

module Scheme
  # ------------------------------------------------------------------ engine
  module RRB
    WIDTH = 32

    abstract class Node
      abstract def size : Int32
    end

    class Leaf < Node
      getter items : Array(SchemeValue)

      def initialize(@items : Array(SchemeValue))
      end

      def size : Int32
        @items.size
      end
    end

    class Branch < Node
      getter children : Array(Node)
      getter sizes : Array(Int32) # cumulative: sizes[i] = elements in children[0..i]
      getter height : Int32

      def initialize(@children : Array(Node), @sizes : Array(Int32), @height : Int32)
      end

      def size : Int32
        @sizes.empty? ? 0 : @sizes[-1]
      end
    end

    def self.height_of(n : Node) : Int32
      n.is_a?(Branch) ? n.height : 0
    end

    # Narrow a node to Branch via is_a? rather than .as(Branch): the latter
    # fails to compile in Crystal's per-argument-type specializations of
    # concat_sub that get instantiated with a Leaf argument (the cast is then
    # statically impossible even on a runtime-unreachable path).
    def self.as_branch(n : Node) : Branch
      n.is_a?(Branch) ? n : raise("RRB: expected a branch node")
    end

    # Build a branch from same-height children, computing its size table.
    def self.mk_branch(children : Array(Node)) : Branch
      h = height_of(children[0]) + 1
      sizes = Array(Int32).new(children.size)
      acc = 0
      children.each do |child|
        acc += child.size
        sizes << acc
      end
      Branch.new(children, sizes, h)
    end

    def self.node_ref(node : Node, index : Int32) : SchemeValue
      loop do
        case node
        when Leaf
          return node.items[index]
        when Branch
          i = 0
          while node.sizes[i] <= index
            i += 1
          end
          index -= node.sizes[i - 1] if i > 0
          node = node.children[i]
        end
      end
    end

    def self.node_set(node : Node, index : Int32, v : SchemeValue) : Node
      case node
      when Leaf
        items = node.items.dup
        items[index] = v
        Leaf.new(items)
      else
        node = node.as(Branch)
        i = 0
        while node.sizes[i] <= index
          i += 1
        end
        prev = i > 0 ? node.sizes[i - 1] : 0
        children = node.children.dup
        children[i] = node_set(children[i], index - prev, v)
        Branch.new(children, node.sizes.dup, node.height)
      end
    end

    # Fast rightmost append; returns nil if the rightmost leaf is full.
    def self.fast_push(node : Node, v : SchemeValue) : Node?
      case node
      when Leaf
        node.items.size < WIDTH ? Leaf.new(node.items + [v]) : nil
      else
        node = node.as(Branch)
        child = fast_push(node.children[-1], v)
        return nil if child.nil?
        children = node.children.dup
        children[-1] = child
        sizes = node.sizes.dup
        sizes[-1] += 1
        Branch.new(children, sizes, node.height)
      end
    end

    # Fast leftmost prepend; returns nil if the leftmost leaf is full.
    def self.fast_cons(node : Node, v : SchemeValue) : Node?
      case node
      when Leaf
        node.items.size < WIDTH ? Leaf.new([v] + node.items) : nil
      else
        node = node.as(Branch)
        child = fast_cons(node.children[0], v)
        return nil if child.nil?
        children = node.children.dup
        children[0] = child
        sizes = node.sizes.map { |cum| cum + 1 }
        Branch.new(children, sizes, node.height)
      end
    end

    def self.chunk_leaves(items : Array(SchemeValue)) : Array(Node)
      res = [] of Node
      i = 0
      while i < items.size
        res << Leaf.new(items[i, WIDTH])
        i += WIDTH
      end
      res
    end

    def self.chunk_branches(kids : Array(Node)) : Array(Node)
      res = [] of Node
      i = 0
      while i < kids.size
        res << mk_branch(kids[i, WIDTH])
        i += WIDTH
      end
      res
    end

    # Repack the grandchildren of `merged` (nodes at height `ml`) into full
    # WIDTH-sized nodes, then group them under a branch at height ml+2 with 1
    # or 2 children (at height ml+1) — the shape concat_sub expects back.
    def self.rebalance(merged : Array(Node), ml : Int32) : Branch
      if ml == 0
        items = [] of SchemeValue
        merged.each { |node| items.concat(node.as(Leaf).items) }
        new_nodes = chunk_leaves(items)
      else
        kids = [] of Node
        merged.each { |node| kids.concat(node.as(Branch).children) }
        new_nodes = chunk_branches(kids)
      end

      if new_nodes.size <= WIDTH
        mk_branch([mk_branch(new_nodes).as(Node)])
      else
        a = mk_branch(new_nodes[0...WIDTH])
        b = mk_branch(new_nodes[WIDTH..])
        mk_branch([a.as(Node), b.as(Node)])
      end
    end

    # Concatenate two nodes; returns a branch one level above max(height) with
    # 1 or 2 children (already rebalanced).
    def self.concat_sub(left : Node, right : Node) : Branch
      hl = height_of(left)
      hr = height_of(right)

      if hl == hr
        if left.is_a?(Leaf) && right.is_a?(Leaf)
          combined = left.items + right.items
          if combined.size <= WIDTH
            mk_branch([Leaf.new(combined).as(Node)])
          else
            mk_branch([Leaf.new(combined[0...WIDTH]).as(Node), Leaf.new(combined[WIDTH..]).as(Node)])
          end
        else
          lb = as_branch(left)
          rb = as_branch(right)
          mid = concat_sub(lb.children[-1], rb.children[0])
          merged = lb.children[0...-1] + mid.children + rb.children[1..]
          rebalance(merged, hl - 1)
        end
      elsif hl > hr
        lb = as_branch(left)
        mid = concat_sub(lb.children[-1], right)
        merged = lb.children[0...-1] + mid.children
        rebalance(merged, hl - 1)
      else
        rb = as_branch(right)
        mid = concat_sub(left, rb.children[0])
        merged = mid.children + rb.children[1..]
        rebalance(merged, hr - 1)
      end
    end

    # Extract elements [from, to) from `node`, preserving its height.
    def self.slice_node(node : Node, from : Int32, to : Int32) : Node
      case node
      when Leaf
        Leaf.new(node.items[from...to])
      else
        node = node.as(Branch)
        result = [] of Node
        lo = 0
        node.children.each do |child|
          hi = lo + child.size
          a = Math.max(from, lo)
          b = Math.min(to, hi)
          if a < b
            result << (a == lo && b == hi ? child : slice_node(child, a - lo, b - lo))
          end
          lo = hi
          break if lo >= to
        end
        mk_branch(result)
      end
    end

    # Bulk-load a balanced tree from an array. O(n).
    def self.from_array(items : Array(SchemeValue)) : Node
      return Leaf.new([] of SchemeValue) if items.empty?
      nodes = chunk_leaves(items)
      while nodes.size > 1
        nodes = chunk_branches(nodes)
      end
      nodes[0]
    end

    def self.collect(node : Node, acc : Array(SchemeValue)) : Nil
      case node
      when Leaf
        acc.concat(node.items)
      else
        node.as(Branch).children.each { |child| collect(child, acc) }
      end
    end

    # A persistent treelist: an RRB root plus a cached element count.
    class Tree
      getter root : Node
      getter size : Int32

      def initialize(@root : Node, @size : Int32)
      end

      def self.empty : Tree
        new(Leaf.new([] of SchemeValue), 0)
      end

      def self.from_array(items : Array(SchemeValue)) : Tree
        new(RRB.from_array(items), items.size)
      end

      def ref(i : Int32) : SchemeValue
        RRB.node_ref(@root, i)
      end

      def set(i : Int32, v : SchemeValue) : Tree
        Tree.new(RRB.node_set(@root, i, v), @size)
      end

      def add(v : SchemeValue) : Tree
        if nr = RRB.fast_push(@root, v)
          Tree.new(nr, @size + 1)
        else
          Tree.new(RRB.concat_roots(@root, Leaf.new([v])), @size + 1)
        end
      end

      def cons(v : SchemeValue) : Tree
        if nr = RRB.fast_cons(@root, v)
          Tree.new(nr, @size + 1)
        else
          Tree.new(RRB.concat_roots(Leaf.new([v]), @root), @size + 1)
        end
      end

      def concat(other : Tree) : Tree
        return other if @size == 0
        return self if other.size == 0
        Tree.new(RRB.concat_roots(@root, other.root), @size + other.size)
      end

      def take(n : Int32) : Tree
        return Tree.empty if n <= 0
        return self if n >= @size
        Tree.new(RRB.canonical(RRB.slice_node(@root, 0, n)), n)
      end

      def drop(n : Int32) : Tree
        return self if n <= 0
        return Tree.empty if n >= @size
        Tree.new(RRB.canonical(RRB.slice_node(@root, n, @size)), @size - n)
      end

      def sublist(from : Int32, to : Int32) : Tree
        take(to).drop(from)
      end

      def insert(i : Int32, v : SchemeValue) : Tree
        return cons(v) if i <= 0
        return add(v) if i >= @size
        take(i).concat(Tree.new(Leaf.new([v]), 1)).concat(drop(i))
      end

      def delete(i : Int32) : Tree
        take(i).concat(drop(i + 1))
      end

      def to_a : Array(SchemeValue)
        acc = Array(SchemeValue).new(@size)
        RRB.collect(@root, acc)
        acc
      end

      def reverse : Tree
        Tree.from_array(to_a.reverse!)
      end

      def each(&block : SchemeValue ->) : Nil
        acc = [] of SchemeValue
        RRB.collect(@root, acc)
        acc.each { |v| block.call(v) }
      end
    end

    def self.concat_roots(left : Node, right : Node) : Node
      top = concat_sub(left, right)
      top.children.size == 1 ? top.children[0] : top
    end

    # Strip redundant single-child branch roots left behind by slicing.
    def self.canonical(node : Node) : Node
      while node.is_a?(Branch) && node.children.size == 1
        node = node.children[0]
      end
      node
    end
  end

  # ----------------------------------------------------------------- values
  class SchemeTreelist
    include SchemeBaseValue
    getter tree : RRB::Tree

    def initialize(@tree : RRB::Tree)
    end

    def to_display(io : IO) : Nil
      io << "#<treelist"
      @tree.each { |v| io << ' '; v.to_write(io) }
      io << '>'
    end
  end

  class SchemeMutableTreelist
    include SchemeBaseValue
    property tree : RRB::Tree

    def initialize(@tree : RRB::Tree)
    end

    def to_display(io : IO) : Nil
      io << "#<mutable-treelist"
      @tree.each { |v| io << ' '; v.to_write(io) }
      io << '>'
    end
  end
end

module Scheme::Builtins::Treelist
  extend self
  include Scheme::BuiltinHelpers

  # -------- construction / conversion (immutable) --------

  @[Scheme::SchemeFn("treelist", min: 0, max: -1)]
  def treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(RRB::Tree.from_array(args.dup)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("make-treelist", min: 2, max: 2)]
  def make_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = size_arg(args[0], "make-treelist")
    SchemeTreelist.new(RRB::Tree.from_array(Array(SchemeValue).new(n, args[1]))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("list->treelist", min: 1, max: 1)]
  def list_to_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(RRB::Tree.from_array(Scheme.list_to_a(args[0]))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist->list", min: 1, max: 1)]
  def treelist_to_list(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Scheme.a_to_list(tl_arg(args[0], "treelist->list").to_a)
  end

  @[Scheme::SchemeFn("vector->treelist", min: 1, max: 1)]
  def vector_to_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(RRB::Tree.from_array(vector_arg(args[0], "vector->treelist").dup)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist->vector", min: 1, max: 1)]
  def treelist_to_vector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeVector.new(tl_arg(args[0], "treelist->vector").to_a).as(SchemeValue)
  end

  # -------- predicates / size --------

  @[Scheme::SchemeFn("treelist?", min: 1, max: 1)]
  def treelist_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeTreelist))
  end

  @[Scheme::SchemeFn("treelist-empty?", min: 1, max: 1)]
  def treelist_empty_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(tl_arg(args[0], "treelist-empty?").size == 0)
  end

  @[Scheme::SchemeFn("treelist-length", min: 1, max: 1)]
  def treelist_length(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(tl_arg(args[0], "treelist-length").size.to_i64).as(SchemeValue)
  end

  # -------- access --------

  @[Scheme::SchemeFn("treelist-ref", min: 2, max: 2)]
  def treelist_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-ref")
    t.ref(bounds(args[1], t.size, "treelist-ref"))
  end

  @[Scheme::SchemeFn("treelist-first", min: 1, max: 1)]
  def treelist_first(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-first")
    raise SchemeRuntimeError.new("treelist-first: empty treelist") if t.size == 0
    t.ref(0)
  end

  @[Scheme::SchemeFn("treelist-last", min: 1, max: 1)]
  def treelist_last(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-last")
    raise SchemeRuntimeError.new("treelist-last: empty treelist") if t.size == 0
    t.ref(t.size - 1)
  end

  # -------- functional update --------

  @[Scheme::SchemeFn("treelist-add", min: 2, max: 2)]
  def treelist_add(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(tl_arg(args[0], "treelist-add").add(args[1])).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-cons", min: 2, max: 2)]
  def treelist_cons(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(tl_arg(args[0], "treelist-cons").cons(args[1])).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-set", min: 3, max: 3)]
  def treelist_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-set")
    SchemeTreelist.new(t.set(bounds(args[1], t.size, "treelist-set"), args[2])).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-insert", min: 3, max: 3)]
  def treelist_insert(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-insert")
    SchemeTreelist.new(t.insert(bounds_incl(args[1], t.size, "treelist-insert"), args[2])).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-delete", min: 2, max: 2)]
  def treelist_delete(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-delete")
    SchemeTreelist.new(t.delete(bounds(args[1], t.size, "treelist-delete"))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-take", min: 2, max: 2)]
  def treelist_take(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-take")
    SchemeTreelist.new(t.take(count(args[1], t.size, "treelist-take"))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-drop", min: 2, max: 2)]
  def treelist_drop(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-drop")
    SchemeTreelist.new(t.drop(count(args[1], t.size, "treelist-drop"))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-take-right", min: 2, max: 2)]
  def treelist_take_right(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-take-right")
    n = count(args[1], t.size, "treelist-take-right")
    SchemeTreelist.new(t.drop(t.size - n)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-drop-right", min: 2, max: 2)]
  def treelist_drop_right(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-drop-right")
    n = count(args[1], t.size, "treelist-drop-right")
    SchemeTreelist.new(t.take(t.size - n)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-sublist", min: 3, max: 3)]
  def treelist_sublist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-sublist")
    from = count(args[1], t.size, "treelist-sublist")
    to = count(args[2], t.size, "treelist-sublist")
    raise SchemeRuntimeError.new("treelist-sublist: bad range [#{from}, #{to})") if from > to
    SchemeTreelist.new(t.sublist(from, to)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-rest", min: 1, max: 1)]
  def treelist_rest(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-rest")
    raise SchemeRuntimeError.new("treelist-rest: empty treelist") if t.size == 0
    SchemeTreelist.new(t.drop(1)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-append", min: 0, max: -1)]
  def treelist_append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    acc = RRB::Tree.empty
    args.each { |arg| acc = acc.concat(tl_arg(arg, "treelist-append")) }
    SchemeTreelist.new(acc).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-reverse", min: 1, max: 1)]
  def treelist_reverse(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(tl_arg(args[0], "treelist-reverse").reverse).as(SchemeValue)
  end

  # -------- higher-order --------

  @[Scheme::SchemeFn("treelist-map", min: 2, max: 2)]
  def treelist_map(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-map")
    proc = proc_arg(args[1], "treelist-map")
    mapped = t.to_a.map { |v| interp.apply(proc, [v]) }
    SchemeTreelist.new(RRB::Tree.from_array(mapped)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-filter", min: 2, max: 2)]
  def treelist_filter(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    keep = proc_arg(args[0], "treelist-filter")
    t = tl_arg(args[1], "treelist-filter")
    kept = t.to_a.select { |v| Scheme.truthy?(interp.apply(keep, [v])) }
    SchemeTreelist.new(RRB::Tree.from_array(kept)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-for-each", min: 2, max: 2)]
  def treelist_for_each(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-for-each")
    proc = proc_arg(args[1], "treelist-for-each")
    t.each { |v| interp.apply(proc, [v]) }
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-sort", min: 2, max: 2)]
  def treelist_sort(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-sort")
    less = proc_arg(args[1], "treelist-sort")
    sorted = t.to_a.sort do |lhs, rhs|
      if Scheme.truthy?(interp.apply(less, [lhs, rhs]))
        -1
      elsif Scheme.truthy?(interp.apply(less, [rhs, lhs]))
        1
      else
        0
      end
    end
    SchemeTreelist.new(RRB::Tree.from_array(sorted)).as(SchemeValue)
  end

  # -------- search --------

  @[Scheme::SchemeFn("treelist-member?", min: 2, max: 3)]
  def treelist_member_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-member?")
    SchemeBool.of(find_index(interp, t, args[1], args[2]?, "treelist-member?") != nil)
  end

  @[Scheme::SchemeFn("treelist-index-of", min: 2, max: 3)]
  def treelist_index_of(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-index-of")
    idx = find_index(interp, t, args[1], args[2]?, "treelist-index-of")
    idx ? SchemeInt.new(idx.to_i64).as(SchemeValue) : FALSE.as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-find", min: 2, max: 2)]
  def treelist_find(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = tl_arg(args[0], "treelist-find")
    pred = proc_arg(args[1], "treelist-find")
    t.to_a.each do |v|
      return v if Scheme.truthy?(interp.apply(pred, [v]))
    end
    FALSE.as(SchemeValue)
  end

  # -------- mutable construction / conversion --------

  @[Scheme::SchemeFn("mutable-treelist", min: 0, max: -1)]
  def mutable_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeMutableTreelist.new(RRB::Tree.from_array(args.dup)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("make-mutable-treelist", min: 1, max: 2)]
  def make_mutable_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    n = size_arg(args[0], "make-mutable-treelist")
    fill = args[1]? || FALSE.as(SchemeValue)
    SchemeMutableTreelist.new(RRB::Tree.from_array(Array(SchemeValue).new(n, fill))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("list->mutable-treelist", min: 1, max: 1)]
  def list_to_mutable_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeMutableTreelist.new(RRB::Tree.from_array(Scheme.list_to_a(args[0]))).as(SchemeValue)
  end

  @[Scheme::SchemeFn("vector->mutable-treelist", min: 1, max: 1)]
  def vector_to_mutable_treelist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeMutableTreelist.new(RRB::Tree.from_array(vector_arg(args[0], "vector->mutable-treelist").dup)).as(SchemeValue)
  end

  @[Scheme::SchemeFn("treelist-copy", min: 1, max: 1)]
  def treelist_copy(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeMutableTreelist.new(tl_arg(args[0], "treelist-copy")).as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-copy", min: 1, max: 1)]
  def mutable_treelist_copy(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeMutableTreelist.new(mtl_arg(args[0], "mutable-treelist-copy").tree).as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-snapshot", min: 1, max: 1)]
  def mutable_treelist_snapshot(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeTreelist.new(mtl_arg(args[0], "mutable-treelist-snapshot").tree).as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist->list", min: 1, max: 1)]
  def mutable_treelist_to_list(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Scheme.a_to_list(mtl_arg(args[0], "mutable-treelist->list").tree.to_a)
  end

  @[Scheme::SchemeFn("mutable-treelist->vector", min: 1, max: 1)]
  def mutable_treelist_to_vector(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeVector.new(mtl_arg(args[0], "mutable-treelist->vector").tree.to_a).as(SchemeValue)
  end

  # -------- mutable predicates / size / access --------

  @[Scheme::SchemeFn("mutable-treelist?", min: 1, max: 1)]
  def mutable_treelist_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(args[0].is_a?(SchemeMutableTreelist))
  end

  @[Scheme::SchemeFn("mutable-treelist-empty?", min: 1, max: 1)]
  def mutable_treelist_empty_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(mtl_arg(args[0], "mutable-treelist-empty?").tree.size == 0)
  end

  @[Scheme::SchemeFn("mutable-treelist-length", min: 1, max: 1)]
  def mutable_treelist_length(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeInt.new(mtl_arg(args[0], "mutable-treelist-length").tree.size.to_i64).as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-ref", min: 2, max: 2)]
  def mutable_treelist_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = mtl_arg(args[0], "mutable-treelist-ref").tree
    t.ref(bounds(args[1], t.size, "mutable-treelist-ref"))
  end

  @[Scheme::SchemeFn("mutable-treelist-first", min: 1, max: 1)]
  def mutable_treelist_first(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = mtl_arg(args[0], "mutable-treelist-first").tree
    raise SchemeRuntimeError.new("mutable-treelist-first: empty treelist") if t.size == 0
    t.ref(0)
  end

  @[Scheme::SchemeFn("mutable-treelist-last", min: 1, max: 1)]
  def mutable_treelist_last(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    t = mtl_arg(args[0], "mutable-treelist-last").tree
    raise SchemeRuntimeError.new("mutable-treelist-last: empty treelist") if t.size == 0
    t.ref(t.size - 1)
  end

  # -------- mutable destructive ops --------

  @[Scheme::SchemeFn("mutable-treelist-add!", min: 2, max: 2)]
  def mutable_treelist_add(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-add!")
    m.tree = m.tree.add(args[1])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-cons!", min: 2, max: 2)]
  def mutable_treelist_cons(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-cons!")
    m.tree = m.tree.cons(args[1])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-set!", min: 3, max: 3)]
  def mutable_treelist_set(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-set!")
    m.tree = m.tree.set(bounds(args[1], m.tree.size, "mutable-treelist-set!"), args[2])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-insert!", min: 3, max: 3)]
  def mutable_treelist_insert(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-insert!")
    m.tree = m.tree.insert(bounds_incl(args[1], m.tree.size, "mutable-treelist-insert!"), args[2])
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-delete!", min: 2, max: 2)]
  def mutable_treelist_delete(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-delete!")
    m.tree = m.tree.delete(bounds(args[1], m.tree.size, "mutable-treelist-delete!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-append!", min: 2, max: 2)]
  def mutable_treelist_append(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-append!")
    m.tree = m.tree.concat(any_tree(args[1], "mutable-treelist-append!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-prepend!", min: 2, max: 2)]
  def mutable_treelist_prepend(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-prepend!")
    m.tree = any_tree(args[1], "mutable-treelist-prepend!").concat(m.tree)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-take!", min: 2, max: 2)]
  def mutable_treelist_take(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-take!")
    m.tree = m.tree.take(count(args[1], m.tree.size, "mutable-treelist-take!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-drop!", min: 2, max: 2)]
  def mutable_treelist_drop(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-drop!")
    m.tree = m.tree.drop(count(args[1], m.tree.size, "mutable-treelist-drop!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-take-right!", min: 2, max: 2)]
  def mutable_treelist_take_right(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-take-right!")
    n = count(args[1], m.tree.size, "mutable-treelist-take-right!")
    m.tree = m.tree.drop(m.tree.size - n)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-drop-right!", min: 2, max: 2)]
  def mutable_treelist_drop_right(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-drop-right!")
    n = count(args[1], m.tree.size, "mutable-treelist-drop-right!")
    m.tree = m.tree.take(m.tree.size - n)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-sublist!", min: 3, max: 3)]
  def mutable_treelist_sublist(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-sublist!")
    from = count(args[1], m.tree.size, "mutable-treelist-sublist!")
    to = count(args[2], m.tree.size, "mutable-treelist-sublist!")
    raise SchemeRuntimeError.new("mutable-treelist-sublist!: bad range [#{from}, #{to})") if from > to
    m.tree = m.tree.sublist(from, to)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-reverse!", min: 1, max: 1)]
  def mutable_treelist_reverse(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-reverse!")
    m.tree = m.tree.reverse
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-map!", min: 2, max: 2)]
  def mutable_treelist_map(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-map!")
    proc = proc_arg(args[1], "mutable-treelist-map!")
    m.tree = RRB::Tree.from_array(m.tree.to_a.map { |v| interp.apply(proc, [v]) })
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-sort!", min: 2, max: 2)]
  def mutable_treelist_sort(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-sort!")
    less = proc_arg(args[1], "mutable-treelist-sort!")
    sorted = m.tree.to_a.sort do |lhs, rhs|
      if Scheme.truthy?(interp.apply(less, [lhs, rhs]))
        -1
      elsif Scheme.truthy?(interp.apply(less, [rhs, lhs]))
        1
      else
        0
      end
    end
    m.tree = RRB::Tree.from_array(sorted)
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-for-each", min: 2, max: 2)]
  def mutable_treelist_for_each(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-for-each")
    proc = proc_arg(args[1], "mutable-treelist-for-each")
    m.tree.each { |v| interp.apply(proc, [v]) }
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mutable-treelist-member?", min: 2, max: 3)]
  def mutable_treelist_member_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-member?")
    SchemeBool.of(find_index(interp, m.tree, args[1], args[2]?, "mutable-treelist-member?") != nil)
  end

  @[Scheme::SchemeFn("mutable-treelist-find", min: 2, max: 2)]
  def mutable_treelist_find(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    m = mtl_arg(args[0], "mutable-treelist-find")
    pred = proc_arg(args[1], "mutable-treelist-find")
    m.tree.to_a.each do |v|
      return v if Scheme.truthy?(interp.apply(pred, [v]))
    end
    FALSE.as(SchemeValue)
  end

  # ------------------------------------------------------------- helpers

  private def tl_arg(v : SchemeValue, who : String) : RRB::Tree
    raise SchemeRuntimeError.new("#{who}: expected a treelist, got #{v.write_string}") unless v.is_a?(SchemeTreelist)
    v.tree
  end

  private def mtl_arg(v : SchemeValue, who : String) : SchemeMutableTreelist
    raise SchemeRuntimeError.new("#{who}: expected a mutable treelist, got #{v.write_string}") unless v.is_a?(SchemeMutableTreelist)
    v
  end

  private def any_tree(v : SchemeValue, who : String) : RRB::Tree
    case v
    when SchemeTreelist        then v.tree
    when SchemeMutableTreelist then v.tree
    else
      raise SchemeRuntimeError.new("#{who}: expected a treelist, got #{v.write_string}")
    end
  end

  private def proc_arg(v : SchemeValue, who : String) : SchemeValue
    callable = v.is_a?(Builtin) || v.is_a?(BytecodeClosure) || v.is_a?(BytecodeCaseClosure)
    raise SchemeRuntimeError.new("#{who}: expected a procedure, got #{v.write_string}") unless callable
    v
  end

  private def size_arg(v : SchemeValue, who : String) : Int32
    n = int_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: size must be non-negative, got #{n}") if n < 0
    n.to_i
  end

  # Index that must be within [0, size).
  private def bounds(v : SchemeValue, size : Int32, who : String) : Int32
    i = int_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: index #{i} out of range for treelist of length #{size}") if i < 0 || i >= size
    i.to_i
  end

  # Position that must be within [0, size] (insertion / boundary).
  private def bounds_incl(v : SchemeValue, size : Int32, who : String) : Int32
    i = int_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: position #{i} out of range for treelist of length #{size}") if i < 0 || i > size
    i.to_i
  end

  # Count that must be within [0, size] (take/drop lengths).
  private def count(v : SchemeValue, size : Int32, who : String) : Int32
    i = int_arg(v, who)
    raise SchemeRuntimeError.new("#{who}: count #{i} out of range for treelist of length #{size}") if i < 0 || i > size
    i.to_i
  end

  private def find_index(interp : Interpreter, t : RRB::Tree, needle : SchemeValue, eql : SchemeValue?, who : String) : Int32?
    proc = eql
    if proc && !(proc.is_a?(Builtin) || proc.is_a?(BytecodeClosure) || proc.is_a?(BytecodeCaseClosure))
      raise SchemeRuntimeError.new("#{who}: expected a procedure, got #{proc.write_string}")
    end
    t.to_a.each_with_index do |v, i|
      match = proc ? Scheme.truthy?(interp.apply(proc, [needle, v])) : Scheme.scheme_equal?(needle, v)
      return i if match
    end
    nil
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "builtin", "treelist"] do |env|
      names = register_module(Scheme::Builtins::Treelist, env)
      env.define("empty-treelist", SchemeTreelist.new(RRB::Tree.empty))
      names + ["empty-treelist"]
    end
  end
end
