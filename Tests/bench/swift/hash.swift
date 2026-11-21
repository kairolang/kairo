// Hasher rows (ops.toml, group "hash"). `_std` is Swift's Hasher (SipHash-1-3
// with a per-process seed); `_fast` is bench.swift's fast hasher. A `_std`
// checksum counts the calls; a `_fast` checksum is the hashes themselves.

func u64Row(_ b: Bench, fast: Bool) {
    let ops: UInt64 = 1 << 20
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        if fast {
            for i in 0..<ops { acc &+= benchFastHashU64(benchOpaque(i)) }
        } else {
            for i in 0..<ops {
                var h = Hasher()
                h.combine(benchOpaque(i))
                acc &+= UInt64(truncatingIfNeeded: h.finalize())
            }
        }
        benchSink(acc)
        b.toc(fast ? acc : ops)
    }
    b.end()
}

func bytesRow(_ b: Bench, _ len: Int, fast: Bool) {
    let keys = 256
    let passes = (UInt64(1) << 22) / UInt64(keys * len)
    var rng = BenchRng()
    let k: [String] = (0..<keys).map { _ in rng.letters(len, 26) }
    b.begin(UInt64(keys) * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(k)
            if fast {
                for s in k { acc &+= benchFastHashString(s) }
            } else {
                for s in k {
                    var h = Hasher()
                    h.combine(s)
                    acc &+= UInt64(truncatingIfNeeded: h.finalize())
                }
            }
        }
        benchSink(acc)
        b.toc(fast ? acc : UInt64(keys) * passes)
    }
    b.end()
}

@main
struct HashBench {
    static func main() {
        let b = Bench()
        if b.want("hash.u64_std", 8) { u64Row(b, fast: false) }
        if b.want("hash.u64_fast", 8) { u64Row(b, fast: true) }
        for n: UInt64 in [8, 16, 64, 1024] {
            if b.want("hash.bytes_std", n) { bytesRow(b, Int(n), fast: false) }
            if b.want("hash.bytes_fast", n) { bytesRow(b, Int(n), fast: true) }
        }
    }
}
