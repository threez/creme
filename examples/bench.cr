# Native Crystal counterpart to bench.scm — same five workloads, same
# sizes, implemented directly in Crystal (no Scheme::Interpreter involved).
# Gives a compiled-code baseline to set alongside the interpreter's and
# Racket's numbers for the identical work.
#
# Build: crystal build --release examples/bench.cr -o bin/bench_cr
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

def string_build_test(n : Int32) : Int32
  s = ""
  i = 0
  while i != n
    s += "x"
    i += 1
  end
  s.size
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
timed_run("string-build-test(4000) length") { string_build_test(4_000) }

puts "total = #{(Time.instant - total_start).total_seconds}s"
