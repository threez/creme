;; ===========================================================================
;; (dialect ruby): Ruby-familiar procedure names over this project's own
;; R7RS/creme stdlib
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme extra)/(creme sort) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS with no
;; opaque foreign object, stateful handle, or third-party Crystal library
;; involved — see modules/creme/extra.sld's own header comment for the same
;; rationale.
;;
;; Not auto-imported anywhere — every script that wants to_s/each/puts/etc.
;; must (import (dialect ruby)) explicitly, same as any other file-based
;; library.
;;
;; NOTE: "dialect" is used elsewhere in this codebase for a different
;; concept — #lang <library> SYNTAX dialects (modules/creme/syntax/*.sld,
;; wired through src/creme/runner.cr's reader). This library is unrelated
;; to that: it's a plain naming/wrapping layer over existing procedures, not
;; a Ruby-syntax reader. `(import (dialect ruby))` just happens to reuse the
;; same English word for a different purpose.
;;
;; CALLING CONVENTION: since this is a Lisp with no obj.method dispatch,
;; every alias is prefix-call, `(name receiver args ...)`. Where Ruby itself
;; is polymorphic across String/Array/Hash (to_s, to_i, to_f, length/size,
;; empty?, each, reverse, include?, first, last), the alias here is a single
;; generic procedure that dispatches on the receiver's runtime type via
;; string?/vector?/hash-table?/pair?. Multi-list higher-order procedures
;; (map/select/reject/inject) keep the existing PROC-FIRST argument order
;; (matching (scheme base)'s own map/for-each and (creme extra)'s
;; filter/reduce shape) rather than reordering to receiver-first — reordering
;; risks re-exporting the same name with an incompatible calling convention
;; if a script also imports (scheme base) into the same environment (import
;; is a value-copy into env: whichever import runs last wins, silently).
;; Single-collection, non-higher-order operations (each, each_with_index,
;; push/pop/shift/unshift, flatten, uniq, sort, sum, count, compact, zip)
;; ARE receiver-first, since there's no multi-list-zip ambiguity to protect
;; against there.
;;
;; DO-SUGAR: the six proc-LAST operations (each, each_with_index, times,
;; upto, downto, step) additionally accept a Ruby-block-flavored inline form
;; with no extra parens around the callback: `(each lst do (x) (puts x))`
;; instead of `(each lst (lambda (x) (puts x)))` — this desugars at the
;; `each`/etc. call site itself (not via the standalone `do` macro below,
;; though that one composes fine too: `(each lst (do (x) (puts x)))` still
;; works). This makes each of these six a MACRO, not a plain procedure, so
;; none of them can be passed around as a first-class value anymore (stored
;; in a variable, passed to `apply`/`map`, etc.) — a macro's expansion is
;; analyzed against the CALLER's own environment in this interpreter (same
;; as (creme for)'s macros), so each macro here expands to a call of a
;; same-named `-proc` sibling that IS a plain, first-class procedure and is
;; exported right alongside it (`each-proc`, `each_with_index-proc`,
;; `times-proc`, `upto-proc`, `downto-proc`, `step-proc`) — reach for those
;; directly whenever first-class-value behavior is needed.
;;
;; The parameter list right after `do` is REQUIRED, even when empty — write
;; `(times 3 do () (puts "hi"))`, not `(times 3 do (puts "hi"))`. The
;; `(param ...)` pattern greedily matches the first list form after `do`
;; no matter its contents, so an omitted parameter list is genuinely
;; ambiguous with a single-body-form call that merely looks like a param
;; list (`(times 3 do (process item))` — is that a 2-param list, or a call
;; to `process` with argument `item` as the whole body?), the same
;; ambiguity Ruby itself resolves with `|param|` pipe delimiters that this
;; syntax doesn't have room for.
;;
;; ARITY: every `do`/do-sugar lambda gets a trailing rest parameter tacked
;; on (`(param ... . %do-rest)`), so it silently accepts and discards any
;; call arguments beyond the ones you declared — `(times 3 do () ...)`'s
;; zero-param block still works even though `times-proc` always calls its
;; proc with the index, matching Ruby's own lenient block-arity behavior
;; (a block that ignores `|i|` still works fine as `3.times { ... }`).
;;
;; RETURN VALUE: each of the six proc-taking loop operations (each,
;; each_with_index, times, upto, downto, step) is purely for side effects
;; and returns void ('(), this interpreter's own convention — see what
;; (for-each ...) or (when #f ...) already return) once the loop finishes,
;; not #f — so e.g. `(write (times 3 (lambda (i) i)))` prints `()`, matching
;; the rest of this project's side-effecting forms rather than reading as a
;; meaningful boolean result.
;;

;; NAME COLLISIONS, called out explicitly rather than silently shadowed:
;;   - values: Ruby's Hash#values naturally wants this name, but R7RS's own
;;     `values` (multiple-return) already occupies it. This library exports
;;     `values` as the Ruby-named hash accessor AND `r7rs-values` as R7RS's
;;     original multiple-return procedure, so a script that needs both can
;;     still reach multiple-return after (import (dialect ruby)) shadows the
;;     bare name.
;;   - times: (creme extra) already defines a `times` MACRO (repeat a body n
;;     times, purely for side effects, no bound index). Ruby's `3.times { |i|
;;     ... }` is method-shaped and binds an index, so this library's `times`
;;     is its own distinct macro, `(times n proc)` / `(times n do (i) body
;;     ...)` (see DO-SUGAR above) — bearing no relation to (creme extra)'s
;;     `times` beyond the shared name. If a script imports both (creme
;;     extra) and (dialect ruby), whichever import runs last wins the
;;     `times` binding — not an error, just worth knowing.
;;   - min/max: R7RS's `min`/`max` (from (scheme base)) take multiple number
;;     arguments, e.g. (min 3 1 2). This library's `min`/`max` take a single
;;     list receiver, e.g. (min '(3 1 2)), matching Ruby's Array#min/#max.
;;     Same last-import-wins caveat as `times` if both bindings are visible
;;     in the same environment.
;;   - do: THE SEVERE ONE. `do` is a hard-coded special form (the R7RS
;;     named-loop construct), not an ordinary identifier — but this
;;     interpreter's analyzer checks for a local macro/variable binding
;;     named `do` before falling back to the special-form table (see
;;     src/creme/compile/analyzer.cr's analyze_cons), so a library-exported
;;     `define-syntax do` DOES shadow it once imported. This library exports
;;     `do` as a Ruby-block-flavored macro, `(do (param ...) body ...)` =>
;;     `(lambda (param ... . %do-rest) body ...)` (the trailing rest param
;;     silently swallows any extra call args beyond the ones you declared,
;;     matching Ruby's own lenient block arity — see ARITY below), so
;;     `(each lst (do (x) (puts x)))` reads close to Ruby's `each { |x| puts
;;     x }`. There is no reliable way to support both this shape and R7RS's
;;     `(do ((var init step) ...) (test
;;     expr ...) command ...)` under one macro name (syntax-rules has no
;;     type-based dispatch, and both shapes start `(do (...) ...)`), so
;;     importing (dialect ruby) makes the REAL `do` loop entirely unusable
;;     for the rest of that script — including indirectly, e.g. (creme
;;     extra)'s `times` macro expands to a real `do` loop at its call site,
;;     so `(import (creme extra) (dialect ruby))` followed by a `(times ...)`
;;     call will fail once `do` is shadowed. Only import (dialect ruby) in a
;;     script that doesn't need R7RS `do` loops elsewhere — use this
;;     library's own `times`/`upto`/`downto`/`step`/`each` instead.
;;
;; MUTATION: Ruby's push/pop/shift/unshift/<< mutate their receiver in
;; place; plain Scheme lists are immutable-by-convention here. Rather than
;; silently faking mutation, this library's push/pop/shift/unshift are PURE
;; functions that return the new list (pop/shift additionally return the
;; removed element via a second value — see `values`/`call-with-values` or
;; `let-values` to bind both). Callers who want real in-place mutable-array
;; semantics already have (creme treelist)'s mutable-treelist-* family;
;; wrapping that under Ruby names is out of scope here.
;;
;; SIMPLIFICATION: to_i/to_f parse a leading (optionally signed) integer/
;; decimal prefix the way Ruby's String#to_i/#to_f do (`"42abc".to_i` => 42,
;; non-numeric => 0), but do NOT understand exponent notation ("1e10") the
;; way Ruby's to_f does — a rare enough case that a plain decimal literal
;; scan is not worth the extra complexity here.
;; ===========================================================================

(define-library (dialect ruby)
  (export
    ;; kernel / IO
    puts print p to_s to_i to_f inspect do
    ;; generic (string/vector/hash-table/list dispatch)
    length size empty? each each-proc each_with_index each_with_index-proc
    reverse include? first last
    ;; string
    upcase downcase strip split start_with? end_with? gsub chars index
    ljust rjust
    ;; array (over plain lists)
    map select reject collect inject reduce
    push pop shift unshift flatten uniq sort min max sum count compact zip join
    ;; hash (over (creme hash-table))
    keys values r7rs-values has_key? key? delete each_pair to_a merge
    ;; numeric
    times times-proc upto upto-proc downto downto-proc step step-proc
    even? odd? zero? positive? negative? abs round ceil floor)
  (import (scheme base)
          (scheme write)
          (scheme char)
          (rename (scheme base)
                  (values r7rs-values)
                  (length r7rs-length)
                  (reverse r7rs-reverse))
          (creme string)
          (creme hash-table)
          (creme sort))
  (begin
    ;; ------------------------------------------------------------------
    ;; kernel / IO
    ;; ------------------------------------------------------------------

    (define (%puts-one x)
      (if (pair? x)
          (for-each %puts-one x)
          (begin (display x) (newline))))

    ;; (puts arg ...) — each arg on its own line; a list arg is flattened
    ;; one level (recursively), same as Ruby's Array-flattening puts.
    (define (puts . args)
      (if (null? args)
          (newline)
          (for-each %puts-one args)))

    ;; (print arg ...) — display every arg, no trailing newline.
    (define (print . args)
      (for-each display args))

    ;; (p x) — write x (readable/quoted form) followed by a newline,
    ;; returning x, matching Ruby's `p`.
    (define (p x)
      (write x)
      (newline)
      x)

    ;; (do (param ...) body ...) => (lambda (param ... . %do-rest) body ...) — a
    ;; Ruby-block-flavored way to write a callback, e.g.
    ;; (each lst (do (x) (puts x))) reading close to Ruby's `each { |x|
    ;; puts x }`. SHADOWS THE REAL R7RS `do` LOOP for the rest of any script
    ;; that imports this library — see this file's header comment (the `do`
    ;; entry under NAME COLLISIONS) before relying on this.
    (define-syntax do
      (syntax-rules ()
        ((_ (param ...) body ...) (lambda (param ... . %do-rest) body ...))))

    (define (to_s x)
      (cond
        ((string? x) x)
        ((symbol? x) (symbol->string x))
        ((number? x) (number->string x))
        (else (let ((port (open-output-string)))
                (display x port)
                (get-output-string port)))))

    ;; (inspect x) — to_s's readable/quoted counterpart, as a string.
    (define (inspect x)
      (let ((port (open-output-string)))
        (write x port)
        (get-output-string port)))

    ;; Longest leading (optionally +/- signed) run of digits in s, as a
    ;; string, or #f if s has no leading digit at all.
    (define (%leading-int-string s)
      (let loop ((cs (string->list s)) (acc '()) (started #f))
        (cond
          ((and (null? acc) (pair? cs) (or (char=? (car cs) #\-) (char=? (car cs) #\+)))
           (loop (cdr cs) (list (car cs)) #f))
          ((and (pair? cs) (char-numeric? (car cs)))
           (loop (cdr cs) (cons (car cs) acc) #t))
          (else (if started (list->string (r7rs-reverse acc)) #f)))))

    ;; Longest leading run of plain digits (no sign) in s, as a string
    ;; (possibly "").
    (define (%leading-digits s)
      (let loop ((cs (string->list s)) (acc '()))
        (if (and (pair? cs) (char-numeric? (car cs)))
            (loop (cdr cs) (cons (car cs) acc))
            (list->string (r7rs-reverse acc)))))

    ;; Like %leading-int-string, but also consumes a single "." plus
    ;; trailing digits right after the integer part, if present.
    (define (%leading-float-string s)
      (let ((int-part (%leading-int-string s)))
        (and int-part
             (let* ((len (string-length int-part))
                    (rest (substring s len (string-length s))))
               (if (and (> (string-length rest) 0) (char=? (string-ref rest 0) #\.))
                   (let ((frac (%leading-digits (substring rest 1 (string-length rest)))))
                     (string-append int-part "." (if (string=? frac "") "0" frac)))
                   int-part)))))

    (define (to_i x)
      (cond
        ((number? x) (exact (truncate x)))
        ((string? x) (let ((digits (%leading-int-string x)))
                       (if digits (or (string->number digits) 0) 0)))
        (else (error "to_i: unsupported type" x))))

    (define (to_f x)
      (cond
        ((number? x) (inexact x))
        ((string? x) (let ((digits (%leading-float-string x)))
                       (if digits
                           (let ((n (string->number digits)))
                             (if n (inexact n) 0.0))
                           0.0)))
        (else (error "to_f: unsupported type" x))))

    ;; ------------------------------------------------------------------
    ;; generic (string / vector / hash-table / list dispatch)
    ;; ------------------------------------------------------------------

    (define (length coll)
      (cond
        ((string? coll) (string-length coll))
        ((vector? coll) (vector-length coll))
        ((hash-table? coll) (r7rs-length (hash-table->alist coll)))
        (else (r7rs-length coll))))

    (define size length)

    (define (empty? coll) (zero? (length coll)))

    (define (each-proc coll proc)
      (cond
        ((string? coll) (string-for-each proc coll))
        ((vector? coll) (vector-for-each proc coll))
        ((hash-table? coll) (for-each proc (hash-table->alist coll)))
        (else (for-each proc coll))))

    ;; (each coll proc) or (each coll do (param ...) body ...) — the latter
    ;; lets a call read close to Ruby's `coll.each do |x| ... end`, with no
    ;; extra parens around the block: (each lst do (x) (puts x)). `each` is
    ;; a MACRO (not a plain procedure) to make this fusion possible, so it
    ;; can no longer be passed around as a first-class value (e.g. to apply
    ;; or stored in a variable) — pass each-proc's underlying behavior via
    ;; an explicit (lambda (c p) (each c p)) wrapper if that's ever needed.
    (define-syntax each
      (syntax-rules (do)
        ((_ coll do (param ...) body ...) (each-proc coll (lambda (param ... . %do-rest) body ...)))
        ((_ coll proc) (each-proc coll proc))))

    ;; (each_with_index-proc coll proc) — proc called with (elem index), 0-based.
    (define (each_with_index-proc coll proc)
      (let loop ((rest (cond ((string? coll) (string->list coll))
                              ((vector? coll) (vector->list coll))
                              ((hash-table? coll) (hash-table->alist coll))
                              (else coll)))
                 (i 0))
        (if (null? rest)
            '()
            (begin (proc (car rest) i) (loop (cdr rest) (+ i 1))))))

    ;; (each_with_index coll proc) or (each_with_index coll do (elem i) body ...)
    ;; — same do-sugar fusion as `each`, see its comment above.
    (define-syntax each_with_index
      (syntax-rules (do)
        ((_ coll do (param ...) body ...) (each_with_index-proc coll (lambda (param ... . %do-rest) body ...)))
        ((_ coll proc) (each_with_index-proc coll proc))))

    (define (reverse coll)
      (cond
        ((string? coll) (string-reverse coll))
        ((vector? coll) (list->vector (r7rs-reverse (vector->list coll))))
        ((hash-table? coll) (error "reverse: hash-tables have no order"))
        (else (r7rs-reverse coll))))

    (define (%vector-member? x v)
      (let loop ((i 0))
        (cond
          ((= i (vector-length v)) #f)
          ((equal? (vector-ref v i) x) #t)
          (else (loop (+ i 1))))))

    (define (include? coll x)
      (cond
        ((string? coll) (string-contains? coll x))
        ((hash-table? coll) (hash-table-contains? coll x))
        ((vector? coll) (%vector-member? x coll))
        (else (if (member x coll) #t #f))))

    (define (first coll)
      (cond
        ((string? coll) (string-ref coll 0))
        ((vector? coll) (vector-ref coll 0))
        (else (car coll))))

    (define (%last-pair lst) (if (pair? (cdr lst)) (%last-pair (cdr lst)) lst))

    (define (last coll)
      (cond
        ((string? coll) (string-ref coll (- (string-length coll) 1)))
        ((vector? coll) (vector-ref coll (- (vector-length coll) 1)))
        (else (car (%last-pair coll)))))

    ;; ------------------------------------------------------------------
    ;; string
    ;; ------------------------------------------------------------------

    (define upcase string-upcase)
    (define downcase string-downcase)
    (define strip string-trim)
    (define split string-split)
    (define start_with? string-prefix?)
    (define end_with? string-suffix?)
    (define gsub string-replace)
    (define chars string->list)
    (define index string-index-of)
    ;; string-pad right-justifies (pads on the left) == Ruby's rjust;
    ;; string-pad-right left-justifies (pads on the right) == Ruby's ljust.
    (define rjust string-pad)
    (define ljust string-pad-right)

    ;; ------------------------------------------------------------------
    ;; array (over plain lists)
    ;; ------------------------------------------------------------------

    (define (select pred lst)
      (cond
        ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (select pred (cdr lst))))
        (else (select pred (cdr lst)))))

    (define (reject pred lst) (select (lambda (x) (not (pred x))) lst))

    (define collect map)

    (define (inject proc init lst)
      (if (null? lst) init (inject proc (proc init (car lst)) (cdr lst))))

    (define reduce inject)

    (define (push lst x) (append lst (list x)))

    (define (%drop-last lst)
      (if (null? (cdr lst)) '() (cons (car lst) (%drop-last (cdr lst)))))

    ;; (pop lst) -> two values: the removed last element, and the
    ;; shortened list. Use let-values/call-with-values to bind both.
    ;; NOTE: uses r7rs-values, not the bare `values` name — this library
    ;; later redefines `values` as the hash-table accessor (see the Hash
    ;; section below), and since a library body's defines all share one
    ;; environment, a later `(define values ...)` would otherwise silently
    ;; break this multiple-return call once the whole library has loaded.
    (define (pop lst) (r7rs-values (last lst) (%drop-last lst)))

    ;; (shift lst) -> two values: the removed first element, and the rest.
    (define (shift lst) (r7rs-values (car lst) (cdr lst)))

    (define (unshift lst x) (cons x lst))

    (define (flatten lst)
      (cond
        ((null? lst) '())
        ((pair? (car lst)) (append (flatten (car lst)) (flatten (cdr lst))))
        (else (cons (car lst) (flatten (cdr lst))))))

    (define (uniq lst)
      (let loop ((lst lst) (seen '()) (acc '()))
        (cond
          ((null? lst) (r7rs-reverse acc))
          ((member (car lst) seen) (loop (cdr lst) seen acc))
          (else (loop (cdr lst) (cons (car lst) seen) (cons (car lst) acc))))))

    (define (%default-less? a b)
      (cond
        ((and (number? a) (number? b)) (< a b))
        ((and (string? a) (string? b)) (string<? a b))
        (else (error "sort: no default comparator for these element types; pass one explicitly"))))

    ;; (sort lst [less?]) — stable; less? defaults to < for numbers,
    ;; string<? for strings.
    (define (sort lst . opt)
      (list-sort (if (pair? opt) (car opt) %default-less?) lst))

    (define (%extreme better? lst)
      (let loop ((rest (cdr lst)) (best (car lst)))
        (if (null? rest)
            best
            (loop (cdr rest) (if (better? (car rest) best) (car rest) best)))))

    ;; (min lst) / (max lst) — the smallest/largest element of lst, per
    ;; %default-less?. NOTE this shadows R7RS's variadic-number-argument
    ;; min/max — see this file's header comment.
    (define (min lst) (%extreme %default-less? lst))
    (define (max lst) (%extreme (lambda (a b) (%default-less? b a)) lst))

    (define (sum lst) (inject + 0 lst))

    (define (count lst . opt)
      (if (pair? opt)
          (let ((pred (car opt)))
            (inject (lambda (acc x) (if (pred x) (+ acc 1) acc)) 0 lst))
          (length lst)))

    ;; drops #f elements (this dialect's closest analog to Ruby's nil).
    (define (compact lst) (select (lambda (x) x) lst))

    (define (%any-null? lists)
      (cond
        ((null? lists) #f)
        ((null? (car lists)) #t)
        (else (%any-null? (cdr lists)))))

    (define (zip . lists)
      (if (or (null? lists) (%any-null? lists))
          '()
          (cons (map car lists) (apply zip (map cdr lists)))))

    ;; (join lst sep) — every element converted via to_s, then joined by
    ;; sep; works for a list of strings too (to_s is identity on strings),
    ;; covering Ruby's String#join-via-Array as one procedure.
    (define (join lst sep) (string-join (map to_s lst) sep))

    ;; ------------------------------------------------------------------
    ;; hash (over (creme hash-table))
    ;; ------------------------------------------------------------------

    (define keys hash-table-keys)
    ;; shadows R7RS's `values` (multiple-return) — see r7rs-values above and
    ;; this file's header comment.
    (define values hash-table-values)
    (define has_key? hash-table-contains?)
    (define key? hash-table-contains?)
    ;; unlike this dialect's other mutating operations, `delete` has no `!`
    ;; suffix, matching Ruby's own Hash#delete (also mutates without a bang).
    (define delete hash-table-delete!)

    (define (each_pair h proc)
      (for-each (lambda (kv) (proc (car kv) (cdr kv))) (hash-table->alist h)))

    (define to_a hash-table->alist)

    ;; (merge h1 h2) -> a new hash-table with every key from both, h2's
    ;; value winning on conflict.
    (define (merge h1 h2)
      (let ((result (make-hash-table)))
        (for-each (lambda (kv) (hash-table-set! result (car kv) (cdr kv))) (hash-table->alist h1))
        (for-each (lambda (kv) (hash-table-set! result (car kv) (cdr kv))) (hash-table->alist h2))
        result))

    ;; ------------------------------------------------------------------
    ;; numeric
    ;; ------------------------------------------------------------------

    ;; (times-proc n proc) — proc called with 0, 1, ..., n-1.
    (define (times-proc n proc)
      (let loop ((i 0))
        (if (= i n) '() (begin (proc i) (loop (+ i 1))))))

    ;; (times n proc) or (times n do (i) body ...) — do-sugar fusion, see
    ;; `each`'s comment above; this ALSO makes `times` a macro rather than a
    ;; plain procedure — see this file's header comment re: (creme extra)'s
    ;; own `times` macro for the pre-existing naming collision.
    (define-syntax times
      (syntax-rules (do)
        ((_ n do (param ...) body ...) (times-proc n (lambda (param ... . %do-rest) body ...)))
        ((_ n proc) (times-proc n proc))))

    (define (upto-proc n limit proc)
      (let loop ((i n))
        (if (> i limit) '() (begin (proc i) (loop (+ i 1))))))

    (define-syntax upto
      (syntax-rules (do)
        ((_ n limit do (param ...) body ...) (upto-proc n limit (lambda (param ... . %do-rest) body ...)))
        ((_ n limit proc) (upto-proc n limit proc))))

    (define (downto-proc n limit proc)
      (let loop ((i n))
        (if (< i limit) '() (begin (proc i) (loop (- i 1))))))

    (define-syntax downto
      (syntax-rules (do)
        ((_ n limit do (param ...) body ...) (downto-proc n limit (lambda (param ... . %do-rest) body ...)))
        ((_ n limit proc) (downto-proc n limit proc))))

    (define (step-proc n limit by proc)
      (let loop ((i n))
        (if (if (> by 0) (> i limit) (< i limit))
            '()
            (begin (proc i) (loop (+ i by))))))

    (define-syntax step
      (syntax-rules (do)
        ((_ n limit by do (param ...) body ...) (step-proc n limit by (lambda (param ... . %do-rest) body ...)))
        ((_ n limit by proc) (step-proc n limit by proc))))

    (define ceil ceiling)))
