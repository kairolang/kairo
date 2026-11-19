// A position past the end of a HashMap's entries() slice traps (slice.k:
// the index is "checked"), whatever the map held before: nothing, entries
// since removed by each removal form, or a cleared map; a range that ends
// past the end traps too. The number of arguments picks the case; with none,
// the same reads on valid positions succeed.
//
// Cases from indexmap src/map/tests.rs (insert_before_oob, shift_insert_oob, get_index_mut2)
// Cases from indexmap tests/quick.rs (indexing)

fn keep_none(k: *const u64, v: *u64) -> bool { return false }

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    var n: u64 = 0
    var empty: {u64: u64}
    var m: {u64: u64}
    for var i: u64 = 0; i < 6; i += 1 { m.insert(i * 3, i) }

    if kind == 0 {
        n += m.entries()[0].key + m.entries()[5].key + m.entries()[1..3][1].key
        var p? = m.pop()
        n += m.entries()[4].key
        if n != 0 + 15 + 6 + 12 { return 1 }
        return 0
    }

    if kind == 1 { n += empty.entries()[0].key }                 // empty map
    if kind == 2 { n += m.entries()[6].key }                     // one past the end
    if kind == 3 { n += m.entries()[1000].key }                  // far past the end
    if kind == 4 { m.pop(); n += m.entries()[5].key }            // after pop
    if kind == 5 { m.swap_remove(3); n += m.entries()[5].key }   // after swap_remove
    if kind == 6 { m.shift_remove(3); n += m.entries()[5].key }  // after shift_remove
    if kind == 7 { m.clear(); n += m.entries()[0].key }          // after clear
    if kind == 8 { m.retain(keep_none); n += m.entries()[0].key } // after retain dropped all
    if kind == 9 { n += m.entries()[2..9].size() as u64 }               // range ends past the end
    if kind == 10 { n += m.entries()[7..].size() as u64 }               // range starts past the end
    // A trap never gets here; reaching it fails the run.
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
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
