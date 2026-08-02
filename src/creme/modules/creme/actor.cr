# ===========================================================================
# actor module: fiber-based, location-transparent actors
#
# Each actor is a real Crystal Fiber running its own Interpreter (see
# Interpreter#initialize(inherit_from:) in eval/interpreter.cr — @base_env is
# shared with the spawning interpreter by reference (safe: it's read-only
# past construction), while @global/@libraries are each a private overlay
# seeded from the parent's own at spawn time, so a top-level define/import
# an actor performs lands only in its own frame rather than racing a
# sibling's — with independent per-fiber execution state), paired with an
# inbox Channel(SchemeValue). An actor
# reference is an opaque SchemeBox (tag "actor-ref") wrapping ActorRefData,
# either local (no ActorAddress) or remote (an ActorAddress + id) —
# send!/monitor!/register! branch on `local?`; the three ActorAddress kinds
# below (TCPAddress/UnixAddress/LocalAddress) don't care which is in play.
#
# ActorSystem is the one genuinely cross-Interpreter-shared object in this
# codebase: the registry (id -> ActorContext), the name table, the monitor
# table, and (if start-node was called) a TCP/Unix listener + outbound
# connection pool. It's threaded by direct reference into every Interpreter
# spawned from the same root (see spawn_actor below) rather than being
# module/class-level state, so it never leaks across unrelated Interpreter
# instances. start-node REPLACES whichever ActorSystem is current on the
# calling Interpreter with a fresh one bound to the given address/cookie —
# this is what lets one OS process model more than one logically independent
# "node" (see examples/34-actor-ping-pong.scm, which runs a server node and a
# client node in the same script). The one exception is 'local nodes, which
# register into the process-wide LocalNodeRegistry (below) instead of owning
# a real socket, since "in the same OS process" is the whole point of that
# transport.
#
# Wire format (tcp:/unix: only — 'local delivery skips wire encoding
# entirely, see send_remote): a real socket connection per peer, one dial
# attempt (cached until stop-node!), no reconnect/backoff — a single demo
# transport, not a production connection pool. Authenticated by a mutual
# HMAC-SHA256 nonce-bound challenge/response (modeled on raft.cr's transport
# handshake: github.com/threez/raft.cr/blob/main/src/raft/transport/
# handshake.cr) before any actor traffic crosses it. Frames are
# [type:u8][length:u32 BE][body], one Deliver frame per message
# ([to-len:u16 BE][to bytes][payload bytes]). The payload is plain R7RS data
# produced by write_string/read — records and actor refs are NOT directly
# writable/readable, so to_wire_plain/from_wire_plain recursively swap a
# SchemeRecord for a plain ("@record" type-name field...) list (registering
# the type by name in the shared ActorSystem so the far side can reconstruct
# the SAME SchemeRecordType object its own predicates check against) and a
# local actor ref for an "@ref:tcp://id@host:port" string, leaving every
# other value untouched.
#
# Actor URIs are `<scheme>://<id>@<address>` for every transport — the
# actor id as userinfo (like user@host), so a Unix socket path (which itself
# contains `/`) needs no escaping: everything after `@` to end-of-string is
# the address. `tcp://svc@127.0.0.1:9000`, `unix://svc@/tmp/n.sock`,
# `local://svc@node-a`. This also means a future `tls:` transport is just
# another TCPAddress-shaped case in parse_actor_uri, not a new grammar.
# ===========================================================================

require "socket"
require "openssl/hmac"
require "random/secure"

