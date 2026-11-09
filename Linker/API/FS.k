/// --- The Kairo Project ------------------------------------- API/FS.k --- ///
///
///   LinkFS: the filesystem calls the linker API needs, over LLVM.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Object/ArchiveWriter.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh" // write_file_exact
ffi "c++" import "Native/Win32.hh" // move_path (Windows directory renames)
ffi "c++" import "cstdlib"
ffi "c++" import "vector"
ffi "c++" import "system_error"
ffi "c++" import "utility"

import std::c_char
import std::env

pub class LinkFS {
    pub static fn exists(const p: string) -> bool {
        return llvm::sys::fs::exists(llvm::Twine(kairo::sref(p)))
    }

    pub static fn is_dir(const p: string) -> bool {
        return llvm::sys::fs::is_directory(llvm::Twine(kairo::sref(p)))
    }

    pub static fn is_file(const p: string) -> bool {
        return llvm::sys::fs::is_regular_file(llvm::Twine(kairo::sref(p)))
    }

    /// Symlinks resolved; \p p unchanged if it cannot be.
    pub static fn real(p: string) -> string {
        var out: llvm::SmallString<256>
        var ec = llvm::sys::fs::real_path(llvm::Twine(kairo::sref(p)), &out, false)
        if ec.value() != 0 {
            return p
        }

        return string(unsafe ((out.data() as unsafe *const u8) as *const u8), out.size())
    }

