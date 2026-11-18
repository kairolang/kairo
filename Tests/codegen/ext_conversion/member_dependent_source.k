// A MEMBER `@implicit op as` of a generic class still converts a dependent
// source in a generic body (`Wrap<T>` to `i32`): only an extension's
// operator needs the source's arguments to know whether it applies.

class <T> Wrap {
    pub var v: T
    pub fn Wrap(self, v: T) { self.v = v }
    @implicit pub fn op as (const self) -> i32 { return 7 }
}

fn <T> g(w: Wrap<T>) -> i32 { return w }

fn main() -> i32 {
    var w = Wrap<i64>(1)
    return g(w) - 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
