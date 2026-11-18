// A Kairo generic class filling a C++ template (`vector<Box<i32>>`)
// is declared to clang as a stand-in class template, whose parameter names
// were read as `gps[i]->name.imm` (TypeExport::_standin_template). A
// parameter written in a macro body, or passed as a macro argument, is a
// macro-expansion token whose imm is not an index into the file's table;
// Codegen spells it through CXXSpell::tok_name, and so does the stand-in.
// Pure coverage: the stand-in's parameter names are not visible in the
// output, so this compiled and ran before the change too.

ffi "c++" import "vector"

macro BOX! {
    class <Elem> Box {
        var v: Elem
        fn Box(self, x: Elem) { self.v = x }
    }
}

macro PAIR!(P) {
    class <P> Pair {
        var a: P
        fn Pair(self, x: P) { self.a = x }
    }
}

BOX!
PAIR!(Item)

fn main() -> i32 {
    var xs = cxx::std::vector<Box<i32>>()
    xs.push_back(Box<i32>(4))
    var ps = cxx::std::vector<Pair<i32>>()
    ps.push_back(Pair<i32>(2))
    return (xs.size() as i32) + xs[0].v + ps[0].a
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// RUN: %kairo %s -fno-shared-header-set -o %t2.exe --cache-dir %t.d
// RUN: %t2.exe; test $? -eq 7
