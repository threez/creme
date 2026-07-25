# ===========================================================================
# mux module: HTTP server + path-based routing, built on threez/mux.cr
# (a thin frontend over luislavena/radix) plus stdlib HTTP::Server.
#
# A router is an opaque SchemeBox (tag "mux-router"); route handlers are
# ordinary Scheme procedures of one argument, a request alist:
#   ((method . "GET") (path . "/foo/1") (path-params . (("id" . "1")))
#    (headers . (("content-type" . "text/plain"))) (remote-addr . "1.2.3.4:5678")
#    (body . "..."))
# and must return a response alist, mirroring the (creme http) convention:
#   ((status . 200) (headers . (("content-type" . "text/plain"))) (body . "..."))
# `body` is either a plain string (written as-is) or a procedure of one
# argument, a port — called directly against the real HTTP response IO
# (via a SchemePort wrapping context.response) instead of being stringified
# first, so a handler can stream a large/dynamic body (e.g. built with
# (creme html)'s html-write!/html-document-write!) without ever
# materializing the whole thing as one Crystal String first — the win is
# skipping the Scheme-side string-building/generic-conversion work for the
# body, not necessarily the wire format: Crystal's HTTP::Server::Response
# still buffers internally and computes a real Content-Length for anything
# that fits in its buffer, falling back to chunked transfer encoding only
# once a response outgrows it, same as for a plain string body. Status/
# headers are always set before any body byte is written, streaming or
# not.
#
# `(mux-use! router middleware)` registers a middleware — an ordinary
# two-argument Scheme procedure `(lambda (request next) ...)` — onto the
# router; every middleware registered on a router wraps every one of that
# router's routes once `mux-listen!` starts the server, in registration
# order (first-registered = outermost). `next` is a zero-argument Scheme
# procedure that runs the rest of the chain (the next middleware, or
# finally the matched route) and returns the resulting HTTP status code as
# an integer; a middleware can run code both before calling `next` (e.g.
# capture a start time) and after it returns (e.g. log using the now-known
# status) — the classic "onion" shape, same as Rack/Express middleware. If
# a middleware calls `next`, its own return value is ignored (the response
# was already written by whatever `next` reached). If a middleware never
# calls `next`, it short-circuits the request — no route handler ever runs
# — and its return value is instead treated exactly like a route handler's:
# a response alist, written the same way. This is built entirely on
# Crystal's own HTTP::Server handler-chaining
# (`HTTP::Server.new(handlers : Indexable(HTTP::Handler))`, each handler
# calling `call_next` to continue) — Mux::Router itself already
# `include`s `HTTP::Handler`, so it's simply the last handler in that
# chain, with one small MuxMiddlewareHandler wrapping each registered
# Scheme middleware in front of it.
#
# `mux-listen!` starts the server on a spawned Fiber (non-blocking) and
# returns an opaque server handle (tag "mux-server") — pass port 0 to
# `mux-listen!` for an OS-assigned ephemeral port, then read the real one
# back via `mux-address` (host/port alist) or `mux-base-url` ("http://host:port",
# ready to concatenate a path onto for a (creme http) client call) — and
# `mux-close!` to shut the server down.
# ===========================================================================

require "mux"

# Caches the request body on the context itself: with middleware in front
# of the router, request_to_scheme can now be called more than once per
# request (once per middleware, once for the matched route), but
# HTTP::Request#body is a stream, only readable once, so a naive second
# call would see an already-drained body. Only the body is cached (not the
# whole alist) — path-params specifically must NOT be cached, since
# Mux::Router only populates request.path_params once its own routing
# actually runs (inside call_next, downstream of any middleware), so a
# request built before that point genuinely has no path-params yet; a
# request built after routing (inside the matched route's own handler)
# correctly sees them. Caching on the context itself (rather than some
# separate keyed cache needing its own cleanup) means this is leak-free
# for free: the cached value's lifetime is exactly the context's own.
class HTTP::Server::Context
  property mux_body : String?

  # This request's own Interpreter — see request_interpreter below for why
  # every middleware/route handler in this one request's chain shares
  # exactly one (not the router-registration-time Interpreter directly).
  property mux_interp : Scheme::Interpreter?
end

