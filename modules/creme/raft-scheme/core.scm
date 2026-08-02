;; ===========================================================================
;; (creme raft-scheme) engine -- pure R7RS Scheme Raft consensus, no FFI.
;;
;; This file has NO (import ...)/(define-library ...) header of its own on
;; purpose: it is spliced into two different hosts.
;;   - modules/creme/raft-scheme.sld pulls it in via (include "raft-scheme/
;;     core.scm") inside a real define-library, for native creme.
;;   - cvm (the standalone C VM) has no runtime library/import machinery at
;;     all -- a plain top-level (import ...) line in a SCRIPT only tells its
;;     bundled self-hosted compiler which native builtin "families" to
;;     register (spawn/send!/receive!/... for (creme actor), sql-open/
;;     -execute/-query/-scalar for (creme sql), sleep-ms! for (creme
;;     process)); it has no separate-file library resolution beyond that.
;;     A cvm-facing script therefore starts with its own (import ...) line
;;     naming those families, then (include "modules/creme/raft-scheme/
;;     core.scm") -- cvm's compiler supports a bare top-level (include ...)
;;     the same way native's define-library does, splicing this file's
;;     forms in textually. Either way, this file only ever calls primitives
;;     confirmed present as flat globals on BOTH runtimes: R7RS base, plus
;;     spawn/send!/receive!/self, sql-open/-close/-execute/-query/-scalar,
;;     sleep-ms!, write, and (creme hash-table)'s make-hash-table/-set!/-ref/
;;     -contains?/-delete!.
;;
;; Why this exists at all: src/creme/modules/creme/raft.cr ((creme raft)) is
;; a Scheme *binding* over an external Crystal shard (threez/raft.cr) that
;; cvm has no native counterpart for at all -- see that file's own header
;; comment. (creme raft-scheme) is a separate, independent implementation:
;; real Raft, driven entirely by actor mailboxes instead of Crystal fibers/
;; channels, log/metadata/snapshots persisted in SQLite instead of a
;; bespoke binary file format -- so the SAME Scheme source runs identically
;; under native creme and under cvm. (creme raft)/(creme raft-machine) are
;; untouched; this is purely additive.
;;
;; ---- Design ---------------------------------------------------------------
;;
;; One actor per node (spawn), running raft-node-loop -- a plain tail-
;; recursive (receive!) dispatch loop, closing over a private, mutable
;; hash-table "state" that only THAT actor's thread ever touches. This
;; matters specifically under cvm: cvm actors are real OS threads, each
;; with its own independently-copied VM/heap (spawn deep-copies whatever
;; the thunk closes over, then the two sides share NOTHING afterward) --
;; so unlike native's cooperative-fiber actors, there is no shared-memory
;; fallback here even if you wanted one. Every cross-actor interaction in
;; this file is therefore a message (send!/receive!), never a hash-table or
;; box passed by reference and mutated from two actors at once.
;;
;; Node-to-node RPC (RequestVote/AppendEntries/InstallSnapshot/PreVote, and
;; their responses) all go through one shared "transport" actor per cluster
;; (raft-scheme-transport-in-memory), which owns the id->ref registry and
;; the partition blocklist privately -- mirroring Raft::Transport::InMemory's
;; class-level registry/@@partitions, just modeled as an actor instead of a
;; process-wide class variable, and so that partition simulation applies
;; symmetrically to responses too, not just requests. This is the one
;; deliberate API shape difference from (creme raft)'s raft-transport-in-
;; memory: there, each node builds its OWN transport object bound to its own
;; id, backed by one shared class-level table; here, one transport actor is
;; shared directly by every node in a cluster (raft-scheme-cluster wires
;; this up automatically). Client calls (propose!/read/add-peer!/.../
;; metrics/role/leader/stop!) are NOT simulated network traffic -- they go
;; straight to the target node's own actor-ref (returned by raft-scheme-
;; start!), bypassing the transport entirely, matching how a real client
;; talks to a Raft node "out of band" from the cluster's own RPC traffic.
;;
;; Election/heartbeat timers are a SEPARATE small "ticker" actor per role
;; period: spawned by whichever code just changed role (become-follower!/
;; -candidate!/-leader!), it sleeps (sleep-ms!) then sends one (election-
;; timeout epoch) or (heartbeat-tick epoch) message and, for the election
;; ticker, re-spawns itself for the next interval; "epoch" is a plain
;; integer snapshotted at spawn time (tickers never read live node state --
;; there is nothing shared to read), and the receiving node ignores any tick
;; whose epoch doesn't match its OWN current election-epoch/heartbeat-epoch,
;; so a stale tick from a since-superseded role period is cheap to discard.
;; KNOWN LIMITATION: a ticker from a role period that has since ended is
;; never explicitly canceled -- it just keeps ticking at a low rate forever,
;; harmlessly ignored via the epoch check (and, for a stopped node, sending
;; into an abandoned mailbox). One extra idle OS thread per role change over
;; a node's lifetime is an acceptable cost at the single-process demo/test
;; scale this module targets; a long-running production cluster doing
;; thousands of elections would want real timer cancellation instead.
;;
;; ---- Persistence -----------------------------------------------------------
;;
;; Each node opens its OWN SQLite connection (sql-open, created lazily
;; inside the node's own actor thunk, never before spawn or shared across
;; actors) at a caller-given path -- ":memory:" for tests/demos, a real file
;; path for durability across restarts. Schema: entries(idx PRIMARY KEY,
;; term, entry_type, data) where data is (write ...)'s external
;; representation of the entry's opaque application payload, read back via
;; this file's own small hand-rolled parse-datum reader (numbers/strings/
;; symbols/booleans/proper-and-dotted lists -- the subset `write` actually
;; produces for ordinary command data); metadata(current_term, voted_for)
;; and snapshots(last_included_index, last_included_term, data), each a
;; single upserted row. parse-datum exists because (scheme read)'s `read`
;; has no cvm-native counterpart outside its own "compiler mode" (see cvm/
;; README.md) -- `write` alone is not enough to round-trip.
;;
;; ---- Scope cuts (deliberate, matching the "full feature parity" minus
;; RTT-tuning/TCP-transport scope agreed for this module) --------------------
;;
;; - Snapshots are sent to a lagging follower in ONE message, not chunked --
;;   fine since actor send! passes an arbitrary-size Scheme value directly,
;;   with no wire-framing size pressure the way a real TCP transport has.
;; - AppendEntries failure just decrements next-index by 1 and lets the next
;;   heartbeat tick retry (no fast log-backtracking optimization).
;; - Membership changes (add-peer!/remove-peer!/add-learner!/promote-
;;   learner!) go through the ordinary single-entry replicated log, applied
;;   identically on every node as that entry commits -- the classic single-
;;   server-at-a-time approach, not joint consensus (so, as in real Raft
;;   without joint consensus, only change one member at a time and let it
;;   commit before starting another).
;; - No Ping/Pong RTT auto-tuning, no ConfigUpdate timeout distribution, no
;;   TCP/Unix wire transport -- (creme actor)'s own start-node 'tcp/'unix
;;   already gives a distribution path later if wanted, so it isn't
;;   duplicated here.
;; ===========================================================================

