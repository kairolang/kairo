// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// An index that does not fit u32 must be diagnosed, never truncated (it once
// became `.0`, 4294967296 mod 2^32: wrong code, no diagnostic). Stage 0 types
// a literal >= 2^31 as i32, so the limit is not spelled 0xFFFFFFFF in the
// compiler (_read_tuple_index). Only this file's tree: builtin files have
// tuple steps of their own (base/alloc.k).
// AST-LABEL: AST (tree) for fid 0
// ERR: :12:3: error [S054E]: tuple index 4294967296 is too large; the largest addressable element is 4294967295
// AST-NOT: tuple-index
// AST-LABEL: AST (tree) for fid 1
t.4294967296
