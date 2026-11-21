/// --- The Kairo Project ---------------------------- Native/ObjCache.k --- ///
///
///   The object cache's hashes and its record section: XXH3-128 of a byte
///   range, a string or a file, as 32 hex digits, and the cache record a
///   cached object carries in its `.kairo.cache` (ELF), `__cache` (Mach-O)
///   or `.kcache` (COFF) section.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // sref
ffi "c++" import "clang/Basic/Version.h"
ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Object/ObjectFile.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/xxhash.h"
ffi "c++" import "string"

import std::c_char

eval HEX_DIGITS: [u8; 16] = [
    '0' as u8, '1' as u8, '2' as u8, '3' as u8, '4' as u8, '5' as u8, '6' as u8, '7' as u8,
    '8' as u8, '9' as u8, 'a' as u8, 'b' as u8, 'c' as u8, 'd' as u8, 'e' as u8, 'f' as u8,
]

pub fn objcache_hex128(const h: llvm::XXH128_hash_t) -> cxx::std::string {
    var out = cxx::std::string(32 as usize, ('0' as u8) as c_char)
    for var i: u32 = 0; i < 16; ++i {
        out[15 - i] = HEX_DIGITS[(h.high64 >> (4 * i)) & 0xf] as c_char
        out[31 - i] = HEX_DIGITS[(h.low64 >> (4 * i)) & 0xf] as c_char
    }

    return out
}

pub fn objcache_hash128_bytes(p: unsafe *const void, n: usize) -> cxx::std::string {
    return objcache_hex128(
        llvm::xxh3_128bits(
            llvm::ArrayRef<u8>(unsafe (p as unsafe *const u8), n),
        ),
    )
}

pub fn objcache_hash128(s: llvm::StringRef) -> cxx::std::string {
    return objcache_hash128_bytes(s.data(), s.size())
}

pub fn objcache_file_hash(path: llvm::StringRef) -> cxx::std::string {
    var buf = llvm::MemoryBuffer::getFile(llvm::Twine(path), false, false) // IsText, RequiresNullTerminator
    if buf.getError().value() != 0 {
        return cxx::std::string()
    }

    return objcache_hash128_bytes(
        buf.get()->getBufferStart(),
        buf.get()->getBufferSize(),
    )
}

pub fn objcache_record(path: llvm::StringRef) -> cxx::std::string {
    var buf = llvm::MemoryBuffer::getFile(llvm::Twine(path), false, false) // IsText, RequiresNullTerminator
    if buf.getError().value() != 0 {
        return cxx::std::string()
    }

    var obj = llvm::object::ObjectFile::createObjectFile(
        buf.get()->getMemBufferRef(),
    )

    if !(obj as bool) {
        llvm::consumeError(obj.takeError())
        return cxx::std::string()
    }

    for s in obj.get()->sections() {
        var name = s.getName()
        if !(name as bool) {
            llvm::consumeError(name.takeError())
            continue
        }

        if name.get() != kairo::sref(".kairo.cache")
            && name.get() != kairo::sref("__cache")
            && name.get() != kairo::sref(".kcache") {
            continue
        }

        var data = s.getContents()
        if !(data as bool) {
            llvm::consumeError(data.takeError())
            return cxx::std::string()
        }

        return data.get().str()
    }

    return cxx::std::string()
}

pub fn objcache_clang_version() -> cxx::std::string {
    return clang::getClangFullVersion()
}
