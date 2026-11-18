// Unions follow the struct rule: ctors and operators yes, named functions no.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: :[[#@LINE+7]]:5: error [S048E]: a struct or union body cannot contain a named function
// ERR-NOT: error [S
union U {
    var a: i32
    var b: f32
    fn U(self, a: i32) { self.a = a }
    fn op == (self, o: Self) -> bool = self.a == o.a
    fn describe(self) -> i32 { return self.a }
}
