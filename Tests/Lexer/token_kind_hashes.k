// Every hash-valued TokenKind is compute_hash() of the spelling in
// token_kind_to_readable_string(), and EvalHash.k's constants are the Python
// twin's. The lexer finds a word's kind by hashing the word, and TokenText and
// the diagnostic highlighter spell kinds from the table, so a value written
// wrong is a keyword that lexes as an identifier with nothing else failing.
//
// RUN: python3 %S/../../Scripts/check_token_hashes.py %S/../../Compiler/Token/TokenKind.k %S/../../Compiler/Support/EvalHash.k | %FileCheck %s
// CHECK-NOT: error:
// CHECK: 0 disagreements
