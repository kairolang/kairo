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
// Tokens 0-156 are the per-TU preamble (the `__kairo_array` alias, the
// `__kairo_tmp` helper, the `__kairo_nd` non-deduced wrapper, the `__kairo_vt` variant tag and the
// `__kairo_construct_at` / `__kairo_destroy_at` helpers, and the
// division-by-zero crash's declaration). It is synthesized
// and has no Kairo bytes, so it is emitted unanchored (EmitSink::unanchored):
// every token is an arena token with a location of its own, and none of them
// takes a byte of this file. Its fid prints as the invalid sentinel;
// wildcarded so the test does not pin that value. If these ever turn
// borrowed again, the preamble is eating the file's bytes, and every real
// token after it -- a declaration's name, which clang points its notes at --
// is pushed off its own span.
//
// The real tokens then claim their own bytes, each a UNIQUE location
// (duplicates corrupted clang's annotation cache, see TokenSink::_claim).
// `main` anchors at its name (3, len 4), and the name's first byte is kept
// for the token that spells exactly `main`, so `int` (anchored there too)
// moves to 4 and `main` takes 3. `(` and `)` walk on to 5 and 6, and the
// `noexcept` every Kairo function carries (StmtTyping::_stamp_no_unwind) to
// 7. `4` is a
// borrowed LITERAL: CreateString gives it an expansion location of its own,
// so it is unique to clang whatever span it shows, and it does not claim its
// byte. Kairo elides the statement `;`, so token 165 is synthesized; it
// anchors on the `4` and takes that byte (30). `}` lands on its own (32).
//
// Tokens 167-204 are the `[[gnu::used, gnu::section("__kairo_abi")]]
// static const unsigned char __kairo_abi_alloc[] = {...};` ABI blob. Its
// attribute tokens (167-180: `[[`, `gnu::used`, `gnu::section(...)`, `]]`)
// are synthesized, so they are unanchored like the preamble (divergent, fid
// printed as the invalid sentinel, wildcarded). They borrow no file
// bytes, so the divergent count is 178. The declaration proper (181 on)
// still borrows, and its
// offsets start at 1-24 because the attribute claims no 20 bytes
// ahead of it.

