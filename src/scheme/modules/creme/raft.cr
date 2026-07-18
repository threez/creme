# ===========================================================================
# raft module: replicated state machines via threez/raft.cr
#
# A cluster node is an opaque SchemeBox (tag "raft-node") wrapping a
# Raft::Node; logs ("raft-log"), transports ("raft-transport"), configs
# ("raft-config"), and state machines ("raft-state-machine") are each their
# own tag. A state machine is built from three ordinary Scheme procedures
# (apply-proc, snapshot-proc, restore-proc — see SchemeRaftStateMachine
# below) rather than a Crystal subclass, matching how (creme mux)'s route
# handlers and (creme actor)'s spawn thunks are plain Scheme closures
# invoked via Interpreter#apply. Commands/snapshots round-trip as R7RS
# bytevectors (SchemeBlob) — encode/decode application data with
# write/read + string->utf8/utf8->string, or (creme json), as needed.
#
# Raft::Node drives its own event loop and replicator fibers internally and
# calls the state machine's apply/snapshot/restore from those fibers, not
# from whichever fiber called raft-start!/raft-propose! — this is fine
# since Interpreter#apply and Interpreter.current are fiber-keyed (see
# eval/interpreter.cr), the same property (creme actor)/(creme mux) rely on
# for their own cross-fiber callbacks.
#
# (raft-transport-in-memory id)/(raft-log-in-memory) are for single-process
# clusters (tests, examples/37-raft-kv-store.scm) — real deployments use
# (raft-transport-tcp)/(raft-log-file) instead. Every Raft::Error subclass
# is caught at the builtin boundary and re-wrapped as a SchemeRuntimeError.
#
# raft-read's linearizability barrier (Raft::Node#read) internally reproposes
# a zero-length bytevector through the ordinary replicated log before
# performing the real read, so apply-proc WILL be called with an empty
# bytevector it never issued itself — it must tolerate that (returning
# anything; the result is discarded) rather than assuming every applied
# command is one its own decode step produced.
#
# apply-proc must not raise: an uncaught Scheme error there crashes the
# node's own event-loop fiber (see Raft::Node#apply_committed_entries)
# without ever resolving the Channel a concurrent raft-propose!/raft-read
# call is blocked on, so that caller hangs forever instead of seeing the
# error — guard/catch unknown commands inside apply-proc rather than
# letting them propagate. See (creme raft-machine)'s `raft-commands` for
# a declarative dispatcher that still raises on an unknown command, but
# only when called directly (outside a real node's apply/propose cycle).
#
# Raft::Transport::InMemory (lib/raft/src/raft/transport/in_memory.cr) keeps
# its peer registry in a Crystal CLASS variable — one flat, process-wide
# namespace keyed only by node id, shared across every raft-transport-in-
# memory call regardless of which cluster or Interpreter created it. Two
# clusters sharing an id (e.g. both naming a node "n1") silently cross-talk
# rather than erroring (Raft::Transport#send is "best-effort, silently
# dropped" by design), and raft-transport-in-memory-reset! clears that
# entire registry, not just one cluster's slice of it. raft-fresh-namespace
# returns a string unique for the lifetime of the OS process (a Crystal
# class-variable counter — deliberately not Interpreter-scoped `gensym`,
# since the registry it protects against outlives any one Interpreter) —
# (creme raft-machine)'s `raft-cluster` uses it to prefix every id
# automatically, so callers going through that DSL never need
# raft-transport-in-memory-reset! at all. Raw (creme raft) usage building
# ids by hand still needs its own namespacing convention (or the reset,
# accepting that it's global) to run more than one in-memory cluster safely.
# ===========================================================================

require "raft"

