/// --- The Kairo Project ------------------------ Native/LlvmCompat.hh --- ///
///
///   The LLVM APIs whose spelling differs between the LLVM releases the tree
///   builds against (22.1 and 23.1).
///
///   WHY C++: Kairo resolves and types both branches of a function-body
///   `eval if` that does not fold, so a member that exists in only one
///   release cannot be named from Kairo behind a version test. The
///   preprocessor can, so the difference lives here and the Kairo code calls
///   one spelling. Native/ClangCompat.hh is the same for clang.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_LLVMCOMPAT_HH__
#define __KAIRO_NATIVE_LLVMCOMPAT_HH__

#include <llvm/Config/llvm-config.h>
#include <llvm/MC/MCSubtargetInfo.h>
#include <llvm/Target/TargetMachine.h>

namespace kairo::llvm_compat {

/// The machine's subtarget info. Never null from 23, where the accessor
/// returns a reference.
inline const llvm::MCSubtargetInfo *subtarget_info(const llvm::TargetMachine *tm) noexcept {
#if LLVM_VERSION_MAJOR >= 23
    return &tm->getMCSubtargetInfo();
#else
    return tm->getMCSubtargetInfo();
#endif
}

// From 23 the key and description are offsets into a string table read
// through key() / desc(), and the rows are not copyable: callers take them
// by address.

inline const char *cpu_key(const llvm::SubtargetSubTypeKV *kv) noexcept {
#if LLVM_VERSION_MAJOR >= 23
    return kv->key();
#else
    return kv->Key;
#endif
}

inline const char *feature_key(const llvm::SubtargetFeatureKV *kv) noexcept {
#if LLVM_VERSION_MAJOR >= 23
    return kv->key();
#else
    return kv->Key;
#endif
}

inline const char *feature_desc(const llvm::SubtargetFeatureKV *kv) noexcept {
#if LLVM_VERSION_MAJOR >= 23
    return kv->desc();
#else
    return kv->Desc;
#endif
}

} // namespace kairo::llvm_compat

#endif // __KAIRO_NATIVE_LLVMCOMPAT_HH__
