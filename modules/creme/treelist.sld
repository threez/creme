;; (creme treelist): thin re-export frontend over (creme builtin treelist)
(define-library (creme treelist)
  (import (creme builtin treelist))
  (export empty-treelist list->mutable-treelist list->treelist
          make-mutable-treelist make-treelist mutable-treelist
          mutable-treelist->list mutable-treelist->vector
          mutable-treelist-add! mutable-treelist-append!
          mutable-treelist-copy mutable-treelist-cons!
          mutable-treelist-delete! mutable-treelist-drop!
          mutable-treelist-drop-right! mutable-treelist-empty?
          mutable-treelist-find mutable-treelist-first
          mutable-treelist-for-each mutable-treelist-insert!
          mutable-treelist-last mutable-treelist-length
          mutable-treelist-map! mutable-treelist-member?
          mutable-treelist-prepend! mutable-treelist-ref
          mutable-treelist-reverse! mutable-treelist-set!
          mutable-treelist-snapshot mutable-treelist-sort!
          mutable-treelist-sublist! mutable-treelist-take!
          mutable-treelist-take-right! mutable-treelist?
          vector->mutable-treelist vector->treelist
          treelist treelist->list treelist->vector treelist-add
          treelist-append treelist-cons treelist-copy treelist-delete
          treelist-drop treelist-drop-right treelist-empty? treelist-filter
          treelist-find treelist-first treelist-for-each treelist-index-of
          treelist-insert treelist-last treelist-length treelist-map
          treelist-member? treelist-ref treelist-rest treelist-reverse
          treelist-set treelist-sort treelist-sublist treelist-take
          treelist-take-right treelist?))
