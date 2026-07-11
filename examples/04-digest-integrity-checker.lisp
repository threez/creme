(require 'file)
(require 'digest)

(define path "/tmp/crisp-example-integrity.txt")

(file:write path "Original important data.\n")
(define original-hash (digest:sha256 (file:read path)))
(println "Original SHA-256: " original-hash)

(file:append path "An unexpected extra line was appended!\n")
(define modified-hash (digest:sha256 (file:read path)))
(println "Modified SHA-256: " modified-hash)

(if (string=? original-hash modified-hash)
    (println "Integrity check: OK (no changes detected)")
    (println "Integrity check: FAILED (file has been modified)"))

(file:delete path)
