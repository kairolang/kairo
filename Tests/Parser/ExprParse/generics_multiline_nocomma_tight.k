// RUN: %kairo %s --print-ast=tree | %FileCheck %s
// Generic args parse onto the name, not as comparisons; the chain
// round-trips to canonical single-line source.
// CHECK: `-DeclStmt
// CHECK-NEXT:   `-VariableDecl var x
// CHECK-NEXT:     `-CallExpr (0 args)
// CHECK-NEXT:       `-ChainExpr 'Lookup<string, Vec<i32>>::create'
// CHECK-NEXT:         |-NamedIdentExpr Lookup<string, Vec<i32>>
// CHECK-NEXT:         | |-GenericArg 'string'
// CHECK-NEXT:         | `-GenericArg 'Vec<i32>'
// CHECK-NEXT:         |   `-GenericArg 'i32'
// CHECK-NEXT:         `-Step ::create
var x = Lookup<string, Vec<i32>>::create()
