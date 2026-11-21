// The measuring protocol of the builtin-library benchmarks in Go: the same
// rules, output and inputs as cpp/bench.h, which documents them. Each group
// program is built from this file and its own <group>.go, both `package main`:
//
//	go build -o <exe> bench.go <group>.go
package main

import (
	"encoding/binary"
	"fmt"
	"math/bits"
	"os"
	"strconv"
	"strings"
	"time"
	"unsafe"
)

// --- the optimizer barrier ---------------------------------------------------

// The functions below are never inlined and publish what they are given to a
// package-level variable, so the compiler can neither fold a workload away nor
// hoist it out of its loop, and a value handed to them counts as escaped.
var (
	sinkVal uint64
	sinkPtr unsafe.Pointer
	sinkAny any
)

// The value is treated as read by something the optimizer cannot see.
//
//go:noinline
func benchSink(v uint64) { sinkVal = v }

// The slice's storage is treated as read and kept by something unseen.
//
//go:noinline
func benchSinkSlice[T any](s []T) { sinkPtr = unsafe.Pointer(unsafe.SliceData(s)) }

// The string's bytes are treated as read and kept by something unseen.
//
//go:noinline
func benchSinkStr(s string) { sinkPtr = unsafe.Pointer(unsafe.StringData(s)) }

// A map or other pointer-shaped value is treated as read and kept by something
// unseen.
//
//go:noinline
func benchSinkAny(x any) { sinkAny = x }

// The value comes back as one the optimizer knows nothing about.
//
//go:noinline
func benchOpaque(v uint64) uint64 { return v }

// --- selection and the repetition loop ---------------------------------------

type benchState struct {
	wantID     string // "", "all", "list" or a row id
	anySize    bool
	wantSize   uint64
	minTotalNs uint64
	fixedReps  uint64 // 0 = time-driven
	id         string
	size       uint64
	ops        uint64
	reps       uint64
	minNs      uint64
	totalNs    uint64
	t0         time.Time
	check      uint64
	warm       bool
}

var bench benchState

// `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`, or the same four from
// BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS.
func benchInit() {
	id, hasID := os.LookupEnv("BENCH_ROW")
	size := os.Getenv("BENCH_SIZE")
	minMs := os.Getenv("BENCH_MIN_MS")
	reps := os.Getenv("BENCH_REPS")
	pos := 0
	for _, a := range os.Args[1:] {
		switch {
		case strings.HasPrefix(a, "--min-ms="):
			minMs = a[len("--min-ms="):]
		case strings.HasPrefix(a, "--reps="):
			reps = a[len("--reps="):]
		case pos == 0:
			id, hasID = a, true
			pos++
		default:
			size = a
		}
	}
	if !hasID {
		id = "list"
	}
	bench.wantID = id
	bench.anySize = size == ""
	bench.wantSize, _ = strconv.ParseUint(size, 10, 64)
	ms := uint64(200)
	if minMs != "" {
		ms, _ = strconv.ParseUint(minMs, 10, 64)
	}
	bench.minTotalNs = ms * 1000000
	bench.fixedReps, _ = strconv.ParseUint(reps, 10, 64)
}

// True when the row at this size is to run now. In list mode it prints the
// pair and answers false, so `prog list` enumerates what a program holds.
func benchWant(id string, size uint64) bool {
	s := &bench
	if s.wantID == "list" {
		fmt.Printf("%s,%d\n", id, size)
		return false
	}
	if s.wantID != "all" && s.wantID != id {
		return false
	}
	if !s.anySize && s.wantSize != size {
		return false
	}
	s.id = id
	s.size = size
	return true
}

func benchBegin(opsPerRep uint64) {
	s := &bench
	s.ops = opsPerRep
	s.reps = 0
	s.minNs = ^uint64(0)
	s.totalNs = 0
	s.check = 0
	s.warm = false
}

func benchNext() bool {
	s := &bench
	if !s.warm {
		return true
	}
	if s.fixedReps != 0 {
		return s.reps < s.fixedReps
	}
	return s.reps < 3 || (s.totalNs < s.minTotalNs && s.reps < 100000000)
}

func benchTic() { bench.t0 = time.Now() }

func benchToc(check uint64) {
	dt := uint64(time.Since(bench.t0).Nanoseconds())
	s := &bench
	s.check = check
	if !s.warm {
		s.warm = true
		return
	}
	s.reps++
	s.totalNs += dt
	if dt < s.minNs {
		s.minNs = dt
	}
}

func benchEnd() {
	s := &bench
	fmt.Printf("%s,%d,%.4f,%d\n", s.id, s.size, float64(s.minNs)/float64(s.ops), s.reps)
	fmt.Fprintf(os.Stderr, "check,%s,%d,%016x,%d\n", s.id, s.size, s.check, s.ops)
}

// A row this program cannot run: the cell stays empty in the report.
func benchSkip() {
	fmt.Printf("%s,%d,nan,0\n", bench.id, bench.size)
}

func benchTodo(id string, size uint64) {
	if benchWant(id, size) {
		benchSkip()
	}
}

// --- the shared inputs -------------------------------------------------------

// xorshift64 (13, 7, 17), seeded alike in every language.
const benchSeed uint64 = 0x9E3779B97F4A7C15

type Rng struct{ s uint64 }

func newRng() Rng { return Rng{benchSeed} }

func (r *Rng) next() uint64 {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return r.s
}

// Uniform in [0, n) for n < 2^32, with no division.
func (r *Rng) below(n uint64) uint64 { return ((r.next() >> 32) * n) >> 32 }

// A string of len letters drawn from the first `alphabet` of a..z.
func (r *Rng) letters(n int, alphabet uint64) string {
	var b strings.Builder
	b.Grow(n)
	for i := 0; i < n; i++ {
		b.WriteByte('a' + byte(r.below(alphabet)))
	}
	return b.String()
}

// --- the fast hasher ---------------------------------------------------------

// The "fast hasher" of the rows that name one; cpp/bench.h has the same.
const (
	benchK0 uint64 = 0x2D358DCCAA6C78A5
	benchK1 uint64 = 0x8BB84B93962EACC9
)

func benchFold(a, b uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	return lo ^ hi
}

func benchRead64(p []byte) uint64 { return binary.LittleEndian.Uint64(p) }

func benchFastHashU64(x uint64) uint64 { return benchFold(x^benchK0, benchK1) }

func benchFastHashBytes(p []byte) uint64 {
	h := benchK0 ^ uint64(len(p))
	if len(p) >= 32 {
		a, b := h, h
		for len(p) >= 32 {
			a = benchFold(benchRead64(p)^benchK0, benchRead64(p[8:])^a)
			b = benchFold(benchRead64(p[16:])^benchK1, benchRead64(p[24:])^b)
			p = p[32:]
		}
		h = a ^ b
	}
	for len(p) >= 8 {
		h = benchFold(h^benchRead64(p), benchK1)
		p = p[8:]
	}
	if len(p) != 0 {
		var w [8]byte
		copy(w[:], p)
		h = benchFold(h^benchRead64(w[:]), benchK1)
	}
	return benchFold(h, benchK0)
}
