// A type body left open at the end of the file: S048E can only land
// on the file's last token, which may be hundreds of lines below the body
// that is open, so a note now points at the body's `{`.

fn before() -> i32 { return 1 }

class Holder {
    var a: i32 = 0
    fn get(self) -> i32 { return self.a }

fn after() -> i32 { return 2 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: unclosed_type_body_note.k:{{[0-9]+}}:{{[0-9]+}}: error [S048E]: expected '}' to close the type body
// CHECK-NEXT: unclosed_type_body_note.k:7:14: note [I900N]: the type body opened here is not closed
