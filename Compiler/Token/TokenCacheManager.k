/// --- The Kairo Project -------------------- Token/TokenCacheManager.k --- ///
///
///   TokenCacheManager: the per-file cache of lexers and token buffers.
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
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"

import Diagnostic::Engine::DiagEngine
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceManager::SourceManager
import Support::TimeReport::{
    time_enabled,
    time_region,
}
import Threading::ThreadPool::ThreadPool
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer

/// One page of the fid -> ImmediateTable mirror (TokenCacheManager::_imm_dir).
pub class ImmPage {
    pub var e: cxx::std::array<kairo::std::Atomic<unsafe *ImmediateTable>, 4096> = cxx::std::array<kairo::std::Atomic<unsafe *ImmediateTable>, 4096>()
}

///
/// \class TokenCacheManager
/// \brief per-fid cache of lexers and their token buffers.
///
/// \details
/// fids are dense sequential u32s minted by the VirtualFileManager, so the
/// cache is a flat slot vector indexed by fid no hashing. lexing (discovery
/// phase) is serial by design; the shared mutex exists for the parallel
/// phases that follow: expansion.
///
pub class TokenCacheManager {
    enum SlotState derives u8 {
        NotLexed  = 0,
        Streaming = 1,
        Ready     = 2,
        Failed    = 3
    }

    struct ScanStream {
        pub var lexer: unsafe *Lexer          = &null
        var     imm:   unsafe *ImmediateTable = &null
    }


    struct Slot {
        var state:  SlotState                = SlotState::NotLexed
        var lexer:  unsafe *Lexer            = &null
        var imm:    unsafe *ImmediateTable   = &null // slot-owned, outlives the stream
        var tokens: unsafe *TokenBuffer<512> = &null // PP output; null until Ready
    }

    var _lex_mu: kairo::std::SharedMutex
    /// fid -> its ImmediateTable, read with NO lock. get_imm_table_for_token
    /// runs for every identifier a token spells, from every worker, and took
    /// _lex_mu shared each time; libc++'s shared_mutex is a mutex + condvars, so
    /// every lock_shared / unlock_shared serialized on one internal mutex. glibc
    /// spins that contention away, musl sleeps on it: ~95% of the static musl
    /// compiler's 78k futex waits (2x glibc's kernel time) were here. The lock
    /// only ever guarded _slots' growth, never the table (a caller uses it after
    /// unlocking), so a mirror whose pages never move reads the same pointer.
    /// Written under _lex_mu wherever a slot's imm changes (_publish_imm);
    /// 1024 pages x 4096 fids, a page allocated on first use and freed with the TCM.
    var _imm_dir: cxx::std::array<kairo::std::Atomic<unsafe *ImmPage>, 1024> = cxx::std::array<kairo::std::Atomic<unsafe *ImmPage>, 1024>()
    var _slots: cxx::std::vector<Self::Slot>
    var _pool:  *ThreadPool
    var _sm:    unsafe *SourceManager
    var _diag:  *DiagEngine

    fn op finally (self) {
        for var i: usize = 0; i < 1024; ++i {
            var unsafe *page = self._imm_dir[i].load(kairo::std::MemoryOrder::relaxed)
            if page != &null {
                kairo::std::destroy(page)
            }
        }
    }

    /// Mirrors slot \p fid's imm into _imm_dir. Caller holds _lex_mu exclusively.
    priv fn _publish_imm(self, fid: u32, imm: unsafe *ImmediateTable) {
        var pi = (fid as usize) >> 12
        if pi >= 1024 {
            kairo::std::ice_fail("TokenCacheManager: more than 4M file ids")
        }

        var unsafe *page = self._imm_dir[pi].load(kairo::std::MemoryOrder::relaxed)
        if page == &null {
            if imm == &null {
                return
            }

            page = kairo::std::create<ImmPage>()
            self._imm_dir[pi].store(page, kairo::std::MemoryOrder::release)
        }

        page->e[(fid as usize) & 4095].store(imm, kairo::std::MemoryOrder::release)
    }

