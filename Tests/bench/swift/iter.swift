// Iterator chain rows (ops.toml, group "iter"): lazy sequence chains and
// reduce, and beside each chain the loop a person would write by hand
// (`_loop`).

// Values in [-1000, 1000]: no sum below leaves Int32.
func input(_ n: UInt64) -> [Int32] {
    var rng = BenchRng()
    return (0..<n).map { _ in Int32(rng.below(2001)) - 1000 }
}

enum Chain { case mapFilterSum, enumerateTake, revTakeWhile, collectMap }

func chain(_ which: Chain, _ v: [Int32]) -> UInt64 {
    switch which {
    case .mapFilterSum:
        let sum = v.lazy.map { $0 * 3 }.filter { ($0 & 1) == 0 }.reduce(Int32(0), +)
        return UInt64(bitPattern: Int64(sum))
    case .enumerateTake:
        let sum = v.enumerated().prefix(v.count / 2).reduce(Int64(0)) { $0 + Int64($1.offset) * Int64($1.element) }
        return UInt64(bitPattern: sum)
    case .revTakeWhile:
        return UInt64(v.reversed().prefix(while: { $0 != 5000 }).count)
    case .collectMap:
        let out = Array(v.lazy.map { $0 * 3 })
        benchSink(out)
        return UInt64(out.count) &+ UInt64(bitPattern: Int64(out[out.count - 1]))
    }
}

func loop(_ which: Chain, _ v: [Int32]) -> UInt64 {
    let n = v.count
    switch which {
    case .mapFilterSum:
        var sum: Int32 = 0
        for i in 0..<n {
            let x = v[i] * 3
            if (x & 1) == 0 { sum += x }
        }
        return UInt64(bitPattern: Int64(sum))
    case .enumerateTake:
        var sum: Int64 = 0
        for i in 0..<(n / 2) { sum += Int64(i) * Int64(v[i]) }
        return UInt64(bitPattern: sum)
    case .revTakeWhile:
        var i = n
        while i != 0 && v[i - 1] != 5000 { i -= 1 }
        return UInt64(n - i)
    case .collectMap:
        var out: [Int32] = []
        out.reserveCapacity(n)
        for i in 0..<n { out.append(v[i] * 3) }
        benchSink(out)
        return UInt64(out.count) &+ UInt64(bitPattern: Int64(out[n - 1]))
    }
}

func run(_ b: Bench, _ which: Chain, byHand: Bool, _ n: UInt64) {
    let passes = (UInt64(1) << 22) / n
    let v = input(n)
    var ops = n
    if case .enumerateTake = which { ops = n / 2 }
    b.begin(ops * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(v)
            acc &+= byHand ? loop(which, v) : chain(which, v)
        }
        b.toc(acc)
    }
    b.end()
}

@main
struct IterBench {
    static func main() {
        let b = Bench()
        for n: UInt64 in [1000, 1_000_000] {
            if b.want("iter.map_filter_sum", n) { run(b, .mapFilterSum, byHand: false, n) }
            if b.want("iter.map_filter_sum_loop", n) { run(b, .mapFilterSum, byHand: true, n) }
            if b.want("iter.enumerate_take", n) { run(b, .enumerateTake, byHand: false, n) }
            if b.want("iter.enumerate_take_loop", n) { run(b, .enumerateTake, byHand: true, n) }
            if b.want("iter.rev_take_while_count", n) { run(b, .revTakeWhile, byHand: false, n) }
            if b.want("iter.rev_take_while_count_loop", n) { run(b, .revTakeWhile, byHand: true, n) }
            if b.want("iter.collect_map", n) { run(b, .collectMap, byHand: false, n) }
            if b.want("iter.collect_map_loop", n) { run(b, .collectMap, byHand: true, n) }
        }
    }
}
