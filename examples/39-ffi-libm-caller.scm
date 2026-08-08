;; (creme ffi) + (creme foreign): calling straight into libm/libc by name,
;; no native module written for either library -- unlike every other
;; examples/*.scm that wraps a C library (regex/sql/csv/digest/...), this
;; one IS the generic escape hatch: (creme ffi) dlopen's a shared library
;; and lets Scheme call any exported function by name + a hand-declared
;; signature, and (creme foreign)'s define-foreign-function turns that
;; into an ordinary-looking procedure definition -- (sqrt 2.0) instead of
;; (ffi-call (ffi-function lib "sqrt" 'double '(double)) (list 2.0)).
;; Same underlying eight primitives, same MVP type-marshalling scope, on
;; both backends this project ships: native `bin/creme`
;; (modules/creme/ffi.sld -> src/creme/modules/creme/ffi.cr) and
;; `icecreme/icecreme` (icecreme/creme_ffi.c) -- see either file's own header comment for
;; the full non-goals list (no whole-struct-by-value marshalling, no
;; Scheme-closure-as-C-callback), and modules/creme/foreign.sld's own
;; header comment for exactly what define-foreign-function expands to.
;;
;; SECURITY: (creme ffi)/(creme foreign) hand a script genuine native code
;; execution. An embedder sandboxing untrusted guest scripts MUST exclude
;; both from any allowed_libraries allowlist, exactly like (creme tui)/
;; (creme rfc8439)/(creme raft) already are -- see README.md's
;; "Sandboxing untrusted rule/template content" section.
(import (scheme base) (scheme write) (creme ffi) (creme foreign) (creme introspection))

(define (report label value)
  (display label) (display ": ") (display value) (newline))

;; Sonames are platform-specific -- glibc (most Linux) uses libX.so.6,
;; FreeBSD (this project's own dev environment) uses BSD-style
;; single-digit versioning instead, and macOS has no separate libm at
;; all (both live in libSystem.dylib). (runtime)'s `os` field is uname
;; -s, so this picks the right one instead of hardcoding one platform --
;; see spec/main_spec.cr's own copy of this same table for the ffi
;; backend test this example's demo is modeled on.
(define os (cdr (assq 'os (runtime))))
(define libm-soname
  (cond ((string=? os "FreeBSD") "libm.so.5")
        ((string=? os "Darwin") "libSystem.dylib")
        (else "libm.so.6")))
(define libc-soname
  (cond ((string=? os "FreeBSD") "libc.so.7")
        ((string=? os "Darwin") "libSystem.dylib")
        (else "libc.so.6")))

;; --- libm: 'double in, 'double out -----------------------------------
(define libm (ffi-open libm-soname))
(define-foreign-function sqrt libm "sqrt" double (double))
(define-foreign-function pow libm "pow" double (double double))
(define-foreign-function floor libm "floor" double (double))

(report "(sqrt 2.0) via libm" (sqrt 2.0))
(report "(pow 2.0 10.0) via libm" (pow 2.0 10.0))
(report "(floor 3.7) via libm" (floor 3.7))
(ffi-close libm)
(newline)

;; --- libc: 'string in, 'int64/'int32 out ------------------------------
(define libc (ffi-open libc-soname))
(define-foreign-function c-strlen libc "strlen" int64 (string))
(define-foreign-function c-atoi libc "atoi" int32 (string))
(define-foreign-function c-getpid libc "getpid" int32 ())

(report "(strlen \"hello, ffi\") via libc" (c-strlen "hello, ffi"))
(report "(atoi \"42\") via libc" (c-atoi "42"))
(display "(getpid) via libc: a pid > 0? ") (display (> (c-getpid) 0)) (newline)
(newline)

;; --- pointers: an opaque handle round-tripped through the FFI boundary,
;; never touched Scheme-side except to check it's non-NULL/pass it back.
;; malloc/free is the smallest pair that demonstrates this without
;; needing any real struct layout.
(define-foreign-function c-malloc libc "malloc" pointer (int64))
(define-foreign-function c-free libc "free" void (pointer))

(define block (c-malloc 64))
(report "malloc(64) returned a non-null pointer?" (not (ffi-null-pointer? block)))
(c-free block)
(ffi-close libc)
