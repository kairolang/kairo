/// --- The Kairo Project ------------------------ API/SysrootManifest.k --- ///
///
///   Reads a ksys SYSROOT.toml and the flat TOML subset it uses.
///
///   The flat TOML subset it needs: `key = "string"`, `key = true|false`,
///   `key = ["a", "b"]` (arrays may span lines), `#` comments. Table headers
///   are skipped; the manifest is flat. Unknown keys are ignored: they belong
///   to kbld or ksys, not the linker.
///
///   Relative paths in the manifest resolve against the manifest's own
///   directory (`sysroot = "."` is that directory), and every other path
///   against the resolved sysroot. Toolchain does the resolving; this file only
///   reads.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import API::FS::LinkFS
import API::Text::LinkText

pub struct TomlValue {
    pub var kind: u8                       = 0 ///< 0 none, 1 string, 2 bool, 3 string array, 4 other scalar
    pub var text: string
    pub var flag: bool                     = false
    pub var list: cxx::std::vector<string>
}

pub class TomlLite {
    priv var _s:    string
    priv var _i:    usize  = 0
    pub var  error: string
    /// The last `[table]` header seen ("" before the first), dots kept:
    /// `[quirk.wasm-bf16]` is "quirk.wasm-bf16". SYSROOT.toml is flat and
    /// ignores it; ksys's registry and recipes are not.
    pub var table: string

    pub fn TomlLite(self, const text: string) {
        self._s = text
    }

    /// Next key/value pair. False at end of input or on error (check error).
    pub fn next(self, @inout key: string, @inout val: TomlValue) -> bool {
        while true {
            self._skip(true)
            if self._i >= self._s.size() {
                return false
            }

            if self._s[self._i] != ('[' as u8) {
                break
            }

            var hb = self._i + 1
            while self._i < self._s.size() && self._s[self._i] != ('\n' as u8) {
                self._i += 1
            }

            var he = hb
            while he < self._i && self._s[he] != (']' as u8) {
                he += 1
            }

            self.table = LinkText::trim(LinkText::slice(self._s, hb, he))
        }

        // A quoted key: registry.toml's input dirs hold `/` and `.`, which a
        // bare TOML key cannot.
        if self._s[self._i] == ('\x22' as u8) {
            if !self._string(&key) {
                return false
            }

            return self._after_key(&key, &val)
        }

        var b = self._i
        while self._i < self._s.size() {
            var c = self._s[self._i]
            if c == ('=' as u8) || c == (' ' as u8) || c == ('\t' as u8) || c == ('\n' as u8) {
                break
            }

            self._i += 1
        }

        key = LinkText::slice(self._s, b, self._i)
        return self._after_key(&key, &val)
    }

    priv fn _after_key(self, @inout key: string, @inout val: TomlValue) -> bool {
        self._skip(false)
        if self._i >= self._s.size() || self._s[self._i] != ('=' as u8) {
            return self._fail(f"expected = after {key}")
        }

        self._i += 1
        self._skip(false)

        val = TomlValue{}
        if !self._value(&val) {
            return false
        }

        self._skip(false)
        if self._i < self._s.size() && self._s[self._i] != ('\n' as u8) {
            return self._fail(f"unexpected text after the value of {key}")
        }

        return true
    }

    priv fn _value(self, @inout val: TomlValue) -> bool {
        if self._i >= self._s.size() {
            return self._fail("missing value")
        }

        var c = self._s[self._i]

        if c == ('\x22' as u8) || c == ('\x27' as u8) {
            val.kind = 1
            return self._string(&val.text)
        }

        if c == ('[' as u8) {
            val.kind = 3
            self._i += 1
            while true {
                self._skip(true)
                if self._i >= self._s.size() {
                    return self._fail("unterminated array")
                }

                if self._s[self._i] == (']' as u8) {
                    self._i += 1
                    return true
                }

                var q = self._s[self._i]
                if q != ('\x22' as u8) && q != ('\x27' as u8) {
                    return self._fail("arrays may only hold strings")
                }

                var item = ""
                if !self._string(&item) {
                    return false
                }

                val.list.push_back(item)
                self._skip(true)
                if self._i < self._s.size() && self._s[self._i] == (',' as u8) {
                    self._i += 1
                }
            }
        }

        var b = self._i
        while self._i < self._s.size() {
            var d = self._s[self._i]
            if d == ('\n' as u8)
                || d == ('#' as u8)
                || d == (' ' as u8)
                || d == ('\t' as u8)
                || d == ('\r' as u8) {
                break
            }

            self._i += 1
        }

        val.text = LinkText::slice(self._s, b, self._i)
        if val.text == "true" {
            val.kind = 2
            val.flag = true
        } else if val.text == "false" {
            val.kind = 2
            val.flag = false
        } else {
            val.kind = 4
        }

        return true
    }

    /// Basic ("...", with \" \\ \n \t) or literal ('...', no escapes).
    priv fn _string(self, @inout out: string) -> bool {
        var q = self._s[self._i]
        self._i += 1
        var b   = self._i
        var res = ""
        while self._i < self._s.size() {
            var c = self._s[self._i]
            if c == ('\n' as u8) {
                break
            }

            if c == q {
                res += LinkText::slice(self._s, b, self._i)
                self._i += 1
                out = res
                return true
            }

            if q == ('\x22' as u8) && c == ('\\' as u8) && self._i + 1 < self._s.size() {
                res += LinkText::slice(self._s, b, self._i)
                var e = self._s[self._i + 1]
                if e == ('n' as u8) {
                    res += "\n"
                } else if e == ('t' as u8) {
                    res += "\t"
                } else {
                    res += LinkText::slice(self._s, self._i + 1, self._i + 2)
                }

                self._i += 2
                b = self._i
                continue
            }

            self._i += 1
        }

        return self._fail("unterminated string")
    }

