// `.` on a binding a closure captures by pointer: the name is a `*S`.

struct S { var n: i32 }

extend S {
    fn bump(self) {
        self.n += 1
    }
}

fn main() -> i32 {
    var s:  S     = S { n: 1 }
    var f         = fn ()|*s| { s.bump() }
    var st: [i32] = []
    var g         = fn (r: i32)|*st| { st.push(r) }
    f()
    g(1)
    return 0
}