module Creme
  # One actor's mailbox + identity, cached on its owning Interpreter
  # (Interpreter#actor_context) so repeated (self)/(receive!) calls from the
  # same fiber return/read from the same place.
  class ActorContext
    getter id : String
    getter inbox : Channel(SchemeValue)

    def initialize(@id : String)
      @inbox = Channel(SchemeValue).new(64)
    end
  end

  # Where a non-local ActorRefData's actor lives — one of the three
  # transport kinds (creme actor) supports. A nil `address` on ActorRefData
  # still means "same ActorSystem, deliver_local directly", unchanged from
  # before this type existed.
  abstract class ActorAddress
    abstract def uri(id : String) : String
  end

  # tcp://<id>@<host>:<port>
  class TCPAddress < ActorAddress
    getter host : String
    getter port : Int32

    def initialize(@host : String, @port : Int32)
    end

    def uri(id : String) : String
      "tcp://#{id}@#{host}:#{port}"
    end

    # Key into ActorSystem#@connections — one cached outbound connection
    # per peer address.
    def connection_key : String
      "tcp:#{host}:#{port}"
    end
  end

  # unix://<id>@<path> — a real Unix domain socket, path can itself contain
  # `/`, which is exactly why the id comes first as userinfo.
  class UnixAddress < ActorAddress
    getter path : String

    def initialize(@path : String)
    end

    def uri(id : String) : String
      "unix://#{id}@#{path}"
    end

    def connection_key : String
      "unix:#{path}"
    end
  end

  # local://<id>@<node-name> — an in-process node registered in
  # LocalNodeRegistry (below); send_remote resolves this directly, never
  # reaching dial/connection_for at all.
  class LocalAddress < ActorAddress
    getter node : String

    def initialize(@node : String)
    end

    def uri(id : String) : String
      "local://#{id}@#{node}"
    end
  end

  # The payload an "actor-ref" SchemeBox wraps. Local (address nil) or
  # remote — send!/monitor/register! branch on `local?`; wire encoding turns
  # a local ref into a dialable URI using the CURRENT node's own address
  # (see ActorLibrary#local_ref_uri).
  class ActorRefData
    getter id : String
    getter address : ActorAddress?
    # The ActorSystem `id` is actually registered in -- ONLY meaningful
    # when local? (address.nil?). `local?` only means "same OS process",
    # not "the same ActorSystem as whoever is about to look this ref up"
    # -- an actor can call start-node itself, switching its OWN current
    # system, while still holding (or being handed, e.g. a reply-to ref
    # built via `self` before the switch) a ref minted in a DIFFERENT
    # ActorSystem. send!/monitor used to resolve a local? ref's id
    # against `ensure_system` -- the CALLING actor's own current system
    # -- instead of wherever the id actually lives, which raised a
    # spurious "no such local actor" (silently swallowed by spawn's own
    # rescue) the moment the two diverged, hanging the sender's own
    # receive! forever waiting for a reply that could never arrive. This
    # field lets send!/monitor resolve against the ref's OWN system
    # instead, falling back to the caller's ensure_system only if it's
    # nil (defensive; every ref this library itself constructs always
    # sets it).
    getter system : ActorSystem?

    def initialize(@id : String, @address : ActorAddress? = nil, @system : ActorSystem? = nil)
    end

    def local? : Bool
      @address.nil?
    end

    def uri : String
      @address.as(ActorAddress).uri(@id)
    end

    def uri_or_id : String
      local? ? @id : uri
    end
  end

  # Process-wide registry of "local" nodes (see (creme actor)'s
  # `start-node 'local`): unlike ActorSystem's own per-root-Interpreter-tree
  # registry (below), this one is deliberately process-global, so two
  # independently start-node'd ActorSystems in the same OS process can
  # address each other's actors via local://<id>@<node-name> with no socket,
  # no handshake, and no wire (de)serialization — messages are delivered by
  # direct object reference, since there's no real process boundary to
  # cross. Used for testing multi-node topologies cheaply and for scripts
  # that want more than one named node without paying for real I/O.
  class LocalNodeRegistry
    @@mutex = Mutex.new
    @@nodes = {} of String => ActorSystem

    def self.register(name : String, system : ActorSystem) : Nil
      @@mutex.synchronize do
        raise SchemeRuntimeError.new("start-node: local node '#{name}' is already running") if @@nodes.has_key?(name)
        @@nodes[name] = system
      end
    end

    def self.unregister(name : String) : Nil
      @@mutex.synchronize { @@nodes.delete(name) }
    end

    def self.lookup(name : String) : ActorSystem?
      @@mutex.synchronize { @@nodes[name]? }
    end
  end

  # One node's worth of actor state: local registry/names/monitors, a cache
  # of record types seen (by name) so remotely-received records reconstruct
  # against the SAME SchemeRecordType object this node's own predicates
  # check, and (once start-node is called) a TCP/Unix listener + outbound
  # connection pool — or, for a 'local node, no listener at all (see
  # local_node_name below). See the file header for why this is the one
  # object in this codebase deliberately shared by reference across many
  # Interpreter instances.
  class ActorSystem
    property listener : (TCPServer | UNIXServer)?
    property cookie : String?
    property bind_host : String?
    property bind_port : Int32?
    # Set instead of bind_host/bind_port for a 'unix node — the socket file
    # path this system is listening on.
    property unix_path : String?
    # Set instead of bind_host/bind_port/unix_path for a 'local node — the
    # name this system is registered under in LocalNodeRegistry, needed so
    # shutdown! can unregister it. A node is exactly one of tcp/unix/local;
    # node-port/node-path/node-name each raise if asked about the wrong kind.
    property local_node_name : String?
    # The @global Env of whichever Interpreter created this ActorSystem —
    # captured once, up front (see ActorLibrary#ensure_system/#start_node),
    # so a raw I/O fiber like handle_inbound (which runs NO Scheme VM of its
    # own, so Interpreter.current is nil there) can still resolve a record
    # type by name when reconstructing a message received over the wire
    # (see ActorLibrary#from_wire_plain). This is genuinely shared script-
    # wide — a define-record-type binds its type into @global once, and
    # every "node" in the same script sees the exact same Env object — so
    # this correctly resolves even though the sender and receiver may
    # belong to two different ActorSystems (see start-node's doc comment).
    property global_env : Env?

    def initialize
      @mutex = Mutex.new
      @next_id = 0
      @contexts = {} of String => ActorContext
      @names = {} of String => String
      @monitors = {} of String => Array(String)
      @connections = {} of String => Channel(Bytes)
      @inbound_sockets = [] of (TCPSocket | UNIXSocket)
    end

    def next_id : String
      @mutex.synchronize do
        @next_id += 1
        "actor-#{@next_id}"
      end
    end

    def register_context(ctx : ActorContext) : Nil
      @mutex.synchronize { @contexts[ctx.id] = ctx }
    end

    # Unregisters `id` from THIS system's own registry without touching
    # its monitors/names -- used by start-node when an actor that
    # already has a context (every spawned actor does, registered into
    # whichever system its own spawn call happened in) switches to a
    # brand new system: the context itself must move too, or nothing
    # else can ever find it there again (see start_node's own comment).
    def forget_context(id : String) : Nil
      @mutex.synchronize { @contexts.delete(id) }
    end

    def register_name(name : String, id : String) : Nil
      @mutex.synchronize { @names[name] = id }
    end

    def resolve_name(name : String) : String?
      @mutex.synchronize { @names[name]? }
    end

    def add_monitor(target_id : String, watcher_id : String) : Nil
      @mutex.synchronize { (@monitors[target_id] ||= [] of String) << watcher_id }
    end

    # Delivers by raw actor id first, falling back to the name table — the
    # same lookup handles both a well-known registered service name and an
    # ad-hoc anonymous ref (e.g. a reply-to address) via one code path,
    # since names and generated ids never collide (ids are always
    # "actor-<n>").
    def deliver_local(to : String, msg : SchemeValue) : Bool
      ctx = @mutex.synchronize { @contexts[to]? || @names[to]?.try { |id| @contexts[id]? } }
      return false unless ctx
      ctx.inbox.send(msg)
      true
    end

    # Removes a terminated actor from the registry and returns whoever was
    # watching it, so the caller can notify them.
    def terminated(id : String) : Array(String)
      @mutex.synchronize do
        @contexts.delete(id)
        @monitors.delete(id) || [] of String
      end
    end

    def connection_for(key : String, & : -> Channel(Bytes)) : Channel(Bytes)
      @mutex.synchronize { @connections[key] ||= yield }
    end

    def track_inbound(socket : TCPSocket | UNIXSocket) : Nil
      @mutex.synchronize { @inbound_sockets << socket }
    end

    def shutdown! : Nil
      @mutex.synchronize do
        @listener.try(&.close)
        @connections.each_value(&.close)
        @connections.clear
        @inbound_sockets.each { |socket| socket.close rescue nil }
        @inbound_sockets.clear
      end
      if name = @local_node_name
        LocalNodeRegistry.unregister(name)
      end
    end
  end

  # The <down> notification `monitor` delivers when a watched actor
  # terminates (normally or via an unhandled exception) — a genuine
  # SchemeRecordType/SchemeRecord pair (see eval/record.cr), owned by this
  # module rather than defined via Scheme's own define-record-type, since
  # Crystal-side code (the fiber-termination handler below) is what
  # constructs instances of it.
  DOWN_TYPE = SchemeRecordType.new("down", ["ref", "reason"])
