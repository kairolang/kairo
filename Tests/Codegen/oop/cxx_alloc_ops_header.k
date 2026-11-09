// The class-scope C++ allocation operators (Compiler/Spec/Codegen.md#c-allocation-operators)
// are C++-facing text only: the --emit-headers header and the kcc
// `#include "x.k"` stream give each record them, routed to the program's
// global allocator (kairo_global_alloc / kairo_global_free), always: a class
// cannot have its own `op new` / `op delete` (SC149E, 2026-11-08); the module's own
// object (--print-ir) has none of them, only the placement form an ADT
// payload always carried.
import builtin::base::alloc::*

pub class Point {
    var x: i32
    pub fn Point(self, x: i32) { self.x = x }
}

pub class <T> Box {
    var v: T
}

pub enum Shape { Circle { r: i32 }, Dot }

pub class Node {
    var x: i32
}

pub fn use_box(b: *Box<i32>) -> i32 { return b->v }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: tr -d '[:space:]' < %t.d/h/cxx_alloc_ops_header.hh | %FileCheck %s --check-prefix=CXX
// RUN: echo '#include "%s"' > %t.d/host.cpp
// RUN: %kcc -E %t.d/host.cpp -o %t.d/host.ii
// RUN: tr -d '[:space:]' < %t.d/host.ii | %FileCheck %s --check-prefix=CXX
// RUN: %kairo %s -c -o %t.d/own.o --cache-dir %t.d/c --print-ir 2>/dev/null > %t.d/own.ir
// RUN: %FileCheck %s --check-prefix=OWN < %t.d/own.ir
//
// The helpers, once, ahead of every record.
// CXX: namespacestd{enumclassalign_val_t:decltype(sizeof(0));structnothrow_t;}
// CXX: extern"C"unsignedchar*kairo_global_alloc(decltype(sizeof(0))size,decltype(sizeof(0))align)noexcept;
// CXX: extern"C"voidkairo_global_free(unsignedchar*ptr,decltype(sizeof(0))size,decltype(sizeof(0))align)noexcept;
// CXX: extern"C"__attribute__((noreturn))voidkairo_rt_crash_exit(
// CXX: inlinevoid*__kairo_cxx_got(unsignedchar*p,boolnothrow)noexcept{
//
// A class: public, then back to the class default.
// CXX: classPoint{public:__attribute__((exclude_from_explicit_instantiation))staticvoid*operatornew(decltype(sizeof(0))n){return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,alignof(Point)),false);}
// CXX-SAME: staticvoid*operatornew(decltype(sizeof(0))n,::std::align_val_ta){return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,static_cast<decltype(sizeof(0))>(a)),false);}
// CXX-SAME: staticvoid*operatornew(decltype(sizeof(0))n,const::std::nothrow_t&)noexcept{return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,alignof(Point)),true);}
// CXX-SAME: staticvoid*operatornew(decltype(sizeof(0)),void*p)noexcept{returnp;}
// CXX-SAME: staticvoid*operatornew[](decltype(sizeof(0))n){return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,(alignof(Point)>2*sizeof(void*)?alignof(Point):2*sizeof(void*))),false);}
// CXX-SAME: staticvoidoperatordelete(void*p,decltype(sizeof(0))n)noexcept{if(p)::kairo_global_free(static_cast<unsignedchar*>(p),n?n:1,alignof(Point));}
// CXX-SAME: staticvoidoperatordelete(void*p,decltype(sizeof(0))n,::std::align_val_ta)noexcept{if(p)::kairo_global_free(static_cast<unsignedchar*>(p),n?n:1,static_cast<decltype(sizeof(0))>(a));}
// CXX-SAME: staticvoidoperatordelete[](void*p,decltype(sizeof(0))n)noexcept{
// CXX-SAME: private:signedintx
//
// A generic class: the same, over the injected name.
// CXX: template<classT>classBox{public:__attribute__((exclude_from_explicit_instantiation))staticvoid*operatornew(decltype(sizeof(0))n){return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,alignof(Box)),false);}
//
// An ADT enum.
// CXX: structShape{
// CXX: staticvoid*operatornew(decltype(sizeof(0))n){return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,alignof(Shape)),false);}
//
// Another class: the global pair too (there is no per-class allocator).
// CXX: classNode{public:__attribute__((exclude_from_explicit_instantiation))staticvoid*operatornew(decltype(sizeof(0))n){return::__kairo_cxx_got(::kairo_global_alloc(n?n:1,alignof(Node)),false);}
// CXX-SAME: staticvoidoperatordelete(void*p,decltype(sizeof(0))n)noexcept{if(p)::kairo_global_free(static_cast<unsignedchar*>(p),n?n:1,alignof(Node));}
//
// The module's own object: none of it.
// OWN: CODEGEN C++: {{.*}}cxx_alloc_ops_header.k
// OWN-NOT: kairo_global_alloc
// OWN-NOT: __kairo_cxx_got
// OWN-NOT: align_val_t
// OWN: class Point {
// OWN-NOT: operator new
// OWN: };