;; ---- small utilities -------------------------------------------------------

;; (creme actor)'s spawn constructs the new actor's Interpreter by
;; inheriting from whichever interpreter CALLED spawn -- the caller's own
;; import set, not the defining library's. A caddr/cadddr call inside code
;; that runs inside a spawned thunk would therefore only resolve if the
;; SCRIPT that happened to call raft-scheme-start! also imported (scheme
;; cxr) itself, which this library has no way to require of every caller.
;; Sidestep that entirely with local car/cdr-only helpers, so no consumer
;; of (creme raft-scheme) ever needs to import (scheme cxr) on its behalf.
(define (raft-caddr x) (car (cdr (cdr x))))
(define (raft-cadddr x) (car (cdr (cdr (cdr x)))))

(define (raft-list-remove-equal lst x)
  (cond ((null? lst) '())
        ((equal? (car lst) x) (raft-list-remove-equal (cdr lst) x))
        (else (cons (car lst) (raft-list-remove-equal (cdr lst) x)))))

(define (raft-max a b) (if (> a b) a b))
(define (raft-min a b) (if (< a b) a b))

(define (raft-has-majority? votes-count total)
  (> (* 2 votes-count) total))

;; A local, portable `filter` -- not a base-library builtin on both
;; runtimes (native has none at all outside (creme extra); cvm's is a
;; native builtin, but relying on the environment to supply it either
;; way would make this file's portability depend on which runtime it's
;; running under, exactly what this file is trying to avoid everywhere
;; else).
(define (raft-filter pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (raft-filter pred (cdr lst))))
        (else (raft-filter pred (cdr lst)))))

;; ---- parse-datum: a minimal recursive-descent reader ------------------------
;; (round-trips whatever `write` produces for numbers/strings/symbols/
;; booleans/proper-and-dotted lists -- no vectors/bytevectors/chars, out of
;; scope for ordinary application command/state data)

