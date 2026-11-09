/// --- The Kairo Project --------------------------------- Driver/kld.k --- ///
///
///   kld, the Kairo linker driver: a thin dispatcher over LLD.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Faithful port of llvm-project/lld/tools/lld/lld.cpp non-test path.
///   lldMain() does argv[0]/-flavor dispatch internally, so kld just hands it
///   the full driver table and returns the code.
///

ffi "c++" import "llvm/Support/InitLLVM.h"
ffi "c++" import "lld/Common/Driver.h"
ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Include/kld_drivers.hh"
ffi "c++" import "Native/Types.hh"

import API::FS::LinkFS
import std::c_char

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    LinkFS::use_sibling_symbolizer()
    static init = llvm::InitLLVM(&argc, &argv)
    llvm::sys::Process::UseANSIEscapeCodes(true)

    var args = llvm::ArrayRef<kairo::std::ConstPtr<c_char>>(
        unsafe (argv as unsafe *kairo::std::ConstPtr<c_char>),
        argc as usize,
    )

    var r = lld::lldMain(args, &llvm::outs(), &llvm::errs(), kld_driver_list())

    return r.retCode
}
