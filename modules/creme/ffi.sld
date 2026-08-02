;; (creme ffi): thin re-export frontend over (creme builtin ffi)
;;
;; ffi-pointer-ref/ffi-pointer-set! read/write an individual struct FIELD
;; given a pointer and that field's byte offset (ffi-type-size reports a
;; type's byte size, for computing offsets); see src/scheme/modules/
;; creme/ffi.cr's own header comment for exactly what is/isn't supported
;; -- there's still no whole-struct-by-value marshalling, and layout
;; (alignment/padding) is never computed for you. (creme foreign)'s
;; define-foreign-struct is declarative sugar over exactly these two.
;;
;; ffi-gc-malloc gives a script scratch memory backed by THIS process's
;; own Boehm GC heap (the same allocator every other Scheme value already
;; lives in) instead of libc's malloc -- reclaimed automatically once
;; unreachable, no matching free ever required. ffi-gc-free is an
;; OPTIONAL early release, valid ONLY on a pointer ffi-gc-malloc itself
;; returned -- never on a libc-malloc'd pointer or one a C function
;; handed back (a FILE*, a sqlite3*, ...), which corrupts the GC's own
;; heap bookkeeping. (creme foreign)'s define-foreign-struct pairs
;; naturally with ffi-gc-malloc for a buffer the script itself owns.
;;
;; SECURITY: this library hands a guest script genuine native code
;; execution (dlopen + an arbitrary native call by name/signature, plus
;; raw offset+type memory access via ffi-pointer-ref/-set!, plus
;; ffi-gc-free's own heap-corruption risk if misused) and every
;; memory-safety risk that comes with it. An embedder MUST exclude
;; "creme ffi" from any allowed_libraries allowlist for untrusted guest
;; scripts, the same way (creme tui)/(creme rfc8439)/(creme raft)/
;; (creme jose) already are.
(define-library (creme ffi)
  (import (creme builtin ffi))
  (export ffi-open ffi-close ffi-function ffi-call
          ffi-pointer-ref ffi-pointer-set! ffi-type-size
          ffi-gc-malloc ffi-gc-free
          ffi-lib? ffi-function? ffi-pointer? ffi-null-pointer?))
