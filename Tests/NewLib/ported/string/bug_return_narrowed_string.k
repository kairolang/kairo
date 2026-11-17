// XFAIL: *
// Defect (compiler): a narrowed nullable move-only local (`var f? = string::from_utf8(b)`
// inside `if f?`) cannot be returned by name from a function that returns the
// plain type. The emitted C++ copies `f` and clang rejects it with CL001E
// ("call to implicitly-deleted copy constructor of string"); the nullables page
// says a known non-null nullable is used as its `T` directly.
// Found while writing the helper of model.k (a Rust from_utf8-style round trip).

fn from_bytes(const b: [const u8;]) -> string {
    var f? = string::from_utf8(b)
    if f? {
        return f
    }

    return string()
}

fn main() -> i32 {
    var s = from_bytes(b"h\xc3\xa9llo")
    if !(s == "héllo") {
        return 1
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
