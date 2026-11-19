// The hash of a string is the hash of its bytes: a literal, a view and a
// heap string of the same text hash alike and compare equal, whatever their
// ASCII bit and capacity, and different text hashes differently.

import std::io

fn hash_of(const s: string, seed: u64) -> u64 {
    var h = Hasher(seed)
    s.hash(&h)
    return h.finish()
}

fn main() -> i32 {
    var bad  = 0
    var lit  = "héllo wörld"
    var heap = lit.to_owned()
    var view = heap.view()
    var cut  = "xxhéllo wörldxx"[2..15]
    var roomy = string::with_capacity(200)
    roomy += lit

    for var seed: u64 = 0; seed < 4; seed += 1 {
        var h = hash_of(lit, seed)
        if hash_of(heap, seed) != h || hash_of(view, seed) != h { bad += 1 }
        if hash_of(cut, seed) != h || hash_of(roomy, seed) != h { bad += 1 }
        if hash_of("héllo wörle", seed) == h { bad += 1 }
        if hash_of("héllo wörl", seed) == h { bad += 1 }
    }

    // ASCII text cut from non-ASCII text carries no ASCII bit, and still
    // hashes and compares as the literal does.
    var a  = "plain"
    var av = "é plain"[3..]
    if !(a == av) || !av.is_ascii() { bad += 1 }
    if hash_of(a, 1) != hash_of(av, 1) || hash_of(a, 1) != hash_of(a.to_owned(), 1) { bad += 1 }

    // The length is part of the hash: ("ab", "c") and ("a", "bc") differ.
    var h1 = Hasher(7)
    "ab".hash(&h1)
    "c".hash(&h1)
    var h2 = Hasher(7)
    "a".hash(&h2)
    "bc".hash(&h2)
    if h1.finish() == h2.finish() { bad += 1 }

    if hash_of("", 3) != hash_of(string(), 3) { bad += 1 }

    if bad == 0 {
        io::println("ok")
    }

    return bad
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: ok
