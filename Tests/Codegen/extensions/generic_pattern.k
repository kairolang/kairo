// generic_pattern.k -- exit 9
struct <T> Box  { var v: T; }
struct <T> Wrap { var inner: T; }

extend <T> Wrap<Box<T>> {
    fn unbox(const self) -> T { return self.inner.v; }
}

fn main() -> i32 {
    var w = Wrap<Box<i32>> { inner: Box<i32> { v: 9 } };
    return w.unbox();
}

// --- lit wiring -----------------------------------------------------------
// The extension's target is a PATTERN, `Wrap<Box<T>>`, so `self` is typed
// with it (not Wrap over Wrap's own T) and the field step `self.inner` reads
// through the receiver's args: Box<T>, whose `.v` is T. Before, `.v` was
// R051E ("'T' has no members").

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      friend struct::generic_pattern::__kairo_ext_Wrap;
// CXX:      template<class T> static T unbox(const::generic_pattern::Wrap< ::generic_pattern::Box<T>> * self);
// CXX:      template<class T> T __kairo_ext_Wrap::unbox(const::generic_pattern::Wrap< ::generic_pattern::Box<T>> * self) {
// CXX:      return::generic_pattern::__kairo_ext_Wrap::unbox<signed int>((& w));
// CXX:      template signed int({{ *}}::generic_pattern::__kairo_ext_Wrap::unbox<signed int>)(const::generic_pattern::Wrap< ::generic_pattern::Box<signed int>> *);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 9
