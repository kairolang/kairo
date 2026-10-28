// A local declaration that names a generic parameter of the function (or
// class) around it is SC116E for now: codegen emits a local declaration at
// namespace scope, where that parameter is not in scope. The error is at
// the local's name, with a note at the parameter. A local that names no
// outer parameter, or only its own, compiles (Codegen/functions/
// local_decls_generic.k). An `extend` in a body is gated too.

fn <T> wraps(x: T) -> i32 {
    fn echo(v: T) -> T { return v }                 // a parameter of type T
    class Holder { pub var h: *T? = &null }         // a field over T
    enum Tagged { One { v: *T }, None }             // a payload over T
    return 0
}

fn <eval N: i32> sized() -> i32 {
    fn get() -> i32 { return N }                    // a value parameter
    return get()
}

class <E> Outer {
    fn method(self) -> i32 {
        fn make() -> E? { return null }             // the class's parameter
        return 0
    }
}

struct P { var v: i32 }

fn extends_locally() -> i32 {
    extend P { fn twice(self) -> i32 { return self.v * 2 } }
    return 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:9:8: error [SC116E]: 'echo' is declared in a body and uses 'T', a generic parameter of 'wraps'; that is not yet supported
// DIAG-NEXT: {{.*}}:8:5: note [I900N]: 'T' is declared here; a local declaration is emitted outside the generic function, where 'T' is not in scope -- declare it at file scope with its own '<T>'
// DIAG: {{.*}}:10:11: error [SC116E]: 'Holder' is declared in a body and uses 'T', a generic parameter of 'wraps'; that is not yet supported
// DIAG-NEXT: {{.*}}:8:5: note [I900N]: 'T' is declared here; a local declaration is emitted outside the generic function, where 'T' is not in scope -- declare it at file scope with its own '<T>'
// DIAG: {{.*}}:11:10: error [SC116E]: 'Tagged' is declared in a body and uses 'T', a generic parameter of 'wraps'; that is not yet supported
// DIAG-NEXT: {{.*}}:8:5: note [I900N]: 'T' is declared here; a local declaration is emitted outside the generic function, where 'T' is not in scope -- declare it at file scope with its own '<T>'
// DIAG: {{.*}}:16:8: error [SC116E]: 'get' is declared in a body and uses 'N', a generic parameter of 'sized'; that is not yet supported
// DIAG-NEXT: {{.*}}:15:5: note [I900N]: 'N' is declared here; a local declaration is emitted outside the generic function, where 'N' is not in scope -- declare it at file scope with its own '<N>'
// DIAG: {{.*}}:22:12: error [SC116E]: 'make' is declared in a body and uses 'E', a generic parameter of 'Outer'; that is not yet supported
// DIAG-NEXT: {{.*}}:20:8: note [I900N]: 'E' is declared here; a local declaration is emitted outside the generic function, where 'E' is not in scope -- declare it at file scope with its own '<E>'
// DIAG: {{.*}}:30:5: error [SC116E]: an 'extend' in a function body is not yet supported
// END-GENERATED-CHECKS(DIAG)
