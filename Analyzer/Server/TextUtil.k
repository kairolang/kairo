/// --- The Kairo Project -------------------- Analyzer/Server/TextUtil.k --- ///
///
///   Text helpers the server needs that are not Kairo-aware: search, case, top-level names, keywords.
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
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "chrono"

import API::FS::LinkFS
import DocumentStore::{
    DocumentStore,
    fnv1a,
    path_to_uri,
    uri_to_path,
}
import Index::Legend::*
import Index::Snapshot::*
import Protocol::*
import Tuning::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io
import Server::ClangdBridge::*
import Server::CodeActions::*
import Server::Completion::*
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
import Server::Lifecycle::*
import Server::Lookup::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::Tokens::*
import Server::Workers::*

/// Offset of \p needle in \p hay at or after \p from, or usize::MAX.
pub fn find_from(const hay: string, const needle: string, from: usize) -> usize {
    if needle.empty() || (needle.size() > hay.size()) {
        return usize::MAX
    }

    var last = hay.size() - needle.size()
    for var i: usize = from; i <= last; ++i {
        var m: usize = 0
        while (m < needle.size()) && (hay[i + m] == needle[m]) {
            m += 1
        }

        if m == needle.size() {
            return i
        }
    }

    return usize::MAX
}

/// A C or C++ source or header, by its extension.
pub fn is_cxx_source(const path: string) -> bool {
    var dot = path.rfind(46 as u8)
    var sl  = path.rfind(47 as u8)
    if (dot == usize::MAX) || ((sl != usize::MAX) && (dot < sl)) {
        return false
    }

    var ext = lower(path.subslice(dot + 1, path.size() - dot - 1))
    return (ext == "c") || (ext == "cc") || (ext == "cpp") || (ext == "cxx") || (ext == "c++") || (ext == "h")
        || (ext == "hh") || (ext == "hpp") || (ext == "hxx") || (ext == "ipp") || (ext == "m") || (ext == "mm")
}

/// The quoted `#include "x.k"` names of a C or C++ text, as written.
pub fn k_includes(const text: string) -> [string] {
    var out: [string]
    var all = quoted_includes(text)
    for var i: usize = 0; i < all.size(); ++i {
        if all[i].ends_with(".k") {
            out.push_back(all[i])
        }
    }

    return out
}

/// Every quoted `#include "x"` name of a C or C++ text, as written, in
/// order (the bridge follows headers to the `.k` files they include, P861).
/// Textual: a conditional block (`#ifdef __cplusplus`) is not evaluated.
pub fn quoted_includes(const text: string) -> [string] {
    var out: [string]
    var i: usize = 0
    var n = text.size()
    while i < n {
        var p = i
        while (p < n) && ((text[p] == 32) || (text[p] == 9)) {
            p += 1
        }

        var le = p
        while (le < n) && (text[le] != 10) {
            le += 1
        }

        if (p < le) && (text[p] == 35) {
            p += 1
            while (p < le) && ((text[p] == 32) || (text[p] == 9)) {
                p += 1
            }

            if ((p + 7) <= le) && (text.subslice(p, 7) == "include") {
                p += 7
                while (p < le) && ((text[p] == 32) || (text[p] == 9)) {
                    p += 1
                }

                if (p < le) && (text[p] == 34) {
                    var q = p + 1
                    while (q < le) && (text[q] != 34) {
                        q += 1
                    }

                    var name = text.subslice(p + 1, q - p - 1)
                    if (q < le) && (!name.empty()) {
                        out.push_back(name)
                    }
                }
            }
        }

        i = le + 1
    }

    return out
}

/// ASCII lower-casing: symbol search ignores case.
pub fn lower(const s: string) -> string {
    var out = string()
    for var i: usize = 0; i < s.size(); ++i {
        var c = s[i]
        if (c >= 65) && (c <= 90) {
            c = c + 32
        }

        out.push_back(c)
    }

    return out
}

