// A generic ADT enum whose variant shares a type parameter's name.
// The record's tag enum is written inside `template <class T>`, where an
// enumerator `T` shadows the parameter (clang: "declaration of 'T' shadows
// template parameter", CL001E). The tag enumerator is renamed in C++ only;
// the Kairo variant keeps its name. 3 + 7 - 10.
enum <T> Box2 { T { v: T }, Empty }

fn get(b: Box2<i32>) -> i32 {
    match b {
        case .T(var v) { return v }
        case .Empty { return 7 }
    }
}

fn main() -> i32 {
    var b = Box2<i32>::T { v: 3 }
    var e = Box2<i32>::Empty
    return get(b) + get(e) - 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
