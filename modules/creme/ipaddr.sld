;; ===========================================================================
;; (creme ipaddr): IPv4/IPv6 address parsing, formatting, and CIDR math,
;; matching Ruby's IPAddr
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme pathname)/(creme abbrev) use). Pure R7RS: no new builtins on
;; either backend. Ruby's IPAddr needs no raw sockets or DNS -- it's just
;; string parsing/formatting plus integer arithmetic on the address --
;; and since IPv4/IPv6 CIDR masks are always contiguous from the MSB, all
;; the network math below is plain quotient/remainder/expt, never
;; bitwise-and/or/shift (creme has none of those anywhere, on either
;; backend, and none are needed here).
;;
;; An address is stored NOT as one combined integer but as a list of
;; per-group values, most-significant-group first (4 groups of 0..255
;; for ipv4, 8 groups of 0..65535 for ipv6) -- this interpreter's plain
;; integers are fixnums that overflow past roughly 2^62 rather than
;; auto-promoting to a bignum (confirmed directly: (expt 2 100) already
;; raises "integer overflow"; only (creme bigdecimal)'s own boxed type
;; gets arbitrary precision), so a single flat integer can't safely hold
;; a full 128-bit IPv6 address. Every group value here is always well
;; under 2^16, so every arithmetic step (quotient/remainder/*/+/- by a
;; per-group modulus of 256 or 65536) stays far inside fixnum range no
;; matter which family is in play.
;;
;; An <ipaddr> record wraps a family symbol ('ipv4 or 'ipv6), that groups
;; list, and a CIDR prefix length (defaults to the full address width --
;; a bare host address, not a network).
;;
;;   (make-ipaddr str)              -> parses "192.168.1.1" or
;;                                      "192.168.1.0/24" (same for ipv6:
;;                                      "::1", "fe80::/10"); family is
;;                                      autodetected from whether str
;;                                      contains a ":"
;;   (ipaddr? x)
;;   (ipv4-address? ipa) / (ipv6-address? ipa)
;;   (ipaddr->string ipa)           -> canonical text form; ipv6 uses
;;                                      lowercase hex groups with the
;;                                      longest run of >=2 zero groups
;;                                      collapsed to "::" (RFC 5952,
;;                                      leftmost run wins on a length
;;                                      tie) -- no IPv4-mapped ("::ffff:
;;                                      1.2.3.4") mixed notation and no
;;                                      zone-ID ("%eth0") support
;;   (ipaddr-family ipa)            -> 'ipv4 or 'ipv6
;;   (ipaddr-prefix ipa)            -> CIDR prefix length (0..32/0..128)
;;   (ipaddr->groups ipa)           -> the address as a list of plain
;;                                      per-group integers, MSB-first (4
;;                                      groups of 0..255 for ipv4, 8
;;                                      groups of 0..65535 for ipv6) --
;;                                      the escape hatch for anything not
;;                                      covered below; deliberately NOT a
;;                                      single combined integer, for the
;;                                      fixnum-overflow reason above
;;   (groups->ipaddr family groups)          -> family's bare host address
;;   (groups->ipaddr family groups prefix)   -> ditto, with a given prefix
;;   (ipaddr-netmask ipa) / (ipaddr-hostmask ipa)
;;                                  -> the mask/its complement, as a bare
;;                                     host <ipaddr> of the same family
;;                                     (e.g. 255.255.255.0), derived from
;;                                     ipa's own prefix only -- not from
;;                                     its address
;;   (ipaddr-network ipa)          -> ipa's network address (host bits
;;                                     zeroed), as an <ipaddr> with the
;;                                     same prefix
;;   (ipaddr-broadcast ipa)        -> ipa's network's last address (host
;;                                     bits all-ones), as an <ipaddr>
;;                                     with the same prefix
;;   (ipaddr-include? self other)  -> #t iff other's whole address range
;;                                     (its own network..broadcast, which
;;                                     is just [other,other] for a bare
;;                                     host) falls inside self's; raises
;;                                     if the two are different families
;;   (ipaddr=? a b)                -> same family and same address (the
;;                                     prefix is NOT compared)
;;   (ipaddr<? a b)                -> address ordering; raises on a
;;                                     cross-family comparison (Ruby's
;;                                     IPAddr#<=> returns nil there --
;;                                     creme has no partial-order
;;                                     protocol to return nil through, so
;;                                     this raises instead)
;;   (ipaddr-succ ipa) / (ipaddr-pred ipa)
;;                                  -> address +/- 1, same family and
;;                                     prefix; raises if it would fall
;;                                     outside the family's address range
;;
;; Not auto-imported anywhere -- every script that wants this must
;; (import (creme ipaddr)) explicitly, same as any other file-based
;; library.
;; ===========================================================================

(define-library (creme ipaddr)
  (export make-ipaddr ipaddr? ipv4-address? ipv6-address? ipaddr->string
          ipaddr-family ipaddr-prefix ipaddr->groups groups->ipaddr
          ipaddr-netmask ipaddr-hostmask ipaddr-network ipaddr-broadcast
          ipaddr-include? ipaddr=? ipaddr<? ipaddr-succ ipaddr-pred)
  (import (scheme base) (creme string))
  (begin
    (define-record-type <ipaddr>
      (ipaddr-priv-make family groups prefix)
      ipaddr?
      (family ipaddr-family)
      (groups ipaddr->groups)
      (prefix ipaddr-prefix))

    (define (ipv4-address? ipa) (eq? (ipaddr-family ipa) 'ipv4))
    (define (ipv6-address? ipa) (eq? (ipaddr-family ipa) 'ipv6))

    (define (ipaddr-priv-bits-of-family family) (if (eq? family 'ipv4) 32 128))
    (define (ipaddr-priv-ngroups family) (if (eq? family 'ipv4) 4 8))
    (define (ipaddr-priv-bpg family) (if (eq? family 'ipv4) 8 16))
    (define (ipaddr-priv-modulus family) (expt 2 (ipaddr-priv-bpg family)))

    (define (ipaddr-priv-validate-prefix p bits who)
      (if (or (not (integer? p)) (< p 0) (> p bits))
          (error (string-append who ": invalid prefix length") p)
          p))

    (define (ipaddr-priv-check-same-family who a b)
      (if (not (eq? (ipaddr-family a) (ipaddr-family b)))
          (error (string-append who ": family mismatch") a b)))

    ;; ---- parsing -----------------------------------------------------------

    ;; Splits "ADDR/PREFIX" into (values "ADDR" "PREFIX") -- the prefix
    ;; half is the raw string, unparsed, or #f if there's no "/" at all
    ;; (distinct from "invalid prefix text", which must still raise).
    (define (ipaddr-priv-split-prefix s)
      (let ((idx (string-index-of s "/")))
        (if idx
            (values (substring s 0 idx) (substring s (+ idx 1) (string-length s)))
            (values s #f))))

    (define (ipaddr-priv-parse-prefix raw bits)
      (let ((p (string->number raw)))
        (if (not p)
            (error "make-ipaddr: invalid prefix length" raw)
            (ipaddr-priv-validate-prefix p bits "make-ipaddr"))))

    (define (ipaddr-priv-parse-ipv4-octet tok)
      (let ((o (string->number tok)))
        (if (or (not o) (not (integer? o)) (< o 0) (> o 255) (= (string-length tok) 0))
            (error "make-ipaddr: invalid IPv4 octet" tok)
            o)))

    (define (ipaddr-priv-parse-ipv4 s)
      (let ((octs (string-split s ".")))
        (if (not (= (length octs) 4))
            (error "make-ipaddr: invalid IPv4 address (expected 4 octets)" s))
        (map ipaddr-priv-parse-ipv4-octet octs)))

    (define (ipaddr-priv-parse-hex-group g)
      (let ((v (string->number g 16)))
        (if (or (not v) (not (integer? v)) (< v 0) (> v 65535) (= (string-length g) 0))
            (error "make-ipaddr: invalid IPv6 group" g)
            v)))

    (define (ipaddr-priv-zeros n)
      (if (= n 0) '() (cons 0 (ipaddr-priv-zeros (- n 1)))))

    (define (ipaddr-priv-parse-ipv6 s)
      (let ((halves (string-split s "::")))
        (cond
         ((= (length halves) 1)
          (let ((groups (map ipaddr-priv-parse-hex-group (string-split s ":"))))
            (if (not (= (length groups) 8))
                (error "make-ipaddr: invalid IPv6 address (expected 8 groups)" s))
            groups))
         ((= (length halves) 2)
          (let* ((left (car halves))
                 (right (cadr halves))
                 (left-groups (if (string=? left "") '() (map ipaddr-priv-parse-hex-group (string-split left ":"))))
                 (right-groups (if (string=? right "") '() (map ipaddr-priv-parse-hex-group (string-split right ":"))))
                 (missing (- 8 (length left-groups) (length right-groups))))
            (if (< missing 0)
                (error "make-ipaddr: invalid IPv6 address (too many groups)" s))
            (append left-groups (ipaddr-priv-zeros missing) right-groups)))
         (else (error "make-ipaddr: invalid IPv6 address (more than one '::')" s)))))

    (define (make-ipaddr s)
      (let*-values (((body prefix-raw) (ipaddr-priv-split-prefix s)))
        (let* ((ipv6? (string-contains? body ":"))
               (family (if ipv6? 'ipv6 'ipv4))
               (bits (ipaddr-priv-bits-of-family family))
               (groups (if ipv6? (ipaddr-priv-parse-ipv6 body) (ipaddr-priv-parse-ipv4 body)))
               (prefix (if prefix-raw (ipaddr-priv-parse-prefix prefix-raw bits) bits)))
          (ipaddr-priv-make family groups prefix))))

    (define (ipaddr-priv-validate-groups family groups who)
      (let ((ngroups (ipaddr-priv-ngroups family)) (modulus (ipaddr-priv-modulus family)))
        (if (not (= (length groups) ngroups))
            (error (string-append who ": wrong number of groups for family") family groups))
        (for-each
         (lambda (g) (if (or (not (integer? g)) (< g 0) (>= g modulus))
                         (error (string-append who ": group out of range") g)))
         groups)))

    (define (groups->ipaddr family groups . prefix-opt)
      (let* ((bits (ipaddr-priv-bits-of-family family))
             (prefix (ipaddr-priv-validate-prefix (if (null? prefix-opt) bits (car prefix-opt)) bits "groups->ipaddr")))
        (ipaddr-priv-validate-groups family groups "groups->ipaddr")
        (ipaddr-priv-make family groups prefix)))

    ;; ---- formatting ----------------------------------------------------------

    (define (ipaddr-priv-format-ipv4 groups)
      (string-join (map number->string groups) "."))

    (define (ipaddr-priv-take lst n)
      (if (= n 0) '() (cons (car lst) (ipaddr-priv-take (cdr lst) (- n 1)))))

    ;; All maximal runs of zero-valued groups in groups (starting at
    ;; position idx), as a list of (start . len) pairs, in left-to-right
    ;; order.
    (define (ipaddr-priv-zero-runs groups idx)
      (cond
       ((null? groups) '())
       ((= (car groups) 0)
        (let loop ((g (cdr groups)) (i (+ idx 1)) (len 1))
          (if (and (not (null? g)) (= (car g) 0))
              (loop (cdr g) (+ i 1) (+ len 1))
              (cons (cons idx len) (ipaddr-priv-zero-runs g i)))))
       (else (ipaddr-priv-zero-runs (cdr groups) (+ idx 1)))))

    (define (ipaddr-priv-filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (ipaddr-priv-filter pred (cdr lst))))
            (else (ipaddr-priv-filter pred (cdr lst)))))

    ;; Longest run (leftmost on a tie, since strictly-greater is required
    ;; to displace the current best -- matches RFC 5952's tie-break rule).
    (define (ipaddr-priv-best-run runs)
      (let loop ((rs runs) (best #f))
        (cond
         ((null? rs) best)
         ((or (not best) (> (cdr (car rs)) (cdr best))) (loop (cdr rs) (car rs)))
         (else (loop (cdr rs) best)))))

    (define (ipaddr-priv-format-ipv6 groups)
      (let* ((runs (ipaddr-priv-filter (lambda (r) (>= (cdr r) 2)) (ipaddr-priv-zero-runs groups 0)))
             (best (ipaddr-priv-best-run runs)))
        (if (not best)
            (string-join (map (lambda (g) (number->string g 16)) groups) ":")
            (let* ((start (car best))
                   (len (cdr best))
                   (before (ipaddr-priv-take groups start))
                   (after (list-tail groups (+ start len))))
              (string-append
               (string-join (map (lambda (g) (number->string g 16)) before) ":")
               "::"
               (string-join (map (lambda (g) (number->string g 16)) after) ":"))))))

    (define (ipaddr->string ipa)
      (if (ipv4-address? ipa)
          (ipaddr-priv-format-ipv4 (ipaddr->groups ipa))
          (ipaddr-priv-format-ipv6 (ipaddr->groups ipa))))

    ;; ---- network math --------------------------------------------------------

    ;; How many of this group's bits (0..bits-per-group) fall on the
    ;; network side of prefix, given the group is the i-th (0-based, from
    ;; the MSB end).
    (define (ipaddr-priv-net-bits-at prefix bits-per-group i)
      (let ((nb (- prefix (* i bits-per-group))))
        (cond ((<= nb 0) 0) ((>= nb bits-per-group) bits-per-group) (else nb))))

    ;; modulus - 2^host-bits-in-this-group is all-ones in exactly the top
    ;; net-bits-in-this-group bits and 0 elsewhere -- one formula, valid
    ;; across the whole 0..bits-per-group range (net-bits=0 -> 0,
    ;; net-bits=bits-per-group -> modulus-1), no branching needed.
    (define (ipaddr-priv-netmask-groups prefix ngroups bits-per-group modulus)
      (let loop ((i 0) (acc '()))
        (if (= i ngroups)
            (reverse acc)
            (let* ((nb (ipaddr-priv-net-bits-at prefix bits-per-group i))
                   (hb (- bits-per-group nb)))
              (loop (+ i 1) (cons (- modulus (expt 2 hb)) acc))))))

    (define (ipaddr-priv-hostmask-groups prefix ngroups bits-per-group modulus)
      (map (lambda (g) (- modulus 1 g)) (ipaddr-priv-netmask-groups prefix ngroups bits-per-group modulus)))

    ;; Same unifying trick: dividing then re-multiplying by 2^host-bits
    ;; zeroes exactly the low host-bits-in-this-group bits, whether that's
    ;; 0 (fully network -- divisor 1, value unchanged), bits-per-group
    ;; (fully host -- divisor modulus, value becomes 0), or a genuine
    ;; partial boundary group in between.
    (define (ipaddr-priv-network-groups groups prefix bits-per-group)
      (let loop ((gs groups) (i 0) (acc '()))
        (if (null? gs)
            (reverse acc)
            (let* ((nb (ipaddr-priv-net-bits-at prefix bits-per-group i))
                   (hb (- bits-per-group nb))
                   (divisor (expt 2 hb)))
              (loop (cdr gs) (+ i 1) (cons (* (quotient (car gs) divisor) divisor) acc))))))

    (define (ipaddr-priv-broadcast-groups groups prefix bits-per-group)
      (let loop ((gs groups) (i 0) (acc '()))
        (if (null? gs)
            (reverse acc)
            (let* ((nb (ipaddr-priv-net-bits-at prefix bits-per-group i))
                   (hb (- bits-per-group nb))
                   (divisor (expt 2 hb))
                   (base (* (quotient (car gs) divisor) divisor)))
              (loop (cdr gs) (+ i 1) (cons (+ base (- divisor 1)) acc))))))

    (define (ipaddr-netmask ipa)
      (let ((f (ipaddr-family ipa)))
        (groups->ipaddr f (ipaddr-priv-netmask-groups (ipaddr-prefix ipa) (ipaddr-priv-ngroups f) (ipaddr-priv-bpg f) (ipaddr-priv-modulus f)))))

    (define (ipaddr-hostmask ipa)
      (let ((f (ipaddr-family ipa)))
        (groups->ipaddr f (ipaddr-priv-hostmask-groups (ipaddr-prefix ipa) (ipaddr-priv-ngroups f) (ipaddr-priv-bpg f) (ipaddr-priv-modulus f)))))

    (define (ipaddr-network ipa)
      (groups->ipaddr (ipaddr-family ipa)
                       (ipaddr-priv-network-groups (ipaddr->groups ipa) (ipaddr-prefix ipa) (ipaddr-priv-bpg (ipaddr-family ipa)))
                       (ipaddr-prefix ipa)))

    (define (ipaddr-broadcast ipa)
      (groups->ipaddr (ipaddr-family ipa)
                       (ipaddr-priv-broadcast-groups (ipaddr->groups ipa) (ipaddr-prefix ipa) (ipaddr-priv-bpg (ipaddr-family ipa)))
                       (ipaddr-prefix ipa)))

    (define (ipaddr-priv-groups<? a b)
      (cond ((null? a) #f)
            ((< (car a) (car b)) #t)
            ((> (car a) (car b)) #f)
            (else (ipaddr-priv-groups<? (cdr a) (cdr b)))))

    (define (ipaddr-priv-groups<=? a b) (or (equal? a b) (ipaddr-priv-groups<? a b)))

    (define (ipaddr-include? self other)
      (ipaddr-priv-check-same-family "ipaddr-include?" self other)
      (let* ((bpg (ipaddr-priv-bpg (ipaddr-family self)))
             (self-net (ipaddr-priv-network-groups (ipaddr->groups self) (ipaddr-prefix self) bpg))
             (self-bc (ipaddr-priv-broadcast-groups (ipaddr->groups self) (ipaddr-prefix self) bpg))
             (other-net (ipaddr-priv-network-groups (ipaddr->groups other) (ipaddr-prefix other) bpg))
             (other-bc (ipaddr-priv-broadcast-groups (ipaddr->groups other) (ipaddr-prefix other) bpg)))
        (and (ipaddr-priv-groups<=? self-net other-net)
             (ipaddr-priv-groups<=? other-bc self-bc))))

    (define (ipaddr=? a b)
      (and (eq? (ipaddr-family a) (ipaddr-family b)) (equal? (ipaddr->groups a) (ipaddr->groups b))))

    (define (ipaddr<? a b)
      (ipaddr-priv-check-same-family "ipaddr<?" a b)
      (ipaddr-priv-groups<? (ipaddr->groups a) (ipaddr->groups b)))

    ;; ---- successor/predecessor, with carry/borrow across groups -------------

    ;; Second value is #t when a carry propagated past the MSB group
    ;; (would-be overflow past the address space).
    (define (ipaddr-priv-inc-groups groups modulus)
      (if (null? groups)
          (values '() #t)
          (let-values (((new-rest carry) (ipaddr-priv-inc-groups (cdr groups) modulus)))
            (let ((g (car groups)))
              (if carry
                  (if (= (+ g 1) modulus)
                      (values (cons 0 new-rest) #t)
                      (values (cons (+ g 1) new-rest) #f))
                  (values (cons g new-rest) #f))))))

    ;; Second value is #t when a borrow propagated past the MSB group
    ;; (would-be underflow below the address space).
    (define (ipaddr-priv-dec-groups groups modulus)
      (if (null? groups)
          (values '() #t)
          (let-values (((new-rest borrow) (ipaddr-priv-dec-groups (cdr groups) modulus)))
            (let ((g (car groups)))
              (if borrow
                  (if (= g 0)
                      (values (cons (- modulus 1) new-rest) #t)
                      (values (cons (- g 1) new-rest) #f))
                  (values (cons g new-rest) #f))))))

    (define (ipaddr-succ ipa)
      (let-values (((new-groups overflow?) (ipaddr-priv-inc-groups (ipaddr->groups ipa) (ipaddr-priv-modulus (ipaddr-family ipa)))))
        (if overflow?
            (error "ipaddr-succ: no successor (address overflow)" ipa)
            (ipaddr-priv-make (ipaddr-family ipa) new-groups (ipaddr-prefix ipa)))))

    (define (ipaddr-pred ipa)
      (let-values (((new-groups underflow?) (ipaddr-priv-dec-groups (ipaddr->groups ipa) (ipaddr-priv-modulus (ipaddr-family ipa)))))
        (if underflow?
            (error "ipaddr-pred: no predecessor (address underflow)" ipa)
            (ipaddr-priv-make (ipaddr-family ipa) new-groups (ipaddr-prefix ipa)))))))
