/// --- The Kairo Project ------------------------------ Sysroot/SysUtil.k --- ///
///
///   SysUtil: the small pieces ksys needs that Linker/API does not have:
///   sha256 (LLVM's, through ffi), the share tree's tree_sha256, canonical
///   JSON for cache keys, dotted version compares.
///
///   tree_sha256 is a contract with the share-tree producer (Python), so its
///   byte stream is fixed: every regular file under the dir as
///   `rel\n<sha256 hex>\n`, sorted by the UTF-8 bytes of rel. Registry
///   schema 1 follows symlinks; schema 2 inputs hold none, and one there is
///   an error (P612: a Windows unzip turns a link into a file holding its
///   text, so a followed link hashes differently per host).
///   build/sysroot-share/FORMAT.md has the reference implementation.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/SHA256.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "algorithm"
ffi "c++" import "array"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::Text::LinkText

/// A key/value list kept in insertion order; `json` sorts it, so the
/// caller never has to add fields in key order to get a canonical key.
pub struct SysJsonField {
    pub var key:  string
    pub var json: string ///< already-encoded JSON value
}

pub class SysUtil {
    /// sha256 of \p s, 64 lowercase hex.
    pub static fn sha256(const s: string) -> string {
        return SysUtil::_hex(llvm::SHA256::hash(llvm::arrayRefFromStringRef(kairo::sref(s))))
    }

    /// sha256 of the file's bytes; "" when it cannot be read.
    pub static fn sha256_file(const path: string) -> string {
        var mb = llvm::MemoryBuffer::getFile(llvm::Twine(kairo::sref(path)), false, false)
        if mb.getError().value() != 0 {
            return ""
        }

        return SysUtil::_hex(llvm::SHA256::hash(llvm::arrayRefFromStringRef(mb.get()->getBuffer())))
    }

    /// The share tree's tree_sha256 of \p dir (FORMAT.md). \p follow is
    /// schema 1's rule; without it (schema 2) a symlink below \p dir is an
    /// error naming it. \p dir itself may be one: a share view links whole
    /// inputs in. "" with \p err set on either failure.
    pub static fn tree_sha256(const dir: string, follow: bool, @inout err: string) -> string {
        var rels  = cxx::std::vector<string>()
        var links = cxx::std::vector<string>()
        SysUtil::_walk(dir, "", 0, follow, &rels, &links)
        if !links.empty() {
            err = f"{LinkText::join(dir, links[0])} is a symlink; a schema 2 input holds none (links.tsv records them)"
            return ""
        }

        cxx::std::sort(rels.begin(), rels.end())

        var stream = ""
        for var r: string in rels {
            var fh = SysUtil::sha256_file(LinkText::join(dir, r))
            if fh.empty() {
                err = f"cannot read {LinkText::join(dir, r)}"
                return ""
            }

            stream += r
            stream += "\n"
            stream += fh
            stream += "\n"
        }

        return SysUtil::sha256(stream)
    }

    /// What tree_sha256 would read, by name, size and mtime only: the
    /// verification cache (SysRoot.md 4.3) re-hashes a dir only when this
    /// changes, which is a walk with no reads. A link under a schema 2
    /// input is in it, so a memo never hides one.
    pub static fn tree_stamp(const dir: string, follow: bool) -> string {
        var rels  = cxx::std::vector<string>()
        var links = cxx::std::vector<string>()
        SysUtil::_walk(dir, "", 0, follow, &rels, &links)
        cxx::std::sort(rels.begin(), rels.end())

        var stream = if (follow) => ("schema 1\n") else => "schema 2\n"
        for var r: string in rels {
            var p = LinkText::join(dir, r)
            stream += f"{r} {SysUtil::file_size(p)} {LinkFS::mtime(p)}\n"
        }

        for var l: string in links {
            stream += f"link {l}\n"
        }

        return SysUtil::sha256(stream)
    }

    pub static fn file_size(const p: string) -> u64 {
        var sz: u64 = 0
        var ec      = llvm::sys::fs::file_size(llvm::Twine(kairo::sref(p)), &sz)
        if ec.value() != 0 {
            return 0
        }

        return sz
    }

    /// A JSON string literal.
    pub static fn json_str(const s: string) -> string {
        var out = "\x22"
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            if c == ('\x22' as u8) || c == ('\\' as u8) {
                out += "\\"
                out.push_back(c)
            } else if c == ('\n' as u8) {
                out += "\\n"
            } else if c == ('\t' as u8) {
                out += "\\t"
            } else {
                out.push_back(c)
            }
        }

