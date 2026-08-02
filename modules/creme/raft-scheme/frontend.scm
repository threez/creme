;; ===========================================================================
;; (creme raft) pure-Scheme frontend -- bare raft-* primitives matching the
;; real (creme raft) FFI binding's exact contract, built as thin aliases/
;; adapters over the already-tested raft-scheme-* engine (core.scm, included
;; just before this file). Included ONLY by modules/creme/raft.sld's
;; cond-expand `else` branch (i.e. only ever reached when `(library (creme
;; builtin raft))` is unavailable -- see raft.sld's own header comment for
;; why that's a reliable "am I running where raft.cr's FFI code doesn't
;; exist" signal, with no new feature identifier needed on either runtime).
;;
;; No import/define-library header of its own, same reasoning as core.scm:
;; it's spliced in via `(include ...)`, so it must only reference names
;; already visible in whatever surrounds it.
;;
;; Because (creme raft-machine) (raft-cluster, raft-commands,
;; raft-sexp->bytevector/-bytevector->sexp, raft-noop-snapshot/-restore) is
;; pure R7RS, generic over whatever (creme raft) exports, it needs NO
;; changes at all to work against this backend -- it never touches
;; raft-scheme-* names directly, only the bare raft-* ones this file
;; provides. raft-propose!/raft-read need no bytevector conversion here:
;; raft-scheme's engine already treats command data as an arbitrary opaque
;; Scheme value (a bytevector is just one such value), and core.scm's
;; parse-datum reader understands #u8(...) literals specifically so a
;; bytevector-valued log entry still round-trips through SQLite.
;;
;; ---- The "node" indirection ------------------------------------------------
;; The real (creme raft) contract MUTATES a node in place: `raft-start!`
;; upgrades an already-constructed node object, and every caller keeps using
;; the SAME reference from before the start (examples/37-raft-kv-store.scm
;; does exactly this: `(for-each raft-start! nodes)` discards raft-start!'s
;; own return value and keeps passing the ORIGINAL `nodes` list to
;; raft-await-leader!/raft-leader/etc afterward). raft-scheme's own
;; raft-scheme-start! can't mutate in place -- spawning an actor genuinely
;; produces a brand-new reference, there's no way to turn a plain
;; descriptor list into that reference by mutating it. So every "node"
;; value this file's public API hands out is a one-element mutable box
;; (a list of one element) rather than the bare raft-scheme-* value
;; directly: `raft-node` wraps the pre-start descriptor in a box;
;; `raft-start!` replaces the box's content with the started actor-ref
;; in place; every other function here (propose!/read/stop!/role/leader/
;; metrics/add-peer!/...) unwraps the box to get whatever it currently
;; holds. This indirection is entirely local to this file -- core.scm and
;; (creme raft-scheme)'s own raft-scheme-* API are untouched and keep using
;; bare actor-refs directly, as already tested.
;;
;; Predicates (raft-node?/-log?/-transport?/-config?/-state-machine?) are
;; deliberately best-effort here, not exhaustively identical to the FFI
;; version's tagged-SchemeBox semantics (there's no equivalent tagging
;; mechanism available to plain included Scheme source) -- fine for the
;; kv-store-shaped demo/spec surface this backend actually needs to satisfy.
;; ===========================================================================

;; ---- the node box -----------------------------------------------------

(define (raft-node . args) (list (apply raft-scheme-node args)))

(define (raft-node-ref box) (car box))

(define (raft-start! box)
  (set-car! box (raft-scheme-start! (car box)))
  raft-unspecified)