module Scheme
  # Bridges a Raft::StateMachine to three Scheme procedures. apply-proc
  # receives/returns a bytevector; snapshot-proc takes no arguments and
  # returns a bytevector; restore-proc receives a bytevector and its return
  # value is ignored. Constructed once per (raft-state-machine ...) call
  # and shared by every raft-node built from it.
  class SchemeRaftStateMachine < Raft::StateMachine
    include Scheme::BuiltinHelpers

    def initialize(@interp : Interpreter, @apply_proc : SchemeValue,
                   @snapshot_proc : SchemeValue, @restore_proc : SchemeValue)
    end

    def apply(command : Bytes) : Bytes
      result = @interp.apply(@apply_proc, [SchemeBlob.new(command).as(SchemeValue)])
      blob_arg(result, "raft-state-machine apply-proc")
    end

    def snapshot : Bytes
      result = @interp.apply(@snapshot_proc, [] of SchemeValue)
      blob_arg(result, "raft-state-machine snapshot-proc")
    end

    def restore(io : IO) : Nil
      buf = IO::Memory.new
      IO.copy(io, buf)
      @interp.apply(@restore_proc, [SchemeBlob.new(buf.to_slice.dup).as(SchemeValue)])
      nil
    end
  end
end

module Scheme::Builtins::RaftLibrary
  extend self
  include Scheme::BuiltinHelpers

  # ---- logs ------------------------------------------------------------

  @[Scheme::SchemeFn("raft-log-in-memory", min: 0, max: 0)]
  def raft_log_in_memory(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBox.new("raft-log", Raft::Log::InMemory.new, "#<raft-log:in-memory>")
  end

  @[Scheme::SchemeFn("raft-log-file", min: 1, max: 2)]
  def raft_log_file(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    path = string_arg(args[0], "raft-log-file")
    fsync = args.size == 2 ? Scheme.truthy?(args[1]) : true
    SchemeBox.new("raft-log", Raft::Log::File.new(path, fsync), "#<raft-log:file:#{path}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("raft-log-file: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-log?", min: 1, max: 1)]
  def raft_log_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(raft_tag?(args[0], "raft-log"))
  end

  # ---- transports --------------------------------------------------------

  @[Scheme::SchemeFn("raft-transport-in-memory", min: 1, max: 1)]
  def raft_transport_in_memory(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    id = string_arg(args[0], "raft-transport-in-memory")
    SchemeBox.new("raft-transport", Raft::Transport::InMemory.new(id), "#<raft-transport:in-memory:#{id}>")
  end

  @[Scheme::SchemeFn("raft-transport-in-memory-reset!", min: 0, max: 0)]
  def raft_transport_in_memory_reset(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Raft::Transport::InMemory.reset
    NIL.as(SchemeValue)
  end

  # A fresh id-prefix, unique for the life of the OS process — see this
  # file's header comment for why that's a process-wide Crystal class
  # variable rather than an Interpreter-scoped `gensym`. An `Atomic` (rather
  # than a plain increment guarded by nothing) is required as soon as more
  # than one OS thread can run Scheme fibers concurrently (-Dpreview_mt with
  # CRYSTAL_WORKERS > 1) — a bare `+= 1` is a non-atomic read-modify-write
  # that can drop increments or hand out a duplicate id under real
  # parallelism, even though it's safe under single-OS-thread cooperative
  # fiber scheduling.
  @@namespace_counter = Atomic(UInt64).new(0_u64)

  @[Scheme::SchemeFn("raft-fresh-namespace", min: 0, max: 1)]
  def raft_fresh_namespace(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    prefix = args.size == 1 ? string_arg(args[0], "raft-fresh-namespace") : "raft"
    n = @@namespace_counter.add(1_u64) + 1_u64
    SchemeStr.new("#{prefix}-#{n}")
  end

  @[Scheme::SchemeFn("raft-transport-partition!", min: 2, max: 2)]
  def raft_transport_partition(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Raft::Transport::InMemory.partition(string_arg(args[0], "raft-transport-partition!"), string_arg(args[1], "raft-transport-partition!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("raft-transport-heal!", min: 2, max: 2)]
  def raft_transport_heal(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    Raft::Transport::InMemory.heal(string_arg(args[0], "raft-transport-heal!"), string_arg(args[1], "raft-transport-heal!"))
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("raft-transport-tcp", min: 3, max: 4)]
  def raft_transport_tcp(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    bind_host = string_arg(args[0], "raft-transport-tcp")
    port = int_arg(args[1], "raft-transport-tcp").to_i32
    peer_addresses = Hash(String, {String, Int32}).new
    Scheme.list_to_a(args[2]).each do |entry|
      cons = raft_cons_arg(entry, "raft-transport-tcp")
      addr = raft_cons_arg(cons.cdr, "raft-transport-tcp")
      peer_addresses[string_arg(cons.car, "raft-transport-tcp")] = {string_arg(addr.car, "raft-transport-tcp"), int_arg(addr.cdr, "raft-transport-tcp").to_i32}
    end
    cookie = args.size == 4 ? string_arg(args[3], "raft-transport-tcp") : ""
    SchemeBox.new("raft-transport", Raft::Transport::TCP.new(bind_host, port, peer_addresses, cookie), "#<raft-transport:tcp:#{bind_host}:#{port}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("raft-transport-tcp: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-transport?", min: 1, max: 1)]
  def raft_transport_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(raft_tag?(args[0], "raft-transport"))
  end

  # ---- config --------------------------------------------------------------

  @[Scheme::SchemeFn("raft-config", min: 0, max: 1)]
  def raft_config(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    overrides = Hash(String, SchemeValue).new
    if args.size == 1
      Scheme.list_to_a(args[0]).each do |entry|
        cons = raft_cons_arg(entry, "raft-config")
        overrides[raft_key_arg(cons.car, "raft-config")] = cons.cdr
      end
    end
    # Defaults mirror Raft::Config#initialize (lib/raft/src/raft/config.cr) —
    # duplicated here since active_passive?/rtt_tuning? are read-only getters,
    # so every field must go through the constructor rather than a setter.
    config = Raft::Config.new(
      election_timeout_min: config_int(overrides, "election-timeout-min", 150),
      election_timeout_max: config_int(overrides, "election-timeout-max", 300),
      heartbeat_interval: config_int(overrides, "heartbeat-interval", 50),
      max_entries_per_rpc: config_int(overrides, "max-entries-per-rpc", 100),
      cookie: config_string(overrides, "cookie", ""),
      snapshot_chunk_size: config_int(overrides, "snapshot-chunk-size", 65536),
      snapshot_threshold: config_int(overrides, "snapshot-threshold", 1000),
      max_inflight_rpcs: config_int(overrides, "max-inflight-rpcs", 2),
      active_passive: config_bool(overrides, "active-passive", false),
      rtt_tuning: config_bool(overrides, "rtt-tuning", false),
      rtt_probe_interval: config_int(overrides, "rtt-probe-interval", 60),
    )
    SchemeBox.new("raft-config", config, "#<raft-config>")
  end

  @[Scheme::SchemeFn("raft-config?", min: 1, max: 1)]
  def raft_config_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(raft_tag?(args[0], "raft-config"))
  end

  # ---- state machine ---------------------------------------------------

  @[Scheme::SchemeFn("raft-state-machine", min: 3, max: 3)]
  def raft_state_machine(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    sm = SchemeRaftStateMachine.new(interp, args[0], args[1], args[2])
    SchemeBox.new("raft-state-machine", sm, "#<raft-state-machine>")
  end

  @[Scheme::SchemeFn("raft-state-machine?", min: 1, max: 1)]
  def raft_state_machine_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(raft_tag?(args[0], "raft-state-machine"))
  end

  # ---- node --------------------------------------------------------------

  @[Scheme::SchemeFn("raft-node", min: 5, max: 7)]
  def raft_node(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    id = string_arg(args[0], "raft-node")
    peers = Scheme.list_to_a(args[1]).map { |v| string_arg(v, "raft-node") }
    state_machine = raft_state_machine_arg(args[2], "raft-node")
    transport = raft_transport_arg(args[3], "raft-node")
    log = raft_log_arg(args[4], "raft-node")
    config = args.size >= 6 ? raft_config_arg(args[5], "raft-node") : Raft::Config.new
    learners = args.size >= 7 ? Scheme.list_to_a(args[6]).map { |v| string_arg(v, "raft-node") } : [] of String
    node = Raft::Node.new(id, peers, state_machine, transport, log, config, learners)
    SchemeBox.new("raft-node", node, "#<raft-node:#{id}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("raft-node: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-node?", min: 1, max: 1)]
  def raft_node_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBool.of(raft_tag?(args[0], "raft-node"))
  end

  @[Scheme::SchemeFn("raft-start!", min: 1, max: 1)]
  def raft_start(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-start!").start
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("raft-stop!", min: 1, max: 1)]
  def raft_stop(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-stop!").stop
    NIL.as(SchemeValue)
  end

  # Blocks the calling fiber (yielding to the nodes' own event-loop/timer
  # fibers, which is what actually decides the election — busy-polling
  # `raft-role` from Scheme alone would never yield, since this dialect has
  # no general-purpose sleep primitive) until one of `nodes` becomes leader
  # or `timeout-ms` (default 5000) elapses. Returns that node, or `#f`.
  @[Scheme::SchemeFn("raft-await-leader!", min: 1, max: 2)]
  def raft_await_leader(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    candidates = Scheme.list_to_a(args[0]).map { |v| {v, raft_node_arg(v, "raft-await-leader!")} }
    timeout_ms = args.size == 2 ? int_arg(args[1], "raft-await-leader!").to_i32 : 5000
    deadline = Time.instant + timeout_ms.milliseconds
    loop do
      candidates.each do |scheme_node, node|
        return scheme_node if node.role.leader?
      end
      return FALSE.as(SchemeValue) if Time.instant >= deadline
      sleep 10.milliseconds
    end
  end

  @[Scheme::SchemeFn("raft-propose!", min: 2, max: 2)]
  def raft_propose(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    node = raft_node_arg(args[0], "raft-propose!")
    command = blob_arg(args[1], "raft-propose!")
    SchemeBlob.new(node.propose(command))
  rescue ex : Raft::Error
    raise SchemeRuntimeError.new("raft-propose!: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-read", min: 2, max: 2)]
  def raft_read(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    node = raft_node_arg(args[0], "raft-read")
    command = blob_arg(args[1], "raft-read")
    SchemeBlob.new(node.read(command))
  rescue ex : Raft::Error
    raise SchemeRuntimeError.new("raft-read: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-leader", min: 1, max: 1)]
  def raft_leader(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    leader = raft_node_arg(args[0], "raft-leader").leader
    leader ? SchemeStr.new(leader).as(SchemeValue) : FALSE.as(SchemeValue)
  end

  @[Scheme::SchemeFn("raft-role", min: 1, max: 1)]
  def raft_role(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeSym.of(raft_node_arg(args[0], "raft-role").role.to_s.downcase)
  end

  @[Scheme::SchemeFn("raft-add-peer!", min: 2, max: 2)]
  def raft_add_peer(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-add-peer!").add_peer(string_arg(args[1], "raft-add-peer!"))
    NIL.as(SchemeValue)
  rescue ex : Raft::Error
    raise SchemeRuntimeError.new("raft-add-peer!: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-add-learner!", min: 2, max: 2)]
  def raft_add_learner(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-add-learner!").add_learner(string_arg(args[1], "raft-add-learner!"))
    NIL.as(SchemeValue)
  rescue ex : Raft::Error
    raise SchemeRuntimeError.new("raft-add-learner!: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-promote-learner!", min: 2, max: 2)]
  def raft_promote_learner(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-promote-learner!").promote_learner(string_arg(args[1], "raft-promote-learner!"))
    NIL.as(SchemeValue)
  rescue ex : Raft::Error
    raise SchemeRuntimeError.new("raft-promote-learner!: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-remove-peer!", min: 2, max: 2)]
  def raft_remove_peer(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-remove-peer!").remove_peer(string_arg(args[1], "raft-remove-peer!"))
    NIL.as(SchemeValue)
  rescue ex : Raft::Error
    raise SchemeRuntimeError.new("raft-remove-peer!: #{ex.message}")
  end

  @[Scheme::SchemeFn("raft-snapshot!", min: 1, max: 1)]
  def raft_snapshot(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    raft_node_arg(args[0], "raft-snapshot!").snapshot
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("raft-metrics", min: 1, max: 1)]
  def raft_metrics(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    metrics = raft_node_arg(args[0], "raft-metrics").metrics
    pairs = metrics.to_h.map do |key, value|
      scheme_value = value.is_a?(String) ? SchemeStr.new(value).as(SchemeValue) : SchemeInt.new(value.as(UInt64).to_i64).as(SchemeValue)
      Cons.new(SchemeSym.of(key.gsub('_', '-')).as(SchemeValue), scheme_value).as(SchemeValue)
    end
    Scheme.a_to_list(pairs)
  end

  # ---- arg helpers -------------------------------------------------------

  private def config_int(overrides : Hash(String, SchemeValue), key : String, default : Int32) : Int32
    overrides[key]?.try { |v| int_arg(v, "raft-config").to_i32 } || default
  end

  private def config_string(overrides : Hash(String, SchemeValue), key : String, default : String) : String
    overrides[key]?.try { |v| string_arg(v, "raft-config") } || default
  end

  private def config_bool(overrides : Hash(String, SchemeValue), key : String, default : Bool) : Bool
    overrides[key]?.try { |v| Scheme.truthy?(v) } || default
  end

  private def raft_tag?(v : SchemeValue, tag : String) : Bool
    v.is_a?(SchemeBox) && v.tag == tag
  end

  private def raft_cons_arg(v : SchemeValue, who : String) : Cons
    raise SchemeRuntimeError.new("#{who}: expected a pair, got #{v.write_string}") unless v.is_a?(Cons)
    v
  end

  private def raft_key_arg(v : SchemeValue, who : String) : String
    case v
    when SchemeSym then v.name
    when SchemeStr then v.value
    else                raise SchemeRuntimeError.new("#{who}: expected a symbol key, got #{v.write_string}")
    end
  end

  private def raft_log_arg(v : SchemeValue, who : String) : Raft::Log
    raise SchemeRuntimeError.new("#{who}: expected a raft-log, got #{v.write_string}") unless raft_tag?(v, "raft-log")
    v.as(SchemeBox).get(Raft::Log)
  end

  private def raft_transport_arg(v : SchemeValue, who : String) : Raft::Transport
    raise SchemeRuntimeError.new("#{who}: expected a raft-transport, got #{v.write_string}") unless raft_tag?(v, "raft-transport")
    v.as(SchemeBox).get(Raft::Transport)
  end

  private def raft_config_arg(v : SchemeValue, who : String) : Raft::Config
    raise SchemeRuntimeError.new("#{who}: expected a raft-config, got #{v.write_string}") unless raft_tag?(v, "raft-config")
    v.as(SchemeBox).get(Raft::Config)
  end

  private def raft_state_machine_arg(v : SchemeValue, who : String) : Raft::StateMachine
    raise SchemeRuntimeError.new("#{who}: expected a raft-state-machine, got #{v.write_string}") unless raft_tag?(v, "raft-state-machine")
    v.as(SchemeBox).get(Raft::StateMachine)
  end

  private def raft_node_arg(v : SchemeValue, who : String) : Raft::Node
    raise SchemeRuntimeError.new("#{who}: expected a raft-node, got #{v.write_string}") unless raft_tag?(v, "raft-node")
    v.as(SchemeBox).get(Raft::Node)
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "raft"], Scheme::Builtins::RaftLibrary
  end
end
