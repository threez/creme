require "../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new(library_search_path: ["./modules"])
  Scheme.run_source(interp, "(import (creme ffi) (creme foreign)) #{src}").write_string
end

# Sonames are platform-specific -- see spec/main_spec.cr's own copy of
# this same table for why (FreeBSD, this project's own dev environment,
# vs. glibc/Linux).
private LIBC_SONAME = {% if flag?(:freebsd) %}
                        "libc.so.7"
                      {% elsif flag?(:linux) %}
                        "libc.so.6"
                      {% else %}
                        "libSystem.dylib"
                      {% end %}

describe "foreign module" do
  it "define-foreign-function wraps ffi-function/ffi-call into an ordinary callable procedure" do
    w(<<-SCHEME).should eq("10")
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-function c-strlen libc "strlen" int64 (string))
      (c-strlen "hello, wor")
      SCHEME
  end

  it "define-foreign-function raises ffi-call's own arity error on a mismatched call" do
    w(<<-SCHEME).should eq(%("ffi-call: expected 1 argument(s), got 2"))
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-function c-strlen libc "strlen" int64 (string))
      (guard (e (#t (error-object-message e)))
        (c-strlen "a" "b"))
      SCHEME
  end

  it "define-foreign-struct reads/writes real struct fields at explicit byte offsets" do
    w(<<-SCHEME).should eq("(1000000000 1)")
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-function malloc libc "malloc" pointer (int64))
      (define-foreign-function free libc "free" void (pointer))
      (define-foreign-struct timeval
        (timeval-tv-sec  timeval-tv-sec-set!  int64 0)
        (timeval-tv-usec timeval-tv-usec-set! int64 8))
      (define tv (malloc 16))
      (timeval-tv-sec-set! tv 1000000000)
      (timeval-tv-usec-set! tv 1)
      (define result (list (timeval-tv-sec tv) (timeval-tv-usec tv)))
      (free tv)
      result
      SCHEME
  end

  it "define-foreign-struct works identically over an ffi-gc-malloc'd buffer, with no matching free needed" do
    w(<<-SCHEME).should eq("(0 0 1000000000 1)")
      (define-foreign-struct timeval
        (timeval-tv-sec  timeval-tv-sec-set!  int64 0)
        (timeval-tv-usec timeval-tv-usec-set! int64 8))
      (define tv (ffi-gc-malloc 16))
      (define before (list (timeval-tv-sec tv) (timeval-tv-usec tv)))
      (timeval-tv-sec-set! tv 1000000000)
      (timeval-tv-usec-set! tv 1)
      (define after (list (timeval-tv-sec tv) (timeval-tv-usec tv)))
      (ffi-gc-free tv)
      (append before after)
      SCHEME
  end

  it "define-foreign-record gives a genuine distinct predicate, not just ffi-pointer?" do
    w(<<-SCHEME).should eq("(#t #f)")
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-record <file>
        (open-file libc "fopen" pointer (string string))
        file?
        (file-close! libc "fclose" int32 (pointer)))
      (define f (open-file "/dev/null" "r"))
      (define result (list (file? f) (file? (ffi-open "#{LIBC_SONAME}"))))
      (file-close! f)
      result
      SCHEME
  end

  it "define-foreign-record's constructor propagates a NULL native return as plain #f" do
    w(<<-SCHEME).should eq("#f")
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-record <file>
        (open-file libc "fopen" pointer (string string))
        file?
        (file-close! libc "fclose" int32 (pointer)))
      (open-file "/no/such/path/at/all" "r")
      SCHEME
  end

  it "define-foreign-record's accessors thread the wrapped pointer in as the first ffi-call argument" do
    w(<<-SCHEME).should eq("0")
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-record <file>
        (open-file libc "fopen" pointer (string string))
        file?
        (file-tell libc "ftell" int64 (pointer))
        (file-close! libc "fclose" int32 (pointer)))
      (define f (open-file "/dev/null" "r"))
      (define result (file-tell f))
      (file-close! f)
      result
      SCHEME
  end

  it "two define-foreign-record types in the same file don't corrupt each other's internal helpers" do
    w(<<-SCHEME).should eq("(#t #f #f #t)")
      (define libc (ffi-open "#{LIBC_SONAME}"))
      (define-foreign-record <file>
        (open-file libc "fopen" pointer (string string))
        file?
        (file-close! libc "fclose" int32 (pointer)))
      (define-foreign-record <other-file>
        (open-other-file libc "fopen" pointer (string string))
        other-file?
        (other-file-close! libc "fclose" int32 (pointer)))
      (define f (open-file "/dev/null" "r"))
      (define g (open-other-file "/dev/null" "r"))
      (define result (list (file? f) (file? g) (other-file? f) (other-file? g)))
      (file-close! f)
      (other-file-close! g)
      result
      SCHEME
  end
end
