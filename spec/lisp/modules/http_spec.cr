require "../../spec_helper"
require "http/server"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'http) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'http) #{src}")
end

private TEST_SERVER = HTTP::Server.new do |context|
  request = context.request
  case {request.method, request.path}
  when {"GET", "/hello"}
    context.response.headers["Content-Type"] = "text/plain"
    context.response.print "hello"
  when {"POST", "/echo"}
    context.response.status_code = 201
    context.response.print(request.body.try(&.gets_to_end) || "")
  when {"PUT", "/put"}
    context.response.print(request.body.try(&.gets_to_end) || "")
  when {"PATCH", "/patch"}
    context.response.print(request.body.try(&.gets_to_end) || "")
  when {"DELETE", "/delete"}
    context.response.status_code = 204
  when {"HEAD", "/head"}
    context.response.status_code = 200
  when {"GET", "/headers"}
    context.response.headers["X-Custom"] = request.headers["X-Custom"]? || ""
  else
    context.response.status_code = 404
  end
end

private TEST_PORT = TEST_SERVER.bind_unused_port("127.0.0.1").port

spawn { TEST_SERVER.listen }
sleep 50.milliseconds

private def base_url : String
  "http://127.0.0.1:#{TEST_PORT}"
end

describe "http module" do
  it "performs a GET and returns status/headers/body" do
    result = run(%((http:get "#{base_url}/hello")))
    alist = LISP.list_to_a(result).map { |c| c.as(LISP::Cons) }
    status = alist.find { |c| c.car.as(LISP::LispStr).value == "status" }.not_nil!.cdr
    body = alist.find { |c| c.car.as(LISP::LispStr).value == "body" }.not_nil!.cdr
    status.write_string.should eq("200")
    body.write_string.should eq(%("hello"))
    w(%((cdr (assoc "Content-Type" (cdr (assoc "headers" (http:get "#{base_url}/hello"))))))).should eq(%("text/plain"))
  end

  it "sends custom request headers and reads response headers" do
    w(%((cdr (assoc "X-Custom" (cdr (assoc "headers" (http:get "#{base_url}/headers" '(("X-Custom" . "abc")))))))))
      .should eq(%("abc"))
  end

  it "performs a POST with a body" do
    result = run(%((http:post "#{base_url}/echo" "payload")))
    alist = LISP.list_to_a(result).map { |c| c.as(LISP::Cons) }
    status = alist.find { |c| c.car.as(LISP::LispStr).value == "status" }.not_nil!.cdr
    body = alist.find { |c| c.car.as(LISP::LispStr).value == "body" }.not_nil!.cdr
    status.write_string.should eq("201")
    body.write_string.should eq(%("payload"))
  end

  it "performs PUT and PATCH with bodies" do
    w(%((cdr (assoc "body" (http:put "#{base_url}/put" "put-body"))))).should eq(%("put-body"))
    w(%((cdr (assoc "body" (http:patch "#{base_url}/patch" "patch-body"))))).should eq(%("patch-body"))
  end

  it "performs DELETE and HEAD" do
    w(%((cdr (assoc "status" (http:delete "#{base_url}/delete"))))).should eq("204")
    w(%((cdr (assoc "status" (http:head "#{base_url}/head"))))).should eq("200")
  end

  it "supports the generic request builtin" do
    w(%((cdr (assoc "status" (http:request "POST" "#{base_url}/echo" '() "generic"))))).should eq("201")
  end

  it "raises on connection failure" do
    expect_raises(LISP::LispRuntimeError, /http:get:/) do
      run(%((http:get "http://127.0.0.1:1")))
    end
  end

  it "raises on a malformed url" do
    expect_raises(LISP::LispRuntimeError, /http:get: invalid url/) do
      run(%((http:get "not a url")))
    end
  end
end
