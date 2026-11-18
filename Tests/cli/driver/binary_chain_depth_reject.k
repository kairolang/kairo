// RUN: python3 -c "print('fn main() -> i32 {\n    var x: i32 = ' + ' + '.join(['1'] * 1500) + ' + \"s\"\n    return 0\n}')" > %t.k
// RUN: { %kairo %t.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='I003E' --implicit-check-not='internal'
// A long left-leaning chain of additions with one ill-typed term is a single
// SC066E from the type checker, with no stack overflow and no internal
// error. This file is only the generator; the chain is built per run.
// CHECK: error [SC066E]: no operator '+' for operands 'i32' and 'string'
fn main() -> i32 { return 0 }
