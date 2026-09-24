// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// An index that does not fit u32 must be diagnosed, never truncated. This used
// to silently become `.0` (4294967296 mod 2^32), i.e. wrong code with no
// diagnostic. The bound is compared in u64 before any narrowing cast.
//
// NOTE the limit cannot be spelled `0xFFFFFFFF` in the compiler source: stage 0
// types a literal >= 2^31 as a signed 32-bit value, so that constant IS -1 and
// the comparison never fires. See _read_tuple_index.
// ERR: :12:3: error [S054E]: tuple index 4294967296 is too large; the largest addressable element is 4294967295
// AST-NOT: tuple-index
t.4294967296
