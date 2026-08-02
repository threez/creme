# Ruby translation of competition/bench/workloads.scm — same nine
# workloads, timed the same way, for a same-machine cross-language
# comparison alongside the creme/Racket numbers in competition/bench.scm.
#
# hashtable-test exercises Ruby's own real Hash under a mixed read/write/
# growth workload -- see that method's own comment for the full design
# (shared identically, in shape, across every language's own bench.*
# port). record-test uses a distinct Point
# instance per index -- see that method's own comment for why a single
# reused instance doesn't give a meaningful measurement here.
#
# One workload is translated idiomatically rather than literally, since
# Ruby (MRI) has no guaranteed tail-call optimization:
#   - sum-to: an iterative loop (a literal recursive translation would blow
#     the stack at n=2,000,000 under MRI, which doesn't TCO by default).
# build-list uses a genuine singly-linked Cons class (mirroring bench.cr's
# own Cons), consing onto the front in O(1) and reversing/measuring via
# manual pointer-chasing — same allocate-a-heap-object-per-element pattern
# Scheme's build-list has, not Array#<<'s amortized-O(1)-but-no-per-element-
# allocation behavior, so this stays a fair comparison for exactly the
# allocation-pressure workload it's meant to be.
# vector-sum-test uses a plain Array as the "vector" (Ruby's Array supports
# O(1) amortized index get/set, matching vector-ref/vector-set!).
# string-build-test uses `<<` (Ruby's own mutating, amortized-O(1)-append
# String builder idiom), matching the Scheme benchmark's own switch to a
# string output port — the comparison is each language's best-practice
# string-building approach, not a deliberately-naive allocate-per-append one.

def fib(n)
  n < 2 ? n : fib(n - 1) + fib(n - 2)
end

def sum_to(n, acc)
  while n > 0
    acc += n
    n -= 1
  end
  acc
end

class Cons
  attr_reader :car, :cdr

  def initialize(car, cdr)
    @car = car
    @cdr = cdr
  end
end

def build_list(n)
  acc = nil
  i = 0
  while i < n
    acc = Cons.new(i, acc)
    i += 1
  end
  acc
end

def list_reverse(list)
  acc = nil
  node = list
  while node
    acc = Cons.new(node.car, acc)
    node = node.cdr
  end
  acc
end

def list_length(list)
  n = 0
  node = list
  while node
    n += 1
    node = node.cdr
  end
  n
end

def vector_sum_test(n)
  v = Array.new(n, 0)
  i = 0
  while i < n
    v[i] = i * 2
    i += 1
  end
  acc = 0
  i = 0
  while i < n
    acc += v[i]
    i += 1
  end
  acc
end

# hashtable-test against Ruby's own real Hash (see competition/scheme/
# bench/creme.scm's own comment for the full mixed read/write/growth
# design and why this workload is defined per-language rather than a
# hand-rolled shared algorithm). String keys ("k" + i), not raw integers
# -- matches every other language's own bench.* port so the same
# checksum is comparable across all of them (also happens to matter for
# Lua specifically, though not Ruby: see that file's own comment).
def hashtable_test(n)
  h = {}
  i = 0
  while i < n
    h["k#{i}"] = i * 2
    i += 1
  end
  acc = 0
  i = 0
  while i < n
    case i % 4
    when 0
      h["k#{n + i}"] = i
    when 1
      key = "k#{i % n}"
      h[key] += 1
    else
      acc += h["k#{i % n}"]
    end
    i += 1
  end
  acc
end

Point = Struct.new(:x, :y)

# A distinct Point per index (like vector_sum_test's distinct Integer per
# index), not one reused mutable instance -- see workloads.scm's own
# comment on record-test for why that shape risks being optimized away
# under a smarter (AOT/JIT) host than MRI.
def record_test(n)
  v = Array.new(n) { |i| Point.new(i, i * 2) }
  acc = 0
  i = 0
  while i < n
    p = v[i]
    acc += p.x + p.y
    i += 1
  end
  acc
end

def string_build_test(n)
  s = String.new
  i = 0
  while i < n
    s << "x"
    i += 1
  end
  s.length
end

def tak(x, y, z)
  y < x ? tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) : z
end

# Positions reuse the same Cons list build_list uses, so nqueens conses a
# position per placement exactly as the Scheme version does.
def queens_safe?(col, positions)
  node = positions
  dist = 1
  while node
    return false if node.car == col || (node.car - col).abs == dist
    node = node.cdr
    dist += 1
  end
  true
end

def nqueens(board_size, row = 0, positions = nil)
  return 1 if row == board_size
  count = 0
  col = 0
  while col < board_size
    count += nqueens(board_size, row + 1, Cons.new(col, positions)) if queens_safe?(col, positions)
    col += 1
  end
  count
end

def timed_run(name)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "#{name} = #{result}  (#{elapsed}s)"
  result
end

total_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

timed_run("fib(27)") { fib(27) }
timed_run("sum-to(2000000)") { sum_to(2_000_000, 0) }
timed_run("build-list(200000) length+reverse") { list_length(list_reverse(build_list(200_000))) }
timed_run("vector-sum-test(500000)") { vector_sum_test(500_000) }
timed_run("hashtable-test(200000)") { hashtable_test(200_000) }
timed_run("record-test(500000)") { record_test(500_000) }
timed_run("string-build-test(4000) length") { string_build_test(4_000) }
timed_run("tak(18,12,6)") { tak(18, 12, 6) }
timed_run("nqueens(9)") { nqueens(9) }

puts "total = #{Process.clock_gettime(Process::CLOCK_MONOTONIC) - total_start}s"
