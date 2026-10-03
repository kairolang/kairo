import lib::*

fn main() -> i32 {
    var raw: [i32; 1] = [3]
    var b = Box<i32>(unsafe (&raw as unsafe *void))
    return b.read()                   // 3 + 4 == 7, Hidden never named here
}

// --- lit wiring -----------------------------------------------------------
// main.k homes Box<i32>, so Box's member bodies are emitted into THIS TU, and
// Hidden is reachable only through them: sizeof (Complete), a cast to a
// pointer (Fwd) and `h->n` (Complete, though h is only a pointer). main never
// names Hidden, so the only way it reaches this preamble is EmitPlan walking
// the homed template's bodies as it walks its own.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
