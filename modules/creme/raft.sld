;; (creme raft): transparent frontend -- (creme builtin raft) (the real
;; threez/raft.cr FFI binding) when it exists, else the pure-Scheme
;; actor+SQLite engine in raft-scheme/ (no FFI at all, so it also runs
;; under cvm, which has no raft.cr code compiled in).
;;
;; The `(library (creme builtin raft))` check is a reliable, already-
;; existing discriminator between the two runtimes, needing no new feature
;; identifier anywhere: `(creme builtin raft)` is registered directly into
;; native's in-memory pending-library table by `register_library ["creme",
;; "builtin", "raft"], ...` in src/scheme/modules/creme/raft.cr (no .sld
;; file involved at all, always present whenever raft.cr's FFI code is
;; compiled into the binary) -- so it's ALWAYS true under any `bin/creme`
;; build, including `--self-hosted` mode (still native Crystal underneath).
;; Under cvm, that same 3-segment library name fails BOTH of cvm's own
;; resolution paths (no modules/creme/builtin/raft.sld file exists on disk,
;; and cvm/bootstrap.c's hardcoded fallback table structurally only handles
;; 2-segment "(creme X)" names) -- feature-satisfied?'s `library` case
;; gracefully returns #f, never an abort, so the `else` branch below is
;; exactly the cvm case.
;;
;; (creme raft-machine) (raft-cluster, raft-commands, sexp<->bytevector,
;; noop-snapshot/-restore -- pure R7RS, generic over whatever (creme raft)
;; exports) needs NO changes to work unchanged on top of either branch.
;; (creme raft-scheme) (modules/creme/raft-scheme.sld) is the same engine
;; under its own raft-scheme-* names, for anyone who wants it directly
;; without going through this dispatch.
(define-library (creme raft)
  (cond-expand
    ((library (creme builtin raft))
     (import (creme builtin raft)))
    (else
     (import (scheme base) (scheme write) (scheme char)
             (creme actor) (creme sql) (creme process) (creme hash-table) (creme random))
     (include "raft-scheme/core.scm")
     (include "raft-scheme/frontend.scm")))
  (export raft-add-learner! raft-add-peer! raft-await-leader! raft-config
          raft-config? raft-fresh-namespace raft-leader raft-log-file
          raft-log-in-memory raft-log? raft-metrics raft-node raft-node?
          raft-promote-learner! raft-propose! raft-read raft-remove-peer!
          raft-role raft-snapshot! raft-start! raft-state-machine
          raft-state-machine? raft-stop! raft-transport-heal!
          raft-transport-in-memory raft-transport-in-memory-reset!
          raft-transport-partition! raft-transport-tcp raft-transport?))
