// `__builtin_is_declared<P>()` over C++ paths: true for what this file's
// own headers declare (a type alias, a class template named without
// arguments, a namespace, a function), false for a name they do not, and
// never an error. The same question about `cxx::std::string` in a file
// with no header is `false` (Tests/Sema/Check/is_declared.k).

ffi "c++" import "string"

eval if __builtin_is_declared<cxx::std::string>() { fn a() -> i32 { return 1 } } else { fn a() -> i32 { return 100 } }
eval if __builtin_is_declared<cxx::std::no_such_name>() { fn b() -> i32 { return 100 } } else { fn b() -> i32 { return 2 } }

eval TEMPLATE  = __builtin_is_declared<cxx::std::basic_string>()
eval NAMESPACE = __builtin_is_declared<cxx::std>()
eval ALLOC     = __builtin_is_declared<cxx::std::allocator>()
eval FUNCTION  = __builtin_is_declared<cxx::std::to_string>()
eval NOT_STD   = __builtin_is_declared<cxx::boost::any>()
eval BARE_CXX  = __builtin_is_declared<std::string>()     // C++'s std is `cxx::std`

fn main() -> i32 {
    var t = 0
    if TEMPLATE && NAMESPACE && ALLOC && FUNCTION { t += 4 }
    if NOT_STD || BARE_CXX { t += 100 }
    if __builtin_is_declared<cxx::std::string>() {
        var s = cxx::std::string("abc")
        t += s.size() as i32
    }

    return a() + b() + t - 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
