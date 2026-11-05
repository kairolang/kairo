// O38: copying a `vector<*S>` element into another `vector<*S>` passes it as
// `push_back(const value_type&)`. The const of that parameter qualifies the
// pointer, so it is spelled `S *const &`; a prefix `const S *&` (const
// pointee) is a reference clang refuses to bind to the `S *` element.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

ffi "c++" import "vector";
class S { pub var x: i32; }
fn main() -> i32 {
    var a = S { x: 1 };
    var v = cxx::std::vector<unsafe *S>();
    var w = cxx::std::vector<unsafe *S>();
    v.push_back(unsafe &a);
    for var i: usize = 0; i < v.size(); ++i { w.push_back(v[i]); }
    if w.size() == 1 { return 0; }
    return 1;
}
