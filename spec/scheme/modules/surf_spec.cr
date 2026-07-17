require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme surf) (creme mux) (creme html) (creme http)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme surf) (creme mux) (creme html) (creme http)) #{src}")
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
end
