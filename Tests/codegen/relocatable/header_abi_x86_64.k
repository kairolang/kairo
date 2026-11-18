// C++ that includes the header header_abi.k emits passes and returns the
// relocatable record the way Kairo's object code does: in two registers on
// x86-64 SysV, with no `sret` and no indirect argument.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, default-sysroot, host-x86_64, host-linux
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S && %kairo header_abi.k --type-check-only --emit-headers %t.d/h
// RUN: printf '#include "h/header_abi.hh"\nheader_abi::Res pass(header_abi::Res r) { return r; }\nunsigned long use() { return header_abi::take(pass(header_abi::make(21))); }\n' > %t.d/use.cc
// RUN: %clangxx -std=c++23 -S -emit-llvm -O0 -o - %t.d/use.cc | %FileCheck %s --check-prefix=IR
// IR: define {{.*}}{ i64, i64 } @_Z4pass{{[A-Za-z0-9_]*}}(i64 %{{[^,]*}}, i64 %{{[^,)]*}})
// IR: declare {{.*}}i64 @{{[A-Za-z0-9_]*}}take{{[A-Za-z0-9_]*}}(i64, i64)
// IR: declare {{.*}}{ i64, i64 } @{{[A-Za-z0-9_]*}}make{{[A-Za-z0-9_]*}}(i64 noundef)
