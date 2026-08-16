;; ===========================================================================
;; A (creme spec)-based port of (creme http)'s own cases
;; (spec/scheme/modules/creme/http_spec.cr) -- see modules/creme/spec.sld's
;; own header comment for the framework this uses.
;;
;; (creme http) used to be entirely absent from icecreme. Crystal's own
;; `require "http/client"` is standard library, not an external shard --
;; backed here (icecreme/http.c) by a small hand-rolled HTTP/1.1 client (raw
;; getaddrinfo/connect/read/write, the same pattern (creme actor)'s own
;; dial() already uses): builds a request, sends "Connection: close",
;; and drains the response by reading until the peer closes the socket
;; (decoding a chunked Transfer-Encoding body as a second pass over
;; whatever bytes were read, if the server ever sends one) rather than
;; tracking Content-Length precisely while receiving.
;;
;; HTTPS/TLS is now real (icecreme/http.c's own header comment) -- this file's
;; two https:// cases near the end are the only ones needing actual
;; external network access, everything else here is local-only via the
;; spawned mux server below. Native's own spec suite (spec/scheme/modules/
;; creme/http_spec.cr) still never exercises HTTPS -- that's Crystal's
;; standard HTTP::Client, already TLS-capable independent of this project.
;;
;; Unlike this directory's should-match-native? spec files, this one
;; needs a REAL server to test the client against -- same reasoning as
;; actor_spec.scm's own header comment (inherently about real I/O, not a
;; deterministic dual-compiler comparison). Native's own http_spec.cr
;; spins up a real HTTP::Server on its own Fiber; icecreme has no such
;; concurrency primitive for (creme mux)'s own mux-listen! (it blocks
;; the calling thread inside facil.io's own reactor loop forever, by
;; design -- see mux.c's own comment), so this spins up the SAME real
;; mux-based HTTP server on its own (creme actor) thread instead (a
;; FIXED port, not mux-listen!'s own ephemeral-port return value, since
;; mux-listen! never returns that value back to the caller at all).
;; try-connect below retries the very first request in a bounded loop
;; (no sleep builtin exists in icecreme to wait out the small
;; spawn-a-thread-then-bind-a-socket startup race otherwise) -- once
;; that first request succeeds, the server is definitely up for every
;; case that follows.
;;
;; Unlike every other file in this directory, this one is icecreme-ONLY --
;; native's differently-shaped mux-listen!/actor Fiber concurrency
;; doesn't stand up the same "server on one thread, client on another,
;; same script" pattern this file relies on (see main_spec.scm's own
;; native-excluded list, and its comment on why nothing is left
;; untested: native's own (creme http) has its own separate, already-
;; passing Crystal spec, spec/scheme/modules/creme/http_spec.cr).
;;
;; Run with:
;;   ./icecreme/icecreme spec/creme/http_spec.scm
;; ===========================================================================

(import (scheme base) (scheme write) (creme mux) (creme http) (creme actor) (creme spec))

(define http-spec-port 18923)
(define (url path) (string-append "http://127.0.0.1:" (number->string http-spec-port) path))

