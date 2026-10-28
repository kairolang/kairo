// A record with a const field cannot be assigned (SC071E), but a const
// field of that type is initialized, not assigned, by the constructor's one
// `self.key = ...`: that write alone is let through. Any other write to the
// const field is CtorInitCheck's error, reported once; a local of the type
// is assigned by any `=`.

class Key {
    pub const k: i32
    fn Key(self, k: i32) { self.k = k }
}

class Box {
    pub const key: Key
    fn Box(self) {
        self.key = Key(1)
    }
    fn reset(self) { self.key = Key(4) }
}

fn f(a: Key, b: Key) -> i32 {
    var x = a
    x = b
    return x.k
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:17:22: error [SC001E]: cannot assign to const field 'key'
// DIAG-NEXT: {{.*}}:13:9: note [I900N]: 'key' is const: only a constructor of its own record initializes it, once
// DIAG: {{.*}}:22:5: error [SC071E]: cannot assign a 'Key': its field 'k' is const
// DIAG-NEXT: {{.*}}:7:1: note [I900N]: type declared here
// END-GENERATED-CHECKS(DIAG)
