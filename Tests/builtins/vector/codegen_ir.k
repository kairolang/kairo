// The optimized IR of the vector's hot paths, as properties:
//  - push on [i32] reads the capacity and calls no function (LLVM
//    intrinsics aside) but the cold grower, which takes the preserve_most
//    convention;
//  - clear() on [i32] is one store;
//  - destroying a vector that never grew makes no call;
//  - a for loop summing a [i32] vectorizes;
//  - a vector returned by value comes back in two registers (the define
//    returns the pair), not through a hidden pointer;
//  - the grower is defined cold, preserve_most and not inlined.

pub fn push_i32(v: *[i32], x: i32) {
    v->push(x)
}

pub fn clear_i32(v: *[i32]) {
    v->clear()
}

pub fn drop_empty() -> usize {
    var v: [i32]
    return v.size()
}

pub fn sum(const v: [i32]) -> i64 {
    var s: i64 = 0
    for x in v {
        s += x
    }

    return s
}

pub fn ret_vec(n: i32) -> [i32] {
    var v: [i32]
    v.push(n)
    return v
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.ll --cache-dir %t.d/x86_64
// RUN: %FileCheck %s --check-prefixes=IR,X64 < %t.ll
// RUN: %FileCheck %s --check-prefix=GROW < %t.d/x86_64/builtin/containers/vector.ll
// RUN: %kairo %s -O2 --target=aarch64-linux-gnu --emit=llvm-ir -o %t.a64.ll --cache-dir %t.d/aarch64
// RUN: %FileCheck %s --check-prefixes=IR,A64 < %t.a64.ll
// RUN: %FileCheck %s --check-prefix=GROW < %t.d/aarch64/builtin/containers/vector.ll

// IR-LABEL: define {{.*}}@_ZN{{.*}}8push_i32
// IR-NOT:   {{ call [^@]*@[_a-km-z]}}
// IR:       load i64, ptr {{%.*}}, align 8
// IR-NOT:   {{ call [^@]*@[_a-km-z]}}
// IR:       {{ call }}preserve_mostcc {{.*}}@_ZN{{.*}}10grow_bytes
// IR-NOT:   {{ call [^@]*@[_a-km-z]}}
// IR:       store i32 %x
// IR-NOT:   {{ call [^@]*@[_a-km-z]}}
// IR:       ret void

// IR-LABEL: define {{.*}}@_ZN{{.*}}9clear_i32
// IR-NEXT:  entry:
// IR-NEXT:  getelementptr
// IR-NEXT:  store i64 0
// IR-NEXT:  ret void

// IR-LABEL: define {{.*}}@_ZN{{.*}}10drop_empty
// IR-NOT:   {{ call [^@]*@[_a-km-z]}}
// IR:       ret i64 0
// IR-NEXT:  }

// IR-LABEL: define {{.*}}@_ZN{{.*}}3sum
// IR:       {{<[0-9]+ x i64>}}
// IR:       ret i64

// X64-LABEL: define {{.*}}{ ptr, i64 } @_ZN{{.*}}7ret_vec
// A64-LABEL: define {{.*}}[2 x i64] @_ZN{{.*}}7ret_vec

// GROW:     define {{.*}}preserve_mostcc {{.*}}@_ZN{{.*}}10grow_bytes{{.*}} #[[ATTR:[0-9]+]]
// GROW:     attributes #[[ATTR]] = { cold noinline
