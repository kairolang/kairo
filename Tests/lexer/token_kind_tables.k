// The hand-written tables in Compiler/Token/TokenKind.k name every TokenKind
// once: is_valid_token_kind (the lexer accepts a word or operator only when it
// holds for the hash), the two name tables, word_token_kinds (keyword
// completion), and the class predicates (is_keyword, is_builtin, ...). The
// enum is @open and its values are spelling hashes, so a missing row compiles
// and fails only at run time; check_token_tables.py walks the enum and every
// table and names each disagreement.
//
// RUN: python3 %S/check_token_tables.py %S/../../Compiler/Token %S/../../Scripts | %FileCheck %s
// CHECK-NOT: error:
// CHECK: 0 disagreements
