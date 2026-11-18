// A member a mixin's body names through the bound of its type parameter is
// the bound's, as Sema found it, even when the instance's argument declares
// the name again: `class <A derives hb::Base> Mix derives A` over hb::Hide,
// which hides `size()` and `n`, still calls `hb::Base::size()` and reads
// `hb::Base::n`, including a protected field. A virtual method still
// dispatches to the argument's override. Each instance also asserts in the
// C++ that its argument derives the bound. The agreement pass sees no
// difference on `size()`.

ffi "c++" import "inputs/param_base_bound_member.hh"

class <A derives hb::Base> Mix derives A {
    pub fn sz(self) -> i32 {
        return self.size()
    }

    pub fn field(self) -> i32 {
        return self.n
    }

    pub fn guarded(self) -> i32 {
        return self.guard
    }

    pub fn kinds(self) -> i32 {
        return self.kind()
    }
}

fn main() -> i32 {
    var m = Mix<hb::Hide>()
    var b = Mix<hb::Base>()
    if m.sz() != 1 || m.field() != 1 || m.guarded() != 5 { return 1 }
    if m.kinds() != 20 || b.kinds() != 10 || b.sz() != 1 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s -c --print-ir -fsema-agreement 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: this->{{ ?}}::hb::Base::size()
// CXX: this->{{ ?}}::hb::Base::n
// CXX: this->{{ ?}}::hb::Base::guard
// CXX: this->kind()
// CXX: static_assert(__is_base_of({{ ?}}::hb::Base, {{ ?}}::hb::Hide)
// CXX-NOT: I012W{{.*}}size
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
