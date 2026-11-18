// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
//
// A tuple literal element is a value: `(1, cxx::std::move(c))` is
// `(i32, Cmd)`, not `(i32, Cmd&&)`, which no `(i32, Cmd)` return type
// accepted (SC028E "cannot convert '(i32, Cmd&&)' to '(i32, Cmd)'",
// FlagRegistry.k). A `u64&` element read as `usize` stays an error: the
// lattice has no implicit u64 -> usize, reference or not, so it needs `as`.

ffi "c++" import "vector"
ffi "c++" import "utility"

struct Cmd { var v: i32 = 0 }

fn pair() -> (i32, Cmd) {
    var c = Cmd()
    return (1, cxx::std::move(c))
}

fn widen(m: usize) -> usize {
    var prev: cxx::std::vector<u64>
    prev.push_back(1)
    return prev[m] as usize
}

fn narrow(m: usize) -> usize {
    var prev: cxx::std::vector<u64>
    prev.push_back(1)
    return prev[m]
}

// CHECK-NOT: cannot convert '(i32, Cmd
// CHECK: tuple_elem_ref.k:[[#]]:{{[0-9]+}}: error [SC028E]: cannot convert 'u64&' to 'usize'
// CHECK-NOT: error
