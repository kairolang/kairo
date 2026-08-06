/// --- The Kairo Project -------------------- Token/TokenCacheManager.k --- ///
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

import Lexer::Lexer::*;

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
class TokenCacheManager {
    enum SlotState derives u8 {
        NotLexed  = 0,
        Streaming = 1,
        Ready     = 2,
        Failed    = 3
    }

    struct ScanStream {
        var lexer: own::<Lexer>          = &null;
        var imm:   own::<ImmediateTable> = &null;
    }


    struct Slot {
        var state:  SlotState                = SlotState::NotLexed;
        var lexer:  own::<Lexer>             = &null;
        var imm:    own::<ImmediateTable>    = &null;  // slot-owned, outlives the stream
        var tokens: own::<TokenBuffer::<512>> = &null; // PP output; null until Ready
    }

    var _lex_mu : std::SharedMutex;
    var _slots  : vec::<Slot>;
    var _pool   : obs::<ThreadPool>;
    var _sm     : obs::<SourceManager>;
    var _diag   : obs::<DiagEngine>;

    fn TokenCacheManager(self, sm: *SourceManager, pool: *ThreadPool, diag: *DiagEngine) {
        self._sm   = sm;
        self._pool = pool;
        self._diag = diag;
        /// TODO: tune these sizes on:
        /// 1. Hello world with full std
        /// 2. avg mid sized project with std + 3rd party deps
        /// 3. Stage1.5 self-hosting with std + macros + 3rd party deps - large project
        self._slots.reserve(1024); // 16KB
    }

    /// \brief transient scan-only stream. NEVER touches _slots the PP later
    ///        opens the real stream on this fid and asserts NotLexed.
    fn open_scan_stream(self, fid: u32) -> ScanStream {
        var s = ScanStream();
        var imm = std::create::<ImmediateTable>();
        imm->initialize(self._sm);
        var lexer = std::create::<Lexer>(self._sm, self._pool, self._diag, imm);
        if !lexer->open(fid) {
            std::destroy(lexer);
            std::destroy(imm);
            return s; // lexer == &null signals failure
        }
        s.lexer = lexer;
        s.imm   = imm;
        return s;
    }

    fn close_scan_stream(self, s: *ScanStream) {
        if s->lexer != &null {
            s->lexer->close();
            std::destroy(s->lexer);
            s->lexer = &null;
        }
        if s->imm != &null {
            std::destroy(s->imm);
            s->imm = &null;
        }
    }

    /// \brief opens a forward-only token stream for fid.
    /// \details slot transitions NotLexed -> Streaming. get_tokens(fid) returns
    ///          null (and asserts) until close_stream() moves it to Ready.
    ///          returns null on failure (slot -> Failed).
    fn open_stream(self, fid: u32) -> *Lexer {
        var wlock = std::UniqueLock(self._lex_mu);

        while self._slots.size() <= (fid as usize) {
            self._slots.push_back(Slot());
        }

        var st = self._slots[fid].state;
        std::ICE(st == SlotState::NotLexed, "open_stream: fid already open or closed");

        var imm = std::create::<ImmediateTable>();
        imm->initialize(self._sm);

        var lexer = std::create::<Lexer>(self._sm, self._pool, self._diag, imm);
        if !lexer->open(fid) {
            std::destroy(lexer);
            std::destroy(imm);
            self._slots[fid].state = SlotState::Failed;
            Logger::error(Logger::Stage::Lexer, f"TCM::open_stream: open failed fid={fid}");
            return &null;
        }

        self._slots[fid].imm   = imm;
        self._slots[fid].lexer = lexer;
        self._slots[fid].state = SlotState::Streaming;
        return lexer;
    }

    /// \brief the stream consumer (PP) hands back the expanded buffer.
    /// \details slot transitions Streaming -> Ready. lexer is destroyed;
    ///          the ImmediateTable is NOT indices are stable forever.
    fn close_stream(self, fid: u32, tokens: *TokenBuffer::<512>) {
        var wlock = std::UniqueLock(self._lex_mu);

        assert((self._slots[fid].state == SlotState::Streaming) && r"close_stream: fid not Streaming");

        self._slots[fid].lexer->close();
        std::destroy(self._slots[fid].lexer);
        self._slots[fid].lexer  = &null;

        self._slots[fid].tokens = tokens;
        self._slots[fid].state  = SlotState::Ready;
    }

    fn abort_stream(self, fid: u32) {
        var wlock = std::UniqueLock(self._lex_mu);
        if self._slots[fid].lexer != &null {
            std::destroy(self._slots[fid].lexer);
            self._slots[fid].lexer = &null;
        }
        self._slots[fid].state = SlotState::Failed;
    }