(spawn (lambda ()
         (define router (mux-router))
         (mux-get! router "/hello"
           (lambda (request)
             (list (cons "status" 200)
                   (cons "headers" (list (cons "Content-Type" "text/plain")))
                   (cons "body" "hello"))))
         (mux-get! router "/headers"
           (lambda (request)
             (define req-headers (cdr (assoc "headers" request)))
             (define custom (assoc "X-Custom" req-headers))
             (list (cons "status" 200)
                   (cons "headers" (list (cons "X-Custom" (if custom (cdr custom) ""))))
                   (cons "body" ""))))
         (mux-post! router "/echo"
           (lambda (request)
             (list (cons "status" 201)
                   (cons "body" (cdr (assoc "body" request))))))
         (mux-put! router "/put"
           (lambda (request)
             (list (cons "status" 200)
                   (cons "body" (cdr (assoc "body" request))))))
         (mux-patch! router "/patch"
           (lambda (request)
             (list (cons "status" 200)
                   (cons "body" (cdr (assoc "body" request))))))
         (mux-delete! router "/delete"
           (lambda (request)
             (list (cons "status" 204) (cons "body" ""))))
         (mux-head! router "/head"
           (lambda (request)
             (list (cons "status" 200) (cons "body" ""))))
         ;; Routing/radix-tree coverage (icecreme/radix.c, replacing what used
         ;; to be a linear MUX_MAX_SEGS/MUX_SEG_LEN-bounded segment-array
         ;; scan -- see mux.c's own header comment): "/users/me" is
         ;; registered AFTER the overlapping "/users/:id" to prove a static
         ;; route wins regardless of registration order, not just when
         ;; registered first.
         (mux-get! router "/users/:id"
           (lambda (request)
             (list (cons "status" 200) (cons "body" (string-append "param:" (cdr (assoc "id" (cdr (assoc "path-params" request)))))))))
         (mux-get! router "/users/me"
           (lambda (request)
             (list (cons "status" 200) (cons "body" "static-me"))))
         (mux-get! router "/files/*path"
           (lambda (request)
             (list (cons "status" 200) (cons "body" (string-append "glob:" (cdr (assoc "path" (cdr (assoc "path-params" request)))))))))
         (mux-get! router "/a/b/c/d/e/f/g/h/i/j"
           (lambda (request)
             (list (cons "status" 200) (cons "body" "deep-ok"))))
         (mux-listen! router http-spec-port (list (cons "host" "127.0.0.1")))
         (display "unreachable: mux-listen! blocks its own thread forever")))

(define (try-connect n)
  (guard (e (#t (if (> n 0) (try-connect (- n 1)) (error "http-spec: test server never came up"))))
    (http-get (url "/hello"))))

(describe "(creme http)"
  (it "performs a GET and returns status/headers/body"
    (let ((result (try-connect 500)))
      (should-equal? (cdr (assoc "status" result)) 200)
      (should-equal? (cdr (assoc "body" result)) "hello")
      (should-equal? (cdr (assoc "Content-Type" (cdr (assoc "headers" result)))) "text/plain")))

  (it "sends custom request headers and reads response headers"
    (should-equal?
     (cdr (assoc "X-Custom" (cdr (assoc "headers" (http-get (url "/headers") '(("X-Custom" . "abc")))))))
     "abc"))

  (it "performs a POST with a body"
    (let ((result (http-post (url "/echo") "payload")))
      (should-equal? (cdr (assoc "status" result)) 201)
      (should-equal? (cdr (assoc "body" result)) "payload")))

  (it "performs PUT and PATCH with bodies"
    (should-equal? (cdr (assoc "body" (http-put (url "/put") "put-body"))) "put-body")
    (should-equal? (cdr (assoc "body" (http-patch (url "/patch") "patch-body"))) "patch-body"))

  (it "performs DELETE and HEAD"
    (should-equal? (cdr (assoc "status" (http-delete (url "/delete")))) 204)
    (should-equal? (cdr (assoc "status" (http-head (url "/head")))) 200))

  (it "a static route wins over an overlapping :name route registered earlier"
    (should-equal? (cdr (assoc "body" (http-get (url "/users/me")))) "static-me")
    (should-equal? (cdr (assoc "body" (http-get (url "/users/42")))) "param:42"))

  (it "a *name catch-all route captures the entire remaining path"
    (should-equal? (cdr (assoc "body" (http-get (url "/files/a/b/c.txt")))) "glob:a/b/c.txt"))

  (it "matches a path deeper than the old 8-segment cap"
    (should-equal? (cdr (assoc "body" (http-get (url "/a/b/c/d/e/f/g/h/i/j")))) "deep-ok"))

  (it "supports the generic http-request builtin"
    (should-equal? (cdr (assoc "status" (http-request "POST" (url "/echo") '() "generic"))) 201))

  (it "raises on connection failure"
    (should-raise? (lambda () (http-get "http://127.0.0.1:1"))))

  (it "raises on a malformed url"
    (should-raise? (lambda () (http-get "not a url"))))

  ;; HTTPS: real TLS now (icecreme/http.c's Conn/connect_tls), always with full
  ;; certificate + hostname verification (SSL_VERIFY_PEER against the
  ;; system trust store, plus SSL_set1_host -- see http.c's own header
  ;; comment; there's no flag anywhere to turn either off). Unlike every
  ;; other case in this file, these two genuinely need REAL external
  ;; network access -- there's no local TLS server here to test against
  ;; (icecreme's own mux.c is a plain-HTTP server only, no TLS listener), so
  ;; this mirrors examples/27-http-json-fetch.scm's own pre-existing
  ;; live-network dependency (postman-echo.com) rather than introducing a
  ;; new kind of exception: example.com and badssl.com's wrong-host
  ;; fixture are both long-lived, stable endpoints kept up specifically
  ;; for this kind of TLS-client smoke test.
  (it "performs a real HTTPS GET with certificate/hostname verification"
    (let ((result (http-get "https://example.com")))
      (should-equal? (cdr (assoc "status" result)) 200)))

  (it "rejects an https url whose certificate doesn't match the hostname"
    (should-raise? (lambda () (http-get "https://wrong.host.badssl.com/")))))

(spec-summary!)
