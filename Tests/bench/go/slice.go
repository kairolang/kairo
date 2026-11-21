// Slice rows (ops.toml, group "slice"): package slices over slice storage.
// slices.Sort and slices.SortFunc (pattern-defeating quicksort) pair with
// std::sort, slices.SortStableFunc (insertion sort and symmerge, the only
// stable sort Go's library has) with std::stable_sort.
package main

import (
	"cmp"
	"slices"
)

type Wide struct {
	key uint64
	pad [7]uint64
}

func cmpWide(a, b Wide) int { return cmp.Compare(a.key, b.key) }

// One element type of the sort rows: how to make one, how to digest one for
// the checksum, and its two sorts.
type element[T any] struct {
	make     func(rng *Rng, i uint64) T
	digest   func(x T) uint64
	unstable func(v []T)
	stable   func(v []T)
}

func sortRow[T any](n uint64, stable bool, e element[T]) {
	rng := newRng()
	input := make([]T, n)
	for i := range input {
		input[i] = e.make(&rng, uint64(i))
	}
	var work []T
	benchBegin(n)
	for benchNext() {
		work = append(work[:0], input...)
		benchTic()
		if stable {
			e.stable(work)
		} else {
			e.unstable(work)
		}
		benchToc(e.digest(work[0]) ^ (e.digest(work[n/2]) * 3) ^ (e.digest(work[n-1]) * 5))
	}
	benchEnd()
}

var i32Element = element[int32]{
	make:     func(rng *Rng, _ uint64) int32 { return int32(rng.next()) },
	digest:   func(x int32) uint64 { return uint64(uint32(x)) },
	unstable: func(v []int32) { slices.Sort(v) },
	stable:   func(v []int32) { slices.SortStableFunc(v, cmp.Compare[int32]) },
}

var u64Element = element[uint64]{
	make:     func(rng *Rng, _ uint64) uint64 { return rng.next() },
	digest:   func(x uint64) uint64 { return x },
	unstable: func(v []uint64) { slices.Sort(v) },
	stable:   func(v []uint64) { slices.SortStableFunc(v, cmp.Compare[uint64]) },
}

var stringElement = element[string]{
	make:     func(rng *Rng, _ uint64) string { return rng.letters(16, 26) },
	digest:   func(x string) uint64 { return benchFastHashBytes([]byte(x)) },
	unstable: func(v []string) { slices.Sort(v) },
	stable:   func(v []string) { slices.SortStableFunc(v, cmp.Compare[string]) },
}

var wideElement = element[Wide]{
	make: func(rng *Rng, i uint64) Wide {
		w := Wide{key: rng.next()}
		for j := range w.pad {
			w.pad[j] = i
		}
		return w
	},
	digest:   func(x Wide) uint64 { return x.key ^ x.pad[0] },
	unstable: func(v []Wide) { slices.SortFunc(v, cmpWide) },
	stable:   func(v []Wide) { slices.SortStableFunc(v, cmpWide) },
}

func binarySearch(n uint64) {
	const ops = 1 << 16
	a := make([]uint64, n)
	for i := range a {
		a[i] = 3*uint64(i) + 1
	}
	benchBegin(ops)
	for benchNext() {
		rng := newRng()
		var acc uint64
		benchTic()
		for i := 0; i < ops; i++ {
			q := rng.below(3 * n)
			if idx, found := slices.BinarySearch(a, q); found {
				acc += uint64(idx)
			} else {
				acc += 1 << 40
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

func reverse(n uint64) {
	passes := ((uint64(1) << 22) / n) | 1
	a := make([]uint64, n)
	for i := range a {
		a[i] = uint64(i)
	}
	benchBegin(n * passes)
	for benchNext() {
		benchTic()
		for p := uint64(0); p < passes; p++ {
			benchSinkSlice(a)
			slices.Reverse(a)
		}
		benchToc(a[0] + a[n-1])
	}
	benchEnd()
}

func fill(n uint64) {
	passes := (uint64(1) << 22) / n
	a := make([]uint64, n)
	benchBegin(n * passes)
	for benchNext() {
		benchTic()
		for p := uint64(0); p < passes; p++ {
			v := benchOpaque(p)
			for i := range a {
				a[i] = v
			}
			benchSinkSlice(a)
		}
		benchToc(a[0] + a[n-1])
	}
	benchEnd()
}

func main() {
	benchInit()
	const n = 1000000
	if benchWant("slice.sort_unstable_i32", n) {
		sortRow(n, false, i32Element)
	}
	if benchWant("slice.sort_unstable_u64", n) {
		sortRow(n, false, u64Element)
	}
	if benchWant("slice.sort_unstable_string", n) {
		sortRow(n, false, stringElement)
	}
	if benchWant("slice.sort_unstable_struct64", n) {
		sortRow(n, false, wideElement)
	}
	if benchWant("slice.sort_stable_i32", n) {
		sortRow(n, true, i32Element)
	}
	if benchWant("slice.sort_stable_u64", n) {
		sortRow(n, true, u64Element)
	}
	if benchWant("slice.sort_stable_string", n) {
		sortRow(n, true, stringElement)
	}
	if benchWant("slice.sort_stable_struct64", n) {
		sortRow(n, true, wideElement)
	}
	for _, m := range []uint64{1024, 10000000} {
		if benchWant("slice.binary_search", m) {
			binarySearch(m)
		}
	}
	for _, m := range []uint64{4096, 1000000} {
		if benchWant("slice.reverse", m) {
			reverse(m)
		}
	}
	for _, m := range []uint64{4096, 1000000} {
		if benchWant("slice.fill", m) {
			fill(m)
		}
	}
}
