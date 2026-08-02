;; (creme ffi) + (creme foreign): real struct FIELD access, not just an
;; opaque pointer. (creme ffi)'s bridge deliberately does not marshal a
;; whole C struct by value (there's no type symbol for "struct") -- but
;; ffi-pointer-ref/ffi-pointer-set! DO let a script read/write an
;; individual field, given a pointer to the struct and that field's real
;; byte offset in the target C ABI, and (creme foreign)'s
;; define-foreign-struct turns a byte-offset table into ordinary-looking
;; accessor/mutator procedures. See cvm/creme_ffi.c's and
;; src/scheme/modules/creme/ffi.cr's own header comments for the exact
;; scope (still no automatic layout/alignment computation -- offsets must
;; come from the real ABI), and modules/creme/foreign.sld's header
;; comment for define-foreign-struct's own contract.
;;
;; The struct here is POSIX's `struct timeval` (`sys/time.h`), filled in
;; by `gettimeofday`:
;;   struct timeval { time_t tv_sec; suseconds_t tv_usec; };
;; deliberately chosen because its layout is simple and stable across
;; every 64-bit target this project runs on (glibc/Linux and FreeBSD
;; amd64 alike): both fields are plain 8-byte integers with no padding
;; between them (verified directly on this project's own FreeBSD dev
;; box via a scratch C program printing sizeof/offsetof) -- tv_sec at
;; byte offset 0, tv_usec at byte offset 8, 16 bytes total. A struct
;; mixing field widths (e.g. an int32 next to an int64) would need real
;; alignment padding accounted for, which this bridge never computes for
;; you -- see the header comments above for why.
;;
;; SECURITY: see examples/39-ffi-libm-caller.scm's own SECURITY note --
;; ffi-pointer-ref/-set! add raw offset+type memory access with no bounds
;; checking whatsoever on top of that.
;;
;; The 16-byte buffer itself comes from ffi-gc-malloc, not libc's malloc:
;; scratch memory this script owns outright (not a handle some C API
;; allocated and expects back through its own matching free), so it's
;; backed by this process's own Boehm GC heap instead -- reclaimed
;; automatically once unreachable, no matching free to remember (contrast
;; examples/39-ffi-libm-caller.scm's libc malloc/free, which still needs
;; one). See (creme ffi)'s own header comment for exactly when
;; ffi-gc-malloc/ffi-gc-free fit and when they don't.
(import (scheme base) (scheme write) (creme ffi) (creme foreign) (creme introspection))

;; Same platform-specific soname table as examples/39-ffi-libm-caller.scm
;; (see that file's own comment) -- glibc vs. FreeBSD's BSD-style libc.
(define os (cdr (assq 'os (runtime))))
(define libc-soname (if (string=? os "FreeBSD") "libc.so.7" "libc.so.6"))
(define libc (ffi-open libc-soname))

;; int gettimeofday(struct timeval *tv, struct timezone *tz) -- the
;; second argument is always NULL here (struct timezone is long obsolete).
(define-foreign-function gettimeofday libc "gettimeofday" int32 (pointer pointer))

;; Declares real field-level access into a 16-byte struct timeval buffer
;; -- no accessor-function trick needed, this reads the raw bytes
;; gettimeofday itself wrote.
(define-foreign-struct timeval
  (timeval-tv-sec  timeval-tv-sec-set!  int64 0)
  (timeval-tv-usec timeval-tv-usec-set! int64 8))

;; Unlike libc's malloc, ffi-gc-malloc's contents are always zeroed
;; (Boehm GC's own contract, same as GC_MALLOC everywhere else in this
;; codebase) -- so this is a genuine, deterministic (0 0), not just "some
;; unspecified but readable value".
(define tv (ffi-gc-malloc 16))
(display "freshly ffi-gc-malloc'd, always zeroed: (") (display (timeval-tv-sec tv)) (display " ") (display (timeval-tv-usec tv)) (display ")") (newline)

(gettimeofday tv #f)
(display "after gettimeofday(&tv, NULL):") (newline)
(display "  tv_sec (epoch seconds): ") (display (timeval-tv-sec tv)) (newline)
(display "  tv_usec (microseconds): ") (display (timeval-tv-usec tv)) (newline)
(display "  tv_usec < 1,000,000? ") (display (< (timeval-tv-usec tv) 1000000)) (newline)

;; No free needed -- tv is reclaimed automatically once unreachable. An
;; early release is still available if wanted: (ffi-gc-free tv).
(ffi-close libc)
