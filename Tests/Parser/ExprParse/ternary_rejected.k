// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// C-style ternary (?:) is NOT a grammar construct. Conditional expressions use
// the block form: if cond { e } else { e }. The ? is postfix-only (optional/try).
a ? b : c
// ERR: error [S052E]: expected expression, found '?'
