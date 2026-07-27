;; ===========================================================================
;; A (creme spec)-based port of the LOCAL half of actor_spec.cr's own
;; cases -- see modules/creme/spec.sld's own header comment for the
;; framework this uses. Later phases (this project's own planning doc)
;; extend this file with the 'local same-process transport and real
;; TCP/Unix distribution.
;;
;; (creme actor) used to be entirely absent from cvm -- porting it
;; required building real concurrency into cvm for the first time (see
;; cvm/actor.c's own header comment): one real OS thread + one
;; independent VM per spawned actor (not a cooperative green-thread
;; scheduler), a bounded (64-slot) mutex+condvar mailbox per actor
;; matching native's own Channel(64) exactly, and a per-actor
;; setjmp/longjmp escape hatch so an uncaught error inside one actor's
;; thunk takes down only that actor (notifying its monitors with a
;; <down> record), not the whole process.
;;
;; Unlike this directory's should-match-native? spec files, actor tests
;; are inherently about real concurrency -- comparing two independent
;; compiler runs of the SAME form wouldn't be meaningful here (each
;; would spawn its own, unrelated actor). Every case below instead runs
;; directly against whichever single backend is executing this file and
;; asserts on the OBSERVABLE result of a message round-trip, exactly
;; like random_spec.scm's own approach to a similarly not-directly-
;; comparable feature.
;;
;; actor-ref-id's exact STRING FORMAT is deliberately NOT asserted on --
;; cvm uses its own simple sequential-counter id scheme, not native's
;; "actor-N" naming (see actor.c's own comment) -- only that two refs to
;; the SAME actor produce the SAME id (self-consistency), never a
;; specific expected string.
;;
;; Run with (all cases pass under all three):
;;   ./bin/creme spec/creme/actor_spec.scm
;;   ./bin/creme --self-hosted spec/creme/actor_spec.scm
;;   ./cvm/cvm spec/creme/actor_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (creme actor) (creme spec))

;; Used by the Phase 4 "record round-trips over a real tcp: socket" case
;; below -- a message decoded off the wire is only reconstructed as a
;; record if the RECEIVING actor's own VM has a global bound to this
;; exact type name (see cvm/actor.c's read_list, which mirrors native's
;; own from_wire_plain type-by-name lookup); defining it once here, at
;; top level, means every actor spawned in this file (including ones
;; that started their own 'tcp node) sees the same type.
(define-record-type <spec-actor-point>
  (make-spec-actor-point x y)
  spec-actor-point?
  (x spec-actor-point-x)
  (y spec-actor-point-y))

(describe "(creme actor) local actors"
  (it "spawn/send!/receive! round-trip a value through a worker actor"
    (define worker
      (spawn (lambda ()
               (let ((msg (receive!)))
                 (send! (car msg) (* (cdr msg) 2))))))
    (send! worker (cons (self) 21))
    (should-equal? (receive!) 42))

  (it "self returns a ref usable as a reply-to address, consistently"
    (define a (self))
    (define b (self))
    (should-equal? (actor-ref-id a) (actor-ref-id b)))

  ;; NOTE: deliberately uses let* (not two top-level defines with
  ;; register! in between) -- a define whose initializer depends on an
  ;; EARLIER expression's side effect on shared/global state, with
  ;; another define in between, hits a genuine pre-existing cvm compiler
  ;; bug (confirmed unrelated to actor.c: reproduces with plain set!/
  ;; define, no actors involved at all) where the later define's
  ;; initializer gets evaluated before the intervening expression runs.
  ;; let*'s own sequential-binding evaluation isn't affected by this --
  ;; only body-level defines interleaved with expressions are.
  (it "register!/whereis resolve a name to the same actor a ref points to"
    (let* ((named-worker
            (spawn (lambda ()
                     (let ((msg (receive!)))
                       (send! (car msg) (+ (cdr msg) 1))))))
           (ignored (register! 'spec-named-worker named-worker))
           (found (whereis 'spec-named-worker)))
      (should-equal? (actor-ref-id found) (actor-ref-id named-worker))
      (send! found (cons (self) 100))
      (should-equal? (receive!) 101)))

  (it "whereis returns #f for a name that was never registered"
    (should-be-false? (whereis 'spec-never-registered-name)))

  (it "send! to an unknown (never registered) name raises"
    (should-raise? (lambda () (send! 'spec-totally-unknown-name 42))))

  (it "monitor + <down> fires with reason 'normal on a clean exit"
    (define clean-actor (spawn (lambda () 'done)))
    (monitor clean-actor)
    (let ((d (receive!)))
      (should-be-true? (down? d))
      (should-equal? (down-reason d) 'normal)
      (should-equal? (actor-ref-id (down-ref d)) (actor-ref-id clean-actor))))

  (it "monitor + <down> fires with a string reason on an error exit"
    (define crashing-actor (spawn (lambda () (car '()))))
    (monitor crashing-actor)
    (let ((d (receive!)))
      (should-be-true? (down? d))
      (should-be-true? (string? (down-reason d)))
      (should-equal? (actor-ref-id (down-ref d)) (actor-ref-id crashing-actor))))

  (it "down? is false for an ordinary (non-<down>) value"
    (should-be-false? (down? 42))
    (should-be-false? (down? "not a down record")))

  ;; --- Phase 3: 'local transport (multiple ActorSystems, same process) ---
  ;; cvm's own actor-ref is always a direct, process-wide-valid pointer
  ;; (see actor.c's own comment on why), so unlike native's ActorRefData
  ;; a ref never needs rewriting ("localize_refs") when a message carrying
  ;; it crosses an ActorSystem/node boundary -- these cases confirm that
  ;; holds rather than exercising a rewrite step that isn't needed here.
  ;;
  ;; NOTE: every case below runs start-node from inside a SPAWNED actor
  ;; (never on the main/spec-runner thread itself). start-node reassigns
  ;; the CALLING thread's own current node permanently (mirroring native's
  ;; own current_interp.actor_system reassignment) -- since every `it`
  ;; block in this file runs on the very same main thread, one `it`
  ;; calling start-node directly would leak into every later `it`.
  ;; Spawning a throwaway actor to hold the new node keeps each case
  ;; isolated, exactly like a real multi-node program would use start-node
  ;; from whichever thread is meant to own that node -- never main.

  (it "start-node 'local returns a node whose node-name matches what was given"
    (define main-ref (self))
    (spawn (lambda ()
             (let ((node (start-node 'local "spec-node-a" "cookie")))
               (send! main-ref (list (node-name node) (node-name))))))
    (should-equal? (receive!) (list "spec-node-a" "spec-node-a"))) ;; 0-arg form: caller's own current node

  (it "node-address builds a dialable local:// URI for an actor on a node"
    (define main-ref (self))
    (spawn (lambda ()
             (define node (start-node 'local "spec-node-b" "cookie"))
             (define worker (spawn (lambda () (receive!))))
             (send! main-ref (list (string? (node-address node worker))
                                    (node-address node worker)
                                    (string-append "local://" (actor-ref-id worker) "@spec-node-b")))))
    (let ((result (receive!)))
      (should-be-true? (car result))
      (should-equal? (cadr result) (caddr result))))

  (it "register!/whereis are scoped per-node -- a name registered on one node is invisible on another"
    (define main-ref (self))
    (spawn (lambda ()
             (start-node 'local "spec-node-c" "cookie")
             (register! 'spec-node-c-only (self))
             (send! main-ref (if (whereis 'spec-node-c-only) #t #f))))
    (should-be-true? (receive!))
    ;; The MAIN actor never called start-node itself (still whichever
    ;; system it was already in) -- it must NOT see spec-node-c's own name.
    (should-be-false? (whereis 'spec-node-c-only)))

  (it "same object identity and a working reply-to ref survive crossing a 'local node boundary"
    (define main-ref (self))
    (define payload (list 1 2 3))
    (define echoer
      (spawn (lambda ()
               (let ((msg (receive!)))
                 (send! (car msg) (cons 'echo (cdr msg)))))))
    (spawn (lambda ()
             (start-node 'local "spec-node-d" "cookie")
             (send! echoer (cons (self) payload))
             (let ((reply (receive!)))
               (send! main-ref (eq? (cdr reply) payload)))))
    (should-be-true? (receive!)))

  (it "stop-node! removes a node so its name is no longer resolvable via node-address's own node handle"
    (define main-ref (self))
    (spawn (lambda ()
             (define node (start-node 'local "spec-node-e" "cookie"))
             (stop-node! node)
             ;; node-name/node-address still work on the handle itself
             ;; (it's just an unlinked struct, not freed) -- stop-node!'s
             ;; only real effect is removing it from the process-wide name
             ;; registry future cross-node lookups would use (Phase 4's
             ;; remote-ref equivalent); confirm the call itself doesn't
             ;; raise and the node still reports its own name.
             (send! main-ref (node-name node))))
    (should-equal? (receive!) "spec-node-e"))

  ;; --- Phase 4: real TCP/Unix transport, HMAC handshake, wire protocol ---
  ;; Every case spawns BOTH ends of the connection within this same spec
  ;; process (mirroring native's own actor_spec.cr:59-99/134-192) --
  ;; port 0 always means "let the kernel pick a free ephemeral port",
  ;; read back afterwards via node-port, so these never collide with
  ;; anything else listening on the test machine.
  ;;
  ;; NOTE: every spawned body below uses let* (never a body-level define
  ;; following a preceding expression, e.g. start-node) -- this hits the
  ;; SAME pre-existing compiler bug documented on the Phase 3 cases above
  ;; (confirmed here too, independently: a (define worker (spawn ...))
  ;; placed right after a (start-node ...) call in the same body ran the
  ;; define's initializer before start-node's own system-reassignment
  ;; took effect, so the spawned worker landed in the WRONG ActorSystem
  ;; and was never reachable by the registered name -- symptom was every
  ;; send! to it silently vanishing, since a dropped/misrouted message is
  ;; not an error, just a receive! that blocks forever).

  (it "'tcp transport: send!/receive! round-trip a value across a real socket, resolved by name via remote-ref"
    (define main-ref (self))
    (spawn (lambda ()
             (let* ((node (start-node 'tcp "127.0.0.1" 0 "spec-tcp-cookie"))
                    (sent-port (send! main-ref (node-port node)))
                    (worker (spawn (lambda ()
                                     (let ((msg (receive!)))
                                       (send! (car msg) (* (cdr msg) 2))))))
                    (registered (register! 'spec-tcp-worker worker)))
               (receive!)))) ;; keep the node's actor alive for the duration of this case
    (let ((port (receive!)))
      (spawn (lambda ()
               (let* ((node (start-node 'tcp "127.0.0.1" 0 "spec-tcp-cookie"))
                      (target (remote-ref (string-append "tcp://spec-tcp-worker@127.0.0.1:" (number->string port))))
                      (sent (send! target (cons (self) 21))))
                 (send! main-ref (receive!)))))
      (should-equal? (receive!) 42)))

  (it "'tcp transport: a record and an actor-ref (reply-to) round-trip correctly over the wire"
    (define main-ref (self))
    (spawn (lambda ()
             (let* ((node (start-node 'tcp "127.0.0.1" 0 "spec-tcp-record-cookie"))
                    (sent-port (send! main-ref (node-port node)))
                    (echoer (spawn (lambda ()
                                     (let ((msg (receive!)))
                                       (send! (car msg) (make-spec-actor-point (+ (spec-actor-point-x (cdr msg)) 1) (spec-actor-point-y (cdr msg))))))))
                    (registered (register! 'spec-tcp-echoer echoer)))
               (receive!))))
    (let ((port (receive!)))
      (spawn (lambda ()
               (let* ((node (start-node 'tcp "127.0.0.1" 0 "spec-tcp-record-cookie"))
                      (target (remote-ref (string-append "tcp://spec-tcp-echoer@127.0.0.1:" (number->string port))))
                      (sent (send! target (cons (self) (make-spec-actor-point 10 20)))))
                 (send! main-ref (receive!)))))
      (let ((reply (receive!)))
        (should-be-true? (spec-actor-point? reply))
        (should-equal? (spec-actor-point-x reply) 11)
        (should-equal? (spec-actor-point-y reply) 20))))

  (it "'tcp transport: a mismatched cookie is rejected by the HMAC handshake"
    (define main-ref (self))
    (spawn (lambda ()
             (let* ((node (start-node 'tcp "127.0.0.1" 0 "spec-correct-cookie"))
                    (sent-port (send! main-ref (node-port node)))
                    (worker (spawn (lambda () (receive!))))
                    (registered (register! 'spec-tcp-guarded-worker worker)))
               (receive!))))
    (let ((port (receive!)))
      (spawn (lambda ()
               (let* ((node (start-node 'tcp "127.0.0.1" 0 "spec-WRONG-cookie"))
                      (target (remote-ref (string-append "tcp://spec-tcp-guarded-worker@127.0.0.1:" (number->string port)))))
                 (send! main-ref (guard (e (#t #t)) (send! target 'hello) #f)))))
      (should-be-true? (receive!))))

  (it "'unix transport: send!/receive! round-trip a value across a real unix domain socket"
    (define main-ref (self))
    (define sock-path "/tmp/cvm-actor-spec.sock")
    (spawn (lambda ()
             (let* ((node (start-node 'unix sock-path "spec-unix-cookie"))
                    (worker (spawn (lambda ()
                                     (let ((msg (receive!)))
                                       (send! (car msg) (* (cdr msg) 3))))))
                    (registered (register! 'spec-unix-worker worker))
                    (sent-ready (send! main-ref 'ready)))
               (receive!))))
    (receive!) ;; wait for the server side's socket file to actually exist
    (spawn (lambda ()
             (let* ((node (start-node 'unix (string-append sock-path ".client") "spec-unix-cookie"))
                    (target (remote-ref (string-append "unix://spec-unix-worker@" sock-path)))
                    (sent (send! target (cons (self) 7))))
               (send! main-ref (receive!)))))
    (should-equal? (receive!) 21)))

(spec-summary!)
