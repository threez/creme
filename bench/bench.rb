# Ruby translation of examples/bench.scm — same seven workloads, timed the
# same way, for a same-machine cross-language comparison alongside the
# creme/Racket numbers in baseline.md.
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
timed_run("string-build-test(4000) length") { string_build_test(4_000) }
timed_run("tak(18,12,6)") { tak(18, 12, 6) }
timed_run("nqueens(9)") { nqueens(9) }

puts "total = #{Process.clock_gettime(Process::CLOCK_MONOTONIC) - total_start}s"
