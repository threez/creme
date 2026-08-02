-- Lua translation of competition/bench/workloads.scm -- same nine
-- workloads, timed the same way, for a same-machine cross-language
-- comparison alongside the creme/Crystal/Go/Ruby/Racket/Guile/Node numbers
-- in competition/bench.scm. Runs unmodified under both PUC-Rio Lua (5.1+)
-- and LuaJIT -- competition/bench.scm invokes this same file as both the
-- "lua" and "luajit" columns.
--
-- hashtable-test exercises Lua's own real, native table under a mixed
-- read/write/growth workload -- see that function's own comment for the
-- full design (shared identically, in shape, across every language's own
-- bench.* port), and specifically for why it uses STRING keys rather
-- than the small sequential integers vector-sum-test/record-test use:
-- a Lua table is hybrid array+hash storage, and small sequential integer
-- keys starting near 1 land in its array part, silently skipping the
-- hash part (and this whole workload's point) entirely. record-test uses a
-- distinct table per index -- see that function's own comment for why a
-- single reused instance doesn't give a meaningful measurement (LuaJIT's
-- own trace compiler can hoist/eliminate a provably-invariant reused
-- table just as an AOT compiler can).
--
-- Unlike bench.rb/bench.js (whose host languages have no guaranteed
-- tail-call optimization), Lua's own language spec guarantees PROPER tail
-- calls -- `return f(...)` never grows the call stack -- so sum-to is
-- written exactly as the canonical Scheme version is (a genuine tail-
-- recursive accumulation), not as an iterative loop.
--
-- build-list uses a genuine singly-linked cons cell (a two-field table
-- {car=..., cdr=...}, mirroring bench.cr's own Cons class), consing onto
-- the front in O(1) and reversing/measuring via manual pointer-chasing --
-- not Lua's own table.insert, so this stays a fair comparison for exactly
-- the allocation-pressure workload it's meant to be.
-- vector-sum-test uses a plain table as the "vector" (1-based integer
-- keys, the shape Lua's own table implementation optimizes as a real
-- array rather than a hash), matching the other variants' generic-vector
-- semantics.
-- string-build-test builds a table of "x" pieces and table.concat's them
-- once at the end -- Lua strings are immutable, so repeated `..`
-- concatenation is O(n^2); table.concat is Lua's own idiomatic O(n)
-- string-builder pattern, matching the Scheme benchmark's own
-- string-output-port builder idiom (each language's best-practice
-- string-building approach, not a deliberately-naive one).
--
-- Timing: os.clock() (CPU time, the only clock both PUC-Lua and LuaJIT
-- ship in their standard library with no C extension) is too coarse for
-- LuaJIT specifically -- its tick resolution here (~1/128s) means several
-- JIT-compiled workloads finish before a single tick elapses and read
-- back as exactly 0. Under LuaJIT (detected via the `jit` global table,
-- always present there and nowhere else), its own FFI binds gettimeofday
-- instead -- microsecond resolution, and its (timeval, NULL) signature is
-- identical across Linux/BSD/macOS, unlike clock_gettime's own
-- CLOCK_MONOTONIC constant (a different integer per platform), so no
-- per-OS branching is needed.
--
-- Plain PUC-Lua has no FFI, but its own os.clock() tick turns out to be
-- just as coarse here (also ~1/128s) -- and this benchmark's own fastest
-- workloads (tak(18,12,6)/string-build-test(4000)) finish inside a single
-- tick on plain Lua, reading back as an unmeasurable 0.0 too, not just
-- under LuaJIT. competition/lua/bench/monotonic.so (see monotonic.c's own
-- header comment for the one-time build command) is a tiny C extension exposing
-- CLOCK_MONOTONIC for exactly this — tried first, falling back to
-- os.clock() if it hasn't been built (every comparison variant in this
-- harness is optional; this is no different). Either way this benchmark
-- is pure computation (no I/O/sleep), so CPU time and wall-clock time
-- coincide for it in practice regardless of which of the three clocks
-- ends up used.
local now
if jit then
  local ffi = require("ffi")
  ffi.cdef [[
    typedef struct { long tv_sec; long tv_usec; } bench_timeval;
    int gettimeofday(bench_timeval *tv, void *tz);
  ]]
  local tv = ffi.new("bench_timeval")
  now = function()
    ffi.C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
  end
