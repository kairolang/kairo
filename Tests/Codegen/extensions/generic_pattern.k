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
// XFAIL: *
// Waiting on ChainBinding: a field step anchors on the field's DECLARED
// type, never on it as seen through the receiver. Through `Wrap<Box<T>>`,
// `self.inner` is Wrap's bare `T`, so `.v` is R051E ("'T' has no members").
// When it XPASSes, add: `unbox<int>((& w))`, and one
// `template <class T> static T unbox(const ::generic_pattern::Wrap<::generic_pattern::Box<T>>* self)`.

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 9
