// RUN: %kairo %s --type-check-only
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// A class holding `[Self]` keeps its implicit copy constructor: clang asks
// Vector<Json>'s copy constraint while Json is incomplete, and the answer
// must not be cached as "false" and delete Json's copy (`return j`, `push_back(v)` fail with CL001E).
// The constraint passes for an incomplete element.
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
    a.push_back(v)
    var w = a[0]
    return w.n
}
