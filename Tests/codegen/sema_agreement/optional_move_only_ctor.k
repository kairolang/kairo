// `std::optional<Mv>(Mv(4))` over a move-only Kairo class: clang takes the
// converting constructor optional(U&&), and Sema binds the same one. The
// agreement pass joins the call to clang's tree and reports no finding (no
// I012W), and the program runs.

ffi "c++" import "optional"

class Mv {
    var id: i32
    fn Mv(self) { self.id = 3 }
    fn Mv(self, id: i32) { self.id = id }
    @move fn Mv(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn main() -> i32 {
    var o = cxx::std::optional<Mv>(Mv(4))
    return (*o).id
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d %t.exe
// RUN: { %kairo %s -fsema-agreement -v -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=AGREE --implicit-check-not=I012W --implicit-check-not='error ['
// AGREE: sema agreement: {{[1-9][0-9]*}} calls recorded, {{[1-9][0-9]*}} joined, {{[1-9][0-9]*}} agreed {{.*}} 0 disagreed in {{.*}}optional_move_only_ctor.k
// RUN: %t.exe; test $? -eq 4
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O2 -fsema-agreement -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
