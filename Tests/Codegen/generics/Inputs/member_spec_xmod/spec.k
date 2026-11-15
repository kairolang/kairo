// Corpus for Codegen/generics/member_spec_xmod.k: its member
// specializations, in a module of their own.
import lib::*

extend <T> G<T> {
    pub fn <> m<i32>(self) -> i32 { return 2 }
}

extend G<u8> {
    pub fn <U> m(self) -> i32 { return 3 }
}

extend G<u8> {
    pub fn <> m<i32>(self) -> i32 { return 4 }
}
