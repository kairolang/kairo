// Allocation rows (ops.toml, group "alloc"): UnsafeMutableRawPointer.allocate
// and deallocate for raw blocks, final classes for the object rows. The
// standard library has no realloc: the growth row allocates the doubled block,
// copies the old bytes with copyMemory and deallocates the old block.

final class Obj16 {
    var a: UInt64
    var b: UInt64
    init(_ a: UInt64, _ b: UInt64) {
        self.a = a
        self.b = b
    }
}

final class Obj64 {
    var a: UInt64
    var b: UInt64
    var p0: UInt64 = 0, p1: UInt64 = 0, p2: UInt64 = 0, p3: UInt64 = 0, p4: UInt64 = 0, p5: UInt64 = 0
    init(_ a: UInt64, _ b: UInt64) {
        self.a = a
        self.b = b
    }
}

func pairRow(_ b: Bench, _ size: Int) {
    let ops: UInt64 = size > 65536 ? 2000 : 200_000
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for i in 0..<ops {
            let n = benchOpaque(size)
            let p = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 8)
            p.storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)
            benchSink(p)
            acc += UInt64(p.load(as: UInt8.self))
            p.deallocate()
        }
        b.toc(acc)
    }
    b.end()
}

func object16Row(_ b: Bench) {
    let ops: UInt64 = 200_000
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for i in 0..<ops {
            let p = Obj16(i, 2)
            benchSink(p)
            acc += p.a + p.b
        }
        b.toc(acc)
    }
    b.end()
}

func object64Row(_ b: Bench) {
    let ops: UInt64 = 200_000
    b.begin(ops)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for i in 0..<ops {
            let p = Obj64(i, 2)
            benchSink(p)
            acc += p.a + p.b
        }
        b.toc(acc)
    }
    b.end()
}

func batchRow(_ b: Bench, _ size: Int) {
    let live = 1024
    let rounds: UInt64 = 200
    var slot = [UnsafeMutableRawPointer?](repeating: nil, count: live)
    b.begin(UInt64(live) * rounds)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for _ in 0..<rounds {
            let n = benchOpaque(size)
            for k in 0..<live {
                let p = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 8)
                p.storeBytes(of: UInt8(truncatingIfNeeded: k), as: UInt8.self)
                slot[k] = p
            }
            benchSink(slot)
            for k in 0..<live {
                let p = slot[k]!
                acc += UInt64(p.load(as: UInt8.self))
                p.deallocate()
            }
        }
        b.toc(acc)
    }
    b.end()
}

func growRow(_ b: Bench, _ size: Int) {
    let chains: UInt64 = 500
    var steps: UInt64 = 0
    var m = 16
    while m < size {
        steps += 1
        m *= 2
    }
    b.begin(chains * steps)
    while b.next() {
        var acc: UInt64 = 0
        b.tic()
        for c in 0..<chains {
            // 16 bytes, as a value the optimizer knows nothing about.
            var n = 16 + Int(benchOpaque(c) >> 60)
            var p = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 8)
            p.storeBytes(of: 1, as: UInt8.self)
            while n < size {
                let q = UnsafeMutableRawPointer.allocate(byteCount: n * 2, alignment: 8)
                q.copyMemory(from: p, byteCount: n)
                p.deallocate()
                p = q
                p.storeBytes(of: 1, toByteOffset: n, as: UInt8.self)
                benchSink(p)
                acc += UInt64(p.load(as: UInt8.self)) + UInt64(p.load(fromByteOffset: n, as: UInt8.self))
                n *= 2
            }
            p.deallocate()
        }
        b.toc(acc)
    }
    b.end()
}

@main
struct AllocBench {
    static func main() {
        let b = Bench()
        for n: UInt64 in [16, 256, 4096, 1_048_576] {
            if b.want("alloc.pair", n) { pairRow(b, Int(n)) }
        }
        if b.want("alloc.object", 16) { object16Row(b) }
        if b.want("alloc.object", 64) { object64Row(b) }
        for n: UInt64 in [16, 256] {
            if b.want("alloc.batch", n) { batchRow(b, Int(n)) }
        }
        if b.want("alloc.grow", 1_048_576) { growRow(b, 1_048_576) }
    }
}
