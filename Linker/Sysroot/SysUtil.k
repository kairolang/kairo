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
///   an error (a Windows unzip turns a link into a file holding its
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
    /// sha256 of `s`, 64 lowercase hex.
    pub static fn sha256(const s: string) -> string {
        return SysUtil::_hex(
            llvm::SHA256::hash(llvm::arrayRefFromStringRef(kairo::sref(s))),
        )
    }

    /// sha256 of the file's bytes; "" when it cannot be read.
    pub static fn sha256_file(const path: string) -> string {
        var mb = llvm::MemoryBuffer::getFile(
            llvm::Twine(kairo::sref(path)),
            false,
            false,
        )

        if mb.getError().value() != 0 {
            return ""
        }

        return SysUtil::_hex(
            llvm::SHA256::hash(
                llvm::arrayRefFromStringRef(mb.get()->getBuffer()),
            ),
        )
    }

    /// The share tree's tree_sha256 of `dir` (FORMAT.md). `follow` is
    /// schema 1's rule; without it (schema 2) a symlink below `dir` is an
    /// error naming it. `dir` itself may be one: a share view links whole
    /// inputs in. "" with `err` set on either failure.
    pub static fn tree_sha256(const dir: string, follow: bool, @inout err: string) -> string {
        var rels:  [string]
        var links: [string]
        SysUtil::_walk(dir, "", 0, follow, &rels, &links)
        if !links.is_empty() {
            err = f"{LinkText::join(dir.copy(), links[0].copy())} is a symlink; a schema 2 input holds none (links.tsv records them)"
            return ""
        }

        SysUtil::sort(&rels)

        var stream = ""
        for r in rels {
            var fh = SysUtil::sha256_file(LinkText::join(dir.copy(), r.copy()))
            if fh.is_empty() {
                err = f"cannot read {LinkText::join(dir.copy(), r.copy())}"
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
        var rels:  [string]
        var links: [string]
        SysUtil::_walk(dir, "", 0, follow, &rels, &links)
        SysUtil::sort(&rels)

        var stream = if (follow) => ("schema 1\n") else => "schema 2\n"
        for *r in rels {
            var p = LinkText::join(dir.copy(), r->copy())
            stream += f"{*r} {SysUtil::file_size(p)} {LinkFS::mtime(p)}\n"
        }

        for *l in links {
            stream += f"link {*l}\n"
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
        var out        = "\x22"
        var run: usize = 0      ///< the first byte of `s` not yet in `out`
        for var i: usize = 0; i < s.size(); ++i {
            var c   = s.data()[i]
            var esc = ""
            if c == ('\x22' as u8) {
                esc = "\\\x22"
            } else if c == ('\\' as u8) {
                esc = "\\\\"
            } else if c == ('\n' as u8) {
                esc = "\\n"
            } else if c == ('\t' as u8) {
                esc = "\\t"
            } else {
                continue
            }

            out += s[run..i]
            out += esc
            run = i + 1
        }

        out += s[run..]
        out += "\x22"
        return out
    }

    /// A JSON array of strings, in the order given.
    pub static fn json_list(const xs: [string]) -> string {
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
    pub static fn json_object(const fields: [SysJsonField]) -> string {
        var keys: [string]
        for const *f in fields {
            keys.push(f->key.copy())
        }

        SysUtil::sort(&keys)
        var out = "{"
        for var i: usize = 0; i < keys.size(); ++i {
            if i > 0 {
                out += ","
            }

            for const *f in fields {
                if f->key == keys[i] {
                    out += SysUtil::json_str(f->key)
                    out += ":"
                    out += f->json
                    break
                }
            }
        }

        out += "}"
        return out
    }

    pub static fn field(@inout fields: [SysJsonField], const key: string, const json: string) {
        var f = SysJsonField{}
        f.key  = key.copy()
        f.json = json.copy()
        fields.push(f)
    }

    /// `v` in byte order.
    pub static fn sort(@inout v: [string]) {
        v.sort()
    }

    /// The entries of `dir`, as a Kairo list.
    pub static fn list_dir(const dir: string) -> [string] {
        var names = LinkFS::list_dir(dir)
        return SysUtil::strings(names)
    }

    /// A Kairo list of copies of `v`'s strings.
    pub static fn strings(const v: cxx::std::vector<string>) -> [string] {
        var out: [string]
        for *s in v {
            out.push(s->copy())
        }

        return out
    }

    /// `strings(v)`, leaving `v` empty.
    pub static fn taken(@inout v: cxx::std::vector<string>) -> [string] {
        var out = SysUtil::strings(v)
        v.clear()
        return out
    }

    /// The same strings as a C++ vector, for an API that takes one.
    pub static fn to_cxx(const v: [string]) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        for const *s in v {
            out.push_back(s->copy())
        }

        return out
    }

    pub static fn split(const s: string, sep: u8) -> [string] {
        var out: [string]
        var b:   usize    = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s.data()[i] == sep {
                out.push(LinkText::slice(s, b, i))
                b = i + 1
            }
        }

        out.push(LinkText::slice(s, b, s.size()))
        return out
    }

    /// Every `{name}` in `tmpl` replaced by `value`.
    pub static fn fill(const tmpl: string, const name: string, const value: string) -> string {
        var pat        = "{" + name + "}"
        var out        = ""
        var i:   usize = 0
        var run: usize = 0                ///< the first byte of `tmpl` not yet in `out`
        while i < tmpl.size() {
            if i + pat.size() <= tmpl.size() && LinkText::slice(tmpl, i, i + pat.size()) == pat {
                out += tmpl[run..i]
                out += value
                i += pat.size()
                run = i
                continue
            }

            i += 1
        }

        out += tmpl[run..]
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

    pub static fn contains(const xs: [string], const s: string) -> bool {
        for const *x in xs {
            if *x == s {
                return true
            }
        }

        return false
    }

    pub static fn joined(const xs: [string], const sep: string) -> string {
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
            if s.data()[i] < ('0' as u8) || s.data()[i] > ('9' as u8) {
                break
            }

            v = v * 10 + ((s.data()[i] - ('0' as u8)) as u64)
        }

        return v
    }

    /// Regular files under `dir` as `/`-joined paths relative to the
    /// walk's root, symlinks followed when `follow`, else each symlink's
    /// path into `links` and not descended. Depth-capped: a symlink loop
    /// in a share tree must end the walk, not the process.
    priv static fn _walk(const dir:    string,
                         const rel:    string,
                         depth:        u32,
                         follow:       bool,
                         @inout out:   [string],
                         @inout links: [string]) {
        if depth > 64 {
            return
        }

        for *name in LinkFS::list_dir(dir) {
            var p = LinkText::join(dir.copy(), name->copy())
            var r = if (rel.is_empty()) => (name->copy()) else => rel.copy() + "/" + *name
            if !follow && llvm::sys::fs::is_symlink_file(llvm::Twine(kairo::sref(p))) {
                links.push(r)
            } else if LinkFS::is_dir(p) {
                SysUtil::_walk(p, r, depth + 1, follow, &out, &links)
            } else if LinkFS::is_file(p) {
                out.push(r)
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
