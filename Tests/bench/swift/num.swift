// Number text rows (ops.toml, group "num"): String(x), UInt64(text) and
// Double(text). Double.description is the shortest text that reads back; the
// values stay in [0, 10^6), where it is in fixed notation.

let count = 4096
let passes: UInt64 = 64

func integers(_ digits: Int) -> [UInt64] {
    var rng = BenchRng()
    return (0..<count).map { _ in digits == 4 ? rng.below(10000) : rng.next() }
}

// In [0, 10^6), with a full 53-bit significand.
func doubles() -> [Double] {
    var rng = BenchRng()
    return (0..<count).map { _ in Double(rng.next() &>> 11) * (1.0 / 9007199254740992.0) * 1e6 }
}

func u64ToText(_ b: Bench, _ digits: Int) {
    let v = integers(digits)
    var s = String()
    b.begin(UInt64(count) * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(v)
            s.removeAll(keepingCapacity: true)
            for x in v { s += String(x) }
            acc += UInt64(s.utf8.count)
        }
        b.toc(acc)
    }
    b.end()
}

func textToU64(_ b: Bench, _ digits: Int) {
    let text = integers(digits).map { String($0) }
    b.begin(UInt64(count) * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(text)
            for t in text { acc &+= UInt64(t)! }
        }
        b.toc(acc)
    }
    b.end()
}

func f64ToText(_ b: Bench) {
    let v = doubles()
    var s = String()
    b.begin(UInt64(count) * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(v)
            s.removeAll(keepingCapacity: true)
            for x in v { s += x.description }
            acc += UInt64(s.utf8.count)
        }
        b.toc(acc)
    }
    b.end()
}

func textToF64(_ b: Bench) {
    let text = doubles().map { $0.description }
    b.begin(UInt64(count) * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(text)
            for t in text { acc &+= Double(t)!.bitPattern }
        }
        b.toc(acc)
    }
    b.end()
}

@main
struct NumBench {
    static func main() {
        let b = Bench()
        for d: UInt64 in [4, 20] {
            if b.want("num.u64_to_text", d) { u64ToText(b, Int(d)) }
            if b.want("num.text_to_u64", d) { textToU64(b, Int(d)) }
        }
        if b.want("num.f64_to_text", 17) { f64ToText(b) }
        if b.want("num.text_to_f64", 17) { textToF64(b) }
    }
}