    fn TokenCacheManager(self, sm: unsafe *SourceManager, pool: *ThreadPool, diag: *DiagEngine) {
        self._sm   = sm
        self._pool = pool
        self._diag = diag
        /// TODO: tune these sizes on:
        /// 1. Hello world with full std
        /// 2. avg mid sized project with std + 3rd party deps
        /// 3. Stage1.5 self-hosting with std + macros + 3rd party deps - large project
        self._slots.reserve(1024) // 16KB
    }

    /// \brief transient scan-only stream. NEVER touches _slots the PP later
    ///        opens the real stream on this fid and asserts NotLexed.
    pub fn open_scan_stream(self, fid: u32) -> Self::ScanStream {
        var        s    = Self::ScanStream()
        var unsafe *imm = kairo::std::create<ImmediateTable>()
        imm->initialize(self._sm)
        var unsafe *lexer = kairo::std::create<Lexer>(self._sm, self._pool, self._diag, imm)

        // Bound explicitly, under the caller's region (DepScan), so this scan
        // lex does not merge with the walk's lex into a single row. They are
        // two full tokenizations of the same bytes and the report has to say
        // so   see the comment on open_scan_stream above.
        if time_enabled() {
            lexer->bind_time_region(time_region("Lex"))
        }

        if !lexer->open(fid) {
            kairo::std::destroy(lexer)
            kairo::std::destroy(imm)
            return s // lexer == &null signals failure
        }

        s.lexer = lexer
        s.imm   = imm
        return s
    }

    pub fn close_scan_stream(self, s: *Self::ScanStream) {
        if s->lexer != &null {
            s->lexer->close()
            kairo::std::destroy(s->lexer)
            s->lexer = &null
        }

        if s->imm != &null {
            kairo::std::destroy(s->imm)
            s->imm = &null
        }
    }

    /// \brief opens a forward-only token stream for fid.
    /// \details slot transitions NotLexed -> Streaming. get_tokens(fid) returns
    ///          null (and asserts) until close_stream() moves it to Ready.
    ///          returns null on failure (slot -> Failed).
    pub fn open_stream(self, fid: u32) -> unsafe *Lexer {
        var wlock = kairo::std::UniqueLock(self._lex_mu)

        while self._slots.size() <= (fid as usize) {
            self._slots.push_back(Self::Slot())
        }

        var st = self._slots[fid].state
        if st != Self::SlotState::NotLexed {
            kairo::std::ice_fail("open_stream: fid already open or closed")
        }

        var unsafe *imm = kairo::std::create<ImmediateTable>()
        imm->initialize(self._sm)

        var unsafe *lexer = kairo::std::create<Lexer>(self._sm, self._pool, self._diag, imm)
        if !lexer->open(fid) {
            kairo::std::destroy(lexer)
            kairo::std::destroy(imm)
            self._slots[fid].state = Self::SlotState::Failed
            kairo::Logger::error(
                kairo::Logger::Stage::Lexer,
                f"TCM::open_stream: open failed fid={fid}",
            )

            return &null
        }

        self._slots[fid].imm = imm
        self._publish_imm(fid, imm)
        self._slots[fid].lexer = lexer
        self._slots[fid].state = Self::SlotState::Streaming
        return lexer
    }

    /// \brief the stream consumer (PP) hands back the expanded buffer.
    /// \details slot transitions Streaming -> Ready. lexer is destroyed;
    ///          the ImmediateTable is NOT indices are stable forever.
    pub fn close_stream(self, fid: u32, tokens: unsafe *TokenBuffer<512>) {
        var wlock = kairo::std::UniqueLock(self._lex_mu)

        eval if defined!(DEBUG) {
            if !(self._slots[fid].state == Self::SlotState::Streaming) {
                kairo::std::ice_fail(r"close_stream: fid not Streaming")
            }
        }

        self._slots[fid].lexer->close()
        kairo::std::destroy(self._slots[fid].lexer)
        self._slots[fid].lexer = &null

        self._slots[fid].tokens = tokens
        self._slots[fid].state  = Self::SlotState::Ready
    }

