/// --- The Kairo Project ------------------------------ Native/Types.k --- ///
///
///   The parts of the Native base layer that are ordinary code. The rest of
///   it (the template aliases over the C++ library, the allocation and
///   string-conversion templates, SmallFunction, StackBuf, the ICE entry
///   points with their caller's source_location) is in Native/Types.hh, the
///   header every remaining C++ part of Native includes.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import std::c_char

/// The thread model the compiler was built for, as `--version` prints it.
pub fn thread_model_cstr() -> unsafe *const c_char {
    eval if defined!(_WIN32) {
        return "win32".c_str()
    } else if defined!(__wasm32__) || defined!(__wasm64__) {
        return "single".c_str()
    } else {
        return "posix".c_str()
    }
}
