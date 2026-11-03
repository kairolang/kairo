class Fwd;

pub class W {
    pub var p: unsafe *Fwd = &null

    pub fn make(self) -> Fwd {
        unsafe { return *self.p }
    }
}

fn main() -> i32 {
    var w = W()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// P253: a clang diagnostic at an out-of-line method definition lands on the
// method's name. Only one exact token gets a name's byte (TokenSink::_claim);
// the in-class declaration, spelled first, took it, so the definition's name
// walked on to its `{` (6:30). The declaration now sits on the method's first
// byte and the definition keeps the name, as P145 did for constructors.
// The error leans on a clang check Sema does not own yet (a by-value use of a
// record that is never defined); if Sema starts reporting it, move this test
// onto another clang error at the definition.
// RUN: { %kairo %s -c -o %t.o 2>&1 || true; } | %FileCheck %s
// CHECK: method_name_byte.k:6:12: error [CL001E]: incomplete result type '{{.*}}Fwd' in function definition
