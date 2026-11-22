// A `@relocatable` record's transfer constructor with a body is spelled as
// a forwarder defined in the class, which callers name, delegating to a
// constructor that takes a leading `::__kairo_vt<0>` and holds the body.
// Clang marks only the in-class declaration of a `trivial_abi` record's
// copy or move constructor trivial for calls, so with the body defined out
// of line a record holding one would be passed through a pointer or by
// value depending on where its definition falls in the stream.
//  - R: a move constructor split at its const field (the slot record and
//       its constructor), whose tagged half delegates to the slot one.
//  - G<i32>: a `@relocatable` full specialization of a generic class; the
//       primary's members are instantiated and keep their one form.
//  - H holds both and is passed by value.
@relocatable
class R {
    pub const id:  i32
    pub var   pad: usize

    pub fn R(self, id: i32) {
        self.id  = id
        self.pad = 0
    }

    @move pub fn R(self, other: Self) {
        if other.id < 0 {
            self.id = 0
        } else {
            self.id = other.id
        }

        self.pad = other.pad
    }

    pub fn op finally(self) { }
}

class <T> G {
    pub var v: T
    pub fn G(self, v: T) {
        self.v = v
    }
}

@relocatable
class <> G<i32> {
    pub var v: i32
    pub var w: usize
    pub fn G(self, v: i32) {
        self.v = v
        self.w = 0
    }

    @move pub fn G(self, other: Self) {
        self.v = other.v
        self.w = other.w
    }

    pub fn op finally(self) { }
}

struct H {
    var r: R
    var g: G<i32>
    var a: u64
    var b: u64
}

@no_inline fn take(h: H) -> i32 {
    return h.r.id + h.g.v + (h.a as i32)
}

fn main() -> i32 {
    var r  = R(7)
    var r2 = r
    var g  = G<i32>(2)
    var g2 = g
    return take(H { r: r2, g: g2, a: 3, b: 4 })
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe; test $? -eq 12
// RUN: %kairo %s --print-ir | %FileCheck %s --check-prefix=CXX
// CXX:      always_inline)) R({{ ?}}::{{.*}}::R{{ ?}}&& other) noexcept{{ ?}}: R({{ ?}}::__kairo_vt<0>
// CXX:      R({{ ?}}::__kairo_vt<0>, {{ ?}}::{{.*}}::R{{ ?}}&& other) noexcept;
// CXX:      template{{ ?}}<class T> class G {
// CXX-NOT:  __kairo_vt<0>
// CXX:      class __attribute((trivial_abi)) G<signed int> {
// CXX:      always_inline)) G({{ ?}}::{{.*}}::G<signed int>{{ ?}}&& other) noexcept{{ ?}}: G({{ ?}}::__kairo_vt<0>
// CXX:      R::R({{ ?}}::__kairo_vt<0>, {{ ?}}::{{.*}}::R{{ ?}}&& other) noexcept{{ ?}}: R(__kairo_ci1(), other)
// CXX:      G<signed int>::G({{ ?}}::__kairo_vt<0>, {{ ?}}::{{.*}}::G<signed int>{{ ?}}&& other) noexcept {
