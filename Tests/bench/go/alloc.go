// Allocation rows (ops.toml, group "alloc"): the Go heap. A block is a
// make([]byte, n) or a pointer to a struct; "free" is the collector's business.
package main

func pair(size uint64) {
	ops := uint64(200000)
	if size > 65536 {
		ops = 2000
	}
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		for i := uint64(0); i < ops; i++ {
			p := make([]byte, benchOpaque(size))
			p[0] = byte(i)
			benchSinkSlice(p)
			acc += uint64(p[0])
		}
		benchToc(acc)
	}
	benchEnd()
}

type Obj16 struct{ a, b uint64 }
type Obj64 struct {
	a, b uint64
	pad  [6]uint64
}

func object16() {
	const ops = 200000
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		for i := uint64(0); i < ops; i++ {
			p := &Obj16{a: i, b: 2}
			benchSinkAny(p)
			acc += p.a + p.b
		}
		benchToc(acc)
	}
	benchEnd()
}

func object64() {
	const ops = 200000
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		for i := uint64(0); i < ops; i++ {
			p := &Obj64{a: i, b: 2}
			benchSinkAny(p)
			acc += p.a + p.b
		}
		benchToc(acc)
	}
	benchEnd()
}

func batch(size uint64) {
	const live, rounds = 1024, 200
	var slot [live][]byte
	benchBegin(live * rounds)
	for benchNext() {
		var acc uint64
		benchTic()
		for r := 0; r < rounds; r++ {
			n := benchOpaque(size)
			for k := range slot {
				p := make([]byte, n)
				p[0] = byte(k)
				slot[k] = p
			}
			benchSinkSlice(slot[:])
			for k := range slot {
				acc += uint64(slot[k][0])
				slot[k] = nil
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

// Go has no realloc: each doubling is append(p, make([]byte, n)...), which
// allocates the larger block and copies, as realloc does when it cannot extend
// in place.
func grow(size uint64) {
	const chains = 500
	var steps uint64
	for n := uint64(16); n < size; n *= 2 {
		steps++
	}
	benchBegin(chains * steps)
	for benchNext() {
		var acc uint64
		benchTic()
		for c := uint64(0); c < chains; c++ {
			// 16 bytes, as a value the optimizer knows nothing about.
			n := 16 + (benchOpaque(c) >> 60)
			p := make([]byte, n)
			p[0] = 1
			for n < size {
				p = append(p, make([]byte, n)...)
				p[n] = 1
				benchSinkSlice(p)
				acc += uint64(p[0]) + uint64(p[n])
				n *= 2
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

func main() {
	benchInit()
	for _, n := range []uint64{16, 256, 4096, 1048576} {
		if benchWant("alloc.pair", n) {
			pair(n)
		}
	}
	if benchWant("alloc.object", 16) {
		object16()
	}
	if benchWant("alloc.object", 64) {
		object64()
	}
	for _, n := range []uint64{16, 256} {
		if benchWant("alloc.batch", n) {
			batch(n)
		}
	}
	if benchWant("alloc.grow", 1048576) {
		grow(1048576)
	}
}
