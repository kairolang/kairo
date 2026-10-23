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
// Tokens 0-124 are the per-TU preamble (the `__kairo_array` alias, the
// `__kairo_tmp` helper, the `__kairo_vt` variant tag and the
// `__kairo_construct_at` / `__kairo_destroy_at` helpers). It is synthesized,
// so it anchors at byte 0 of this file, and TokenSink::_claim hands every
// token a UNIQUE location: each one walks forward to the next free byte. That
// is why the preamble occupies offsets 0..123 one byte apart -- past the end
// of `fn main`, which is shorter than the preamble -- and why the real tokens
// after it land late (`int` at 124, `main` at 125 rather than at their own
// bytes 13 and 3). Duplicate
// locations corrupted clang's annotation cache (see _claim), so this
// displacement is the invariant, not noise; if the preamble tokens ever share
// an offset again, that bug is back.
//
// Token 9 is the one divergent token: the `0` of `sizeof(0)` has no Kairo
// bytes at all, so it is an arena token with no file location. Its fid prints
// as the invalid sentinel; wildcarded so the test does not pin that value.
//
// `return` anchors at 23 (len 6) but every byte through 128 is claimed, so it
// lands at 129 with the last byte of its caret. `4` is a borrowed LITERAL:
// CreateString gives it an expansion location of its own, so it is unique to
// clang whatever span it shows, and it keeps its own Kairo span (30) although
// the preamble's `T` was walked onto that byte. Kairo elides the statement
// `;`, so token 132 is synthesized; it anchors on the `4` and walks on to the
// next free byte (130), and `}` finds its own byte taken and lands at 131.