(define (raft-pd-peek str pos)
  (if (>= (vector-ref pos 0) (string-length str)) #f (string-ref str (vector-ref pos 0))))

(define (raft-pd-advance! pos)
  (vector-set! pos 0 (+ 1 (vector-ref pos 0))))

(define (raft-pd-skip-ws! str pos)
  (let loop ()
    (let ((c (raft-pd-peek str pos)))
      (if (and c (char-whitespace? c)) (begin (raft-pd-advance! pos) (loop)) #f))))

(define (raft-pd-token str pos)
  (let loop ((acc '()))
    (let ((c (raft-pd-peek str pos)))
      (if (and c (not (char-whitespace? c)) (not (char=? c #\()) (not (char=? c #\))))
          (begin (raft-pd-advance! pos) (loop (cons c acc)))
          (list->string (reverse acc))))))

(define (raft-pd-read-string! str pos)
  (let loop ((acc '()))
    (let ((c (raft-pd-peek str pos)))
      (cond
        ((not c) (error "parse-datum: unterminated string"))
        ((char=? c #\") (raft-pd-advance! pos) (list->string (reverse acc)))
        ((char=? c #\\)
         (raft-pd-advance! pos)
         (let ((e (raft-pd-peek str pos)))
           (raft-pd-advance! pos)
           (loop (cons (cond ((eqv? e #\n) #\newline)
                             ((eqv? e #\t) #\tab)
                             ((eqv? e #\\) #\\)
                             ((eqv? e #\") #\")
                             (else e))
                       acc))))
        (else (raft-pd-advance! pos) (loop (cons c acc)))))))

;; #u8(1 2 3) -- `write`'s external representation for a bytevector.
;; Needed so a bytevector-valued command (e.g. (creme raft-machine)'s
;; raft-commands, which round-trips commands through raft-sexp->bytevector)
;; survives being written to and re-read from the SQLite-backed log.
(define (raft-pd-read-bytevector! str pos)
  (raft-pd-advance! pos) ;; 'u'
  (raft-pd-advance! pos) ;; '8'
  (raft-pd-advance! pos) ;; '('
  (apply bytevector (raft-pd-read-list! str pos)))

(define (raft-pd-read-hash! str pos)
  (raft-pd-advance! pos) ;; consume '#'
  (let ((c (raft-pd-peek str pos)))
    (cond
      ((and c (char=? c #\t)) (raft-pd-token str pos) #t)
      ((and c (char=? c #\f)) (raft-pd-token str pos) #f)
      ((and c (char=? c #\u)) (raft-pd-read-bytevector! str pos))
      (else (error "parse-datum: unsupported # syntax")))))

(define (raft-pd-dot-terminator? str pos)
  (let ((c0 (raft-pd-peek str pos)))
    (and c0 (char=? c0 #\.)
         (let ((save (vector-ref pos 0)))
           (raft-pd-advance! pos)
           (let ((c1 (raft-pd-peek str pos)))
             (vector-set! pos 0 save)
             (or (not c1) (char-whitespace? c1)))))))

(define (raft-pd-read-list! str pos)
  (raft-pd-skip-ws! str pos)
  (let ((c (raft-pd-peek str pos)))
    (cond
      ((not c) (error "parse-datum: unterminated list"))
      ((char=? c #\)) (raft-pd-advance! pos) '())
      ((raft-pd-dot-terminator? str pos)
       (raft-pd-advance! pos)
       (let ((tail (raft-pd-read! str pos)))
         (raft-pd-skip-ws! str pos)
         (if (eqv? (raft-pd-peek str pos) #\))
             (begin (raft-pd-advance! pos) tail)
             (error "parse-datum: malformed dotted list"))))
      (else
       (let ((head (raft-pd-read! str pos)))
         (cons head (raft-pd-read-list! str pos)))))))

(define (raft-pd-read! str pos)
  (raft-pd-skip-ws! str pos)
  (let ((c (raft-pd-peek str pos)))
    (cond
      ((not c) (error "parse-datum: unexpected end of input"))
      ((char=? c #\() (raft-pd-advance! pos) (raft-pd-read-list! str pos))
      ((char=? c #\") (raft-pd-advance! pos) (raft-pd-read-string! str pos))
      ((char=? c #\#) (raft-pd-read-hash! str pos))
      (else
       (let* ((tok (raft-pd-token str pos)) (n (string->number tok)))
         (if n n (string->symbol tok)))))))

(define (raft-write-datum v)
  (let ((p (open-output-string)))
    (write v p)
    (get-output-string p)))

(define (raft-read-datum str)
  (raft-pd-read! str (vector 0)))

;; ---- SQLite-backed log ------------------------------------------------------

(define (raft-log-open path)
  (let ((db (sql-open path)))
    (sql-execute db "CREATE TABLE IF NOT EXISTS entries (idx INTEGER PRIMARY KEY, term INTEGER NOT NULL, entry_type TEXT NOT NULL, data TEXT NOT NULL)")
    (sql-execute db "CREATE TABLE IF NOT EXISTS metadata (id INTEGER PRIMARY KEY CHECK (id = 0), current_term INTEGER NOT NULL, voted_for TEXT NOT NULL)")
    (sql-execute db "CREATE TABLE IF NOT EXISTS snapshots (id INTEGER PRIMARY KEY CHECK (id = 0), last_included_index INTEGER NOT NULL, last_included_term INTEGER NOT NULL, data TEXT NOT NULL)")
    db))

(define (raft-log-close! db) (sql-close db))

(define (raft-row-cell row name)
  (cdr (assoc name row)))

(define (raft-row->entry row)
  (list (raft-row-cell row "idx")
        (raft-row-cell row "term")
        (string->symbol (raft-row-cell row "entry_type"))
        (raft-read-datum (raft-row-cell row "data"))))

(define (raft-log-insert! db index term entry-type data)
  (sql-execute db "INSERT OR REPLACE INTO entries (idx, term, entry_type, data) VALUES (?, ?, ?, ?)"
               index term (symbol->string entry-type) (raft-write-datum data)))

;; Append with conflict detection: an existing entry at `index` with a
;; DIFFERENT term means everything from `index` onward is stale (from an
;; old leader) and must be discarded first; a matching (index . term) is a
;; no-op (idempotent re-delivery, e.g. a retried heartbeat).
(define (raft-log-append! db index term entry-type data)
  (let ((existing (raft-log-get db index)))
    (cond
      ((and existing (= (cadr existing) term)) #t)
      (existing (raft-log-truncate-from! db index) (raft-log-insert! db index term entry-type data))
      (else (raft-log-insert! db index term entry-type data)))))

(define (raft-log-get db index)
  (let ((rows (sql-query db "SELECT idx, term, entry_type, data FROM entries WHERE idx = ?" index)))
    (if (zero? (vector-length rows)) #f (raft-row->entry (vector-ref rows 0)))))

(define (raft-log-truncate-from! db index)
  (sql-execute db "DELETE FROM entries WHERE idx >= ?" index))

(define (raft-log-slice db from to)
  (let ((rows (sql-query db "SELECT idx, term, entry_type, data FROM entries WHERE idx >= ? AND idx <= ? ORDER BY idx ASC" from to)))
    (let loop ((i 0) (acc '()))
      (if (>= i (vector-length rows))
          (reverse acc)
          (loop (+ i 1) (cons (raft-row->entry (vector-ref rows i)) acc))))))

(define (raft-log-snapshot-bounds db)
  ;; -> (last-included-index . last-included-term), or (0 . 0) if none.
  (let ((rows (sql-query db "SELECT last_included_index, last_included_term FROM snapshots WHERE id = 0")))
    (if (zero? (vector-length rows))
        (cons 0 0)
        (cons (raft-row-cell (vector-ref rows 0) "last_included_index")
              (raft-row-cell (vector-ref rows 0) "last_included_term")))))

(define (raft-log-last-index db)
  ;; SQL NULL (an empty entries table) round-trips as Scheme's '() here,
  ;; which -- unlike #f -- is truthy, so a plain (if v v ...) would wrongly
  ;; treat "no rows" as a present value of '(); check explicitly instead.
  (let ((v (sql-scalar db "SELECT MAX(idx) FROM entries")))
    (if (or (not v) (null? v)) (car (raft-log-snapshot-bounds db)) v)))

(define (raft-log-last-term db)
  (let ((last (raft-log-last-index db)))
    (if (zero? last) (cdr (raft-log-snapshot-bounds db)) (raft-log-term-at db last))))

(define (raft-log-term-at db index)
  (if (zero? index)
      0
      (let ((bounds (raft-log-snapshot-bounds db)))
        (if (= index (car bounds))
            (cdr bounds)
            (let ((e (raft-log-get db index)))
              (if e (cadr e) #f))))))

(define (raft-log-save-metadata! db term voted-for)
  (sql-execute db "INSERT INTO metadata (id, current_term, voted_for) VALUES (0, ?, ?) ON CONFLICT(id) DO UPDATE SET current_term = excluded.current_term, voted_for = excluded.voted_for"
               term (if voted-for voted-for "")))

(define (raft-log-load-metadata db)
  ;; -> (term . voted-for), voted-for is #f when none is on record.
  (let ((rows (sql-query db "SELECT current_term, voted_for FROM metadata WHERE id = 0")))
    (if (zero? (vector-length rows))
        (cons 0 #f)
        (let* ((row (vector-ref rows 0))
               (vf (raft-row-cell row "voted_for")))
          (cons (raft-row-cell row "current_term") (if (string=? vf "") #f vf))))))

(define (raft-log-save-snapshot! db last-included-index last-included-term data)
  (sql-execute db "INSERT INTO snapshots (id, last_included_index, last_included_term, data) VALUES (0, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET last_included_index = excluded.last_included_index, last_included_term = excluded.last_included_term, data = excluded.data"
               last-included-index last-included-term (raft-write-datum data))
  (sql-execute db "DELETE FROM entries WHERE idx <= ?" last-included-index))

(define (raft-log-load-snapshot db)
  ;; -> (last-included-index last-included-term data), or #f if none.
  (let ((rows (sql-query db "SELECT last_included_index, last_included_term, data FROM snapshots WHERE id = 0")))
    (if (zero? (vector-length rows))
        #f
        (let ((row (vector-ref rows 0)))
          (list (raft-row-cell row "last_included_index")
                (raft-row-cell row "last_included_term")
                (raft-read-datum (raft-row-cell row "data")))))))

;; ---- config ------------------------------------------------------------

(define (raft-scheme-config . kvs)
  (let loop ((kvs kvs) (acc '()))
    (if (null? kvs) acc (loop (cddr kvs) (cons (cons (car kvs) (cadr kvs)) acc)))))

(define (raft-cfg config key default)
  (let ((p (assq key config)))
    (if p (cdr p) default)))

;; ---- state machine -------------------------------------------------------

(define (raft-scheme-state-machine apply-proc snapshot-proc restore-proc)
  (list apply-proc snapshot-proc restore-proc))

(define (raft-sm-apply sm v) ((car sm) v))
(define (raft-sm-snapshot sm) ((cadr sm)))
(define (raft-sm-restore sm data) ((raft-caddr sm) data))

;; ---- transport (one shared actor per cluster) ------------------------------

(define (raft-transport-partitioned? partitions a b)
  (cond ((null? partitions) #f)
        ((let ((p (car partitions)))
           (or (and (equal? (car p) a) (equal? (cdr p) b))
               (and (equal? (car p) b) (equal? (cdr p) a))))
         #t)
        (else (raft-transport-partitioned? (cdr partitions) a b))))

(define (raft-transport-loop registry partitions)
  (let ((msg (receive!)))
    (case (car msg)
      ((register)
       (hash-table-set! registry (cadr msg) (raft-caddr msg))
       (raft-transport-loop registry partitions))
      ((deliver)
       (let ((to (cadr msg)) (payload (raft-caddr msg)) (from (raft-cadddr msg)))
         (if (not (raft-transport-partitioned? partitions from to))
             (if (hash-table-contains? registry to)
                 (send! (hash-table-ref registry to) payload)
                 #f))
         (raft-transport-loop registry partitions)))
      ((partition)
       (send! (raft-cadddr msg) 'ok)
       (raft-transport-loop registry (cons (cons (cadr msg) (raft-caddr msg)) partitions)))
      ((heal)
       (send! (raft-cadddr msg) 'ok)
       (raft-transport-loop registry (raft-list-remove-equal partitions (cons (cadr msg) (raft-caddr msg)))))
      (else (raft-transport-loop registry partitions)))))

(define (raft-scheme-transport-in-memory)
  (spawn (lambda () (raft-transport-loop (make-hash-table) '()))))

(define (raft-scheme-transport-partition! transport a b)
  (send! transport (list 'partition a b (self)))
  (receive!))

(define (raft-scheme-transport-heal! transport a b)
  (send! transport (list 'heal a b (self)))
  (receive!))

;; ---- node state (a private hash-table, only ever touched by its own actor)

(define (raft-ns-get st key) (hash-table-ref st key))
(define (raft-ns-set! st key v) (hash-table-set! st key v))

(define (raft-new-state id peers learners state-machine transport log-db config)
  (let ((st (make-hash-table))
        (meta (raft-log-load-metadata log-db))
        (snap (raft-log-load-snapshot log-db)))
    (raft-ns-set! st 'id id)
    (raft-ns-set! st 'peers peers)
    (raft-ns-set! st 'learners learners)
    (raft-ns-set! st 'state-machine state-machine)
    (raft-ns-set! st 'transport transport)
    (raft-ns-set! st 'log-db log-db)
    (raft-ns-set! st 'config config)
    (raft-ns-set! st 'role 'follower)
    (raft-ns-set! st 'current-term (car meta))
    (raft-ns-set! st 'voted-for (cdr meta))
    (raft-ns-set! st 'leader-id #f)
    (raft-ns-set! st 'commit-index (if snap (car snap) 0))
    (raft-ns-set! st 'last-applied (if snap (car snap) 0))
    (raft-ns-set! st 'last-snapshot-index (if snap (car snap) 0))
    (raft-ns-set! st 'next-index (make-hash-table))
    (raft-ns-set! st 'match-index (make-hash-table))
    (raft-ns-set! st 'votes-received '())
    (raft-ns-set! st 'prevotes-received '())
    (raft-ns-set! st 'election-epoch 0)
    (raft-ns-set! st 'heartbeat-epoch 0)
    (raft-ns-set! st 'pending-requests (make-hash-table))
    (raft-ns-set! st 'running #t)
    (raft-ns-set! st 'metrics (make-hash-table))
    (if snap (raft-sm-restore state-machine (raft-caddr snap)) #f)
    st))

(define (raft-metric-inc! st key)
  (hash-table-set! (raft-ns-get st 'metrics) key (+ 1 (hash-table-ref (raft-ns-get st 'metrics) key (lambda () 0)))))

(define (raft-is-learner? st)
  (and (member (raft-ns-get st 'id) (raft-ns-get st 'learners)) #t))

(define (raft-total-voters st)
  (+ 1 (length (raft-ns-get st 'peers))))

(define (raft-send! st to-id message)
  (send! (raft-ns-get st 'transport) (list 'deliver to-id message (raft-ns-get st 'id))))

;; ---- tickers ---------------------------------------------------------------

(define (raft-random-election-timeout st)
  (let ((lo (raft-cfg (raft-ns-get st 'config) 'election-timeout-min 150))
        (hi (raft-cfg (raft-ns-get st 'config) 'election-timeout-max 300)))
    (+ lo (random-integer (+ 1 (- hi lo))))))

(define (raft-start-election-ticker! st self-ref epoch)
  (let ((delay (raft-random-election-timeout st)))
    (spawn (lambda ()
             (sleep-ms! delay)
             (send! self-ref (list 'election-timeout epoch))))))

(define (raft-start-heartbeat-ticker! st self-ref epoch)
  (let ((interval (raft-cfg (raft-ns-get st 'config) 'heartbeat-interval 50)))
    (spawn (lambda () (raft-heartbeat-ticker-loop self-ref epoch interval)))))

(define (raft-heartbeat-ticker-loop self-ref epoch interval)
  (sleep-ms! interval)
  (send! self-ref (list 'heartbeat-tick epoch))
  (raft-heartbeat-ticker-loop self-ref epoch interval))

;; ---- role transitions -------------------------------------------------------

(define (raft-fail-pending-requests! st reason)
  (let ((pending (raft-ns-get st 'pending-requests)))
    (for-each (lambda (k) (send! (cadr (hash-table-ref pending k)) (list 'error reason)))
              (hash-table-keys pending))
    (raft-ns-set! st 'pending-requests (make-hash-table))))

(define (raft-become-follower! st self-ref term)
  (if (> term (raft-ns-get st 'current-term))
      (begin
        (raft-ns-set! st 'current-term term)
        (raft-ns-set! st 'voted-for #f)
        (raft-log-save-metadata! (raft-ns-get st 'log-db) term #f))
      #f)
  (if (not (eq? (raft-ns-get st 'role) 'follower)) (raft-fail-pending-requests! st 'not-leader-anymore) #f)
  (raft-ns-set! st 'role 'follower)
  (let ((epoch (+ 1 (raft-ns-get st 'election-epoch))))
    (raft-ns-set! st 'election-epoch epoch)
    (raft-start-election-ticker! st self-ref epoch)))

(define (raft-become-leader! st self-ref)
  (raft-ns-set! st 'role 'leader)
  (raft-ns-set! st 'leader-id (raft-ns-get st 'id))
  (raft-metric-inc! st 'elections-won)
  (let ((db (raft-ns-get st 'log-db))
        (next (make-hash-table))
        (match (make-hash-table)))
    (for-each (lambda (p) (hash-table-set! next p (+ 1 (raft-log-last-index db))) (hash-table-set! match p 0))
              (append (raft-ns-get st 'peers) (raft-ns-get st 'learners)))
    (raft-ns-set! st 'next-index next)
    (raft-ns-set! st 'match-index match))
  (let ((epoch (+ 1 (raft-ns-get st 'heartbeat-epoch))))
    (raft-ns-set! st 'heartbeat-epoch epoch)
    (raft-start-heartbeat-ticker! st self-ref epoch))
  (raft-replicate-to-peers! st))

(define (raft-become-candidate-for-real! st self-ref)
  (let* ((db (raft-ns-get st 'log-db))
         (term (+ 1 (raft-ns-get st 'current-term))))
    (raft-ns-set! st 'current-term term)
    (raft-ns-set! st 'voted-for (raft-ns-get st 'id))
    (raft-log-save-metadata! db term (raft-ns-get st 'id))
    (raft-ns-set! st 'role 'candidate)
    (raft-ns-set! st 'votes-received (list (raft-ns-get st 'id)))
    (for-each (lambda (peer)
                (raft-send! st peer (list 'request-vote term (raft-ns-get st 'id)
                                          (raft-log-last-index db) (raft-log-last-term db))))
              (raft-ns-get st 'peers))
    (raft-maybe-win-election! st self-ref)))

(define (raft-maybe-win-election! st self-ref)
  (if (and (eq? (raft-ns-get st 'role) 'candidate)
           (raft-has-majority? (length (raft-ns-get st 'votes-received)) (raft-total-voters st)))
      (raft-become-leader! st self-ref)
      #f))

;; The pre-vote round's own request/response messages carry the CANDIDATE's
;; current election-epoch as an opaque round token (echoed back verbatim by
;; every responder), used purely to match a response to the round that
;; produced it -- never compared against a term. That's deliberate: the
;; pre-vote's own "term" field is a SPECULATIVE probe (current-term + 1,
;; never actually applied), so it is always one greater than the
;; candidate's own real current-term by construction; naively treating
;; "responder's echoed term > my current-term" as "someone has a newer
;; term, step down" (the correct rule for REAL RequestVote/AppendEntries
;; responses, whose term fields are real) would misfire on literally every
;; pre-vote round. See raft-handle-pre-vote-response! below.
(define (raft-start-election! st self-ref)
  (if (raft-is-learner? st)
      #f
      (let* ((db (raft-ns-get st 'log-db))
             (term (+ 1 (raft-ns-get st 'current-term)))
             (epoch (raft-ns-get st 'election-epoch)))
        (raft-ns-set! st 'role 'pre-candidate)
        (raft-ns-set! st 'prevotes-received (list (raft-ns-get st 'id)))
        (raft-metric-inc! st 'elections-started)
        (for-each (lambda (peer)
                    (raft-send! st peer (list 'pre-vote term (raft-ns-get st 'id)
                                              (raft-log-last-index db) (raft-log-last-term db) epoch)))
                  (raft-ns-get st 'peers))
        (raft-maybe-start-real-election! st self-ref))))

(define (raft-maybe-start-real-election! st self-ref)
  (if (and (eq? (raft-ns-get st 'role) 'pre-candidate)
           (raft-has-majority? (length (raft-ns-get st 'prevotes-received)) (raft-total-voters st)))
      (raft-become-candidate-for-real! st self-ref)
      #f))

;; ---- replication (leader side) ---------------------------------------------

(define (raft-append-entries-message st peer)
  (let* ((db (raft-ns-get st 'log-db))
         (next (hash-table-ref (raft-ns-get st 'next-index) peer))
         (bounds (raft-log-snapshot-bounds db)))
    (if (<= next (car bounds))
        (list 'install-snapshot (raft-ns-get st 'current-term) (raft-ns-get st 'id)
              (car bounds) (cdr bounds) (raft-sm-snapshot (raft-ns-get st 'state-machine)))
        (let* ((prev-index (- next 1))
               (prev-term (raft-log-term-at db prev-index))
               (last (raft-log-last-index db))
               (entries (if (<= next last) (raft-log-slice db next last) '())))
          (list 'append-entries (raft-ns-get st 'current-term) (raft-ns-get st 'id)
                prev-index prev-term entries (raft-ns-get st 'commit-index))))))

(define (raft-replicate-to-peers! st)
  (for-each (lambda (peer) (raft-send! st peer (raft-append-entries-message st peer)))
            (append (raft-ns-get st 'peers) (raft-ns-get st 'learners))))

(define (raft-recompute-commit-index! st)
  (let* ((db (raft-ns-get st 'log-db))
         (my-last (raft-log-last-index db))
         (match (raft-ns-get st 'match-index))
         (peer-matches (map (lambda (p) (hash-table-ref match p (lambda () 0))) (raft-ns-get st 'peers)))
         (all-matches (cons my-last peer-matches))
         (total (raft-total-voters st))
         (candidate-n (raft-ns-get st 'commit-index)))
    (for-each (lambda (n)
                (if (and (> n candidate-n)
                         (raft-has-majority? (length (raft-filter (lambda (m) (>= m n)) all-matches)) total)
                         (eqv? (raft-log-term-at db n) (raft-ns-get st 'current-term)))
                    (set! candidate-n n)
                    #f))
              all-matches)
    (if (> candidate-n (raft-ns-get st 'commit-index))
        (begin (raft-ns-set! st 'commit-index candidate-n) #t)
        #f)))

;; ---- apply committed entries -------------------------------------------------

(define (raft-apply-config-change! st entry-data)
  (let ((action (car entry-data)) (peer-id (cadr entry-data)))
    (case action
      ((add-peer)
       (raft-ns-set! st 'peers (cons peer-id (raft-list-remove-equal (raft-ns-get st 'peers) peer-id)))
       (raft-ns-set! st 'learners (raft-list-remove-equal (raft-ns-get st 'learners) peer-id)))
      ((add-learner)
       (raft-ns-set! st 'learners (cons peer-id (raft-list-remove-equal (raft-ns-get st 'learners) peer-id))))
      ((promote-learner)
       (raft-ns-set! st 'learners (raft-list-remove-equal (raft-ns-get st 'learners) peer-id))
       (raft-ns-set! st 'peers (cons peer-id (raft-list-remove-equal (raft-ns-get st 'peers) peer-id))))
      ((remove-peer)
       (raft-ns-set! st 'peers (raft-list-remove-equal (raft-ns-get st 'peers) peer-id))
       (raft-ns-set! st 'learners (raft-list-remove-equal (raft-ns-get st 'learners) peer-id))))
    (if (and (eq? (raft-ns-get st 'role) 'leader) (not (eq? action 'remove-peer)))
        (begin
          (if (not (hash-table-contains? (raft-ns-get st 'next-index) peer-id))
              (hash-table-set! (raft-ns-get st 'next-index) peer-id (+ 1 (raft-log-last-index (raft-ns-get st 'log-db))))
              #f)
          (if (not (hash-table-contains? (raft-ns-get st 'match-index) peer-id))
              (hash-table-set! (raft-ns-get st 'match-index) peer-id 0)
              #f))
        #f)))

(define (raft-maybe-auto-snapshot! st)
  (let ((threshold (raft-cfg (raft-ns-get st 'config) 'snapshot-threshold 1000)))
    (if (>= (- (raft-ns-get st 'last-applied) (raft-ns-get st 'last-snapshot-index)) threshold)
        (raft-do-snapshot! st)
        #f)))

(define (raft-do-snapshot! st)
  (let* ((db (raft-ns-get st 'log-db))
         (index (raft-ns-get st 'last-applied))
         (term (raft-log-term-at db index))
         (data (raft-sm-snapshot (raft-ns-get st 'state-machine))))
    (raft-log-save-snapshot! db index term data)
    (raft-ns-set! st 'last-snapshot-index index)
    (raft-metric-inc! st 'snapshots-installed)))

(define (raft-apply-one-entry! st entry)
  (let ((index (car entry)) (type (raft-caddr entry)) (data (raft-cadddr entry))
        (pending (raft-ns-get st 'pending-requests))
        (sm (raft-ns-get st 'state-machine)))
    (case type
      ((normal)
       (let ((result (raft-sm-apply sm data)))
         (if (hash-table-contains? pending index)
             (let ((req (hash-table-ref pending index)))
               (hash-table-delete! pending index)
               (send! (cadr req) (list 'ok result)))
             #f)))
      ((noop)
       (raft-sm-apply sm data) ;; must still be tolerated/discarded, may be a linearizability barrier
       (if (hash-table-contains? pending index)
           (let ((req (hash-table-ref pending index)))
             (hash-table-delete! pending index)
             (if (eq? (car req) 'read-barrier)
                 (send! (cadr req) (list 'ok (raft-sm-apply sm (raft-caddr req))))
                 (send! (cadr req) (list 'ok result-unspecified))))
           #f))
      ((config)
       (raft-apply-config-change! st data)
       (if (hash-table-contains? pending index)
           (let ((req (hash-table-ref pending index)))
             (hash-table-delete! pending index)
             (send! (cadr req) (list 'ok result-unspecified)))
           #f)))
    (raft-metric-inc! st 'entries-applied)
    (if (eq? type 'normal) (raft-metric-inc! st 'proposals-committed) #f)))

(define result-unspecified (list 'unspecified))

(define (raft-apply-committed! st)
  (let loop ()
    (if (> (raft-ns-get st 'commit-index) (raft-ns-get st 'last-applied))
        (let* ((next (+ 1 (raft-ns-get st 'last-applied)))
               (entry (raft-log-get (raft-ns-get st 'log-db) next)))
          (if entry (raft-apply-one-entry! st entry) #f)
          (raft-ns-set! st 'last-applied next)
          (raft-maybe-auto-snapshot! st)
          (loop))
        #f)))

;; ---- client-originated entries (propose/read/config changes) ----------------

(define (raft-client-append! st self-ref entry-type data pending kind reply-ref)
  (if (not (eq? (raft-ns-get st 'role) 'leader))
      (send! reply-ref (list 'error (list 'not-leader (raft-ns-get st 'leader-id))))
      (let* ((db (raft-ns-get st 'log-db))
             (index (+ 1 (raft-log-last-index db)))
             (term (raft-ns-get st 'current-term)))
        (raft-log-append! db index term entry-type data)
        (hash-table-set! (raft-ns-get st 'pending-requests) index
                          (if (eq? kind 'read-barrier) (list 'read-barrier reply-ref pending) (list 'write reply-ref)))
        (raft-recompute-commit-index! st)
        (raft-apply-committed! st)
        (raft-replicate-to-peers! st))))

;; ---- RPC handlers (follower/candidate/leader side) --------------------------

(define (raft-log-up-to-date? st cand-last-term cand-last-index)
  (let ((my-term (raft-log-last-term (raft-ns-get st 'log-db)))
        (my-index (raft-log-last-index (raft-ns-get st 'log-db))))
    (or (> cand-last-term my-term)
        (and (= cand-last-term my-term) (>= cand-last-index my-index)))))

(define (raft-handle-request-vote! st self-ref msg)
  (let ((term (list-ref msg 1)) (cand-id (list-ref msg 2))
        (cand-last-index (list-ref msg 3)) (cand-last-term (list-ref msg 4)))
    (if (> term (raft-ns-get st 'current-term)) (raft-become-follower! st self-ref term) #f)
    (cond
      ((< term (raft-ns-get st 'current-term))
       (raft-send! st cand-id (list 'request-vote-response (raft-ns-get st 'current-term) #f (raft-ns-get st 'id))))
      ((raft-is-learner? st)
       (raft-send! st cand-id (list 'request-vote-response (raft-ns-get st 'current-term) #f (raft-ns-get st 'id))))
      ((and (or (not (raft-ns-get st 'voted-for)) (equal? (raft-ns-get st 'voted-for) cand-id))
            (raft-log-up-to-date? st cand-last-term cand-last-index))
       ;; Granting a vote is a legitimate reason to reset our own election
       ;; timer -- go through raft-become-follower! (not a bare ticker
       ;; respawn) so its epoch bump actually invalidates any
       ;; already-in-flight ticker from before this reset; respawning a
       ;; ticker at the OLD epoch here would leave two live tickers
       ;; sharing one epoch, so the older one's eventual tick would look
       ;; "current" and spuriously restart an election right after we
       ;; just reset the timer.
       (raft-become-follower! st self-ref (raft-ns-get st 'current-term))
       (raft-ns-set! st 'voted-for cand-id)
       (raft-log-save-metadata! (raft-ns-get st 'log-db) (raft-ns-get st 'current-term) cand-id)
       (raft-send! st cand-id (list 'request-vote-response (raft-ns-get st 'current-term) #t (raft-ns-get st 'id))))
      (else
       (raft-send! st cand-id (list 'request-vote-response (raft-ns-get st 'current-term) #f (raft-ns-get st 'id)))))))

(define (raft-handle-request-vote-response! st self-ref msg)
  (let ((term (list-ref msg 1)) (granted (list-ref msg 2)) (from (list-ref msg 3)))
    (cond
      ((> term (raft-ns-get st 'current-term)) (raft-become-follower! st self-ref term))
      ((not (and (eq? (raft-ns-get st 'role) 'candidate) (= term (raft-ns-get st 'current-term)))) #f)
      (granted
       (raft-ns-set! st 'votes-received (cons from (raft-list-remove-equal (raft-ns-get st 'votes-received) from)))
       (raft-maybe-win-election! st self-ref))
      (else #f))))

(define (raft-handle-pre-vote! st self-ref msg)
  (let ((term (list-ref msg 1)) (cand-id (list-ref msg 2))
        (cand-last-index (list-ref msg 3)) (cand-last-term (list-ref msg 4)) (epoch (list-ref msg 5)))
    (let ((granted (and (not (raft-is-learner? st))
                        (>= term (raft-ns-get st 'current-term))
                        (raft-log-up-to-date? st cand-last-term cand-last-index))))
      ;; Reply with OUR OWN real current-term (not an echo of the
      ;; candidate's speculative probe) -- see raft-start-election!'s
      ;; comment for why that distinction matters.
      (raft-send! st cand-id (list 'pre-vote-response (raft-ns-get st 'current-term) granted (raft-ns-get st 'id) epoch)))))

(define (raft-handle-pre-vote-response! st self-ref msg)
  (let ((responder-term (list-ref msg 1)) (granted (list-ref msg 2)) (from (list-ref msg 3)) (epoch (list-ref msg 4)))
    (cond
      ((> responder-term (raft-ns-get st 'current-term)) (raft-become-follower! st self-ref responder-term))
      ((not (and (eq? (raft-ns-get st 'role) 'pre-candidate) (= epoch (raft-ns-get st 'election-epoch)))) #f)
      (granted
       (raft-ns-set! st 'prevotes-received (cons from (raft-list-remove-equal (raft-ns-get st 'prevotes-received) from)))
       (raft-maybe-start-real-election! st self-ref))
      (else #f))))

(define (raft-handle-append-entries! st self-ref msg)
  (let ((term (list-ref msg 1)) (leader-id (list-ref msg 2)) (prev-index (list-ref msg 3))
        (prev-term (list-ref msg 4)) (entries (list-ref msg 5)) (leader-commit (list-ref msg 6))
        (db (raft-ns-get st 'log-db)))
    (if (>= term (raft-ns-get st 'current-term))
        (begin (raft-become-follower! st self-ref (raft-max term (raft-ns-get st 'current-term)))
               (raft-ns-set! st 'leader-id leader-id))
        #f)
    (cond
      ((< term (raft-ns-get st 'current-term))
       (raft-send! st leader-id (list 'append-entries-response (raft-ns-get st 'current-term) #f 0 (raft-ns-get st 'id))))
      ((and (> prev-index 0) (not (eqv? (raft-log-term-at db prev-index) prev-term)))
       (raft-send! st leader-id (list 'append-entries-response (raft-ns-get st 'current-term) #f (raft-log-last-index db) (raft-ns-get st 'id))))
      (else
       (for-each (lambda (e) (raft-log-append! db (car e) (cadr e) (raft-caddr e) (raft-cadddr e))) entries)
       (if (> leader-commit (raft-ns-get st 'commit-index))
           (begin (raft-ns-set! st 'commit-index (raft-min leader-commit (raft-log-last-index db)))
                  (raft-apply-committed! st))
           #f)
       (raft-send! st leader-id (list 'append-entries-response (raft-ns-get st 'current-term) #t (raft-log-last-index db) (raft-ns-get st 'id)))))))

(define (raft-handle-append-entries-response! st self-ref msg)
  (let ((term (list-ref msg 1)) (success (list-ref msg 2)) (match-idx (list-ref msg 3)) (from (list-ref msg 4)))
    (cond
      ((> term (raft-ns-get st 'current-term)) (raft-become-follower! st self-ref term))
      ((not (and (eq? (raft-ns-get st 'role) 'leader) (= term (raft-ns-get st 'current-term)))) #f)
      (success
       (hash-table-set! (raft-ns-get st 'match-index) from (raft-max match-idx (hash-table-ref (raft-ns-get st 'match-index) from (lambda () 0))))
       (hash-table-set! (raft-ns-get st 'next-index) from (+ 1 match-idx))
       (if (raft-recompute-commit-index! st) (raft-apply-committed! st) #f))
      (else
       (hash-table-set! (raft-ns-get st 'next-index) from (raft-max 1 (- (hash-table-ref (raft-ns-get st 'next-index) from (lambda () 1)) 1)))))))

(define (raft-handle-install-snapshot! st self-ref msg)
  (let ((term (list-ref msg 1)) (leader-id (list-ref msg 2)) (last-index (list-ref msg 3))
        (last-term (list-ref msg 4)) (data (list-ref msg 5)) (db (raft-ns-get st 'log-db)))
    (if (>= term (raft-ns-get st 'current-term))
        (begin (raft-become-follower! st self-ref (raft-max term (raft-ns-get st 'current-term)))
               (raft-ns-set! st 'leader-id leader-id))
        #f)
    (if (< term (raft-ns-get st 'current-term))
        (raft-send! st leader-id (list 'install-snapshot-response (raft-ns-get st 'current-term) 0 (raft-ns-get st 'id)))
        (begin
          (raft-log-save-snapshot! db last-index last-term data)
          (raft-sm-restore (raft-ns-get st 'state-machine) data)
          (raft-ns-set! st 'last-snapshot-index last-index)
          (raft-ns-set! st 'commit-index (raft-max (raft-ns-get st 'commit-index) last-index))
          (raft-ns-set! st 'last-applied (raft-max (raft-ns-get st 'last-applied) last-index))
          (raft-metric-inc! st 'snapshots-installed)
          (raft-send! st leader-id (list 'install-snapshot-response (raft-ns-get st 'current-term) last-index (raft-ns-get st 'id)))))))

(define (raft-handle-install-snapshot-response! st self-ref msg)
  (let ((term (list-ref msg 1)) (last-index (list-ref msg 2)) (from (list-ref msg 3)))
    (cond
      ((> term (raft-ns-get st 'current-term)) (raft-become-follower! st self-ref term))
      ((not (and (eq? (raft-ns-get st 'role) 'leader) (= term (raft-ns-get st 'current-term)))) #f)
      (else
       (hash-table-set! (raft-ns-get st 'match-index) from (raft-max last-index (hash-table-ref (raft-ns-get st 'match-index) from (lambda () 0))))
       (hash-table-set! (raft-ns-get st 'next-index) from (+ 1 last-index))
       (if (raft-recompute-commit-index! st) (raft-apply-committed! st) #f)))))

;; ---- the node actor loop ----------------------------------------------------

;; A raised error inside a spawned actor's thunk unwinds straight out of
;; that actor (per (creme actor)'s own spawn: any exception there just
;; terminates the fiber/thread) with no built-in way for it to surface
;; anywhere -- exactly the "apply-proc must not raise" hazard (creme
;; raft)'s own header comment warns about, since a concurrent propose!/
;; read blocked on (receive!) for this node's reply would then hang
;; forever with no diagnostic at all. Guard every message dispatch here so
;; a bug in this engine (or in a caller-supplied state-machine procedure)
;; logs to (current-error-port) and drops just that one message instead of
;; silently killing the whole node.
(define (raft-node-loop st self-ref)
  (let ((msg (receive!)))
    (guard (e (#t (display "raft-scheme: error handling " (current-error-port))
                  (write msg (current-error-port))
                  (display ": " (current-error-port))
                  (write e (current-error-port))
                  (newline (current-error-port))))
    (case (car msg)
      ((request-vote) (raft-handle-request-vote! st self-ref msg))
      ((request-vote-response) (raft-handle-request-vote-response! st self-ref msg))
      ((pre-vote) (raft-handle-pre-vote! st self-ref msg))
      ((pre-vote-response) (raft-handle-pre-vote-response! st self-ref msg))
      ((append-entries) (raft-handle-append-entries! st self-ref msg))
      ((append-entries-response) (raft-handle-append-entries-response! st self-ref msg))
      ((install-snapshot) (raft-handle-install-snapshot! st self-ref msg))
      ((install-snapshot-response) (raft-handle-install-snapshot-response! st self-ref msg))
      ((election-timeout)
       (if (and (= (list-ref msg 1) (raft-ns-get st 'election-epoch)) (not (eq? (raft-ns-get st 'role) 'leader)))
           (raft-start-election! st self-ref)
           #f))
      ((heartbeat-tick)
       (if (and (= (list-ref msg 1) (raft-ns-get st 'heartbeat-epoch)) (eq? (raft-ns-get st 'role) 'leader))
           (raft-replicate-to-peers! st)
           #f))
      ((propose) (raft-client-append! st self-ref 'normal (list-ref msg 1) #f 'write (list-ref msg 2)))
      ((read-request) (raft-client-append! st self-ref 'noop 'noop (list-ref msg 1) 'read-barrier (list-ref msg 2)))
      ((add-peer) (raft-client-append! st self-ref 'config (list 'add-peer (list-ref msg 1)) #f 'write (list-ref msg 2)))
      ((remove-peer) (raft-client-append! st self-ref 'config (list 'remove-peer (list-ref msg 1)) #f 'write (list-ref msg 2)))
      ((add-learner) (raft-client-append! st self-ref 'config (list 'add-learner (list-ref msg 1)) #f 'write (list-ref msg 2)))
      ((promote-learner) (raft-client-append! st self-ref 'config (list 'promote-learner (list-ref msg 1)) #f 'write (list-ref msg 2)))
      ((snapshot-now) (raft-do-snapshot! st) (send! (list-ref msg 1) (list 'ok result-unspecified)))
      ((get-metrics) (send! (list-ref msg 1) (list 'ok (raft-build-metrics st))))
      ((get-role) (send! (list-ref msg 1) (list 'ok (raft-ns-get st 'role))))
      ((get-leader) (send! (list-ref msg 1) (list 'ok (raft-ns-get st 'leader-id))))
      ((stop)
       (raft-ns-set! st 'running #f)
       (send! (list-ref msg 1) (list 'ok result-unspecified)))
      (else #f)))
    (if (raft-ns-get st 'running) (raft-node-loop st self-ref) #f)))

(define (raft-build-metrics st)
  (let ((m (raft-ns-get st 'metrics)))
    (list (cons 'elections-started (hash-table-ref m 'elections-started (lambda () 0)))
          (cons 'elections-won (hash-table-ref m 'elections-won (lambda () 0)))
          (cons 'proposals-committed (hash-table-ref m 'proposals-committed (lambda () 0)))
          (cons 'entries-applied (hash-table-ref m 'entries-applied (lambda () 0)))
          (cons 'snapshots-installed (hash-table-ref m 'snapshots-installed (lambda () 0)))
          (cons 'term (raft-ns-get st 'current-term))
          (cons 'commit-index (raft-ns-get st 'commit-index))
          (cons 'role (raft-ns-get st 'role)))))

;; ---- public constructors/API ------------------------------------------------

;; (raft-scheme-node id peers state-machine transport log-path [config [learners]])
;; -> an opaque node handle (not yet running -- pass to raft-scheme-start!).
(define (raft-scheme-node id peers state-machine transport log-path . rest)
  (let ((config (if (>= (length rest) 1) (car rest) '()))
        (learners (if (>= (length rest) 2) (cadr rest) '())))
    (list id peers learners state-machine transport log-path config)))

;; Spawns the node's actor and its initial election ticker; returns the
;; node's actor-ref -- THIS is what every other raft-scheme-* client
;; procedure below takes as `node`.
(define (raft-scheme-start! node)
  (let* ((id (list-ref node 0)) (peers (list-ref node 1)) (learners (list-ref node 2))
         (state-machine (list-ref node 3)) (transport (list-ref node 4))
         (log-path (list-ref node 5)) (config (list-ref node 6)))
    (let ((ref (spawn (lambda ()
                        ;; Construction failing (a bad log path, a broken
                        ;; snapshot restore-proc, ...) has no sensible
                        ;; "resume" -- log it visibly, then let the actor
                        ;; die, rather than fail silently.
                        (guard (e (#t (display "raft-scheme: node startup failed: " (current-error-port))
                                      (write e (current-error-port))
                                      (newline (current-error-port))
                                      (raise e)))
                        (let* ((db (raft-log-open log-path))
                               (st (raft-new-state id peers learners state-machine transport db config))
                               (self-ref (self)))
                          (raft-start-election-ticker! st self-ref 0)
                          (raft-node-loop st self-ref)))))))
      (send! transport (list 'register id ref))
      ref)))

(define (raft-scheme-stop! node) (send! node (list 'stop (self))) (car (cdr (receive!))))

(define (raft-scheme-propose! node command)
  (send! node (list 'propose command (self)))
  (let ((reply (receive!)))
    (if (eq? (car reply) 'ok) (cadr reply) (error "raft-scheme-propose!: not leader" (cadr reply)))))

(define (raft-scheme-read node command)
  (send! node (list 'read-request command (self)))
  (let ((reply (receive!)))
    (if (eq? (car reply) 'ok) (cadr reply) (error "raft-scheme-read: not leader" (cadr reply)))))

(define (raft-scheme-add-peer! node peer-id)
  (send! node (list 'add-peer peer-id (self)))
  (let ((reply (receive!))) (if (eq? (car reply) 'ok) result-unspecified (error "raft-scheme-add-peer!" (cadr reply)))))

(define (raft-scheme-remove-peer! node peer-id)
  (send! node (list 'remove-peer peer-id (self)))
  (let ((reply (receive!))) (if (eq? (car reply) 'ok) result-unspecified (error "raft-scheme-remove-peer!" (cadr reply)))))

(define (raft-scheme-add-learner! node peer-id)
  (send! node (list 'add-learner peer-id (self)))
  (let ((reply (receive!))) (if (eq? (car reply) 'ok) result-unspecified (error "raft-scheme-add-learner!" (cadr reply)))))

(define (raft-scheme-promote-learner! node peer-id)
  (send! node (list 'promote-learner peer-id (self)))
  (let ((reply (receive!))) (if (eq? (car reply) 'ok) result-unspecified (error "raft-scheme-promote-learner!" (cadr reply)))))

(define (raft-scheme-snapshot! node)
  (send! node (list 'snapshot-now (self)))
  (receive!)
  result-unspecified)

(define (raft-scheme-metrics node)
  (send! node (list 'get-metrics (self)))
  (cadr (receive!)))

(define (raft-scheme-role node)
  (send! node (list 'get-role (self)))
  (cadr (receive!)))

(define (raft-scheme-leader node)
  (send! node (list 'get-leader (self)))
  (cadr (receive!)))

;; Blocks the calling actor (yielding via sleep-ms!, the only portable
;; "wait a bit" primitive here) until one of `nodes` reports role 'leader
;; or `timeout-ms` (default 5000) elapses. Returns that node's ref, or #f.
(define (raft-scheme-await-leader! nodes . rest)
  (let ((timeout-ms (if (null? rest) 5000 (car rest))))
    (let loop ((waited 0))
      (let ((leader (raft-find-leader nodes)))
        (cond
          (leader leader)
          ((>= waited timeout-ms) #f)
          (else (sleep-ms! 10) (loop (+ waited 10))))))))

(define (raft-find-leader nodes)
  (cond
    ((null? nodes) #f)
    ((eq? (raft-scheme-role (car nodes)) 'leader) (car nodes))
    (else (raft-find-leader (cdr nodes)))))

;; ---- cluster convenience (mirrors (creme raft-machine)'s raft-cluster) ------

(define (raft-other-ids ids id)
  (cond ((null? ids) '())
        ((string=? (car ids) id) (raft-other-ids (cdr ids) id))
        (else (cons (car ids) (raft-other-ids (cdr ids) id)))))

;; (raft-scheme-cluster ids make-node) -- ids a flat list of node ids,
;; make-node a (lambda (id peers transport) ...) returning a raft-scheme-node
;; (NOT yet started). Builds one shared in-memory transport for the whole
;; cluster and computes `peers` as "every other id" for each node, mirroring
;; (creme raft-machine)'s raft-cluster. Returns a list of (id . node) pairs
;; -- start each with raft-scheme-start! to get its actor-ref.
(define (raft-scheme-cluster ids make-node)
  (let ((transport (raft-scheme-transport-in-memory)))
    (map (lambda (id) (cons id (make-node id (raft-other-ids ids id) transport))) ids)))
