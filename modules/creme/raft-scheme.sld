;; (creme raft-scheme): pure-Scheme Raft consensus (actor + SQLite), no FFI.
;; See modules/creme/raft-scheme/core.scm's own header comment for the full
;; design -- this file is just the native import/export wrapper around it.
(define-library (creme raft-scheme)
  (import (scheme base) (scheme write) (scheme char)
          (creme actor) (creme sql) (creme process) (creme hash-table) (creme random))
  (export raft-scheme-config raft-scheme-state-machine
          raft-scheme-transport-in-memory raft-scheme-transport-partition!
          raft-scheme-transport-heal!
          raft-scheme-node raft-scheme-start! raft-scheme-stop!
          raft-scheme-propose! raft-scheme-read
          raft-scheme-add-peer! raft-scheme-remove-peer!
          raft-scheme-add-learner! raft-scheme-promote-learner!
          raft-scheme-snapshot! raft-scheme-metrics raft-scheme-role raft-scheme-leader
          raft-scheme-await-leader! raft-scheme-cluster)
  (include "raft-scheme/core.scm"))
