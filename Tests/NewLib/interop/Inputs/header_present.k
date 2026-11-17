// header_absent.k with the C++ headers imported and the interop used.

ffi "c++" import "string_view"
ffi "c++" import "vector"

fn len(v: cxx::std::string_view) -> usize {
    return v.size()
}

fn main() -> i32 {
    var v = Vector<i32>()
    v.push(3)
    var c = v.into_cxx()
    return (c.size() + len("ab") - 3) as i32
}