    fn abort_stream(self, fid: u32) {
        var wlock = kairo::std::UniqueLock(self._lex_mu)
        if self._slots[fid].lexer != &null {
            kairo::std::destroy(self._slots[fid].lexer)
            self._slots[fid].lexer = &null
        }

        self._slots[fid].state = Self::SlotState::Failed
    }

    pub fn get_tokens(self, fid: u32) -> unsafe *(TokenBuffer<512>) {
        var rlock = kairo::std::SharedLock(self._lex_mu)

        if (fid as usize) >= self._slots.size() {
            return &null
        }

        eval if defined!(DEBUG) {
            if !(self._slots[fid].state != Self::SlotState::Streaming) {
                kairo::std::ice_fail(r"get_tokens: fid still Streaming")
            }
        }

        if self._slots[fid].state != Self::SlotState::Ready {
            return &null
        }

        return self._slots[fid].tokens
    }

    /// \brief imm table for fid. valid from open_stream() onward, for the
    ///        lifetime of the TCM. append-safe while the stream is live.
    pub fn get_imm_table_for_fid(self, fid: u32) -> unsafe *ImmediateTable {
        // Lock-free: see _imm_dir. Valid even while Streaming.
        var pi = (fid as usize) >> 12
        if pi >= 1024 {
            return &null
        }

        var unsafe *page = self._imm_dir[pi].load(kairo::std::MemoryOrder::acquire)
        if page == &null {
            return &null
        }

        return page->e[(fid as usize) & 4095].load(kairo::std::MemoryOrder::acquire)
    }

    /// A fid that is not Kairo source (a C++ header): an identifier table
    /// with no lexer and no tokens. Idempotent.
    pub fn ensure_imm_table(self, fid: u32) {
        var wlock = kairo::std::UniqueLock(self._lex_mu)
        while self._slots.size() <= (fid as usize) {
            self._slots.push_back(Self::Slot())
        }

        if self._slots[fid].imm != &null {
            return
        }

        var unsafe *imm = kairo::std::create<ImmediateTable>()
        imm->initialize(self._sm)
        self._slots[fid].imm = imm
        self._publish_imm(fid, imm)
        if self._slots[fid].state == Self::SlotState::NotLexed {
            self._slots[fid].state = Self::SlotState::Ready
        }
    }

    fn reset(self) {
        var wlock = kairo::std::UniqueLock(self._lex_mu)
        for var f: usize = 0; f < self._slots.size(); ++f {
            if self._slots[f].imm != &null {
                self._publish_imm(f as u32, &null)
            }
        }

        for *slot in self._slots {
            if slot->lexer != &null {
                kairo::std::destroy(slot->lexer)
                slot->lexer = &null
            }

            if slot->tokens != &null {
                kairo::std::destroy(slot->tokens)
                slot->tokens = &null
            }

            if slot->imm != &null {
                kairo::std::destroy(slot->imm)
                slot->imm = &null
            }
        }

        self._slots.clear()
    }

