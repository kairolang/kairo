// Only a function that stays in its TU is called by an inferred
// signature. A private function (unmarked in a file with no module is
// `priv`; written `priv` too; a method of a private class) whose body only
// reads its Box takes it as `const Box&`. An exported one (`pub`, a
// method of a `pub` class, or an unmarked function in a file under a
// `module.k`, which is `prot` and reaches the module's other files) keeps
// the written by-value form, and takes the
// reference only when it says `const`. Every read-only parameter is
// warned either way. Each body counts its calls, so none is a const
// function (which keeps every parameter by value).

static calls: i32 = 0

pub class Box {
    pub var n: i32 = 0
    pub fn Box(self, n: i32) { self.n = n }
    @copy pub fn Box(self, const o: Self) { self.n = o.n }
}

fn local_read(b: Box) -> i32 { calls += 1; return b.n }

priv fn priv_read(b: Box) -> i32 { calls += 1; return b.n }

pub fn pub_read(b: Box) -> i32 { calls += 1; return b.n }

pub fn pub_const(const b: Box) -> i32 { calls += 1; return b.n }

class Hidden {
    pub fn Hidden(self) { }
    pub fn hidden_take(self, b: Box) -> i32 { calls += 1; return b.n }
}

pub class Shown {
    pub fn Shown(self) { }
    pub fn shown_take(self, b: Box) -> i32 { calls += 1; return b.n }
}

fn main() -> i32 {
    var b = Box(1)
    var h = Hidden()
    var w = Shown()
    return local_read(b) + priv_read(b) + pub_read(b) + pub_const(b) + h.hidden_take(b) + w.shown_take(b)
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ir --emit-scope=inputs -w 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR-DAG: local_read(const{{.*}}Box & b)
// IR-DAG: priv_read(const{{.*}}Box & b)
// IR-DAG: pub_read({{[^&]*}}Box b)
// IR-DAG: pub_const(const{{.*}}Box & b)
// IR-DAG: hidden_take(const{{.*}}Box & b)
// IR-DAG: shown_take({{[^&]*}}Box b)
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WARN --implicit-check-not="warning [" --implicit-check-not="error ["
// WARN: :20:15: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
// WARN: :22:19: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
// WARN: :24:17: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
// WARN: :30:30: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
// WARN: :35:29: warning [SC224W]: parameter 'b' is never mutated; declare it 'const'
// RUN: { %kairo %S/inputs/mod/prot_read.k -I %S/inputs --print-ir --emit-scope=inputs -w 2>/dev/null || true; } | %FileCheck %s --check-prefix=PROT
// PROT: prot_read({{[^&]*}}Box b)
// PROT: priv_in_module({{.*}}const{{.*}}Box & b)
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
