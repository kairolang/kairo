// Known-answer vectors for the hasher, one set per `mum` path, from an
// independent model of the algorithm. Each input sits at every offset 0..7
// with different bytes around it, so a read outside the range or a
// dependence on alignment changes the hash.

import std::io

/// xorshift64*: the same stream on every target.
struct Rng {
    var s: u64
}

extend Rng {
    fn next(self) -> u64 {
        self.s ^= self.s >> 12
        self.s ^= self.s << 25
        self.s ^= self.s >> 27
        return self.s * 0x2545f4914f6cdd1du64
    }

    /// Uniform in [0, n); n > 0.
    fn below(self, n: u64) -> u64 {
        return (self.next() >> 11) % n
    }
}

var failures: i32 = 0

fn fail(const what: string) {
    failures += 1
    if failures <= 20 {
        io::println(f"FAIL: {what}")
    }
}

fn check(ok: bool, const what: string) {
    if !ok {
        fail(what)
    }
}

/// The process exit status: 0 when nothing failed.
fn result(const name: string) -> i32 {
    if failures == 0 {
        io::println(f"ok {name}")
        return 0
    }
    io::println(f"FAILED {name}: {failures} failure(s)")
    return 1
}

// The hasher's byte entry point takes a slice; the tests hold raw pointers.
fn sl(p: unsafe *const u8, n: usize) -> [const u8;] {
    return unsafe Slice<const u8>(p, n)
}

eval SEED: u64 = 0x0123456789abcdefu64

fn hash_bytes(p: unsafe *const u8, n: usize) -> u64 {
    var h = Hasher(SEED)
    h.write(sl(p, n))
    return h.finish()
}

fn hash_int(v: u64) -> u64 {
    var h = Hasher(SEED)
    h.write_u64(v)
    return h.finish()
}

