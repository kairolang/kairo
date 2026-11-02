// P239: an expansion of a forwarding pack moves each element (P225), so a
// body that reads the pack again after it -- a second expansion, the same
// one on a loop's next iteration -- was handed moved-from elements. A COPY
// element passed by value is copied and the pack stays live (Doc: Ownership,
// Function Parameters), so only an expansion nothing reads the pack after
// forwards; every earlier one is plain `xs...`. S declares no transfer, so
// C++ moves its std::string out and leaves it empty: a moved-from read
// shows as a short length.

ffi "c++" import "string"

class S {
    pub var v: cxx::std::string
    fn S(self, n: usize) { self.v.resize(n) }
}

fn len(s: S) -> usize { return s.v.size() }

fn <...T> once(...xs: T) -> usize { return len(xs...) }
fn <...T> twice(...xs: T) -> usize { return len(xs...) + len(xs...) }
fn <...T> looped(...xs: T) -> usize {
    var n: usize = 0
    for var i = 0; i < 3; ++i { n += len(xs...) }
    return n
}

fn main() -> i32 {
    if once(S(3)) != 3 { return 1 }
    if twice(S(3)) != 6 { return 2 }
    if looped(S(3)) != 9 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class ... T> {{.*}} once(T && ... xs) noexcept {
// CXX-NEXT: len(static_cast<T &&>(xs){{ ?}}...);
// CXX: template<class ... T> {{.*}} twice(T && ... xs) noexcept {
// CXX: len(xs{{ ?}}...)
// CXX-NEXT: len(static_cast<T &&>(xs){{ ?}}...)
// CXX: template<class ... T> {{.*}} looped(T && ... xs) noexcept {
// CXX-NOT: static_cast<T &&>
// CXX: len(xs{{ ?}}...)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
