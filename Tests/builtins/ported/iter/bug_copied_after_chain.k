// `copied()` on a chain of two slice iterators is rejected: `Chain` does not
// implement `PointerItems`. The doc comment on `Copied` (Lib/std2/iter.k)
// states that the inner iterator may be "an adapter over one that passes its
// items on unchanged", which a chain does; `Filter`, `Take`, `Skip`,
// `TakeWhile`, `SkipWhile`, `StepBy`, `Peekable` and `Rev` each have the
// extension and `Chain` has none. Expected: it compiles and yields the values.

import std::iter::*
import self::inputs::probe::*

fn main() -> i32 {
    var a: [i64] = [1, 2]
    var b: [i64] = [3]
    var v = iter(a.iter()).chain(b.iter()).copied().collect<[i64]>()
    expect(ints_are(v, [1, 2, 3]), "copied after chain")
    return finish()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
