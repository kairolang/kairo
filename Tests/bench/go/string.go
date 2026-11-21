// String rows (ops.toml, group "string"): string, strings.Builder and
// package strings.
package main

import (
	"strings"
	"unicode/utf8"
)

func createDestroy(length uint64) {
	const ops = 200000
	rng := newRng()
	src := rng.letters(int(length), 26)
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		for i := 0; i < ops; i++ {
			s := strings.Clone(src[:benchOpaque(length)])
			benchSinkStr(s)
			acc += uint64(len(s))
		}
		benchToc(acc)
	}
	benchEnd()
}

func pushByte(n uint64) {
	var s strings.Builder
	benchBegin(n)
	for benchNext() {
		s = strings.Builder{}
		benchTic()
		for i := uint64(0); i < n; i++ {
			s.WriteByte('a' + byte(i&15))
		}
		benchToc(uint64(s.Len()) + uint64(s.String()[n-1]))
	}
	benchEnd()
	benchSinkStr(s.String())
}

func appendLiteral(length uint64) {
	const ops = 100000
	var s strings.Builder
	benchBegin(ops)
	for benchNext() {
		s = strings.Builder{}
		benchTic()
		if length == 4 {
			for i := 0; i < ops; i++ {
				s.WriteString("abcd")
			}
		} else {
			for i := 0; i < ops; i++ {
				s.WriteString("hello, world")
			}
		}
		benchToc(uint64(s.Len()))
	}
	benchEnd()
	benchSinkStr(s.String())
}

func find(n uint64) {
	ops := (uint64(1) << 22) / n
	rng := newRng()
	hay := rng.letters(int(n), 16)
	hay = hay[:n-1] + "z"
	// A needle of its own, not a window into the haystack.
	needle := strings.Clone(hay[n-8:])
	benchBegin(ops)
	for benchNext() {
		var acc uint64
		benchTic()
		for i := uint64(0); i < ops; i++ {
			benchSinkStr(hay)
			benchSinkStr(needle)
			acc += uint64(strings.Index(hay, needle))
		}
		benchToc(acc)
	}
	benchEnd()
}

func eq(length uint64) {
	const pairs, passes = 1024, 64
	rng := newRng()
	a := make([]string, 0, pairs)
	b := make([]string, 0, pairs)
	for i := 0; i < pairs; i++ {
		s := rng.letters(int(length), 26)
		a = append(a, s)
		if i&1 == 1 {
			b = append(b, s[:length-1]+"Z")
		} else {
			b = append(b, strings.Clone(s))
		}
	}
	benchBegin(pairs * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := 0; p < passes; p++ {
			benchSinkSlice(a)
			benchSinkSlice(b)
			for i := range a {
				if a[i] == b[i] {
					acc++
				}
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
func utf8Text(n uint64) string {
	rng := newRng()
	s := make([]byte, 0, n)
	for uint64(len(s))+3 <= n {
		kind := rng.below(10)
		if kind < 7 {
			s = append(s, 'a'+byte(rng.below(26)))
		} else if kind < 9 {
			s = append(s, 0xC3, 0x80+byte(rng.below(64)))
		} else {
			s = append(s, 0xE2, 0x82, 0x80+byte(rng.below(64)))
		}
	}
	for uint64(len(s)) < n {
		s = append(s, 'x')
	}
	return string(s)
}

func codepoints(n uint64) {
	passes := (uint64(1) << 22) / n
	s := utf8Text(n)
	benchBegin(n * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := uint64(0); p < passes; p++ {
			benchSinkStr(s)
			acc += uint64(utf8.RuneCountInString(s))
		}
		benchToc(acc)
	}
	benchEnd()
}

func main() {
	benchInit()
	for _, n := range []uint64{0, 8, 32, 256} {
		if benchWant("string.create_destroy", n) {
			createDestroy(n)
		}
	}
	if benchWant("string.push_byte", 1048576) {
		pushByte(1048576)
	}
	for _, n := range []uint64{4, 12} {
		if benchWant("string.append_literal", n) {
			appendLiteral(n)
		}
	}
	for _, n := range []uint64{64, 4096, 1048576} {
		if benchWant("string.find", n) {
			find(n)
		}
	}
	for _, n := range []uint64{8, 16} {
		if benchWant("string.eq", n) {
			eq(n)
		}
	}
	for _, n := range []uint64{4096, 1048576} {
		if benchWant("string.codepoints", n) {
			codepoints(n)
		}
	}
	// The count is not stored by a Go string: no counterpart to a cached read.
	for _, n := range []uint64{4096, 1048576} {
		benchTodo("string.codepoints_cached", n)
	}
}