    pub static fn parent(const p: string) -> string {
        var sr = llvm::sys::path::parent_path(kairo::sref(p))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    pub static fn filename(const p: string) -> string {
        var sr = llvm::sys::path::filename(kairo::sref(p))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    /// Entry NAMES directly in \p dir, unsorted. Empty if unreadable.
    pub static fn list_dir(const dir: string) -> cxx::std::vector<string> {
        var out                      = cxx::std::vector<string>()
        var ec: cxx::std::error_code
        var it  = llvm::sys::fs::directory_iterator(llvm::Twine(kairo::sref(dir)), &ec, true)
        var end = llvm::sys::fs::directory_iterator()
        while ec.value() == 0 && it != end {
            var p = it->path()
            out.push_back(
                LinkFS::filename(
                    string(unsafe ((p.data() as unsafe *const u8) as *const u8), p.size()),
                ),
            )

            it.increment(&ec)
        }

        return out
    }

    pub static fn read(const path: string, @inout out: string) -> bool {
        var mb = llvm::MemoryBuffer::getFile(llvm::Twine(kairo::sref(path)))
        if mb.getError().value() != 0 {
            return false
        }

        var sr = mb.get()->getBuffer()
        out = string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
        return true
    }

    pub static fn write(const path: string, const text: string) -> bool {
        // Exact bytes (KShims write_file_exact): writeFileWithEncoding's text
        // mode turned '\n' into "\r\n" on Windows, and read() returns bytes.
        return kairo::write_file_exact(kairo::sref(path), kairo::sref(text))
    }

    /// Creates an empty temp file and returns its path; "" on failure.
    static fn temp_file(const prefix: string, const suffix: string) -> string {
        var out: llvm::SmallString<256>
        var ec = llvm::sys::fs::createTemporaryFile(
            llvm::Twine(kairo::sref(prefix)),
            kairo::sref(suffix),
            &out,
        )

        if ec.value() != 0 {
            return ""
        }

        return string(unsafe ((out.data() as unsafe *const u8) as *const u8), out.size())
    }

    /// Creates a unique directory under the system temp dir; "" on failure.
    pub static fn temp_dir(const prefix: string) -> string {
        var base: llvm::SmallString<256>
        llvm::sys::path::system_temp_directory(true, &base)
        llvm::sys::path::append(&base, llvm::Twine(kairo::sref(prefix)))
        var out: llvm::SmallString<256>
        var ec = llvm::sys::fs::createUniqueDirectory(llvm::Twine(base), &out)
        if ec.value() != 0 {
            return ""
        }

        return string(unsafe ((out.data() as unsafe *const u8) as *const u8), out.size())
    }

    /// Last modification, in the filesystem clock's ticks; 0 if \p p cannot
    /// be stat'd. Only ever compared for equality.
    pub static fn mtime(const p: string) -> u64 {
        var st: llvm::sys::fs::file_status
        var ec = llvm::sys::fs::status(llvm::Twine(kairo::sref(p)), &st, true)
        if ec.value() != 0 {
            return 0
        }

        return st.getLastModificationTime().time_since_epoch().count() as u64
    }

    /// Atomic on one filesystem; false if \p to exists as a non-empty
    /// directory or the move fails.
    pub static fn rename(const from: string, const to: string) -> bool {
        var ec = llvm::sys::fs::rename(llvm::Twine(kairo::sref(from)), llvm::Twine(kairo::sref(to)))
        if ec.value() == 0 {
            return true
        }

        // llvm's Windows rename opens the source as a FILE, so a directory never
        // moves (the Kairo library cache's tmp -> final publish failed on every
        // Windows run); MoveFileExW moves either.
        eval if defined!(_WIN32) {
            return kairo::win32::move_path(
                unsafe ((from.raw() as unsafe *const u8) as unsafe *const c_char),
                from.size(),
                unsafe ((to.raw() as unsafe *const u8) as unsafe *const c_char),
                to.size(),
            )
        }

        return false
    }

    /// A GNU archive of \p objects, with a symbol table, written to \p path:
    /// for a linker that has no --start-lib (the MinGW driver) to take
    /// objects lazily. Members keep their basenames; two of one name are
    /// fine to a linker, which reads the symbol table.
    pub static fn write_archive(const path:     string,
                                @inout objects: cxx::std::vector<string>) -> bool {
        var members: cxx::std::vector<llvm::NewArchiveMember>
        for var o: string in objects {
            var m = llvm::NewArchiveMember::getFile(kairo::sref(o), true)
            if !(m as bool) {
                llvm::consumeError(m.takeError())
                return false
            }

            members.push_back(cxx::std::move(*m))
        }

        var err = llvm::writeArchive(
            kairo::sref(path),
            llvm::ArrayRef<llvm::NewArchiveMember>(members),
            llvm::SymtabWritingMode::NormalSymtab,
            llvm::object::Archive::K_GNU,
            true,
            false,
        )

        if (err as bool) {
            llvm::consumeError(cxx::std::move(err))
            return false
        }

        return true
    }

    pub static fn make_dirs(const p: string) -> bool {
        var ec = llvm::sys::fs::create_directories(llvm::Twine(kairo::sref(p)), true)
        return ec.value() == 0
    }

    pub static fn remove(const p: string) {
        llvm::sys::fs::remove(llvm::Twine(kairo::sref(p)), true)
    }

    /// Copies the tree \p from into \p to (created): files and subdirectories.
    pub static fn copy_tree(const from: string, const to: string) -> bool {
        if !LinkFS::make_dirs(to) {
            return false
        }

        for var name: string in LinkFS::list_dir(from) {
            var s = from + "/" + name
            var d = to + "/" + name
            if LinkFS::is_dir(s) {
                if !LinkFS::copy_tree(s, d) {
                    return false
                }

                continue
            }

            var ec = llvm::sys::fs::copy_file(
                llvm::Twine(kairo::sref(s)),
                llvm::Twine(kairo::sref(d)),
            )

            if ec.value() != 0 {
                return false
            }
        }

        return true
    }

    pub static fn remove_tree(const p: string) {
        if p.empty() {
            return
        }

        llvm::sys::fs::remove_directories(llvm::Twine(kairo::sref(p)), true)
    }

    /// The environment variable \p name; "" when unset.
    pub static fn env(const name: string) -> string {
        var v = llvm::sys::Process::GetEnv(kairo::sref(name))
        if !v.has_value() {
            return ""
        }

        return string(unsafe ((v.value().c_str() as unsafe *const u8) as *const u8))
    }

    /// Sets \p name to \p value, overwriting. Portable: Windows has no
    /// setenv, and its _putenv_s is the CRT's copy of the environment that
    /// llvm::sys::Process::GetEnv reads back.
    pub static fn set_env(const name: string, const value: string) {
        eval if defined!(_WIN32) {
            _putenv_s(name.c_str(), value.c_str())
        } else {
            setenv(name.c_str(), value.c_str(), 1)
        }
    }

    /// Points LLVM_SYMBOLIZER_PATH at the llvm-symbolizer beside the running
    /// executable, unless the user already set it. Must run before
    /// llvm::InitLLVM: that is when the crash handler reads the variable, and
    /// otherwise an installed tree that is not on PATH prints an
    /// unsymbolized backtrace.
    pub static fn use_sibling_symbolizer() {
        if !LinkFS::env("LLVM_SYMBOLIZER_PATH").empty() {
            return
        }

        var exe = env::exe_path()
        if exe.empty() {
            return
        }

        var sym = LinkFS::parent(exe) + "/llvm-symbolizer"
        eval if defined!(_WIN32) {
            sym = sym + ".exe"
        }

        if LinkFS::is_file(sym) {
            LinkFS::set_env("LLVM_SYMBOLIZER_PATH", sym)
        }
    }
}
