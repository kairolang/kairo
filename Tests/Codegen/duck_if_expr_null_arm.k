// `var id = if (x != &null && isa<..>(x)) => (cast<..>(x)) else => &null;`
// in a duck `<T: type>` mixin: the `&null` arm is typed beside a dependent
// arm, and `id->resolved_decl` does not reach codegen unbound.
// An if-expression with a duck-rooted arm is the instance's: the local is
// `auto`, and the `&null` arm is emitted so the conditional has a common type.

class Node {
    pub var n: i32 = 0;
}
class Host derives Mixin<Host> {
    pub var node: Node = Node();
    fn get(self) -> *Node { return &self.node; }
}
class <T: type> Mixin {
    inline fn dyn(self) -> *T {
        return unsafe (&self as *T);
    }
    pub fn go(self, want: bool) -> i32 {
        var x = self.dyn()->get();
        var id = if (x != &null && want) => (x) else => &null;
        if id != &null && id->n == 0 { return 7 }
        return 1
    }
}
fn main() -> i32 {
    var h = Host();
    h.node.n = 0;
    var a = h.go(true);
    var b = h.go(false);
    return a * 10 + b
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I011W
// DIAG-NOT: I003E
// DIAG-NOT: unbound member step
// RUN: %t.exe; test $? -eq 71
