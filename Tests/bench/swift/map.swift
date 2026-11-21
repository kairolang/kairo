// Hash map and set rows (ops.toml, group "map"): Dictionary and Set. A row
// without a suffix hashes with Swift's default (SipHash-1-3 through Hasher); a
// `_fast` row wraps the key in a struct that implements Hashable's
// `_rawHashValue(seed:)` requirement with bench.swift's fast hasher. That
// underscored requirement is the one place the standard library lets a key
// replace the hashing of Dictionary and Set: `hash(into:)` alone always runs
// through Hasher.

// A bijection on u64, so the "random" keys are distinct.
@inline(__always)
func scramble(_ i: UInt64) -> UInt64 { return i &* benchSeed }

protocol U64Key: Hashable {
    init(key: UInt64)
}

extension UInt64: U64Key {
    init(key: UInt64) { self = key }
}

struct FastU64: U64Key {
    var v: UInt64
    init(key: UInt64) { v = key }
    func hash(into hasher: inout Hasher) { hasher.combine(v) }
    func _rawHashValue(seed: Int) -> Int { return Int(truncatingIfNeeded: benchFastHashU64(v)) }
}

protocol StrKey: Hashable {
    init(key: String)
}

extension String: StrKey {
    init(key: String) { self = key }
}

struct FastStr: StrKey {
    var s: String
    init(key: String) { s = key }
    func hash(into hasher: inout Hasher) { hasher.combine(s) }
    func _rawHashValue(seed: Int) -> Int {
        return Int(truncatingIfNeeded: benchFastHashString(s))
    }
}

func insert<K: U64Key>(_ b: Bench, _ n: UInt64, _ keys: K.Type, sequential: Bool) {
    var m: [K: UInt64] = [:]
    b.begin(n)
    while b.next() {
        m = [:]
        b.tic()
        for i in 0..<n { m[K(key: sequential ? i : scramble(i))] = i }
        b.toc(UInt64(m.count))
    }
    b.end()
    benchSink(m)
}

func lookup<K: U64Key>(_ b: Bench, _ n: UInt64, _ keys: K.Type, hit: Bool) {
    let ops: UInt64 = 1 << 20
    var m = [K: UInt64](minimumCapacity: Int(n))
    for i in 0..<n { m[K(key: scramble(i))] = i }
    b.begin(ops)
    while b.next() {
        var rng = BenchRng()
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<ops {
            let j = rng.below(n)
            acc += m[K(key: scramble(hit ? j : j + n))] ?? 7
        }
        b.toc(acc)
    }
    b.end()
}

func churn<K: U64Key>(_ b: Bench, _ n: UInt64, _ keys: K.Type) {
    let ops: UInt64 = 1 << 20
    var m: [K: UInt64] = [:]
    for i in 0..<n { m[K(key: scramble(i))] = i }
    var next = n
    b.begin(ops)
    while b.next() {
        b.tic()
        for _ in 0..<ops {
            m.removeValue(forKey: K(key: scramble(next - n)))
            m[K(key: scramble(next))] = next
            next += 1
        }
        b.toc(UInt64(m.count))
    }
    b.end()
}

func iterate(_ b: Bench, _ n: UInt64) {
    let passes: UInt64 = 4
    var m: [UInt64: UInt64] = [:]
    for i in 0..<n { m[scramble(i)] = i }
    b.begin(n * passes)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<passes {
            benchSink(m)
            for (_, v) in m { acc += v }
        }
        b.toc(acc)
    }
    b.end()
}

func stringKeys(_ n: UInt64, _ len: Int) -> [String] {
    var rng = BenchRng()
    return (0..<n).map { _ in rng.letters(len, 26) }
}

func strInsert(_ b: Bench, _ len: Int) {
    let n: UInt64 = 100_000
    let keys = stringKeys(n, len)
    var m: [String: UInt64] = [:]
    b.begin(n)
    while b.next() {
        m = [:]
        b.tic()
        for i in 0..<n { m[keys[Int(i)]] = i }
        b.toc(UInt64(m.count))
    }
    b.end()
    benchSink(m)
}

