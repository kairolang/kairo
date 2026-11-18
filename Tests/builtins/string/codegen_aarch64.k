// The properties of codegen_x86_64.k on AArch64 (AAPCS64): the same source,
// compiled for aarch64-linux-gnu. A string returns as two words, the cold
// halves are preserve_most, and the fast paths call nothing else.

// --- lit wiring ---
// REQUIRES: newlib
// REQUIRES: sysroot-aarch64-linux-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=aarch64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll

// CHECK-LABEL: define {{.*}} @_ZN{{[0-9a-zA-Z_]*}}2szE
// CHECK-NOT:   {{ call }}
// CHECK:       lshr i64 %{{.*}}, 3
// CHECK-NOT:   {{ call }}
// CHECK:       ret i64

// CHECK-LABEL: define {{.*}}7app_litE
// CHECK-NOT:   {{ call }}
// CHECK:       br i1
// CHECK-NOT:   {{ call }}
// CHECK:       br i1
// CHECK-NOT:   {{ call }}
// CHECK:       store i32 1684234849
// CHECK-NOT:   {{ call }}
// CHECK:       call preserve_mostcc [2 x i64] @{{.*}}append_slow_
// CHECK-NOT:   {{ call }}
// CHECK:       ret void

// CHECK-LABEL: define {{.*}}7app_strE
// CHECK-NOT:   {{ call }}
// CHECK:       call void @llvm.memcpy
// CHECK-NOT:   {{ call }}
// CHECK:       call preserve_mostcc [2 x i64] @{{.*}}append_slow_
// CHECK-NOT:   {{ call }}
// CHECK:       ret void

// CHECK-LABEL: define {{.*}}6push_cE
// CHECK-NOT:   {{ call }}
// CHECK:       store i16
// CHECK-NOT:   {{ call }}
// CHECK:       call preserve_mostcc [2 x i64] @{{.*}}push_slow_
// CHECK-NOT:   {{ call }}
// CHECK:       ret void

// CHECK-LABEL: define {{.*}}8drop_litE
// CHECK-NOT:   {{ call }}
// CHECK:       ret i64 5

// CHECK:       define {{[^(]*}}[2 x i64] @{{[^(]*}}3litEv()
// CHECK:       define {{[^(]*}}[2 x i64] @{{[^(]*}}4passE{{[^(]*}}([2 x i64] {{[^,)]*}})

// CHECK-LABEL: define {{.*}}4fillE
// CHECK-NOT:   alloca
// CHECK:       call preserve_mostcc [2 x i64] @{{.*}}push_slow_
// CHECK-NOT:   alloca
// CHECK:       ret [2 x i64]

// CHECK-LABEL: define {{.*}}4cstrE
// CHECK:       call preserve_mostcc [2 x i64] @{{.*}}promote_

// CHECK:       define {{[^(]*}}[2 x i64] @{{[^(]*}}11parse_smallE
// CHECK-NOT:   sret

// CHECK:       declare preserve_mostcc {{.*}}promote_{{.*}} #[[COLD:[0-9]+]]
// CHECK:       attributes #[[COLD]] = { cold
