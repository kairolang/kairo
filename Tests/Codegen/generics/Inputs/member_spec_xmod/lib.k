// Corpus for Codegen/generics/member_spec_xmod.k: the generic class.
pub class <T> G {
    pub var v: i32 = 0
    pub fn <U> m(self) -> i32 { return 1 }
}
