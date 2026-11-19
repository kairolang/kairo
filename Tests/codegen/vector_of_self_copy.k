// RUN: %kairo %s --type-check-only
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// A class holding `[Self]` keeps its implicit transfer: clang asks about
// Vector<Json> while Json is incomplete, and the answer must not be cached
// as "no transfer" (`return j` and `push(v)` would fail with CL001E). A
// vector is move-only, so Json moves; an element is read through a borrow.
pub class Json {
    pub var items: [Json]
    pub var n: i32 = 0
    fn Json(self) = default
}

fn make() -> Json {
    var j = Json()
    j.n = 7
    return j
}

fn main() -> i32 {
    var v = make()
    var a: [Json]
    a.push(v)
    var *w = &a[0]
    return w->n
}
