/// --- The Kairo Project --------------------- AST/Context/ASTContext.k --- ///
///
///   ----------------------------------------------------------------------
///   ASTContext is a long-lived object that owns all AST nodes and provides
///   utilities for node creation, interning, and memory management.
///   ----------------------------------------------------------------------
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/MapVector.h"
ffi "c++" import "Native/KPlacement.hh" // construct_at, destroy_in_place
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "cstring"
ffi "c++" import "utility"

import AST::Context::DisambigTable::DisambigTable
import AST::Context::TranslationUnit::TranslationUnit
import Config::Invocation::CompilerInvocation
import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Driver::TUStage::TUStage // standalone enum, no imports of its own; no cycle
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Memory::ArenaAllocator::ArenaAllocator
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Support::EvalHash::compute_hash
import Support::FileIO::Path::Path
import Token::Token::Token
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind
import Token::TokenSpan::TokenSpan
import Token::TokenText::{
    TokenText,
    unwrap_expansion,
}

pub class ASTContext {
    pub var source_path: Path
    pub var module_base: ModulePath

    /// `module_base`'s LEAF segment, interned into THIS file's imm table.
    /// ModulePath segments carry PreprocessorSymbolTable SymbolIDs, which are
    /// a different name domain from an imm index; a synthesized module name
    /// token built from one spells as the interner's fallback text. The PP
    /// writes this once, next to module_base. u32(-1) = anonymous root file.
    pub var module_leaf_imm: u32 = u32::MAX

    /// This is the general allocators for the compiler pipeline.
    /// One allocator per transiatve stage of the pipeline. Each allocator is reset when the stage is complete.
    pub var string_alloc: ArenaAllocator = ArenaAllocator(1024 * sizeof(string)) ///< interned strings; outlives every stage.
    pub var pp_alloc:     ArenaAllocator = ArenaAllocator(64 * 1024) ///< TU, ImportDecl, MacroDecl, import edges.
    pub var index_alloc:  ArenaAllocator = ArenaAllocator(64 * 1024) ///< DisambigTable/Node. Read CROSS-FID during parse,
    ///  so it outlives this fid's ast_alloc.
    pub var ast_alloc:     ArenaAllocator   = ArenaAllocator(1024 * 1024) ///< Program + every Decl/Stmt/Expr/Type/Pattern.
    pub var sema_alloc:    ArenaAllocator   = ArenaAllocator() ///< lazy   nothing allocates here until Sema exists.
    pub var codegen_alloc: ArenaAllocator   = ArenaAllocator() ///< lazy   CodegenBackend's node storage.
    pub var scratch_alloc: ArenaAllocator   = ArenaAllocator() ///< lazy   For transient tooling buffers whose contents never become AST.
    pub var diag_sink:     BufferedDiagSink
    /// Sema reported an error against this TU. Kept past the sink's drain
    /// because a LATER input of the same batch that imports this TU finds it
    /// already analysed and reports nothing, yet its codegen would walk this
    /// TU's poisoned or never-lowered decls and hit an emitter ICE guard;
    /// FrontendAction::_codegen refuses a graph holding one.
    pub var sema_errored: bool                       = false
    pub var sm:           unsafe *SourceManager      = &null
    pub var tcm:          unsafe *TokenCacheManager  = &null // we can get the imm table from the tcm
    pub var diags:        unsafe *DiagEngine         = &null
    pub var resolver:     unsafe *ImportResolver     = &null
    pub var hoisted:      unsafe *DisambigTable      = &null
    pub var ci:           unsafe *CompilerInvocation = &null
    pub var tu:           unsafe *TranslationUnit    = &null
    pub var fid:          u32 // needed to get the right lexer

    // Arena reset frees the BLOCKS; it does not run destructors. Anything
    // allocated into an arena whose type is not trivially destructible   it
    // holds a vec, a libcxx::unordered_map, a string   leaks that heap
    // storage on every reset unless its destructor runs first.
    //
    // Harmless when a context is built once and torn down once. Not harmless
    // under incremental reparse, where the leak repeats per edit.
    //
    // Register such allocations via the *_cleanup helpers below and
    // release_from() will run the destructor (placement dtor only   the
    // storage itself still belongs to the arena) before resetting.