        out += "\x22"
        return out
    }

    /// A JSON array of strings, in the order given.
    pub static fn json_list(@inout xs: cxx::std::vector<string>) -> string {
        var out = "["
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 {
                out += ","
            }

            out += SysUtil::json_str(xs[i])
        }

        out += "]"
        return out
    }

    /// Canonical JSON object: keys sorted bytewise, no whitespace. Two runs
    /// that mean the same key spell it the same, whatever order the fields
    /// were added in.
    pub static fn json_object(@inout fields: cxx::std::vector<SysJsonField>) -> string {
        var keys = cxx::std::vector<string>()
        for var f: SysJsonField in fields {
            keys.push_back(f.key)
        }

        cxx::std::sort(keys.begin(), keys.end())
        var out = "{"
        for var i: usize = 0; i < keys.size(); ++i {
            if i > 0 {
                out += ","
            }

            for var f: SysJsonField in fields {
                if f.key == keys[i] {
                    out += SysUtil::json_str(f.key)
                    out += ":"
                    out += f.json
                    break
                }
            }
        }

        out += "}"
        return out
    }

    pub static fn field(@inout fields: cxx::std::vector<SysJsonField>,
                        const key:     string,
                        const json:    string) {
        var f = SysJsonField{}
        f.key  = key
        f.json = json
        fields.push_back(f)
    }

    pub static fn split(const s: string, sep: u8) -> cxx::std::vector<string> {
        var out       = cxx::std::vector<string>()
        var b:  usize = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] == sep {
                out.push_back(LinkText::slice(s, b, i))
                b = i + 1
            }
        }

        out.push_back(LinkText::slice(s, b, s.size()))
        return out
    }

    /// Every `{name}` in \p tmpl replaced by \p value.
    pub static fn fill(const tmpl: string, const name: string, const value: string) -> string {
        var pat       = "{" + name + "}"
        var out       = ""
        var i:  usize = 0
        while i < tmpl.size() {
            if i + pat.size() <= tmpl.size() && LinkText::slice(tmpl, i, i + pat.size()) == pat {
                out += value
                i += pat.size()
                continue
            }

            out.push_back(tmpl[i])
            i += 1
        }

        return out
    }

    /// Dotted numeric compare: "2.9" < "2.28" < "2.31".
    pub static fn version_less(const a: string, const b: string) -> bool {
        var pa = SysUtil::split(a, ('.' as u8))
        var pb = SysUtil::split(b, ('.' as u8))
        var n  = if (pa.size() > pb.size()) => (pa.size()) else => pb.size()
        for var i: usize = 0; i < n; ++i {
            var x = if (i < pa.size()) => (SysUtil::_num(pa[i])) else => 0
            var y = if (i < pb.size()) => (SysUtil::_num(pb[i])) else => 0
            if x != y {
                return x < y
            }
        }

        return false
    }

    pub static fn contains(@inout xs: cxx::std::vector<string>, const s: string) -> bool {
        for var x: string in xs {
            if x == s {
                return true
            }
        }

        return false
    }

    pub static fn joined(@inout xs: cxx::std::vector<string>, const sep: string) -> string {
        var out = ""
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 {
                out += sep
            }

            out += xs[i]
        }

        return out
    }

    priv static fn _num(const s: string) -> u64 {
        var v: u64 = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] < ('0' as u8) || s[i] > ('9' as u8) {
                break
            }

            v = v * 10 + ((s[i] - ('0' as u8)) as u64)
        }

        return v
    }

    /// Regular files under \p dir as `/`-joined paths relative to the
    /// walk's root, symlinks followed when \p follow, else each symlink's
    /// path into \p links and not descended. Depth-capped: a symlink loop
    /// in a share tree must end the walk, not the process.
    priv static fn _walk(const dir:    string,
                         const rel:    string,
                         depth:        u32,
                         follow:       bool,
                         @inout out:   cxx::std::vector<string>,
                         @inout links: cxx::std::vector<string>) {
        if depth > 64 {
            return
        }

        for var name: string in LinkFS::list_dir(dir) {
            var p = LinkText::join(dir, name)
            var r = if (rel.empty()) => (name) else => rel + "/" + name
            if !follow && llvm::sys::fs::is_symlink_file(llvm::Twine(kairo::sref(p))) {
                links.push_back(r)
            } else if LinkFS::is_dir(p) {
                SysUtil::_walk(p, r, depth + 1, follow, &out, &links)
            } else if LinkFS::is_file(p) {
                out.push_back(r)
            }
        }
    }

    /// One-shot llvm::SHA256::hash: the streaming API's digest method is
    /// spelled `final`, which Kairo reserves.
    priv static fn _hex(const d: cxx::std::array<u8, 32>) -> string {
        var s = llvm::toHex(llvm::ArrayRef<u8>(d.data(), d.size()), true)
        return kairo::std::from_std_string<string>(s)
    }
}
