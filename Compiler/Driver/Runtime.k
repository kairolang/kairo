/// --- The Kairo Project ----------------------------- Driver/Runtime.k --- ///
///
///   init_runtime: process startup shared by the kairo and kcc entry points
///   (LLVM targets, crash message, locale).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/KLocale.hh" // init_process_locale
ffi "c++" import "llvm/Support/InitLLVM.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "locale"
ffi "c++" import "sstream"

import API::FS::LinkFS
import std::c_char

/// \return the InitLLVM guard; main destroys it before returning.
///
/// \details Not a function-local static: its destructor runs llvm_shutdown,
///          and as a static, built first, it was destroyed LAST -- after the
///          parallel executor lld's parallelFor creates on first use, a static
///          built later and so destroyed earlier. llvm_shutdown then stopped
///          that dead executor and locked its freed mutex: an intermittent
///          crash at exit, on the runs that linked.
pub fn init_runtime(argc: i32, argv: unsafe *(unsafe *c_char)) -> unsafe *llvm::InitLLVM {
    LinkFS::use_sibling_symbolizer()
    var unsafe *init_llvm = kairo::std::create<llvm::InitLLVM>(argc, argv)
    llvm::InitializeAllTargetInfos()
    llvm::InitializeAllTargets()
    llvm::InitializeAllTargetMCs()
    llvm::InitializeAllAsmParsers()
    llvm::InitializeAllAsmPrinters()

    llvm::setBugReportMsg(
        "PLEASE submit a bug report to https://github.com/kairolang/kairo/issues and include the crash backtrace.\n",
    )

    // Locale from the environment, LC_CTYPE forced to UTF-8 if that did not
    // give one (Native/KLocale.hh says why), eagerly on the main thread
    // before any worker starts.
    kairo::init_process_locale()

    cxx::std::use_facet<cxx::std::num_put<c_char>>(cxx::std::locale())
    cxx::std::use_facet<cxx::std::num_get<c_char>>(cxx::std::locale())

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: cxx::std::ostringstream
        // i32 and f32, not usize and f64: on arm64 Darwin size_t (unsigned long) and
        // uint64_t (unsigned long long) are distinct, and so are double and long double
        // (both 64-bit there), and ffi maps each pair to one Kairo type, so usize and f64
        // each matched two operator<< (SC064E). The facets are the same either way.
        oss << (1 as i32) << (1.0 as f32)
        oss.str()
    }

    eval if defined!(__linux__) {
        var attr: pthread_attr_t
        pthread_attr_init(unsafe &attr)
        pthread_attr_setstacksize(unsafe &attr, (64 * 1024 * 1024) as usize)
        // pthread_setattr_default_np(&attr);
        pthread_attr_destroy(unsafe &attr)
    }

    return init_llvm
}