    struct ArenaCleanup {
        var obj: unsafe *void
        var run: fn(unsafe *void)
    }

    priv var _cleanup_pp:    cxx::std::vector<Self::ArenaCleanup>
    priv var _cleanup_index: cxx::std::vector<Self::ArenaCleanup>
    priv var _cleanup_ast:   cxx::std::vector<Self::ArenaCleanup>
    priv var _cleanup_sema:  cxx::std::vector<Self::ArenaCleanup>


    fn ASTContext(self,
                  fid:      u32,
                  sm:       unsafe *SourceManager,
                  tcm:      unsafe *TokenCacheManager,
                  diags:    unsafe *DiagEngine,
                  resolver: unsafe *ImportResolver,
                  ci:       unsafe *CompilerInvocation) {
        self.fid      = fid
        self.sm       = sm
        self.tcm      = tcm
        self.diags    = diags
        self.resolver = resolver
        self.ci       = ci
    }

    pub fn get_imm_table(self) -> unsafe *ImmediateTable {
        if self.tcm != &null {
            return self.tcm->get_imm_table_for_fid(self.fid)
        }

        return &null
    }

    pub fn get_tokens(self) -> TokenSpan {
        var unsafe *token_buff = self.tcm->get_tokens(self.fid)
        if token_buff == &null {
            return TokenSpan(&null, 0, 0)
        }

        return TokenSpan(token_buff)
    }