func strLookup<K: StrKey>(_ b: Bench, _ len: Int, _ keys: K.Type) {
    let n: UInt64 = 100_000
    let ops: UInt64 = 1 << 18
    let strs = stringKeys(n, len)
    let ks = strs.map { K(key: $0) }
    var m: [K: UInt64] = [:]
    for i in 0..<n { m[ks[Int(i)]] = i }
    b.begin(ops)
    while b.next() {
        var rng = BenchRng()
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<ops { acc += m[ks[Int(rng.below(n))]] ?? 7 }
        b.toc(acc)
    }
    b.end()
}

// A Dictionary copy is lazy (copy on write): `c = m` shares the storage. The
// one value written back below, the entry the key 0 already has, is what makes
// c unique, so the copy of every entry happens inside the timed region.
func copyRow(_ b: Bench, _ n: UInt64) {
    var m: [UInt64: UInt64] = [:]
    for i in 0..<n { m[scramble(i)] = i }
    var c: [UInt64: UInt64] = [:]
    b.begin(n)
    while b.next() {
        c = [:]
        b.tic()
        c = m
        c[0] = 0
        b.toc(UInt64(c.count))
    }
    b.end()
    benchSink(c)
}

func setInsert(_ b: Bench, _ n: UInt64) {
    var s = Set<UInt64>()
    b.begin(n)
    while b.next() {
        s = Set<UInt64>()
        b.tic()
        for i in 0..<n { s.insert(scramble(i)) }
        b.toc(UInt64(s.count))
    }
    b.end()
    benchSink(s)
}

func setContains(_ b: Bench, _ n: UInt64) {
    let ops: UInt64 = 1 << 20
    var s = Set<UInt64>()
    for i in 0..<n { s.insert(scramble(i)) }
    b.begin(ops)
    while b.next() {
        var rng = BenchRng()
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<ops { acc += s.contains(scramble(rng.below(2 * n))) ? 1 : 0 }
        b.toc(acc)
    }
    b.end()
}

@main
struct MapBench {
    static func main() {
        let b = Bench()
        if b.want("map.insert_seq", 1_000_000) { insert(b, 1_000_000, UInt64.self, sequential: true) }
        if b.want("map.insert_rand", 1_000_000) { insert(b, 1_000_000, UInt64.self, sequential: false) }
        if b.want("map.insert_rand_fast", 1_000_000) { insert(b, 1_000_000, FastU64.self, sequential: false) }
        for n: UInt64 in [1000, 100_000, 10_000_000] {
            if b.want("map.lookup_hit", n) { lookup(b, n, UInt64.self, hit: true) }
            if b.want("map.lookup_hit_fast", n) { lookup(b, n, FastU64.self, hit: true) }
            if b.want("map.lookup_miss", n) { lookup(b, n, UInt64.self, hit: false) }
            if b.want("map.lookup_miss_fast", n) { lookup(b, n, FastU64.self, hit: false) }
        }
        if b.want("map.churn", 100_000) { churn(b, 100_000, UInt64.self) }
        if b.want("map.churn_fast", 100_000) { churn(b, 100_000, FastU64.self) }
        if b.want("map.iterate", 1_000_000) { iterate(b, 1_000_000) }
        for n: UInt64 in [8, 32] {
            if b.want("map.str_insert", n) { strInsert(b, Int(n)) }
            if b.want("map.str_lookup", n) { strLookup(b, Int(n), String.self) }
            if b.want("map.str_lookup_fast", n) { strLookup(b, Int(n), FastStr.self) }
        }
        if b.want("map.copy", 1_000_000) { copyRow(b, 1_000_000) }
        if b.want("set.insert_rand", 1_000_000) { setInsert(b, 1_000_000) }
        if b.want("set.contains", 100_000) { setContains(b, 100_000) }
    }
}