    priv fn _skip(self, newlines: bool) {
        while self._i < self._s.size() {
            var c = self._s[self._i]
            if c == (' ' as u8) || c == ('\t' as u8) || c == ('\r' as u8) {
                self._i += 1
                continue
            }

            if newlines && c == ('\n' as u8) {
                self._i += 1
                continue
            }

            if c == ('#' as u8) {
                while self._i < self._s.size() && self._s[self._i] != ('\n' as u8) {
                    self._i += 1
                }

                continue
            }

            break
        }
    }

    priv fn _fail(self, const what: string) -> bool {
        var line: usize = 1
        for var i: usize = 0; i < self._i && i < self._s.size(); ++i {
            if self._s[i] == ('\n' as u8) {
                line += 1
            }
        }

        self.error = f"line {line}: {what}"
        return false
    }
}

pub class SysrootManifest {
    pub var path:  string ///< the SYSROOT.toml itself
    pub var dir:   string ///< its directory: the base for `sysroot`
    pub var error: string

    pub var triple: string
    /// The triple clang is handed (`armv7-unknown-linux-musleabihf` for the
    /// sysroot named armv7-linux-musl). "" in roots older than ksys: the
    /// driver then derives it (FlagTranslator::clang_triple).
    pub var clang_triple: string
    pub var llvm_version: string
    pub var family:       string
    /// glibc_version: the glibc the sysroot's libc is (its "floor"), "" for
    /// any other C library. A host shared library that needs a newer
    /// GLIBC_ symbol version raises what the program needs to run.
    pub var glibc_version: string
    pub var sysroot:       string = "."
    pub var resource_dir:  string
    pub var rtlib:         string
    pub var unwindlib:     string
    pub var linker:        string
    pub var has_libcxx:    bool   = false
    pub var is_static:     bool   = false ///< `static` in the file

    pub var include_dirs: cxx::std::vector<string>
    pub var lib_dirs:     cxx::std::vector<string>
    pub var crt_startup:  cxx::std::vector<string>
    pub var crt_end:      cxx::std::vector<string>
    pub var libc_link:    cxx::std::vector<string>
    pub var libcxx_link:  cxx::std::vector<string>
    pub var cc_isolation: cxx::std::vector<string>
    pub var cc_defines:   cxx::std::vector<string> ///< -D names the prebuilt libc++ was built with

    pub static fn load(const path: string, @inout out: SysrootManifest) -> bool {
        out      = SysrootManifest()
        out.path = path
        out.dir  = LinkFS::parent(path)

        var text = ""
        if !LinkFS::read(path, &text) {
            out.error = "cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if !out._set(key, &val) {
                return false
            }
        }

        if !toml.error.empty() {
            out.error = toml.error
            return false
        }

        if out.triple.empty() {
            out.error = "no triple key: a sysroot manifest must name its target"
            return false
        }

        return true
    }

    priv fn _set(self, const key: string, @inout v: TomlValue) -> bool {
        if key == "triple" {
            return self._str(key, &v, &self.triple)
        }

        if key == "clang_triple" {
            return self._str(key, &v, &self.clang_triple)
        }

        if key == "llvm_version" {
            return self._str(key, &v, &self.llvm_version)
        }

        if key == "family" {
            return self._str(key, &v, &self.family)
        }

        if key == "glibc_version" {
            return self._str(key, &v, &self.glibc_version)
        }

        if key == "sysroot" {
            return self._str(key, &v, &self.sysroot)
        }

        if key == "resource_dir" {
            return self._str(key, &v, &self.resource_dir)
        }

        if key == "rtlib" {
            return self._str(key, &v, &self.rtlib)
        }

        if key == "unwindlib" {
            return self._str(key, &v, &self.unwindlib)
        }

        if key == "linker" {
            return self._str(key, &v, &self.linker)
        }

        if key == "has_libcxx" {
            return self._flag(key, &v, &self.has_libcxx)
        }

        if key == "static" {
            return self._flag(key, &v, &self.is_static)
        }

        if key == "include_dirs" {
            return self._list(key, &v, &self.include_dirs)
        }

        if key == "lib_dirs" {
            return self._list(key, &v, &self.lib_dirs)
        }

        if key == "crt_startup" {
            return self._list(key, &v, &self.crt_startup)
        }

        if key == "crt_end" {
            return self._list(key, &v, &self.crt_end)
        }

        if key == "libc_link" {
            return self._list(key, &v, &self.libc_link)
        }

        if key == "libcxx_link" {
            return self._list(key, &v, &self.libcxx_link)
        }

        if key == "cc_isolation" {
            return self._list(key, &v, &self.cc_isolation)
        }

        if key == "cc_defines" {
            return self._list(key, &v, &self.cc_defines)
        }

        return true
    }

    priv fn _str(self, const key: string, @inout v: TomlValue, @inout dst: string) -> bool {
        if v.kind != 1 {
            self.error = f"{key} must be a string"
            return false
        }

        dst = v.text
        return true
    }

    priv fn _flag(self, const key: string, @inout v: TomlValue, @inout dst: bool) -> bool {
        if v.kind != 2 {
            self.error = f"{key} must be true or false"
            return false
        }

        dst = v.flag
        return true
    }

    priv fn _list(self,
                  const key:  string,
                  @inout v:   TomlValue,
                  @inout dst: cxx::std::vector<string>) -> bool {
        if v.kind != 3 {
            self.error = f"{key} must be an array of strings"
            return false
        }

        dst = v.list
        return true
    }
}
