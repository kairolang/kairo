/// --- The Kairo Project ------------------------ Support/FileIO/Path.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


import Support::FileIO::FileSystem::*;

ffi "c++" import "Native/Types.hh";
ffi "c++" import "llvm/ADT/SmallString.h";
ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/ADT/Twine.h";
ffi "c++" import "llvm/ADT/iterator_range.h";
ffi "c++" import "llvm/Support/FileSystem.h";
ffi "c++" import "llvm/Support/Path.h";
ffi "c++" import "llvm/Support/raw_ostream.h";

///
/// \file Path.k
/// \brief high-level abstraction over llvm::sys::path / llvm::sys::fs.
///
/// \details
/// `Path` holds an absolute path as a plain UTF-8 string and answers every
/// query through LLVM's path library, the same one clang and the linker
/// API (Linker/API/FS.k) use. Sharing it is the point: a path Kairo
/// spells and a path clang spells for the same file come out of one
/// normaliser, so they compare equal as strings.
///
/// key behaviors:
///   - converts input into an absolute path on construction ('.' segments
///     dropped; '..' kept, since folding it lexically is wrong through a
///     symlink).
///   - performs validation unless `mustExist = false`.
///   - caches file type for faster attribute lookups.
///   - stores and returns the generic ('/'-separated) form on every host.
///
/// \note this class is designed as a thin wrapper and does not perform
/// any I/O beyond filesystem metadata queries.
///
/// \see FileSystem, VirtualFileManager, MappedFileBuffer
///

default class Path {
    pub var path_data:  string;   ///< absolute, generic-form path.
    pub var entry_type: FileType; ///< cached type of the path entry.

    ///
    /// \brief default constructor (creates empty path).
    ///
    default fn Path(self);

    ///
    /// \brief constructs and validates a new Path from string input.
    ///
    /// \param input raw path string (absolute or relative).
    /// \param mustExist if true, ensures the path exists on disk.
    ///
    /// \details
    /// - converts `input` into an absolute path against the process cwd.
    /// - crashes if the path is empty or non-existent when `mustExist` is true.
    ///
    /// \warning
    /// this constructor performs a system call to check existence.
    ///
    fn Path(self, input: string, mustExist: bool = false) {
        self.path_data = Path::_normalize(input);

        if self.path_data.empty() {
            std::crash(std::Error::RuntimeError("Path: empty path string"));
        }

        // Follows symlinks, as the libc++ status() this replaced did: a link
        // to a file reports regular_file, never symlink_file.
        self.entry_type = llvm::sys::fs::get_file_type(llvm::Twine(sref(self.path_data)), true);

        if mustExist && (!self._entry_exists()) {
            std::crash(std::Error::RuntimeError(
                f"Path: path does not exist: {self.path_data}"
            ));
        }
    }

    ///
    /// \brief a Path for \p abs whose type the caller already knows -- from
    ///        a readdir record or a probe's own stat. No syscall.
    ///
    /// \details \p abs must already be absolute and generic-form (a
    ///          Path::join off another Path is); it is stored as given.
    ///
    static fn from_known(abs: string, t: FileType) -> Path {
        var p = Path();
        p.path_data  = abs;
        p.entry_type = t;
        return p;
    }

    static fn cwd() -> Path {
        var buf: llvm::SmallString::<256>;
        llvm::sys::fs::current_path(buf);
        return Path(string(buf.data(), buf.size()));
    }

    static fn home() -> Path {
        var buf: llvm::SmallString::<256>;
        if !llvm::sys::path::home_directory(buf) {
            std::crash(std::Error::RuntimeError("Path::home: no home directory (HOME not set)"));
        }

        return Path(string(buf.data(), buf.size()));
    }

    static fn temp_dir() -> Path {
        var buf: llvm::SmallString::<256>;
        llvm::sys::path::system_temp_directory(true, buf);
        return Path(string(buf.data(), buf.size()));
    }

    static fn root() -> Path {
        return Path("/");
    }

