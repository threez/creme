;; ===========================================================================
;; (creme disassemble): a human-readable dump of a compiled <chunk> (or its
;; serialized ICE bytes), the pure-Scheme counterpart of the native
;; src/creme/compile/disassembler.cr -- backs `icecreme -S`/`--dump-bytecode`
;; (disassemble a chunk freshly compiled from source) and `icecreme
;; --disassemble <file.ice>` (disassemble already-serialized bytes, via
;; (creme bytecode)'s bytes->chunk). The output format deliberately mirrors
;; the native Disassembler so the two runtimes' dumps read the same:
;;
;;   == <name> (regs=N, params=M[+rest]) ==
;;      0  <Op>            a=.. b=..  ; <annotation>
;;      1  <JumpOp>        a=.. -> <target>
;;   ...
;;   (blank line, then each nested proto, recursively)
;;
;; File-based, pure R7RS over (creme bytecode)'s already-exported record
;; accessors -- no FFI, no native disassembler dependency of its own.
;; ===========================================================================

(define-library (creme disassemble)
  (export disassemble-chunk disassemble-bytes)
  (import (scheme base) (scheme write) (creme bytecode)
          (only (creme extra) write-to-string))
  (begin

    ;; Ops whose `b` operand is a signed relative jump offset -- printed as an
    ;; absolute target index (i + 1 + b) instead of the raw offset. Mirrors
    ;; disassembler.cr's JUMP_OPS exactly.
    (define jump-ops
      '(Jmp TestFalse TestLt TestLe TestGt TestGe TestEq TestIsEq
        TestLtImm TestLeImm TestGtImm TestGeImm TestEqImm TestIsEqImm
        TestLtUp TestLeUp TestGtUp TestGeUp TestEqUp TestIsEqUp
        PushHandler ForPrep ForLoop
        ForLoopGuardedInc ForLoopGuardedDec TestGlobalIdentity))

    ;; op -> which operand field (a/b/c/d) is a const-pool index (annotated
    ;; with the referenced constant). Mirrors disassembler.cr's CONST_OPS.
    (define const-ops
      '((LoadK . b) (GetGlobal . b) (HelperForm . b) (HelperFormLocal . b)
        (DefGlobal . a) (SetGlobal . a) (ReturnGlobal . a) (Throw . a)
        (CaseMatch . c)
        (CallGlobal . d) (TailCallGlobal . d)
        (ForLoopGuardedInc . d) (ForLoopGuardedDec . d) (TestGlobalIdentity . a)))

    ;; Ops whose `c` is meaningful even when 0 (an argument count / width),
    ;; so it's always shown. Mirrors disassembler.cr's `c != 0 || op.in?({...})`.
    (define c-shown-ops '(Call TailCall MakeCaseClosure Destructure ParamPush))

    (define (pad-left s w)
      (let ((n (- w (string-length s))))
        (if (> n 0) (string-append (make-string n #\space) s) s)))

    (define (pad-right s w)
      (let ((n (- w (string-length s))))
        (if (> n 0) (string-append s (make-string n #\space)) s)))


    (define (instr-field instr field)
      (cond ((eq? field 'a) (instr-a instr))
            ((eq? field 'b) (instr-b instr))
            ((eq? field 'c) (instr-c instr))
            (else (instr-d instr))))

    ;; Trailing "; ..." comment resolving a const-pool reference or a Closure's
    ;; own proto -- the CaseDispatch table annotation the native disassembler
    ;; also emits is skipped here (the (creme bytecode) <chunk> record carries
    ;; no separate case-dispatch-table list to resolve against).
    (define (annotate ch instr port)
      (let ((op (instr-op instr))
            (field (assq (instr-op instr) const-ops)))
        (cond
          (field
           (let ((idx (instr-field instr (cdr field)))
                 (consts (chunk-consts ch)))
             (when (< idx (length consts))
               (display "   ; " port)
               (display (write-to-string (list-ref consts idx)) port))))
          ((and (eq? op 'Closure) (< (instr-b instr) (length (chunk-protos ch))))
           (display "   ; proto " port) (display (instr-b instr) port)
           (display " (" port)
           (display (chunk-name (list-ref (chunk-protos ch) (instr-b instr))) port)
           (display ")" port))
          (else #f))))

    (define (dis-instr ch instr i port)
      (let ((op (instr-op instr)))
        (display (pad-left (number->string i) 4) port)
        (display "  " port)
        (display (pad-right (symbol->string op) 16) port)
        (display " a=" port) (display (instr-a instr) port)
        (if (memq op jump-ops)
            (begin (display " -> " port) (display (+ i 1 (instr-b instr)) port))
            (begin (display " b=" port) (display (instr-b instr) port)))
        (when (or (not (= (instr-c instr) 0)) (memq op c-shown-ops))
          (display " c=" port) (display (instr-c instr) port))
        (when (not (= (instr-d instr) 0))
          (display " d=" port) (display (instr-d instr) port))
        (annotate ch instr port)
        (newline port)))

    (define (dis ch name port)
      (display "== " port) (display name port)
      (display " (regs=" port) (display (chunk-num-registers ch) port)
      (display ", params=" port) (display (chunk-param-count ch) port)
      (display (if (chunk-has-rest ch) "+rest" "") port)
      (display ") ==" port) (newline port)
      ;; chunk-instrs is stored in internal (reversed) order; reverse to the
      ;; forward order the indices and jump targets are numbered against.
      (let loop ((is (reverse (chunk-instrs ch))) (i 0))
        (when (pair? is)
          (dis-instr ch (car is) i port)
          (loop (cdr is) (+ i 1))))
      (let loop ((ps (chunk-protos ch)) (i 0))
        (when (pair? ps)
          (newline port)
          (dis (car ps)
               (string-append name " > proto " (number->string i)
                              " (" (chunk-name (car ps)) ")")
               port)
          (loop (cdr ps) (+ i 1)))))

    (define (opt-name rest fallback)
      (if (and (pair? rest) (car rest)) (car rest) fallback))
    (define (opt-port rest)
      (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) (current-output-port)))

    ;; (disassemble-chunk chunk [name] [port]) -- name defaults to the chunk's
    ;; own name, port to current-output-port.
    (define (disassemble-chunk ch . rest)
      (dis ch (opt-name rest (chunk-name ch)) (opt-port rest)))

    ;; (disassemble-bytes bytevector [name] [port]) -- deserialize ICE bytes
    ;; (bytes->chunk) then disassemble.
    (define (disassemble-bytes bv . rest)
      (let ((ch (bytes->chunk bv)))
        (dis ch (opt-name rest (chunk-name ch)) (opt-port rest))))))
