/// --- The Kairo Project ---------------------- Codegen/Sink/HashSink.k --- ///
///
///   \brief EmitSink that hashes what it is given: the incremental object
///          cache's view of one TU's stream (Compiler/Spec/Incremental.md#object-key).
///
///   The stream a TU's fill writes is everything clang is given to compile
///   it apart from the headers and the options: its own bodies, every
///   interface entry and body of another module its plan names (only
///   those: a plan names what the TU uses), its tier-3 instantiations and
///   `extern template`s, and every fact Sema and the lowerings inferred
///   (they change the C++ the emitters write). Hashing that stream instead
///   of a list of Kairo-level facts is what makes the key cover inferred
///   facts without naming them.
///
///   Each token goes in as its spelling and a separator: C++ tokens never
///   hold a raw newline, so the byte string reads back as one token list
///   and two streams hash alike only when they are the same tokens.
///   Directives (`#include <...>`, a text sink's lines) are tagged so they
///   never alias a token.
///
///   With debug info (\p with_locs) the object's line tables hold the
///   tokens' positions, so each anchored token adds its file and
///   line:column: an edit that moves a declaration recompiles what records
///   its line, and one that moves nothing does not. Line starts are
///   computed here from the file's bytes, once per file per sink, because
///   SourceManager::get_line_col builds a Path (a stat) per call.
///
///   It also notes which files the anchored tokens came from (files()):
///   the modules and headers the stream draws on, from which ObjectCache
///   decides which header files the TU's key holds.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "Native/KObjCache.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import Codegen::Sink::EmitSink::EmitSink
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Support::FileIO::VirtualFileManager::VirtualFileManager
import Token::Token::Token
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenText::TokenText

pub class HashSink derives EmitSink {
    priv var _sm:         unsafe *SourceManager
    priv var _tcm:        unsafe *TokenCacheManager
    priv var _locs:       bool                      = false
    priv var _unanchored: bool                      = false
    /// Bytes not folded into _acc yet; folded every MiB, so a TU's stream
    /// never sits in memory whole (the compiler's largest is tens of MiB of
    /// text, times every worker).
    priv var _buf:    string = ""
    priv var _acc:    string = ""
    priv var _tokens: usize  = 0
    /// -g only: per fid, the index into _starts (-1 unseen), and each
    /// seen file's line starts.
    priv var _fid_ix: cxx::std::vector<i64>
    priv var _starts: cxx::std::vector<cxx::std::vector<u32>>
    /// Per fid: 1 once a token anchored in that file went into the stream
    /// (files()). Which modules (and headers) the stream draws on decides
    /// which header files the TU's key holds (ObjectCache::tu_headers).
    priv var _seen: cxx::std::vector<u8>

    pub fn HashSink(self,
                    sm:        unsafe *SourceManager,
                    tcm:       unsafe *TokenCacheManager,
                    with_locs: bool) {
        self._sm   = sm
        self._tcm  = tcm
        self._locs = with_locs
    }

    /// The stream's hash, 32 hex digits. Call once, after the fill.
    pub fn digest(self) -> string {
        self._fold()
        return self._acc + f"-{self._tokens}"
    }

    pub fn token_count(self) -> usize {
        return self._tokens
    }

    /// Every file an anchored token of the stream came from, ascending.
    pub fn files(self) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        for var i: usize = 0; i < self._seen.size(); ++i {
            if self._seen[i] != (0 as u8) {
                out.push_back(i as u32)
            }
        }

