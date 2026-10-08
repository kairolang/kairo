/// --- The Kairo Project --------------- Linker/API/SysrootManifest.k ----- ///
///
///   \brief Reader for a ksys SYSROOT.toml, plus the flat TOML subset it
///          needs: `key = "string"`, `key = true|false`, `key = ["a", "b"]`
///          (arrays may span lines), `#` comments. Table headers are
///          skipped; the manifest is flat. Unknown keys are ignored: they
///          belong to kbld or ksys, not the linker.
///
///   Relative paths in the manifest resolve against the manifest's own
///   directory (`sysroot = "."` is that directory), and every other path
///   against the resolved sysroot. Toolchain does the resolving; this file
///   only reads.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Linker::API::Text::*;
import Linker::API::FS::*;

struct TomlValue {
    var kind: u8 = 0;           ///< 0 none, 1 string, 2 bool, 3 string array, 4 other scalar
    var text: string;
    var flag: bool = false;
    var list: vec::<string>;
}

class TomlLite {
    priv var _s: string;
    priv var _i: usize = 0;
    pub var error: string;

    fn TomlLite(self, text: string) { self._s = text; }

    /// Next key/value pair. False at end of input or on error (check error).
    fn next(self, key: ref!(string), val: ref!(TomlValue)) -> bool {
        while true {
            self._skip(true);
            if self._i >= self._s.size() { return false; }
            if self._s[self._i] != '[' { break; }
            while (self._i < self._s.size()) && (self._s[self._i] != '\n') { self._i += 1; }
        }

        var b = self._i;
        while self._i < self._s.size() {
            var c = self._s[self._i];
            if (c == '=') || (c == ' ') || (c == '\t') || (c == '\n') { break; }
            self._i += 1;
        }
        key = LinkText::slice(self._s, b, self._i);

        self._skip(false);
        if (self._i >= self._s.size()) || (self._s[self._i] != '=') {
            return self._fail(f"expected = after {key}");
        }
        self._i += 1;
        self._skip(false);

        val = TomlValue{};
        if !self._value(val) { return false; }

        self._skip(false);
        if (self._i < self._s.size()) && (self._s[self._i] != '\n') {
            return self._fail(f"unexpected text after the value of {key}");
        }
        return true;
    }

    priv fn _value(self, val: ref!(TomlValue)) -> bool {
        if self._i >= self._s.size() { return self._fail("missing value"); }
        var c = self._s[self._i];

        if (c == '\x22') || (c == '\x27') {
            val.kind = 1;
            return self._string(val.text);
        }

        if c == '[' {
            val.kind = 3;
            self._i += 1;
            while true {
                self._skip(true);
                if self._i >= self._s.size() { return self._fail("unterminated array"); }
                if self._s[self._i] == ']' { self._i += 1; return true; }
                var q = self._s[self._i];
                if (q != '\x22') && (q != '\x27') { return self._fail("arrays may only hold strings"); }
                var item = "";
                if !self._string(item) { return false; }
                val.list.push_back(item);
                self._skip(true);
                if (self._i < self._s.size()) && (self._s[self._i] == ',') { self._i += 1; }
            }
            return false;
        }

        var b = self._i;
        while self._i < self._s.size() {
            var d = self._s[self._i];
            if (d == '\n') || (d == '#') || (d == ' ') || (d == '\t') || (d == '\r') { break; }
            self._i += 1;
        }
        val.text = LinkText::slice(self._s, b, self._i);
        if val.text == "true"       { val.kind = 2; val.flag = true;  }
        else if val.text == "false" { val.kind = 2; val.flag = false; }
        else                        { val.kind = 4; }
        return true;
    }

    /// Basic ("...", with \" \\ \n \t) or literal ('...', no escapes).
    priv fn _string(self, out: ref!(string)) -> bool {
        var q = self._s[self._i];
        self._i += 1;
        var b   = self._i;
        var res = "";
        while self._i < self._s.size() {
            var c = self._s[self._i];
            if c == '\n' { break; }
            if c == q {
                res += LinkText::slice(self._s, b, self._i);
                self._i += 1;
                out = res;
                return true;
            }
            if (q == '\x22') && (c == '\\') && ((self._i + 1) < self._s.size()) {
                res += LinkText::slice(self._s, b, self._i);
                var e = self._s[self._i + 1];
                if e == 'n'      { res += "\n"; }
                else if e == 't' { res += "\t"; }
                else             { res += LinkText::slice(self._s, self._i + 1, self._i + 2); }
                self._i += 2;
                b = self._i;
                continue;
            }
            self._i += 1;
        }
        return self._fail("unterminated string");
    }

