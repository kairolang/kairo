// Vector rows (ops.toml, group "vector"): Array.

func pushI32(_ b: Bench, _ n: UInt64, reserve: Bool) {
    var v: [Int32] = []
    b.begin(n)
    while b.next() {
        v = []
        b.tic()
        if reserve { v.reserveCapacity(Int(n)) }
        for i in 0..<n { v.append(Int32(truncatingIfNeeded: i)) }
        b.toc(UInt64(v.count) &+ UInt64(bitPattern: Int64(v[Int(n) - 1])))
    }
    b.end()
    benchSink(v)
}

func pushString(_ b: Bench, _ len: Int) {
    let n: UInt64 = 1_000_000
    // A String built from a byte range: the bytes are validated UTF-8 and
    // stored inline up to 15 bytes, on the heap above.
    let src = [UInt8](repeating: UInt8(ascii: "k"), count: len)
    var v: [String] = []
    b.begin(n)
    while b.next() {
        v = []
        b.tic()
        for _ in 0..<n { v.append(String(decoding: src[0..<benchOpaque(len)], as: UTF8.self)) }
        b.toc(UInt64(v.count) &+ UInt64(v[Int(n) - 1].utf8.count))
    }
    b.end()
    benchSink(v)
}

func iterSum(_ b: Bench, _ n: UInt64) {
    let passes = 10_000_000 / n
    var rng = BenchRng()
    let v: [Int32] = (0..<n).map { _ in Int32(truncatingIfNeeded: rng.next()) }
    b.begin(n * passes)
    while b.next() {
        var sum: Int64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(v)
            for x in v { sum += Int64(x) }
        }
        b.toc(UInt64(bitPattern: sum))
    }
    b.end()
}

func insertFront(_ b: Bench, _ n: UInt64) {
    var v: [Int32] = []
    b.begin(n)
    while b.next() {
        v = []
        b.tic()
        for i in 0..<n { v.insert(Int32(truncatingIfNeeded: i), at: 0) }
        b.toc(UInt64(v.count) &+ UInt64(bitPattern: Int64(v[0])))
    }
    b.end()
    benchSink(v)
}

func createDestroy(_ b: Bench, _ elements: UInt64) {
    let ops: UInt64 = 1_000_000
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for i in 0..<ops {
            var v: [Int32] = []
            if elements != 0 { v.append(Int32(truncatingIfNeeded: benchOpaque(i))) }
            benchSink(v)
            acc &+= UInt64(v.count)
        }
        b.toc(acc)
    }
    b.end()
}

// Array has no swap_remove; the two statements below are the idiom.
func swapRemove(_ b: Bench, _ n: UInt64) {
    var v: [Int32] = []
    b.begin(n)
    while b.next() {
        v.removeAll(keepingCapacity: true)
        v.append(contentsOf: 0..<Int32(n))
        var rng = BenchRng()
        var acc: UInt64 = 0
        b.tic()
        while !v.isEmpty {
            let i = Int(rng.below(UInt64(v.count)))
            acc = acc &* 31 &+ UInt64(bitPattern: Int64(v[i]))
            v[i] = v[v.count - 1]
            v.removeLast()
        }
        b.toc(acc)
    }
    b.end()
}

@main
struct VectorBench {
    static func main() {
        let b = Bench()
        if b.want("vector.push_i32", 10_000_000) { pushI32(b, 10_000_000, reserve: false) }
        if b.want("vector.push_i32_reserved", 10_000_000) { pushI32(b, 10_000_000, reserve: true) }
        // A Kairo-only row: push through a vector variant that keeps its capacity inline.
        if b.want("vector.push_i32_cap24", 10_000_000) { b.skip() }
        for n: UInt64 in [8, 32] {
            if b.want("vector.push_string", n) { pushString(b, Int(n)) }
        }
        for n: UInt64 in [10_000, 10_000_000] {
            if b.want("vector.iter_sum", n) { iterSum(b, n) }
        }
        if b.want("vector.insert_front", 10_000) { insertFront(b, 10_000) }
        for n: UInt64 in [0, 1] {
            if b.want("vector.create_destroy", n) { createDestroy(b, n) }
        }
        if b.want("vector.swap_remove", 1_000_000) { swapRemove(b, 1_000_000) }
    }
}
