/// --- The Kairo Project --------------------------- Linker/API/FS.k ------ ///
///
///   \brief The filesystem surface the linker API needs, over
///          llvm::sys::fs / llvm::sys::path. Every call takes and returns
///          Kairo strings; narrow conversion happens here and nowhere else.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/SmallString.h";
ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/ADT/Twine.h";
ffi "c++" import "llvm/Object/ArchiveWriter.h";
ffi "c++" import "llvm/Support/FileSystem.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";
ffi "c++" import "llvm/Support/Path.h";
ffi "c++" import "llvm/Support/Process.h";
ffi "c++" import "llvm/Support/Program.h";

class LinkFS {
    static fn exists(p: string) -> bool {
        return llvm::sys::fs::exists(llvm::Twine(sref(p)));
    }

    static fn is_dir(p: string) -> bool {
        return llvm::sys::fs::is_directory(llvm::Twine(sref(p)));
    }

    static fn is_file(p: string) -> bool {
        return llvm::sys::fs::is_regular_file(llvm::Twine(sref(p)));
    }

    /// Symlinks resolved; \p p unchanged if it cannot be.
    static fn real(p: string) -> string {
        var out: llvm::SmallString::<256>;
        var ec  = llvm::sys::fs::real_path(llvm::Twine(sref(p)), out, false);
        if ec { return p; }
        return string(out.data(), out.size());
    }

    static fn parent(p: string) -> string {
        var sr = llvm::sys::path::parent_path(sref(p));
        return string(sr.data(), sr.size());
    }

    static fn filename(p: string) -> string {
        var sr = llvm::sys::path::filename(sref(p));
        return string(sr.data(), sr.size());
    }

    /// Entry NAMES directly in \p dir, unsorted. Empty if unreadable.
    static fn list_dir(dir: string) -> vec::<string> {
        var out = vec::<string>();
        var ec: libcxx::error_code;
        var it  = llvm::sys::fs::directory_iterator(llvm::Twine(sref(dir)), ec, true);
        var end = llvm::sys::fs::directory_iterator();
        while (!ec) && (it != end) {
            var p = it->path();
            out.push_back(LinkFS::filename(string(p)));
            it.increment(ec);
        }
        return out;
    }

    static fn read(path: string, out: ref!(string)) -> bool {
        var mb = llvm::MemoryBuffer::getFile(llvm::Twine(sref(path)));
        if !mb { return false; }
        var sr = mb.get()->getBuffer();
        out = string(sr.data(), sr.size());
        return true;
    }

    static fn write(path: string, text: string) -> bool {
        var ec = llvm::sys::writeFileWithEncoding(
            sref(path), sref(text));
        return !ec;
    }

    /// Creates an empty temp file and returns its path; "" on failure.
    static fn temp_file(prefix: string, suffix: string) -> string {
        var out: llvm::SmallString::<256>;
        var ec  = llvm::sys::fs::createTemporaryFile(
            llvm::Twine(sref(prefix)), sref(suffix), out);
        if ec { return ""; }
        return string(out.data(), out.size());
    }

    /// Creates a unique directory under the system temp dir; "" on failure.
    static fn temp_dir(prefix: string) -> string {
        var base: llvm::SmallString::<256>;
        llvm::sys::path::system_temp_directory(true, base);
        llvm::sys::path::append(base, llvm::Twine(sref(prefix)));
        var out: llvm::SmallString::<256>;
        var ec  = llvm::sys::fs::createUniqueDirectory(llvm::Twine(base), out);
        if ec { return ""; }
        return string(out.data(), out.size());
    }

    /// Last modification, in the filesystem clock's ticks; 0 if \p p cannot
    /// be stat'd. Only ever compared for equality.
    static fn mtime(p: string) -> u64 {
        var st: llvm::sys::fs::file_status;
        var ec = llvm::sys::fs::status(llvm::Twine(sref(p)), st, true);
        if ec { return 0; }
        return static_cast::<u64>(st.getLastModificationTime().time_since_epoch().count());
    }

    /// Atomic on one filesystem; false if \p to exists as a non-empty
    /// directory or the move fails.
    static fn rename(from: string, to: string) -> bool {
        var ec = llvm::sys::fs::rename(llvm::Twine(sref(from)), llvm::Twine(sref(to)));
        return !ec;
    }

    /// A GNU archive of \p objects, with a symbol table, written to \p path:
    /// for a linker that has no --start-lib (the MinGW driver) to take
    /// objects lazily. Members keep their basenames; two of one name are
    /// fine to a linker, which reads the symbol table.
    static fn write_archive(path: string, objects: ref!(vec::<string>)) -> bool {
        var members: libcxx::vector::<llvm::NewArchiveMember>;
        for o: string in objects {
            var m = llvm::NewArchiveMember::getFile(sref(o), true);
            if !m {
                llvm::consumeError(m.takeError());
                return false;
            }
            members.push_back(libcxx::move(*m));
        }
        var err = llvm::writeArchive(sref(path), members, llvm::SymtabWritingMode::NormalSymtab,
                                     llvm::object::Archive::K_GNU, true, false);
        if err {
            llvm::consumeError(libcxx::move(err));
            return false;
        }
        return true;
    }

    static fn make_dirs(p: string) -> bool {
        var ec = llvm::sys::fs::create_directories(llvm::Twine(sref(p)), true);
        return !ec;
    }

    static fn remove(p: string) {
        llvm::sys::fs::remove(llvm::Twine(sref(p)), true);
    }

    static fn remove_tree(p: string) {
        if p.empty() { return; }
        llvm::sys::fs::remove_directories(llvm::Twine(sref(p)), true);
    }

    /// The environment variable \p name; "" when unset.
    static fn env(name: string) -> string {
        var v  = llvm::sys::Process::GetEnv(sref(name));
        if !v { return ""; }
        return string(v.value());
    }
}