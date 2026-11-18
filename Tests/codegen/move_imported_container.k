// GH#87: an imported template over an element that cannot be copied cannot
// be copied either. Clang declares `std::vector<Mv>`'s copy constructor and
// fails only when its body is instantiated, so its facts alone made the
// instance COPY: `var all = words` stayed a copy and the error came from
// libc++. It is MOVE, and each transfer of it is a move. A vector of a
// COPY element is still copied.

ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n }
}

fn total(v: cxx::std::vector<Mv>) -> i32 { return v[0].n + v.size() as i32 }

fn main() -> i32 {
    var words: cxx::std::vector<Mv>
    words.push_back(Mv(1))
    var all = words                         // moves
    var more: cxx::std::vector<Mv>
    more = all                              // moves
    var n = total(more)                     // moves: 1 + 1
    var ints: cxx::std::vector<i32>
    ints.push_back(3)
    var copy = ints                         // copies; ints stays live
    return n + copy[0] + ints[0] - 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}move_imported_container.k
// IR:      all = static_cast<{{.*}}vector<{{.*}}Mv{{.*}}> &&>(words);
// IR:      (more = static_cast<{{.*}}vector<{{.*}}Mv{{.*}}> &&>(all));
// IR:      total(static_cast<{{.*}}vector<{{.*}}Mv{{.*}}> &&>(more));
// IR:      copy = ints;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
