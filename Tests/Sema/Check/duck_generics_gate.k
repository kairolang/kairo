// `<T: type>` is the transitional C++-checked regime (MONO.md D1). It is on
// by default until the compiler hosts itself; with -fno-duck-generics every
// `: type` in a program file is an error, labelled at the bound. When the body uses no member of the
// parameter the fix-it deletes `: type` (an unbounded `T` accepts the same
// body); when it does, deleting it would only trade this error for R051E,
// so a note points at the first member use instead. With the regime on
// (the default, or -fduck-generics spelled out) the file is clean.

fn <T: type> uses(t: T) -> i32 { return t.value() }

fn <T: type> plain(t: T) -> T { return t }

class <X: type, Y> Pair {
    fn get(const self, y: Y) -> Y { return y }
}

fn <T: type> static_use(n: i32) -> bool { return T::classof(n) }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -fno-duck-generics 2>&1 || true; } | %FileCheck %s --check-prefix=OFF
// OFF: duck_generics_gate.k:9:6: error [SC001E]: 'T: type' needs -fduck-generics: a generic body is checked against its bounds, not per instance
// OFF-NEXT: duck_generics_gate.k:9:43: note [{{.*}}]: the body uses a member of 'T' here; declare an interface with the members it needs and bound the parameter 'T impl <Interface>'
// OFF-NOT: fix-it
// OFF: note [{{.*}}]: `: type` is the transitional regime clang checks per instance; -fduck-generics enables it
// OFF: duck_generics_gate.k:11:6: error [SC001E]: 'T: type' needs -fduck-generics
// OFF-NEXT: fix-it:"{{.*}}duck_generics_gate.k":{11:6-11:12}:""
// OFF: duck_generics_gate.k:13:9: error [SC001E]: 'X: type' needs -fduck-generics
// OFF-NEXT: fix-it:"{{.*}}duck_generics_gate.k":{13:9-13:15}:""
// OFF: duck_generics_gate.k:17:6: error [SC001E]: 'T: type' needs -fduck-generics
// OFF-NEXT: duck_generics_gate.k:17:{{[0-9]+}}: note [{{.*}}]: the body uses a member of 'T' here
// OFF-NOT: error

// RUN: { %kairo %s --type-check-only -fduck-generics 2>&1 || true; } | %FileCheck %s --check-prefix=ON --allow-empty
// ON-NOT: {{error|warning}}

// No flag is the regime on: the default until self-hosting.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=ON --allow-empty