end

module Creme
  class Interpreter
    # The shared ActorSystem this Interpreter (and, transitively, every
    # actor spawned from it) currently belongs to — lazily created on first
    # use, replaced wholesale by start-node. See actor.cr's file header.
    property actor_system : ActorSystem?
    # This Interpreter's own actor identity/mailbox, lazily created the
    # first time the owning fiber calls self/receive!/monitor/register! —
    # covers the "main" script fiber too, which never calls spawn on
    # itself.
    property actor_context : ActorContext?
  end
end

module Creme::Builtins::ActorLibrary
  extend self
  include Creme::BuiltinHelpers

  FRAME_HANDSHAKE = 1_u8
  FRAME_DELIVER   = 2_u8
  FRAME_ERROR     = 3_u8
  NONCE_SIZE      =   32

  # ---- core actor primitives -----------------------------------------------

  @[Creme::SchemeFn("spawn", min: 1, max: 1)]
  def spawn_actor(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    thunk = args[0]
    system = ensure_system
    id = system.next_id
    ctx = ActorContext.new(id)
    system.register_context(ctx)
    child = Interpreter.new(inherit_from: interp)
    child.actor_context = ctx
    child.actor_system = system
    spawn(name: "actor-#{id}") do
      reason = SchemeSym.of("normal").as(SchemeValue)
      begin
        child.apply(thunk, [] of SchemeValue)
      rescue ex : Exception
        reason = SchemeStr.new(ex.message || ex.class.name).as(SchemeValue)
      ensure
        notify_down(system, id, reason)
      end
    end
    make_ref(id, system: system)
  end

  @[Creme::SchemeFn("send!", min: 2, max: 2)]
  def send_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = ensure_system
    target = args[0]
    msg = args[1]
    case target
    when SchemeSym then deliver_named(system, target.name, msg)
    when SchemeStr then deliver_named(system, target.value, msg)
    when SchemeBox
      ref = actor_ref_arg(target, "send!")
      if ref.local?
        target_system = ref.system || system
        raise SchemeRuntimeError.new("send!: no such local actor '#{ref.id}'") unless target_system.deliver_local(ref.id, msg)
      else
        send_remote(system, ref, msg)
      end
    else
      raise SchemeRuntimeError.new("send!: expected an actor reference or registered name, got #{target.write_string}")
    end
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("receive!", min: 0, max: 0)]
  def receive_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    ensure_context.inbox.receive
  end

  @[Creme::SchemeFn("self", min: 0, max: 0)]
  def self_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    make_ref(ensure_context.id, system: ensure_system)
  end

  @[Creme::SchemeFn("monitor", min: 1, max: 1)]
  def monitor(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = ensure_system
    watcher = ensure_context
    target = actor_ref_arg(args[0], "monitor")
    raise SchemeRuntimeError.new("monitor: cannot monitor a remote actor reference") unless target.local?
    (target.system || system).add_monitor(target.id, watcher.id)
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("register!", min: 2, max: 2)]
  def register_bang(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = ensure_system
    name = name_arg(args[0], "register!")
    target = actor_ref_arg(args[1], "register!")
    raise SchemeRuntimeError.new("register!: cannot register a remote actor reference") unless target.local?
    system.register_name(name, target.id)
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("whereis", min: 1, max: 1)]
  def whereis(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = ensure_system
    id = system.resolve_name(name_arg(args[0], "whereis"))
    id ? make_ref(id, system: system) : FALSE.as(SchemeValue)
  end

  @[Creme::SchemeFn("actor-ref-id", min: 1, max: 1)]
  def actor_ref_id(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeStr.new(actor_ref_arg(args[0], "actor-ref-id").id)
  end

  # ---- <down> accessors -----------------------------------------------------

  @[Creme::SchemeFn("down?", min: 1, max: 1)]
  def down_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeRecord) && v.type.same?(DOWN_TYPE))
  end

  @[Creme::SchemeFn("down-ref", min: 1, max: 1)]
  def down_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    down_field(args[0], 0, "down-ref")
  end

  @[Creme::SchemeFn("down-reason", min: 1, max: 1)]
  def down_reason(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    down_field(args[0], 1, "down-reason")
  end

  # ---- location transparency: nodes + remote refs ---------------------------

  # Returns an opaque node handle (in addition to making this node current
  # on the calling Interpreter, as before) so a script that calls
  # start-node more than once — running more than one logically
  # independent node in the same process, see the file header — can still
  # stop_node! an EARLIER node after switching to a later one; without the
  # handle, stop-node! could only ever reach whichever ActorSystem happens
  # to be current right now.
  #
  # Two calling conventions: `(start-node host port cookie)` — the original,
  # untagged 3-arg form, always 'tcp, kept working forever for backward
  # compatibility — or a transport-tagged form: `(start-node 'tcp host port
  # cookie)`, `(start-node 'unix path cookie)`, `(start-node 'local name
  # cookie)`.
  @[Creme::SchemeFn("start-node", min: 3, max: 4)]
  def start_node(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = ActorSystem.new
    system.global_env = current_interp.global
    tag = args[0]
    display =
      if tag.is_a?(SchemeSym)
        rest = args[1..]
        case tag.name
        when "tcp"   then start_tcp_node(system, rest)
        when "unix"  then start_unix_node(system, rest)
        when "local" then start_local_node(system, rest)
        else
          raise SchemeRuntimeError.new("start-node: unknown transport '#{tag.name}', expected 'tcp, 'unix, or 'local")
        end
      else
        start_tcp_node(system, args) # legacy untagged (host port cookie) == 'tcp
      end
    # Reassigning actor_system alone only changes which system FUTURE
    # ensure_system/ensure_context calls land in -- it does nothing for
    # a context that already exists (every spawned actor has one,
    # registered into whichever system was current at spawn time,
    # before this actor's own thunk -- and this start-node call -- ever
    # ran). Without migrating it too, this actor's own id stays findable
    # only in the OLD system: any OTHER actor holding a ref to this one
    # minted AFTER this switch (e.g. a `(self)` reply-to address, which
    # now correctly carries `system` as ActorRefData's own field) would
    # have send!/monitor resolve against the NEW system's registry and
    # find nothing there, raising "no such local actor" -- silently
    # swallowed by spawn's own rescue, hanging the sender's own
    # receive! forever. Moving the context is the other half of the
    # same fix that gave ActorRefData a system field in the first
    # place.
    old_system = current_interp.actor_system
    current_interp.actor_system = system
    if ctx = current_interp.actor_context
      old_system.try(&.forget_context(ctx.id))
      system.register_context(ctx)
    end
    SchemeBox.new("actor-node", system, "#<actor-node:#{display}>")
  end

  private def start_tcp_node(system : ActorSystem, args : Array(SchemeValue)) : String
    raise SchemeRuntimeError.new("start-node: 'tcp expects (host port cookie), got #{args.size} argument(s)") unless args.size == 3
    host = string_arg(args[0], "start-node")
    port = int_arg(args[1], "start-node").to_i32
    cookie = string_arg(args[2], "start-node")
    server = TCPServer.new(host, port)
    system.listener = server
    system.cookie = cookie
    system.bind_host = host
    system.bind_port = server.local_address.port
    spawn(name: "actor-node-accept") { accept_loop(server, system) }
    "#{host}:#{system.bind_port}"
  end

  private def start_unix_node(system : ActorSystem, args : Array(SchemeValue)) : String
    raise SchemeRuntimeError.new("start-node: 'unix expects (path cookie), got #{args.size} argument(s)") unless args.size == 2
    path = string_arg(args[0], "start-node")
    cookie = string_arg(args[1], "start-node")
    File.delete(path) rescue nil # drop a stale socket file from a prior crashed run
    server = UNIXServer.new(path)
    system.listener = server
    system.cookie = cookie
    system.unix_path = path
    spawn(name: "actor-node-accept") { accept_loop(server, system) }
    path
  end

  private def start_local_node(system : ActorSystem, args : Array(SchemeValue)) : String
    raise SchemeRuntimeError.new("start-node: 'local expects (name cookie), got #{args.size} argument(s)") unless args.size == 2
    name = string_arg(args[0], "start-node")
    cookie = string_arg(args[1], "start-node")
    system.cookie = cookie
    system.local_node_name = name
    LocalNodeRegistry.register(name, system)
    name
  end

  # (node-address node id) -> the full dialable URI for actor `id` on
  # `node` — "tcp://id@host:port", "unix://id@/path", or "local://id@name"
  # depending which transport `node` was started with. Meant to replace
  # manually string-appending a URI (e.g. examples/34-actor-ping-pong.scm
  # used to build "tcp://ping-server@127.0.0.1:<port>" by hand); the result
  # is exactly what remote-ref expects. `id` may be a registered name
  # (symbol/string, e.g. 'ping-server) OR an actor-ref directly (its own
  # .id is used) — the latter accepted for symmetry with cvm's own
  # node-address (cvm/actor.c), which supports both forms.
  @[Creme::SchemeFn("node-address", min: 2, max: 2)]
  def node_address(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = node_arg(args[0], "node-address")
    id_arg = args[1]
    id = (id_arg.is_a?(SchemeBox) && id_arg.tag == "actor-ref") ? id_arg.get(ActorRefData).id : name_arg(id_arg, "node-address")
    SchemeStr.new(node_address_uri(system, id, "node-address"))
  end

  @[Creme::SchemeFn("node-port", min: 0, max: 1)]
  def node_port(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = args[0]? ? node_arg(args[0], "node-port") : current_interp.actor_system
    raise SchemeRuntimeError.new("node-port: start-node has not been called") unless system
    port = system.bind_port
    raise SchemeRuntimeError.new("node-port: this node has no TCP port (started as 'unix or 'local)") unless port
    SchemeInt.new(port.to_i64)
  end

  @[Creme::SchemeFn("node-path", min: 0, max: 1)]
  def node_path(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = args[0]? ? node_arg(args[0], "node-path") : current_interp.actor_system
    raise SchemeRuntimeError.new("node-path: start-node has not been called") unless system
    path = system.unix_path
    raise SchemeRuntimeError.new("node-path: this node has no socket path (started as 'tcp or 'local)") unless path
    SchemeStr.new(path)
  end

  @[Creme::SchemeFn("node-name", min: 0, max: 1)]
  def node_name(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = args[0]? ? node_arg(args[0], "node-name") : current_interp.actor_system
    raise SchemeRuntimeError.new("node-name: start-node has not been called") unless system
    name = system.local_node_name
    raise SchemeRuntimeError.new("node-name: this node has no name (started as 'tcp or 'unix)") unless name
    SchemeStr.new(name)
  end

  @[Creme::SchemeFn("stop-node!", min: 0, max: 1)]
  def stop_node(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    system = args[0]? ? node_arg(args[0], "stop-node!") : current_interp.actor_system
    system.try(&.shutdown!)
    NIL.as(SchemeValue)
  end

  @[Creme::SchemeFn("remote-ref", min: 1, max: 1)]
  def remote_ref(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    address, id = parse_actor_uri(string_arg(args[0], "remote-ref"), "remote-ref")
    make_ref(id, address)
  end

  # ---- argument helpers -----------------------------------------------------

  # The Interpreter whose VM is actually running THIS fiber right now —
  # NOT the `interp` parameter a builtin method receives, which is whichever
  # Interpreter originally registered the Builtin closure into @global
  # (captured once, at construction time — see actor.cr's file header on
  # why actors share @global by reference). Interpreter.current instead
  # reads the Fiber-keyed stack VM#execute/VM#call push/pop, which reflects
  # whichever Interpreter's `.call`/`.apply` is actually on this fiber's
  # stack right now — correct per-actor identity.
  private def current_interp : Interpreter
    Interpreter.current.as(Interpreter)
  end

  private def ensure_system : ActorSystem
    interp = current_interp
    interp.actor_system ||= ActorSystem.new.tap(&.global_env=(interp.global))
  end

  private def ensure_context : ActorContext
    interp = current_interp
    if ctx = interp.actor_context
      return ctx
    end
    system = ensure_system
    id = system.next_id
    ctx = ActorContext.new(id)
    system.register_context(ctx)
    interp.actor_context = ctx
    ctx
  end

  private def make_ref(id : String, address : ActorAddress? = nil, system : ActorSystem? = nil) : SchemeValue
    data = ActorRefData.new(id, address, system)
    SchemeBox.new("actor-ref", data, "#<actor:#{data.uri_or_id}>")
  end

  private def actor_ref_arg(v : SchemeValue, who : String) : ActorRefData
    raise SchemeRuntimeError.new("#{who}: expected an actor reference, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "actor-ref"
    v.get(ActorRefData)
  end

  private def node_arg(v : SchemeValue, who : String) : ActorSystem
    raise SchemeRuntimeError.new("#{who}: expected a node handle, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "actor-node"
    v.get(ActorSystem)
  end

  private def name_arg(v : SchemeValue, who : String) : String
    case v
    when SchemeSym then v.name
    when SchemeStr then v.value
    else                raise SchemeRuntimeError.new("#{who}: expected a symbol or string name, got #{v.write_string}")
    end
  end

  private def down_field(v : SchemeValue, idx : Int32, who : String) : SchemeValue
    raise SchemeRuntimeError.new("#{who}: expected a <down> record, got #{v.write_string}") unless v.is_a?(SchemeRecord) && v.type.same?(DOWN_TYPE)
    v.fields[idx]
  end

  # Every actor URI is <scheme>://<id>@<address> — the actor id as userinfo
  # (like user@host), so a Unix path (which itself contains `/`) needs no
  # escaping: everything after `@` to end-of-string is the address.
  private def parse_actor_uri(uri : String, who : String) : {ActorAddress, String}
    if m = uri.match(/\Atcp:\/\/([^@]+)@([^:\/]+):(\d+)\z/)
      {TCPAddress.new(m[2], m[3].to_i), m[1]}
    elsif m = uri.match(/\Aunix:\/\/([^@]+)@(.+)\z/)
      {UnixAddress.new(m[2]), m[1]}
    elsif m = uri.match(/\Alocal:\/\/([^@]+)@([^\/]+)\z/)
      {LocalAddress.new(m[2]), m[1]}
    else
      raise SchemeRuntimeError.new("#{who}: malformed actor URI: #{uri}")
    end
  end

  private def deliver_named(system : ActorSystem, name : String, msg : SchemeValue) : Nil
    raise SchemeRuntimeError.new("send!: no actor registered as '#{name}'") unless system.deliver_local(name, msg)
  end

  private def notify_down(system : ActorSystem, id : String, reason : SchemeValue) : Nil
    watchers = system.terminated(id)
    return if watchers.empty?
    down = SchemeRecord.new(DOWN_TYPE, [make_ref(id, system: system), reason])
    watchers.each { |watcher_id| system.deliver_local(watcher_id, down) }
  end

  # ---- TCP/Unix transport: handshake, framing, connection lifecycle --------
  # (see send_remote below for 'local delivery, which never reaches any of
  # this — no socket, no handshake, no wire encoding).

  private def accept_loop(server : TCPServer | UNIXServer, system : ActorSystem) : Nil
    loop do
      socket = server.accept?
      break unless socket
      system.track_inbound(socket)
      spawn(name: "actor-node-inbound") { handle_inbound(socket, system) }
    end
  rescue IO::Error
  end

  private def handle_inbound(socket : TCPSocket | UNIXSocket, system : ActorSystem) : Nil
    handshake_respond(socket, system.cookie.as(String))
    loop do
      type, body = read_frame(socket)
      next unless type == FRAME_DELIVER
      to, payload = parse_deliver_body(body)
      msg = decode_message(payload, system)
      system.deliver_local(to, msg)
    end
  rescue IO::Error | SchemeRuntimeError
    # peer closed, or handshake/frame was bad — drop the connection quietly.
  ensure
    socket.close rescue nil
  end

  private def send_remote(system : ActorSystem, ref : ActorRefData, msg : SchemeValue) : Nil
    address = ref.address.as(ActorAddress)
    if address.is_a?(LocalAddress)
      # In-process delivery: no socket, no handshake, no string (de)serial-
      # ization — the message is delivered by direct object reference, the
      # same as any other same-process deliver_local. Any bare (same-
      # system) actor ref embedded in the message — most commonly a
      # reply-to address built via (self) — still needs rewriting into a
      # fully-qualified local:// address before it crosses into a
      # DIFFERENT ActorSystem, exactly as local_ref_uri does for a
      # tcp:/unix: send; localize_refs is that rewrite without the string
      # round-trip.
      target = LocalNodeRegistry.lookup(address.node)
      raise SchemeRuntimeError.new("send!: no local node registered as '#{address.node}'") unless target
      localized = localize_refs(msg, system)
      raise SchemeRuntimeError.new("send!: no such local actor '#{ref.id}' on node '#{address.node}'") unless target.deliver_local(ref.id, localized)
      return
    end
    key = case address
          when TCPAddress  then address.connection_key
          when UnixAddress then address.connection_key
          else                  raise "unreachable: a LocalAddress never reaches here (see the early return above)"
          end
    payload = encode_message(msg, system)
    frame = build_frame(FRAME_DELIVER, build_deliver_body(ref.id, payload))
    chan = system.connection_for(key) { dial(address, system) }
    chan.send(frame)
  rescue ex : IO::Error
    raise SchemeRuntimeError.new("send!: connection to #{ref.uri_or_id} failed: #{ex.message}")
  end

  private def dial(address : ActorAddress, system : ActorSystem) : Channel(Bytes)
    cookie = system.cookie
    raise SchemeRuntimeError.new("send!: start-node must be called before contacting a remote actor") unless cookie
    socket = case address
             when TCPAddress
               s = TCPSocket.new(address.host, address.port)
               s.tcp_nodelay = true
               s.as(TCPSocket | UNIXSocket)
             when UnixAddress
               UNIXSocket.new(address.path).as(TCPSocket | UNIXSocket)
             else
               raise "unreachable: a LocalAddress never reaches dial (see send_remote)"
             end
    handshake_initiate(socket, cookie)
    chan = Channel(Bytes).new(64)
    spawn(name: "actor-send-#{address.uri("*")}") do
      begin
        loop do
          socket.write(chan.receive)
          socket.flush
        end
      rescue Channel::ClosedError | IO::Error
      ensure
        socket.close rescue nil
      end
    end
    chan
  end

  private def handshake_initiate(io : IO, cookie : String) : Nil
    nonce = Random::Secure.random_bytes(NONCE_SIZE)
    write_frame(io, FRAME_HANDSHAKE, concat_bytes(nonce, OpenSSL::HMAC.digest(:sha256, cookie, nonce)))
    io.flush
    type, body = read_frame(io)
    raise SchemeRuntimeError.new("actor: handshake failed") unless type == FRAME_HANDSHAKE && body.size == NONCE_SIZE * 2
    resp_nonce, resp_hmac = body[0, NONCE_SIZE], body[NONCE_SIZE, NONCE_SIZE]
    expected = OpenSSL::HMAC.digest(:sha256, cookie, concat_bytes(nonce, resp_nonce))
    raise SchemeRuntimeError.new("actor: handshake authentication rejected") unless constant_time_eq(resp_hmac, expected)
  end

  private def handshake_respond(io : IO, cookie : String) : Nil
    type, body = read_frame(io)
    raise SchemeRuntimeError.new("actor: handshake failed") unless type == FRAME_HANDSHAKE && body.size == NONCE_SIZE * 2
    initiator_nonce, initiator_hmac = body[0, NONCE_SIZE], body[NONCE_SIZE, NONCE_SIZE]
    unless constant_time_eq(initiator_hmac, OpenSSL::HMAC.digest(:sha256, cookie, initiator_nonce))
      write_frame(io, FRAME_ERROR, "authentication failed".to_slice)
      io.flush
      raise SchemeRuntimeError.new("actor: handshake authentication rejected")
    end
    resp_nonce = Random::Secure.random_bytes(NONCE_SIZE)
    resp_hmac = OpenSSL::HMAC.digest(:sha256, cookie, concat_bytes(initiator_nonce, resp_nonce))
    write_frame(io, FRAME_HANDSHAKE, concat_bytes(resp_nonce, resp_hmac))
    io.flush
  end

  private def constant_time_eq(a : Bytes, b : Bytes) : Bool
    return false if a.size != b.size
    result = 0_u8
    a.size.times { |i| result |= a[i] ^ b[i] }
    result == 0
  end

  private def concat_bytes(a : Bytes, b : Bytes) : Bytes
    combined = Bytes.new(a.size + b.size)
    a.copy_to(combined[0, a.size])
    b.copy_to(combined[a.size, b.size])
    combined
  end

  private def build_frame(type : UInt8, body : Bytes) : Bytes
    io = IO::Memory.new
    io.write_bytes(type)
    io.write_bytes(body.size.to_u32, IO::ByteFormat::BigEndian)
    io.write(body)
    io.to_slice
  end

  private def write_frame(io : IO, type : UInt8, body : Bytes) : Nil
    io.write(build_frame(type, body))
  end

  private def read_frame(io : IO) : {UInt8, Bytes}
    type = io.read_bytes(UInt8)
    len = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
    body = Bytes.new(len)
    io.read_fully(body)
    {type, body}
  end

  private def build_deliver_body(to : String, payload : String) : Bytes
    to_bytes = to.to_slice
    payload_bytes = payload.to_slice
    io = IO::Memory.new
    io.write_bytes(to_bytes.size.to_u16, IO::ByteFormat::BigEndian)
    io.write(to_bytes)
    io.write(payload_bytes)
    io.to_slice
  end

  private def parse_deliver_body(body : Bytes) : {String, String}
    to_len = (body[0].to_u16 << 8) | body[1]
    to = String.new(body[2, to_len])
    payload = String.new(body[2 + to_len, body.size - 2 - to_len])
    {to, payload}
  end

  # ---- wire (de)serialization: plain data + records + actor refs ------------

  private def encode_message(msg : SchemeValue, system : ActorSystem) : String
    to_wire_plain(msg, system).write_string
  end

  private def decode_message(text : String, system : ActorSystem) : SchemeValue
    tokens = Lexer.tokenize(text, "<actor-wire>")
    from_wire_plain(Reader.new(tokens).read_form, system)
  end

  # The 'local-transport equivalent of to_wire_plain's ref-rewriting: since
  # a local: send delivers `v` by direct object reference (no string
  # encode/decode — see send_remote), a value with no embedded ref needing
  # rewriting is returned completely unchanged (eq? the original) — only
  # the minimal spine containing a rewritten ref is ever rebuilt. Only a
  # bare (same-system) actor ref embedded anywhere in `v` needs rewriting,
  # into a fully-qualified local:// address naming `sender`'s own node, so
  # the destination ActorSystem (a DIFFERENT object from the sender's) can
  # resolve it — otherwise e.g. a (self) reply-to ref would be delivered as
  # an ambiguous "local to whichever system happens to receive this" ref
  # and silently resolve against the WRONG system's registry.
  private def localize_refs(v : SchemeValue, sender : ActorSystem) : SchemeValue
    case v
    when SchemeBox
      return v.as(SchemeValue) unless v.tag == "actor-ref"
      data = v.get(ActorRefData)
      return v.as(SchemeValue) unless data.local?
      name = sender.local_node_name
      raise SchemeRuntimeError.new("send!: cannot forward a local actor reference over a local: link before this node's own start-node 'local has been called") unless name
      make_ref(data.id, LocalAddress.new(name))
    when SchemeRecord
      changed = false
      fields = v.fields.map do |field|
        new_field = localize_refs(field, sender)
        changed = true unless new_field == field
        new_field
      end
      changed ? SchemeRecord.new(v.type, fields).as(SchemeValue) : v.as(SchemeValue)
    when Cons
      car = localize_refs(v.car, sender)
      cdr = localize_refs(v.cdr, sender)
      car == v.car && cdr == v.cdr ? v.as(SchemeValue) : Cons.new(car, cdr).as(SchemeValue)
    when SchemeVector
      changed = false
      values = v.value.map do |e|
        ne = localize_refs(e, sender)
        changed = true unless ne == e
        ne
      end
      changed ? SchemeVector.new(values).as(SchemeValue) : v.as(SchemeValue)
    else
      v
    end
  end

  private def to_wire_plain(v : SchemeValue, system : ActorSystem) : SchemeValue
    case v
    when SchemeRecord
      fields = v.fields.map { |field| to_wire_plain(field, system) }
      Creme.a_to_list([SchemeStr.new("@record").as(SchemeValue), SchemeStr.new(v.type.name).as(SchemeValue)] + fields)
    when SchemeBox
      if v.tag == "actor-ref"
        ref = v.get(ActorRefData)
        uri = ref.local? ? local_ref_uri(ref, system) : ref.uri
        SchemeStr.new("@ref:#{uri}").as(SchemeValue)
      else
        v
      end
    when Cons
      Cons.new(to_wire_plain(v.car, system), to_wire_plain(v.cdr, system)).as(SchemeValue)
    when SchemeVector
      SchemeVector.new(v.value.map { |e| to_wire_plain(e, system) }).as(SchemeValue)
    else
      v
    end
  end

  private def from_wire_plain(v : SchemeValue, system : ActorSystem) : SchemeValue
    case v
    when SchemeStr
      v.value.starts_with?("@ref:") ? decode_ref(v.value[5..]) : v.as(SchemeValue)
    when Cons
      items = begin
        Creme.list_to_a(v)
      rescue
        nil
      end
      if items && items.size >= 2 && (tag = items[0]).is_a?(SchemeStr) && tag.value == "@record"
        type_name = items[1].as(SchemeStr).value
        type = system.global_env.try(&.get?(type_name)).as?(SchemeRecordType)
        raise SchemeRuntimeError.new("actor: received unknown record type '#{type_name}' over the network") unless type
        SchemeRecord.new(type, items[2..].map { |field| from_wire_plain(field, system) }).as(SchemeValue)
      else
        Cons.new(from_wire_plain(v.car, system), from_wire_plain(v.cdr, system)).as(SchemeValue)
      end
    when SchemeVector
      SchemeVector.new(v.value.map { |e| from_wire_plain(e, system) }).as(SchemeValue)
    else
      v
    end
  end

  # The full dialable URI for actor `id` on `system`, whichever transport it
  # was started with — shared by local_ref_uri (below, for tcp:/unix: wire
  # sends) and the node-address builtin.
  private def node_address_uri(system : ActorSystem, id : String, who : String) : String
    if (host = system.bind_host) && (port = system.bind_port)
      TCPAddress.new(host, port).uri(id)
    elsif path = system.unix_path
      UnixAddress.new(path).uri(id)
    elsif name = system.local_node_name
      LocalAddress.new(name).uri(id)
    else
      raise SchemeRuntimeError.new("#{who}: start-node has not been called")
    end
  end

  # Only reached over a tcp:/unix: wire (see to_wire_plain above) — a
  # 'local-only node's own refs never cross this path at all, since
  # send_remote's LocalAddress branch never calls to_wire_plain/
  # encode_message in the first place.
  private def local_ref_uri(ref : ActorRefData, system : ActorSystem) : String
    node_address_uri(system, ref.id, "send!")
  end

  private def decode_ref(uri : String) : SchemeValue
    address, id = parse_actor_uri(uri, "actor")
    make_ref(id, address)
  end
end

module Creme
  class Interpreter
    register_library ["creme", "builtin", "actor"], Creme::Builtins::ActorLibrary
  end
end
