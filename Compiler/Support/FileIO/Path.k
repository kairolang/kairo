/// --- The Kairo Project ------------------------ Support/FileIO/Path.k --- ///
///
///   Path: an absolute UTF-8 path, queried through LLVM's path library.
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
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/ADT/iterator_range.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/KFileSystem.hh" // dir_entry_type: `type` is a keyword
ffi "c++" import "system_error"
ffi "c++" import "vector"

import Support::FileIO::FileSystem::FileType

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

pub class Path {
    pub var path_data:  string   ///< absolute, generic-form path.
    pub var entry_type: FileType ///< cached type of the path entry.

    ///
    /// \brief default constructor (creates empty path).
    ///
    pub fn Path(self) = default

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
    pub fn Path(self, const input: string, mustExist: bool = false) {
        self.path_data = Path::_normalize(input)

        if self.path_data.empty() {
            kairo::std::ice_fail("Path: empty path string")
        }

        // Follows symlinks, as the libc++ status() this replaced did: a link
        // to a file reports regular_file, never symlink_file.
        self.entry_type = llvm::sys::fs::get_file_type(
            llvm::Twine(kairo::sref(self.path_data)),
            true,
        )

        if mustExist && !self._entry_exists() {
            kairo::std::ice_fail(f"Path: path does not exist: {self.path_data}")
        }
    }

    ///
    /// \brief a Path for \p abs whose type the caller already knows -- from
    ///        a readdir record or a probe's own stat. No syscall.
    ///
    /// \details \p abs must already be absolute and generic-form (a
    ///          Path::join off another Path is); it is stored as given.
    ///
    pub static fn from_known(const abs: string, t: FileType) -> Path {
        var p = Path()
        p.path_data  = abs
        p.entry_type = t
        return p
    }

    pub static fn cwd() -> Path {
        var buf: llvm::SmallString<256>
        llvm::sys::fs::current_path(&buf)
        return Path(string(unsafe ((buf.data() as unsafe *const u8) as *const u8), buf.size()))
    }

    static fn home() -> Path {
        var buf: llvm::SmallString<256>
        if !llvm::sys::path::home_directory(&buf) {
            kairo::std::ice_fail("Path::home: no home directory (HOME not set)")
        }

        return Path(string(unsafe ((buf.data() as unsafe *const u8) as *const u8), buf.size()))
    }

    pub static fn temp_dir() -> Path {
        var buf: llvm::SmallString<256>
        llvm::sys::path::system_temp_directory(true, &buf)
        return Path(string(unsafe ((buf.data() as unsafe *const u8) as *const u8), buf.size()))
    }

