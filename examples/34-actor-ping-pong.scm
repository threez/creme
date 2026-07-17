(import (scheme base) (scheme write) (creme actor) (creme actor-supervisor) (creme match) (creme extra) (creme sql))

(define-record-type <ping>          (make-ping reply-to)          ping?          (reply-to ping-reply-to))
(define-record-type <pong>          (make-pong)                   pong?)
(define-record-type <count-request> (make-count-request reply-to) count-request? (reply-to count-request-reply-to))
(define-record-type <count-reply>   (make-count-reply n)          count-reply?   (n count-reply-n))
(define-record-type <stop>          (make-stop)                   stop?)

;; Server actor: owns the SQLite connection exclusively, so every ping/
;; count-request is naturally serialized through its own message queue,
;; no locking required.
(define (server-behavior)
  (lambda ()
    (define conn (sql-open ":memory:"))
    (sql-execute conn "CREATE TABLE pings (id INTEGER PRIMARY KEY, ts INTEGER)")
    (let loop ()
      (match (receive!)
        ((ping? reply-to)
         (sql-execute conn "INSERT INTO pings (ts) VALUES (strftime('%s','now'))")
         (send! reply-to (make-pong))
         (loop))
        ((count-request? reply-to)
         (send! reply-to (make-count-reply (sql-scalar conn "SELECT COUNT(*) FROM pings")))
         (loop))
        ((stop?) (sql-close conn))))))

(define (ping! target)
  (send! target (make-ping (self)))
  (receive!))

(define (ping-count target)
  (send! target (make-count-request (self)))
  (count-reply-n (receive!)))

(define (client-behavior server n)
  (lambda ()
    (times n (ping! server))
    (display "total pings so far: ")
    (display (ping-count server))
    (newline)))

(define cluster-cookie "shared-secret-change-me")

;; --- server node: hosts the supervised ping-server, addressable
;; externally as tcp://ping-server@127.0.0.1:<port> ------------------------
(define server-node (start-node "127.0.0.1" 0 cluster-cookie))
(define server-port (node-port server-node))

(start-supervisor
  (list (child-spec 'ping-server server-behavior 'permanent)))

;; --- client node: in practice a separate process (its own `creme`
;; invocation, its own port) -- shown in the same script for readability --
(start-node "127.0.0.1" 0 cluster-cookie)

(define server
  (remote-ref (node-address server-node 'ping-server)))

;; The main script has an implicit actor identity too (self/receive! work
;; from anywhere), so it can monitor the client and block until the
;; client's own termination -- the client's completion controls this
;; program's lifetime, not an unbounded background listener.
(define client (spawn (client-behavior server 5)))
(monitor client)
(receive!)

(send! server (make-stop))
(stop-node!)              ; the client node, current on this Interpreter
(stop-node! server-node)  ; the server node