        return out
    }

    override fn create(self, t: Token) -> bool {
        self._tok(*TokenText::resolve(t, self._tcm).get_text(), t.range)
        return true
    }

    override fn create_ident(self, at: SourceRange, const spelling: string) -> bool {
        self._tok(spelling, at)
        return true
    }

    override fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *p = clang::tok::getPunctuatorSpelling(k)
        if p == &null {
            self.ice_at(at, "HashSink::punct: kind has no punctuator spelling")
        }

        self._tok(string(unsafe ((p as unsafe *const u8) as *const u8)), at)
        return true
    }

    override fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *kw = clang::tok::getKeywordSpelling(k)
        if kw == &null {
            self.ice_at(at, "HashSink::keyword: kind is not a keyword")
        }

        self._tok(string(unsafe ((kw as unsafe *const u8) as *const u8)), at)
        return true
    }

    override fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self._tok(*TokenText::from_range(at, self._sm).get_text(), at)
        return true
    }

    override fn create_int(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._tok(cxx_v, at)
        return true
    }

    override fn create_str(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._tok(cxx_v, at)
        return true
    }

    override fn create_char(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._tok(cxx_v, at)
        return true
    }

    override fn directive(self, at: SourceRange, const text: string) -> bool {
        self._buf += "\n#d "
        self._buf += text
        self._buf += "\n"
        return true
    }

    /// TokenSink enters these ahead of the stream; they are part of what
    /// clang compiles.
    override fn system_header(self, at: SourceRange, const name: string) -> bool {
        self._buf += "\n#s "
        self._buf += name
        self._buf += "\n"
        return true
    }

    override fn unanchored(self, on: bool) {
        self._unanchored = on
    }

    override fn is_unanchored(self) -> bool {
        return self._unanchored
    }

    priv fn _tok(self, const s: string, at: SourceRange) {
        self._tokens += 1
        self._buf += s
        // An unanchored token takes an arena location, which is a pure
        // function of the stream already hashed: nothing to add.
        if !self._unanchored {
            var res = self._sm->resolve(at.start)
            if res.fid != usize::MAX {
                while self._seen.size() <= res.fid {
                    self._seen.push_back(0 as u8)
                }

                self._seen[res.fid] = (1 as u8)
            }

            if self._locs {
                self._buf += self._where(res)
            }
        }

        self._buf += "\n"
        if self._buf.size() >= 1048576 {
            self._fold()
        }
    }

    priv fn _fold(self) {
        if self._buf.size() == 0 && self._acc.size() > 0 {
            return
        }

        var chunk = self._acc + self._buf
        self._acc = kairo::std::from_std_string<string>(kairo::objcache_hash128(kairo::sref(chunk)))
        self._buf = ""
    }

    /// ` @<file>:<line>:<col>`; a file is named once, when first seen, and
    /// by its index in first-seen order after that, which the stream
    /// already orders.
    priv fn _where(self, res: VirtualFileManager::SegmentResolve) -> string {
        if res.fid == usize::MAX {
            return " @-"
        }

        var fid   = res.fid
        var named = ""
        while self._fid_ix.size() <= fid {
            self._fid_ix.push_back(-1 as i64)
        }

        if self._fid_ix[fid] < 0 {
            self._fid_ix[fid] = (self._starts.size() as i64)
            self._starts.push_back(self._line_starts(fid as u32))
            named = "=" + self._sm->get_filename(fid as u32)
        }

        var ix  = (self._fid_ix[fid] as usize)
        var *st = &self._starts[ix]
        // The last line start at or before the offset.
        var off       = (res.offset as u32)
        var lo: usize = 0
        var hi: usize = st->size()
        while lo + 1 < hi {
            var mid = (lo + hi) / 2
            if (*st)[mid] <= off {
                lo = mid
            } else {
                hi = mid
            }
        }

        var col = off - (*st)[lo]
        return f" @{ix}{named}:{lo + 1}:{col + 1}"
    }

    priv fn _line_starts(self, fid: u32) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        out.push_back(0 as u32)
        var buf? = self._sm->get_buffer(fid)
        if buf == null || !buf.is_valid() {
            return out
        }

        var unsafe *p = (buf.data() as unsafe *const u8)
        var        n  = buf.size()
        for var i: usize = 0; i < n; ++i {
            if p[i] == ('\n' as u8) {
                out.push_back((i + 1) as u32)
            }
        }

        return out
    }
}
