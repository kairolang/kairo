ffi "c++" import "utility"
import m::Ar::Ar
fn f(a: Ar) -> Ar {
    var b = a
    return cxx::std::move(b)
}
fn main() -> i32 {
    var a = Ar()
    var c = f(a)
    return 0
}
