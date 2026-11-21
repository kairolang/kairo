// Vector rows (ops.toml, group "vector"): slices with append.
package main

import (
	"slices"
	"strings"
)

func pushI32(n uint64, reserve bool) {
	var v []int32
	benchBegin(n)
	for benchNext() {
		v = nil
		benchTic()
		if reserve {
			v = make([]int32, 0, n)
		}
		for i := uint64(0); i < n; i++ {
			v = append(v, int32(i))
		}
		benchToc(uint64(len(v)) + uint64(v[n-1]))
	}
	benchEnd()
	benchSinkSlice(v)
}

func pushString(length uint64) {
	const n = 1000000
	src := strings.Repeat("k", int(length))
	var v []string
	benchBegin(n)
	for benchNext() {
		v = nil
		benchTic()
		for i := 0; i < n; i++ {
			v = append(v, strings.Clone(src[:benchOpaque(length)]))
		}
		benchToc(uint64(len(v)) + uint64(len(v[n-1])))
	}
	benchEnd()
	benchSinkSlice(v)
}

func iterSum(n uint64) {
	passes := 10000000 / n
	rng := newRng()
	v := make([]int32, n)
	for i := range v {
		v[i] = int32(rng.next())
	}
	benchBegin(n * passes)
	for benchNext() {
		var sum int64
		benchTic()
		for p := uint64(0); p < passes; p++ {
			benchSinkSlice(v)
			for _, x := range v {
				sum += int64(x)
			}
		}
		benchToc(uint64(sum))
	}
	benchEnd()
}

func insertFront(n uint64) {
	var v []int32
	benchBegin(n)
	for benchNext() {
		v = nil
		benchTic()
		for i := uint64(0); i < n; i++ {
			v = slices.Insert(v, 0, int32(i))
		}
		benchToc(uint64(len(v)) + uint64(v[0]))
	}
	benchEnd()
	benchSinkSlice(v)
}

func createDestroy(elements uint64) {
	const ops = 1000000
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		for i := uint64(0); i < ops; i++ {
			var v []int32
			if elements != 0 {
				v = append(v, int32(benchOpaque(i)))
			}
			benchSinkSlice(v)
			acc += uint64(len(v))
		}
		benchToc(acc)
	}
	benchEnd()
}

// Go has no swap_remove; the two statements below are the idiom.
func swapRemove(n uint64) {
	v := make([]int32, 0, n)
	benchBegin(n)
	for benchNext() {
		v = v[:n]
		for i := range v {
			v[i] = int32(i)
		}
		rng := newRng()
		var acc uint64
		benchTic()
		for len(v) != 0 {
			i := rng.below(uint64(len(v)))
			acc = acc*31 + uint64(v[i])
			v[i] = v[len(v)-1]
			v = v[:len(v)-1]
		}
		benchToc(acc)
	}
	benchEnd()
}

func main() {
	benchInit()
	if benchWant("vector.push_i32", 10000000) {
		pushI32(10000000, false)
	}
	if benchWant("vector.push_i32_reserved", 10000000) {
		pushI32(10000000, true)
	}
	// A Kairo-only row: push through a vector variant that keeps its capacity inline.
	if benchWant("vector.push_i32_cap24", 10000000) {
		benchSkip()
	}
	for _, n := range []uint64{8, 32} {
		if benchWant("vector.push_string", n) {
			pushString(n)
		}
	}
	for _, n := range []uint64{10000, 10000000} {
		if benchWant("vector.iter_sum", n) {
			iterSum(n)
		}
	}
	if benchWant("vector.insert_front", 10000) {
		insertFront(10000)
	}
	for _, n := range []uint64{0, 1} {
		if benchWant("vector.create_destroy", n) {
			createDestroy(n)
		}
	}
	if benchWant("vector.swap_remove", 1000000) {
		swapRemove(1000000)
	}
}
