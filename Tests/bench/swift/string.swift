// String rows (ops.toml, group "string"): String. `String.count` counts
// grapheme clusters, so the code point rows use `unicodeScalars.count`; the
// byte rows work on the `utf8` view.

func createDestroy(_ b: Bench, _ len: Int) {
    let ops: UInt64 = 200_000
    var rng = BenchRng()
    let src = Array(rng.letters(len, 26).utf8)
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<ops {
            let s = String(decoding: src[0..<benchOpaque(len)], as: UTF8.self)
            benchSink(s)
            acc += UInt64(s.utf8.count)
        }
        b.toc(acc)
    }
    b.end()
}

func pushByte(_ b: Bench, _ n: UInt64) {
    var s = String()
    b.begin(n)
    while b.next() {
        s = String()
        b.tic()
        for i in 0..<n { s.append(Character(Unicode.Scalar(UInt8(ascii: "a") &+ UInt8(truncatingIfNeeded: i & 15)))) }
        b.toc(UInt64(s.utf8.count) &+ UInt64(s.utf8.last!))
    }
    b.end()
    benchSink(s)
}

func appendLiteral(_ b: Bench, _ len: Int) {
    let ops: UInt64 = 100_000
    var s = String()
    b.begin(ops)
    while b.next() {
        s = String()
        b.tic()
        if len == 4 {
            for _ in 0..<ops { s += "abcd" }
        } else {
            for _ in 0..<ops { s += "hello, world" }
        }
        b.toc(UInt64(s.utf8.count))
    }
    b.end()
    benchSink(s)
}

func find(_ b: Bench, _ n: UInt64) {
    let ops = (UInt64(1) << 22) / n
    var rng = BenchRng()
    var bytes = Array(rng.letters(Int(n), 16).utf8)
    bytes[Int(n) - 1] = UInt8(ascii: "z")
    let hay = String(decoding: bytes, as: UTF8.self)
    let needle = String(decoding: bytes[(Int(n) - 8)...], as: UTF8.self)
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<ops {
            benchSink(hay)
            benchSink(needle)
            let r = hay.firstRange(of: needle)!
            acc += UInt64(hay.utf8.distance(from: hay.startIndex, to: r.lowerBound))
        }
        b.toc(acc)
    }
    b.end()
}

func eq(_ b: Bench, _ len: Int) {
    let pairs = 1024
    let passes: UInt64 = 64
    var rng = BenchRng()
    var x: [String] = []
    var y: [String] = []
    for i in 0..<pairs {
        let s = rng.letters(len, 26)
        var t = Array(s.utf8)
        if i & 1 == 1 { t[len - 1] = UInt8(ascii: "Z") }
        x.append(s)
        y.append(String(decoding: t, as: UTF8.self))
    }
    b.begin(UInt64(pairs) * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(x)
            benchSink(y)
            for i in 0..<pairs { acc += x[i] == y[i] ? 1 : 0 }
        }
        b.toc(acc)
    }
    b.end()
}

// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
func utf8Text(_ n: Int) -> String {
    var rng = BenchRng()
    var s: [UInt8] = []
    s.reserveCapacity(n)
    while s.count + 3 <= n {
        let kind = rng.below(10)
        if kind < 7 {
            s.append(UInt8(ascii: "a") + UInt8(rng.below(26)))
        } else if kind < 9 {
            s.append(0xC3)
            s.append(0x80 + UInt8(rng.below(64)))
        } else {
            s.append(0xE2)
            s.append(0x82)
            s.append(0x80 + UInt8(rng.below(64)))
        }
    }
    while s.count < n { s.append(UInt8(ascii: "x")) }
    return String(decoding: s, as: UTF8.self)
}

func codepoints(_ b: Bench, _ n: UInt64) {
    let passes = (UInt64(1) << 22) / n
    let s = utf8Text(Int(n))
    b.begin(n * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(s)
            acc += UInt64(s.unicodeScalars.count)
        }
        b.toc(acc)
    }
    b.end()
}

@main
struct StringBench {
    static func main() {
        let b = Bench()
        for n: UInt64 in [0, 8, 32, 256] {
            if b.want("string.create_destroy", n) { createDestroy(b, Int(n)) }
        }
        if b.want("string.push_byte", 1_048_576) { pushByte(b, 1_048_576) }
        for n: UInt64 in [4, 12] {
            if b.want("string.append_literal", n) { appendLiteral(b, Int(n)) }
        }
        for n: UInt64 in [64, 4096, 1_048_576] {
            if b.want("string.find", n) { find(b, n) }
        }
        for n: UInt64 in [8, 16] {
            if b.want("string.eq", n) { eq(b, Int(n)) }
        }
        for n: UInt64 in [4096, 1_048_576] {
            if b.want("string.codepoints", n) { codepoints(b, n) }
        }
        // A String does not store its code point count: no counterpart to a cached read.
        for n: UInt64 in [4096, 1_048_576] {
            if b.want("string.codepoints_cached", n) { b.skip() }
        }
    }
}