module Scheme
  # The "mux-router" SchemeBox's wrapped value: the real Mux::Router plus
  # the ordered list of Scheme middleware procedures registered onto it via
  # mux-use! (empty until mux-use! is called at least once).
  class MuxApp
    getter router : Mux::Router
    getter middlewares : Array(SchemeValue)

    def initialize(@router : Mux::Router)
      @middlewares = [] of SchemeValue
    end
  end

  # Sits as the very first handler in mux-listen!'s chain (see mux_listen
  # below): acquires this request's own child Interpreter from the
  # ROOT Interpreter's pool (Interpreter#acquire_child_interpreter — see its
  # own doc comment for why a real pool, not just Interpreter.new(
  # inherit_from:) every time, is worth the trouble), stashes it on the
  # context for every downstream middleware/route handler to share (see
  # HTTP::Server::Context#mux_interp), then releases it back to the pool
  # once the ENTIRE chain has unwound. Centralizing acquire/release here
  # (rather than in request_interpreter, which runs once per handler in the
  # chain) guarantees exactly one acquire and one release per request
  # regardless of how many middlewares are registered — request_interpreter
  # itself just reads whatever this handler already stashed.
  class MuxInterpreterPoolHandler
    include HTTP::Handler

    def initialize(@interp : Interpreter)
    end

    def call(context : HTTP::Server::Context) : Nil
      child = @interp.acquire_child_interpreter
      context.mux_interp = child
      call_next(context)
    ensure
      @interp.release_child_interpreter(child) if child
    end
  end

  # Wraps one Scheme middleware as a Crystal HTTP::Handler, so it can sit in
  # Crystal's own handler chain in front of the router. Builds the request
  # alist once (the same shape every route handler gets) and a `next`
  # procedure that runs the rest of the chain and reports back the status
  # code that ended up on the wire.
  class MuxMiddlewareHandler
    include HTTP::Handler

    def initialize(@interp : Interpreter, @middleware : SchemeValue)
    end

    def call(context : HTTP::Server::Context) : Nil
      request = Scheme::Builtins::MuxLibrary.request_to_scheme(context)
      request_interp = Scheme::Builtins::MuxLibrary.request_interpreter(context, @interp)
      called_next = false
      next_proc = Builtin.new("mux-middleware-next", 0, 0) do |_args|
        called_next = true
        call_next(context)
        SchemeInt.new(context.response.status_code.to_i64).as(SchemeValue)
      end
      result = request_interp.apply(@middleware, [request, next_proc.as(SchemeValue)])
      Scheme::Builtins::MuxLibrary.write_response(request_interp, context, result, "mux-use!") unless called_next
    end
  end
end