fn main() -> i32 {
    var lens: [usize; 30] = [0, 1, 2, 3, 4, 5, 7, 8, 9, 12, 15, 16, 17, 24, 31, 32, 33, 47, 48, 49, 63, 64, 65, 80, 96, 97, 127, 128, 255, 256]
    var ints: [u64; 10] = [
        0x0000000000000000u64,
        0x0000000000000001u64,
        0x0000000000000002u64,
        0x00000000000000ffu64,
        0x0000000000000100u64,
        0x00000000deadbeefu64,
        0x0000000100000000u64,
        0x8000000000000000u64,
        0xffffffffffffffffu64,
        0x0123456789abcdefu64,
    ]
        eval if !defined!(KAIRO_HASH_NARROW) && (defined!(__x86_64__) || defined!(__aarch64__) || defined!(__LP64__) || defined!(_WIN64) || defined!(__mips64)) {
        var want_bytes: [u64; 30] = [
            0xd2d622e277055053u64,
            0x34c0bba97acb789bu64,
            0xef0d7420aae6329du64,
            0x4d053e3cf3262182u64,
            0x804c6baa9f2f43deu64,
            0x6a8f4df0a0d17b6eu64,
            0x15c5db8d97611b62u64,
            0x2798751d7e25551cu64,
            0x7258825e1d611687u64,
            0xb19220e5d9f9098cu64,
            0xe3c7f1f5dab2fd2du64,
            0x534adc3a06a2fddcu64,
            0x6a269675412990feu64,
            0x64b59122b81cb3bdu64,
            0x9850ec01d43bf370u64,
            0x90d98a110316e92du64,
            0x832fdf10273c0bdfu64,
            0x8f3cae95a10b4649u64,
            0xd949dd4b72ac944du64,
            0xd4d96cf2a38dd0d5u64,
            0x74e3a58501f31110u64,
            0xcc0a82d0ded7841du64,
            0xfad3c25bd99cd571u64,
            0x8c3b6b9ce0781a48u64,
            0xad10ab4df4aded19u64,
            0x6cd1dc67a91da67du64,
            0x790fe5bf7445d2a3u64,
            0x23c8bdb941c5d4b4u64,
            0x7fb03700fd49faacu64,
            0xba717b9f6a6b5c8bu64,
        ]
        var want_ints: [u64; 10] = [
            0x59e7ff07d4938624u64,
            0x0f8ba4046875b635u64,
            0xf064200b6ca574d2u64,
            0x1e868f25d9a87bc7u64,
            0xe833d550676ebad1u64,
            0x0cc9163a5dcd5178u64,
            0x750e006d498a14b9u64,
            0x2a5ae22ea94a7b84u64,
            0xd075f3e64cfe103du64,
            0x0000000000000000u64,
        ]
        var want_seq: [u64; 5] = [
            0x7bf444add314d063u64,
            0x0eb82d84fd377824u64,
            0x7a94f264020d90eeu64,
            0x0000000000000000u64,
            0x0000000000000000u64,
        ]
    } else {
        var want_bytes: [u64; 30] = [
            0xf01a93ab8b84342eu64,
            0xbe6c49fe746379d1u64,
            0x8c6f7cc6a6efc53eu64,
            0x8dbca1aa189fafe1u64,
            0x43871d25db0dc747u64,
            0x0650e83f0761d5c3u64,
            0x88bd6878db267e00u64,
            0x03509b6d90840461u64,
            0xd1ff7276f4ed8191u64,
            0x896c2517877dc63fu64,
            0x3f9ab69d84e76ceeu64,
            0x926ed287c71e0f22u64,
            0x185f9e57f008c463u64,
            0x66aa0e8b1ccf03a7u64,
            0x49d3461e9270c137u64,
            0x9fb6a8808c73ae33u64,
            0xb6220ef3fe0a4b69u64,
            0xa9e20d472dbb8027u64,
            0x62f5bbaa13d8c7efu64,
            0x7f41a0c66fe27ce2u64,
            0x7b15c2ef474b5290u64,
            0x283df8e8caf28482u64,
            0x4e2428c55ccca51du64,
            0x56696f2d6d187b02u64,
            0xa0bf36a53360c43au64,
            0x302222966865871cu64,
            0x64d884937b9e66bdu64,
            0x934884aee03eedccu64,
            0x357a70a65678b4a3u64,
            0x261b75cb191251d1u64,
        ]
        var want_ints: [u64; 10] = [
            0xf181ceaf53225c3eu64,
            0x588eddca2ce27c8cu64,
            0xf31fc1388c067ed7u64,
            0x01d0592c39111fe2u64,
            0xb9063dc9d54075ddu64,
            0x9972e899974912c0u64,
            0xf9c733c5457a7823u64,
            0x1161efa2a22f3e8au64,
            0x74d1e3e064de4e16u64,
            0x00b4dac10c7d416eu64,
        ]
        var want_seq: [u64; 5] = [
            0xe220a098f86f09c8u64,
            0x0dc85e92d3d613ecu64,
            0x36084436c001b90cu64,
            0x0000000000000000u64,
            0x0000000000000000u64,
        ]
    }
    
    // The input sits at every offset 0..7 of the buffer, with different
    // bytes around it each time: the hash depends on neither the alignment
    // nor anything outside [p, p + n).
    var buf: [u8; 280]
    for var off: usize = 0; off < 8; off++ {
        for var i: usize = 0; i < 280; i++ {
            buf[i] = (0xa5 + off * 31 + i) as u8
        }
        for var i: usize = 0; i < 256; i++ {
            buf[off + i] = (i * 7 + 1) as u8
        }
        var p: unsafe *const u8 = &null
        unsafe { p = (&buf[0] as unsafe *const u8) + off }
        for var k: usize = 0; k < 30; k++ {
            var got = hash_bytes(p, lens[k])
            check(got == want_bytes[k], f"bytes n={lens[k]} off={off}: got {got}")
        }
    }

    for var k: usize = 0; k < 10; k++ {
        var got = hash_int(ints[k])
        check(got == want_ints[k], f"u64 #{k}: got {got}")
        var h = Hasher(SEED)
        h.write_usize(ints[k] as usize)
        if sizeof usize == 8 {
            check(h.finish() == want_ints[k], f"usize #{k}")
        }
    }

    var abc: [u8; 3] = [0x61, 0x62, 0x63]
    var s: unsafe *const u8 = &null
    unsafe { s = &abc[0] as unsafe *const u8 }
    var h1 = Hasher(SEED)
    h1.write(sl(s, 2))
    unsafe { h1.write(sl(s + 2, 1)) }
    var h2 = Hasher(SEED)
    h2.write(sl(s, 1))
    unsafe { h2.write(sl(s + 1, 2)) }
    check(h1.finish() == want_seq[0], f"ab,c: got {h1.finish()}")
    check(h2.finish() == want_seq[1], f"a,bc: got {h2.finish()}")
    check(h1.finish() != h2.finish(), "ab,c equals a,bc")

    var p0: unsafe *const u8 = &null
    unsafe { p0 = &buf[0] as unsafe *const u8 }
    for var i: usize = 0; i < 40; i++ {
        buf[i] = (i * 7 + 1) as u8
    }
    var h3 = Hasher(SEED)
    h3.write_u64(7)
    h3.write(sl(p0, 40))
    h3.write_u64(9)
    check(h3.finish() == want_seq[2], f"mixed sequence: got {h3.finish()}")

    var h4 = Hasher(0)
    check(h4.finish() == want_seq[3], f"empty, seed 0: got {h4.finish()}")
    h4.write(sl(p0, 0))
    check(h4.finish() == want_seq[4], f"zero-length write, seed 0: got {h4.finish()}")

    // A different seed gives a different hash of the same key.
    var h5 = Hasher(SEED ^ 1)
    h5.write_u64(1)
    check(h5.finish() != want_ints[1], "seed does not reach the hash")

    return result("hash_kat")
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok hash_kat
// RUN: %kairo_new %s -o %t.o0.exe --cache-dir %t.d
// RUN: %t.o0.exe | %FileCheck %s
// The narrow (32-bit target) path, forced on this host.
// RUN: %kairo_new %s -O2 -DKAIRO_HASH_NARROW -o %t.narrow.exe --cache-dir %t.dn
// RUN: %t.narrow.exe | %FileCheck %s
