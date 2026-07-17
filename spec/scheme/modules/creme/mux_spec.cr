require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme mux) (creme http)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme mux) (creme http)) #{src}")
end

describe "mux module" do
  it "routes GET/POST requests, path params, and headers through Scheme handlers" do
    result = run(<<-SCM)
      (define router (mux-router))

      (mux-get! router "/hello/:id"
        (lambda (request)
          (list (cons "status" 200)
                (cons "headers" (list (cons "content-type" "text/plain")))
                (cons "body" (string-append "hello " (cdr (assoc "id" (cdr (assoc "path-params" request))))))))
      )

      (mux-post! router "/echo"
        (lambda (request)
          (list (cons "status" 201)
                (cons "body" (cdr (assoc "body" request))))))

      (define server (mux-listen! router 0))
      (define base-url (mux-base-url server))
      (define get-result (http-get (string-append base-url "/hello/42")))
      (define post-result (http-post (string-append base-url "/echo") "payload"))
      (mux-close! server)
      (list get-result post-result)
    SCM

    pair = Scheme.list_to_a(result)
    get_alist = Scheme.list_to_a(pair[0]).map { |cons| cons.as(Scheme::Cons) }
    post_alist = Scheme.list_to_a(pair[1]).map { |cons| cons.as(Scheme::Cons) }

    get_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("200")
    get_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("hello 42"))
    headers = Scheme.list_to_a(get_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "headers" }.cdr)
      .map { |cons| cons.as(Scheme::Cons) }
    headers.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "content-type" }.cdr.write_string.should eq(%("text/plain"))

    post_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("201")
    post_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("payload"))
  end

  it "returns 404 for unmatched routes and 500 with the error message for a handler that raises" do
    w(<<-SCM).should eq("404")
      (define router (mux-router))
      (define server (mux-listen! router 0))
      (define base-url (mux-base-url server))
      (define result (cdr (assoc "status" (http-get (string-append base-url "/nope")))))
      (mux-close! server)
      result
    SCM

    result = run(<<-SCM)
      (define router (mux-router))
      (mux-get! router "/boom" (lambda (request) (car '())))
      (define server (mux-listen! router 0))
      (define base-url (mux-base-url server))
      (define response (http-get (string-append base-url "/boom")))
      (mux-close! server)
      response
    SCM
    alist = Scheme.list_to_a(result).map { |cons| cons.as(Scheme::Cons) }
    alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("500")
  end

  it "reports the bound host/port via mux-address" do
    w(<<-SCM).should eq("#t")
      (define router (mux-router))
      (define server (mux-listen! router 0))
      (define addr (mux-address server))
      (define port (cdr (assoc "port" addr)))
      (mux-close! server)
      (and (string? (cdr (assoc "host" addr))) (integer? port) (> port 0))
    SCM
  end

  it "recognizes mux-router?" do
    w(%((mux-router? (mux-router)))).should eq("#t")
    w(%((mux-router? 5))).should eq("#f")
  end

  it "streams a body written directly into the response port when body is a procedure" do
    interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
    result = Scheme.run_source(interp, <<-SCM)
      (import (creme mux) (creme http) (creme html))

      (define router (mux-router))

      (mux-get! router "/stream"
        (lambda (request)
          (list (cons "status" 200)
                (cons "headers" (list (cons "content-type" "text/html")))
                (cons "body" (lambda (port)
                               (write-string "<p>a</p>" port)
                               (html-write! port `(p ,(string-append "b" "!")))
                               (write-string "<p>c</p>" port))))))

      (mux-get! router "/plain"
        (lambda (request)
          (list (cons "status" 200) (cons "body" "plain string body"))))

      (define server (mux-listen! router 0))
      (define base-url (mux-base-url server))
      (define stream-result (http-get (string-append base-url "/stream")))
      (define plain-result (http-get (string-append base-url "/plain")))
      (mux-close! server)
      (list stream-result plain-result)
      SCM

    pair = Scheme.list_to_a(result)
    stream_alist = Scheme.list_to_a(pair[0]).map { |cons| cons.as(Scheme::Cons) }
    plain_alist = Scheme.list_to_a(pair[1]).map { |cons| cons.as(Scheme::Cons) }

    stream_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("200")
    stream_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("<p>a</p><p>b!</p><p>c</p>"))

    plain_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("200")
    plain_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("plain string body"))
  end

  describe "mux-use!" do
    it "runs a middleware around a real request, letting it read the status from next" do
      w(<<-SCM).should eq(%("GET /hi -> 200"))
        (define router (mux-router))
        (define log "")
        (mux-use! router
          (lambda (request next)
            (define status (next))
            (set! log (string-append (cdr (assoc "method" request)) " " (cdr (assoc "path" request)) " -> " (number->string status)))
            status))
        (mux-get! router "/hi" (lambda (request) (list (cons "status" 200) (cons "body" "hi"))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (http-get (string-append base-url "/hi"))
        (mux-close! server)
        log
        SCM
    end

    it "a middleware that never calls next short-circuits the request" do
      w(<<-SCM).should eq("403")
        (define router (mux-router))
        (define ran #f)
        (mux-use! router (lambda (request next) (list (cons "status" 403) (cons "body" "nope"))))
        (mux-get! router "/hi" (lambda (request) (set! ran #t) (list (cons "status" 200) (cons "body" "hi"))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define status (cdr (assoc "status" (http-get (string-append base-url "/hi")))))
        (mux-close! server)
        status
        SCM

      run(<<-SCM).write_string.should eq("#f")
        (define router (mux-router))
        (mux-use! router (lambda (request next) (list (cons "status" 403) (cons "body" "nope"))))
        (define ran #f)
        (mux-get! router "/hi" (lambda (request) (set! ran #t) (list (cons "status" 200) (cons "body" "hi"))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (http-get (string-append base-url "/hi"))
        (mux-close! server)
        ran
        SCM
    end

    it "runs multiple middlewares in registration order (outermost first-in, last-out)" do
      w(<<-SCM).should eq(%("a-in b-in b-out a-out"))
        (define router (mux-router))
        (define trace "")
        (define (append! s) (set! trace (if (= (string-length trace) 0) s (string-append trace " " s))))
        (mux-use! router (lambda (request next) (append! "a-in") (define r (next)) (append! "a-out") r))
        (mux-use! router (lambda (request next) (append! "b-in") (define r (next)) (append! "b-out") r))
        (mux-get! router "/hi" (lambda (request) (list (cons "status" 200) (cons "body" "hi"))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (http-get (string-append base-url "/hi"))
        (mux-close! server)
        trace
        SCM
    end
  end
end
