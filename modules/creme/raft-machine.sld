;; ===========================================================================
;; (creme raft-machine): declarative sugar over (creme raft)
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme match)/(creme actor-supervisor) use) — pure R7RS Scheme layered on
;; (creme raft)'s primitives, no FFI of its own. Addresses the three bits of
;; boilerplate every (creme raft) state machine otherwise has to hand-roll:
;;
;; - raft-sexp->bytevector / raft-bytevector->sexp: the write/read +
;;   string->utf8/utf8->string round-trip every command/response needs,
;;   since raft-propose!/raft-read only speak bytevectors.
;; - (raft-commands (pattern body ...) ...): an apply-proc builder that
;;   decodes the incoming bytevector, dispatches on the command's head
;;   symbol (destructuring the rest positionally, case-style), re-encodes
;;   whatever the matching clause returns, and — the one genuinely
;;   non-obvious gotcha — transparently answers the zero-length bytevector
;;   raft-read's linearizability barrier reproposes through the real log
;;   (see (creme raft)'s own header comment) with a no-op instead of
;;   letting it fall through to "unknown command".
;; - (raft-cluster ids make-node): given a flat list of node ids and a
;;   (lambda (id peers) ...) constructor, returns one node per id with
;;   `peers` computed as "every other id" — the repetitive part of wiring
;;   up an N-node cluster by hand. Every id `make-node` actually receives
;;   is prefixed with a fresh (raft-fresh-namespace) unique to this one
;;   raft-cluster call, so the ids you pass in (e.g. "n1"/"n2"/"n3") never
;;   need to be globally unique themselves — see (creme raft)'s own header
;;   comment for why raft-transport-in-memory otherwise needs that: its
;;   peer registry is one flat, process-wide namespace shared by every
;;   cluster. Going through raft-cluster means never needing
;;   raft-transport-in-memory-reset! at all.
;;
;; raft-noop-snapshot/raft-noop-restore are ready-made snapshot-proc/
;; restore-proc for demos and tests that don't care about persistence.
;;
;; raft-commands still raises on an unmatched command (via `error`) — fine
;; when called directly, but wired into a real raft-node as its apply-proc
;; that raise crashes the node's own event-loop fiber and hangs whichever
;; raft-propose!/raft-read call triggered it forever, per (creme raft)'s own
;; header comment. Give every command your cluster can receive a clause
;; (an `(else ...)` fallback isn't supported — cover every case instead).
;;
;; Example (a full node constructor, vs. the hand-rolled version in
;; examples/37-raft-kv-store.scm):
;;
;;   (define (make-kv-node id peers)
;;     (define store (make-hash-table))
;;     (raft-node id peers
;;       (raft-state-machine
;;         (raft-commands
;;           ((set key value) (hash-table-set! store key value) 'ok)
;;           ((get key) (hash-table-ref store key (lambda () 'missing))))
;;         raft-noop-snapshot
;;         raft-noop-restore)
;;       (raft-transport-in-memory id)
;;       (raft-log-in-memory)))
;;   (define nodes (raft-cluster '("n1" "n2" "n3") make-kv-node))
;; ===========================================================================

(define-library (creme raft-machine)
  (export raft-sexp->bytevector raft-bytevector->sexp
          raft-commands raft-cluster
          raft-noop-snapshot raft-noop-restore)
  (import (scheme base) (scheme write) (scheme read) (creme raft))
  (begin
    (define (raft-sexp->bytevector v)
      (let ((p (open-output-string)))
        (write v p)
        (string->utf8 (get-output-string p))))

    (define (raft-bytevector->sexp bv)
      (read (open-input-string (utf8->string bv))))

    (define (raft-noop-snapshot) (raft-sexp->bytevector '()))
    (define (raft-noop-restore bv) #t)

    (define-syntax raft-commands
      (syntax-rules ()
        ((_ ((cmd-name field ...) body ...) ...)
         (lambda (%raft-cmd-bv)
           (if (zero? (bytevector-length %raft-cmd-bv))
               (raft-sexp->bytevector 'noop)
               (let ((%raft-cmd-form (raft-bytevector->sexp %raft-cmd-bv)))
                 (case (car %raft-cmd-form)
                   ((cmd-name)
                    (apply (lambda (field ...) (raft-sexp->bytevector (begin body ...)))
                           (cdr %raft-cmd-form)))
                   ...
                   (else (error "raft-commands: unknown command" %raft-cmd-form)))))))))

    (define (raft-other-ids ids id)
      (cond ((null? ids) '())
            ((string=? (car ids) id) (raft-other-ids (cdr ids) id))
            (else (cons (car ids) (raft-other-ids (cdr ids) id)))))

    (define (raft-cluster ids make-node)
      (let* ((namespace (raft-fresh-namespace))
             (qualify (lambda (id) (string-append namespace ":" id)))
             (qualified-ids (map qualify ids)))
        (map (lambda (id) (make-node id (raft-other-ids qualified-ids id))) qualified-ids)))))