// CHECK: CODEGEN TOKEN STREAM: {{.*}}m1_hello.k
// CHECK-NEXT: -- 206 token(s), 178 divergent --
// CHECK-NEXT: 0  template  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "template"
// CHECK-NEXT: 1  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 2  class  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "class"
// CHECK-NEXT: 3  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 4  comma  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ","
// CHECK-NEXT: 5  decltype  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "decltype"
// CHECK-NEXT: 6  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 7  sizeof  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "sizeof"
// CHECK-NEXT: 8  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 9  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0"
// CHECK-NEXT: 10  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 11  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 12  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "N"
// CHECK-NEXT: 13  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 14  using  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "using"
// CHECK-NEXT: 15  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_array"
// CHECK-NEXT: 16  equal  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "="
// CHECK-NEXT: 17  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 18  l_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "["
// CHECK-NEXT: 19  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "N"
// CHECK-NEXT: 20  r_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "]"
// CHECK-NEXT: 21  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 22  template  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "template"
// CHECK-NEXT: 23  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 24  class  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "class"
// CHECK-NEXT: 25  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 26  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 27  auto  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "auto"
// CHECK-NEXT: 28  star  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "*"
// CHECK-NEXT: 29  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_tmp"
// CHECK-NEXT: 30  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 31  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 32  ampamp  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "&&"
// CHECK-NEXT: 33  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "t"
// CHECK-NEXT: 34  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 35  l_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "{"
// CHECK-NEXT: 36  return  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "return"
// CHECK-NEXT: 37  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__builtin_addressof"
// CHECK-NEXT: 38  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 39  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "t"
// CHECK-NEXT: 40  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 41  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 42  r_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "}"
// CHECK-NEXT: 43  template  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "template"
// CHECK-NEXT: 44  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 45  class  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "class"
// CHECK-NEXT: 46  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 47  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 48  struct  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "struct"
// CHECK-NEXT: 49  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_nd"
// CHECK-NEXT: 50  l_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "{"
// CHECK-NEXT: 51  using  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "using"
// CHECK-NEXT: 52  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "type"
// CHECK-NEXT: 53  equal  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "="
// CHECK-NEXT: 54  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 55  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 56  r_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "}"
// CHECK-NEXT: 57  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 58  template  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "template"
// CHECK-NEXT: 59  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 60  unsigned  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "unsigned"
// CHECK-NEXT: 61  int  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "int"
// CHECK-NEXT: 62  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "I"
// CHECK-NEXT: 63  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 64  struct  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "struct"
// CHECK-NEXT: 65  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_vt"
// CHECK-NEXT: 66  l_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "{"
// CHECK-NEXT: 67  explicit  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "explicit"
// CHECK-NEXT: 68  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_vt"
// CHECK-NEXT: 69  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 70  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 71  equal  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "="
// CHECK-NEXT: 72  default  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "default"
// CHECK-NEXT: 73  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 74  r_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "}"
// CHECK-NEXT: 75  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 76  template  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "template"
// CHECK-NEXT: 77  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 78  class  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "class"
// CHECK-NEXT: 79  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 80  comma  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ","
// CHECK-NEXT: 81  class  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "class"
// CHECK-NEXT: 82  ellipsis  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "..."
// CHECK-NEXT: 83  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "A"
// CHECK-NEXT: 84  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 85  inline  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "inline"
// CHECK-NEXT: 86  void  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "void"
// CHECK-NEXT: 87  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_construct_at"
// CHECK-NEXT: 88  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 89  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 90  star  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "*"
// CHECK-NEXT: 91  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "p"
// CHECK-NEXT: 92  comma  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ","
// CHECK-NEXT: 93  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "A"
// CHECK-NEXT: 94  ampamp  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "&&"
// CHECK-NEXT: 95  ellipsis  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "..."
// CHECK-NEXT: 96  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "a"
// CHECK-NEXT: 97  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 98  l_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "{"
// CHECK-NEXT: 99  new  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "new"
// CHECK-NEXT: 100  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 101  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "p"
// CHECK-NEXT: 102  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 103  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 104  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 105  static_cast  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "static_cast"
// CHECK-NEXT: 106  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 107  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "A"
// CHECK-NEXT: 108  ampamp  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "&&"
// CHECK-NEXT: 109  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 110  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 111  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "a"
// CHECK-NEXT: 112  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 113  ellipsis  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "..."
// CHECK-NEXT: 114  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 115  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 116  r_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "}"
// CHECK-NEXT: 117  template  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "template"
// CHECK-NEXT: 118  less  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "<"
// CHECK-NEXT: 119  class  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "class"
// CHECK-NEXT: 120  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 121  greater  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ">"
// CHECK-NEXT: 122  inline  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "inline"
// CHECK-NEXT: 123  void  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "void"
// CHECK-NEXT: 124  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "__kairo_destroy_at"
// CHECK-NEXT: 125  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 126  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 127  star  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "*"
// CHECK-NEXT: 128  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "p"
// CHECK-NEXT: 129  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 130  noexcept  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "noexcept"
// CHECK-NEXT: 131  l_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "{"
// CHECK-NEXT: 132  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "p"
// CHECK-NEXT: 133  arrow  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "->"
// CHECK-NEXT: 134  tilde  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "~"
// CHECK-NEXT: 135  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "T"
// CHECK-NEXT: 136  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 137  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 138  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 139  r_brace  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "}"
// CHECK-NEXT: 140  extern  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "extern"
// CHECK-NEXT: 141  string_literal  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ""C""
// CHECK-NEXT: 142  l_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "["
// CHECK-NEXT: 143  l_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "["
// CHECK-NEXT: 144  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "noreturn"
// CHECK-NEXT: 145  comma  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ","
// CHECK-NEXT: 146  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "gnu"
// CHECK-NEXT: 147  coloncolon  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "::"
// CHECK-NEXT: 148  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "cold"
// CHECK-NEXT: 149  r_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "]"
// CHECK-NEXT: 150  r_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "]"
// CHECK-NEXT: 151  void  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "void"
// CHECK-NEXT: 152  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "kairo_rt_div_zero"
// CHECK-NEXT: 153  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 154  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 155  noexcept  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "noexcept"
// CHECK-NEXT: 156  semi  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ";"
// CHECK-NEXT: 157  int  borrowed   [0:4, 3)  "int"
// CHECK-NEXT: 158  identifier  borrowed   [0:3, 4)  "main"
// CHECK-NEXT: 159  l_paren  borrowed   [0:5, 2)  "("
// CHECK-NEXT: 160  r_paren  borrowed   [0:6, 1)  ")"
// CHECK-NEXT: 161  noexcept  borrowed   [0:7, 1)  "noexcept"
// CHECK-NEXT: 162  l_brace  borrowed   [0:17, 1)  "{"
// CHECK-NEXT: 163  return  borrowed   [0:23, 6)  "return"
// CHECK-NEXT: 164  numeric_constant  borrowed   [0:30, 1)  "4"
// CHECK-NEXT: 165  semi  borrowed   [0:30, 1)  ";"
// CHECK-NEXT: 166  r_brace  borrowed   [0:32, 1)  "}"
// CHECK-NEXT: 167  l_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "["
// CHECK-NEXT: 168  l_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "["
// CHECK-NEXT: 169  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "gnu"
// CHECK-NEXT: 170  coloncolon  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "::"
// CHECK-NEXT: 171  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "used"
// CHECK-NEXT: 172  comma  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ","
// CHECK-NEXT: 173  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "gnu"
// CHECK-NEXT: 174  coloncolon  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "::"
// CHECK-NEXT: 175  identifier  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "section"
// CHECK-NEXT: 176  l_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "("
// CHECK-NEXT: 177  string_literal  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ""__kairo_abi""
// CHECK-NEXT: 178  r_paren  DIVERGENT  [{{[0-9]+}}:     ?, 1)  ")"
// CHECK-NEXT: 179  r_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "]"
// CHECK-NEXT: 180  r_square  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "]"
// CHECK-NEXT: 181  static  borrowed   [0:1, 1)  "static"
// CHECK-NEXT: 182  const  borrowed   [0:2, 1)  "const"
// CHECK-NEXT: 183  unsigned  borrowed   [0:8, 1)  "unsigned"
// CHECK-NEXT: 184  char  borrowed   [0:9, 1)  "char"
// CHECK-NEXT: 185  identifier  borrowed   [0:10, 1)  "__kairo_abi_alloc"
// CHECK-NEXT: 186  l_square  borrowed   [0:11, 1)  "["
// CHECK-NEXT: 187  r_square  borrowed   [0:12, 1)  "]"
// CHECK-NEXT: 188  equal  borrowed   [0:13, 1)  "="
// CHECK-NEXT: 189  l_brace  borrowed   [0:14, 1)  "{"
// CHECK-NEXT: 190  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0x7f"
// CHECK-NEXT: 191  comma  borrowed   [0:15, 1)  ","
// CHECK-NEXT: 192  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0x4b"
// CHECK-NEXT: 193  comma  borrowed   [0:16, 1)  ","
// CHECK-NEXT: 194  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0x41"
// CHECK-NEXT: 195  comma  borrowed   [0:18, 1)  ","
// CHECK-NEXT: 196  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0x42"
// CHECK-NEXT: 197  comma  borrowed   [0:19, 1)  ","
// CHECK-NEXT: 198  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "0x49"
// CHECK-NEXT: 199  comma  borrowed   [0:20, 1)  ","
// CHECK-NEXT: 200  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "2"
// CHECK-NEXT: 201  comma  borrowed   [0:21, 1)  ","
// CHECK-NEXT: 202  numeric_constant  DIVERGENT  [{{[0-9]+}}:     ?, 1)  "1"
// CHECK-NEXT: 203  r_brace  borrowed   [0:22, 1)  "}"
// CHECK-NEXT: 204  semi  borrowed   [0:24, 1)  ";"

// eof anchors at ksize-1, so its offset tracks the length of THIS FILE --
// including these comments. Wildcarded on purpose: an exact value would make
// the test assert a property of its own harness rather than of codegen, and
// every edit below would break it. Length 0 is the part that matters (it can
// never be confused with a real token) along with it resolving inside the
// file at all, which _loc already ICEs on.
// CHECK-NEXT: 205  eof  borrowed   [0:{{[0-9]+}}, 0)  ""
