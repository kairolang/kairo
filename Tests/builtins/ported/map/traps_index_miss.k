// A lookup with `m[k]` that finds no entry traps (hash_map.k: "reads;
// traps on a miss"), in every build, whatever the map held before: nothing,
// one entry, thousands, an entry since removed by each removal form, or a
// cleared map. The number of arguments picks the case; with none, the same
// lookups on present keys all succeed. Every other lookup member returns
// null instead and is covered in lookup.k.
//
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.elem/at.pass.cpp
// Cases from Rust library/std/src/collections/hash/map/tests.rs (test_index_nonexistent)

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    var n: u64 = 0
    var empty: {u64: u64}
    var one: {u64: u64} = {7: 70}
    var many: {u64: u64}
    for var i: u64 = 0; i < 3000; i += 1 { many.insert(i * 2, i) }
    var s: {string: u64} = {"present": 1}

    if kind == 0 {
        n += one[7] + many[0] + many[5998] + s["present"]
        var r? = many.swap_remove(10)
        n += many[12]
        r = many.shift_remove(14)
        n += many[16]
        if n != 3084 { return 1 }
        return 0
    }

    if kind == 1 { n += empty[0] }                       // empty map
    if kind == 2 { n += one[8] }                         // one entry, another key
    if kind == 3 { n += many[5999] }                     // many entries, an odd key
    if kind == 4 { n += many[6000] }                     // one past the last key
    if kind == 5 { many.swap_remove(10); n += many[10] } // after swap_remove
    if kind == 6 { many.shift_remove(10); n += many[10] } // after shift_remove
    if kind == 7 { many.pop(); n += many[5998] }         // after pop
    if kind == 8 { many.clear(); n += many[0] }          // after clear
    if kind == 9 { n += s["absent"] }                    // string key
    if kind == 10 { n += s[""] }                         // the empty string key
    if kind == 11 { many.retain(drop_all); n += many[2] } // after retain dropped it

    return (n + 0) as i32 & 0
}

fn drop_all(k: *const u64, v: *u64) -> bool { return false }

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
// RUN: not --crash %t.exe 1
// RUN: not --crash %t.exe 1 2
// RUN: not --crash %t.exe 1 2 3
// RUN: not --crash %t.exe 1 2 3 4
// RUN: not --crash %t.exe 1 2 3 4 5
// RUN: not --crash %t.exe 1 2 3 4 5 6
// RUN: not --crash %t.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11
// RUN: not --crash %t.o2.exe 1
// RUN: not --crash %t.o2.exe 1 2
// RUN: not --crash %t.o2.exe 1 2 3
// RUN: not --crash %t.o2.exe 1 2 3 4
// RUN: not --crash %t.o2.exe 1 2 3 4 5
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11
