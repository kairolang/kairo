// A `const` match binder on a pointer payload makes the binding itself const
// (`Expr *const`), not its pointee: the binder is passed on to a function
// taking `*Expr`. A `const` binder of a pointer to const would be rejected by
// clang (CL001E), so the run is the proof; the IR check pins the spelling.

enum Expr {
    Num { v: i64 },
    Add { l: *Expr, r: *Expr },
}

fn value(e: *Expr) -> i64 = match *e {
    case .Num(const v) => v
    case .Add(const l, const r) => value(l) + value(r)
}

fn main() -> i32 {
    var *a = @create Expr(Expr::Num { v: 2 })
    var *b = @create Expr(Expr::Num { v: 3 })
    var *s = @create Expr(Expr::Add { l: a, r: b })
    return value(s) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe; test $? -eq 5
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe; test $? -eq 5
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Expr * const & l = __kairo_m0_s.__kairo_Add.l;
// CXX: Expr * const & r = __kairo_m0_s.__kairo_Add.r;
