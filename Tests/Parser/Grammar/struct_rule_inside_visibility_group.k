// The same rule applies inside a visibility group in a struct body.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: :[[#@LINE+7]]:9: error [S048E]: a struct or union body cannot contain a named function
// ERR-NOT: error [S
struct S {
    pub {
        var a: i32
        fn S(self, a: i32) { self.a = a }
        fn op == (self, o: Self) -> bool = self.a == o.a
        fn helper(self) -> i32 { return self.a }
    }
}
