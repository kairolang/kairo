// Every shape of `@create` / `@destroy` the generic calls `create<T>(...)` /
// `destroy(p)` are written in has an attribute spelling that compiles and
// runs: a generic application with a type or value argument, a `Self::`
// path, the generic form, the parenthesized and generic `@destroy`, a
// checked nullable field of a local, a field through a pointer, an array
// element, and a `@create` nested in another's arguments.

class <T> Box {
    pub var v: T
    pub fn Box(self, v: T) { self.v = v }
}

class <T, eval N: usize> Buf {
    pub var n: usize = N
    pub fn Buf(self) { }
}

class Outer {
    pub class Inner {
        pub var k: i32 = 7
        pub fn Inner(self) { }
    }

    fn Outer(self) { }

    fn make(self) -> i32 {
        var *a = @create Self::Inner()
        var r = a->k
        @destroy a
        return r
    }
}

class Node {
    pub var v: i32 = 1
    pub fn Node(self) { }
}

class Holder {
    pub var n: *Node
    pub var opt: *Node? = null
    pub fn Holder(self, n: *Node) { self.n = n }
}

fn main() -> i32 {
    var *b = @create Box<i32>(3)
    var *g = @create Box<i32>(4)
    var *z = @create Buf<i32, 512>()
    var o = Outer()
    var r = b->v + g->v + (z->n as i32) + o.make()
    @destroy b
    @destroy(g)
    @destroy(z)
    var *h = @create Holder(@create Node())
    r += h->n->v
    @destroy h->n
    @destroy h
    var hv = Holder(@create Node())
    hv.opt = @create Node()
    r += hv.n->v + hv.opt->v
    @destroy hv.n
    @destroy hv.opt
    var arr: [*Node; 1] = [@create Node()]
    r += arr[0]->v
    @destroy arr[0]
    // 3 + 4 + 512 + 7 + 1 + 1 + 1 + 1 = 530
    return r - 500
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 30
