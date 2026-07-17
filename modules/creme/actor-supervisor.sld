;; ===========================================================================
;; (creme actor-supervisor): generic OTP-style restart-on-crash supervision
;;
;; File-based library layered purely on (creme actor)'s spawn/monitor/
;; register! primitives and (creme match) — no FFI of its own, so every
;; actor-using script gets restart bookkeeping without re-deriving it.
;;
;; (child-spec name make-behavior restart) describes one supervised child:
;; `name` is what it's register!-ed under (and how other actors address
;; it — see (creme actor)'s send!, which accepts a registered name
;; directly); `make-behavior` is a 0-argument procedure returning the
;; thunk to spawn (called fresh on every (re)start, so it can rebuild any
;; per-start state, e.g. reopening a database connection); `restart` is
;; 'permanent (always restart, crash or clean exit) or anything else
;; (never restart — dropped from supervision once it terminates).
;; 'transient (restart only on an abnormal exit) isn't implemented yet:
;; that needs the <down> reason threaded through to tell "crashed" apart
;; from "exited cleanly", which this first pass doesn't distinguish.
;;
;; (start-supervisor specs) spawns and returns a supervisor actor watching
;; every spec in `specs`, restarting each 'permanent child when it goes
;; down.
;; ===========================================================================

(define-library (creme actor-supervisor)
  (export child-spec start-supervisor)
  (import (scheme base) (scheme cxr) (creme actor) (creme match) (creme extra))
  (begin
    (define (child-spec name make-behavior restart)
      (list name make-behavior restart))

    (define (spec-name spec) (car spec))
    (define (spec-make-behavior spec) (cadr spec))
    (define (spec-restart spec) (caddr spec))

    (define (start-child spec)
      (define ref (spawn ((spec-make-behavior spec))))
      (register! (spec-name spec) ref)
      (monitor ref)
      ref)

    ;; children: alist of (spec . current-ref), keyed by comparing
    ;; actor-ref-id rather than the ref value itself, since a fresh ref
    ;; freshly deserialized/reconstructed is never eq?/eqv? to another
    ;; ref naming the same actor.
    (define (find-entry children id)
      (cond ((null? children) #f)
            ((string=? (actor-ref-id (cdar children)) id) (car children))
            (else (find-entry (cdr children) id))))

    (define (replace-entry children spec new-ref)
      (map (lambda (entry)
             (if (eq? (car entry) spec) (cons spec new-ref) entry))
           children))

    (define (remove-entry children spec)
      (filter (lambda (entry) (not (eq? (car entry) spec))) children))

    (define (supervisor-loop children)
      (match (receive!)
        ((down? ref reason)
         (let ((entry (find-entry children (actor-ref-id ref))))
           (if entry
               (let ((spec (car entry)))
                 (supervisor-loop
                   (if (eq? (spec-restart spec) 'permanent)
                       (replace-entry children spec (start-child spec))
                       (remove-entry children spec))))
               (supervisor-loop children))))
        (else (supervisor-loop children))))

    (define (start-supervisor specs)
      (spawn (lambda ()
               (supervisor-loop (map (lambda (spec) (cons spec (start-child spec))) specs)))))))
