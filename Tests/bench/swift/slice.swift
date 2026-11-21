// Slice rows (ops.toml, group "slice"): Array's sort(), reverse() and
// withUnsafeMutableBufferPointer { $0.update(repeating:) }. Array has one
// sort(), a stable one, so the "unstable" and "stable" rows run the same call.

struct Wide {
    var key: UInt64
    var pad: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
}

protocol Element {
    static func make(_ rng: inout BenchRng, _ i: UInt64) -> Self
    var digest: UInt64 { get }
    static func sortAll(_ v: inout [Self])
}

extension Int32: Element {
    static func make(_ rng: inout BenchRng, _ i: UInt64) -> Int32 { return Int32(truncatingIfNeeded: rng.next()) }
    var digest: UInt64 { return UInt64(UInt32(bitPattern: self)) }
    static func sortAll(_ v: inout [Int32]) { v.sort() }
}

extension UInt64: Element {
    static func make(_ rng: inout BenchRng, _ i: UInt64) -> UInt64 { return rng.next() }
    var digest: UInt64 { return self }
    static func sortAll(_ v: inout [UInt64]) { v.sort() }
}

extension String: Element {
    static func make(_ rng: inout BenchRng, _ i: UInt64) -> String { return rng.letters(16, 26) }
    var digest: UInt64 {
        return benchFastHashString(self)
    }
    static func sortAll(_ v: inout [String]) { v.sort() }
}

extension Wide: Element {
    static func make(_ rng: inout BenchRng, _ i: UInt64) -> Wide {
        return Wide(key: rng.next(), pad: (i, i, i, i, i, i, i))
    }
    var digest: UInt64 { return key ^ pad.0 }
    static func sortAll(_ v: inout [Wide]) { v.sort { $0.key < $1.key } }
}

func sortRow<T: Element>(_ b: Bench, _ n: UInt64, _ type: T.Type) {
    var rng = BenchRng()
    let input: [T] = (0..<n).map { T.make(&rng, $0) }
    var work: [T] = []
    b.begin(n)
    while b.next() {
        // An explicit copy: `work = input` would share the storage and the
        // sort would pay for the copy.
        work.removeAll(keepingCapacity: true)
        work.append(contentsOf: input)
        b.tic()
        T.sortAll(&work)
        let n = Int(n)
        b.toc(work[0].digest ^ (work[n / 2].digest &* 3) ^ (work[n - 1].digest &* 5))
    }
    b.end()
}

func reverseRow(_ b: Bench, _ n: UInt64) {
    let passes = ((UInt64(1) << 22) / n) | 1
    var a = [UInt64](0..<n)
    b.begin(n * passes)
    while b.next() {
        b.tic()
        for _ in 0..<passes {
            benchSink(a)
            a.reverse()
        }
        b.toc(a[0] + a[Int(n) - 1])
    }
    b.end()
}

func fillRow(_ b: Bench, _ n: UInt64) {
    let passes = (UInt64(1) << 22) / n
    var a = [UInt64](repeating: 0, count: Int(n))
    b.begin(n * passes)
    while b.next() {
        b.tic()
        for p in 0..<passes {
            let v = benchOpaque(p)
            a.withUnsafeMutableBufferPointer { $0.update(repeating: v) }
            benchSink(a)
        }
        b.toc(a[0] + a[Int(n) - 1])
    }
    b.end()
}

@main
struct SliceBench {
    static func main() {
        let b = Bench()
        let n: UInt64 = 1_000_000
        if b.want("slice.sort_unstable_i32", n) { sortRow(b, n, Int32.self) }
        if b.want("slice.sort_unstable_u64", n) { sortRow(b, n, UInt64.self) }
        if b.want("slice.sort_unstable_string", n) { sortRow(b, n, String.self) }
        if b.want("slice.sort_unstable_struct64", n) { sortRow(b, n, Wide.self) }
        if b.want("slice.sort_stable_i32", n) { sortRow(b, n, Int32.self) }
        if b.want("slice.sort_stable_u64", n) { sortRow(b, n, UInt64.self) }
        if b.want("slice.sort_stable_string", n) { sortRow(b, n, String.self) }
        if b.want("slice.sort_stable_struct64", n) { sortRow(b, n, Wide.self) }
        // The standard library has no binary search (partitioningIndex(where:) is in swift-algorithms).
        for m: UInt64 in [1024, 10_000_000] {
            if b.want("slice.binary_search", m) { b.skip() }
        }
        for m: UInt64 in [4096, 1_000_000] {
            if b.want("slice.reverse", m) { reverseRow(b, m) }
        }
        for m: UInt64 in [4096, 1_000_000] {
            if b.want("slice.fill", m) { fillRow(b, m) }
        }
    }
}
