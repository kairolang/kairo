//  build: kairo C4-semadump-labels-specialization-as-redecl-chain.k --print-sema --type-check-only
// version: kairo-0.1.1+dev.20260907
//
// ### Expected behavior
// Render explicit specializations as their own row, not a chain member,
// e.g.:
//   <tu>::Box   class Box @ 1:1  [definition]  [canonical]
//   class <> Box<bool> [specialization of Box @ 1:1]  @ 5:1
//
// ### Additional context
// Source: Compiler/Sema/SemaDump.k. Confirmed live: phase: Checked, 0
// errors, but the multi-decl-names section renders the primary template
// and its explicit specialization as one ordinary redeclaration chain
// ("<tu>::Box [redecl chain x2]" listing both as plain chain members). It
// also duplicates the scope-table entry: "<tu>::Box [1 name(s)]" prints
// twice with different field sets, once per decl in the chain, instead of
// showing the specialization as a distinct thing.

class <T> Pair { var a: T; var b: T }

class <> Pair<bool>;
class <> Pair<bool> { var packed: u8 }

class <> Pair<i32> { var x: i32 }

class <T> Late { var v: T }
class <> Late<u8> { var w: u8 }