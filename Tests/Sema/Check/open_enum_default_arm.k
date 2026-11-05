// An `@open` enum may hold a value no variant names (enums-plain.md, closed
// and open enums), so a `default` after arms covering every variant is
// reachable: no SC121E. PatternSpace::is_open_enum read only imported and
// flags-style enums, never EnumDecl::is_open, and called it dead (found when
// the diagnostic registry's `diag_explain` gained its fallback arm).
//
// The program casts an undeclared value in and returns what the match gave it.

@open enum Code derives u32 {
    A = 1,
    B = 2,
}

fn explain(c: Code) -> i32 {
    match c {
        case Code::A { return 10; }
        case Code::B { return 20; }
        default      { return 7; }
    }
    return 0;
}

fn main() -> i32 {
    var raw: u32 = 99;
    return explain(raw as Code) + explain(Code::B);
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: SC121E
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 27
