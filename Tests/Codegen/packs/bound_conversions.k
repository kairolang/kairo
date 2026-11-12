// A pack element is held to its pack's bounds like any other parameter:
// `arg as string` and `f"{arg}"` in a `for arg in args` body are
// calls through the bound's witness, once per element, as on a `<T impl I>`
// (witness/bound_ops.k). They are not SC027E / SC080E whatever the bound
// says, and a bounded pack's C++ head does not name the pack unexpanded in its
// requires clause. Without a bound they are the bound error naming the
// requirement (Sema/Check/pack_bound_conversions.k).
pub interface Named {
    fn op as(const self) -> string
}
pub interface Shown {
    fn repr(const self) -> string
}

pub class Tag {
    pub var v: i32
    fn Tag(self, v: i32) { self.v = v }
    pub fn op as(const self) -> string = "tag"
    pub fn repr(const self) -> string = "<t>"
}
pub class Mark {
    fn Mark(self) { }
    pub fn op as(const self) -> string = "mark!"
    pub fn repr(const self) -> string = "<mark>"
}

fn <...T impl Named> total(...args: T) -> usize {
    var n: usize = 0
    for arg in args { n += (arg as string).length() }
    return n
}
fn <...T impl Shown> shown(...args: T) -> usize {
    var n: usize = 0
    for arg in args { n += f"{arg}".length() }
    return n
}

fn main() -> i32 {
    var r = 0
    if total(Tag(1), Mark(), Tag(2)) != 11 { r += 1 }   // 3 + 5 + 3
    if shown(Mark(), Tag(7)) != 9         { r += 2 }    // 6 + 3
    if total() != 0                       { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// A pack's bound is a fold over its elements, and an element's witness is
// named by the element's own type (an unexpanded `T` there is ill-formed).
// CXX: template<class ... T> requires(( {{.*}}Named_c<T> && ...)) decltype(sizeof(0)) total(T && ... args) noexcept {
// CXX: Named_witness<__remove_cvref(decltype(arg))>::__kairo_op_as
// CXX: template<class ... T> requires(( {{.*}}Shown_c<T> && ...)) decltype(sizeof(0)) shown(T && ... args) noexcept {
// CXX: Shown_witness<__remove_cvref(decltype(arg))>::repr

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
