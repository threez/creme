;; A plain Scheme script — nothing marks host-greet/host-version as coming
;; from the host program below; they're just free identifiers, resolved by
;; name against whatever the C host registered before running this file.
;; See host_demo.c and icecreme/README.md's "Embedding" section.
(import (scheme base) (scheme write))

(display (host-greet "world"))
(newline)
(display host-version)
(newline)
