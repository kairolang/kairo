ffi "c++" import "ffi_ref_return_string.h"

class D derives Named {
    pub var mine: cxx::std::string = cxx::std::string("kairo")
    override fn name(const self) -> ffi::ref<const cxx::std::string> { return self.mine }
    override fn label(self) -> ffi::ref<cxx::std::string> { return self.mine }
}

fn Named::slot(self) -> ffi::ref<cxx::std::string> { return self.tag }

fn main() -> i32 {
    var d = D()
    if name_len(d) != 5 {          // C++ reads d.mine through name()
        return 1
    }

    relabel(&d)                    // C++ assigns d.mine through label()
    if d.mine.size() != 8 {
        return 2
    }

    var *p = &d.name()             // the field itself, not a copy
    var *q = &d.mine
    if p != q {
        return 3
    }

    var n = Named()
    n.slot() = cxx::std::string("xyz")
    if n.tag.size() != 3 {
        return 4
    }

    var copy = d.name()            // a copy; the field is not moved from
    if d.mine.size() != 8 || copy.size() != 8 {
        return 5
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// A class-type referee: `return self.mine` binds the reference (no copy,
// no move: `&d.name()` is the field's address and the field is intact
// after `var copy = d.name()`), from C++ through the virtuals and from
// Kairo. Red on a compiler without `ffi::ref`.
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
