/// --- The Kairo Project -------------------------- Native/KObjCache.hh --- ///
///
///   The byte-level pieces of the incremental object cache
///   (Compiler/Spec/Incremental.md) that Kairo has no spelling for:
///
///     objcache_hash128    xxh3-128 of a byte range, as 32 hex digits. The
///                         object key is content addressing: a 64-bit hash
///                         is a birthday away from a false hit, which is a
///                         miscompile, so keys are 128-bit.
///     objcache_file_hash  the same over a file's bytes ("" when unreadable).
///     objcache_record     the cache record section of an object file
///                         (`.kairo.cache` / `__KAIRO,__cache` / `.kcache`),
///                         or "" for a file that is not an object or has none.
///     objcache_clang_version  clang's full version, the fork revision
///                         included when the build recorded it.
///
///   WHY C++: llvm::object's section iteration is a range of value types
///   with Expected<> accessors, and XXH128_hash_t is a two-word struct;
///   both are a few lines here and a page of FFI plumbing in Kairo.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KOBJCACHE_HH__
#define __KAIRO_NATIVE_KOBJCACHE_HH__

#include <cstddef>
#include <cstdint>
#include <string>

#include "clang/Basic/Version.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/xxhash.h"

namespace kairo {

inline ::std::string objcache_hex128(const llvm::XXH128_hash_t &h) {
    static const char digits[] = "0123456789abcdef";
    ::std::string out(32, '0');
    for (int i = 0; i < 16; ++i) {
        out[15 - i] = digits[(h.high64 >> (4 * i)) & 0xf];
        out[31 - i] = digits[(h.low64 >> (4 * i)) & 0xf];
    }
    return out;
}

inline ::std::string objcache_hash128_bytes(const void *p, ::std::size_t n) {
    return objcache_hex128(llvm::xxh3_128bits(
        llvm::ArrayRef<uint8_t>(static_cast<const uint8_t *>(p), n)));
}

inline ::std::string objcache_hash128(llvm::StringRef s) {
    return objcache_hash128_bytes(s.data(), s.size());
}

inline ::std::string objcache_file_hash(llvm::StringRef path) {
    auto buf = llvm::MemoryBuffer::getFile(path, /*IsText=*/false,
                                           /*RequiresNullTerminator=*/false);
    if (!buf) return "";
    return objcache_hash128_bytes((*buf)->getBufferStart(), (*buf)->getBufferSize());
}

inline ::std::string objcache_record(llvm::StringRef path) {
    auto buf = llvm::MemoryBuffer::getFile(path, /*IsText=*/false,
                                           /*RequiresNullTerminator=*/false);
    if (!buf) return "";
    auto obj = llvm::object::ObjectFile::createObjectFile((*buf)->getMemBufferRef());
    if (!obj) {
        llvm::consumeError(obj.takeError());
        return "";
    }
    for (const llvm::object::SectionRef &s : (*obj)->sections()) {
        auto name = s.getName();
        if (!name) {
            llvm::consumeError(name.takeError());
            continue;
        }
        if (*name != ".kairo.cache" && *name != "__cache" && *name != ".kcache") continue;
        auto data = s.getContents();
        if (!data) {
            llvm::consumeError(data.takeError());
            return "";
        }
        return data->str();
    }
    return "";
}

inline ::std::string objcache_clang_version() { return clang::getClangFullVersion(); }

} // namespace kairo

#endif // __KAIRO_NATIVE_KOBJCACHE_HH__