else
  package.cpath = package.cpath .. ";competition/lua/bench/?.so"
  local ok, monotonic = pcall(require, "monotonic")
  now = ok and monotonic.now or os.clock
end

local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end

local function sum_to(n, acc)
  if n == 0 then return acc end
  return sum_to(n - 1, acc + n)
end

local function build_list(n)
  local acc = nil
  for i = 0, n - 1 do
    acc = { car = i, cdr = acc }
  end
  return acc
end

local function list_reverse(list)
  local acc = nil
  local node = list
  while node do
    acc = { car = node.car, cdr = acc }
    node = node.cdr
  end
  return acc
end

local function list_length(list)
  local n = 0
  local node = list
  while node do
    n = n + 1
    node = node.cdr
  end
  return n
end

local function vector_sum_test(n)
  local v = {}
  for i = 1, n do
    v[i] = (i - 1) * 2
  end
  local acc = 0
  for i = 1, n do
    acc = acc + v[i]
  end
  return acc
end

local function hashtable_test(n)
  local h = {}
  for i = 0, n - 1 do
    h["k" .. i] = i * 2
  end
  local acc = 0
  for i = 0, n - 1 do
    local m = i % 4
    if m == 0 then
      h["k" .. (n + i)] = i
    elseif m == 1 then
      local key = "k" .. (i % n)
      h[key] = h[key] + 1
    else
      acc = acc + h["k" .. (i % n)]
    end
  end
  return acc
end

-- A distinct table per index (like vector_sum_test's distinct number per
-- index), not one reused mutable table -- see workloads.scm's own comment
-- on record-test for why that shape isn't a meaningful benchmark under a
-- sufficiently smart JIT/AOT compiler.
local function record_test(n)
  local v = {}
  for i = 0, n - 1 do
    v[i + 1] = { x = i, y = i * 2 }
  end
  local acc = 0
  for i = 1, n do
    local p = v[i]
    acc = acc + p.x + p.y
  end
  return acc
end

local function string_build_test(n)
  local parts = {}
  for i = 1, n do
    parts[i] = "x"
  end
  return #table.concat(parts)
end

local function tak(x, y, z)
  if not (y < x) then return z end
  return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))
end

-- Positions reuse the same cons list build_list uses, so nqueens conses a
-- position per placement exactly as the Scheme version does.
local function queens_safe(col, positions)
  local node = positions
  local dist = 1
  while node do
    if node.car == col or math.abs(node.car - col) == dist then return false end
    node = node.cdr
    dist = dist + 1
  end
  return true
end

local function nqueens(board_size, row, positions)
  row = row or 0
  positions = positions or nil
  if row == board_size then return 1 end
  local count = 0
  for col = 0, board_size - 1 do
    if queens_safe(col, positions) then
      count = count + nqueens(board_size, row + 1, { car = col, cdr = positions })
    end
  end
  return count
end

local function timed_run(name, fn)
  local start = now()
  local result = fn()
  local elapsed = now() - start
  print(name .. " = " .. tostring(result) .. "  (" .. tostring(elapsed) .. "s)")
  return result
end

local total_start = now()

timed_run("fib(27)", function() return fib(27) end)
timed_run("sum-to(2000000)", function() return sum_to(2000000, 0) end)
timed_run("build-list(200000) length+reverse", function() return list_length(list_reverse(build_list(200000))) end)
timed_run("vector-sum-test(500000)", function() return vector_sum_test(500000) end)
timed_run("hashtable-test(200000)", function() return hashtable_test(200000) end)
timed_run("record-test(500000)", function() return record_test(500000) end)
timed_run("string-build-test(4000) length", function() return string_build_test(4000) end)
timed_run("tak(18,12,6)", function() return tak(18, 12, 6) end)
timed_run("nqueens(9)", function() return nqueens(9) end)

print("total = " .. tostring(now() - total_start) .. "s")
