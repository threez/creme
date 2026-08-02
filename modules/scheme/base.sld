;; ===========================================================================
;; (scheme base): thin re-export frontend over (creme builtin base)
;;
;; The native/builtin split lives entirely behind (creme builtin base) now
;; (see src/scheme/modules/scheme/base.cr) — that native family already
;; includes the Scheme-defined list-copy/list-set! layer (registered under
;; the very same ["creme","builtin","base"] key, overwriting the raw
;; Crystal-only registration during Interpreter#initialize), so this
;; frontend needs no additional body of its own: it is a pure re-export.
;; ===========================================================================

(define-library (scheme base)
  (import (creme builtin base))
  (export * + - / < <= = > >= abs and append apply assoc assq assv begin
          binary-port? boolean=? boolean? bytevector bytevector-append
          bytevector-copy bytevector-copy! bytevector-length
          bytevector-u8-ref bytevector-u8-set! bytevector? caar cadr
          call-with-current-continuation call-with-port call-with-values
          call/cc car case case-lambda cdar cddr cdr ceiling char->integer
          char-ready? char<=? char<? char=? char>=? char>? char?
          close-input-port close-output-port close-port cond cond-expand
          cons current-error-port current-input-port current-output-port
          define define-record-type define-syntax define-values denominator
          do dynamic-wind eof-object eof-object? eq? equal? eqv? error
          error-object-irritants error-object-message error-object? even?
          exact exact-integer-sqrt exact-integer? exact? expt features
          file-error? floor floor-quotient floor-remainder floor/
          flush-output-port for-each gcd get-output-bytevector
          get-output-string guard if inexact inexact? input-port-open?
          input-port? integer->char integer? lambda lcm length let let*
          let*-values let-syntax let-values letrec letrec-syntax list
          list->string list->vector list-copy list-ref list-set! list-tail
          list? make-bytevector make-list make-parameter make-string
          make-vector map max member memq memv min modulo negative?
          newline not null? number->string number? numerator odd?
          open-input-bytevector open-input-string open-output-bytevector
          open-output-string or output-port-open? output-port? pair?
          parameterize peek-char peek-u8 port? positive? procedure?
          quasiquote quote quotient raise raise-continuable rational?
          rationalize read-bytevector read-bytevector! read-char read-error?
          read-line read-string read-u8 real? remainder reverse round set!
          set-car! set-cdr! square string string->list string->number
          string->symbol string->utf8 string->vector string-append
          string-copy string-copy! string-fill! string-for-each
          string-length string-map string-ref string-set! string<=?
          string<? string=? string>=? string>? string? substring
          symbol->string symbol=? symbol? syntax-error textual-port?
          truncate truncate-quotient truncate-remainder truncate/ u8-ready?
          unless unquote unquote-splicing utf8->string values vector
          vector->list vector->string vector-append vector-copy
          vector-copy! vector-fill! vector-for-each vector-length
          vector-map vector-ref vector-set! vector? when
          with-exception-handler write-bytevector write-char write-string
          write-u8 zero?))
