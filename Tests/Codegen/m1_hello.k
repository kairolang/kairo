fn main() -> i32 {
    return 4
}

// NOTE: the code above MUST stay at the top of this file. Every CHECK below
// encodes a byte offset into it, so anything inserted before `fn` shifts the
// whole expected stream.

// RUN: { %kairo --print-cg %s || true; } | %FileCheck %s

// The M2 exit criterion: the emitted token stream for the simplest complete
// program, locked token-for-token.
//
// Every column is load-bearing:
//
//   kind      -- structural correctness of the emission
//   family    -- borrowed vs DIVERGENT. A borrowed token that starts
//                diverging means a literal path changed silently.
//   [fid:off, len) -- THE Kairo span, file-relative.
//   spelling  -- what clang actually receives.
//
// Tokens 0-42 are the per-TU preamble (the `__kairo_array` alias and the
// `__kairo_tmp` helper). It is synthesized, so it anchors at byte 0 of this
// file, and TokenSink::_claim hands every token a UNIQUE location: each one
// walks forward to the next free byte. That is why the preamble occupies
// offsets 0..41 one byte apart -- past the end of `fn main`, which is shorter
// than the preamble -- and why the real tokens after it land late (`int` at
// 42, `main` at 43 rather than at their own bytes 13 and 3). Duplicate
// locations corrupted clang's annotation cache (see _claim), so this
// displacement is the invariant, not noise; if the preamble tokens ever share
// an offset again, that bug is back.
//
// Token 9 is the one divergent token: the `0` of `sizeof(0)` has no Kairo
// bytes at all, so it is an arena token with no file location. Its fid prints
// as the invalid sentinel; wildcarded so the test does not pin that value.
//
// `return` anchors at 23 (len 6) but every byte through 46 is claimed, so it
// lands at 47 with the last byte of its caret. `4` is a borrowed LITERAL:
// CreateString gives it an expansion location of its own, so it is unique to
// clang whatever span it shows, and it keeps its own Kairo span (30) although
// the preamble's `T` was walked onto that byte. Kairo elides the statement
// `;`, so token 50 is synthesized; it anchors on the `4` and walks on to the
// next free byte (48), and `}` finds its own byte taken and lands at 49.

// CHECK: CODEGEN TOKEN STREAM: {{.*}}m1_hello.k
// CHECK-NEXT: -- 53 token(s), 1 divergent --
// CHECK-NEXT: 0  identifier  borrowed   [0:0, 1)  "template"
// CHECK-NEXT: 1  less  borrowed   [0:1, 1)  "<"
// CHECK-NEXT: 2  identifier  borrowed   [0:2, 1)  "class"
// CHECK-NEXT: 3  identifier  borrowed   [0:3, 1)  "T"
// CHECK-NEXT: 4  comma  borrowed   [0:4, 1)  ","
// CHECK-NEXT: 5  identifier  borrowed   [0:5, 1)  "decltype"
// CHECK-NEXT: 6  l_paren  borrowed   [0:6, 1)  "("
// CHECK-NEXT: 7  identifier  borrowed   [0:7, 1)  "sizeof"
// CHECK-NEXT: 8  l_paren  borrowed   [0:8, 1)  "("
// CHECK-NEXT: 9  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0"
// CHECK-NEXT: 10  r_paren  borrowed   [0:9, 1)  ")"
// CHECK-NEXT: 11  r_paren  borrowed   [0:10, 1)  ")"
// CHECK-NEXT: 12  identifier  borrowed   [0:11, 1)  "N"
// CHECK-NEXT: 13  greater  borrowed   [0:12, 1)  ">"
// CHECK-NEXT: 14  identifier  borrowed   [0:13, 1)  "using"
// CHECK-NEXT: 15  identifier  borrowed   [0:14, 1)  "__kairo_array"
// CHECK-NEXT: 16  equal  borrowed   [0:15, 1)  "="
// CHECK-NEXT: 17  identifier  borrowed   [0:16, 1)  "T"
// CHECK-NEXT: 18  l_square  borrowed   [0:17, 1)  "["
// CHECK-NEXT: 19  identifier  borrowed   [0:18, 1)  "N"
// CHECK-NEXT: 20  r_square  borrowed   [0:19, 1)  "]"
// CHECK-NEXT: 21  semi  borrowed   [0:20, 1)  ";"
// CHECK-NEXT: 22  identifier  borrowed   [0:21, 1)  "template"
// CHECK-NEXT: 23  less  borrowed   [0:22, 1)  "<"
// CHECK-NEXT: 24  identifier  borrowed   [0:23, 1)  "class"
// CHECK-NEXT: 25  identifier  borrowed   [0:24, 1)  "T"
// CHECK-NEXT: 26  greater  borrowed   [0:25, 1)  ">"
// CHECK-NEXT: 27  identifier  borrowed   [0:26, 1)  "auto"
// CHECK-NEXT: 28  star  borrowed   [0:27, 1)  "*"
// CHECK-NEXT: 29  identifier  borrowed   [0:28, 1)  "__kairo_tmp"
// CHECK-NEXT: 30  l_paren  borrowed   [0:29, 1)  "("
// CHECK-NEXT: 31  identifier  borrowed   [0:30, 1)  "T"
// CHECK-NEXT: 32  ampamp  borrowed   [0:31, 1)  "&&"
// CHECK-NEXT: 33  identifier  borrowed   [0:32, 1)  "t"
// CHECK-NEXT: 34  r_paren  borrowed   [0:33, 1)  ")"
// CHECK-NEXT: 35  l_brace  borrowed   [0:34, 1)  "{"
// CHECK-NEXT: 36  identifier  borrowed   [0:35, 1)  "return"
// CHECK-NEXT: 37  identifier  borrowed   [0:36, 1)  "__builtin_addressof"
// CHECK-NEXT: 38  l_paren  borrowed   [0:37, 1)  "("
// CHECK-NEXT: 39  identifier  borrowed   [0:38, 1)  "t"
// CHECK-NEXT: 40  r_paren  borrowed   [0:39, 1)  ")"
// CHECK-NEXT: 41  semi  borrowed   [0:40, 1)  ";"
// CHECK-NEXT: 42  r_brace  borrowed   [0:41, 1)  "}"
// CHECK-NEXT: 43  identifier  borrowed   [0:42, 1)  "int"
// CHECK-NEXT: 44  identifier  borrowed   [0:43, 1)  "main"
// CHECK-NEXT: 45  l_paren  borrowed   [0:44, 1)  "("
// CHECK-NEXT: 46  r_paren  borrowed   [0:45, 1)  ")"
// CHECK-NEXT: 47  l_brace  borrowed   [0:46, 1)  "{"
// CHECK-NEXT: 48  identifier  borrowed   [0:47, 1)  "return"
// CHECK-NEXT: 49  numeric_constant  borrowed   [0:30, 1)  "4"
// CHECK-NEXT: 50  semi  borrowed   [0:48, 1)  ";"
// CHECK-NEXT: 51  r_brace  borrowed   [0:49, 1)  "}"

// eof anchors at ksize-1, so its offset tracks the length of THIS FILE --
// including these comments. Wildcarded on purpose: an exact value would make
// the test assert a property of its own harness rather than of codegen, and
// every edit below would break it. Length 0 is the part that matters (it can
// never be confused with a real token) along with it resolving inside the
// file at all, which _loc already ICEs on.
// CHECK-NEXT: 52  eof  borrowed   [0:{{[0-9]+}}, 0)  ""
