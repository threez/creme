// Node.js (V8) translation of examples/bench.scm -- same seven workloads,
// timed the same way, for a same-machine cross-language comparison
// alongside the creme/Crystal/Go/Ruby/Racket/Guile numbers in bench.scm.
//
// One workload is translated idiomatically rather than literally, since V8
// has no guaranteed tail-call optimization (mirroring bench.rb's own note
// for MRI):
//   - sum-to: an iterative loop (a literal recursive translation would blow
//     the stack at n=2,000,000 under V8, which doesn't TCO by default).
// build-list uses a genuine singly-linked Cons class (mirroring bench.cr's
// own Cons), consing onto the front in O(1) and reversing/measuring via
// manual pointer-chasing -- not a native Array's push/pop, so this stays a
// fair comparison for exactly the allocation-pressure workload it's meant
// to be.
// vector-sum-test uses a plain Array as the "vector" (a fixed-size,
// index-set/get generic array, not a typed array like Float64Array, to
// match the other variants' generic-vector semantics).
// string-build-test uses `+=` (V8 ropes/flattens repeated string
// concatenation efficiently, matching the Scheme benchmark's own
// string-output-port builder idiom).

function fib(n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

function sumTo(n, acc) {
  while (n > 0) {
    acc += n;
    n -= 1;
  }
  return acc;
}

class Cons {
  constructor(car, cdr) {
    this.car = car;
    this.cdr = cdr;
  }
}

function buildList(n) {
  let acc = null;
  for (let i = 0; i < n; i += 1) {
    acc = new Cons(i, acc);
  }
  return acc;
}

function listReverse(list) {
  let acc = null;
  let node = list;
  while (node) {
    acc = new Cons(node.car, acc);
    node = node.cdr;
  }
  return acc;
}

function listLength(list) {
  let n = 0;
  let node = list;
  while (node) {
    n += 1;
    node = node.cdr;
  }
  return n;
}

function vectorSumTest(n) {
  const v = new Array(n).fill(0);
  for (let i = 0; i < n; i += 1) {
    v[i] = i * 2;
  }
  let acc = 0;
  for (let i = 0; i < n; i += 1) {
    acc += v[i];
  }
  return acc;
}

function stringBuildTest(n) {
  let s = "";
  for (let i = 0; i < n; i += 1) {
    s += "x";
  }
  return s.length;
}

function tak(x, y, z) {
  return y < x ? tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) : z;
}

// Positions reuse the same Cons list buildList uses, so nqueens conses a
// position per placement exactly as the Scheme version does.
function queensSafe(col, positions) {
  let node = positions;
  let dist = 1;
  while (node) {
    if (node.car === col || Math.abs(node.car - col) === dist) return false;
    node = node.cdr;
    dist += 1;
  }
  return true;
}

function nqueens(boardSize, row = 0, positions = null) {
  if (row === boardSize) return 1;
  let count = 0;
  for (let col = 0; col < boardSize; col += 1) {
    if (queensSafe(col, positions)) {
      count += nqueens(boardSize, row + 1, new Cons(col, positions));
    }
  }
  return count;
}

function timedRun(name, fn) {
  const start = process.hrtime.bigint();
  const result = fn();
  const elapsed = Number(process.hrtime.bigint() - start) / 1e9;
  console.log(`${name} = ${result}  (${elapsed}s)`);
  return result;
}

const totalStart = process.hrtime.bigint();

timedRun("fib(27)", () => fib(27));
timedRun("sum-to(2000000)", () => sumTo(2000000, 0));
timedRun("build-list(200000) length+reverse", () => listLength(listReverse(buildList(200000))));
timedRun("vector-sum-test(500000)", () => vectorSumTest(500000));
timedRun("string-build-test(4000) length", () => stringBuildTest(4000));
timedRun("tak(18,12,6)", () => tak(18, 12, 6));
timedRun("nqueens(9)", () => nqueens(9));

console.log(`total = ${Number(process.hrtime.bigint() - totalStart) / 1e9}s`);
