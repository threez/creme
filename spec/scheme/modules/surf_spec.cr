require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme surf) (creme mux) (creme html) (creme json-builder) (creme http)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme surf) (creme mux) (creme html) (creme json-builder) (creme http)) #{src}")
end

describe "surf module" do
  describe "surf-normalize-response" do
    it "wraps a bare string as a 200 text/html response" do
      w(%((cdr (assoc "status" (surf-normalize-response "hi"))))).should eq("200")
      w(%((cdr (assoc "body" (surf-normalize-response "hi"))))).should eq(%("hi"))
      w(%((cdr (assoc "content-type" (cdr (assoc "headers" (surf-normalize-response "hi")))))))
        .should eq(%("text/html"))
    end

    it "passes a hand-built response alist through unchanged" do
      w(%((cdr (assoc "status" (surf-normalize-response (list (cons "status" 201) (cons "body" "ok")))))))
        .should eq("201")
    end

    it "raises on an unsupported handler return value" do
      expect_raises(Scheme::SchemeRuntimeError, /unsupported value/) do
        run(%((surf-normalize-response 42)))
      end
    end
  end

  describe "response builders" do
    it "surf-text defaults to 200 text/plain" do
      w(%((cdr (assoc "status" (surf-text "hi"))))).should eq("200")
      w(%((cdr (assoc "content-type" (cdr (assoc "headers" (surf-text "hi"))))))).should eq(%("text/plain"))
      w(%((cdr (assoc "body" (surf-text "hi"))))).should eq(%("hi"))
    end

    it "surf-text accepts an explicit status" do
      w(%((cdr (assoc "status" (surf-text "nope" 404))))).should eq("404")
    end

    it "surf-html passes a string body through unchanged" do
      w(%((cdr (assoc "body" (surf-html "<p>hi</p>"))))).should eq(%("<p>hi</p>"))
    end

    it "surf-html renders a live node" do
      w(%((cdr (assoc "body" (surf-html '(p "hi")))))).should eq(%("<p>hi</p>"))
    end

    it "surf-html passes a streaming procedure body through unchanged" do
      w(%((procedure? (cdr (assoc "body" (surf-html (lambda (port) (write-string "hi" port))))))))
        .should eq("#t")
    end

    it "surf-redirect defaults to 303 with a Location header and empty body" do
      w(%((cdr (assoc "status" (surf-redirect "/somewhere"))))).should eq("303")
      w(%((cdr (assoc "Location" (cdr (assoc "headers" (surf-redirect "/somewhere"))))))).should eq(%("/somewhere"))
      w(%((cdr (assoc "body" (surf-redirect "/somewhere"))))).should eq(%(""))
    end

    it "surf-redirect accepts an explicit status" do
      w(%((cdr (assoc "status" (surf-redirect "/somewhere" 307))))).should eq("307")
    end
  end

  describe "request helpers" do
    it "surf-url-decode handles + and %XX escapes" do
      w(%((surf-url-decode "a+b%2Fc"))).should eq(%("a b/c"))
    end

    it "surf-form parses every field out of an urlencoded body" do
      w(<<-SCM).should eq(%("a b"))
        (cdr (assoc "title" (surf-form (list (cons "body" "title=a+b&done=1")))))
        SCM
      w(<<-SCM).should eq(%("1"))
        (cdr (assoc "done" (surf-form (list (cons "body" "title=a+b&done=1")))))
        SCM
    end

    it "surf-form returns an empty alist for an empty body" do
      w(%((null? (surf-form (list (cons "body" "")))))).should eq("#t")
    end

    it "surf-param prefers path-params over form fields, falls back to form, then #f" do
      w(<<-SCM).should eq(%("42"))
        (surf-param (list (cons "path-params" (list (cons "id" "42")))
                           (cons "body" "id=99"))
                    "id")
        SCM
      w(<<-SCM).should eq(%("a"))
        (surf-param (list (cons "path-params" '()) (cons "body" "title=a")) "title")
        SCM
      w(<<-SCM).should eq("#f")
        (surf-param (list (cons "path-params" '()) (cons "body" "")) "missing")
        SCM
    end

    it "surf-header/surf-path-param return #f when the key is absent" do
      w(%((surf-header (list (cons "headers" '())) "content-type"))).should eq("#f")
      w(%((surf-path-param (list (cons "path-params" '())) "id"))).should eq("#f")
    end
  end

  describe "declarative routing" do
    it "registers routes via surf and round-trips a real HTTP request" do
      result = run(<<-SCM)
        (define router
          (surf
           (get "/hello/:id" (request)
             (string-append "hello " (surf-path-param request "id")))
           (post "/echo" (request)
             (surf-text (cdr (assoc "title" (surf-form request)))))))

        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define get-result (http-get (string-append base-url "/hello/42")))
        (define post-result (http-post (string-append base-url "/echo") "title=hi+there"))
        (mux-close! server)
        (list get-result post-result)
        SCM

      pair = Scheme.list_to_a(result)
      get_alist = Scheme.list_to_a(pair[0]).map { |cons| cons.as(Scheme::Cons) }
      post_alist = Scheme.list_to_a(pair[1]).map { |cons| cons.as(Scheme::Cons) }

      get_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("200")
      get_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("hello 42"))

      post_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "status" }.cdr.write_string.should eq("200")
      post_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("hi there"))
    end

    it "auto-binds extra clause names to their surf-param value" do
      result = run(<<-SCM)
        (define router
          (surf
           (get "/todos/:id/complete" (request id)
             (surf-text (string-append "id=" id)))
           (post "/echo2" (request title)
             (surf-text (string-append "title=" title)))
           (get "/missing" (request nope)
             (surf-text (if nope "present" "absent")))))

        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define path-param-result (http-get (string-append base-url "/todos/42/complete")))
        (define form-field-result (http-post (string-append base-url "/echo2") "title=hi+there"))
        (define missing-result (http-get (string-append base-url "/missing")))
        (mux-close! server)
        (list path-param-result form-field-result missing-result)
        SCM

      triple = Scheme.list_to_a(result)
      path_param_alist = Scheme.list_to_a(triple[0]).map { |cons| cons.as(Scheme::Cons) }
      form_field_alist = Scheme.list_to_a(triple[1]).map { |cons| cons.as(Scheme::Cons) }
      missing_alist = Scheme.list_to_a(triple[2]).map { |cons| cons.as(Scheme::Cons) }

      path_param_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("id=42"))
      form_field_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("title=hi there"))
      missing_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("absent"))
    end

    it "surf-route! adds a route to an already-existing app one at a time" do
      w(<<-SCM).should eq(%("added"))
        (define router (surf-app))
        (surf-route! router (get "/only" (request) "added"))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define result (cdr (assoc "body" (http-get (string-append base-url "/only")))))
        (mux-close! server)
        result
        SCM
    end
  end

  describe "surf-json" do
    it "surf-json defaults to 200 application/json" do
      w(%((cdr (assoc "status" (surf-json "{}"))))).should eq("200")
      w(%((cdr (assoc "content-type" (cdr (assoc "headers" (surf-json "{}"))))))).should eq(%("application/json"))
      w(%((cdr (assoc "body" (surf-json "{}"))))).should eq(%("{}"))
    end

    it "surf-json accepts an explicit status" do
      w(%((cdr (assoc "status" (surf-json "{}" 201))))).should eq("201")
    end

    it "surf-json renders a live (creme json-builder) node" do
      w(%((cdr (assoc "body" (surf-json '(object (a 1))))))).should eq("\"{\\\"a\\\":1}\"")
    end

    it "surf-json passes a string body through unchanged" do
      w(%((cdr (assoc "body" (surf-json "[1,2,3]"))))).should eq(%("[1,2,3]"))
    end
  end

  describe "surf-accept" do
    it "picks the matching clause by Accept header substring" do
      result = run(<<-SCM)
        (define router
          (surf
           (get "/" (request)
             (surf-accept request
               ("application/json" (surf-json (list 'object (list 'kind "json"))))
               (else (surf-text "html-ish"))))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define json-result
          (http-get (string-append base-url "/") (list (cons "Accept" "application/json"))))
        (define html-result
          (http-get (string-append base-url "/") (list (cons "Accept" "text/html"))))
        (mux-close! server)
        (list json-result html-result)
        SCM

      pair = Scheme.list_to_a(result)
      json_alist = Scheme.list_to_a(pair[0]).map { |cons| cons.as(Scheme::Cons) }
      html_alist = Scheme.list_to_a(pair[1]).map { |cons| cons.as(Scheme::Cons) }

      json_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq("\"{\\\"kind\\\":\\\"json\\\"}\"")
      html_alist.find! { |cons| cons.car.as(Scheme::SchemeStr).value == "body" }.cdr.write_string.should eq(%("html-ish"))
    end

    it "a missing Accept header and */* both match any clause" do
      result = run(<<-SCM)
        (define router
          (surf
           (get "/" (request)
             (surf-accept request
               ("application/json" "json-branch")
               (else "else-branch")))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define no-header (cdr (assoc "body" (http-get (string-append base-url "/")))))
        (define star (cdr (assoc "body" (http-get (string-append base-url "/") (list (cons "Accept" "*/*"))))))
        (mux-close! server)
        (list no-header star)
        SCM
      pair = Scheme.list_to_a(result)
      pair[0].write_string.should eq(%("json-branch"))
      pair[1].write_string.should eq(%("json-branch"))
    end

    it "falls back to 406 when nothing matches and there is no else" do
      w(<<-SCM).should eq("406")
        (define router
          (surf
           (get "/" (request)
             (surf-accept request
               ("application/json" "json-branch")))))
        (define server (mux-listen! router 0))
        (define base-url (mux-base-url server))
        (define status (cdr (assoc "status" (http-get (string-append base-url "/") (list (cons "Accept" "text/html"))))))
        (mux-close! server)
        status
        SCM
    end
  end

  describe "logging" do
    it "surf-app registers surf-log-middleware, still recognized by mux-router?" do
      w(%((mux-router? (surf-app)))).should eq("#t")
    end

    it "surf-log-middleware logs one line: method, path, status, elapsed ms" do
      # Called directly (not through a live server): request handling for a
      # real mux-listen! server runs on its own connection fiber, and a
      # Scheme parameter's dynamic binding (current-output-port here) is
      # per-fiber, so parameterize around an http-get call wouldn't reach
      # it -- calling the middleware procedure itself, synchronously, with
      # a stub `next`, is both simpler and fiber-safe.
      w(<<-SCM).should match(/\A"1\.2\.3\.4:5678 GET \/hi -> 200 \(\d+ms\)\\n"\z/)
        (parameterize ((current-output-port (open-output-string)))
          (surf-log-middleware (list (cons "method" "GET") (cons "path" "/hi") (cons "remote-addr" "1.2.3.4:5678"))
                                (lambda () 200))
          (get-output-string (current-output-port)))
        SCM
    end
  end
end
