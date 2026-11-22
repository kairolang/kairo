// windows.k for the Microsoft C++ ABI: `trivial_abi` is not written, the
// record is relocatable by its member alias alone, and a function that
// takes any value with a destructor is not `const`, since the callee
// destroys every by-value parameter there.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-x86_64-windows-msvc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %S/windows.k --emit=llvm-ir -O1 --target=x86_64-windows-msvc --cache-dir %t.d/ir 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/windows.ll
// RUN: %kairo %S/windows.k --print-ir --target=x86_64-windows-msvc | %FileCheck %s --check-prefix=CXX
// CXX-NOT: trivial_abi
// CXX:     class Handle {
// CXX-NEXT: public: using __kairo_relocatable = Handle;
// CXX-NOT: trivial_abi
// CXX: __attribute((noinline)) __attribute((pure)) decltype(sizeof(0)) peek_owned(
// CXX: __attribute((noinline)) decltype(sizeof(0)) take_plain(

// QUIET-NOT: error [
// QUIET-NOT: warning [

// IR-DAG: define {{.*}}void @{{.*}}make_plain{{.*}}(ptr {{.*}}sret({{.*}}Handle{{.*}}) {{.*}}, i64 noundef %{{[^,)]*}})
// IR-DAG: define {{.*}}void @{{.*}}make_nested{{.*}}(ptr {{.*}}sret({{.*}}Outer{{.*}}) {{.*}}, i64 noundef %{{[^,)]*}})
// IR: define {{.*}}i1 @{{.*}}relocatable_plain{{.*}}()
// IR: ret i1 true
// IR: define {{.*}}i1 @{{.*}}relocatable_generic{{.*}}()
// IR: ret i1 true
// IR: define {{.*}}i1 @{{.*}}relocatable_nested{{.*}}()
// IR: ret i1 true
// IR: define {{.*}}i1 @{{.*}}relocatable_owned{{.*}}()
// IR: ret i1 false
