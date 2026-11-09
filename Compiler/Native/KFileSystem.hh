/// --- The Kairo Project ------------------------ Native/KFileSystem.hh --- ///
///
///   Accessors on LLVM filesystem types whose member names are Kairo
///   keywords.
///
///   WHY C++: llvm::sys::fs::directory_entry::type() cannot be called from
///   Kairo, `type` is a keyword. It used to be an inline C++ member call;
///   Stage 1 does not emit inline foreign code.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KFILESYSTEM_HH__
#define __KAIRO_NATIVE_KFILESYSTEM_HH__

#include <llvm/Support/FileSystem.h>

namespace kairo {

/// The entry's type as the readdir record reported it (d_type), with no
/// stat. type_unknown where the OS did not say.
inline ::llvm::sys::fs::file_type dir_entry_type(const ::llvm::sys::fs::directory_entry &e) {
    return e.type();
}

}  // namespace kairo

#endif  // __KAIRO_NATIVE_KFILESYSTEM_HH__
