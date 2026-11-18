// `View<const X>` is an instance of the partial specialization
// `class <T> View<const T>`, as C++ selects it: it has that body's members
// and no others. The primary's members are never instantiated for it, so
// what they name at `T = const X` (`Box<const i32>` below) is no instance of
// the program; the partial's own parameter is `X`, and its `Box<T>` is
// `Box<i32>`.

class <T> Box {
    pub var v: T

    pub fn Box(self, v: T) {
        self.v = v
    }
}

class <T> View {
    pub var p: unsafe *T

    pub fn View(self, p: unsafe *T) {
        self.p = p
    }

    pub fn which(const self) -> i32 = 1

    pub fn boxed(const self) -> Box<T> {
        unsafe {
            return Box<T>(*self.p)
        }
    }

    pub fn set(self, v: T) {
        unsafe {
            *self.p = v
        }
    }
}

class <T> View<const T> {
    pub var p: unsafe *const T

    pub fn View(self, p: unsafe *const T) {
        self.p = p
    }

    pub fn which(const self) -> i32 = 2

    pub fn boxed(const self) -> Box<T> {
        unsafe {
            return Box<T>(*self.p)
        }
    }
}

fn main() -> i32 {
    var x: i32 = 7
    var m = View<i32>(unsafe &x)
    m.set(9)
    var c = View<const i32>(unsafe &x)
    var b = c.boxed()
    b.v += 1                                        // a Box<i32>: its value is not const
    return m.which() * 100 + c.which() * 10 + b.v - 130
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: Box<const signed int>
// CXX:     template class{{.*}}Box<signed int>;
// CXX-NOT: Box<const signed int>

// The same pick as clang's: no agreement finding.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=AGREE --allow-empty
// AGREE-NOT: I012W
// RUN: %t.exe
