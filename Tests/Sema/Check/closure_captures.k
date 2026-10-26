// What a closure may capture (closures.md, Capture Modes; ClosureCaptures).
// With an explicit list -- `||` or named -- a binding the list leaves out
// is an error at its first use, with a note at its declaration and a
// fix-it that captures it: `||` becomes `|x|`, a named list gets `, x`.
// `self` cannot be written in a list; `||` refuses it too, and the fix-it
// removes the `||`. A MOVE value captured by copy is moved into the
// closure, so a later read of it is use-after-move (SC052E). A generic
// closure is not compiled yet (SC116E). The `ok_*` functions have none.

@move class Handle {
    pub var id: i32 = 0
    fn Handle(self, id: i32) { self.id = id }
    @move fn Handle(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Box {
    pub var n: i32 = 0
    fn bad_self(self) -> i32 {
        var f = fn ()|| -> i32 { return self.n }
        return f()
    }
}

var global_n: i32 = 3

fn bad_empty() -> i32 {
    var x = 10
    var f = fn ()|| -> i32 { return x }
    return f()
}

fn bad_named(y: i32) -> i32 {
    var x = 10
    var f = fn ()|y| -> i32 { return x + y }
    return f()
}

fn bad_nested() -> i32 {
    var x = 10
    var f = fn ()|*| -> i32 {
        var g = fn ()|| -> i32 { return *x }
        return g()
    }
    return f()
}

fn bad_moved() -> i32 {
    var h = Handle(5)
    var f = fn () -> i32 { return h.id }
    return h.id
}

fn bad_moved_named() -> i32 {
    var h = Handle(5)
    var f = fn ()|h| -> i32 { return h.id }
    return f() + h.id
}

fn bad_generic() -> i32 {
    var id = fn <T>(v: T) -> T { return v }
    return 0
}

fn ok_lists(a: i32) -> i32 {
    var b = 2
    var c = 3
    var f = fn ()|a, *b, const *c| -> i32 { return a + *b + *c + global_n }
    var g = fn ()|| -> i32 { return global_n }
    var h = fn ()|*| -> i32 { return *b + *a }
    return f() + g() + h()
}

fn ok_moved_copyable() -> i32 {
    var k = 4
    var f = fn () -> i32 { return k }
    return f() + k
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:19:41: error [SC001E]: 'self' is not captured by this closure: its capture list is '||', which captures nothing
// CHECK-NEXT: fix-it:{{.*}}:{19:22-19:24}:""
// CHECK-NEXT: closure_captures.k:18:17: note [{{.*}}]: 'self' is declared here, outside the closure
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:28:37: error [SC001E]: 'x' is not captured by this closure: its capture list is '||', which captures nothing
// CHECK-NEXT: fix-it:{{.*}}:{28:18-28:20}:"|x|"
// CHECK-NEXT: closure_captures.k:27:9: note [{{.*}}]: 'x' is declared here, outside the closure
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:34:38: error [SC001E]: 'x' is not captured by this closure: its capture list does not name it
// CHECK-NEXT: fix-it:{{.*}}:{34:20-34:20}:", x"
// CHECK-NEXT: closure_captures.k:33:9: note [{{.*}}]: 'x' is declared here, outside the closure
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:41:42: error [SC001E]: 'x' is not captured by this closure: its capture list is '||', which captures nothing
// CHECK-NEXT: fix-it:{{.*}}:{41:22-41:24}:"|x|"
// CHECK-NEXT: closure_captures.k:39:9: note [{{.*}}]: 'x' is declared here, outside the closure
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:50:12: error [SC052E]: 'h' is used after being moved
// CHECK-NEXT: closure_captures.k:49:35: note [{{.*}}]: 'h' was moved here, into the closure that captures it
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:56:18: error [SC052E]: 'h' is used after being moved
// CHECK-NEXT: closure_captures.k:55:19: note [{{.*}}]: 'h' was moved here, into the closure that captures it
// CHECK-NOT: {{warning|error}}
// CHECK: closure_captures.k:60:14: error [SC116E]: a generic closure is not yet supported
// CHECK-NOT: {{warning|error}}
