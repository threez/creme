# ===========================================================================
# mux module: HTTP server + path-based routing, built on threez/mux.cr
# (a thin frontend over luislavena/radix) plus stdlib HTTP::Server.
#
# A router is an opaque SchemeBox (tag "mux-router"); route handlers are
# ordinary Scheme procedures of one argument, a request alist:
#   ((method . "GET") (path . "/foo/1") (path-params . (("id" . "1")))
#    (headers . (("content-type" . "text/plain"))) (body . "..."))
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
# `mux-listen!` starts the server on a spawned Fiber (non-blocking) and
# returns an opaque server handle (tag "mux-server") — pass port 0 to
# `mux-listen!` for an OS-assigned ephemeral port, then read the real one
# back via `mux-address` (host/port alist) or `mux-base-url` ("http://host:port",
# ready to concatenate a path onto for a (creme http) client call) — and
# `mux-close!` to shut the server down.
# ===========================================================================

require "mux"

module Scheme::Builtins::MuxLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("mux-router", min: 0, max: 0)]
  def mux_router(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    SchemeBox.new("mux-router", Mux::Router.new, "#<mux-router>")
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

  @[Scheme::SchemeFn("mux-listen!", min: 2, max: 3)]
  def mux_listen(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    router = mux_router_arg(args[0], "mux-listen!")
    host, port = if args.size == 3
                   {mux_str_arg(args[1], "mux-listen!"), mux_int_arg(args[2], "mux-listen!")}
                 else
                   {"127.0.0.1", mux_int_arg(args[1], "mux-listen!")}
                 end
    server = HTTP::Server.new(router)
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
    router = mux_router_arg(args[0], who)
    path = mux_str_arg(args[1], who)
    handler = args[2]
    router.add_handler(path, method: method) do |context|
      response = interp.apply(handler, [request_to_scheme(context)] of SchemeValue)
      write_response(interp, context, response, who)
    end
    NIL.as(SchemeValue)
  end

  private def request_to_scheme(context : HTTP::Server::Context) : SchemeValue
    request = context.request
    header_pairs = [] of SchemeValue
    request.headers.each do |name, values|
      header_pairs << Cons.new(SchemeStr.new(name), SchemeStr.new(values.join(", "))).as(SchemeValue)
    end
    param_pairs = (request.path_params || {} of String => String).map do |name, value|
      Cons.new(SchemeStr.new(name), SchemeStr.new(value)).as(SchemeValue)
    end
    body = request.body.try(&.gets_to_end) || ""
    Scheme.a_to_list([
      Cons.new(SchemeStr.new("method"), SchemeStr.new(request.method)).as(SchemeValue),
      Cons.new(SchemeStr.new("path"), SchemeStr.new(request.path)).as(SchemeValue),
      Cons.new(SchemeStr.new("path-params"), Scheme.a_to_list(param_pairs)).as(SchemeValue),
      Cons.new(SchemeStr.new("headers"), Scheme.a_to_list(header_pairs)).as(SchemeValue),
      Cons.new(SchemeStr.new("body"), SchemeStr.new(body)).as(SchemeValue),
    ])
  end

  private def write_response(interp : Interpreter, context : HTTP::Server::Context, response : SchemeValue, who : String) : Nil
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

  private def mux_router_arg(v : SchemeValue, who : String) : Mux::Router
    raise SchemeRuntimeError.new("#{who}: expected mux-router, got #{v.write_string}") unless v.is_a?(SchemeBox) && v.tag == "mux-router"
    v.get(Mux::Router)
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