// CHECK: CODEGEN TOKEN STREAM: {{.*}}m1_hello.k
// CHECK-NEXT: -- 135 token(s), 1 divergent --
// CHECK-NEXT: 0  template  borrowed   [0:0, 1)  "template"
// CHECK-NEXT: 1  less  borrowed   [0:1, 1)  "<"
// CHECK-NEXT: 2  class  borrowed   [0:2, 1)  "class"
// CHECK-NEXT: 3  identifier  borrowed   [0:3, 1)  "T"
// CHECK-NEXT: 4  comma  borrowed   [0:4, 1)  ","
// CHECK-NEXT: 5  decltype  borrowed   [0:5, 1)  "decltype"
// CHECK-NEXT: 6  l_paren  borrowed   [0:6, 1)  "("
// CHECK-NEXT: 7  sizeof  borrowed   [0:7, 1)  "sizeof"
// CHECK-NEXT: 8  l_paren  borrowed   [0:8, 1)  "("
// CHECK-NEXT: 9  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0"
// CHECK-NEXT: 10  r_paren  borrowed   [0:9, 1)  ")"
// CHECK-NEXT: 11  r_paren  borrowed   [0:10, 1)  ")"
// CHECK-NEXT: 12  identifier  borrowed   [0:11, 1)  "N"
// CHECK-NEXT: 13  greater  borrowed   [0:12, 1)  ">"
// CHECK-NEXT: 14  using  borrowed   [0:13, 1)  "using"
// CHECK-NEXT: 15  identifier  borrowed   [0:14, 1)  "__kairo_array"
// CHECK-NEXT: 16  equal  borrowed   [0:15, 1)  "="
// CHECK-NEXT: 17  identifier  borrowed   [0:16, 1)  "T"
// CHECK-NEXT: 18  l_square  borrowed   [0:17, 1)  "["
// CHECK-NEXT: 19  identifier  borrowed   [0:18, 1)  "N"
// CHECK-NEXT: 20  r_square  borrowed   [0:19, 1)  "]"
// CHECK-NEXT: 21  semi  borrowed   [0:20, 1)  ";"
// CHECK-NEXT: 22  template  borrowed   [0:21, 1)  "template"
// CHECK-NEXT: 23  less  borrowed   [0:22, 1)  "<"
// CHECK-NEXT: 24  class  borrowed   [0:23, 1)  "class"
// CHECK-NEXT: 25  identifier  borrowed   [0:24, 1)  "T"
// CHECK-NEXT: 26  greater  borrowed   [0:25, 1)  ">"
// CHECK-NEXT: 27  auto  borrowed   [0:26, 1)  "auto"
// CHECK-NEXT: 28  star  borrowed   [0:27, 1)  "*"
// CHECK-NEXT: 29  identifier  borrowed   [0:28, 1)  "__kairo_tmp"
// CHECK-NEXT: 30  l_paren  borrowed   [0:29, 1)  "("
// CHECK-NEXT: 31  identifier  borrowed   [0:30, 1)  "T"
// CHECK-NEXT: 32  ampamp  borrowed   [0:31, 1)  "&&"
// CHECK-NEXT: 33  identifier  borrowed   [0:32, 1)  "t"
// CHECK-NEXT: 34  r_paren  borrowed   [0:33, 1)  ")"
// CHECK-NEXT: 35  l_brace  borrowed   [0:34, 1)  "{"
// CHECK-NEXT: 36  return  borrowed   [0:35, 1)  "return"
// CHECK-NEXT: 37  identifier  borrowed   [0:36, 1)  "__builtin_addressof"
// CHECK-NEXT: 38  l_paren  borrowed   [0:37, 1)  "("
// CHECK-NEXT: 39  identifier  borrowed   [0:38, 1)  "t"
// CHECK-NEXT: 40  r_paren  borrowed   [0:39, 1)  ")"
// CHECK-NEXT: 41  semi  borrowed   [0:40, 1)  ";"
// CHECK-NEXT: 42  r_brace  borrowed   [0:41, 1)  "}"
// CHECK-NEXT: 43  template  borrowed   [0:42, 1)  "template"
// CHECK-NEXT: 44  less  borrowed   [0:43, 1)  "<"
// CHECK-NEXT: 45  unsigned  borrowed   [0:44, 1)  "unsigned"
// CHECK-NEXT: 46  int  borrowed   [0:45, 1)  "int"
// CHECK-NEXT: 47  identifier  borrowed   [0:46, 1)  "I"
// CHECK-NEXT: 48  greater  borrowed   [0:47, 1)  ">"
// CHECK-NEXT: 49  struct  borrowed   [0:48, 1)  "struct"
// CHECK-NEXT: 50  identifier  borrowed   [0:49, 1)  "__kairo_vt"
// CHECK-NEXT: 51  l_brace  borrowed   [0:50, 1)  "{"
// CHECK-NEXT: 52  explicit  borrowed   [0:51, 1)  "explicit"
// CHECK-NEXT: 53  identifier  borrowed   [0:52, 1)  "__kairo_vt"
// CHECK-NEXT: 54  l_paren  borrowed   [0:53, 1)  "("
// CHECK-NEXT: 55  r_paren  borrowed   [0:54, 1)  ")"
// CHECK-NEXT: 56  equal  borrowed   [0:55, 1)  "="
// CHECK-NEXT: 57  default  borrowed   [0:56, 1)  "default"
// CHECK-NEXT: 58  semi  borrowed   [0:57, 1)  ";"
// CHECK-NEXT: 59  r_brace  borrowed   [0:58, 1)  "}"
// CHECK-NEXT: 60  semi  borrowed   [0:59, 1)  ";"
// CHECK-NEXT: 61  template  borrowed   [0:60, 1)  "template"
// CHECK-NEXT: 62  less  borrowed   [0:61, 1)  "<"
// CHECK-NEXT: 63  class  borrowed   [0:62, 1)  "class"
// CHECK-NEXT: 64  identifier  borrowed   [0:63, 1)  "T"
// CHECK-NEXT: 65  comma  borrowed   [0:64, 1)  ","
// CHECK-NEXT: 66  class  borrowed   [0:65, 1)  "class"
// CHECK-NEXT: 67  ellipsis  borrowed   [0:66, 1)  "..."
// CHECK-NEXT: 68  identifier  borrowed   [0:67, 1)  "A"
// CHECK-NEXT: 69  greater  borrowed   [0:68, 1)  ">"
// CHECK-NEXT: 70  inline  borrowed   [0:69, 1)  "inline"
// CHECK-NEXT: 71  void  borrowed   [0:70, 1)  "void"
// CHECK-NEXT: 72  identifier  borrowed   [0:71, 1)  "__kairo_construct_at"
// CHECK-NEXT: 73  l_paren  borrowed   [0:72, 1)  "("
// CHECK-NEXT: 74  identifier  borrowed   [0:73, 1)  "T"
// CHECK-NEXT: 75  star  borrowed   [0:74, 1)  "*"
// CHECK-NEXT: 76  identifier  borrowed   [0:75, 1)  "p"
// CHECK-NEXT: 77  comma  borrowed   [0:76, 1)  ","
// CHECK-NEXT: 78  identifier  borrowed   [0:77, 1)  "A"
// CHECK-NEXT: 79  ampamp  borrowed   [0:78, 1)  "&&"
// CHECK-NEXT: 80  ellipsis  borrowed   [0:79, 1)  "..."
// CHECK-NEXT: 81  identifier  borrowed   [0:80, 1)  "a"
// CHECK-NEXT: 82  r_paren  borrowed   [0:81, 1)  ")"
// CHECK-NEXT: 83  l_brace  borrowed   [0:82, 1)  "{"
// CHECK-NEXT: 84  new  borrowed   [0:83, 1)  "new"
// CHECK-NEXT: 85  l_paren  borrowed   [0:84, 1)  "("
// CHECK-NEXT: 86  identifier  borrowed   [0:85, 1)  "p"
// CHECK-NEXT: 87  r_paren  borrowed   [0:86, 1)  ")"
// CHECK-NEXT: 88  identifier  borrowed   [0:87, 1)  "T"
// CHECK-NEXT: 89  l_paren  borrowed   [0:88, 1)  "("
// CHECK-NEXT: 90  static_cast  borrowed   [0:89, 1)  "static_cast"
// CHECK-NEXT: 91  less  borrowed   [0:90, 1)  "<"
// CHECK-NEXT: 92  identifier  borrowed   [0:91, 1)  "A"
// CHECK-NEXT: 93  ampamp  borrowed   [0:92, 1)  "&&"
// CHECK-NEXT: 94  greater  borrowed   [0:93, 1)  ">"
// CHECK-NEXT: 95  l_paren  borrowed   [0:94, 1)  "("
// CHECK-NEXT: 96  identifier  borrowed   [0:95, 1)  "a"
// CHECK-NEXT: 97  r_paren  borrowed   [0:96, 1)  ")"
// CHECK-NEXT: 98  ellipsis  borrowed   [0:97, 1)  "..."
// CHECK-NEXT: 99  r_paren  borrowed   [0:98, 1)  ")"
// CHECK-NEXT: 100  semi  borrowed   [0:99, 1)  ";"
// CHECK-NEXT: 101  r_brace  borrowed   [0:100, 1)  "}"
// CHECK-NEXT: 102  template  borrowed   [0:101, 1)  "template"
// CHECK-NEXT: 103  less  borrowed   [0:102, 1)  "<"
// CHECK-NEXT: 104  class  borrowed   [0:103, 1)  "class"
// CHECK-NEXT: 105  identifier  borrowed   [0:104, 1)  "T"
// CHECK-NEXT: 106  greater  borrowed   [0:105, 1)  ">"
// CHECK-NEXT: 107  inline  borrowed   [0:106, 1)  "inline"
// CHECK-NEXT: 108  void  borrowed   [0:107, 1)  "void"
// CHECK-NEXT: 109  identifier  borrowed   [0:108, 1)  "__kairo_destroy_at"
// CHECK-NEXT: 110  l_paren  borrowed   [0:109, 1)  "("
// CHECK-NEXT: 111  identifier  borrowed   [0:110, 1)  "T"
// CHECK-NEXT: 112  star  borrowed   [0:111, 1)  "*"
// CHECK-NEXT: 113  identifier  borrowed   [0:112, 1)  "p"
// CHECK-NEXT: 114  r_paren  borrowed   [0:113, 1)  ")"
// CHECK-NEXT: 115  noexcept  borrowed   [0:114, 1)  "noexcept"
// CHECK-NEXT: 116  l_brace  borrowed   [0:115, 1)  "{"
// CHECK-NEXT: 117  identifier  borrowed   [0:116, 1)  "p"
// CHECK-NEXT: 118  arrow  borrowed   [0:117, 1)  "->"
// CHECK-NEXT: 119  tilde  borrowed   [0:118, 1)  "~"
// CHECK-NEXT: 120  identifier  borrowed   [0:119, 1)  "T"
// CHECK-NEXT: 121  l_paren  borrowed   [0:120, 1)  "("
// CHECK-NEXT: 122  r_paren  borrowed   [0:121, 1)  ")"
// CHECK-NEXT: 123  semi  borrowed   [0:122, 1)  ";"
// CHECK-NEXT: 124  r_brace  borrowed   [0:123, 1)  "}"
// CHECK-NEXT: 125  int  borrowed   [0:124, 1)  "int"
// CHECK-NEXT: 126  identifier  borrowed   [0:125, 1)  "main"
// CHECK-NEXT: 127  l_paren  borrowed   [0:126, 1)  "("
// CHECK-NEXT: 128  r_paren  borrowed   [0:127, 1)  ")"
// CHECK-NEXT: 129  l_brace  borrowed   [0:128, 1)  "{"
// CHECK-NEXT: 130  return  borrowed   [0:129, 1)  "return"
// CHECK-NEXT: 131  numeric_constant  borrowed   [0:30, 1)  "4"
// CHECK-NEXT: 132  semi  borrowed   [0:130, 1)  ";"
// CHECK-NEXT: 133  r_brace  borrowed   [0:131, 1)  "}"

// eof anchors at ksize-1, so its offset tracks the length of THIS FILE --
// including these comments. Wildcarded on purpose: an exact value would make
// the test assert a property of its own harness rather than of codegen, and
// every edit below would break it. Length 0 is the part that matters (it can
// never be confused with a real token) along with it resolving inside the
// file at all, which _loc already ICEs on.
// CHECK-NEXT: 134  eof  borrowed   [0:{{[0-9]+}}, 0)  ""
