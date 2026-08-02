;; (creme actor): thin re-export frontend over (creme builtin actor)
(define-library (creme actor)
  (import (creme builtin actor))
  (export actor-ref-id down-reason down-ref down? monitor node-address
          node-name node-path node-port receive! register! remote-ref self
          send! spawn start-node stop-node! whereis))
