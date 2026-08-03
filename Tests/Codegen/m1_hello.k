fn main() -> int {
    return 4
}

// NOTE: the code above MUST stay at the top of this file. Every CHECK below
// encodes a byte offset into it, so anything inserted before `fn` shifts the
// whole expected stream.

// RUN: %kairo --print-cg %s | %FileCheck %s

// The M2 exit criterion: the emitted token stream for the simplest complete
// program, locked byte-for-byte. This replaces M1's hand-written stream.
//
// Every column is load-bearing:
//
//   kind      -- structural correctness of the emission
//   family    -- borrowed vs DIVERGENT. A borrowed token that starts
//                diverging means a literal path changed silently.
//   [off,len) -- THE Kairo span, file-relative. A global/relative confusion
//                here shifted every token by one byte and was invisible until
//                this column stopped printing "?".
//   spelling  -- what clang actually receives.
//
// Tokens 0 and 1 are the point: the offset DECREASES across adjacent tokens
// (13 then 3). That is the trailing-return reorder -- `-> int` moved to
// leading position while keeping `int`'s own span, so a diagnostic about the
// return type blames the three bytes the user wrote. If that inversion ever
// disappears, the reorder has regressed to a linear token walk.
//
// Tokens 2/3 and 7 are synthesized: Kairo writes `()` but FunctionDecl does
// not retain the tokens, and Kairo elides the statement `;` entirely. Both
// borrow an adjacent REAL byte rather than a fabricated offset -- 6 is the
// last byte of `main`, 30 the last byte of `4`.

// CHECK: -- 10 token(s), 0 divergent --
// CHECK-NEXT: 0  identifier  borrowed   [13, 3)  "int"
// CHECK-NEXT: 1  identifier  borrowed   [3, 4)  "main"
// CHECK-NEXT: 2  l_paren  borrowed   [6, 1)  "("
// CHECK-NEXT: 3  r_paren  borrowed   [6, 1)  ")"
// CHECK-NEXT: 4  l_brace  borrowed   [17, 1)  "{"
// CHECK-NEXT: 5  identifier  borrowed   [23, 6)  "return"
// CHECK-NEXT: 6  numeric_constant  borrowed   [30, 1)  "4"
// CHECK-NEXT: 7  semi  borrowed   [30, 1)  ";"
// CHECK-NEXT: 8  r_brace  borrowed   [32, 1)  "}"

// eof anchors at ksize-1, so its offset tracks the length of THIS FILE --
// including these comments. Wildcarded on purpose: an exact value would make
// the test assert a property of its own harness rather than of codegen, and
// every edit below would break it. Length 0 is the part that matters (it can
// never be confused with a real token) along with it resolving inside the
// file at all, which _loc already ICEs on.
// CHECK-NEXT: 9  eof  borrowed   [{{[0-9]+}}, 0)  ""
