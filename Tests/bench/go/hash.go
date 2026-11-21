// Hasher rows (ops.toml, group "hash"). `_std` is hash/maphash, the hasher the
// built-in map uses (seeded per process); `_fast` is bench.go's fast hasher. A
// `_std` checksum counts the calls; a `_fast` checksum is the hashes themselves.
package main

import "hash/maphash"

func hashU64(fast bool) {
	const ops = 1 << 20
	seed := maphash.MakeSeed()
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		if fast {
			for i := uint64(0); i < ops; i++ {
				acc += benchFastHashU64(benchOpaque(i))
			}
		} else {
			for i := uint64(0); i < ops; i++ {
				acc += maphash.Comparable(seed, benchOpaque(i))
			}
		}
		benchSink(acc)
		if fast {
			benchToc(acc)
		} else {
			benchToc(ops)
		}
	}
	benchEnd()
}

func hashBytes(length uint64, fast bool) {
	const keys = 256
	passes := (uint64(1) << 22) / (keys * length)
	rng := newRng()
	k := make([][]byte, keys)
	for i := range k {
		k[i] = []byte(rng.letters(int(length), 26))
	}
	seed := maphash.MakeSeed()
	benchBegin(keys * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := uint64(0); p < passes; p++ {
			benchSinkSlice(k)
			if fast {
				for _, s := range k {
					acc += benchFastHashBytes(s)
				}
			} else {
				for _, s := range k {
					acc += maphash.Bytes(seed, s)
				}
			}
		}
		benchSink(acc)
		if fast {
			benchToc(acc)
		} else {
			benchToc(keys * passes)
		}
	}
	benchEnd()
}

func main() {
	benchInit()
	if benchWant("hash.u64_std", 8) {
		hashU64(false)
	}
	if benchWant("hash.u64_fast", 8) {
		hashU64(true)
	}
	for _, n := range []uint64{8, 16, 64, 1024} {
		if benchWant("hash.bytes_std", n) {
			hashBytes(n, false)
		}
		if benchWant("hash.bytes_fast", n) {
			hashBytes(n, true)
		}
	}
}
