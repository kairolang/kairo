// Strings in eval once string owns its bytes: a copy constructor with a
// body and a destructor that frees. Both are C++ constexpr, marked by the
// lang item (NameResolution::_literal_ctor_constexpr), and a constexpr
// destructor is not "a destructor that is not trivial" to an eval binding
// (EvalUsageChecking::_user_dtor). Every compile-time string is borrowed
// (cap 0), so the allocating and freeing branches are never evaluated in a
// constant expression. Before: SC001E on each eval binding below, and clang
// "non-constexpr function '~string' cannot be used in a constant
// expression" on the eval calls.

eval NAME = "Kairo"
eval EMPTY: string = ""
eval fn greet() -> string { return "hi!" }
eval fn shout(s: string) -> i32 { return 1 }
eval fn pick(a: string, b: string) -> string { return b }
eval G = greet()
eval N = shout("abc")
eval P = pick("x", "yz")

fn main() -> i32 {
    var g = greet()
    var p = pick("aa", "bbb")
    var q = p                         // a run-time copy of an eval result
    // 1 + 3 + 5 + 3 + 2 + 3 + 0 + 3 == 20
    return N + (g.length() + NAME.length() + G.length() + P.length() + p.length() + EMPTY.length() + q.length()) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: inline constexpr::builtin::string::string const NAME = ::builtin::string::string( ::__kairo_estr<75, 97, 105, 114, 111>, 5, 5);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 20
