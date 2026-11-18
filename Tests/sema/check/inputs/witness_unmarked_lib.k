// Corpus for sema/check/witness_unmarked_cross_file.k: conformers whose
// implementing member is unmarked (private by default outside a module).
pub interface HasArea { fn area(const self) -> i32 }

// No `impl HasArea`: the unmarked member does not serve a structural use.
pub class Foo {
    pub fn Foo(self) { }
    fn area(const self) -> i32 { return 4 }
}

// The file declares the conformance: the unmarked member serves it.
pub class Sq impl HasArea {
    pub fn Sq(self) { }
    fn area(const self) -> i32 { return 1 }
}

// Written `pub`: it serves a structural use from any file.
pub class Open {
    pub fn Open(self) { }
    pub fn area(const self) -> i32 { return 2 }
}
