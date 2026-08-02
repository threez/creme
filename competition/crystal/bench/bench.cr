# Native Crystal counterpart to competition/bench.scm — same nine
# workloads, same sizes, implemented directly in Crystal (no
# Creme::Interpreter involved). Gives a compiled-code baseline to set
# alongside the interpreter's and Racket's numbers for the identical work.
#
# hashtable-test exercises Crystal's own real, native Hash under a mixed
# read/write/growth workload -- see that function's own comment for the
# full design (shared identically, in shape, across every language's own
# bench.* port). record-test uses a plain mutable Point
# class, matching define-record-type's own idiomatic native-record
# counterpart the same way vector-sum-test already uses a native Array.
#
# Build: crystal build --release --no-debug competition/crystal/bench/bench.cr -o bin/bench_cr
# Run:   bin/bench_cr

def fib(n : Int32) : Int32
  n < 2 ? n : fib(n - 1) + fib(n - 2)
end

def sum_to(n : Int32, acc : Int64) : Int64
  n == 0 ? acc : sum_to(n - 1, acc + n)
end

# Scheme's build-list conses onto the front of a singly-linked list, an
# O(1) op; the Crystal counterpart uses a linked Cons so build+reverse
# has the same asymptotics instead of Array's O(n) unshift/prepend.
class Cons
  getter car : Int32
  getter cdr : Cons?

  def initialize(@car, @cdr)
  end
end

def build_list(n : Int32) : Cons?
  acc = nil
  i = 0
  while i != n
    acc = Cons.new(i, acc)
    i += 1
  end
  acc
end

def list_reverse(list : Cons?) : Cons?
  acc = nil
  node = list
  while node
    acc = Cons.new(node.car, acc)
    node = node.cdr
  end
  acc
end

def list_length(list : Cons?) : Int32
  n = 0
  node = list
  while node
    n += 1
    node = node.cdr
  end
  n
end

def vector_sum_test(n : Int32) : Int64
  v = Array.new(n, 0_i64)
  i = 0
  while i < n
    v[i] = i.to_i64 * 2
    i += 1
  end
  acc = 0_i64
  i = 0
  while i != n
    acc += v[i]
    i += 1
  end
  acc
end

# hashtable-test against Crystal's own real, native Hash -- see
# competition/scheme/bench/creme.scm's own comment for the full mixed
# read/write/growth design and why this workload is defined per-language
# rather than a hand-rolled shared algorithm. String keys ("k" + i), not
# raw integers -- matches every other language's own bench.* port so the
# same checksum is comparable across all of them.
def hashtable_test(n : Int32) : Int64
  h = Hash(String, Int64).new
  i = 0
  while i < n
    h["k#{i}"] = i.to_i64 * 2
    i += 1
  end
  acc = 0_i64
  i = 0
  while i < n
    case i % 4
    when 0
      h["k#{n + i}"] = i.to_i64
    when 1
      key = "k#{i % n}"
      h[key] = h[key] + 1
    else
      acc += h["k#{i % n}"]
    end
    i += 1
  end
  acc
end

class Point
  getter x : Int32
  getter y : Int32

  def initialize(@x, @y)
  end
end

# A distinct Point per index (like vector_sum_test's distinct Int64 per
# index), not one reused mutable instance -- a reused non-escaping instance
# let LLVM (under --release) prove it's loop-invariant and fold the whole
# benchmark away to a near-zero-cost no-op. See workloads.scm's own comment
# on record-test for the full story.
def record_test(n : Int32) : Int64
  v = Array(Point).new(n) { |i| Point.new(i, i * 2) }
  acc = 0_i64
  i = 0
  while i < n
    p = v[i]
    acc += p.x + p.y
    i += 1
  end
  acc
end

def string_build_test(n : Int32) : Int32
  s = String.build { |builder| n.times { builder << "x" } }
  s.size
end

def tak(x : Int32, y : Int32, z : Int32) : Int32
  y < x ? tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) : z
end

# Positions reuse the same Cons list build_list uses, so nqueens conses a
# position per placement exactly as the Scheme version does — a fair
# allocation profile for the backtracking workload.
def queens_safe?(col : Int32, positions : Cons?) : Bool
  node = positions
  dist = 1
  while node
    return false if node.car == col || (node.car - col).abs == dist
    node = node.cdr
    dist += 1
  end
  true
end

def nqueens(board_size : Int32, row : Int32 = 0, positions : Cons? = nil) : Int32
  return 1 if row == board_size
  count = 0
  col = 0
  while col < board_size
    count += nqueens(board_size, row + 1, Cons.new(col, positions)) if queens_safe?(col, positions)
    col += 1
  end
  count
end

def timed_run(name : String, &block : -> _)
  start = Time.instant
  result = block.call
  elapsed = (Time.instant - start).total_seconds
  puts "#{name} = #{result}  (#{elapsed}s)"
  result
end

total_start = Time.instant

timed_run("fib(27)") { fib(27) }
timed_run("sum-to(2000000)") { sum_to(2_000_000, 0_i64) }
timed_run("build-list(200000) length+reverse") { list_length(list_reverse(build_list(200_000))) }
timed_run("vector-sum-test(500000)") { vector_sum_test(500_000) }
timed_run("hashtable-test(200000)") { hashtable_test(200_000) }
timed_run("record-test(500000)") { record_test(500_000) }
timed_run("string-build-test(4000) length") { string_build_test(4_000) }
timed_run("tak(18,12,6)") { tak(18, 12, 6) }
timed_run("nqueens(9)") { nqueens(9) }

puts "total = #{(Time.instant - total_start).total_seconds}s"
