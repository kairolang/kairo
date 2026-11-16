// RUN: %kfmt --stdout %s | diff -u %S/Expected/union_impl.k -
// RUN: %kfmt --check %S/Expected/union_impl.k
//
// A union head prints back as written: its `impl` list and a `requires`
// clause, on the head line and on a continuation line.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

union Bits impl Same {
    var word: u32
    var half: u16

    fn op ==(const self, o: Bits) -> bool {
        return self.word == o.word
    }
}

union <T> Wide requires T impl Same {
    var value: T
    var raw:   u64
}

union <T> Tall
    requires T impl Same {
    var value: T
}
