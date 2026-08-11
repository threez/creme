require "../../spec_helper"

private def run(src : String) : Creme::SchemeValue
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, src)
end

private def w(src : String) : String
  run(src).write_string
end

describe "define-syntax/syntax-rules" do
  it "expands a basic macro with no literals or ellipsis" do
    src = <<-SCHEME
      (define-syntax my-if
        (syntax-rules ()
          ((_ c t e) (cond (c t) (else e)))))
      (list (my-if #t 1 2) (my-if #f 1 2))
      SCHEME
    w(src).should eq("(1 2)")
  end

  it "supports ellipsis in both pattern and template" do
    src = <<-SCHEME
      (define-syntax my-list
        (syntax-rules ()
          ((_ x ...) (list x ...))))
      (my-list 1 2 3)
      SCHEME
    w(src).should eq("(1 2 3)")
  end

  it "supports an empty ellipsis match" do
    src = <<-SCHEME
      (define-syntax my-list
        (syntax-rules ()
          ((_ x ...) (list x ...))))
      (my-list)
      SCHEME
    w(src).should eq("()")
  end

  it "matches a literal keyword and rejects a non-matching one" do
    src = <<-SCHEME
      (define-syntax my-cond
        (syntax-rules (else)
          ((_ (else e ...)) (begin e ...))
          ((_ (c e ...) rest ...) (if c (begin e ...) (my-cond rest ...)))))
      (my-cond (#f 1) (#t 2) (else 3))
      SCHEME
    w(src).should eq("2")
  end

  it "dispatches to different templates via multiple pattern clauses (recursive expansion)" do
    src = <<-SCHEME
      (define-syntax my-let*
        (syntax-rules ()
          ((_ () body ...) (begin body ...))
          ((_ ((var val) rest ...) body ...)
           (let ((var val)) (my-let* (rest ...) body ...)))))
      (my-let* ((a 1) (b (+ a 1))) (* a b))
      SCHEME
    w(src).should eq("2")
  end

  it "supports fixed args mixed with a trailing ellipsis" do
    src = <<-SCHEME
      (define-syntax my-begin
        (syntax-rules ()
          ((_ first rest ...) (begin first rest ...))))
      (my-begin 1 2 3)
      SCHEME
    w(src).should eq("3")
  end

  it "works as a local macro definition scoped to a let" do
    src = <<-SCHEME
      (define (f)
        (define-syntax double (syntax-rules () ((_ x) (* 2 x))))
        (double 21))
      (f)
      SCHEME
    w(src).should eq("42")
  end

  it "is hygienic: a template-introduced identifier cannot capture a use-site binding of the same name" do
    src = <<-SCHEME
      (define-syntax swap!
        (syntax-rules ()
          ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
      (define tmp 1)
      (define y 2)
      (swap! tmp y)
      (list tmp y)
      SCHEME
    # The template's own `tmp` binding is alpha-renamed (see syntax_rules.cr's
    # apply_hygiene) to a fresh name distinct from the use-site `tmp` passed
    # as the `a` argument, so the swap correctly threads the original values
    # through: (2 1), not the pre-hygiene capture bug's (1 2).
    w(src).should eq("(2 1)")
  end

  it "is hygienic: a macro's own use of a special form/global can't be hijacked by a use-site local of the same name" do
    w(<<-SCHEME).should eq("yes")
      (define-syntax my-if (syntax-rules () ((_ c t e) (if c t e))))
      (let ((if (lambda (a b c) 'shadowed))) (my-if #t 'yes 'no))
      SCHEME
    w(<<-SCHEME).should eq("(1 2)")
      (define-syntax my-list (syntax-rules () ((_ a b) (list a b))))
      (let ((list (lambda (a b) 'shadowed))) (my-list 1 2))
      SCHEME
  end

  it "raises when no rule matches" do
    expect_raises(Creme::SchemeRuntimeError, /no matching syntax-rules clause/) do
      run("(define-syntax only-one (syntax-rules () ((_ a b) (+ a b)))) (only-one 1)")
    end
  end

  it "raises on malformed input" do
    expect_raises(Creme::SchemeRuntimeError, /define-syntax: malformed/) do
      run("(define-syntax bad)")
    end
  end

  it "raises when the syntax-rules keyword is missing" do
    expect_raises(Creme::SchemeRuntimeError, /define-syntax: expected syntax-rules/) do
      run("(define-syntax bad (not-syntax-rules () ((_ a) a)))")
    end
  end
end
