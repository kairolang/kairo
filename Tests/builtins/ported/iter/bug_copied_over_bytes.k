// `copied()` on an iterator over a `[u8]` fails inside the library: clang
// rejects `Copied::next` ("type 'unsigned char' cannot be used prior to
// '::' because it has no members", Lib/std2/iter.k, the call of `copy`). The
// same chain over `[i8]`, `[u16]`, `[i32]`, `[u64]`, `[bool]`, `[char]` and
// `[f64]` compiles and runs. Expected: it counts three bytes.

import std::iter::*
import self::inputs::probe::*

fn main() -> i32 {
    var u: [u8] = [100, 100, 50]
    expect(iter(u.iter()).copied().count() == 3, "copied over bytes")
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
