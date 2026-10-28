// A class naming a bounded generic record over ITSELF inside its own body
// -- a field `*Holder<Node>` in Node -- while it is still incomplete. Not
// CRTP, the same C++ problem: a concept on Holder's template head is
// checked where `Holder<Node>` is named, Node does not satisfy it yet, and
// clang rejected the program (CL001E "constraints not satisfied for class
// template 'Holder'") although Kairo had checked the bound. The head is
// unconstrained now and the bound is pinned at the instance's home.

interface Show {
    fn show(const self) -> i32
}

class <T impl Show> Holder {
    pub var p: *T
    fn Holder(self, p: *T) { self.p = p }
    fn get(const self) -> i32 { return self.p->show() }
}

class Node impl Show {
    pub var v: i32 = 4
    pub var next: *Holder<Node> = &null
    fn show(const self) -> i32 { return self.v }
}

fn main() -> i32 {
    var a = Node()
    var b = Node()
    b.v = 9
    var h = Holder<Node>(&b)
    a.next = &h
    return a.next->get() + a.show()      // 9 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
