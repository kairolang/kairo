// `string` cannot be copied in this library, so a plain binder over a vector
// of strings or a map with string keys borrows each element: no copy, no
// error, and the binder is a reference to const in the C++. Changing it is
// refused with the borrow note.
fn main() -> i32 {
    var names: [string]
    names.push("ab")
    names.push("c")
    var m: {string: [i32]}
    m.insert("k", [1, 2])
    var n: usize = 0
    for s in names {
        n += s.size()
    }

    for (k, v) in m {
        n += k.size() + v.size()
    }

    return (n as i32) - 6
}

// --- lit wiring ---
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:   error [
// CHECK-LABEL: int main() noexcept {
// CHECK:       const{{ ?}}::builtin::string::string & s = 
// CHECK:       const{{ ?}}::builtin::string::string & k = 
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