    priv fn _skip(self, newlines: bool) {
        while self._i < self._s.size() {
            var c = self._s[self._i];
            if (c == ' ') || (c == '\t') || (c == '\r') { self._i += 1; continue; }
            if newlines && (c == '\n') { self._i += 1; continue; }
            if c == '#' {
                while (self._i < self._s.size()) && (self._s[self._i] != '\n') { self._i += 1; }
                continue;
            }
            break;
        }
    }

    priv fn _fail(self, what: string) -> bool {
        var line: usize = 1;
        for var i: usize = 0; (i < self._i) && (i < self._s.size()); ++i {
            if self._s[i] == '\n' { line += 1; }
        }
        self.error = f"line {line}: {what}";
        return false;
    }
}

class SysrootManifest {
    pub var path:         string;   ///< the SYSROOT.toml itself
    pub var dir:          string;   ///< its directory: the base for `sysroot`
    pub var error:        string;

    pub var triple:       string;
    pub var llvm_version: string;
    pub var family:       string;
    pub var sysroot:      string = ".";
    pub var resource_dir: string;
    pub var rtlib:        string;
    pub var unwindlib:    string;
    pub var linker:       string;
    pub var has_libcxx:   bool = false;
    pub var is_static:    bool = false;   ///< `static` in the file

    pub var include_dirs: vec::<string>;
    pub var lib_dirs:     vec::<string>;
    pub var crt_startup:  vec::<string>;
    pub var crt_end:      vec::<string>;
    pub var libc_link:    vec::<string>;
    pub var libcxx_link:  vec::<string>;
    pub var cc_isolation: vec::<string>;
    pub var cc_defines:   vec::<string>;   ///< -D names the prebuilt libc++ was built with

    static fn load(path: string, out: ref!(SysrootManifest)) -> bool {
        out      = SysrootManifest();
        out.path = path;
        out.dir  = LinkFS::parent(path);

        var text = "";
        if !LinkFS::read(path, text) {
            out.error = "cannot read the file";
            return false;
        }

        var toml = TomlLite(text);
        var key  = "";
        var val  = TomlValue{};
        while toml.next(key, val) {
            if !out._set(key, val) { return false; }
        }
        if !toml.error.empty() {
            out.error = toml.error;
            return false;
        }
        if out.triple.empty() {
            out.error = "no triple key: a sysroot manifest must name its target";
            return false;
        }
        return true;
    }

    priv fn _set(self, key: string, v: ref!(TomlValue)) -> bool {
        if key == "triple"       { return self._str(key, v, self.triple);       }
        if key == "llvm_version" { return self._str(key, v, self.llvm_version); }
        if key == "family"       { return self._str(key, v, self.family);       }
        if key == "sysroot"      { return self._str(key, v, self.sysroot);      }
        if key == "resource_dir" { return self._str(key, v, self.resource_dir); }
        if key == "rtlib"        { return self._str(key, v, self.rtlib);        }
        if key == "unwindlib"    { return self._str(key, v, self.unwindlib);    }
        if key == "linker"       { return self._str(key, v, self.linker);       }
        if key == "has_libcxx"   { return self._flag(key, v, self.has_libcxx);  }
        if key == "static"       { return self._flag(key, v, self.is_static);   }
        if key == "include_dirs" { return self._list(key, v, self.include_dirs); }
        if key == "lib_dirs"     { return self._list(key, v, self.lib_dirs);     }
        if key == "crt_startup"  { return self._list(key, v, self.crt_startup);  }
        if key == "crt_end"      { return self._list(key, v, self.crt_end);      }
        if key == "libc_link"    { return self._list(key, v, self.libc_link);    }
        if key == "libcxx_link"  { return self._list(key, v, self.libcxx_link);  }
        if key == "cc_isolation" { return self._list(key, v, self.cc_isolation); }
        if key == "cc_defines"   { return self._list(key, v, self.cc_defines);   }
        return true;
    }

    priv fn _str(self, key: string, v: ref!(TomlValue), dst: ref!(string)) -> bool {
        if v.kind != 1 { self.error = f"{key} must be a string"; return false; }
        dst = v.text;
        return true;
    }

    priv fn _flag(self, key: string, v: ref!(TomlValue), dst: ref!(bool)) -> bool {
        if v.kind != 2 { self.error = f"{key} must be true or false"; return false; }
        dst = v.flag;
        return true;
    }

    priv fn _list(self, key: string, v: ref!(TomlValue), dst: ref!(vec::<string>)) -> bool {
        if v.kind != 3 { self.error = f"{key} must be an array of strings"; return false; }
        dst = v.list;
        return true;
    }
}