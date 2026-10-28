// `prot` from a subclass in another module is C++'s protected
// ([class.protected]), since the emitted C++ writes it `protected:`: the
// subclass reaches an instance member of its base only through an object
// of its own class or of one deriving from it, and calls a `prot`
// constructor only as a base initializer. Through `self`, another
// Counter, a Grand (deriving Counter), a static, a nested type and the
// base initializer: clean. Through a bare `*Base`, a sibling subclass,
// or a standalone `Base(5)`: refused, each with a note at the member and
// a fix-it making it `pub`. Inputs/access_prot_object_lib.k reads them all
// in its own file.

import Inputs::access_prot_object_lib::*

class Counter derives Base {
    fn Counter(self) { Base::Base(self, 2) }
    fn own(self) -> i32 { return self.hits }
    fn other(self, c: *Counter) -> i32 { return c->hits }
    fn deeper(self, g: *Grand) -> i32 { return g->hits }
    fn statics(self) -> i32 { return Base::scale }
    fn nested(self) -> i32 { var i = Base::Inner{}; return i.k }
    fn via_base(self, b: *Base) -> i32 { return b->hits }
    fn call_base(self, b: *Base) { b->bump(1) }
    fn sibling(self, s: *Sibling) -> i32 { return s->hits }
    fn standalone(self) -> i32 { var b = Base(5); return 0 }
}

class Grand derives Counter {
    fn mine(self) -> i32 { self.bump(1); return self.hits }
}

class Sibling derives Base {
    fn Sibling(self) { Base::Base(self, 1) }
}

fn main() -> i32 {
    var c = Counter()
    return c.own() + lib_reads(&c)
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:21:50: error [SC001E]: protected field 'hits' of 'Base' is reached here through a 'Base', not through 'Counter' or a class deriving from it
// DIAG-NEXT: fix-it:"{{.*}}/access_prot_object_lib.k":{4:5-4:9}:"pub"
// DIAG-NEXT: {{.*}}/access_prot_object_lib.k:4:14: note [SC001N]: 'hits' is protected: outside the file that declares 'Base', a class deriving from it reaches it only through an object of its own class (as C++ does, [class.protected])
// DIAG: {{.*}}:22:37: error [SC001E]: protected method 'bump' of 'Base' is reached here through a 'Base', not through 'Counter' or a class deriving from it
// DIAG-NEXT: fix-it:"{{.*}}/access_prot_object_lib.k":{6:5-6:9}:"pub"
// DIAG-NEXT: {{.*}}/access_prot_object_lib.k:6:13: note [SC001N]: 'bump' is protected: outside the file that declares 'Base', a class deriving from it reaches it only through an object of its own class (as C++ does, [class.protected])
// DIAG: {{.*}}:23:52: error [SC001E]: protected field 'hits' of 'Base' is reached here through a 'Sibling', not through 'Counter' or a class deriving from it
// DIAG-NEXT: fix-it:"{{.*}}/access_prot_object_lib.k":{4:5-4:9}:"pub"
// DIAG-NEXT: {{.*}}/access_prot_object_lib.k:4:14: note [SC001N]: 'hits' is protected: outside the file that declares 'Base', a class deriving from it reaches it only through an object of its own class (as C++ does, [class.protected])
// DIAG: {{.*}}:24:42: error [SC001E]: this constructor of 'Base' is protected: a class deriving from 'Base' calls it only as a base initializer, not to build a separate 'Base'
// DIAG-NEXT: fix-it:"{{.*}}/access_prot_object_lib.k":{7:5-7:9}:"pub"
// DIAG-NEXT: {{.*}}/access_prot_object_lib.k:7:13: note [SC001N]: declared protected here: outside the file that declares 'Base', a subclass calls it only as 'Base::Base(self, ...)' at the start of its own constructor
// END-GENERATED-CHECKS(DIAG)
