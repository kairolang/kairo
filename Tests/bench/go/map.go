// Hash map and set rows (ops.toml, group "map"): the built-in map. Go's map
// takes no hasher, so the `_fast` rows, which name one, are not run.
package main

import (
	"maps"
	"strings"
)

// A bijection on u64, so the "random" keys are distinct.
func scramble(i uint64) uint64 { return i * benchSeed }

func insert(n uint64, sequential bool) {
	var m map[uint64]uint64
	benchBegin(n)
	for benchNext() {
		m = make(map[uint64]uint64)
		benchTic()
		for i := uint64(0); i < n; i++ {
			if sequential {
				m[i] = i
			} else {
				m[scramble(i)] = i
			}
		}
		benchToc(uint64(len(m)))
	}
	benchEnd()
	benchSinkAny(m)
}

func lookup(n uint64, hit bool) {
	const ops = 1 << 20
	m := make(map[uint64]uint64, n)
	for i := uint64(0); i < n; i++ {
		m[scramble(i)] = i
	}
	benchBegin(ops)
	for benchNext() {
		rng := newRng()
		var acc uint64
		benchTic()
		for i := 0; i < ops; i++ {
			j := rng.below(n)
			if !hit {
				j += n
			}
			if v, ok := m[scramble(j)]; ok {
				acc += v
			} else {
				acc += 7
			}
		}
		benchToc(acc)
	}
	benchEnd()
	benchSinkAny(m)
}

func churn(n uint64) {
	const ops = 1 << 20
	m := make(map[uint64]uint64)
	for i := uint64(0); i < n; i++ {
		m[scramble(i)] = i
	}
	next := n
	benchBegin(ops)
	for benchNext() {
		benchTic()
		for i := 0; i < ops; i++ {
			delete(m, scramble(next-n))
			m[scramble(next)] = next
			next++
		}
		benchToc(uint64(len(m)))
	}
	benchEnd()
	benchSinkAny(m)
}

func iterate(n uint64) {
	const passes = 4
	m := make(map[uint64]uint64)
	for i := uint64(0); i < n; i++ {
		m[scramble(i)] = i
	}
	benchBegin(n * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := 0; p < passes; p++ {
			benchSinkAny(m)
			for _, v := range m {
				acc += v
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

func stringKeys(n uint64, length int) []string {
	rng := newRng()
	keys := make([]string, n)
	for i := range keys {
		keys[i] = rng.letters(length, 26)
	}
	return keys
}

func strInsert(length uint64) {
	const n = 100000
	keys := stringKeys(n, int(length))
	var m map[string]uint64
	benchBegin(n)
	for benchNext() {
		m = make(map[string]uint64)
		benchTic()
		for i := uint64(0); i < n; i++ {
			// A string key is shared, not copied, by an assignment; the
			// C++ and Rust rows copy it, so this one does too.
			m[strings.Clone(keys[i])] = i
		}
		benchToc(uint64(len(m)))
	}
	benchEnd()
	benchSinkAny(m)
}

func strLookup(length uint64) {
	const n, ops = 100000, 1 << 18
	keys := stringKeys(n, int(length))
	m := make(map[string]uint64)
	for i := uint64(0); i < n; i++ {
		m[keys[i]] = i
	}
	benchBegin(ops)
	for benchNext() {
		rng := newRng()
		var acc uint64
		benchTic()
		for i := 0; i < ops; i++ {
			if v, ok := m[keys[rng.below(n)]]; ok {
				acc += v
			} else {
				acc += 7
			}
		}
		benchToc(acc)
	}
	benchEnd()
	benchSinkAny(m)
}

func copyMap(n uint64) {
	m := make(map[uint64]uint64)
	for i := uint64(0); i < n; i++ {
		m[scramble(i)] = i
	}
	var c map[uint64]uint64
	benchBegin(n)
	for benchNext() {
		c = nil
		benchTic()
		c = maps.Clone(m)
		benchToc(uint64(len(c)))
	}
	benchEnd()
	benchSinkAny(c)
}

func setInsert(n uint64) {
	var s map[uint64]struct{}
	benchBegin(n)
	for benchNext() {
		s = make(map[uint64]struct{})
		benchTic()
		for i := uint64(0); i < n; i++ {
			s[scramble(i)] = struct{}{}
		}
		benchToc(uint64(len(s)))
	}
	benchEnd()
	benchSinkAny(s)
}

func setContains(n uint64) {
	const ops = 1 << 20
	s := make(map[uint64]struct{})
	for i := uint64(0); i < n; i++ {
		s[scramble(i)] = struct{}{}
	}
	benchBegin(ops)
	for benchNext() {
		rng := newRng()
		var acc uint64
		benchTic()
		for i := 0; i < ops; i++ {
			if _, ok := s[scramble(rng.below(2*n))]; ok {
				acc++
			}
		}
		benchToc(acc)
	}
	benchEnd()
	benchSinkAny(s)
}

func main() {
	benchInit()
	if benchWant("map.insert_seq", 1000000) {
		insert(1000000, true)
	}
	if benchWant("map.insert_rand", 1000000) {
		insert(1000000, false)
	}
	benchTodo("map.insert_rand_fast", 1000000)
	for _, n := range []uint64{1000, 100000, 10000000} {
		if benchWant("map.lookup_hit", n) {
			lookup(n, true)
		}
		benchTodo("map.lookup_hit_fast", n)
		if benchWant("map.lookup_miss", n) {
			lookup(n, false)
		}
		benchTodo("map.lookup_miss_fast", n)
	}
	if benchWant("map.churn", 100000) {
		churn(100000)
	}
	benchTodo("map.churn_fast", 100000)
	if benchWant("map.iterate", 1000000) {
		iterate(1000000)
	}
	for _, n := range []uint64{8, 32} {
		if benchWant("map.str_insert", n) {
			strInsert(n)
		}
		if benchWant("map.str_lookup", n) {
			strLookup(n)
		}
		benchTodo("map.str_lookup_fast", n)
	}
	if benchWant("map.copy", 1000000) {
		copyMap(1000000)
	}
	if benchWant("set.insert_rand", 1000000) {
		setInsert(1000000)
	}
	if benchWant("set.contains", 100000) {
		setContains(100000)
	}
}
