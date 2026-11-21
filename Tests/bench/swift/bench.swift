// The measuring protocol of the builtin-library benchmarks in Swift: the same
// rules, output and inputs as cpp/bench.h, which documents them. Each group
// program in this directory is compiled together with this file, with
// -parse-as-library, and has an `@main struct` entry point.
import Glibc

// --- the optimizer barrier ---------------------------------------------------

// A call the optimizer cannot inline (@_optimize(none) functions are never
// inlined and their effects are not inferred), so its argument counts as read
// and its result as unknown. The store keeps the call from being dropped as
// side-effect free. The slot is reached through a pointer: a global var would
// cost a dynamic exclusivity check (swift_beginAccess) in every call.
let benchSinkSlot: UnsafeMutablePointer<UInt64> = {
    let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    p.initialize(to: 0)
    return p
}()

@inline(never) @_optimize(none)
func benchSink(_ v: UInt64) { benchSinkSlot.pointee = v }

// The array overload exists because a generic parameter of type Array<Int32>
// makes the caller look up that type's metadata (a runtime cache lookup per
// call); with [T] only the element's metadata, a constant, is passed.
@inline(never) @_optimize(none)
func benchSink<T>(_ v: [T]) { benchSinkSlot.pointee &+= 1 }

@inline(never) @_optimize(none)
func benchSink<T>(_ v: borrowing T) { benchSinkSlot.pointee &+= 1 }

@inline(never) @_optimize(none)
func benchSink(_ p: UnsafeMutableRawPointer) { benchSinkSlot.pointee &+= 1 }

@inline(never) @_optimize(none)
func benchOpaque(_ v: UInt64) -> UInt64 { return v }

@inline(never) @_optimize(none)
func benchOpaque(_ v: Int) -> Int { return v }

@inline(__always)
func benchNowNs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

func benchErr(_ s: String) {
    var s = s
    s.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
}

func benchFixed4(_ x: Double) -> String {
    var buf = [CChar](repeating: 0, count: 64)
    _ = withVaList([x]) { vsnprintf(&buf, 64, "%.4f", $0) }
    return String(cString: buf)
}

func benchHex16(_ x: UInt64) -> String {
    let h = String(x, radix: 16)
    return String(repeating: "0", count: 16 - h.utf8.count) + h
}

// --- selection and the repetition loop ---------------------------------------

final class Bench {
    var wantId: String
    var wantSize: UInt64?
    var minTotalNs: UInt64
    var fixedReps: UInt64
    var id = ""
    var size: UInt64 = 0
    var ops: UInt64 = 0
    var reps: UInt64 = 0
    var minNs: UInt64 = UInt64.max
    var totalNs: UInt64 = 0
    var t0: UInt64 = 0
    var check: UInt64 = 0
    var warm = false

    // `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`, or the same four
    // from BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS.
    init() {
        func env(_ k: String) -> String? {
            guard let p = getenv(k) else { return nil }
            return String(cString: p)
        }
        var id = env("BENCH_ROW")
        var size = env("BENCH_SIZE")
        var minMs = env("BENCH_MIN_MS")
        var reps = env("BENCH_REPS")
        var pos = 0
        for a in CommandLine.arguments.dropFirst() {
            if a.hasPrefix("--min-ms=") {
                minMs = String(a.dropFirst(9))
            } else if a.hasPrefix("--reps=") {
                reps = String(a.dropFirst(7))
            } else if pos == 0 {
                id = a
                pos += 1
            } else {
                size = a
            }
        }
        wantId = id ?? "list"
        wantSize = size.flatMap { UInt64($0) }
        minTotalNs = (minMs.flatMap { UInt64($0) } ?? 200) * 1_000_000
        fixedReps = reps.flatMap { UInt64($0) } ?? 0
    }

    // True when the row at this size is to run now. In list mode it prints the
    // pair and answers false, so `prog list` enumerates what a program holds.
    func want(_ id: String, _ size: UInt64) -> Bool {
        if wantId == "list" {
            print("\(id),\(size)")
            return false
        }
        if wantId != "all" && wantId != id { return false }
        if let s = wantSize, s != size { return false }
        self.id = id
        self.size = size
        return true
    }

