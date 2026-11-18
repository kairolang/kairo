// A pack expansion over a pattern (`Box<T>...`) is SC116E in a pack
// parameter's type and in a type argument; it used to abort CallLowering or
// CXXSpell.
class <T> Box { var v: i32 = 0 }
class <...T> Tup { var v: i32 = 0 }

fn <...T> count(...args: Box<T>...) -> i32 { return 0 }
fn <...T> wrap(...args: T) -> Tup<Box<T>...> { return Tup<Box<T>...>() }

fn main() -> i32 { return count(Box<i32>(), Box<bool>()) }

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not=I003E --implicit-check-not=internal
// CHECK: variadic_pattern_unsupported.k:7:26: error [SC116E]: a pack expansion over a pattern is not yet supported
// CHECK: variadic_pattern_unsupported.k:8:{{[0-9]+}}: error [SC116E]: a pack expansion over a pattern is not yet supported
