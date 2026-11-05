// O39: an lvalue argument for an imported `T&` parameter, and a receiver
// typed as an imported `T&`, are places. Bound for evaluation order, each
// is `auto&&`, never an `auto` snapshot: that copied a non-copyable record
// (clang: call to deleted constructor) and handed a copyable one's callee a
// copy to write to.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

ffi "c++" import "Inputs/o39_lref.h"

class H {
    var c: unsafe *Ctx = &null;
    var k: unsafe *Cnt = &null;
    fn f(self) -> i32 { return use(*self.c, self.c->n()); }             // 4
    fn g(self, const info: Info) -> i32 { return info.getSM().loc(info.getLoc()); }  // 4
    // The write lands on the caller's Cnt, not on a snapshot of it.
    fn h(self) -> i32 { add(*self.k, self.k->bump()); return self.k->v; }   // 1 + 1 = 2
}

fn main() -> i32 {
    var c = Ctx();
    var k = Cnt();
    var sm = SM(1, 2);
    var info = Info();
    info.sm = unsafe &sm;
    var h = H();
    h.c = unsafe &c;
    h.k = unsafe &k;
    return h.f() * 10 + h.g(info) - 4 + h.h() + 0 * k.v;
}
