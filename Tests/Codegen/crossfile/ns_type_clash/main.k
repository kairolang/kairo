import Dg::E::*;
import Dg::Dg::*;

fn main() -> i32 {
    var e = E()
    var d = Dg()
    return e.run() + d.get() + 40      // 2 + 1 + 40 == 43
}

// --- lit wiring -----------------------------------------------------------
// A std::vector of the module's own same-named class is spelled `::`-rooted
// in the field of both files, so Dg::Dg::Dg is not read as a constructor name.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 43