/// Names a file declares at its top level, read from its text: a line that
/// starts (after an optional visibility keyword) with a declaring keyword and
/// a name. Private-looking names (a leading or trailing underscore) and
/// `priv` declarations are left out: an import cannot name them.
pub fn top_level_names(const src: string) -> [string] {
    var out: [string]
    var kws = keyword_list("fn class struct enum union interface type const var static eval macro module")
    var i: usize = 0
    var n = src.size()
    while i < n {
        // one line, which must start in column 0 to be top level
        var le = i
        while (le < n) && (src[le] != 10) {
            le += 1
        }

        var p = i
        var line = src.subslice(i, le - i)
        var hidden = line.starts_with("priv ")
        if line.starts_with("pub ") || line.starts_with("prot ") || line.starts_with("priv ") {
            while (p < le) && (src[p] != 32) {
                p += 1
            }

            p += 1
        }

        // skip modifiers before the declaring keyword (`inline fn`, `unsafe fn`)
        for var m: usize = 0; m < 3; ++m {
            var rest = src.subslice(p, le - p)
            if rest.starts_with("inline ") || rest.starts_with("unsafe ") || rest.starts_with("async ")
                || rest.starts_with("final ") || rest.starts_with("virtual ") {
                while (p < le) && (src[p] != 32) {
                    p += 1
                }

                p += 1
            }
        }

        var we = p
        while (we < le) && is_ident_byte(src[we]) {
            we += 1
        }

        var word = src.subslice(p, we - p)
        var declares = false
        for var k: usize = 0; k < kws.size(); ++k {
            if kws[k] == word {
                declares = true
            }
        }

        if declares && (!hidden) && (we < le) && (src[we] == 32) {
            var ns = we + 1
            // `fn <T> name(` : skip a generic list before the name
            if (ns < le) && (src[ns] == 60) {
                while (ns < le) && (src[ns] != 62) {
                    ns += 1
                }

                ns += 1
                while (ns < le) && (src[ns] == 32) {
                    ns += 1
                }
            }

            var ne = ns
            while (ne < le) && is_ident_byte(src[ne]) {
                ne += 1
            }

            var name = src.subslice(ns, ne - ns)
            if (ne > ns) && (name != "op") && (!name.starts_with("_")) && (!name.ends_with("_")) {
                var dup = false
                for var z: usize = 0; z < out.size(); ++z {
                    if out[z] == name {
                        dup = true
                    }
                }

                if !dup {
                    out.push_back(name)
                }
            }
        }

        i = le + 1
    }

    return out
}

pub fn keyword_list(const all: string) -> [string] {
    var k: [string]
    var cur = string()
    for var i: usize = 0; i < all.size(); ++i {
        if all[i] == 32 {
            if !cur.empty() {
                k.push_back(cur)
            }

            cur = string()
        } else {
            cur.push_back(all[i])
        }
    }

    if !cur.empty() {
        k.push_back(cur)
    }

    return k
}

pub fn is_ident_byte(c: u8) -> bool {
    return ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || ((c >= 48) && (c <= 57)) || (c == 95) || (c >= 128)
}

/// Offered wherever a bare name can start. The spellings are the language
/// reference's; the lexer has no table to read them from.
pub fn keywords() -> [string] {
    var k: [string]
    var all = "fn var const static eval if else unless while for loop match case default return break continue " +
        "class struct enum union interface extend impl derives module import ffi pub priv prot " +
        "unsafe inline virtual override final async await spawn yield try catch finally panic " +
        "true false null self Self as in is where requires type macro test delete sizeof alignof typeof " +
        "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char byte void string"
    var cur = string()
    for var i: usize = 0; i < all.size(); ++i {
        if all[i] == 32 {
            if !cur.empty() {
                k.push_back(cur)
            }

            cur = string()
        } else {
            cur.push_back(all[i])
        }
    }

    if !cur.empty() {
        k.push_back(cur)
    }

    return k
}

