;; ===========================================================================
;; (creme bytecode): a Chunk assembler + SCB1 serializer for this project's
;; own register-VM bytecode format.
;;
;; File-based, no FFI of its own (same rationale as (creme peg)'s own
;; header comment) -- pure bookkeeping over lists/vectors/records, though
;; it does import (creme math) for flonum->bits/bits->flonum (an exact
;; IEEE754 bit-level reinterpret cast, added specifically so this
;; library's float serialization doesn't need its own bitwise-primitive
;; workarounds). This is
;; the "how do you actually build and emit a Chunk" layer, deliberately
;; separated from any particular source-language compiler: a chunk
;; builder (registers/scopes are NOT this library's concern -- see
;; bootstrap/compiler.scm's <fcomp> for that), a complete table of every
;; opcode this VM defines (src/scheme/compile/opcode.cr's Op enum,
;; ordinal-for-ordinal) so any of them can be emitted by name, and the
;; SCB1 byte format (src/scheme/compile/chunk_serializer.cr /
;; chunk_deserializer.cr) a chunk gets turned into so it can be run via
;; (creme bootstrap)'s load-chunk-bytes on the real Crystal VM.
;;
;; API:
;;   (make-chunk name)                 -> a fresh, empty chunk
;;   (chunk-instrs ch) / chunk-consts / chunk-protos / chunk-upvals
;;   (chunk-param-count ch) / chunk-param-count-set!
;;   (chunk-has-rest ch) / chunk-has-rest-set!
;;   (chunk-num-registers ch) / chunk-num-registers-set!
;;   (chunk-name ch) / chunk-name-set!
;;   (chunk-emit! ch op-name a b c d)   -> an opaque instr handle, for
;;                                         later chunk-patch-jump-to-here!
;;   (chunk-patch-jump-to-here! ch instr) -- backpatches a forward jump's
;;                                         offset to the chunk's CURRENT
;;                                         instruction count
;;   (chunk-add-const! ch value)       -> its index in the const pool
;;   (chunk-add-proto! ch proto-chunk) -> its index in the proto list
;;   (chunk-add-upval! ch name from-parent-local index) -> its index
;;   (chunk-find-upval-index ch name)  -> an existing upvalue's index, or #f
;;   (op-ordinal name)                 -> the opcode's raw enum ordinal
;;   (chunk->bytes ch)                 -> a bytevector: "SCB1" magic +
;;                                         an empty required-families
;;                                         section + the chunk, ready for
;;                                         (creme bootstrap)'s
;;                                         load-chunk-bytes
;;
;; FRAGILE DEPENDENCY: the op-ordinals table below must exactly match
;; src/scheme/compile/opcode.cr's Op enum declaration order -- SCB1
;; serializes the raw ordinal directly (same as ChunkSerializer does on
;; the Crystal side), so there's no separate translation table to keep
;; opcode.cr free to reorder against, unlike CVMSerializer's OP_IDS/cvm/
;; opcodes.h pair. If that enum ever gets reordered, this table must be
;; updated by hand.
;; ===========================================================================

(define-library (creme bytecode)
  (export make-chunk
          chunk-instrs chunk-consts chunk-protos chunk-upvals
          chunk-param-count chunk-param-count-set!
          chunk-has-rest chunk-has-rest-set!
          chunk-num-registers chunk-num-registers-set!
          chunk-name chunk-name-set!
          chunk-emit! chunk-patch-jump-to-here! chunk-patch-jump-to!
          chunk-add-const! chunk-add-proto! chunk-add-upval! chunk-find-upval-index
          op-ordinal
          chunk->bytes)
  (import (scheme base) (scheme cxr) (scheme inexact) (scheme complex) (creme hash-table) (creme math))
  (begin

    ;; -----------------------------------------------------------------
    ;; Chunk builder
    ;; -----------------------------------------------------------------

    (define-record-type <instr>
      (make-instr op a b c d idx)
      instr?
      (op instr-op)
      (a instr-a)
      (b instr-b instr-b-set!)
      (c instr-c)
      (d instr-d)
      (idx instr-idx))

    (define-record-type <chunk>
      (make-chunk-raw instrs consts protos upvals param-count has-rest num-registers name)
      chunk?
      (instrs chunk-instrs chunk-instrs-set!)
      (consts chunk-consts chunk-consts-set!)
      (protos chunk-protos chunk-protos-set!)
      (upvals chunk-upvals chunk-upvals-set!)
      (param-count chunk-param-count chunk-param-count-set!)
      (has-rest chunk-has-rest chunk-has-rest-set!)
      (num-registers chunk-num-registers chunk-num-registers-set!)
      (name chunk-name chunk-name-set!))

    (define (make-chunk name) (make-chunk-raw '() '() '() '() 0 #f 0 name))

    ;; Instructions are prepended (O(1)) and reversed once at
    ;; serialization; each instr records its own forward index (computed
    ;; before the cons) so jump patching works regardless of storage
    ;; order. consts/protos/upvals are kept in true forward order via
    ;; append -- smaller lists, and upvalue lookup needs a real index to
    ;; dedupe against, not just a count.
    (define (chunk-emit! ch op a b c d)
      (let* ((idx (length (chunk-instrs ch)))
             (instr (make-instr op a b c d idx)))
        (chunk-instrs-set! ch (cons instr (chunk-instrs ch)))
        instr))

    ;; Patches `instr`'s own `b` (offset) field to jump to an EXPLICIT
    ;; `target` instruction index -- forward (target > this instruction's
    ;; own idx) or backward (target <= it, a negative offset), unlike
    ;; chunk-patch-jump-to-here! below, which only ever targets the chunk's
    ;; current end. Used by a counted-loop's own ForLoop op to jump back to
    ;; its ForPrep-following body start (`target` = that index, captured via
    ;; `(length (chunk-instrs ch))` right after ForPrep was emitted).
    (define (chunk-patch-jump-to! ch instr target)
      (instr-b-set! instr (- target (+ (instr-idx instr) 1))))

    (define (chunk-patch-jump-to-here! ch instr)
      (chunk-patch-jump-to! ch instr (length (chunk-instrs ch))))

    (define (chunk-add-const! ch value)
      (let ((idx (length (chunk-consts ch))))
        (chunk-consts-set! ch (append (chunk-consts ch) (list value)))
        idx))

    (define (chunk-add-proto! ch proto)
      (let ((idx (length (chunk-protos ch))))
        (chunk-protos-set! ch (append (chunk-protos ch) (list proto)))
        idx))

    (define (chunk-add-upval! ch name from-parent-local index)
      (let ((idx (length (chunk-upvals ch))))
        (chunk-upvals-set! ch (append (chunk-upvals ch) (list (list name from-parent-local index))))
        idx))

    (define (chunk-find-upval-index ch name)
      (let loop ((us (chunk-upvals ch)) (i 0))
        (cond
          ((null? us) #f)
          ((eq? (car (car us)) name) i)
          (else (loop (cdr us) (+ i 1))))))

    ;; -----------------------------------------------------------------
    ;; The complete Op table -- every opcode src/scheme/compile/opcode.cr
    ;; defines, not just the subset any one compiler happens to emit, so
    ;; a future compiler targeting this same library can reach for any of
    ;; them (e.g. the fused/Imm/Up superinstruction families, or
    ;; ParamPush/MakePromise/HelperForm) without extending this table.
    ;; -----------------------------------------------------------------

    (define op-ordinal-table (make-hash-table))

    (for-each
      (lambda (pair) (hash-table-set! op-ordinal-table (car pair) (cadr pair)))
      (list
        (list 'LoadK 0) (list 'LoadNil 1) (list 'LoadTrue 2) (list 'LoadFalse 3)
        (list 'Move 4) (list 'GetUpval 5) (list 'SetUpval 6) (list 'GetGlobal 7)
        (list 'DefGlobal 8) (list 'SetGlobal 9)
        (list 'Add 10) (list 'Sub 11) (list 'Mul 12) (list 'NumLt 13) (list 'NumLe 14)
        (list 'NumGt 15) (list 'NumGe 16) (list 'NumEq 17) (list 'VecRef 18) (list 'VecSet 19)
        (list 'VecLen 20) (list 'StrRef 21) (list 'StrSet 22) (list 'BvRef 23) (list 'BvSet 24)
        (list 'Cons 25) (list 'Not 26) (list 'IsNull 27) (list 'IsPair 28) (list 'IsEq 29)
        (list 'Cxr 30) (list 'Abs 31) (list 'CmpZero 32)
        (list 'AddImm 33) (list 'SubImm 34) (list 'MulImm 35) (list 'NumLtImm 36) (list 'NumLeImm 37)
        (list 'NumGtImm 38) (list 'NumGeImm 39) (list 'NumEqImm 40) (list 'IsEqImm 41)
        (list 'AddUp 42) (list 'SubUp 43) (list 'MulUp 44) (list 'NumLtUp 45) (list 'NumLeUp 46)
        (list 'NumGtUp 47) (list 'NumGeUp 48) (list 'NumEqUp 49) (list 'IsEqUp 50)
        (list 'VecRefImm 51) (list 'StrRefImm 52) (list 'BvRefImm 53)
        (list 'VecSetImm 54) (list 'StrSetImm 55) (list 'BvSetImm 56)
        (list 'VecRefUp 57) (list 'VecSetUp 58) (list 'VecLenUp 59)
        (list 'StrRefUp 60) (list 'StrSetUp 61) (list 'BvRefUp 62) (list 'BvSetUp 63)
        (list 'CaseMatch 64) (list 'CaseDispatch 65) (list 'Throw 66)
        (list 'Jmp 67) (list 'TestFalse 68)
        (list 'TestLt 69) (list 'TestLe 70) (list 'TestGt 71) (list 'TestGe 72) (list 'TestEq 73) (list 'TestIsEq 74)
        (list 'TestLtImm 75) (list 'TestLeImm 76) (list 'TestGtImm 77) (list 'TestGeImm 78)
        (list 'TestEqImm 79) (list 'TestIsEqImm 80)
        (list 'TestLtUp 81) (list 'TestLeUp 82) (list 'TestGtUp 83) (list 'TestGeUp 84)
        (list 'TestEqUp 85) (list 'TestIsEqUp 86)
        (list 'Call 87) (list 'TailCall 88)
        (list 'CallGlobal 89) (list 'TailCallGlobal 90) (list 'CallLocal 91) (list 'TailCallLocal 92)
        (list 'CallUpval 93) (list 'TailCallUpval 94)
        (list 'Return 95) (list 'ReturnGlobal 96) (list 'ReturnUpval 97)
        (list 'AddReturn 98) (list 'SubReturn 99) (list 'MulReturn 100) (list 'NumLtReturn 101)
        (list 'NumLeReturn 102) (list 'NumGtReturn 103) (list 'NumGeReturn 104) (list 'NumEqReturn 105)
        (list 'IsEqReturn 106)
        (list 'Closure 107) (list 'MakeCaseClosure 108) (list 'Destructure 109)
        (list 'ParamPush 110) (list 'ParamPop 111)
        (list 'PushHandler 112) (list 'PopHandler 113) (list 'GuardReraise 114)
        (list 'Quasiquote 115) (list 'MakePromise 116)
        (list 'HelperForm 117) (list 'HelperFormLocal 118)
        (list 'ForPrep 119) (list 'ForLoop 120)
        (list 'ForLoopGuardedInc 121) (list 'ForLoopGuardedDec 122) (list 'TestGlobalIdentity 123)))

    (define (op-ordinal name)
      (if (hash-table-contains? op-ordinal-table name)
          (hash-table-ref op-ordinal-table name)
          (error "creme bytecode: unknown opcode -- op-ordinal-table out of date?" name)))

    ;; -----------------------------------------------------------------
    ;; SCB1 serialization -- see chunk_serializer.cr's own header comment
    ;; for the format this mirrors. write-datum! supports every constant
    ;; shape the real Crystal-side ChunkSerializer/ChunkDeserializer do,
    ;; including general (finite/inf/nan) floats via (creme math)'s
    ;; flonum->bits (an exact IEEE754 bit-level reinterpret, not a
    ;; numeric conversion) -- see write-float64!.
    ;; -----------------------------------------------------------------

    (define-record-type <sink>
      (make-sink-raw bytes)
      sink?
      (bytes sink-bytes sink-bytes-set!))

    (define (make-sink) (make-sink-raw '()))
    (define (sink-push-byte! sink b) (sink-bytes-set! sink (cons b (sink-bytes sink))))
    (define (sink-push-bytes! sink lst) (for-each (lambda (b) (sink-push-byte! sink b)) lst))

    (define (bv-from-list lst)
      (let* ((n (length lst)) (bv (make-bytevector n 0)))
        (let loop ((i 0) (l lst))
          (if (null? l)
              bv
              (begin (bytevector-u8-set! bv i (car l)) (loop (+ i 1) (cdr l)))))))

    (define (sink->bytevector sink) (bv-from-list (reverse (sink-bytes sink))))

    ;; A little-endian, two's-complement byte decomposition that works
    ;; for ANY value representable in `byte-count` bytes -- including
    ;; ones spanning this Scheme's own Int64 range (needed for the raw
    ;; bit patterns flonum->bits produces, which use the full 64-bit
    ;; range non-trivially, e.g. +inf.0's bits read as a huge positive
    ;; Int64). `modulo` always returns a value in [0, 256) regardless of
    ;; v's sign (its result takes the divisor's sign, and 256 is
    ;; positive); subtracting that remainder first makes the quotient
    ;; exact (no fractional part to truncate ambiguously), so this is
    ;; correct for negative v too -- unlike naively using `quotient`/
    ;; `remainder` (which truncate toward zero, not floor).
    (define (int->le-bytes v byte-count)
      (let loop ((i 0) (u v) (acc '()))
        (if (= i byte-count)
            (reverse acc)
            (let* ((b (modulo u 256)) (q (quotient (- u b) 256)))
              (loop (+ i 1) q (cons b acc))))))

    (define (i32->bytes v) (int->le-bytes v 4))
    (define (i64->bytes v) (int->le-bytes v 8))

    (define (write-i32! sink v) (sink-push-bytes! sink (i32->bytes v)))

    (define (write-string! sink s)
      (write-i32! sink (string-length s))
      (string-for-each (lambda (c) (sink-push-byte! sink (char->integer c))) s))

    (define (write-float64! sink v) (sink-push-bytes! sink (i64->bytes (flonum->bits v))))

    (define (write-datum! sink v)
      (cond
        ((and (integer? v) (exact? v)) (sink-push-byte! sink 0) (sink-push-bytes! sink (i64->bytes v)))
        ((and (real? v) (inexact? v)) (sink-push-byte! sink 1) (write-float64! sink v))
        ((and (exact? v) (rational? v) (not (integer? v)))
         (sink-push-byte! sink 2)
         (sink-push-bytes! sink (i64->bytes (numerator v)))
         (sink-push-bytes! sink (i64->bytes (denominator v))))
        ((and (complex? v) (not (real? v)))
         (sink-push-byte! sink 3)
         (write-datum! sink (real-part v))
         (write-datum! sink (imag-part v)))
        ((symbol? v) (sink-push-byte! sink 4) (write-string! sink (symbol->string v)))
        ((string? v) (sink-push-byte! sink 5) (write-string! sink v))
        ((boolean? v) (sink-push-byte! sink 6) (sink-push-byte! sink (if v 1 0)))
        ((null? v) (sink-push-byte! sink 7))
        ((char? v) (sink-push-byte! sink 8) (sink-push-bytes! sink (i64->bytes (char->integer v))))
        ((pair? v) (sink-push-byte! sink 9) (write-datum! sink (car v)) (write-datum! sink (cdr v)))
        ((vector? v)
         (sink-push-byte! sink 10)
         (write-i32! sink (vector-length v))
         (vector-for-each (lambda (x) (write-datum! sink x)) v))
        ((bytevector? v)
         (sink-push-byte! sink 11)
         (write-i32! sink (bytevector-length v))
         (let loop ((i 0))
           (if (< i (bytevector-length v))
               (begin (sink-push-byte! sink (bytevector-u8-ref v i)) (loop (+ i 1))))))
        (else (error "creme bytecode: unsupported constant/datum type for SCB1 serialization" v))))

    (define (write-chunk! sink ch)
      (let ((instrs (reverse (chunk-instrs ch))))
        (write-i32! sink (length instrs))
        (for-each
          (lambda (i)
            (write-i32! sink (op-ordinal (instr-op i)))
            (write-i32! sink (instr-a i))
            (write-i32! sink (instr-b i))
            (write-i32! sink (instr-c i))
            (write-i32! sink (instr-d i))
            (sink-push-byte! sink 0))
          instrs))
      (write-i32! sink (length (chunk-consts ch)))
      (for-each (lambda (c) (write-datum! sink c)) (chunk-consts ch))
      (write-i32! sink (length (chunk-protos ch)))
      (for-each (lambda (p) (write-chunk! sink p)) (chunk-protos ch))
      (write-i32! sink (length (chunk-upvals ch)))
      (for-each
        (lambda (u)
          (sink-push-byte! sink (if (cadr u) 1 0))
          (write-i32! sink (caddr u))
          (write-string! sink (symbol->string (car u))))
        (chunk-upvals ch))
      (write-i32! sink (chunk-param-count ch))
      (sink-push-byte! sink (if (chunk-has-rest ch) 1 0))
      (write-i32! sink (chunk-num-registers ch))
      (write-string! sink (chunk-name ch))
      (write-i32! sink 0)
      (write-i32! sink 0))

    ;; `required-families` (optional, defaults to '()): a list of plain
    ;; strings -- native (creme builtin <name>) family names the caller
    ;; already knows the chunk transitively depends on (e.g. compiler.sld's
    ;; own required-native-families-list) -- written into the
    ;; required-families section right after the SCB1 magic, so cvm's
    ;; main.c can decide which cvm_register_*_builtins functions to call
    ;; before running this chunk (see that file's own header comment on
    ;; import-gated native builtin registration). Most callers (bytecode_
    ;; spec.scm's own direct chunk->bytes tests, spec-helper.sld's native-
    ;; eval, run-compiled-forms! above) don't pass this at all and get the
    ;; prior empty-list behavior unchanged.
    (define (chunk->bytes ch . opts)
      (let ((required-families (if (pair? opts) (car opts) '()))
            (sink (make-sink)))
        (sink-push-bytes! sink (map char->integer (string->list "SCB1")))
        ;; Format-version byte, right after the magic -- mirrors
        ;; chunk_serializer.cr's own FORMAT_VERSION exactly (same
        ;; numeric value, bumped in lockstep whenever either writer's
        ;; on-disk chunk layout changes in a way an older reader
        ;; couldn't safely parse). See that constant's own doc comment
        ;; for the compatibility policy this exists to support.
        (sink-push-byte! sink 1)
        (write-i32! sink (length required-families))
        (for-each (lambda (name) (write-string! sink name)) required-families)
        (write-chunk! sink ch)
        (sink->bytevector sink)))))
