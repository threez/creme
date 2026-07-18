;; ===========================================================================
;; (creme wrk): run wrk (the HTTP benchmarking tool) and parse its output
;;
;; File-based library (resolved via library_search_path, same mechanism
;; (creme cli)/(creme extra) use) rather than compiled into the interpreter
;; binary, since every export here is expressible in plain R7RS on top of
;; (creme process)'s own process-run + (creme regex), with no opaque
;; foreign object or third-party Crystal library of its own involved — see
;; modules/creme/extra.sld's own header comment for the same rationale.
;; `wrk` itself is an external tool (like `crystal`/`shards` elsewhere in
;; this project) this library shells out to, not something reimplemented
;; here.
;;
;; Pulled out of competition/bench.scm so a test/spec can call wrk and get
;; back real numbers (requests-per-sec, latency) to assert against,
;; instead of scraping wrk's own text report by hand every time.
;;
;;   (wrk-run url)                  -> runs `wrk -t4 -c32 -d8s --latency
;;                                      url`, returns the parsed result
;;                                      alist (see wrk-parse below).
;;                                      --latency is always passed so
;;                                      wrk-parse's latency-p50-ms/p75/p90/
;;                                      p99 fields are always populated.
;;   (wrk-run url 'key value ...)   -> same, with any of:
;;     'threads N       -- wrk -t (default 4)
;;     'conns N          -- wrk -c (default 32)
;;     'duration "8s"    -- wrk -d (default "8s")
;;     'accept "text/html" -- sets an Accept request header
;;     'headers (("Name" . "Value") ...) -- extra request headers, in
;;                          addition to 'accept if both are given
;;                                      Raises if wrk itself exits
;;                                      nonzero (not found, bad url, ...).
;;   (wrk-parse output)              -> parses one wrk text report (as
;;                                      produced on stdout) into an alist:
;;     url                    - the benchmarked URL (string)
;;     requested-duration     - the "-d" value wrk ran with, e.g. "8s"
;;     threads / connections  - integers
;;     latency-avg-ms / latency-stdev-ms / latency-max-ms
;;                            - floats, normalized to milliseconds
;;                              regardless of wrk's own ns/us/ms/s units
;;     latency-stdev-pct      - float, "+/- Stdev" for the Latency row
;;     latency-p50-ms / latency-p75-ms / latency-p90-ms / latency-p99-ms
;;                            - floats, from wrk's own --latency
;;                              "Latency Distribution" block (wrk has no
;;                              p95 -- these are the 4 fixed percentiles
;;                              wrk itself reports). #f for any of these
;;                              if `output` came from a wrk run without
;;                              --latency (the block is simply absent).
;;     req-per-sec-avg / req-per-sec-max
;;                            - floats, wrk's own "1.74k"-style suffixes
;;                              (k/M) expanded to a plain number
;;     req-per-sec-stdev / req-per-sec-stdev-pct - floats
;;     total-requests         - integer, total requests actually sent
;;     actual-duration        - string, e.g. "8.10s" (wrk's real run time,
;;                              slightly over the requested -d)
;;     bytes-read             - string, e.g. "17.81MB" (left as wrk
;;                              formatted it -- see wrk-count->number/
;;                              wrk-duration-ms to convert a similarly-
;;                              suffixed value yourself)
;;     requests-per-sec       - float, wrk's own headline throughput number
;;     transfer-per-sec       - string, e.g. "2.20MB"
;;     raw                    - the exact output string passed in
;;                                      Raises if `output` doesn't look
;;                                      like a wrk report at all (missing
;;                                      the "Running ... test @ ..." /
;;                                      "Requests/sec:" lines every wrk run
;;                                      produces) -- a malformed/truncated
;;                                      report should fail loudly in a
;;                                      test, not silently return #f
;;                                      fields.
;;   (wrk-count->number s)           -> a wrk count string ("55569",
;;                                      "1.74k", "2.30M") as a plain number.
;;   (wrk-duration-ms s)             -> a wrk duration/latency string
;;                                      ("616.88us", "4.62ms", "9.79ms",
;;                                      "1.20s") as a float number of
;;                                      milliseconds.
;;
;; Not auto-imported anywhere — every script that wants this must (import
;; (creme wrk)) explicitly, same as any other file-based library.
;; ===========================================================================

(define-library (creme wrk)
  (export wrk-run wrk-parse wrk-count->number wrk-duration-ms)
  (import (scheme base) (scheme cxr) (creme process) (creme regex))
  (begin
    (define (kv-ref kvs key)
      (cond
       ((null? kvs) #f)
       ((eq? (car kvs) key) (cadr kvs))
       (else (kv-ref (cddr kvs) key))))

    (define (header-args headers)
      (apply append
             (map (lambda (h) (list "-H" (string-append (car h) ": " (cdr h)))) headers)))

    ;; (wrk-run url 'key value ...) -> see this file's own header comment.
    (define (wrk-run url . kvs)
      (let* ((threads (or (kv-ref kvs 'threads) 4))
             (conns (or (kv-ref kvs 'conns) 32))
             (duration (or (kv-ref kvs 'duration) "8s"))
             (accept (kv-ref kvs 'accept))
             (extra-headers (or (kv-ref kvs 'headers) '()))
             (headers (if accept (cons (cons "Accept" accept) extra-headers) extra-headers))
             (args (append (list "-t" (number->string threads)
                                  "-c" (number->string conns)
                                  "-d" duration)
                            (header-args headers)
                            (list "--latency" url)))
             (result (process-run "wrk" args)))
        (if (list-ref result 3)
            (wrk-parse (car result))
            (error "wrk-run: wrk exited with an error" (cadr result)))))

    (define (regex-required pattern output who)
      (let ((groups (regexp-search (regexp pattern) output)))
        (if groups
            (cdr groups)
            (error (string-append "wrk-parse: " who) output))))

    (define (regex-optional pattern output)
      (let ((groups (regexp-search (regexp pattern) output)))
        (if groups (cdr groups) #f)))

    ;; A count string ("55569", "1.74k", "2.30M") -> a plain number.
    (define (wrk-count->number s)
      (let* ((len (string-length s))
             (suffix (if (> len 0) (string-ref s (- len 1)) #\space)))
        (cond
         ((or (char=? suffix #\k) (char=? suffix #\K))
          (* 1000.0 (string->number (substring s 0 (- len 1)))))
         ((char=? suffix #\M)
          (* 1000000.0 (string->number (substring s 0 (- len 1)))))
         (else (string->number s)))))

    ;; A duration/latency string ("616.88us", "4.62ms", "9.79ms", "1.20s")
    ;; -> a float number of milliseconds. Checked longest-suffix-first (us/
    ;; ms/ns before the bare trailing "s"), since "4.62ms" also ends in "s".
    (define (wrk-duration-ms s)
      (let ((len (string-length s)))
        (cond
         ((and (>= len 2) (string=? (substring s (- len 2) len) "us"))
          (/ (string->number (substring s 0 (- len 2))) 1000.0))
         ((and (>= len 2) (string=? (substring s (- len 2) len) "ms"))
          (string->number (substring s 0 (- len 2))))
         ((and (>= len 2) (string=? (substring s (- len 2) len) "ns"))
          (/ (string->number (substring s 0 (- len 2))) 1000000.0))
         ((and (>= len 1) (string=? (substring s (- len 1) len) "s"))
          (* 1000.0 (string->number (substring s 0 (- len 1)))))
         (else (string->number s)))))

    ;; (wrk-parse output) -> see this file's own header comment for the
    ;; returned alist's shape.
    (define (wrk-parse output)
      (let* ((header (regex-required "Running (\\S+) test @ (\\S+)" output
                                      "not a wrk report (missing \"Running ... test @ ...\")"))
             (requested-duration (car header))
             (url (cadr header))
             (conn-line (regex-required "(\\d+) threads and (\\d+) connections" output
                                        "missing \"N threads and N connections\""))
             (latency (regex-required "Latency\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+([\\d.]+)%" output
                                       "missing the Latency stats row"))
             (req-per-sec (regex-required "Req/Sec\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+([\\d.]+)%" output
                                           "missing the Req/Sec stats row"))
             (totals (regex-required "(\\S+) requests in (\\S+), (\\S+) read" output
                                      "missing the \"N requests in ..., ... read\" summary line"))
             (requests-per-sec (regex-required "Requests/sec:\\s+([\\d.]+)" output
                                                "missing \"Requests/sec: ...\""))
             (transfer-per-sec (regex-required "Transfer/sec:\\s+(\\S+)" output
                                                "missing \"Transfer/sec: ...\""))
             ;; Only present when wrk was run with --latency -- absent
             ;; (each #f) for a plain wrk report.
             (p50 (regex-optional "50%\\s+(\\S+)" output))
             (p75 (regex-optional "75%\\s+(\\S+)" output))
             (p90 (regex-optional "90%\\s+(\\S+)" output))
             (p99 (regex-optional "99%\\s+(\\S+)" output)))
        (list
         (cons "url" url)
         (cons "requested-duration" requested-duration)
         (cons "threads" (string->number (car conn-line)))
         (cons "connections" (string->number (cadr conn-line)))
         (cons "latency-avg-ms" (wrk-duration-ms (car latency)))
         (cons "latency-stdev-ms" (wrk-duration-ms (cadr latency)))
         (cons "latency-max-ms" (wrk-duration-ms (caddr latency)))
         (cons "latency-stdev-pct" (string->number (car (cdddr latency))))
         (cons "latency-p50-ms" (and p50 (wrk-duration-ms (car p50))))
         (cons "latency-p75-ms" (and p75 (wrk-duration-ms (car p75))))
         (cons "latency-p90-ms" (and p90 (wrk-duration-ms (car p90))))
         (cons "latency-p99-ms" (and p99 (wrk-duration-ms (car p99))))
         (cons "req-per-sec-avg" (wrk-count->number (car req-per-sec)))
         (cons "req-per-sec-stdev" (wrk-count->number (cadr req-per-sec)))
         (cons "req-per-sec-max" (wrk-count->number (caddr req-per-sec)))
         (cons "req-per-sec-stdev-pct" (string->number (car (cdddr req-per-sec))))
         (cons "total-requests" (wrk-count->number (car totals)))
         (cons "actual-duration" (cadr totals))
         (cons "bytes-read" (caddr totals))
         (cons "requests-per-sec" (string->number (car requests-per-sec)))
         (cons "transfer-per-sec" (car transfer-per-sec))
         (cons "raw" output))))))
