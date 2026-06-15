// RUN: %kairo %s --print-ast | %FileCheck %s
var x = Lookup<string, Vec<i32>>::create()
// CHECK: decl_stmt(var identifier = call(chain(ident(Lookup)<named(identifier), identifier<named(i32)>>::create), args=[]))
// CHECK-NOT: {{>::identifier>}}
// CHECK-NOT: {{binop\(<, ident}}