    static fn root() -> Path {
        return Path("/")
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
    pub static fn absolute_if_exists(p: string, const base: string = "") -> string {
        if p.empty() {
            return p
        }

        var cand = p
        if !base.empty() && !llvm::sys::path::is_absolute(llvm::Twine(kairo::sref(p))) {
            cand = Path::join_str(base, p)
        }

        if !Path::exists_at(cand) {
            return p
        }

        return Path::_normalize(cand)
    }

    ///
    /// \brief \p rel appended to \p base, purely lexically (no stat).
    ///
    /// \details An absolute \p rel replaces \p base, matching
    ///          filesystem::path's operator/ that the callers were written
    ///          against; llvm's append() would glue the two together instead.
    ///
    pub static fn join_str(const base: string, rel: string) -> string {
        if base.empty() || llvm::sys::path::is_absolute(llvm::Twine(kairo::sref(rel))) {
            return rel
        }

        // posix style: Path stores the generic form on every host, and a
        // native append would splice a '\\' into it on Windows.
        var buf = llvm::SmallString<256>(kairo::sref(base))
        llvm::sys::path::append(&buf, llvm::sys::path::Style::posix, llvm::Twine(kairo::sref(rel)))
        return string(unsafe ((buf.data() as unsafe *const u8) as *const u8), buf.size())
    }

    /// # string-level queries (no Path built, no stat)
    ///
    /// For callers holding a plain path string: building a Path stats the
    /// disk, and these only need the lexical answer.

    pub static fn parent_of(const p: string) -> string {
        var sr = llvm::sys::path::parent_path(kairo::sref(p))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    pub static fn filename_of(const p: string) -> string {
        var sr = llvm::sys::path::filename(kairo::sref(p))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    pub static fn stem_of(const p: string) -> string {
        var sr = llvm::sys::path::stem(kairo::sref(p))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    pub static fn extension_of(const p: string) -> string {
        var sr = llvm::sys::path::extension(kairo::sref(p))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    /// \p p with every symlink resolved, or \p p unchanged when it cannot
    ///        be (it does not exist). One syscall.
    ///
    /// \details For IDENTITY comparisons only -- "are these two spellings one
    ///          directory?" -- never for a path that is printed or stored:
    ///          what the user typed (a vendored symlink) is what a diagnostic
    ///          should quote.
    pub static fn real_path_of(p: string) -> string {
        if p.empty() {
            return p
        }

        var buf: llvm::SmallString<256>
        if llvm::sys::fs::real_path(llvm::Twine(kairo::sref(p)), &buf, false).value() != 0 {
            return p
        }

        var generic = llvm::sys::path::convert_to_slash(llvm::StringRef(buf.data(), buf.size()))
        return string(unsafe ((generic.data() as unsafe *const u8) as *const u8), generic.size())
    }

    /// # filesystem mutations

    /// \p dir and every missing parent. True when it exists afterwards.
    pub static fn make_dirs(const dir: string) -> bool {
        if dir.empty() {
            return true
        }

        return llvm::sys::fs::create_directories(llvm::Twine(kairo::sref(dir)), true).value() == 0
    }

    /// The directory \p file will be written into, created if missing.
    pub static fn make_parent_dirs(const file: string) -> bool {
        return Path::make_dirs(Path::parent_of(file))
    }

    /// chdir. False (nothing changed) when \p dir cannot be entered.
    pub static fn set_cwd(const dir: string) -> bool {
        return llvm::sys::fs::set_current_path(llvm::Twine(kairo::sref(dir))).value() == 0
    }

    /// \p dir and everything under it; a missing \p dir is not an error.
    pub static fn remove_tree(const dir: string) {
        if dir.empty() {
            return
        }

        llvm::sys::fs::remove_directories(llvm::Twine(kairo::sref(dir)), true)
    }

    pub static fn remove_file(const p: string) {
        llvm::sys::fs::remove(llvm::Twine(kairo::sref(p)), true)
    }

    /// A fresh, uniquely named directory under the system temp dir; "" on
    /// failure. The caller owns removing it (remove_tree).
    static fn make_temp_dir(const prefix: string) -> string {
        // createUniqueDirectory takes the prefix relative to the cwd; anchor
        // it in the temp dir first.
        var base: llvm::SmallString<256>
        llvm::sys::path::system_temp_directory(true, &base)
        llvm::sys::path::append(&base, llvm::Twine(kairo::sref(prefix)))
        var out: llvm::SmallString<256>
        if llvm::sys::fs::createUniqueDirectory(llvm::Twine(base), &out).value() != 0 {
            return ""
        }

        return string(unsafe ((out.data() as unsafe *const u8) as *const u8), out.size())
    }

    /// Writes \p text to \p p in one go, truncating. False on failure.
    pub static fn write_file(const p: string, const text: string) -> bool {
        var ec: cxx::std::error_code
        var os = llvm::raw_fd_ostream(kairo::sref(p), &ec, llvm::sys::fs::OF_None)
        if ec.value() != 0 {
            return false
        }

        os.write(text.c_str(), text.size())
        os.close()
        return !os.has_error()
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
    pub static fn type_of_entry(const e: llvm::sys::fs::directory_entry) -> FileType {
        var t: FileType = kairo::dir_entry_type(e)
        if t == FileType::symlink_file || t == FileType::type_unknown {
            t = llvm::sys::fs::get_file_type(llvm::Twine(e.path()), true)
        }

        return t
    }

    ///
    /// \brief whether \p p names something on disk. One stat, no Path built
    ///        -- for probes that only need the answer.
    ///
    pub static fn exists_at(const p: string) -> bool {
        return llvm::sys::fs::exists(llvm::Twine(kairo::sref(p)))
    }

    ///
    /// \brief checks if path exists.
    ///
    pub fn exists(const self) -> bool {
        return Path::exists_at(self.path_data)
    }

    ///
    /// \brief returns file extension (including the dot).
    ///
    pub fn extension(const self) -> string {
        var sr = llvm::sys::path::extension(kairo::sref(self.path_data))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    ///
    /// \brief returns the final filename component.
    ///
    pub fn filename(const self) -> string {
        var sr = llvm::sys::path::filename(kairo::sref(self.path_data))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    ///
    /// \brief returns the final filename component without its extension.
    ///
    pub fn stem(const self) -> string {
        var sr = llvm::sys::path::stem(kairo::sref(self.path_data))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    ///
    /// \brief the containing directory as a string; "" for a root or an
    ///        empty Path. No stat.
    ///
    pub fn parent_path(const self) -> string {
        var sr = llvm::sys::path::parent_path(kairo::sref(self.path_data))
        return string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size())
    }

    ///
    /// \brief \p rel under this path, as a string. No stat -- for probes
    ///        that stat the result themselves; `/` builds a full Path.
    ///
    pub fn join(const self, const rel: string) -> string {
        return Path::join_str(self.path_data, rel)
    }

    ///
    /// \brief this path relative to \p base, or "" when it is not strictly
    ///        under \p base (equal, a sibling, or above it).
    ///
    /// \details Component-wise prefix match on the normalised strings, so
    ///          `/a/bc` is not under `/a/b`. Lexical, like the
    ///          lexically_relative() it replaces.
    ///
    pub fn relative_to(const self, const base: Path) -> string {
        var it   = llvm::sys::path::begin(kairo::sref(self.path_data))
        var end  = llvm::sys::path::end(kairo::sref(self.path_data))
        var bit  = llvm::sys::path::begin(kairo::sref(base.path_data))
        var bend = llvm::sys::path::end(kairo::sref(base.path_data))

        while bit != bend {
            if it == end || *it != *bit {
                return ""
            }

            ++it
            ++bit
        }

        if it == end {
            return ""
        }

        var buf: llvm::SmallString<256>
        while it != end {
            llvm::sys::path::append(&buf, llvm::sys::path::Style::posix, llvm::Twine(*it))
            ++it
        }

        return string(unsafe ((buf.data() as unsafe *const u8) as *const u8), buf.size())
    }

    ///
    /// \brief returns the absolute normalized path as string.
    ///
    pub fn full_path(const self) -> string {
        return self.path_data
    }

    ///
    /// \brief returns the cached filesystem entry type.
    ///
    fn file_type(const self) -> FileType {
        return self.entry_type
    }

    ///
    /// \brief true if the path refers to a directory.
    ///
    pub fn is_directory(const self) -> bool {
        return self.entry_type == FileType::directory_file
    }

    ///
    /// \brief true if the path refers to a regular file.
    ///
    pub fn is_regular_file(const self) -> bool {
        return self.entry_type == FileType::regular_file
    }

    ///
    /// \brief true if the path refers to a symbolic link.
    ///
    pub fn is_symlink(const self) -> bool {
        return self.entry_type == FileType::symlink_file
    }

    ///
    /// \brief true if the path refers to a fifo node.
    ///
    fn is_fifo(const self) -> bool {
        return self.entry_type == FileType::fifo_file
    }

    ///
    /// \brief true if the path refers to a unix domain socket.
    ///
    fn is_socket(const self) -> bool {
        return self.entry_type == FileType::socket_file
    }

    ///
    /// \brief true if the path refers to a block device.
    ///
    fn is_block_device(const self) -> bool {
        return self.entry_type == FileType::block_file
    }

    ///
    /// \brief true if the path refers to a character device.
    ///
    fn is_character_device(const self) -> bool {
        return self.entry_type == FileType::character_file
    }

    fn as_qualified_path(const self) -> cxx::std::vector<string> {
        /// returns a vector of path components from root to leaf.
        /// like for foo/bar/baz.txt, returns [abs .. "foo", "bar", "baz"].
        var components = cxx::std::vector<string>()
        var range = llvm::make_range(
            llvm::sys::path::begin(kairo::sref(self.path_data)),
            llvm::sys::path::end(kairo::sref(self.path_data)),
        )

        for component in range {
            components.emplace_back(
                string(
                    unsafe ((component.data() as unsafe *const u8) as *const u8),
                    component.size(),
                ),
            )
        }

        return components
    }

    pub fn op / (self, const other: string) -> Path {
        return Path(self.join(other))
    }

    fn op / (self, const other: Path) -> Path {
        return Path(self.join(other.path_data))
    }

    ///
    /// \brief string representation for debugging/logging.
    ///
    /// \return formatted as
    ///         `"Path(path_data: <abs_path>, entry_type: <numeric_type>)"`.
    ///
    fn op as (self) -> string {
        return f"Path(path_data: {self.path_data}, entry_type: {(self.entry_type as i32 as u32)})"
    }

    /// get_file_type() reports a failed stat as file_not_found (ENOENT) or
    /// status_error (anything else); both mean "nothing usable is there".
    priv fn _entry_exists(const self) -> bool {
        return self.entry_type != FileType::file_not_found
            && self.entry_type != FileType::status_error
    }

    /// Absolute against the process cwd, '.' segments dropped, generic
    /// separators. '..' survives: folding it lexically walks out of the
    /// wrong directory when the segment before it is a symlink.
    priv static fn _normalize(const input: string) -> string {
        var buf = llvm::SmallString<256>(kairo::sref(input))
        llvm::sys::fs::make_absolute(&buf)
        llvm::sys::path::remove_dots(&buf, false)
        var generic = llvm::sys::path::convert_to_slash(llvm::StringRef(buf.data(), buf.size()))
        return string(unsafe ((generic.data() as unsafe *const u8) as *const u8), generic.size())
    }
}
