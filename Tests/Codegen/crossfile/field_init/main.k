import lib::*

fn main() -> i32 {
    var c = Counter()
    var h = Holder<i32>()
    return c.n + h.v + h.tag        // 42 + 0 + 7 == 49
}

// --- lit wiring -----------------------------------------------------------
// Counter's default runs in main's construction but is defined in lib's
// object; Holder<int>'s is instantiated here from the template body.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 49
