// Iterator chain rows (ops.toml, group "iter"): range-over-func iterators
// (package iter) over the slices package's slices.Values, slices.All and
// slices.Backward, and beside each chain the loop a person would write by
// hand (`_loop`). The standard library has no map, filter, take or take-while
// adapters; the four below are the ones a Go program writes for itself.
package main

import (
	"iter"
	"slices"
)

func mapSeq[T, U any](seq iter.Seq[T], f func(T) U) iter.Seq[U] {
	return func(yield func(U) bool) {
		for x := range seq {
			if !yield(f(x)) {
				return
			}
		}
	}
}

func filterSeq[T any](seq iter.Seq[T], keep func(T) bool) iter.Seq[T] {
	return func(yield func(T) bool) {
		for x := range seq {
			if keep(x) && !yield(x) {
				return
			}
		}
	}
}

func takeSeq2[K, V any](seq iter.Seq2[K, V], n int) iter.Seq2[K, V] {
	return func(yield func(K, V) bool) {
		if n <= 0 {
			return
		}
		taken := 0
		for k, v := range seq {
			if !yield(k, v) {
				return
			}
			taken++
			if taken >= n {
				return
			}
		}
	}
}

func takeWhileSeq2[K, V any](seq iter.Seq2[K, V], keep func(K, V) bool) iter.Seq2[K, V] {
	return func(yield func(K, V) bool) {
		for k, v := range seq {
			if !keep(k, v) || !yield(k, v) {
				return
			}
		}
	}
}

func triple(x int32) int32 { return x * 3 }
func isEven(x int32) bool  { return x&1 == 0 }

// Values in [-1000, 1000]: no sum below leaves i32.
func input(n uint64) []int32 {
	rng := newRng()
	v := make([]int32, n)
	for i := range v {
		v[i] = int32(rng.below(2001)) - 1000
	}
	return v
}

type Chain int

const (
	MapFilterSum Chain = iota
	EnumerateTake
	RevTakeWhile
	CollectMap
)

func chain(which Chain, v []int32) uint64 {
	switch which {
	case MapFilterSum:
		var sum int32
		for x := range filterSeq(mapSeq(slices.Values(v), triple), isEven) {
			sum += x
		}
		return uint64(int64(sum))
	case EnumerateTake:
		var sum int64
		for i, x := range takeSeq2(slices.All(v), len(v)/2) {
			sum += int64(i) * int64(x)
		}
		return uint64(sum)
	case RevTakeWhile:
		count := 0
		for range takeWhileSeq2(slices.Backward(v), func(_ int, x int32) bool { return x != 5000 }) {
			count++
		}
		return uint64(count)
	case CollectMap:
		// One allocation, asked for by hand, as in the C++ and Rust rows.
		out := slices.AppendSeq(make([]int32, 0, len(v)), mapSeq(slices.Values(v), triple))
		benchSinkSlice(out)
		return uint64(len(out)) + uint64(int64(out[len(out)-1]))
	}
	return 0
}

func loop(which Chain, v []int32) uint64 {
	n := len(v)
	switch which {
	case MapFilterSum:
		var sum int32
		for i := 0; i < n; i++ {
			x := v[i] * 3
			if x&1 == 0 {
				sum += x
			}
		}
		return uint64(int64(sum))
	case EnumerateTake:
		var sum int64
		for i := 0; i < n/2; i++ {
			sum += int64(i) * int64(v[i])
		}
		return uint64(sum)
	case RevTakeWhile:
		i := n
		for i != 0 && v[i-1] != 5000 {
			i--
		}
		return uint64(n - i)
	case CollectMap:
		out := make([]int32, 0, n)
		for i := 0; i < n; i++ {
			out = append(out, v[i]*3)
		}
		benchSinkSlice(out)
		return uint64(len(out)) + uint64(int64(out[n-1]))
	}
	return 0
}

func run(which Chain, byHand bool, n uint64) {
	passes := (uint64(1) << 22) / n
	v := input(n)
	ops := n
	if which == EnumerateTake {
		ops = n / 2
	}
	benchBegin(ops * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := uint64(0); p < passes; p++ {
			benchSinkSlice(v)
			if byHand {
				acc += loop(which, v)
			} else {
				acc += chain(which, v)
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

func main() {
	benchInit()
	for _, n := range []uint64{1000, 1000000} {
		if benchWant("iter.map_filter_sum", n) {
			run(MapFilterSum, false, n)
		}
		if benchWant("iter.map_filter_sum_loop", n) {
			run(MapFilterSum, true, n)
		}
		if benchWant("iter.enumerate_take", n) {
			run(EnumerateTake, false, n)
		}
		if benchWant("iter.enumerate_take_loop", n) {
			run(EnumerateTake, true, n)
		}
		if benchWant("iter.rev_take_while_count", n) {
			run(RevTakeWhile, false, n)
		}
		if benchWant("iter.rev_take_while_count_loop", n) {
			run(RevTakeWhile, true, n)
		}
		if benchWant("iter.collect_map", n) {
			run(CollectMap, false, n)
		}
		if benchWant("iter.collect_map_loop", n) {
			run(CollectMap, true, n)
		}
	}
}
