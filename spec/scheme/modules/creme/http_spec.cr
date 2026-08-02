require "../../../spec_helper"
require "http/server"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme http)) #{src}").write_string
end

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (creme http)) #{src}")
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
    result = run(%((http-get "#{base_url}/hello")))
    alist = Creme.list_to_a(result).map { |cons| cons.as(Creme::Cons) }
    status = alist.find! { |cons| cons.car.as(Creme::SchemeStr).value == "status" }.cdr
    body = alist.find! { |cons| cons.car.as(Creme::SchemeStr).value == "body" }.cdr
    status.write_string.should eq("200")
    body.write_string.should eq(%("hello"))
    w(%((cdr (assoc "Content-Type" (cdr (assoc "headers" (http-get "#{base_url}/hello"))))))).should eq(%("text/plain"))
  end

  it "sends custom request headers and reads response headers" do
    w(%((cdr (assoc "X-Custom" (cdr (assoc "headers" (http-get "#{base_url}/headers" '(("X-Custom" . "abc")))))))))
      .should eq(%("abc"))
  end

  it "performs a POST with a body" do
    result = run(%((http-post "#{base_url}/echo" "payload")))
    alist = Creme.list_to_a(result).map { |cons| cons.as(Creme::Cons) }
    status = alist.find! { |cons| cons.car.as(Creme::SchemeStr).value == "status" }.cdr
    body = alist.find! { |cons| cons.car.as(Creme::SchemeStr).value == "body" }.cdr
    status.write_string.should eq("201")
    body.write_string.should eq(%("payload"))
  end

  it "performs PUT and PATCH with bodies" do
    w(%((cdr (assoc "body" (http-put "#{base_url}/put" "put-body"))))).should eq(%("put-body"))
    w(%((cdr (assoc "body" (http-patch "#{base_url}/patch" "patch-body"))))).should eq(%("patch-body"))
  end

  it "performs DELETE and HEAD" do
    w(%((cdr (assoc "status" (http-delete "#{base_url}/delete"))))).should eq("204")
    w(%((cdr (assoc "status" (http-head "#{base_url}/head"))))).should eq("200")
  end

  it "supports the generic request builtin" do
    w(%((cdr (assoc "status" (http-request "POST" "#{base_url}/echo" '() "generic"))))).should eq("201")
  end

  it "raises on connection failure" do
    expect_raises(Creme::SchemeRuntimeError, /http-get:/) do
      run(%((http-get "http://127.0.0.1:1")))
    end
  end

  it "raises on a malformed url" do
    expect_raises(Creme::SchemeRuntimeError, /http-get: invalid url/) do
      run(%((http-get "not a url")))
    end
  end
end
