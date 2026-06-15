// RUN: %kairo %s --print-ast=tree | %FileCheck %s
var x = Lookup<string, Vec<i32>>::create()

// Generic args parse onto the name, not as comparisons; the chain
// round-trips to canonical single-line source.
// CHECK: ChainExpr 'Lookup<string, Vec<i32>>::create'
// CHECK: NamedIdentExpr Lookup<string, Vec<i32>>
// CHECK-NOT: BinaryOperatorExpr 
// CHECK-NOT: BinaryOperatorExpr >