    ///
    /// \brief \p p made absolute against \p base, IF it names something on
    ///        disk; otherwise \p p exactly as given.
    ///
    /// \details For option values (-I, --sysroot, --resource-dir, inputs):
    ///          resolving them once, up front, means nothing downstream
    ///          re-resolves a relative spelling against a different
    ///          directory (a PCH's, a chdir'd cwd). A path that does not exist
    ///          is left alone so the diagnostic that rejects it later quotes
    ///          what the user typed. No stat beyond the one existence check;
    ///          symlinks are NOT resolved.
    ///
    /// \param base directory a relative \p p is taken against; "" means the
    ///             process cwd.
    ///
    static fn absolute_if_exists(p: string, base: string = "") -> string {
        if p.empty() { return p; }

        var cand = p;
        if (!base.empty()) && (!llvm::sys::path::is_absolute(llvm::Twine(sref(p)))) {
            cand = Path::join_str(base, p);
        }

        if !Path::exists_at(cand) { return p; }
        return Path::_normalize(cand);
    }

    ///
    /// \brief \p rel appended to \p base, purely lexically (no stat).
    ///
    /// \details An absolute \p rel replaces \p base, matching
    ///          filesystem::path's operator/ that the callers were written
    ///          against; llvm's append() would glue the two together instead.
    ///
    static fn join_str(base: string, rel: string) -> string {
        if base.empty() || llvm::sys::path::is_absolute(llvm::Twine(sref(rel))) {
            return rel;
        }
        // posix style: Path stores the generic form on every host, and a
        // native append would splice a '\\' into it on Windows.
        var buf = llvm::SmallString::<256>(sref(base));
        llvm::sys::path::append(buf, llvm::sys::path::Style::posix, llvm::Twine(sref(rel)));
        return string(buf.data(), buf.size());
    }

    // --- string-level queries (no Path built, no stat) ---------------------
    //
    // For callers holding a plain path string: building a Path stats the
    // disk, and these only need the lexical answer.

    static fn parent_of(p: string) -> string {
        var sr = llvm::sys::path::parent_path(sref(p));
        return string(sr.data(), sr.size());
    }

    static fn filename_of(p: string) -> string {
        var sr = llvm::sys::path::filename(sref(p));
        return string(sr.data(), sr.size());
    }

    static fn stem_of(p: string) -> string {
        var sr = llvm::sys::path::stem(sref(p));
        return string(sr.data(), sr.size());
    }

    static fn extension_of(p: string) -> string {
        var sr = llvm::sys::path::extension(sref(p));
        return string(sr.data(), sr.size());
    }

    /// \p p with every symlink resolved, or \p p unchanged when it cannot
    ///        be (it does not exist). One syscall.
    ///
    /// \details For IDENTITY comparisons only -- "are these two spellings one
    ///          directory?" -- never for a path that is printed or stored:
    ///          what the user typed (a vendored symlink) is what a diagnostic
    ///          should quote.
    static fn real_path_of(p: string) -> string {
        if p.empty() { return p; }
        var buf: llvm::SmallString::<256>;
        if llvm::sys::fs::real_path(llvm::Twine(sref(p)), buf, false) { return p; }
        var generic = llvm::sys::path::convert_to_slash(llvm::StringRef(buf.data(), buf.size()));
        return string(generic.data(), generic.size());
    }

    // --- filesystem mutations ----------------------------------------------

    /// \p dir and every missing parent. True when it exists afterwards.
    static fn make_dirs(dir: string) -> bool {
        if dir.empty() { return true; }
        return !llvm::sys::fs::create_directories(llvm::Twine(sref(dir)), true);
    }

    /// The directory \p file will be written into, created if missing.
    static fn make_parent_dirs(file: string) -> bool {
        return Path::make_dirs(Path::parent_of(file));
    }

    /// chdir. False (nothing changed) when \p dir cannot be entered.
    static fn set_cwd(dir: string) -> bool {
        return !llvm::sys::fs::set_current_path(llvm::Twine(sref(dir)));
    }

