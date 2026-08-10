# creme bench

## Environment

- Commit: 65aef6b
- Crystal: Crystal 1.20.2 [84f389ac5424] (2026-05-15)
- OS: FreeBSD
- Arch: amd64
- CPU: AMD Ryzen 9 7900X 12-Core Processor
- Cores: 8
- Memory: 15.6 GiB

## Runtime versions

- creme: 0.1.0
- icecreme: creme 0.1.0 (icecreme/self-hosted, FreeBSD/amd64)
- Crystal: Crystal 1.20.2 [84f389ac5424] (2026-05-15) (native comparison floor)
- Go: go version go1.24.13 freebsd/amd64
- Ruby: ruby 3.4.9 (2026-03-11 revision 76cca827ab) +PRISM [amd64-freebsd15]
- Racket: Welcome to Racket v9.2 [cs].
- Guile: guile (GNU Guile) 3.0.11
- Node: v24.18.0
- Lua: Lua 5.5.0  Copyright (C) 1994-2025 Lua.org, PUC-Rio
- LuaJIT: LuaJIT 2.1.1779665312 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/

## bench: measurements (seconds)

single-threaded — 1 of 8 logical cores

| workload                          | crystal |    node |      go |  luajit |  racket |   guile | icecreme |   lua55 |   creme |    ruby |
| --------------------------------- | ------- | ------- | ------- | ------- | ------- | ------- | -------- | ------- | ------- | ------- |
| fib(27)                           | 0.00054 | 0.00153 | 0.00060 | 0.00144 | 0.00085 | 0.00308 |  0.00935 | 0.00705 | 0.03069 | 0.01010 |
| sum-to(2000000)                   | 0.00037 | 0.00165 | 0.04058 | 0.00148 | 0.00134 | 0.00646 |  0.00965 | 0.02271 | 0.02042 | 0.02960 |
| build-list(200000) length+reverse | 0.00846 | 0.01845 | 0.00807 | 0.02449 | 0.00360 | 0.00490 |  0.00714 | 0.03181 | 0.01882 | 0.05406 |
| vector-sum-test(500000)           | 0.00105 | 0.00303 | 0.00032 | 0.00224 | 0.00194 | 0.00264 |  0.00960 | 0.00738 | 0.01591 | 0.02300 |
| hashtable-test(200000)            | 0.03131 | 0.04155 | 0.04553 | 0.03120 | 0.10894 | 0.10672 |  0.07740 | 0.08052 | 0.10943 | 0.10059 |
| record-test(500000)               | 0.00348 | 0.00684 | 0.01011 | 0.05522 | 0.01180 | 0.01154 |  0.03677 | 0.06705 | 0.06148 | 0.09714 |
| string-build-test(4000) length    | 0.00001 | 0.00012 | 0.00002 | 0.00007 | 0.00020 | 0.00023 |  0.00006 | 0.00008 | 0.00032 | 0.00022 |
| tak(18,12,6)                      | 0.00005 | 0.00024 | 0.00006 | 0.00026 | 0.00007 | 0.00031 |  0.00114 | 0.00083 | 0.00182 | 0.00119 |
| nqueens(9)                        | 0.00048 | 0.00113 | 0.00051 | 0.00200 | 0.00078 | 0.00107 |  0.00882 | 0.00919 | 0.01323 | 0.01187 |
| total                             | 0.04578 | 0.07660 | 0.10587 | 0.11843 | 0.12980 | 0.13703 |  0.15998 | 0.22671 | 0.27220 | 0.32783 |

## bench: comparison matrix

row's total time / column's total time

|          | crystal | node |   go | luajit | racket | guile | icecreme | lua55 | creme | ruby |
| -------- | ------- | ---- | ---- | ------ | ------ | ----- | -------- | ----- | ----- | ---- |
| crystal  |       - | 0.6x | 0.4x |   0.4x |   0.4x |  0.3x |     0.3x |  0.2x |  0.2x | 0.1x |
| node     |    1.7x |    - | 0.7x |   0.6x |   0.6x |  0.6x |     0.5x |  0.3x |  0.3x | 0.2x |
| go       |    2.3x | 1.4x |    - |   0.9x |   0.8x |  0.8x |     0.7x |  0.5x |  0.4x | 0.3x |
| luajit   |    2.6x | 1.5x | 1.1x |      - |   0.9x |  0.9x |     0.7x |  0.5x |  0.4x | 0.4x |
| racket   |    2.8x | 1.7x | 1.2x |   1.1x |      - |  0.9x |     0.8x |  0.6x |  0.5x | 0.4x |
| guile    |    3.0x | 1.8x | 1.3x |   1.2x |   1.1x |     - |     0.9x |  0.6x |  0.5x | 0.4x |
| icecreme |    3.5x | 2.1x | 1.5x |   1.4x |   1.2x |  1.2x |        - |  0.7x |  0.6x | 0.5x |
| lua55    |    5.0x | 3.0x | 2.1x |   1.9x |   1.7x |  1.7x |     1.4x |     - |  0.8x | 0.7x |
| creme    |    5.9x | 3.6x | 2.6x |   2.3x |   2.1x |  2.0x |     1.7x |  1.2x |     - | 0.8x |
| ruby     |    7.2x | 4.3x | 3.1x |   2.8x |   2.5x |  2.4x |     2.0x |  1.4x |  1.2x |    - |
