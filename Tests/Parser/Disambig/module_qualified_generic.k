// Nested-module trie children: qualified generic disambiguation must work
// across module scopes built by the Index-mode parser.

module Outer {
    module Inner {
        fn <T> make(v: T) -> T {
            return v
        }
    }
}

fn main() -> i32 {
    var q = Outer::Inner::make<i32>(5)
    return 0
}