    /// \p dir and everything under it; a missing \p dir is not an error.
    static fn remove_tree(dir: string) {
        if dir.empty() { return; }
        llvm::sys::fs::remove_directories(llvm::Twine(sref(dir)), true);
    }

    static fn remove_file(p: string) {
        llvm::sys::fs::remove(llvm::Twine(sref(p)), true);
    }

    /// A fresh, uniquely named directory under the system temp dir; "" on
    /// failure. The caller owns removing it (remove_tree).
    static fn make_temp_dir(prefix: string) -> string {
        // createUniqueDirectory takes the prefix relative to the cwd; anchor
        // it in the temp dir first.
        var base: llvm::SmallString::<256>;
        llvm::sys::path::system_temp_directory(true, base);
        llvm::sys::path::append(base, llvm::Twine(sref(prefix)));
        var out: llvm::SmallString::<256>;
        if llvm::sys::fs::createUniqueDirectory(llvm::Twine(base), out) { return ""; }
        return string(out.data(), out.size());
    }

    /// Writes \p text to \p p in one go, truncating. False on failure.
    static fn write_file(p: string, text: string) -> bool {
        var ec: libcxx::error_code;
        var os = llvm::raw_fd_ostream(sref(p), ec, llvm::sys::fs::OF_None);
        if ec { return false; }
        os.write(text.c_str(), text.size());
        os.close();
        return !os.has_error();
    }

    ///
    /// \brief the type of a directory_iterator entry, from the readdir
    ///        record itself where the OS supplies one (d_type).
    ///
    /// \details A second stat is paid only for a symlink or an unknown type,
    ///          and follows the link: a link to a directory must still be
    ///          walked as one, as filesystem::directory_iterator's
    ///          is_directory() did.
    ///
    static fn type_of_entry(e: cref::<llvm::sys::fs::directory_entry>) -> FileType {
        // INLINE(cxx-feature: member named with a Kairo keyword)
        var t: FileType = e.__inline_cpp("type()");
        if (t == FileType::symlink_file) || (t == FileType::type_unknown) {
            t = llvm::sys::fs::get_file_type(llvm::Twine(e.path()), true);
        }
        return t;
    }

    ///
    /// \brief whether \p p names something on disk. One stat, no Path built
    ///        -- for probes that only need the answer.
    ///
    static fn exists_at(p: string) -> bool {
        return llvm::sys::fs::exists(llvm::Twine(sref(p)));
    }

    ///
    /// \brief checks if path exists.
    ///
    const fn exists(self) -> bool {
        return Path::exists_at(self.path_data);
    }

    ///
    /// \brief returns file extension (including the dot).
    ///
    const fn extension(self) -> string {
        var sr = llvm::sys::path::extension(sref(self.path_data));
        return string(sr.data(), sr.size());
    }

    ///
    /// \brief returns the final filename component.
    ///
    const fn filename(self) -> string {
        var sr = llvm::sys::path::filename(sref(self.path_data));
        return string(sr.data(), sr.size());
    }

    ///
    /// \brief returns the final filename component without its extension.
    ///
    const fn stem(self) -> string {
        var sr = llvm::sys::path::stem(sref(self.path_data));
        return string(sr.data(), sr.size());
    }

    ///
    /// \brief the containing directory as a string; "" for a root or an
    ///        empty Path. No stat.
    ///
    const fn parent_path(self) -> string {
        var sr = llvm::sys::path::parent_path(sref(self.path_data));
        return string(sr.data(), sr.size());
    }

    ///
    /// \brief \p rel under this path, as a string. No stat -- for probes
    ///        that stat the result themselves; `/` builds a full Path.
    ///
    const fn join(self, rel: string) -> string {
        return Path::join_str(self.path_data, rel);
    }