    /// \brief drops one fid's lex products: tokens, lexer, and imm table.
    ///
    /// \details The slot is reset IN PLACE, never erased   `_slots` is indexed
    ///          by fid, so erasing would renumber every later file.
    ///
    ///          CALLER CONTRACT: every AST built from this fid must already be
    ///          gone. Tokens address identifiers by `imm` index into this
    ///          slot's ImmediateTable, so an AST outliving its imm table has
    ///          unresolvable names   `tok()`/`istr()` would read freed memory.
    ///          CompilerInstance::release enforces the ordering; do not call
    ///          this directly out of order.
    ///
    /// \return false if the fid was never lexed (nothing to do).
    pub fn release(self, fid: u32) -> bool {
        var wlock = kairo::std::UniqueLock(self._lex_mu)

        if (fid as usize) >= self._slots.size() {
            return false
        }

        var *slot = &self._slots[fid]

        // Streaming means a lexer task is still writing this slot. Tearing it
        // down here would free the buffer under that thread.
        if slot->state == Self::SlotState::Streaming {
            return false
        }

        // Report whether there was ACTUALLY anything to drop. This used to
        // return true for any non-Streaming slot, including one already at
        // NotLexed holding nothing   which breaks the documented contract and
        // silently breaks callers that drive a "repeat until a pass frees
        // nothing" loop, since such a loop never sees a pass free nothing.
        // release_all() survived it only because its worklist (all_fids())
        // shrinks as contexts are erased; a caller iterating a fixed list
        // spins forever.
        var had = slot->state != Self::SlotState::NotLexed
            || slot->lexer != &null
            || slot->tokens != &null
            || slot->imm != &null

        if slot->lexer != &null {
            kairo::std::destroy(slot->lexer)
            slot->lexer = &null
        }

        if slot->tokens != &null {
            kairo::std::destroy(slot->tokens)
            slot->tokens = &null
        }

        if slot->imm != &null {
            self._publish_imm(fid, &null)
            kairo::std::destroy(slot->imm)
            slot->imm = &null
        }

        slot->state = Self::SlotState::NotLexed
        return had
    }

    /// Slots still holding lex products (tokens / imm table / lexer).
    ///
    /// Should be flat across a reparse loop: every pass releases what it lexed.
    /// A climbing count means release is missing fids, and each one is a whole
    /// token buffer plus identifier table.
    fn live_slots(self) -> usize {
        var rlock       = kairo::std::SharedLock(self._lex_mu)
        var n:    usize = 0
        for *slot in self._slots {
            if slot->state != Self::SlotState::NotLexed {
                n += 1
                continue
            }

            if slot->tokens != &null || slot->imm != &null || slot->lexer != &null {
                n += 1
            }
        }

        return n
    }

    /// Total slots, i.e. the fid high-water mark.
    fn slot_count(self) -> usize {
        var rlock = kairo::std::SharedLock(self._lex_mu)
        return self._slots.size()
    }

    pub fn intern_ident(self, fid: u32, data: unsafe *const u8, len: usize, hash: u32) -> u32 {
        var unsafe *tbl = self.get_imm_table_for_fid(fid)
        eval if defined!(DEBUG) {
            if !(tbl != &null) {
                kairo::std::ice_fail(r"intern_ident: no imm table for fid")
            }
        }

        return tbl->intern_ident(data, len, hash)
    }

    fn <T> create_imm(self, fid: u32) -> u32 {
        var unsafe *tbl = self.get_imm_table_for_fid(fid)
        eval if defined!(DEBUG) {
            if !(tbl != &null) {
                kairo::std::ice_fail(r"create_imm: no imm table for fid")
            }
        }

        return tbl->create<T>()
    }

    fn <T> get_imm(self, fid: u32, idx: u32) -> unsafe *T {
        var unsafe *tbl = self.get_imm_table_for_fid(fid)
        eval if defined!(DEBUG) {
            if !(tbl != &null) {
                kairo::std::ice_fail(r"get_imm: no imm table for fid")
            }
        }

        return tbl->get<T>(idx)
    }

    fn get_fid_for_token(self, tok: Token) -> u32 {
        return self._sm->get_fid(tok.range.start)
    }

    fn get_source_manager(self) -> unsafe *SourceManager {
        return self._sm
    }

    pub fn get_imm_table_for_token(self, tok: Token) -> unsafe *ImmediateTable {
        var fid = self.get_fid_for_token(tok)
        return self.get_imm_table_for_fid(fid)
    }
}