    fn get_tokens(self, fid: u32) -> *(TokenBuffer::<512>) {
        var rlock = std::SharedLock(self._lex_mu);

        if (fid as usize) >= self._slots.size() { return &null; }

        assert((self._slots[fid].state != SlotState::Streaming) && r"get_tokens: fid still Streaming");

        if self._slots[fid].state != SlotState::Ready { return &null; }
        return self._slots[fid].tokens;
    }

    /// \brief imm table for fid. valid from open_stream() onward, for the
    ///        lifetime of the TCM. append-safe while the stream is live.
    fn get_imm_table_for_fid(self, fid: u32) -> *ImmediateTable {
        var rlock = std::SharedLock(self._lex_mu);
        if (fid as usize) >= self._slots.size() { return &null; }
        return self._slots[fid].imm;   // valid even while Streaming
    }

    fn reset(self) {
        var wlock = std::UniqueLock(self._lex_mu);
        for slot: ref!(Slot) in _slots {
            if slot.lexer  != &null { std::destroy(slot.lexer);  slot.lexer  = &null; }
            if slot.tokens != &null { std::destroy(slot.tokens); slot.tokens = &null; }
            if slot.imm    != &null { std::destroy(slot.imm);    slot.imm    = &null; }
        }
        self._slots.clear();
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
    fn release(self, fid: u32) -> bool {
        var wlock = std::UniqueLock(self._lex_mu);

        if (fid as usize) >= self._slots.size() { return false; }

        var slot = &(self._slots[fid]);

        // Streaming means a lexer task is still writing this slot. Tearing it
        // down here would free the buffer under that thread.
        if slot->state == SlotState::Streaming { return false; }

        // Report whether there was ACTUALLY anything to drop. This used to
        // return true for any non-Streaming slot, including one already at
        // NotLexed holding nothing   which breaks the documented contract and
        // silently breaks callers that drive a "repeat until a pass frees
        // nothing" loop, since such a loop never sees a pass free nothing.
        // release_all() survived it only because its worklist (all_fids())
        // shrinks as contexts are erased; a caller iterating a fixed list
        // spins forever.
        var had = (slot->state  != SlotState::NotLexed)
               || (slot->lexer  != &null)
               || (slot->tokens != &null)
               || (slot->imm    != &null);

        if slot->lexer  != &null { std::destroy(slot->lexer);  slot->lexer  = &null; }
        if slot->tokens != &null { std::destroy(slot->tokens); slot->tokens = &null; }
        if slot->imm    != &null { std::destroy(slot->imm);    slot->imm    = &null; }

        slot->state = SlotState::NotLexed;
        return had;
    }

    /// Slots still holding lex products (tokens / imm table / lexer).
    ///
    /// Should be flat across a reparse loop: every pass releases what it lexed.
    /// A climbing count means release is missing fids, and each one is a whole
    /// token buffer plus identifier table.
    fn live_slots(self) -> usize {
        var rlock = std::SharedLock(self._lex_mu);
        var n: usize = 0;
        for slot: ref!(Slot) in _slots {
            if slot.state != SlotState::NotLexed { n += 1; continue; }
            if (slot.tokens != &null) || (slot.imm != &null) || (slot.lexer != &null) { n += 1; }
        }
        return n;
    }

    /// Total slots, i.e. the fid high-water mark.
    fn slot_count(self) -> usize {
        var rlock = std::SharedLock(self._lex_mu);
        return self._slots.size();
    }

    fn intern_ident(self, fid: u32, const data: *u8, len: usize, hash: u32) -> u32 {
        var tbl = self.get_imm_table_for_fid(fid);
        assert((tbl != &null) && r"intern_ident: no imm table for fid");
        return tbl->intern_ident(data, len, hash);
    }

    fn <T> create_imm(self, fid: u32) -> u32 {
        var tbl = self.get_imm_table_for_fid(fid);
        assert((tbl != &null) && r"create_imm: no imm table for fid");
        return tbl->create::<T>();
    }

    fn <T> get_imm(self, fid: u32, idx: u32) -> *T {
        var tbl = self.get_imm_table_for_fid(fid);
        assert((tbl != &null) && r"get_imm: no imm table for fid");
        return tbl->get::<T>(idx);
    }

    fn get_fid_for_token(self, tok: Token) -> u32 {
        return self._sm->get_fid(tok.range.start);
    }

    fn get_source_manager(self) -> *SourceManager {
        return self._sm;
    }

    fn get_imm_table_for_token(self, tok: Token) -> *ImmediateTable {
        var fid = self.get_fid_for_token(tok);
        return self.get_imm_table_for_fid(fid);
    }
}