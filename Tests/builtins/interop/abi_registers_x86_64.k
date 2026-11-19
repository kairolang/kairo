// `string` and `[i32]` cross the C++ boundary by value in two registers, as
// clang passes a `trivial_abi` class of the same shape: no `sret` and no
// `byval` on either side, on x86_64-linux-gnu. The C++ side
// (inputs/abi_twin.cc) declares these functions with hand-written twins of
// the two types, receives and returns the values by value, links with this
// object and runs; Kairo frees what it made.

@no_inline pub fn echo_string(s: string) -> string {
    return s
}

@no_inline pub fn echo_vector(v: [i32]) -> [i32] {
    return v
}

pub fn make_string(n: i32) -> string {
    return f"kairo string number {n}, long enough for the heap"
}

pub fn make_vector(n: i32) -> [i32] {
    var v = Vector<i32>()
    for var i: i32 = 0; i < n; ++i {
        v.push(i)
    }

    return v
}

pub fn vector_sum(const v: [i32]) -> i32 {
    var t = 0
    for x in v {
        t += x
    }

    return t
}

pub fn take_string(s: string) -> usize {
    return s.size()
}

pub fn take_vector(v: [i32]) -> usize {
    return v.size()
}

// --- lit wiring ---
// REQUIRES: clang, host-x86_64, host-linux
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --emit=llvm-ir -o %t.d/k.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --check-prefix=KIR --input-file=%t.d/k.ll
// RUN: %clangxx -std=c++23 -S -emit-llvm -O2 -o - %S/inputs/abi_twin.cc | %FileCheck %s --check-prefix=CIR
// RUN: %kairo %S/inputs/abi_twin.cc %s -o %t.exe --cache-dir %t.d/c2
// RUN: %t.exe

// KIR-DAG: define {{.*}}{ ptr, i64 } @_ZN20abi_registers_x86_6411echo_stringEN7builtin6string6stringE(ptr %{{[^,]*}}, i64 %{{[^,)]*}})
// KIR-DAG: define {{.*}}{ ptr, i64 } @_ZN20abi_registers_x86_6411echo_vectorEN7builtin10containers6vector6VectorIiEE(ptr %{{[^,]*}}, i64 %{{[^,)]*}})
// KIR-DAG: define {{.*}}{ ptr, i64 } @_ZN20abi_registers_x86_6411make_stringEi(i32 noundef %{{[^,)]*}})

// CIR-DAG: define {{.*}}{ ptr, i64 } @_Z16pass_twin_string10TwinString(ptr %{{[^,]*}}, i64 %{{[^,)]*}})
// CIR-DAG: define {{.*}}{ ptr, i64 } @_Z16pass_twin_vector10TwinVector(ptr %{{[^,]*}}, i64 %{{[^,)]*}})
// CIR-DAG: declare {{.*}}{ ptr, i64 } @_ZN20abi_registers_x86_6411echo_stringEN7builtin6string6stringE(ptr, i64)
// CIR-DAG: declare {{.*}}{ ptr, i64 } @_ZN20abi_registers_x86_6411echo_vectorEN7builtin10containers6vector6VectorIiEE(ptr, i64)
