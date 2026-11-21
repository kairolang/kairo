// Number text rows (ops.toml, group "num"): package strconv.
package main

import (
	"math"
	"strconv"
)

const (
	count  = 4096
	passes = 64
)

func integers(digits uint64) []uint64 {
	rng := newRng()
	v := make([]uint64, count)
	for i := range v {
		if digits == 4 {
			v[i] = rng.below(10000)
		} else {
			v[i] = rng.next()
		}
	}
	return v
}

// In [0, 10^6), with a full 53-bit significand.
func doubles() []float64 {
	rng := newRng()
	v := make([]float64, count)
	for i := range v {
		v[i] = float64(rng.next()>>11) * (1.0 / 9007199254740992.0) * 1e6
	}
	return v
}

func u64ToText(digits uint64) {
	v := integers(digits)
	s := make([]byte, 0, 1<<17)
	benchBegin(count * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := 0; p < passes; p++ {
			benchSinkSlice(v)
			s = s[:0]
			for _, x := range v {
				s = strconv.AppendUint(s, x, 10)
			}
			acc += uint64(len(s))
		}
		benchToc(acc)
	}
	benchEnd()
	benchSinkSlice(s)
}

func textToU64(digits uint64) {
	text := make([]string, 0, count)
	for _, x := range integers(digits) {
		text = append(text, strconv.FormatUint(x, 10))
	}
	benchBegin(count * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := 0; p < passes; p++ {
			benchSinkSlice(text)
			for _, t := range text {
				x, _ := strconv.ParseUint(t, 10, 64)
				acc += x
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

// Shortest text that reads back to the same value, in fixed notation.
func f64ToText() {
	v := doubles()
	s := make([]byte, 0, 1<<17)
	benchBegin(count * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := 0; p < passes; p++ {
			benchSinkSlice(v)
			s = s[:0]
			for _, x := range v {
				s = strconv.AppendFloat(s, x, 'f', -1, 64)
			}
			acc += uint64(len(s))
		}
		benchToc(acc)
	}
	benchEnd()
	benchSinkSlice(s)
}

func textToF64() {
	text := make([]string, 0, count)
	for _, x := range doubles() {
		text = append(text, strconv.FormatFloat(x, 'f', -1, 64))
	}
	benchBegin(count * passes)
	for benchNext() {
		var acc uint64
		benchTic()
		for p := 0; p < passes; p++ {
			benchSinkSlice(text)
			for _, t := range text {
				x, _ := strconv.ParseFloat(t, 64)
				acc += math.Float64bits(x)
			}
		}
		benchToc(acc)
	}
	benchEnd()
}

func main() {
	benchInit()
	for _, d := range []uint64{4, 20} {
		if benchWant("num.u64_to_text", d) {
			u64ToText(d)
		}
		if benchWant("num.text_to_u64", d) {
			textToU64(d)
		}
	}
	if benchWant("num.f64_to_text", 17) {
		f64ToText()
	}
	if benchWant("num.text_to_f64", 17) {
		textToF64()
	}
}
