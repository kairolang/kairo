/// --- The Kairo Project ------------------------ Linker/Driver/kld.k ----- ///
///
///   kld, Kairo linker driver. Thin dispatcher over LLD.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Faithful port of llvm-project/lld/tools/lld/lld.cpp non-test path.
///   lldMain() does argv[0]/-flavor dispatch internally, so kld just hands it
///   the full driver table and returns the code.
///

ffi "c++" import "llvm/Support/InitLLVM.h";
ffi "c++" import "lld/Common/Driver.h";
ffi "c++" import "llvm/ADT/ArrayRef.h";
ffi "c++" import "llvm/Support/Process.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "Include/kld_drivers.hh";

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    static var init = llvm::InitLLVM(argc, argv);
    llvm::sys::Process::UseANSIEscapeCodes(true);

    var args = llvm::ArrayRef::<*kairo::std::Legacy::char>(argv, argv + argc);
    var r = lld::lldMain(args, llvm::outs(), llvm::errs(), kld_drivers);
    
    return r.retCode;
}