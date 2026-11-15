// Imported by app.k: an inline function and a generic one whose bodies end
// a local with `finally()`, emitted again in the TU that calls them.
import std::io::println

pub class Res {
    pub var id: i32 = 0
    pub fn Res(self, id: i32) { self.id = id }
    fn op finally(self) { println(f"~Res {self.id}") }
}

pub inline fn end_early(c: bool) -> i32 {
    var r = Res(1)
    if c {
        r.finally()
        println("ended early")
    }

    return 1
}

pub fn <T impl Copyable> end_generic(t: T) -> i32 {
    var r = Res(2)
    r.finally()
    return 2
}

pub interface Copyable { fn tag(const self) -> i32 }
