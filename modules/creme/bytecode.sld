;; ===========================================================================
;; (creme bytecode): a Chunk assembler + ICE serializer for this project's
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
;; opcode this VM defines (src/creme/compile/opcode.cr's Op enum,
;; ordinal-for-ordinal) so any of them can be emitted by name, and the
;; ICE byte format (src/creme/compile/chunk_serializer.cr /
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
;;   (chunk->bytes ch)                 -> a bytevector: "ICE" magic +
;;                                         an empty required-families
;;                                         section + the chunk, ready for
;;                                         (creme bootstrap)'s
;;                                         load-chunk-bytes
;;
;; FRAGILE DEPENDENCY: the op-ordinals table below must exactly match
;; src/creme/compile/opcode.cr's Op enum declaration order -- ICE
;; serializes the raw ordinal directly (same as ChunkSerializer does on
;; the Crystal side), so there's no separate translation table to keep
;; opcode.cr free to reorder against, unlike CVMSerializer's OP_IDS/icecreme/
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
          instr? instr-op instr-a instr-b instr-c instr-d instr-idx instr-pos
          set-emit-pos! clear-emit-pos!
          op-ordinal op-name
          chunk->bytes bytes->chunk ice-bytes?
          strip-dead-globals!)
  (import (scheme base) (scheme cxr) (scheme inexact) (scheme complex) (creme hash-table) (creme math)
          (only (creme bytes) list->bytevector)
          ;; The ICE container is zstd-compressed (see chunk->bytes/bytes->chunk).
          ;; (creme zstd) exports these names and defines no records, so it's safe
          ;; to bake into the self-hosted compiler image.
          (only (creme zstd) zstd-compress zstd-decompress))
  (begin

    ;; -----------------------------------------------------------------
    ;; Chunk builder
    ;; -----------------------------------------------------------------

    (define-record-type <instr>
      (make-instr op a b c d idx pos)
      instr?
      (op instr-op)
      (a instr-a)
      (b instr-b instr-b-set!)
      (c instr-c)
      (d instr-d)
      (idx instr-idx)
      ;; #f, or a (file line col) source position stamped by chunk-emit! from
      ;; current-emit-pos (set by the compiler as it descends each form). Written
      ;; into ICE per-instruction exactly like native's ChunkSerializer, so a
      ;; runtime error / --profile report can name the source line -- see
      ;; write-chunk! below and current-emit-pos.
      (pos instr-pos))

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

    ;; The source position (a (file line col) list, or #f) that chunk-emit!
    ;; stamps on every instruction it creates. The compiler sets it via
    ;; set-emit-pos! as it enters each form (from the reader's per-form position
    ;; table) and clears it with clear-emit-pos!; a builder that never sets it
    ;; (e.g. a hand-assembled chunk, or the compiler before this was wired) gets
    ;; #f on every instruction, i.e. the prior position-less behavior.
    (define current-emit-pos #f)
    (define (set-emit-pos! file line col) (set! current-emit-pos (list file line col)))
    (define (clear-emit-pos!) (set! current-emit-pos #f))

    ;; Instructions are prepended (O(1)) and reversed once at
    ;; serialization; each instr records its own forward index (computed
    ;; before the cons) so jump patching works regardless of storage
    ;; order. consts/protos/upvals are kept in true forward order via
    ;; append -- smaller lists, and upvalue lookup needs a real index to
    ;; dedupe against, not just a count.
    (define (chunk-emit! ch op a b c d)
      (let* ((idx (length (chunk-instrs ch)))
             (instr (make-instr op a b c d idx current-emit-pos)))
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
    ;; The complete Op table -- every opcode src/creme/compile/opcode.cr
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

    ;; Reverse of op-ordinal-table (ordinal -> name), for bytes->chunk below:
    ;; ICE stores the raw enum ordinal, so deserialization has to map each
    ;; back to its symbolic op name. Built once by walking the same table
    ;; op-ordinal reads, so the two can never drift apart (same FRAGILE
    ;; DEPENDENCY on opcode.cr's enum order as the writer -- see this file's
    ;; own header comment).
    (define op-name-table
      (let ((t (make-hash-table)))
        (for-each
          (lambda (name) (hash-table-set! t (hash-table-ref op-ordinal-table name) name))
          (hash-table-keys op-ordinal-table))
        t))

    (define (op-name ordinal)
      (if (hash-table-contains? op-name-table ordinal)
          (hash-table-ref op-name-table ordinal)
          (error "creme bytecode: unknown opcode ordinal -- op-ordinal-table out of date?" ordinal)))

    ;; -----------------------------------------------------------------
    ;; ICE serialization -- see chunk_serializer.cr's own header comment
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

    (define (sink->bytevector sink) (list->bytevector (reverse (sink-bytes sink))))

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

    ;; A raw, length-prefixed string -- now used ONLY to write the entries of
    ;; the global string pool (see chunk->bytes). Every other string/symbol
    ;; in the format is written as a u24 index into that pool instead.
    (define (write-pool-string! sink s)
      (write-i32! sink (string-length s))
      (string-for-each (lambda (c) (sink-push-byte! sink (char->integer c))) s))

    ;; Little-endian unsigned 24-/16-bit writes: pool indices and the narrow
    ;; position fields (file-index/line as u24, col as u16). v must be >= 0.
    (define (write-u24! sink v)
      (sink-push-byte! sink (modulo v 256))
      (sink-push-byte! sink (modulo (quotient v 256) 256))
      (sink-push-byte! sink (modulo (quotient v 65536) 256)))
    (define (write-u16! sink v)
      (sink-push-byte! sink (modulo v 256))
      (sink-push-byte! sink (modulo (quotient v 256) 256)))
    (define (clamp-u24 v) (cond ((< v 0) 0) ((> v #xffffff) #xffffff) (else v)))
    (define (clamp-u16 v) (cond ((< v 0) 0) ((> v #xffff) #xffff) (else v)))

    ;; String-pool interner for the WRITE side. `intern!` assigns a fresh index
    ;; on first sight (keeping `items` in reversed first-seen order); `id` looks
    ;; one up during the write pass. Keys are strings, compared by content
    ;; (make-hash-table is equal?-keyed on both backends), so distinct symbol/
    ;; string occurrences of the same characters collapse to one pool entry.
    (define-record-type <interner>
      (make-interner-raw table items count)
      interner?
      (table interner-table)
      (items interner-items interner-items-set!)
      (count interner-count interner-count-set!))
    (define (make-interner) (make-interner-raw (make-hash-table) '() 0))
    (define (interner-intern! in s)
      (let ((tbl (interner-table in)))
        (if (hash-table-contains? tbl s)
            (hash-table-ref tbl s)
            (let ((i (interner-count in)))
              (hash-table-set! tbl s i)
              (interner-items-set! in (cons s (interner-items in)))
              (interner-count-set! in (+ i 1))
              i))))
    (define (interner-id in s) (hash-table-ref (interner-table in) s))
    (define (interner-strings in) (reverse (interner-items in)))
    ;; Write a string/symbol as its u24 pool index (interned during pass 1).
    (define (write-str-ref! sink pool s) (write-u24! sink (interner-id pool s)))

    (define (write-float64! sink v) (sink-push-bytes! sink (i64->bytes (flonum->bits v))))

    ;; Pass 1 of serialization: intern every string/symbol a const datum
    ;; references, mirroring write-datum!'s own structure (symbols, strings,
    ;; and the pairs/vectors/complex they nest inside). Numbers/bools/chars/
    ;; bytevectors carry no strings. Like write-datum! itself, this assumes
    ;; acyclic const data (the compiler never emits a cyclic literal).
    (define (collect-datum-strings! pool v)
      (cond
        ((symbol? v) (interner-intern! pool (symbol->string v)))
        ((string? v) (interner-intern! pool v))
        ((and (complex? v) (not (real? v)))
         (collect-datum-strings! pool (real-part v))
         (collect-datum-strings! pool (imag-part v)))
        ((pair? v)
         (collect-datum-strings! pool (car v))
         (collect-datum-strings! pool (cdr v)))
        ((vector? v)
         (vector-for-each (lambda (x) (collect-datum-strings! pool x)) v))
        (else #f)))

    ;; Pass 1, chunk level: walk the whole chunk tree exactly as write-chunk!
    ;; does, interning the source-position file of every positioned instruction,
    ;; every const's strings, every upvalue name, and the chunk name -- for the
    ;; root and (recursively) every proto. write-chunk! emits no qq-template /
    ;; case-dispatch sections (it writes 0/0), so there's nothing to collect there.
    (define (collect-chunk-strings! pool ch)
      (for-each
        (lambda (i) (let ((pos (instr-pos i))) (if pos (interner-intern! pool (car pos)))))
        (chunk-instrs ch))
      (for-each (lambda (c) (collect-datum-strings! pool c)) (chunk-consts ch))
      (for-each (lambda (p) (collect-chunk-strings! pool p)) (chunk-protos ch))
      (for-each (lambda (u) (interner-intern! pool (symbol->string (car u)))) (chunk-upvals ch))
      (interner-intern! pool (chunk-name ch)))

    (define (write-datum! sink pool v)
      (cond
        ((and (integer? v) (exact? v)) (sink-push-byte! sink 0) (sink-push-bytes! sink (i64->bytes v)))
        ((and (real? v) (inexact? v)) (sink-push-byte! sink 1) (write-float64! sink v))
        ((and (exact? v) (rational? v) (not (integer? v)))
         (sink-push-byte! sink 2)
         (sink-push-bytes! sink (i64->bytes (numerator v)))
         (sink-push-bytes! sink (i64->bytes (denominator v))))
        ((and (complex? v) (not (real? v)))
         (sink-push-byte! sink 3)
         (write-datum! sink pool (real-part v))
         (write-datum! sink pool (imag-part v)))
        ((symbol? v) (sink-push-byte! sink 4) (write-str-ref! sink pool (symbol->string v)))
        ((string? v) (sink-push-byte! sink 5) (write-str-ref! sink pool v))
        ((boolean? v) (sink-push-byte! sink 6) (sink-push-byte! sink (if v 1 0)))
        ((null? v) (sink-push-byte! sink 7))
        ((char? v) (sink-push-byte! sink 8) (sink-push-bytes! sink (i64->bytes (char->integer v))))
        ((pair? v) (sink-push-byte! sink 9) (write-datum! sink pool (car v)) (write-datum! sink pool (cdr v)))
        ((vector? v)
         (sink-push-byte! sink 10)
         (write-i32! sink (vector-length v))
         (vector-for-each (lambda (x) (write-datum! sink pool x)) v))
        ((bytevector? v)
         (sink-push-byte! sink 11)
         (write-i32! sink (bytevector-length v))
         (let loop ((i 0))
           (if (< i (bytevector-length v))
               (begin (sink-push-byte! sink (bytevector-u8-ref v i)) (loop (+ i 1))))))
        (else (error "creme bytecode: unsupported constant/datum type for ICE serialization" v))))

    (define (write-chunk! sink pool ch)
      (let ((instrs (reverse (chunk-instrs ch)))
            (last-pos #f))
        (write-i32! sink (length instrs))
        (for-each
          (lambda (i)
            (write-i32! sink (op-ordinal (instr-op i)))
            (write-i32! sink (instr-a i))
            (write-i32! sink (instr-b i))
            (write-i32! sink (instr-c i))
            (write-i32! sink (instr-d i))
            ;; Source-position record: a presence byte, and when set, the
            ;; (file line col) -- ChunkSerializer's own per-instruction layout.
            ;; Emitted only when the position CHANGES from the previous
            ;; instruction (byte 0 = "same as previous"); the loader carries the
            ;; last one forward (icecreme/loader.c). A run of instructions from
            ;; one source form thus stores its position once, not on every
            ;; instruction -- the sparse encoding native emits too.
            (let ((pos (instr-pos i)))
              (if (and pos (not (equal? pos last-pos)))
                  (begin
                    (set! last-pos pos)
                    (sink-push-byte! sink 1)
                    (write-str-ref! sink pool (car pos))
                    (write-u24! sink (clamp-u24 (cadr pos)))
                    (write-u16! sink (clamp-u16 (caddr pos))))
                  (sink-push-byte! sink 0))))
          instrs))
      (write-i32! sink (length (chunk-consts ch)))
      (for-each (lambda (c) (write-datum! sink pool c)) (chunk-consts ch))
      (write-i32! sink (length (chunk-protos ch)))
      (for-each (lambda (p) (write-chunk! sink pool p)) (chunk-protos ch))
      (write-i32! sink (length (chunk-upvals ch)))
      (for-each
        (lambda (u)
          (sink-push-byte! sink (if (cadr u) 1 0))
          (write-i32! sink (caddr u))
          (write-str-ref! sink pool (symbol->string (car u))))
        (chunk-upvals ch))
      (write-i32! sink (chunk-param-count ch))
      (sink-push-byte! sink (if (chunk-has-rest ch) 1 0))
      (write-i32! sink (chunk-num-registers ch))
      (write-str-ref! sink pool (chunk-name ch))
      (write-i32! sink 0)
      (write-i32! sink 0))

    ;; `required-families` (optional, defaults to '()): a list of plain
    ;; strings -- native (creme builtin <name>) family names the caller
    ;; already knows the chunk transitively depends on (e.g. compiler.sld's
    ;; own required-native-families-list) -- written into the
    ;; required-families section right after the ICE magic, so icecreme's
    ;; main.c can decide which creme_register_*_builtins functions to call
    ;; before running this chunk (see that file's own header comment on
    ;; import-gated native builtin registration). Most callers (bytecode_
    ;; spec.scm's own direct chunk->bytes tests, spec-helper.sld's native-
    ;; eval, run-compiled-forms! above) don't pass this at all and get the
    ;; prior empty-list behavior unchanged.
    ;; Is `s` (a byte-preserving string, e.g. a file's raw contents) an ICE
    ;; bytecode blob rather than .scm source? Recognized by the 4-byte magic
    ;; "ICE" + one ASCII version digit (see chunk->bytes / bytes->chunk); the
    ;; loader enforces the exact version, so this only needs to tell a compiled
    ;; chunk from source, version-agnostically. (No valid Scheme source starts
    ;; with "ICE" + a digit at byte 0.)
    (define (ice-bytes? s)
      (and (>= (string-length s) 4)
           (string=? (substring s 0 3) "ICE")
           (char<=? #\0 (string-ref s 3) #\9)))  ; digit; char<=? is (scheme base)

    (define (chunk->bytes ch . opts)
      (let ((required-families (if (pair? opts) (car opts) '()))
            (sink (make-sink))
            (pool (make-interner)))
        ;; Pass 1: intern every string/symbol referenced anywhere in the
        ;; chunk tree (and the required-family names) into the global pool.
        (for-each (lambda (name) (interner-intern! pool name)) required-families)
        (collect-chunk-strings! pool ch)
        ;; Pass 2: build the BODY into the sink -- the global string pool (count,
        ;; then each raw entry), then the required-families as u24 pool indices,
        ;; then the chunk itself with every inline string a u24 pool index. No
        ;; magic in the body.
        (let ((strings (interner-strings pool)))
          (write-i32! sink (length strings))
          (for-each (lambda (s) (write-pool-string! sink s)) strings))
        (write-i32! sink (length required-families))
        (for-each (lambda (name) (write-str-ref! sink pool name)) required-families)
        (write-chunk! sink pool ch)
        ;; The file is the plaintext 4-byte magic "ICE" + the ASCII format-version
        ;; digit ("ICE1"), followed by a single zstd frame of the body. The body
        ;; compresses ~6x; zstd is now a required dependency of every backend, and
        ;; chunk_serializer.cr / loader.c / this writer+reader move in lockstep
        ;; (see loader.c's own format-version comment). Level 19 is deterministic
        ;; for a given libzstd, so the self-hosting fixpoint still holds.
        (bytevector-append (list->bytevector (map char->integer (string->list "ICE1")))
                           (zstd-compress (sink->bytevector sink) 19))))

    ;; -----------------------------------------------------------------
    ;; ICE deserialization -- the exact inverse of chunk->bytes /
    ;; write-chunk! / write-datum! above, reconstructing a <chunk> record
    ;; (with symbolic op names, via op-name) from its serialized bytes. The
    ;; native VM (icecreme's C loader, or Crystal's ChunkDeserializer) is what
    ;; actually RUNS these bytes; this reader exists so pure-Scheme tooling --
    ;; e.g. (creme disassemble) backing `icecreme --disassemble <file.ice>` --
    ;; can inspect an already-compiled chunk without a native round-trip. Same
    ;; FRAGILE DEPENDENCY on opcode.cr's enum order as the writer (see this
    ;; file's own header comment): op-name reverses op-ordinal-table.
    ;; -----------------------------------------------------------------

    (define-record-type <source>
      (make-source-raw bytes pos)
      source?
      (bytes source-bytes)
      (pos source-pos source-pos-set!))

    (define (make-source bv) (make-source-raw bv 0))

    (define (read-byte! src)
      (let ((p (source-pos src)))
        (source-pos-set! src (+ p 1))
        (bytevector-u8-ref (source-bytes src) p)))

    ;; Signed little-endian read of `n` bytes (two's complement) -- the inverse
    ;; of int->le-bytes. The MOST-SIGNIFICANT byte is folded in as SIGNED (b-256
    ;; when its high bit is set), rather than assembling the unsigned value and
    ;; correcting afterwards, so no intermediate ever reaches the 2^(8n) unsigned
    ;; scale: every partial product stays within [-2^63, 2^63-1]. That matters
    ;; because reading a full 64-bit value whose top bit is set -- a negative
    ;; i64, or the raw bit pattern of a negative/large flonum (write-float64!) --
    ;; would otherwise form a ~2^64 quantity, and icecreme's fixnums do NOT
    ;; promote to bignum (only rationals use GMP), so the whole read would abort
    ;; with "integer overflow" even though the final signed i64 fits. (Under a
    ;; bignum host like native/Crystal the old unsigned form worked; this keeps
    ;; both, and is what lets `icecreme --disassemble` handle a chunk carrying a
    ;; negative float or large integer constant.)
    (define (read-signed! src n)
      (let loop ((i 0) (acc 0) (mul 1))
        (let ((b (read-byte! src)))
          (if (= i (- n 1))
              (+ acc (* (if (>= b 128) (- b 256) b) mul))
              (loop (+ i 1) (+ acc (* b mul)) (* mul 256))))))

    (define (read-i32! src) (read-signed! src 4))
    (define (read-i64! src) (read-signed! src 8))

    ;; Unsigned little-endian 24-/16-bit reads (pool indices, position fields).
    ;; Always small and non-negative, so no overflow concern (unlike read-signed!).
    (define (read-u24! src)
      (let* ((b0 (read-byte! src)) (b1 (read-byte! src)) (b2 (read-byte! src)))
        (+ b0 (* b1 256) (* b2 65536))))
    (define (read-u16! src)
      (let* ((b0 (read-byte! src)) (b1 (read-byte! src)))
        (+ b0 (* b1 256))))

    ;; A raw, length-prefixed string -- now used ONLY to read the entries of the
    ;; global string pool. Everywhere else a string is a u24 index into the pool
    ;; vector (see read-str-ref! and bytes->chunk).
    (define (read-pool-string! src)
      (let ((len (read-i32! src)))
        (let loop ((i 0) (acc '()))
          (if (= i len)
              (list->string (reverse acc))
              (loop (+ i 1) (cons (integer->char (read-byte! src)) acc))))))

    ;; Reads the global string pool into a vector for O(1) index lookup.
    (define (read-string-pool! src)
      (let* ((n (read-i32! src)) (v (make-vector n "")))
        (let loop ((i 0))
          (if (= i n) v (begin (vector-set! v i (read-pool-string! src)) (loop (+ i 1)))))))

    ;; A string/symbol reference: a u24 index into the already-read pool vector.
    (define (read-str-ref! pool src) (vector-ref pool (read-u24! src)))

    (define (read-float64! src) (bits->flonum (read-i64! src)))

    ;; One top-level datum (a const, or a QQ_CONST literal). Datum labels
    ;; (TAG_LABEL_DEF/REF, R7RS #n=/#n#) are scoped to this outermost datum, so
    ;; a fresh label table per call -- see chunk_serializer.cr's write_datum.
    (define (read-datum! pool src) (read-datum-rec! pool src (make-hash-table)))

    (define (read-datum-rec! pool src labels)
      (let ((tag (read-byte! src)))
        (cond
          ;; TAG_LABEL_DEF: a label prefix on a value that may be referenced
          ;; again; the value's own ordinary encoding follows. Recorded AFTER
          ;; its contents are read, so a genuine self-referential cycle (a REF
          ;; to this label from inside its own contents) resolves to the
          ;; placeholder below rather than looping -- disassembly only needs to
          ;; stay byte-aligned and print something, not reconstruct the cycle.
          ((= tag 13)
           (let ((label (read-i32! src)))
             (let ((v (read-datum-rec! pool src labels)))
               (hash-table-set! labels label v)
               v)))
          ((= tag 14)
           (let ((label (read-i32! src)))
             (if (hash-table-contains? labels label)
                 (hash-table-ref labels label)
                 'creme-disassemble-unresolved-cycle)))
          ((= tag 0) (read-i64! src))
          ((= tag 1) (read-float64! src))
          ((= tag 2) (let* ((n (read-i64! src)) (d (read-i64! src))) (/ n d)))
          ((= tag 3) (let* ((r (read-datum-rec! pool src labels)) (i (read-datum-rec! pool src labels))) (make-rectangular r i)))
          ((= tag 4) (string->symbol (read-str-ref! pool src)))
          ((= tag 5) (read-str-ref! pool src))
          ((= tag 6) (not (= (read-byte! src) 0)))
          ((= tag 7) '())
          ((= tag 8) (integer->char (read-i64! src)))
          ((= tag 9) (let* ((a (read-datum-rec! pool src labels)) (d (read-datum-rec! pool src labels))) (cons a d)))
          ((= tag 10)
           (let* ((len (read-i32! src)) (v (make-vector len 0)))
             (let loop ((i 0))
               (if (= i len) v (begin (vector-set! v i (read-datum-rec! pool src labels)) (loop (+ i 1)))))))
          ((= tag 11)
           (let* ((len (read-i32! src)) (bv (make-bytevector len 0)))
             (let loop ((i 0))
               (if (= i len) bv (begin (bytevector-u8-set! bv i (read-byte! src)) (loop (+ i 1)))))))
          ;; TAG_BUILTIN: a native procedure const, carried only by its name --
          ;; surfaced as that name symbol (enough for a disassembly annotation).
          ((= tag 12) (string->symbol (read-str-ref! pool src)))
          (else (error "creme bytecode: unknown datum tag in ICE stream" tag)))))

    ;; Quasiquote templates and case-dispatch tables are serialized after a
    ;; chunk's name (see chunk_serializer.cr's write_chunk). The self-hosted
    ;; writer emits empty sections (counts 0), but a native-emitted chunk can
    ;; carry real ones -- read PAST them so instruction/const parsing of the
    ;; rest of the file (and of following protos) stays aligned. Nothing in a
    ;; disassembly listing needs their contents, so this only advances the
    ;; cursor, it doesn't build them.
    (define (skip-qq-template! pool src)
      (let ((tag (read-byte! src)))
        (cond
          ((= tag 0) (read-datum! pool src))            ; QQ_CONST
          ((= tag 1) #t)                                 ; QQ_HOLE
          ((= tag 2) #t)                                 ; QQ_SPLICE
          ((= tag 3)                                     ; QQ_LIST: items + tail
           (let ((n (read-i32! src)))
             (let loop ((k 0)) (when (< k n) (skip-qq-template! pool src) (loop (+ k 1)))))
           (skip-qq-template! pool src))
          ((= tag 4)                                     ; QQ_VECTOR: items
           (let ((n (read-i32! src)))
             (let loop ((k 0)) (when (< k n) (skip-qq-template! pool src) (loop (+ k 1))))))
          (else (error "creme bytecode: unknown qq-template tag in ICE stream" tag)))))

    (define (skip-case-table! pool src)
      (read-i32! src)                                    ; default target
      (let ((n (read-i32! src)))                          ; number of keyed targets
        (let loop ((k 0))
          (when (< k n)
            (let ((kt (read-byte! src)))
              (cond
                ((= kt 0) (read-i64! src))               ; CDK_INT
                ((= kt 1) (read-i64! src))               ; CDK_CHAR
                ((= kt 2) (read-str-ref! pool src))      ; CDK_SYM
                ((= kt 3) (read-i64! src))               ; CDK_BOOL
                ((= kt 4) #t)                            ; CDK_NIL
                (else (error "creme bytecode: unknown case-dispatch-key tag in ICE stream" kt))))
            (read-i32! src)                              ; this key's target
            (loop (+ k 1))))))

    (define (read-n! src n reader)
      (let loop ((i 0) (acc '()))
        (if (= i n) (reverse acc) (loop (+ i 1) (cons (reader i) acc)))))

    ;; One instruction: 5 i32 operands, then a source-position record -- a
    ;; presence byte, and when set, a (file line col) triple. Read back into the
    ;; instr's own pos field (round-trip-preserving); a disassembly listing
    ;; doesn't display it, but keeping it means bytes->chunk -> chunk->bytes is
    ;; faithful.
    (define (read-instr! pool src i)
      (let* ((op (op-name (read-i32! src)))
             (a (read-i32! src)) (b (read-i32! src))
             (c (read-i32! src)) (d (read-i32! src))
             (pos (if (= (read-byte! src) 0)
                      #f
                      (let* ((file (read-str-ref! pool src))
                             (line (read-u24! src))
                             (col (read-u16! src)))
                        (list file line col)))))
        (make-instr op a b c d i pos)))

    (define (read-chunk! pool src)
      (let* ((n-instrs (read-i32! src))
             (instrs (read-n! src n-instrs (lambda (i) (read-instr! pool src i))))
             (n-consts (read-i32! src))
             (consts (read-n! src n-consts (lambda (i) (read-datum! pool src))))
             (n-protos (read-i32! src))
             (protos (read-n! src n-protos (lambda (i) (read-chunk! pool src))))
             (n-upvals (read-i32! src))
             (upvals (read-n! src n-upvals
                       (lambda (i)
                         (let* ((from-parent (not (= (read-byte! src) 0)))
                                (index (read-i32! src))
                                (name (string->symbol (read-str-ref! pool src))))
                           (list name from-parent index)))))
             (param-count (read-i32! src))
             (has-rest (not (= (read-byte! src) 0)))
             (num-registers (read-i32! src))
             (name (read-str-ref! pool src))
             (n-qq (read-i32! src)))
        (let loop ((k 0)) (when (< k n-qq) (skip-qq-template! pool src) (loop (+ k 1))))
        (let ((n-case (read-i32! src)))
          (let loop ((k 0)) (when (< k n-case) (skip-case-table! pool src) (loop (+ k 1)))))
        ;; <chunk> stores instrs in the INTERNAL reversed order (chunk-emit!
        ;; prepends, write-chunk! reverses at serialize time), so store the
        ;; reverse of the forward list just read.
        (make-chunk-raw (reverse instrs) consts protos upvals
                        param-count has-rest num-registers name)))

    (define (bytes->chunk bv)
      ;; Magic is the plaintext "ICE" + the ASCII format-version digit (the 4th
      ;; byte both identifies the format and carries its version). Everything
      ;; after it is a zstd frame of the body (see chunk->bytes) -- verify the
      ;; magic on the raw bytevector, then decompress and read the body. A stale
      ;; UNcompressed body fails cleanly in zstd-decompress.
      (if (not (and (>= (bytevector-length bv) 4)
                    (= (bytevector-u8-ref bv 0) (char->integer #\I))
                    (= (bytevector-u8-ref bv 1) (char->integer #\C))
                    (= (bytevector-u8-ref bv 2) (char->integer #\E))
                    (= (bytevector-u8-ref bv 3) (char->integer #\1))))
          (error "creme bytecode: not an ICE1 bytevector (bad magic / unsupported format version)"))
      (let ((src (make-source (zstd-decompress (bytevector-copy bv 4)))))
        (let ((pool (read-string-pool! src)))  ; global string pool, first
          (let ((n-fam (read-i32! src)))        ; skip the required-families section
            (let loop ((i 0))
              (when (< i n-fam) (read-u24! src) (loop (+ i 1)))))
          (read-chunk! pool src))))

    ;; ---- dead-global elimination (opt-in --strip) ----------------------
    ;; Guts every top-level (define name <lambda>) whose global `name` is never
    ;; reachable from the program's live code, replacing that function's proto
    ;; with an empty stub. Runs on the COMPILED chunk (post-macro-expansion, so
    ;; global references are concrete GetGlobal/CallGlobal operands -> sound).
    ;; It only ever EMPTIES a proto IN PLACE -- never removes/reorders protos,
    ;; consts, or instructions -- so there is no index/jump renumbering and the
    ;; chunk stays structurally valid. Assumes a closed world (no eval/dynamic
    ;; global lookup), hence opt-in. Mutates `root` and returns it.

    ;; op -> which operand field names a GLOBAL (a const-pool symbol). Exactly
    ;; loader.c's resolve_globals set (the authoritative global-name operands).
    (define strip-global-op-field
      '((GetGlobal . b) (DefGlobal . a) (SetGlobal . a) (ReturnGlobal . a)
        (CallGlobal . d) (TailCallGlobal . d)
        (ForLoopGuardedInc . d) (ForLoopGuardedDec . d) (TestGlobalIdentity . a)))

    (define (strip-instr-field ins field)
      (cond ((eq? field 'a) (instr-a ins)) ((eq? field 'b) (instr-b ins))
            ((eq? field 'c) (instr-c ins)) (else (instr-d ins))))

    ;; Every symbol in a raw form (a HelperForm payload), conservatively a ref.
    (define (strip-collect-symbols! v add!)
      (cond ((symbol? v) (add! v))
            ((pair? v) (strip-collect-symbols! (car v) add!)
                       (strip-collect-symbols! (cdr v) add!))
            ((vector? v)
             (let loop ((i 0))
               (when (< i (vector-length v))
                 (strip-collect-symbols! (vector-ref v i) add!) (loop (+ i 1)))))))

    ;; Add every global NAME referenced anywhere in `proto` (recursively through
    ;; nested protos) via `add!`.
    (define (strip-collect-proto-globals! proto add!)
      (let ((consts (list->vector (chunk-consts proto))))
        (for-each
          (lambda (ins)
            (let* ((op (instr-op ins)) (fp (assq op strip-global-op-field)))
              (cond
                (fp (add! (vector-ref consts (strip-instr-field ins (cdr fp)))))
                ((or (eq? op 'HelperForm) (eq? op 'HelperFormLocal))
                 (strip-collect-symbols! (vector-ref consts (instr-b ins)) add!)))))
          (chunk-instrs proto)))
      (for-each (lambda (p) (strip-collect-proto-globals! p add!)) (chunk-protos proto)))

    (define (strip-empty-proto! p)
      ;; forward body [LoadNil r0; Return r0]; stored reversed (see chunk-emit!).
      (chunk-instrs-set! p (list (make-instr 'Return 0 0 0 0 1 #f)
                                 (make-instr 'LoadNil 0 0 0 0 0 #f)))
      (chunk-consts-set! p '())
      (chunk-protos-set! p '())
      (chunk-upvals-set! p '()))

    (define (strip-dead-globals! root)
      (let* ((instrs (list->vector (reverse (chunk-instrs root))))
             (consts (list->vector (chunk-consts root)))
             (protos (list->vector (chunk-protos root)))
             (n (vector-length instrs))
             (live (make-hash-table))         ; global name -> #t
             (cand-proto? (make-hash-table))  ; top-level proto idx -> #t
             (name->proto (make-hash-table))  ; candidate name -> proto idx
             (roots '()))
        (define (mark-root! name) (set! roots (cons name roots)))
        ;; 1. Candidate function-defines: Closure r P ; DefGlobal nameC r.
        (let loop ((i 0))
          (when (< i (- n 1))
            (let ((a (vector-ref instrs i)) (b (vector-ref instrs (+ i 1))))
              (when (and (eq? (instr-op a) 'Closure)
                         (eq? (instr-op b) 'DefGlobal)
                         (= (instr-a a) (instr-b b)))
                (let ((name (vector-ref consts (instr-a b)))
                      (pidx (instr-b a)))
                  (hash-table-set! cand-proto? pidx #t)
                  (hash-table-set! name->proto name pidx))))
            (loop (+ i 1))))
        ;; 2. Roots from top-level instrs: every global reference that is NOT a
        ;;    DefGlobal define, plus every symbol in a HelperForm payload.
        (let loop ((i 0))
          (when (< i n)
            (let* ((ins (vector-ref instrs i)) (op (instr-op ins))
                   (fp (assq op strip-global-op-field)))
              (cond
                ((eq? op 'DefGlobal) #t)  ; a definition, not a reference
                (fp (mark-root! (vector-ref consts (strip-instr-field ins (cdr fp)))))
                ((or (eq? op 'HelperForm) (eq? op 'HelperFormLocal))
                 (strip-collect-symbols! (vector-ref consts (instr-b ins)) mark-root!))))
            (loop (+ i 1))))
        ;; 3. Roots from every top-level proto that is NOT a candidate body
        ;;    (inline lambdas / other live code that always runs).
        (let loop ((p 0))
          (when (< p (vector-length protos))
            (unless (hash-table-contains? cand-proto? p)
              (strip-collect-proto-globals! (vector-ref protos p) mark-root!))
            (loop (+ p 1))))
        ;; 4. Transitive closure over candidate references.
        (let bfs ((work roots))
          (when (pair? work)
            (let ((name (car work)) (rest (cdr work)))
              (if (and (hash-table-contains? name->proto name)
                       (not (hash-table-contains? live name)))
                  (let ((body-refs '()))
                    (hash-table-set! live name #t)
                    (strip-collect-proto-globals!
                      (vector-ref protos (hash-table-ref name->proto name))
                      (lambda (g) (set! body-refs (cons g body-refs))))
                    (bfs (append body-refs rest)))
                  (bfs rest)))))
        ;; 5. Empty every candidate proto whose name never became live.
        (for-each
          (lambda (name)
            (unless (hash-table-contains? live name)
              (strip-empty-proto! (vector-ref protos (hash-table-ref name->proto name)))))
          (hash-table-keys name->proto))
        root))))
