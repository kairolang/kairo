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
ffi "c++" import "llvm/Support/FileSystem.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";
ffi "c++" import "llvm/Support/Path.h";
ffi "c++" import "llvm/Support/Process.h";
ffi "c++" import "llvm/Support/Program.h";

class LinkFS {
    static fn exists(p: string) -> bool {
        var np = std::string_to_nstring(p);
        return llvm::sys::fs::exists(llvm::Twine(np.raw()));
    }

    static fn is_dir(p: string) -> bool {
        var np = std::string_to_nstring(p);
        return llvm::sys::fs::is_directory(llvm::Twine(np.raw()));
    }

    static fn is_file(p: string) -> bool {
        var np = std::string_to_nstring(p);
        return llvm::sys::fs::is_regular_file(llvm::Twine(np.raw()));
    }

    /// Symlinks resolved; \p p unchanged if it cannot be.
    static fn real(p: string) -> string {
        var np  = std::string_to_nstring(p);
        var out: llvm::SmallString::<256>;
        var ec  = llvm::sys::fs::real_path(llvm::Twine(np.raw()), out, false);
        if ec { return p; }
        return string(out.data(), out.size());
    }

    static fn parent(p: string) -> string {
        var np = std::string_to_nstring(p);
        var sr = llvm::sys::path::parent_path(llvm::StringRef(np.raw(), np.size()));
        return string(sr.data(), sr.size());
    }

    static fn filename(p: string) -> string {
        var np = std::string_to_nstring(p);
        var sr = llvm::sys::path::filename(llvm::StringRef(np.raw(), np.size()));
        return string(sr.data(), sr.size());
    }

    /// Entry NAMES directly in \p dir, unsorted. Empty if unreadable.
    static fn list_dir(dir: string) -> vec::<string> {
        var out = vec::<string>();
        var nd  = std::string_to_nstring(dir);
        var ec: libcxx::error_code;
        var it  = llvm::sys::fs::directory_iterator(llvm::Twine(nd.raw()), ec, true);
        var end = llvm::sys::fs::directory_iterator();
        while (!ec) && (it != end) {
            var p = it->path();
            out.push_back(LinkFS::filename(std::nstring_to_string(p)));
            it.increment(ec);
        }
        return out;
    }

    static fn read(path: string, out: ref!(string)) -> bool {
        var np = std::string_to_nstring(path);
        var mb = llvm::MemoryBuffer::getFile(llvm::Twine(np.raw()));
        if !mb { return false; }
        var sr = mb.get()->getBuffer();
        out = string(sr.data(), sr.size());
        return true;
    }

    static fn write(path: string, text: string) -> bool {
        var np = std::string_to_nstring(path);
        var nt = std::string_to_nstring(text);
        var ec = llvm::sys::writeFileWithEncoding(
            llvm::StringRef(np.raw(), np.size()), llvm::StringRef(nt.raw(), nt.size()));
        return !ec;
    }

    /// Creates an empty temp file and returns its path; "" on failure.
    static fn temp_file(prefix: string, suffix: string) -> string {
        var np  = std::string_to_nstring(prefix);
        var ns  = std::string_to_nstring(suffix);
        var out: llvm::SmallString::<256>;
        var ec  = llvm::sys::fs::createTemporaryFile(
            llvm::Twine(np.raw()), llvm::StringRef(ns.raw(), ns.size()), out);
        if ec { return ""; }
        return string(out.data(), out.size());
    }

    /// Creates a unique directory under the system temp dir; "" on failure.
    static fn temp_dir(prefix: string) -> string {
        var base: llvm::SmallString::<256>;
        llvm::sys::path::system_temp_directory(true, base);
        var np = std::string_to_nstring(prefix);
        llvm::sys::path::append(base, llvm::Twine(np.raw()));
        var out: llvm::SmallString::<256>;
        var ec  = llvm::sys::fs::createUniqueDirectory(llvm::Twine(base), out);
        if ec { return ""; }
        return string(out.data(), out.size());
    }

    static fn make_dirs(p: string) -> bool {
        var np = std::string_to_nstring(p);
        var ec = llvm::sys::fs::create_directories(llvm::Twine(np.raw()), true);
        return !ec;
    }

    static fn remove(p: string) {
        var np = std::string_to_nstring(p);
        llvm::sys::fs::remove(llvm::Twine(np.raw()), true);
    }

    static fn remove_tree(p: string) {
        if p.empty() { return; }
        var np = std::string_to_nstring(p);
        llvm::sys::fs::remove_directories(llvm::Twine(np.raw()), true);
    }

    /// The environment variable \p name; "" when unset.
    static fn env(name: string) -> string {
        var nn = std::string_to_nstring(name);
        var v  = llvm::sys::Process::GetEnv(llvm::StringRef(nn.raw(), nn.size()));
        if !v { return ""; }
        return std::nstring_to_string(v.value());
    }
}