;; (creme mux): thin re-export frontend over (creme builtin mux)
(define-library (creme mux)
  (import (creme builtin mux))
  (export mux-address mux-base-url mux-close! mux-delete! mux-get!
          mux-head! mux-listen! mux-patch! mux-post! mux-put! mux-router
          mux-router? mux-use!))
