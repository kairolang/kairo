// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `vector<Op>` where Op is a record nested in a generic class, written in that
// class's body: Op there is L<T>::Op, which clang cannot spell, so the fill
// failed and `size_type` stayed an unmapped <ffi type> (SC063E on `v[i]`,
// SC066E on `i < v.size()`). It is dependent like `vector<T>`: the pattern.
// CHECK-NOT: error
// CHECK-NOT: ffi type

ffi "c++" import "vector"

pub class <T> L {
    struct Op { var index: usize; var item: T; }
    priv var ops: cxx::std::vector<Self::Op>;
    pub fn sum(self) -> usize {
        var n: usize = 0;
        for var j: usize = 0; j < self.ops.size(); j++ { n += self.ops[j].index; }
        return n;
    }
}

fn main() -> i32 {
    var l: L<i32>;
    return (l.sum()) as i32;
}
