// Defect: contains, the `in` operator and index_of (all through slice_find) do not
// compile on a slice of a move-only element type that implements Eq:
// slice_find<T> is rejected with SC182E ("cannot copy a value of type" at
// `var x = *v`, in the branch taken only for integral elements) even though
// the element's `==` takes its operand by const. Expected: the members
// work on any `T impl Eq`, as binary_search and is_sorted do on `T impl Ord`.
//
// Cases from libc++ test/std/algorithms/alg.nonmodifying/alg.find/
// Cases from Rust library/coretests/tests/slice.rs (contains, position)

import self::inputs::inst::*
import std::io

fn main() -> i32 {
    {
        var v = insts(6, 0, 2)
        const s: [const Inst;] = v
        check(s.contains(Inst(4, 99)) && !s.contains(Inst(5, 99)), "inst contains", 1)
        check(Inst(8, 99) in s && !(Inst(9, 99) in s), "inst in operator", 2)
        var i? = s.index_of(Inst(10, 99))
        check((i ?? 99) == 5, "inst index_of", 3)
        var l? = s.last_index_of(Inst(0, 99))
        check((l ?? 99) == 0, "inst last_index_of", 4)
        check(s.index_of(Inst(1, 99)) == null && s.last_index_of(Inst(1, 99)) == null, "inst misses", 5)
    }

    check_clean("find: instrumented", 6)
    io::println("find ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: find ok
