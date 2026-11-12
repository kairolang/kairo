// Every field of every AST node class is either written by its io_
// function or named in that function's DEBUG block (DeclIO.k's rule), so a
// field added to a node and forgotten in the serializer fails here instead
// of being silently lost on reload. Scripts/check_ast_serializer.py reads
// the node files and the io_ functions; it exits 1 on a miss.
//
// RUN: python3 %S/../../../Scripts/check_ast_serializer.py | %FileCheck %s
// CHECK-NOT: is not named in
// CHECK: 0 missing