    func begin(_ opsPerRep: UInt64) {
        ops = opsPerRep
        reps = 0
        minNs = UInt64.max
        totalNs = 0
        check = 0
        warm = false
    }

    func next() -> Bool {
        if !warm { return true }
        if fixedReps != 0 { return reps < fixedReps }
        return reps < 3 || (totalNs < minTotalNs && reps < 100_000_000)
    }

    @inline(__always)
    func tic() { t0 = benchNowNs() }

    @inline(__always)
    func toc(_ check: UInt64) {
        let dt = benchNowNs() &- t0
        self.check = check
        if !warm {
            warm = true
            return
        }
        reps += 1
        totalNs += dt
        if dt < minNs { minNs = dt }
    }

    func end() {
        print("\(id),\(size),\(benchFixed4(Double(minNs) / Double(ops))),\(reps)")
        fflush(nil)
        benchErr("check,\(id),\(size),\(benchHex16(check)),\(ops)\n")
    }

    // A row this program cannot run: the cell stays empty in the report.
    func skip() {
        print("\(id),\(size),nan,0")
        fflush(nil)
    }
}

// --- the shared inputs -------------------------------------------------------

// xorshift64 (13, 7, 17), seeded alike in every language.
let benchSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

struct BenchRng {
    var s: UInt64 = benchSeed

    @inline(__always)
    mutating func next() -> UInt64 {
        s ^= s &<< 13
        s ^= s &>> 7
        s ^= s &<< 17
        return s
    }

    // Uniform in [0, n) for n < 2^32, with no division.
    @inline(__always)
    mutating func below(_ n: UInt64) -> UInt64 {
        return ((next() &>> 32) &* n) &>> 32
    }

    mutating func letters(_ len: Int, _ alphabet: UInt64) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(len)
        for _ in 0..<len { bytes.append(UInt8(ascii: "a") &+ UInt8(truncatingIfNeeded: below(alphabet))) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// The "fast hasher" of the rows that name one; cpp/bench.h has the same.
let benchK0: UInt64 = 0x2D35_8DCC_AA6C_78A5
let benchK1: UInt64 = 0x8BB8_4B93_962E_ACC9

@inline(__always)
func benchFold(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let m = a.multipliedFullWidth(by: b)
    return m.low ^ m.high
}

@inline(__always)
func benchFastHashU64(_ x: UInt64) -> UInt64 { return benchFold(x ^ benchK0, benchK1) }

@inline(__always)
func benchRead64(_ p: UnsafeRawBufferPointer, _ off: Int) -> UInt64 {
    return UInt64(littleEndian: p.loadUnaligned(fromByteOffset: off, as: UInt64.self))
}

@inline(__always)
func benchFastHashBytes(_ p: UnsafeRawBufferPointer) -> UInt64 {
    var off = 0
    var len = p.count
    var h = benchK0 ^ UInt64(truncatingIfNeeded: len)
    if len >= 32 {
        var a = h
        var b = h
        repeat {
            a = benchFold(benchRead64(p, off) ^ benchK0, benchRead64(p, off + 8) ^ a)
            b = benchFold(benchRead64(p, off + 16) ^ benchK1, benchRead64(p, off + 24) ^ b)
            off += 32
            len -= 32
        } while len >= 32
        h = a ^ b
    }
    while len >= 8 {
        h = benchFold(h ^ benchRead64(p, off), benchK1)
        off += 8
        len -= 8
    }
    if len != 0 {
        var w: UInt64 = 0
        withUnsafeMutableBytes(of: &w) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: p[off..<(off + len)])) }
        h = benchFold(h ^ UInt64(littleEndian: w), benchK1)
    }
    return benchFold(h, benchK0)
}

// The fast hash of a String's UTF-8 bytes.
func benchFastHashString(_ s: String) -> UInt64 {
    return s.utf8.withContiguousStorageIfAvailable { benchFastHashBytes(UnsafeRawBufferPointer($0)) }!
}