(define raft-unspecified (list 'unspecified))

(define (raft-stop! box) (raft-scheme-stop! (raft-node-ref box)))
(define (raft-propose! box command) (raft-scheme-propose! (raft-node-ref box) command))
(define (raft-read box command) (raft-scheme-read (raft-node-ref box) command))
(define (raft-add-peer! box peer-id) (raft-scheme-add-peer! (raft-node-ref box) peer-id))
(define (raft-remove-peer! box peer-id) (raft-scheme-remove-peer! (raft-node-ref box) peer-id))
(define (raft-add-learner! box peer-id) (raft-scheme-add-learner! (raft-node-ref box) peer-id))
(define (raft-promote-learner! box peer-id) (raft-scheme-promote-learner! (raft-node-ref box) peer-id))
(define (raft-snapshot! box) (raft-scheme-snapshot! (raft-node-ref box)))
(define (raft-leader box) (raft-scheme-leader (raft-node-ref box)))
(define (raft-role box) (raft-scheme-role (raft-node-ref box)))
(define (raft-metrics box) (raft-scheme-metrics (raft-node-ref box)))

;; Awaits a list of BOXES (matching raft-start!'s in-place-mutated boxes),
;; and returns the winning box (not the bare ref) so callers can keep
;; passing it straight into raft-leader/raft-propose!/etc, same as every
;; other node value this file hands out.
(define (raft-find-box-by-ref boxes ref)
  (cond ((null? boxes) #f)
        ((eq? (raft-node-ref (car boxes)) ref) (car boxes))
        (else (raft-find-box-by-ref (cdr boxes) ref))))

(define (raft-await-leader! boxes . rest)
  (let* ((refs (map raft-node-ref boxes))
         (winning-ref (apply raft-scheme-await-leader! refs rest)))
    (if winning-ref (raft-find-box-by-ref boxes winning-ref) #f)))

;; ---- log: raft-scheme-node's log arg is already just a path string --------

(define (raft-log-in-memory) ":memory:")
(define (raft-log-file path . rest) path)
(define (raft-log? v) (string? v))

;; ---- config: raft-scheme's engine already reads config as a plain alist
;; (raft-cfg = assq), so the real (creme raft) 0-or-1-alist-argument
;; contract needs no conversion at all ----------------------------------

(define (raft-config . rest) (if (null? rest) '() (car rest)))
(define (raft-config? v) (or (null? v) (and (pair? v) (pair? (car v)))))

;; ---- transport: (creme raft)'s raft-transport-in-memory is id-keyed
;; against one shared, process-wide, class-level registry; raft-scheme's is
;; one explicit ref threaded through cluster construction. Adapt with a
;; single lazily-created, resettable shared transport --------------------

(define raft-transport-box (list #f))

(define (raft-transport-current!)
  (if (car raft-transport-box)
      (car raft-transport-box)
      (let ((t (raft-scheme-transport-in-memory)))
        (set-car! raft-transport-box t)
        t)))

(define (raft-transport-in-memory id) (raft-transport-current!))

(define (raft-transport-in-memory-reset!)
  (set-car! raft-transport-box (raft-scheme-transport-in-memory)))

(define (raft-transport-partition! a b)
  (raft-scheme-transport-partition! (raft-transport-current!) a b))

(define (raft-transport-heal! a b)
  (raft-scheme-transport-heal! (raft-transport-current!) a b))

(define (raft-transport-tcp . args)
  (error "raft-transport-tcp: not supported by the pure-Scheme (creme raft) backend -- (creme actor)'s own start-node 'tcp/'unix gives real network distribution instead"))

(define (raft-actor-ref? v)
  (guard (e (#t #f)) (actor-ref-id v) #t))

(define (raft-transport? v) (raft-actor-ref? v))

;; ---- raft-fresh-namespace: a simple per-process incrementing counter,
;; matching "a fresh id-prefix unique for the life of the process" without
;; needing Crystal's Atomic --------------------------------------------------

(define raft-fresh-namespace-counter (list 0))

(define (raft-fresh-namespace . rest)
  (let ((prefix (if (null? rest) "raft" (car rest))))
    (set-car! raft-fresh-namespace-counter (+ 1 (car raft-fresh-namespace-counter)))
    (string-append prefix "-" (number->string (car raft-fresh-namespace-counter)))))

;; ---- state machine + node predicate (best-effort, see header comment) -----

;; raft-scheme's own engine signals its linearizability-barrier no-op
;; entry by calling apply-proc with the symbol 'noop (see (creme
;; raft-scheme)'s own header comment/spec) -- the real FFI contract instead
;; calls apply-proc with an EMPTY BYTEVECTOR for that same purpose (see
;; (creme raft)'s own header comment: "apply-proc WILL be called with an
;; empty bytevector it never issued itself"), which is exactly what (creme
;; raft-machine)'s raft-commands macro checks for
;; (zero? (bytevector-length ...)). Translate right at the boundary so the
;; user's apply-proc only ever sees the real contract's shape.
(define (raft-state-machine apply-proc snapshot-proc restore-proc)
  (raft-scheme-state-machine
    (lambda (cmd) (apply-proc (if (eq? cmd 'noop) (bytevector) cmd)))
    snapshot-proc
    restore-proc))

(define (raft-state-machine? v)
  (and (pair? v) (= (length v) 3) (procedure? (car v)) (procedure? (cadr v)) (procedure? (caddr v))))

(define (raft-node? v)
  (and (pair? v) (null? (cdr v))
       (let ((inner (car v)))
         (or (raft-actor-ref? inner)
             (and (list? inner) (= (length inner) 7) (string? (car inner)))))))