module Scheme::Builtins::MuxLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("mux-router", min: 0, max: 0)]
  def mux_router(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBox.new("mux-router", Scheme::MuxApp.new(Mux::Router.new), "#<mux-router>")
  end

  @[Scheme::SchemeFn("mux-router?", min: 1, max: 1)]
  def mux_router_p(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    v = args[0]
    SchemeBool.of(v.is_a?(SchemeBox) && v.tag == "mux-router")
  end

  {% for method in ["get", "head", "post", "put", "delete", "patch"] %}
    @[Scheme::SchemeFn("mux-{{method.id}}!", min: 3, max: 3)]
    def mux_{{method.id}}(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
      register_route(interp, args, {{method}}, "mux-{{method.id}}!")
    end
  {% end %}

  @[Scheme::SchemeFn("mux-use!", min: 2, max: 2)]
  def mux_use(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    app = mux_router_arg(args[0], "mux-use!")
    app.middlewares << args[1]
    NIL.as(SchemeValue)
  end

  @[Scheme::SchemeFn("mux-listen!", min: 2, max: 3)]
  def mux_listen(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    app = mux_router_arg(args[0], "mux-listen!")
    host, port = if args.size == 3
                   {mux_str_arg(args[1], "mux-listen!"), mux_int_arg(args[2], "mux-listen!")}
                 else
                   {"127.0.0.1", mux_int_arg(args[1], "mux-listen!")}
                 end
    handlers = [Scheme::MuxInterpreterPoolHandler.new(interp).as(HTTP::Handler)]
    handlers.concat(app.middlewares.map { |middleware| Scheme::MuxMiddlewareHandler.new(interp, middleware).as(HTTP::Handler) })
    handlers << app.router.as(HTTP::Handler)
    server = HTTP::Server.new(handlers)
    address = server.bind_tcp(host, port)
    spawn { server.listen }
    Fiber.yield
    SchemeBox.new("mux-server", {server, address}, "#<mux-server:#{address}>")
  rescue ex : Exception
    raise SchemeRuntimeError.new("mux-listen!: #{ex.message}")
  end

  @[Scheme::SchemeFn("mux-address", min: 1, max: 1)]
  def mux_address(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    _, address = mux_server_arg(args[0], "mux-address")
    Scheme.a_to_list([
      Cons.new(SchemeStr.new("host"), SchemeStr.new(address.address)).as(SchemeValue),
      Cons.new(SchemeStr.new("port"), SchemeInt.new(address.port.to_i64)).as(SchemeValue),
    ])
  end

  @[Scheme::SchemeFn("mux-base-url", min: 1, max: 1)]
  def mux_base_url(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    _, address = mux_server_arg(args[0], "mux-base-url")
    SchemeStr.new("http://#{address.address}:#{address.port}")
  end

  @[Scheme::SchemeFn("mux-close!", min: 1, max: 1)]
  def mux_close(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    server, _ = mux_server_arg(args[0], "mux-close!")
    server.close
    NIL.as(SchemeValue)
  rescue ex : Exception
    raise SchemeRuntimeError.new("mux-close!: #{ex.message}")
  end

  private def register_route(interp : Interpreter, args : Array(SchemeValue), method : String, who : String) : SchemeValue
    app = mux_router_arg(args[0], who)
    path = mux_str_arg(args[1], who)
    handler = args[2]
    app.router.add_handler(path, method: method) do |context|
      request_interp = request_interpreter(context, interp)
      response = request_interp.apply(handler, [request_to_scheme(context)] of SchemeValue)
      write_response(request_interp, context, response, who)
    end
    NIL.as(SchemeValue)
  end

  # Every request handled by mux-listen! runs against its OWN Interpreter —
  # a lightweight child of whichever Interpreter registered the route/
  # middleware (the exact same isolation (creme actor)'s `spawn` gives each
  # actor). This is required, not just tidy: an Interpreter's own
  # @call_stack (backtrace tracking, mutated on every function call) and
  # other per-instance bookkeeping (gensym counter, eval-depth,
  # exception-handler stack, ...) are NOT safe for two Fibers to touch at
  # the same instant — reusing the single router-registration-time
  # Interpreter directly across every concurrently-handled request
  # corrupted @call_stack under real multi-core parallelism
  # (-Dpreview_mt with more than one OS thread; see competition/results.md
  # in the repo root for how this was found). One Interpreter per HTTP
  # request (shared across that request's own middleware chain + route
  # handler via HTTP::Server::Context#mux_interp) mirrors actor isolation
  # at HTTP-request granularity.
  #
  # The actual acquire (and matching release) happens once per request in
  # MuxInterpreterPoolHandler, the first handler in mux-listen!'s chain —
  # this just reads whatever it already stashed on the context, so every
  # downstream middleware/route handler in the same request shares exactly
  # one child Interpreter. Interpreter#acquire_child_interpreter pulls a
  # reset, already-warm child (own @vm_pool intact) from the root
  # Interpreter's pool instead of allocating a fresh one — see its own doc
  # comment. The `||=` fallback below only matters if a caller invokes a
  # registered route/middleware handler directly, bypassing
  # MuxInterpreterPoolHandler entirely (e.g. a test harness) — that path
  # still works, just unpooled, exactly as this used to always behave.
  def request_interpreter(context : HTTP::Server::Context, interp : Interpreter) : Interpreter
    context.mux_interp ||= Interpreter.new(inherit_from: interp)
  end

  # Public (not private): also called by Scheme::MuxMiddlewareHandler, a
  # sibling class in this same file, to build the request alist a
  # middleware receives — the exact same shape a route handler gets.
  def request_to_scheme(context : HTTP::Server::Context) : SchemeValue
    request = context.request
    header_pairs = [] of SchemeValue
    request.headers.each do |name, values|
      header_pairs << Cons.new(SchemeStr.new(name), SchemeStr.new(values.join(", "))).as(SchemeValue)
    end
    param_pairs = (request.path_params || {} of String => String).map do |name, value|
      Cons.new(SchemeStr.new(name), SchemeStr.new(value)).as(SchemeValue)
    end
    body = cached_body(context)
    remote_addr = request.remote_address.try(&.to_s) || ""
    Scheme.a_to_list([
      Cons.new(SchemeStr.new("method"), SchemeStr.new(request.method)).as(SchemeValue),
      Cons.new(SchemeStr.new("path"), SchemeStr.new(request.path)).as(SchemeValue),
      Cons.new(SchemeStr.new("path-params"), Scheme.a_to_list(param_pairs)).as(SchemeValue),
      Cons.new(SchemeStr.new("headers"), Scheme.a_to_list(header_pairs)).as(SchemeValue),
      Cons.new(SchemeStr.new("remote-addr"), SchemeStr.new(remote_addr)).as(SchemeValue),
      Cons.new(SchemeStr.new("body"), SchemeStr.new(body)).as(SchemeValue),
    ])
  end

  # See HTTP::Server::Context#mux_body's own comment: the request body is a
  # stream, only safely readable once, but request_to_scheme may now run
  # more than once per request (middleware, then the matched route).
  private def cached_body(context : HTTP::Server::Context) : String
    if cached = context.mux_body
      return cached
    end
    value = context.request.body.try(&.gets_to_end) || ""
    context.mux_body = value
    value
  end

  # Public (not private): also called by Scheme::MuxMiddlewareHandler, a
  # sibling class in this same file, to write a short-circuiting
  # middleware's own returned response alist (when it never calls `next`).
  def write_response(interp : Interpreter, context : HTTP::Server::Context, response : SchemeValue, who : String) : Nil
    body_value = alist_lookup(response, "body")
    body_proc = body_value if body_value && callable?(body_value)
    native = Scheme.from_scheme(body_proc ? alist_without(response, "body") : response)
      .as(Hash(String, Scheme::Convertible))
    context.response.status_code = (native["status"]? || 200_i64).as(Int64).to_i32
    if headers = native["headers"]?
      headers.as(Hash(String, Scheme::Convertible)).each do |name, value|
        context.response.headers[name] = value.as(String)
      end
    end
    if body_proc
      interp.apply(body_proc, [SchemePort.new(context.response, false, true)] of SchemeValue)
    else
      context.response.print(native["body"]?.as?(String) || "")
    end
  rescue ex : Exception
    begin
      context.response.status_code = 500
      context.response.content_type = "text/plain"
      context.response.print("#{who}: #{ex.message}")
    rescue
      # The streaming body proc raised after already writing some bytes —
      # status/headers are already committed, so there's nothing more we
      # can cleanly do here; swallow rather than crash the request fiber.
    end
  end

  private def alist_lookup(alist : SchemeValue, key : String) : SchemeValue?
    Scheme.list_to_a(alist).each do |pair|
      return pair.as(Cons).cdr if pair.is_a?(Cons) && (k = pair.car).is_a?(SchemeStr) && k.value == key
    end
    nil
  end

  private def alist_without(alist : SchemeValue, key : String) : SchemeValue
    pairs = Scheme.list_to_a(alist).reject do |pair|
      pair.is_a?(Cons) && (k = pair.car).is_a?(SchemeStr) && k.value == key
    end
    Scheme.a_to_list(pairs)
  end

  private def callable?(v : SchemeValue) : Bool
    v.is_a?(Builtin) || v.is_a?(BytecodeClosure) || v.is_a?(BytecodeCaseClosure)
  end

  private def mux_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def mux_int_arg(v : SchemeValue, who : String) : Int32
    raise SchemeRuntimeError.new("#{who}: expected integer, got #{v.write_string}") unless v.is_a?(SchemeInt)
    v.value.to_i32
  end

  private def mux_router_arg(v : SchemeValue, who : String) : Scheme::MuxApp
    raise SchemeRuntimeError.new("#{who}: expected mux-router, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "mux-router"
    v.get(Scheme::MuxApp)
  end

  private def mux_server_arg(v : SchemeValue, who : String) : {HTTP::Server, Socket::IPAddress}
    raise SchemeRuntimeError.new("#{who}: expected mux-server, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "mux-server"
    v.get(Tuple(HTTP::Server, Socket::IPAddress))
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "mux"], Scheme::Builtins::MuxLibrary
  end
end
