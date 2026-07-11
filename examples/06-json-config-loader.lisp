(require 'file)
(require 'json)
(require 'env)

(define config-path "/tmp/crisp-example-config.json")

(file:write config-path "{\"host\":\"localhost\",\"port\":8080,\"debug\":false}")
(env:set! "CRISP_EXAMPLE_PORT" "9090")

(define config (json:parse (file:read config-path)))

(define (config-ref key default)
  (let ((entry (assoc key config)))
    (if entry (cdr entry) default)))

(define port
  (let ((override (env:get "CRISP_EXAMPLE_PORT")))
    (if override (string->number override) (config-ref "port" 8080))))

(println "host:  " (config-ref "host" "localhost"))
(println "port:  " port " (overridden by CRISP_EXAMPLE_PORT env var; config file said " (config-ref "port" 8080) ")")
(println "debug: " (config-ref "debug" #f))

(file:delete config-path)
(env:delete! "CRISP_EXAMPLE_PORT")
