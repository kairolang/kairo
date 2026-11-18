// A `const self` method beside a base's plain-`self` virtual of the
// same name is another method (classes-inheritance.mdx: only the same
// `self` or `const self` overrides), and the base's stays callable on the
// derived value (Kairo merges the overload sets; `using KB::val;` in C++).
// The base walk that finds an overridden virtual skipped the `self`
// parameters, so the const one was recorded as overriding: C++ got
// `long val() const override`, clang dropped it (CL001E "non-virtual member
// function marked 'override' hides virtual member function", then "out-of-
// line definition of 'val' does not match any declaration"), on release
// too. Now no `override`: `d.val()` on a non-const value calls the base's
// (1), `cd.val()` on a const one the derived (2). Writing `override` on
// such a method is SC150E naming the receiver.

class KB {
    fn KB(self) {}
    virtual fn val(self) -> i32 { return 1 }
}

class KD derives KB {
    fn KD(self) {}
    fn val(const self) -> i64 { return 2 }
}

fn main() -> i32 {
    var d = KD()
    const cd = KD()
    return d.val() + (cd.val() as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}const_self_beside_virtual.k
// CXX: class KD: public{{ ?}}::{{.*}}::KB {
// CXX-NOT: override
// CXX: signed long val() const noexcept;
// CXX-NEXT: using{{ ?}}::{{.*}}::KB::val;

// RUN: printf 'class KB {\n    fn KB(self) {}\n    virtual fn val(self) -> i32 { return 1 }\n}\nclass KD derives KB {\n    fn KD(self) {}\n    override fn val(const self) -> i32 { return 2 }\n}\nfn main() -> i32 { return 0 }\n' > %t.ov.k
// RUN: { %kairo %t.ov.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OV
// OV: ov.k:7:5: error [SC150E]: 'val' is marked 'override' but overrides nothing: it takes 'const self' and the base method takes 'self'
// OV-NEXT: ov.k:3:5: note [{{.*}}]: the base method of that name, which takes 'self'

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