    /// The unqualified alloc* family targets ast_alloc. That is the parse
    /// stage, which is ~113 node create() functions and the overwhelming
    /// majority of call sites, so it stays the default and they stay
    /// untouched. Every OTHER stage names its arena explicitly below.
    pub fn <T> alloc(self) -> unsafe *T {
        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T), alignof(T))
        cxx::std::memset(mem, 0, sizeof(T))
        assert static cxx::std::is_default_constructible<T>::value,
            r"ASTContext::alloc<T>: T must be default-constructible"
        return kairo::construct_at<T>(mem)

        // Zeroed, THEN constructed. Zero alone is not a valid object for every
        // member type: an all-zero MSVC wstring has capacity 0, which its own
        // assign() turns into a heap pointer stored under an inline capacity.
        // libc++ happens to accept zeros, so this only broke on Windows. The
        // memset stays so trivial members with no initializer keep reading 0.
        // Destructors are never run; heap-spilled members leak until exit, by
        // design for the AST's lifetime.
    }

    /// # Construct-in-arena
    ///
    /// alloc_init*<T>(args) allocate a T in one stage's arena and construct
    /// it there; the *_cleanup forms also register its destructor with that
    /// stage's cleanup list (see the arena block above). Kairo generics are
    /// not variadic, so each name has one overload per arity some caller
    /// uses; add one when a new arity is needed. Arguments are taken by value
    /// and moved into T's constructor, one copy at the call, as forwarding an
    /// lvalue was. Every argument passed today is a pointer, enum or integer.

    /// Registers \p p's destructor on \p list and returns \p p.
    priv fn <T> _with_cleanup(self,
                              @inout list: cxx::std::vector<Self::ArenaCleanup>,
                              p:           unsafe *T) -> unsafe *T {
        var c: Self::ArenaCleanup
        c.obj = unsafe (p as unsafe *void)
        c.run = kairo::destroy_in_place<T>
        list.push_back(c)
        return p
    }

    pub fn <T, A0, A1> alloc_init(self, a0: A0, a1: A1) -> unsafe *T {
        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(mem, cxx::std::move(a0), cxx::std::move(a1))
    }

    pub fn <T> alloc_array(self, n: usize) -> unsafe *T {
        if n == 0 {
            return &null
        }

        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T) * n, alignof(T))
        return unsafe (mem as unsafe *T)
    }

    /// An array that lives with the PP-stage nodes (ImportDecl, MacroDecl):
    /// release_from(Parsing) resets ast_alloc but keeps pp_alloc, so a list a
    /// pp_alloc node points at must not sit in ast_alloc (P805).
    pub fn <T> alloc_pp_array(self, n: usize) -> unsafe *T {
        if n == 0 {
            return &null
        }

        var mem: unsafe *void = self.pp_alloc.alloc(sizeof(T) * n, alignof(T))
        return unsafe (mem as unsafe *T)
    }

    fn <T> alloc_array_zeroed(self, n: usize) -> unsafe *T {
        if n == 0 {
            return &null
        }

        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T) * n, alignof(T))
        cxx::std::memset(mem, 0, sizeof(T) * n)
        return unsafe (mem as unsafe *T)
    }

    priv fn _run_cleanups(self, @inout list: cxx::std::vector<Self::ArenaCleanup>) {
        // reverse order: later allocations may reference earlier ones.
        var n = list.size()
        for var i: usize = 0; i < n; ++i {
            var c = (list)[n - 1 - i]
            if c.obj != &null {
                c.run(c.obj)
            }
        }

        list.clear()
    }

    pub fn <T> alloc_init_cleanup(self) -> unsafe *T {
        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(&self._cleanup_ast, kairo::construct_at<T>(mem))
    }

    pub fn <T, A0> alloc_init_cleanup(self, a0: A0) -> unsafe *T {
        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(
            &self._cleanup_ast,
            kairo::construct_at<T>(mem, cxx::std::move(a0)),
        )
    }

    pub fn <T, A0, A1, A2> alloc_init_cleanup(self, a0: A0, a1: A1, a2: A2) -> unsafe *T {
        var mem: unsafe *void = self.ast_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(
            &self._cleanup_ast,
            kairo::construct_at<T>(mem, cxx::std::move(a0), cxx::std::move(a1), cxx::std::move(a2)),
        )
    }

    pub fn <T> alloc_init_sema_cleanup(self) -> unsafe *T {
        var mem: unsafe *void = self.sema_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(&self._cleanup_sema, kairo::construct_at<T>(mem))
    }

    pub fn <T> alloc_init_pp_cleanup(self) -> unsafe *T {
        var mem: unsafe *void = self.pp_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(&self._cleanup_pp, kairo::construct_at<T>(mem))
    }

    pub fn <T, A0, A1, A2, A3> alloc_init_pp_cleanup(self,
                                                     a0: A0,
                                                     a1: A1,
                                                     a2: A2,
                                                     a3: A3) -> unsafe *T {
        var mem: unsafe *void = self.pp_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(
            &self._cleanup_pp,
            kairo::construct_at<T>(
                mem,
                cxx::std::move(a0),
                cxx::std::move(a1),
                cxx::std::move(a2),
                cxx::std::move(a3),
            ),
        )
    }

    fn <T> alloc_init_index_cleanup(self) -> unsafe *T {
        var mem: unsafe *void = self.index_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(&self._cleanup_index, kairo::construct_at<T>(mem))
    }

    pub fn <T, A0> alloc_init_index_cleanup(self, a0: A0) -> unsafe *T {
        var mem: unsafe *void = self.index_alloc.alloc(sizeof(T), alignof(T))
        return self._with_cleanup<T>(
            &self._cleanup_index,
            kairo::construct_at<T>(mem, cxx::std::move(a0)),
        )
    }

    /// # Stage-qualified allocation
    ///
    /// Callers outside the parse stage MUST use these. See the arena block
    /// above for why the choice is per-stage and not per-node-type.

    fn <T> alloc_pp(self) -> unsafe *T {
        var mem: unsafe *void = self.pp_alloc.alloc(sizeof(T), alignof(T))
        cxx::std::memset(mem, 0, sizeof(T))
        return unsafe (mem as unsafe *T)
    }

    pub fn <T, A0, A1, A2, A3> alloc_init_pp(self, a0: A0, a1: A1, a2: A2, a3: A3) -> unsafe *T {
        var mem: unsafe *void = self.pp_alloc.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(
            mem,
            cxx::std::move(a0),
            cxx::std::move(a1),
            cxx::std::move(a2),
            cxx::std::move(a3),
        )
    }

    // No caller yet; kept at the zero-argument arity so the per-stage set
    // stays complete.
    fn <T> alloc_init_index(self) -> unsafe *T {
        var mem: unsafe *void = self.index_alloc.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(mem)
    }

    fn <T> alloc_init_scratch(self) -> unsafe *T {
        var mem: unsafe *void = self.scratch_alloc.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(mem)
    }

    pub fn mem_profile(self) -> (usize, usize, usize) {
        var pp  = self.pp_alloc.profile()
        var ix  = self.index_alloc.profile()
        var ast = self.ast_alloc.profile()
        var sem = self.sema_alloc.profile()
        var scr = self.scratch_alloc.profile()
        var s   = self.string_alloc.profile()
        // (total bytes, total slabs, total alloc calls)
        return (
            pp.bytes_allocated + ix.bytes_allocated + ast.bytes_allocated + sem.bytes_allocated + scr.bytes_allocated + s.bytes_allocated,
            pp.slab_count + ix.slab_count + ast.slab_count + sem.slab_count + scr.slab_count + s.slab_count,
            pp.alloc_calls + ix.alloc_calls + ast.alloc_calls + sem.alloc_calls + scr.alloc_calls + s.alloc_calls,
        )
    }

    /// Frees everything produced at \p from and every LATER stage.
    ///
    /// The cascade is not a convenience: AST nodes address identifiers by
    /// `imm` index into the fid's ImmediateTable, so an AST that outlived its
    /// tokens has unresolvable names. Later stages always die with earlier
    /// ones.
    ///
    /// Idempotent   reset_fast() on an already-reset arena is a no-op, so
    /// releasing at or above a level already released does nothing.
    ///
    /// index_alloc is deliberately NOT released at Parsing: the disambig
    /// table is read cross-fid while DEPENDENT files parse. It is dropped
    /// with the context.
    fn release_from(self, from: TUStage) {
        if (from as u8) <= (TUStage::Codegen as u8) {
            self.codegen_alloc.reset_fast()
        }

        if (from as u8) <= (TUStage::Sema as u8) {
            self._run_cleanups(&self._cleanup_sema)
            self.sema_alloc.reset_fast()
        }

        if (from as u8) <= (TUStage::Parsing as u8) {
            self._run_cleanups(&self._cleanup_ast)
            self.ast_alloc.reset_fast()
            self.scratch_alloc.reset_fast()
            self.hoisted = &null
        }

        if (from as u8) <= (TUStage::Preprocessing as u8) {
            self._run_cleanups(&self._cleanup_pp)
            self._run_cleanups(&self._cleanup_index)
            self.pp_alloc.reset_fast()
            self.index_alloc.reset_fast()
            self.tu = &null
        }
    }

    /// Arena storage is reclaimed by each ArenaAllocator's own destructor, but
    /// registered destructors are not   run them here or every context
    /// teardown leaks the heap members of its non-trivial allocations.
    fn op finally (self) {
        self._run_cleanups(&self._cleanup_sema)
        self._run_cleanups(&self._cleanup_ast)
        self._run_cleanups(&self._cleanup_index)
        self._run_cleanups(&self._cleanup_pp)
    }

    /// Drops the parsed AST and the disambig table, keeping the PP's work
    /// (TU, imports, macro defs) so the file can be re-parsed in place.
    ///
    /// Before the arena split this was reset_fast() on the single shared
    /// arena, which also freed the TranslationUnit and left ctx->tu dangling.
    ///
    /// Unlike release_from(Parsing) this DOES drop index_alloc: the file's
    /// bytes changed, so the hoisted table has to be rebuilt from the new
    /// token stream rather than kept for dependents. Callers holding a
    /// cross-fid DisambigTable pointer must re-fetch after this.
    fn reset_for_reparse(self) {
        self.release_from(TUStage::Parsing)
        self.index_alloc.reset_fast()
    }

    pub fn make_token(self, range: SourceRange, kind: TokenKind, const s: string) -> Token {
        var tok = Token()
        tok.set_kind(kind)
        tok.set_range(range)
        // token = lexer->intern_ident(s_p, length, h);
        // fn intern_ident(self, const data: *u8, len: usize, hash: u32) -> u32
        var unsafe *str = self.string_alloc.alloc_init<string>(s)
        if str == &null {
            self.diags->report(
                DiagID::I002F,
                range.start,
                f"internal error: ASTContext::make_token failed to allocate string for token '{s}'",
            ).first(range)->emit()
            return Token()
        }

        var unsafe *r = unsafe (str->raw() as kairo::std::ConstPtr<u8>)
        var        l  = str->size()
        var        h  = compute_hash(r, l)
        tok.imm = self.tcm->intern_ident(self.fid, r, l, (h as u32))
        return tok
    }

    /// \brief resolved imm ident index for a token, or u32(-1) if it is not an
    ///        identifier (keyword, operator, sentinel, or no interner reachable).
    ///
    /// \details unwraps any TkMacroExpand chain first so the index matches the
    ///          spelling the user wrote, then returns the UNWRAPPED imm (tok.imm
    ///          on a wrapped token is the expansion record, not the ident). This
    ///          is the identity half of TokenText::resolve without materializing
    ///          the string   the sanctioned key for DisambigTable lookups off a
    ///          token. Same spelling collapses to the same index as a string
    ///          interned via intern_ident_copy, so token-keyed and text-keyed
    ///          lookups agree within a file.
    pub fn get_ident_imm(self, tok: Token) -> u32 {
        var unsafe *tbl = self.get_imm_table()
        if tbl == &null {
            return u32::MAX
        }

        var u = unwrap_expansion(tok, self.tcm)
        if u.is_sentinel {
            return u32::MAX
        }

        if (u.kind as u32) != (TokenKind::LitIdentifier as u32) {
            return u32::MAX
        }

        // An identifier from a macro body written in ANOTHER file (an
        // imported `pub macro`, the prelude's `crash!`) indexes THAT file's
        // table; read against this one the same index is some other name
        // (a call to `helper` bound `main`). Re-key it here, finding first:
        // intern_ident_copy stores a fresh copy on every call, and this
        // runs per lookup. The literal half of the problem is the SC073E
        // ticket; only identifiers are re-keyed.
        if u.depth > 0 && u.tbl != &null && u.tbl != tbl {
            var sp  = u.tbl->get_ident(u.imm)
            var idx = tbl->find_ident(sp)
            if idx == u32::MAX {
                idx = tbl->intern_ident_copy(sp)
            }

            return idx
        }

        return u.imm
    }

    /// \brief a macro-wrapped token's ORIGINAL kind and imm, kept at the
    ///        wrapped token's (invocation-site) range; any other token as is.
    ///
    /// \details for nodes that store a token and later read its KIND: an
    ///          operator from a macro body is TkMacroExpand until unwrapped,
    ///          and Sema's operator switch on that kind found no `+` (SC066E
    ///          "not defined on primitives" for `a + b` in any macro body).
    ///          Sentinels stay wrapped: their identity IS the wrapper.
    pub fn unwrap_token(self, tok: Token) -> Token {
        if self.tcm == &null {
            return tok
        }

        if (tok.kind as u32) != (TokenKind::TkMacroExpand as u32) {
            return tok
        }

        var u = unwrap_expansion(tok, self.tcm)
        if u.is_sentinel || u.hit_limit || u.depth == 0 {
            return tok
        }

        return Token(tok.range, u.kind, u.imm)
    }

    /// \brief the table that owns a literal token's payload (IntData,
    ///        FloatData, StringData), unwrapping any macro chain first.
    ///
    /// \details pair it with unwrap_token(tok).imm. A wrapped token's own imm
    ///          is its MacroExpansionInfo record, not a payload index, and the
    ///          payload lives in the file that WROTE the literal (an imported
    ///          macro's body: the defining file; a literal argument: the
    ///          invoking file). Reading the record index against this file's
    ///          literal list was SC073E when it ran off the end and, worse, a
    ///          different literal of this file when it did not.
    pub fn get_payload_table(self, tok: Token) -> unsafe *ImmediateTable {
        var unsafe *tbl = self.get_imm_table()
        if self.tcm == &null {
            return tbl
        }

        if (tok.kind as u32) != (TokenKind::TkMacroExpand as u32) {
            return tbl
        }

        var u = unwrap_expansion(tok, self.tcm)
        if u.is_sentinel || u.hit_limit || u.depth == 0 || u.tbl == &null {
            return tbl
        }

        tbl = u.tbl
        return tbl
    }

    /// \brief where a token was WRITTEN: a macro-wrapped token's innermost
    ///        definition-site range (a body token in the macro's body, a
    ///        substituted argument at the invocation); any other token's own.
    ///
    /// \details a wrapped token's range is the invocation, so two wrapped
    ///          tokens of one body (`t.1`) share a start, and a spacing rule
    ///          read off those ranges reports whitespace that was never
    ///          written. Spacing questions about wrapped tokens ask this.
    fn written_range(self, tok: Token) -> SourceRange {
        if self.tcm == &null {
            return tok.range
        }

        if (tok.kind as u32) != (TokenKind::TkMacroExpand as u32) {
            return tok.range
        }

        var u = unwrap_expansion(tok, self.tcm)
        if u.is_sentinel || u.hit_limit || u.depth == 0 {
            return tok.range
        }

        return u.def_range
    }

    /// \brief \p tok, a raw token another file lexed, wrapped as a macro
    ///        expansion at \p site so it reads against ITS file's tables.
    ///
    /// \details an f-string's holes are token buffers the lexer kept on the
    ///          literal's StringData, unwrapped: a hole's identifier or
    ///          literal indexes the table of the file that wrote the string.
    ///          When that string came out of an imported macro's body, the
    ///          parser of THIS file read those indices against its own
    ///          tables (R020E on the body's names, or a different name or
    ///          literal of this file). The record goes in this file's table,
    ///          at \p site's range (where the expansion is reported), and its
    ///          def_range is the token's own, so unwrap_expansion finds the
    ///          payload table from it exactly as for a token the
    ///          preprocessor wrapped. EVERY token is wrapped, as the
    ///          preprocessor wraps every body token: an unwrapped `(` or `)`
    ///          keeps its range in the other file, and a node spanning a
    ///          wrapped name and that paren (`helper_fn(40)`) then runs from
    ///          this file into that one (TokenSink I003E). The buffer's end
    ///          marker stays as it is.
    fn wrap_foreign_token(self, tok: Token, site: Token) -> Token {
        var unsafe *tbl = self.get_imm_table()
        if tbl == &null || self.tcm == &null {
            return tok
        }

        if (tok.kind as u32) == (TokenKind::TkEof as u32) {
            return tok
        }

        if (tok.kind as u32) == (TokenKind::TkMacroExpand as u32) {
            return tok
        }

        // The invocation's macro name, for the "in expansion of" chain.
        var name = u32::MAX
        if (site.kind as u32) == (TokenKind::TkMacroExpand as u32) {
            var unsafe *rec_tbl = self.tcm->get_imm_table_for_token(site)
            if rec_tbl != &null {
                var unsafe *outer = rec_tbl->get<Immediate::MacroExpansionInfo>(site.imm)
                if outer != &null {
                    name = outer->macro_name
                }
            }
        }

        var        idx   = tbl->create<Immediate::MacroExpansionInfo>()
        var unsafe *info = tbl->get<Immediate::MacroExpansionInfo>(idx)
        info->invoke_range  = site.range
        info->def_range     = tok.range
        info->original_kind = tok.kind
        info->original_imm  = tok.imm
        info->macro_name    = name
        info->parent_idx    = u32::MAX
        return Token(site.range, TokenKind::TkMacroExpand, idx)
    }

    fn get_token_text(self, tok: Token) -> TokenText {
        return TokenText::resolve(tok, self.tcm)
    }

    fn get_token_text(self, rng: SourceRange) -> TokenText {
        return TokenText::from_range(rng, self.sm)
    }

    pub fn get_spelling(self, tok: Token) -> string {
        return *self.get_token_text(tok).get_text()
    }

    pub fn get_spelling(self, rng: SourceRange) -> string {
        return *self.get_token_text(rng).get_text()
    }
}
