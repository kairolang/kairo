// An ADT enum's C++ factories (Compiler/Spec/Interop.md#constructing-adt-
// variants-from-c) are C++-facing text only: the module's header
// (`--emit-headers`) writes one `static E V(fields...)` per variant, named
// exactly after it, with the field constructor's parameters; the module's
// own object never does (nothing Kairo calls them). The C++ side that runs
// them is CLI/Kcc/kcc_adt_factories.k.
//
// Each is a member template over a defaulted dummy (`__kairo_mk`): a plain
// member of an `extern template` instance would only be referenced from
// the C++ TU, and the module's explicit instantiation does not have it.

pub enum <T> Frame {
    Burst { base: T, count: i32 },
    Idle,
}

// Fields form: trivially moved fields, the field constructor directly.
pub enum Pt { At { x: i32, y: i32 }, Origin }

// Lambda form: a non-generic payload is spelled through the dummy, so a
// payload that cannot move does not break the header.
pub enum Res { Err { msg: string, code: i32 }, Nothing }

pub fn burst_of(f: Frame<i32>) -> i32 = match f {
    case .Burst(var base, var count) => base + count
    case .Idle                       => 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: tr -d '[:space:]' < %t.d/h/adt_factories_header.hh | %FileCheck %s --check-prefix=HDR
// HDR: template<classT>structFrame{
// HDR: template<class__kairo_mk=void>staticFrameBurst(Tbase,signedintcount)noexcept{returnFrame(::__kairo_vt<0>{},[&]()noexcept->__kairo_Burst_t{return{static_cast<T&&>(base),count};});}
// HDR: template<class__kairo_mk=void>staticFrameIdle()noexcept{returnFrame(::__kairo_vt<1>{});}
// HDR: structPt{
// HDR: template<class__kairo_mk=void>staticPtAt(signedintx,signedinty)noexcept{returnPt(::__kairo_vt<0>{},x,y);}
// HDR: template<class__kairo_mk=void>staticPtOrigin()noexcept{returnPt(::__kairo_vt<1>{});}
// HDR: structRes{
// HDR: template<class__kairo_mk=void>staticResErr(::builtin::string::stringmsg,signedintcode)noexcept{returnRes(::__kairo_vt<0>{},[&]()noexcept->__type_pack_element<0,__kairo_Err_t,__kairo_mk>{return{static_cast<::builtin::string::string&&>(msg),code};});}
// HDR: template<class__kairo_mk=void>staticResNothing()noexcept{returnRes(::__kairo_vt<1>{});}
//
// RUN: %kairo %s -c -o %t.d/own.o --cache-dir %t.d/c --print-ir 2>/dev/null > %t.d/own.ir
// RUN: %FileCheck %s --check-prefix=OWN < %t.d/own.ir
// OWN: struct Frame
// OWN-NOT: __kairo_mk
// OWN: burst_of
