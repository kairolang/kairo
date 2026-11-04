// `assert static` in a generic body: its condition is a C++ trait over T, so
// no Kairo pass decides it. It goes out as a C++ static_assert and clang
// decides it per instance (O15; EmitIR used to ICE on the statement).

ffi "c++" import "type_traits";

struct Plain { var x: i32; }

fn <T> mk() -> i32 {
    assert static cxx::std::is_default_constructible<T>::value, "T must be default-constructible";
    return 1;
}

fn main() -> i32 {
    return mk<Plain>() - 1;
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
