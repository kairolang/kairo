// O48: a pointer cast between unrelated scalar pointees (`ConstPtr<u8>` as
// `ConstPtr<c_char>`) is no static_cast in C++, also when the operand is typed
// only per instance (a duck call's result in a generic class): the instance
// that retypes `const unsigned char *` as `const char *` must still compile.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

import std::c_char;
ffi "c++" import "scalar_ptr_through_constptr_cast.h";

class Data { pub var owned_ptr: ConstPtr<u8> = &null; }
class Table { pub var d: Data; fn get(self) -> unsafe *Data { return unsafe &self.d; } }
class Ctx { pub var t: Table; }

class <T: type> Base {
    pub var ctx: unsafe *Ctx = &null;
    fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn first(self) -> u8 {
        var imm = self.dyn()->ctx->t.get();
        var p = unsafe ((unsafe (imm->owned_ptr as ConstPtr<c_char>) as unsafe *const u8) as *const u8);
        return unsafe p[0];
    }
}
class D derives Base<D> { }

fn main() -> i32 {
    var s = "hi";
    var c = Ctx {};
    c.t.d.owned_ptr = unsafe (s.as_ptr() as unsafe *const u8);
    var d = D();
    d.ctx = unsafe &c;
    if d.first() == 104 { return 0; }
    return 1;
}