    ///
    /// \brief this path relative to \p base, or "" when it is not strictly
    ///        under \p base (equal, a sibling, or above it).
    ///
    /// \details Component-wise prefix match on the normalised strings, so
    ///          `/a/bc` is not under `/a/b`. Lexical, like the
    ///          lexically_relative() it replaces.
    ///
    const fn relative_to(self, base: Path) -> string {
        var it   = llvm::sys::path::begin(sref(self.path_data));
        var end  = llvm::sys::path::end(sref(self.path_data));
        var bit  = llvm::sys::path::begin(sref(base.path_data));
        var bend = llvm::sys::path::end(sref(base.path_data));

        while (bit != bend) {
            if (it == end) || ((*it) != (*bit)) { return ""; }
            ++it;
            ++bit;
        }
        if it == end { return ""; }

        var buf: llvm::SmallString::<256>;
        while (it != end) {
            llvm::sys::path::append(buf, llvm::sys::path::Style::posix, llvm::Twine(*it));
            ++it;
        }
        return string(buf.data(), buf.size());
    }

    ///
    /// \brief returns the absolute normalized path as string.
    ///
    const fn full_path(self) -> string {
        return self.path_data;
    }

    ///
    /// \brief returns the cached filesystem entry type.
    ///
    const fn file_type(self) -> FileType {
        return self.entry_type;
    }

    ///
    /// \brief true if the path refers to a directory.
    ///
    const fn is_directory(self) -> bool {
        return self.entry_type == FileType::directory_file;
    }

    ///
    /// \brief true if the path refers to a regular file.
    ///
    const fn is_regular_file(self) -> bool {
        return self.entry_type == FileType::regular_file;
    }

    ///
    /// \brief true if the path refers to a symbolic link.
    ///
    const fn is_symlink(self) -> bool {
        return self.entry_type == FileType::symlink_file;
    }

    ///
    /// \brief true if the path refers to a fifo node.
    ///
    const fn is_fifo(self) -> bool {
        return self.entry_type == FileType::fifo_file;
    }

    ///
    /// \brief true if the path refers to a unix domain socket.
    ///
    const fn is_socket(self) -> bool {
        return self.entry_type == FileType::socket_file;
    }

    ///
    /// \brief true if the path refers to a block device.
    ///
    const fn is_block_device(self) -> bool {
        return self.entry_type == FileType::block_file;
    }

    ///
    /// \brief true if the path refers to a character device.
    ///
    const fn is_character_device(self) -> bool {
        return self.entry_type == FileType::character_file;
    }

    const fn as_qualified_path(self) -> vec::<string> {
        /// returns a vector of path components from root to leaf.
        /// like for foo/bar/baz.txt, returns [abs .. "foo", "bar", "baz"].
        var components = vec::<string>();
        var range = llvm::make_range(llvm::sys::path::begin(sref(self.path_data)),
                                     llvm::sys::path::end(sref(self.path_data)));

        for component in range {
            components.emplace_back(string(component.data(), component.size()));
        }

        return components;
    }

    fn op / (self, other: string) -> Path {
        return Path(self.join(other));
    }

    fn op / (self, other: Path) -> Path {
        return Path(self.join(other.path_data));
    }

    ///
    /// \brief string representation for debugging/logging.
    ///
    /// \return formatted as
    ///         `"Path(path_data: <abs_path>, entry_type: <numeric_type>)"`.
    ///
    fn op as (self) -> string {
        return f"Path(path_data: {self.path_data}, entry_type: {static_cast::<u32>(self.entry_type)})";
    }

    /// get_file_type() reports a failed stat as file_not_found (ENOENT) or
    /// status_error (anything else); both mean "nothing usable is there".
    priv const fn _entry_exists(self) -> bool {
        return (self.entry_type != FileType::file_not_found)
            && (self.entry_type != FileType::status_error);
    }

    /// Absolute against the process cwd, '.' segments dropped, generic
    /// separators. '..' survives: folding it lexically walks out of the
    /// wrong directory when the segment before it is a symlink.
    priv static fn _normalize(input: string) -> string {
        var buf = llvm::SmallString::<256>(sref(input));
        llvm::sys::fs::make_absolute(buf);
        llvm::sys::path::remove_dots(buf, false);
        var generic = llvm::sys::path::convert_to_slash(llvm::StringRef(buf.data(), buf.size()));
        return string(generic.data(), generic.size());
    }
}
