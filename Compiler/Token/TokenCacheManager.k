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
/// cache is a flat slot vector indexed by fid — no hashing. lexing (discovery
/// phase) is serial by design; the shared mutex exists for the parallel
/// phases that follow: expansion (`replace_tokens`, writer) and parse
/// (`get_tokens` / `get_lexer_for_fid`, readers).
///
/// \note phase contract: `replace_tokens` must only run at the expansion
/// phase boundary, before parse consumes the fid's tokens. the lock protects
/// the slot table, not the contents of a `TokenBuffer` a reader already
/// holds a pointer to.
///
class TokenCacheManager {
    enum SlotState derives u8 {
        NotLexed = 0, ///< never attempted.
        Ready    = 1, ///< lexed successfully, lexer valid.
        Failed   = 2  ///< lex attempted and failed; cached negative.
    }

    struct Slot {
        var state: SlotState    = SlotState::NotLexed;
        var lexer: own::<Lexer> = &null;
    }

    var _lex_mu:      std::SharedMutex;
    var _slots:       vec::<Slot>;
    var _old_buffers: vec::<view::<TokenBuffer::<512>>>;
    var _pool:        obs::<ThreadPool>;
    var _sm:          obs::<SourceManager>;
    var _diag:        obs::<DiagEngine>;

    fn TokenCacheManager(self, sm: *SourceManager, pool: *ThreadPool, diag: *DiagEngine) {
        self._sm   = sm;
        self._pool = pool;
        self._diag = diag;
        /// TODO: tune these sizes on:
        /// 1. Hello world with full std
        /// 2. avg mid sized project with std + 3rd party deps
        /// 3. Stage1.5 self-hosting with std + macros + 3rd party deps - large project
        self._slots.reserve(1024);       // 16KB
        self._old_buffers.reserve(256);  // one entry per fid that gets macro-expanded
    }

    ///
    /// \brief ensures slot storage covers fids [0, count).
    ///
    /// \details optional; `lex_file` grows lazily. call after file
    /// registration if the fid count is known up front to avoid
    /// reallocation during discovery.
    ///
    fn reserve_fids(self, count: u32) {
        var wlock = std::UniqueLock(self._lex_mu);
        while self._slots.size() < (count as usize) {
            self._slots.push_back(Slot());
        }
    }

    fn lex_file(self, fid: u32) -> bool {
        {
            // fast path: cached result under shared lock
            var rlock = std::SharedLock(self._lex_mu);
            if (fid as usize) < self._slots.size() {
                var st = self._slots[fid].state;
                if st == SlotState::Ready {
                    Logger::debug(Logger::Stage::Lexer, f"TokenCacheManager::lex_file: cache hit fid={fid}");
                    return true;
                }
                if st == SlotState::Failed {
                    Logger::debug(Logger::Stage::Lexer, f"TokenCacheManager::lex_file: cached failure fid={fid}");
                    return false;
                }
            }
        }

        var wlock = std::UniqueLock(self._lex_mu);

        // grow to cover fid (discovery finds files incrementally)
        while self._slots.size() <= (fid as usize) {
            self._slots.push_back(Slot());
        }

        // re-check under write lock
        var st = self._slots[fid].state;
        if st == SlotState::Ready  { return true; }
        if st == SlotState::Failed { return false; }

        var lexer = std::create::<Lexer>(self._sm, self._pool, self._diag);
        var res: bool = false;

        try {
            res = lexer->lex(fid);
        } catch { // fallback: lex() should report via diag, not throw
            res = false;
        }

        if res {
            self._slots[fid].lexer = lexer;
            self._slots[fid].state = SlotState::Ready;
            Logger::debug(Logger::Stage::Lexer, f"TokenCacheManager::lex_file: lexed fid={fid}");
            return true;
        }

        std::destroy(lexer);
        self._slots[fid].state = SlotState::Failed;
        Logger::error(Logger::Stage::Lexer, f"TokenCacheManager::lex_file: lex failed fid={fid}");
        return false;
    }

    fn get_lexer_for_fid(self, fid: u32) -> *Lexer {
        var rlock = std::SharedLock(self._lex_mu);

        if (fid as usize) >= self._slots.size() { return &null; }
        if self._slots[fid].state != SlotState::Ready { return &null; }

        return self._slots[fid].lexer;
    }

    fn get_tokens(self, fid: u32) -> *(TokenBuffer::<512>) {
        var lexer = self.get_lexer_for_fid(fid);
        return (lexer->tokens()) if (lexer != &null) else (&null);
    }

    fn op [] (self, fid: u32) -> *(TokenBuffer::<512>) {
        return self.get_tokens(fid);
    }

    fn replace_tokens(self, fid: u32, new_tokens: *(TokenBuffer::<512>)) {
        var wlock = std::UniqueLock(self._lex_mu);

        if (fid as usize) >= self._slots.size() || self._slots[fid].state != SlotState::Ready {
            std::destroy(new_tokens);
            return;
        }

        self._slots[fid].lexer->tokens()->swap(new_tokens);
        self._old_buffers.push_back(new_tokens);
        // old buffers intentionally retained: MacroDefinition body spans
        // still reference them. destroyed at shutdown/reset. do not free here.
    }

    /// \brief returns the ImmediateTable for the file that owns this token
    /// \details resolves via the token's range -> fid lookup in the SourceManager.
    /// cold path — inside a per-TU loop, resolve once via get_imm_table_for_fid
    /// and carry the pointer instead.
    fn get_imm_table_for_token(self, tok: Token, sm: *SourceManager = &null) -> *ImmediateTable {
        if sm == &null { sm = self._sm; }
        if sm == &null { return &null; }
        return self.get_imm_table_for_fid(sm->get_fid(tok.range.start));
    }

    fn get_imm_table_for_fid(self, fid: u32) -> *ImmediateTable {
        var lexer = self.get_lexer_for_fid(fid);
        return (lexer->get_imm_tbl()) if (lexer != &null) else (&null);
    }

    fn get_source_manager(self) -> *SourceManager {
        return self._sm;
    }

    /// \brief convenience gets the fid for a token
    fn get_fid_for_token(self, tok: Token, sm: *SourceManager) -> u32 {
        return sm->get_fid(tok.range.start);
    }

    fn reset(self) {
        var wlock = std::UniqueLock(self._lex_mu);
        Logger::debug(Logger::Stage::Lexer, f"TokenCacheManager::reset: releasing {self._slots.size()} slots");

        for slot: ref!(Slot) in _slots {
            if slot.lexer != &null {
                std::destroy(slot.lexer);
                slot.lexer = &null;
            }
        }
        self._slots.clear();

        for buf in self._old_buffers {
            std::destroy(buf);
        }
        self._old_buffers.clear();
    }

    fn op delete (self) {
        self.reset();
    }
}