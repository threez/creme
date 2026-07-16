# ===========================================================================
# http module: HTTP(S) client
#
# Responses are alists mirroring the json/sql convention:
#   ((status . 200) (headers . (("content-type" . "application/json") ...)) (body . "..."))
# Request headers are alists of (string . string) pairs. Bodies are plain
# strings — compose with json-write/json-read for JSON APIs.
# ===========================================================================

require "http/client"

module Scheme::Builtins::HttpLibrary
  extend self
  include Scheme::BuiltinHelpers

  @[Scheme::SchemeFn("http-get", min: 1, max: 2)]
  def http_get(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    http_do("GET", args[0], args[1]?, nil, "http-get")
  end

  @[Scheme::SchemeFn("http-head", min: 1, max: 2)]
  def http_head(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    http_do("HEAD", args[0], args[1]?, nil, "http-head")
  end

  @[Scheme::SchemeFn("http-delete", min: 1, max: 2)]
  def http_delete(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    http_do("DELETE", args[0], args[1]?, nil, "http-delete")
  end

  @[Scheme::SchemeFn("http-post", min: 2, max: 3)]
  def http_post(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    http_do("POST", args[0], args[2]?, args[1], "http-post")
  end

  @[Scheme::SchemeFn("http-put", min: 2, max: 3)]
  def http_put(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    http_do("PUT", args[0], args[2]?, args[1], "http-put")
  end

  @[Scheme::SchemeFn("http-patch", min: 2, max: 3)]
  def http_patch(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    http_do("PATCH", args[0], args[2]?, args[1], "http-patch")
  end

  @[Scheme::SchemeFn("http-request", min: 2, max: 4)]
  def http_request(interp : Interpreter, env : Env, args : Array(SchemeValue)) : SchemeValue
    method = http_str_arg(args[0], "http-request")
    http_do(method, args[1], args[2]?, args[3]?, "http-request")
  end

  private def http_do(method : String, url_v : SchemeValue, headers_v : SchemeValue?, body_v : SchemeValue?, who : String) : SchemeValue
    url = http_str_arg(url_v, who)
    headers = headers_v ? http_headers_arg(headers_v, who) : HTTP::Headers.new
    body = body_v ? http_str_arg(body_v, who) : nil

    uri = begin
      URI.parse(url)
    rescue ex : Exception
      raise SchemeRuntimeError.new("#{who}: invalid url '#{url}': #{ex.message}")
    end
    raise SchemeRuntimeError.new("#{who}: invalid url '#{url}': missing host") unless uri.host

    client = HTTP::Client.new(uri)
    client.connect_timeout = 30.seconds
    client.read_timeout = 30.seconds
    begin
      response = client.exec(method, uri.request_target, headers: headers, body: body)
      http_response_to_scheme(response)
    rescue ex : Exception
      raise SchemeRuntimeError.new("#{who}: #{ex.message}")
    ensure
      client.close
    end
  end

  private def http_response_to_scheme(response : HTTP::Client::Response) : SchemeValue
    header_pairs = [] of SchemeValue
    response.headers.each do |name, values|
      header_pairs << Cons.new(SchemeStr.new(name), SchemeStr.new(values.join(", ")))
    end
    Scheme.a_to_list([
      Cons.new(SchemeStr.new("status"), SchemeInt.new(response.status_code.to_i64)).as(SchemeValue),
      Cons.new(SchemeStr.new("headers"), Scheme.a_to_list(header_pairs)).as(SchemeValue),
      Cons.new(SchemeStr.new("body"), SchemeStr.new(response.body)).as(SchemeValue),
    ])
  end

  private def http_str_arg(v : SchemeValue, who : String) : String
    raise SchemeRuntimeError.new("#{who}: expected string, got #{v.write_string}") unless v.is_a?(SchemeStr)
    v.value
  end

  private def http_headers_arg(v : SchemeValue, who : String) : HTTP::Headers
    raise SchemeRuntimeError.new("#{who}: expected headers alist, got #{v.write_string}") unless Scheme.proper_list?(v)
    headers = HTTP::Headers.new
    Scheme.list_to_a(v).each do |entry|
      raise SchemeRuntimeError.new("#{who}: expected (name . value) pair in headers, got #{entry.write_string}") unless entry.is_a?(Cons)
      name = http_str_arg(entry.car, who)
      value = http_str_arg(entry.cdr, who)
      headers.add(name, value)
    end
    headers
  end
end

module Scheme
  class Interpreter
    register_library ["creme", "http"], Scheme::Builtins::HttpLibrary
  end
end
