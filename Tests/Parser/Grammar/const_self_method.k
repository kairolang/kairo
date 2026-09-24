// A const method is spelled on the receiver: `fn f(const self)`. The C++-style
// trailing `fn f(self) const` is a hard error with a fix-it moving the const
// onto the receiver; recovery still marks the method const.
//
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s

class A {
    fn ok(const self) -> i32 { return 1 }
    fn trailing(self) const -> i32 { return 2 }
    fn both(const self) const -> i32 { return 3 }
    fn plain(self) -> i32 { return 4 }
}

fn free_fn() const -> i32 { return 5 }

// CHECK:      FunctionDecl  ok(const self) -> i32
// CHECK-NEXT: ParamDecl const self
// CHECK:      FunctionDecl  trailing(const self) -> i32
// CHECK-NEXT: ParamDecl const self
// CHECK:      FunctionDecl  both(const self) -> i32
// CHECK:      FunctionDecl  plain(self) -> i32
// CHECK-NEXT: ParamDecl self
// CHECK:      FunctionDecl  free_fn() -> i32
// CHECK: const_self_method.k:9:{{[0-9]+}}: error [S047E]: a const method is spelled 'fn name(const self)'
// CHECK: const_self_method.k:10:{{[0-9]+}}: error [S047E]: a trailing 'const' is not valid; the receiver is already 'const self'
// CHECK: const_self_method.k:14:{{[0-9]+}}: error [S047E]: a trailing 'const' is not valid here; only a method can be const
