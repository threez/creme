// Native Go counterpart to competition/bench.scm — same nine workloads,
// same sizes, implemented directly in Go (no Scheme::Interpreter involved).
// Gives a second compiled-code baseline alongside the native-Crystal one for
// the identical work.
//
// hashtable-test exercises Go's own real native map under a mixed read/
// write/growth workload -- see that function's own comment for the full
// design (shared identically, in shape, across every language's own
// bench.* port). record-test uses a distinct *Point per index (see that
// function's own comment for why a single reused instance doesn't work
// here).
//
// Build: go build -o bin/bench_go competition/go/bench/bench.go
// Run:   bin/bench_go
package main

import (
	"fmt"
	"runtime"
	"strings"
	"time"
)

func fib(n int) int {
	if n < 2 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func sumTo(n int, acc int64) int64 {
	if n == 0 {
		return acc
	}
	return sumTo(n-1, acc+int64(n))
}

// Scheme's build-list conses onto the front of a singly-linked list, an O(1)
// op; the Go counterpart uses a linked Cons so build+reverse has the same
// asymptotics instead of a slice's O(n) prepend (matching bench.cr's Cons).
type Cons struct {
	car int
	cdr *Cons
}

func buildList(n int) *Cons {
	var acc *Cons
	for i := 0; i != n; i++ {
		acc = &Cons{car: i, cdr: acc}
	}
	return acc
}

func listReverse(list *Cons) *Cons {
	var acc *Cons
	for node := list; node != nil; node = node.cdr {
		acc = &Cons{car: node.car, cdr: acc}
	}
	return acc
}

func listLength(list *Cons) int {
	n := 0
	for node := list; node != nil; node = node.cdr {
		n++
	}
	return n
}

func vectorSumTest(n int) int64 {
	v := make([]int64, n)
	for i := range n {
		v[i] = int64(i) * 2
	}
	var acc int64
	for i := 0; i != n; i++ {
		acc += v[i]
	}
	return acc
}

// hashtable-test against Go's own real native map -- see competition/
// scheme/bench/creme.scm's own comment for the full mixed read/write/
// growth design and why this workload is defined per-language rather
// than a hand-rolled shared algorithm. String keys ("k" + i), not raw
// integers -- matches every other language's own bench.* port so the
// same checksum is comparable across all of them.
func hashtableTest(n int) int64 {
	h := make(map[string]int64, n)
	for i := 0; i < n; i++ {
		h[fmt.Sprintf("k%d", i)] = int64(i) * 2
	}
	var acc int64
	for i := 0; i < n; i++ {
		switch i % 4 {
		case 0:
			h[fmt.Sprintf("k%d", n+i)] = int64(i)
		case 1:
			key := fmt.Sprintf("k%d", i%n)
			h[key] = h[key] + 1
		default:
			acc += h[fmt.Sprintf("k%d", i%n)]
		}
	}
	return acc
}

type Point struct {
	x, y int
}

// A distinct *Point per index (like vectorSumTest's distinct int64 per
// index), not one reused mutable instance -- a reused non-escaping
// instance risks the same compiler-hoisting trap observed under Crystal
// --release (see workloads.scm's own comment on record-test).
func recordTest(n int) int64 {
	v := make([]*Point, n)
	for i := range n {
		v[i] = &Point{x: i, y: i * 2}
	}
	var acc int64
	for i := 0; i < n; i++ {
		acc += int64(v[i].x + v[i].y)
	}
	return acc
}

func stringBuildTest(n int) int {
	var builder strings.Builder
	for range n {
		builder.WriteString("x")
	}
	return len(builder.String())
}

func tak(x, y, z int) int {
	if y < x {
		return tak(tak(x-1, y, z), tak(y-1, z, x), tak(z-1, x, y))
	}
	return z
}

// Positions reuse the same Cons list buildList uses, so nqueens conses a
// position per placement exactly as the Scheme version does — a fair
// allocation profile for the backtracking workload.
func queensSafe(col int, positions *Cons) bool {
	dist := 1
	for node := positions; node != nil; node = node.cdr {
		if node.car == col || abs(node.car-col) == dist {
			return false
		}
		dist++
	}
	return true
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func nqueens(boardSize, row int, positions *Cons) int {
	if row == boardSize {
		return 1
	}
	count := 0
	for col := range boardSize {
		if queensSafe(col, positions) {
			count += nqueens(boardSize, row+1, &Cons{car: col, cdr: positions})
		}
	}
	return count
}

// timedRun prints "<name> = <result>  (<elapsed>s)" — two spaces before the
// paren, trailing s inside — exactly the shape bench.scm's parse-elapsed-alist
// regexp expects. Elapsed uses %g so a sub-fixed-point result prints in
// scientific notation ("3.19e-05s"), which that regexp already tolerates.
func timedRun(name string, fn func() int64) int64 {
	start := time.Now()
	result := fn()
	elapsed := time.Since(start).Seconds()
	fmt.Printf("%s = %d  (%gs)\n", name, result, elapsed)
	return result
}

func main() {
	// The workloads are sequential, but pin to one core anyway so the runtime
	// (GC, background work) can't use extra cores the single-threaded Crystal/
	// Ruby/creme baselines this is compared against don't have.
	runtime.GOMAXPROCS(1)

	totalStart := time.Now()

	timedRun("fib(27)", func() int64 { return int64(fib(27)) })
	timedRun("sum-to(2000000)", func() int64 { return sumTo(2000000, 0) })
	timedRun("build-list(200000) length+reverse", func() int64 {
		return int64(listLength(listReverse(buildList(200000))))
	})
	timedRun("vector-sum-test(500000)", func() int64 { return vectorSumTest(500000) })
	timedRun("hashtable-test(200000)", func() int64 { return hashtableTest(200000) })
	timedRun("record-test(500000)", func() int64 { return recordTest(500000) })
	timedRun("string-build-test(4000) length", func() int64 { return int64(stringBuildTest(4000)) })
	timedRun("tak(18,12,6)", func() int64 { return int64(tak(18, 12, 6)) })
	timedRun("nqueens(9)", func() int64 { return int64(nqueens(9, 0, nil)) })

	fmt.Printf("total = %gs\n", time.Since(totalStart).Seconds())
}
