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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Memory::ArenaList::*;
import Driver::TUStage::*;   // standalone enum, no imports of its own; no cycle
import Location::SourceManager::*;
import Token::TokenCacheManager::*;
import Lexer::Immediate::*;
import Resolution::ModulePath::*;
import Resolution::ImportProbe::*;
import Token::TokenSpan::*;
import Config::Invocation::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Diagnostic::BufferedDiagSink::*;
import Token::TokenText::*;

/// \brief Forward declaration required by ASTContext.
///
/// DisambigTable and ASTContext are mutually dependent: ASTContext owns the
/// arena that DisambigTable allocates from, and DisambigTable holds an obs<>
/// back-pointer to ASTContext for that allocation. This forward declaration
/// breaks the cycle.
///
/// Full definition follows ASTContext in this file. This is a Stage 0
/// compiler limitation Stage 0 cannot split a forward declaration and its
/// implementation across files when they would land in different generated
/// namespaces. Stage 1 removes this constraint entirely.
///
/// Do not move DisambigTable above ASTContext or extract it to a separate
/// file until Stage 1 is self-hosting.
class DisambigTable;

class ASTContext {
    pub var source_path: Path;
    pub var module_base: ModulePath;
    
    /// This is the general allocators for the compiler pipeline.
    /// One allocator per transiatve stage of the pipeline. Each allocator is reset when the stage is complete.
    pub var string_alloc:  ArenaAllocator = ArenaAllocator(1024 * sizeof(string)); ///< interned strings; outlives every stage.
    pub var pp_alloc:      ArenaAllocator = ArenaAllocator(64 * 1024);             ///< TU, ImportDecl, MacroDecl, import edges.
    pub var index_alloc:   ArenaAllocator = ArenaAllocator(64 * 1024);             ///< DisambigTable/Node. Read CROSS-FID during parse,
                                                                                   ///  so it outlives this fid's ast_alloc.
    pub var ast_alloc:     ArenaAllocator = ArenaAllocator(1024 * 1024);           ///< Program + every Decl/Stmt/Expr/Type/Pattern.
    pub var sema_alloc:    ArenaAllocator = ArenaAllocator();                      ///< lazy   nothing allocates here until Sema exists.
    pub var codegen_alloc: ArenaAllocator = ArenaAllocator();                      ///< lazy   CodegenBackend's node storage.
    pub var scratch_alloc: ArenaAllocator = ArenaAllocator();                      ///< lazy   For transient tooling buffers whose contents never become AST.
    pub var diag_sink:     BufferedDiagSink;
    pub var sm:            obs::<SourceManager>              = &null;
    pub var tcm:           obs::<TokenCacheManager>          = &null; // we can get the imm table from the tcm
    pub var diags:         obs::<DiagEngine>                 = &null;
    pub var resolver:      obs::<ImportResolver>             = &null;
    pub var hoisted:       obs::<DisambigTable>              = &null;
    pub var ci:            obs::<CompilerInvocation>         = &null;
    pub var tu:            obs::<void /* TranslationUnit */> = &null; // stage0 limit with fwd decls, hence void ptr,
                                                                      // but replace with TranslationUnit once stage1 is self-hosting
    pub var fid:           u32; // needed to get the right lexer

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
        var obj: *void;
        var run: fn(*void);
    }

    priv var _cleanup_pp:    vec::<ArenaCleanup>;
    priv var _cleanup_index: vec::<ArenaCleanup>;
    priv var _cleanup_ast:   vec::<ArenaCleanup>;
    priv var _cleanup_sema:  vec::<ArenaCleanup>;


    fn ASTContext(
        self,
        fid:       u32,
        sm:       *SourceManager,
        tcm:      *TokenCacheManager,
        diags:    *DiagEngine,
        resolver: *ImportResolver,
        ci:       *CompilerInvocation
    ) {
        self.fid      = fid;
        self.sm       = sm;
        self.tcm      = tcm;
        self.diags    = diags;
        self.resolver = resolver;
        self.ci       = ci;
    }

    fn get_imm_table(self) -> *ImmediateTable {
        if self.tcm != &null {
            return self.tcm->get_imm_table_for_fid(self.fid);
        }

        return &null;
    }

    fn get_tokens(self) -> TokenSpan {
        var token_buff = self.tcm->get_tokens(self.fid);
        if token_buff == &null {
            return TokenSpan(&null, 0, 0);
        }

        return TokenSpan(token_buff);
    }

    /// The unqualified alloc* family targets ast_alloc. That is the parse
    /// stage, which is ~113 node create() functions and the overwhelming
    /// majority of call sites, so it stays the default and they stay
    /// untouched. Every OTHER stage names its arena explicitly below.
    fn <T> alloc(self) -> *T {
        var mem: *void = self.ast_alloc.alloc(sizeof(T), alignof(T));
        libcxx::memset(mem, 0, sizeof(T));
        return static_cast::<*T>(mem);

        // NOTE: we deliberately do NOT construct, its the parsers job to fill
        //       all the fields. If T has non-trivial members that must be
        //       initialized, use alloc_init<T>() instead.
    }

    inline "c++" { // PORT(trivial)
        private:
        template <typename T, typename ...Args>
        T *placement_new(void *mem, Args &&...args) {
            return ::new (mem) T(libcxx::forward<Args>(args)...);
        }
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init(Args &&...args) {
            void *mem = this->ast_alloc.alloc(sizeof(T), alignof(T));
            return ::new (mem) T(libcxx::forward<Args>(args)...);
        }
    }

    fn <T> alloc_array(self, n: usize) -> *T {
        if n == 0 {
            return &null;
        }

        var mem: *void = self.ast_alloc.alloc(sizeof(T) * n, alignof(T));
        return static_cast::<*T>(mem);
    }

    fn <T> alloc_array_zeroed(self, n: usize) -> *T {
        if n == 0 {
            return &null;
        }

        var mem: *void = self.ast_alloc.alloc(sizeof(T) * n, alignof(T));
        libcxx::memset(mem, 0, sizeof(T) * n);
        return static_cast::<*T>(mem);
    }

    priv fn _run_cleanups(self, list: *vec::<ArenaCleanup>) {
        // reverse order: later allocations may reference earlier ones.
        var n = list->size();
        for var i: usize = 0; i < n; ++i {
            var c = (*list)[(n - 1) - i];
            if c.obj != &null { c.run(c.obj); }
        }
        list->clear();
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_cleanup(Args &&...args) {
            void *mem = this->ast_alloc.alloc(sizeof(T), alignof(T));
            T *p = ::new (mem) T(libcxx::forward<Args>(args)...);
            ArenaCleanup c;
            c.obj = static_cast<void *>(p);
            c.run = [](void *q) { static_cast<T *>(q)->~T(); };
            this->_cleanup_ast.push_back(c);
            return p;
        }
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_sema_cleanup(Args &&...args) {
            void *mem = this->sema_alloc.alloc(sizeof(T), alignof(T));
            T *p = ::new (mem) T(libcxx::forward<Args>(args)...);
            ArenaCleanup c;
            c.obj = static_cast<void *>(p);
            c.run = [](void *q) { static_cast<T *>(q)->~T(); };
            this->_cleanup_sema.push_back(c);
            return p;
        }
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_pp_cleanup(Args &&...args) {
            void *mem = this->pp_alloc.alloc(sizeof(T), alignof(T));
            T *p = ::new (mem) T(libcxx::forward<Args>(args)...);
            ArenaCleanup c;
            c.obj = static_cast<void *>(p);
            c.run = [](void *q) { static_cast<T *>(q)->~T(); };
            this->_cleanup_pp.push_back(c);
            return p;
        }
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_index_cleanup(Args &&...args) {
            void *mem = this->index_alloc.alloc(sizeof(T), alignof(T));
            T *p = ::new (mem) T(libcxx::forward<Args>(args)...);
            ArenaCleanup c;
            c.obj = static_cast<void *>(p);
            c.run = [](void *q) { static_cast<T *>(q)->~T(); };
            this->_cleanup_index.push_back(c);
            return p;
        }
    }

    // --- Stage-qualified allocation --------------------------------------
    //
    // Callers outside the parse stage MUST use these. See the arena block
    // above for why the choice is per-stage and not per-node-type.

    fn <T> alloc_pp(self) -> *T {
        var mem: *void = self.pp_alloc.alloc(sizeof(T), alignof(T));
        libcxx::memset(mem, 0, sizeof(T));
        return static_cast::<*T>(mem);
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_pp(Args &&...args) {
            void *mem = this->pp_alloc.alloc(sizeof(T), alignof(T));
            return ::new (mem) T(libcxx::forward<Args>(args)...);
        }
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_index(Args &&...args) {
            void *mem = this->index_alloc.alloc(sizeof(T), alignof(T));
            return ::new (mem) T(libcxx::forward<Args>(args)...);
        }
    }

    inline "c++" { // PORT(trivial)
        template <typename T, typename ...Args>
        T *alloc_init_scratch(Args &&...args) {
            void *mem = this->scratch_alloc.alloc(sizeof(T), alignof(T));
            return ::new (mem) T(libcxx::forward<Args>(args)...);
        }
    }

    fn mem_profile(self) -> (usize, usize, usize) {
        var pp  = self.pp_alloc.profile();
        var ix  = self.index_alloc.profile();
        var ast = self.ast_alloc.profile();
        var sem = self.sema_alloc.profile();
        var scr = self.scratch_alloc.profile();
        var s   = self.string_alloc.profile();
        // (total bytes, total slabs, total alloc calls)
        return (pp.bytes_allocated + ix.bytes_allocated + ast.bytes_allocated
                    + sem.bytes_allocated + scr.bytes_allocated + s.bytes_allocated,
                pp.slab_count + ix.slab_count + ast.slab_count
                    + sem.slab_count + scr.slab_count + s.slab_count,
                pp.alloc_calls + ix.alloc_calls + ast.alloc_calls
                    + sem.alloc_calls + scr.alloc_calls + s.alloc_calls);
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
        if from <= TUStage::Codegen {
            self.codegen_alloc.reset_fast();
        }

        if from <= TUStage::Sema {
            self._run_cleanups(&(self._cleanup_sema));
            self.sema_alloc.reset_fast();
        }

        if from <= TUStage::Parsing {
            self._run_cleanups(&(self._cleanup_ast));
            self.ast_alloc.reset_fast();
            self.scratch_alloc.reset_fast();
            self.hoisted = &null;
        }

        if from <= TUStage::Preprocessing {
            self._run_cleanups(&(self._cleanup_pp));
            self._run_cleanups(&(self._cleanup_index));
            self.pp_alloc.reset_fast();
            self.index_alloc.reset_fast();
            self.tu = &null;
        }
    }

    /// Arena storage is reclaimed by each ArenaAllocator's own destructor, but
    /// registered destructors are not   run them here or every context
    /// teardown leaks the heap members of its non-trivial allocations.
    fn op delete (self) {
        self._run_cleanups(&(self._cleanup_sema));
        self._run_cleanups(&(self._cleanup_ast));
        self._run_cleanups(&(self._cleanup_index));
        self._run_cleanups(&(self._cleanup_pp));
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
        self.release_from(TUStage::Parsing);
        self.index_alloc.reset_fast();
    }

    fn make_token(self, range: SourceRange, kind: TokenKind, s: string) -> Token {
        var tok = Token();
        tok = kind;
        tok = range;
        // token = lexer->intern_ident(s_p, length, h);
        // fn intern_ident(self, const data: *u8, len: usize, hash: u32) -> u32
        var str = self.string_alloc.alloc_init::<nstring>(std::string_to_nstring(s));
        if str == &null {
            self.diags->report(DiagID::I002F, range.start,
                f"internal error: ASTContext::make_token failed to allocate string for token \x27{s}\x27"
            ).first(range).emit();
            return Token();
        }
        var r   = reinterpret_cast::<std::ConstPtr::<u8>>(str->raw());
        var l   = str->size();
        var h   = compute_hash(r, l);
        tok.imm = self.tcm->intern_ident(self.fid, r, l, h);
        return tok;
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
    fn get_ident_imm(self, tok: Token) -> u32 {
        var tbl = self.get_imm_table();
        if tbl == &null { return u32(-1); }

        var u = unwrap_expansion(tok, self.tcm);
        if u.is_sentinel { return u32(-1); }
        if static_cast::<u32>(u.kind) == static_cast::<u32>(TokenKind::LitIdentifier) {
            return u.imm;
        }
        return u32(-1);
    }

    fn get_token_text(self, tok: Token) -> TokenText {
        return TokenText::resolve(tok, self.tcm);
    }

    fn get_token_text(self, rng: SourceRange) -> TokenText {
        return TokenText::from_range(rng, self.sm);
    }

    fn get_spelling(self, tok: Token) -> string {
        return self.get_token_text(tok).get_text();
    }

    fn get_spelling(self, rng: SourceRange) -> string {
        return self.get_token_text(rng).get_text();
    }
}

/// Coarse declaration kind enough for parser disambiguation.
/// Sema refines these into concrete DeclKind values.
enum DisambigKind derives u8 {
    ClassType,      ///< class Foo
    EnumType,       ///< enum Foo
    UnionType,      ///< union Foo
    StructType,     ///< struct Foo
    InterfaceType,  ///< interface Foo
    TypeAlias,      ///< type Foo = ...
    Function,       ///< fn foo
    Operator,       ///< fn op +
    Variable,       ///< var foo / const foo
    ProcMacro,      ///< @foo
    BasicMacro,     ///< foo!
    Module,         ///< namespace / module block
}

/// A single entry in the hoisted scope table.
///
/// \c decl is null for declarations originating from C++ FFI use
/// \c origin for source location in that case.
/// \c is_foreign is true for symbols introduced via import, not declared
/// locally in the file being indexed.
///
/// \c generic mirrors TemplateParams::is_generic() on the declaring node:
/// true iff the decl carries explicit `<T>` type params OR is a Primary
/// specialization form. Explicit/Partial specializations do NOT set it
/// genericness of a name is owned by the primary declaration. The zero
/// value (false) is the safe default: an entry never accidentally reads
/// as generic. (Replaces the old num_params sentinel, whose two competing
/// contracts 0-means-not-generic vs -1-means-not-generic made every
/// zero-count path read as generic.)
class DisambigEntry {
    struct DeclEntry { // 128 bits
        pub var origin: SourceRange;
    }

    pub var extend_of_name: u32 = u32(-1); ///< imm ident index of the extended type's name.
    pub var name:           u32 = u32(-1); ///< imm ident index of this entry's name.
    pub var kind:           DisambigKind;
    pub var decl:           DeclEntry;
    pub var extend_of:      DeclEntry;
    pub var generic:        bool = false; ///< See class docs; from TemplateParams::is_generic().
    pub var is_foreign:     bool; ///< True if introduced via import.
    pub var extended:       bool; ///< True if this is an extended impl of an existing type, not a new declaration.

    fn is_type(self) -> bool {
        switch self.kind {
            case DisambigKind::ClassType     { return true;  }
            case DisambigKind::EnumType      { return true;  }
            case DisambigKind::UnionType     { return true;  }
            case DisambigKind::StructType    { return true;  }
            case DisambigKind::InterfaceType { return true;  }
            case DisambigKind::TypeAlias     { return true;  }
            default                         { return false; }
        }
    }

    fn is_value(self) -> bool {
        return self.kind == DisambigKind::Function
            || self.kind == DisambigKind::Operator
            || self.kind == DisambigKind::Variable;
    }

    fn is_macro(self) -> bool {
        return self.kind == DisambigKind::ProcMacro
            || self.kind == DisambigKind::BasicMacro;
    }

    fn is_generic(self)   -> bool { return self.generic;        }
    fn is_extension(self) -> bool { return self.extended;       }
    fn is_from_foreign(self)   -> bool { return self.is_foreign;     }
}

/// One node in the hoisted scope trie.
///
/// \c entries holds names declared at this scope level.
/// \c children holds nested scopes (modules, classes, enums with variants).
///
/// Keyed on the u32 imm ident index so all comparisons and hashes are O(1)
/// integer ops. Memory is arena-owned the destructor intentionally leaks child
/// pointers since the arena reclaims everything at once.
class DisambigNode {
    pub var entries:  libcxx::unordered_map::<u32, vec::<DisambigEntry>>;
    pub var children: libcxx::unordered_map::<u32, *DisambigNode>;

    fn DisambigNode(self) {
        self.entries.reserve(16);
        self.children.reserve(8);
    }

    // NOTE: no op delete here. The arena reclaims the NODE STRUCT, but
    // `entries` and `children` are libcxx::unordered_maps with heap buckets
    // (and `entries` values are heap vecs on top of that). Their destructors
    // must still run, so DisambigNode is allocated via
    // alloc_init_index_cleanup() and torn down through ASTContext's cleanup
    // registry. Defining a no-op op delete here would silently defeat that.

    /// Inserts \p entry under \p name. First declaration wins; duplicates ignored.
    /// Sema will catch redefinition errors with full source context.
    fn insert(self, name: u32, entry: DisambigEntry) {
        self.entries[name].push_back(entry);
    }

    /// Returns the child scope for \p name, creating it if absent.
    fn get_or_create_child(self, name: u32, ctx: *ASTContext) -> *DisambigNode {
        var it = self.children.find(name);
        if it != self.children.end() {
            return it->second;
        }
        var child = ctx->alloc_init_index_cleanup::<DisambigNode>();
        self.children.insert(libcxx::make_pair(name, child));
        return child;
    }

    /// Returns the child scope for \p name, or null if absent.
    fn get_child(self, name: u32) -> *DisambigNode {
        var it = self.children.find(name);
        if it == self.children.end() { return &null; }
        return it->second;
    }

    /// Looks up \p name at this scope level only. Does not search children.
    fn lookup(self, name: u32) -> *vec::<DisambigEntry> {
        var it = self.entries.find(name);
        if it == self.entries.end() { return &null; }
        return &it->second;
    }

    fn has_child(self, name: u32) -> bool {
        return self.children.count(name) > 0;
    }

    fn has_entry(self, name: u32) -> bool {
        return self.entries.count(name) > 0;
    }
}

/// Result of a lookup into DisambigTable.
/// Carries both the entry and the scope node it was found in,
/// so the parser can continue walking children if needed.
class LookupResult {
    pub var entries: *vec::<DisambigEntry>;  ///< Null if not found.
    pub var node:    *DisambigNode;            ///< Scope where entry lives. Null if not found.

    fn found(self) -> bool    { return (self.entries != &null) && (!self.entries->empty()); }
    fn is_type(self) -> bool  { return (self.found()) && ((*self.entries)[0].is_type());  }
    fn is_value(self) -> bool { return (self.found()) && ((*self.entries)[0].is_value()); }
    fn is_macro(self) -> bool { return (self.found()) && ((*self.entries)[0].is_macro()); }

    static fn not_found() -> LookupResult {
        var r     = LookupResult{};
        r.entries = &null;
        r.node    = &null;
        return r;
    }

    fn first(self) -> *DisambigEntry {
        if (self.entries == &null) || (self.entries->empty()) { return &null; }
        return &(*self.entries)[0];
    }

    fn is_overloaded(self) -> bool {
        return (self.entries != &null) && (self.entries->size() > 1);
    }

    fn is_extended(self) -> bool {
        if (self.entries == &null) { return false; }
        for entry in *self.entries {
            if entry.extended { return true; }
        }
        return false;
    }

    fn extensions(self) -> vec::<*DisambigEntry> {
        var result = vec::<*DisambigEntry>();
        if self.entries == &null { return result; }
        for var i: usize = 0; i < self.entries->size(); ++i {
            if (*self.entries)[i].extended {
                result.push_back(&(*self.entries)[i]);
            }
        }
        return result;
    }

    fn non_extensions(self) -> vec::<*DisambigEntry> {
        var result = vec::<*DisambigEntry>();
        if self.entries == &null { return result; }
        for var i: usize = 0; i < self.entries->size(); ++i {
            if !(*self.entries)[i].extended {
                result.push_back(&(*self.entries)[i]);
            }
        }
        return result;
    }
}

/// Hierarchical symbol table built by the index pass over a single file
/// and its transitive imports.
///
/// Structured as a trie of \c DisambigNode instances keyed on the u32 imm ident index.
/// Lookup for a qualified name like \c foo::bar::Baz costs one hashmap
/// lookup per segment O(1) per segment, O(depth) total.
///
/// \par Parser API
/// The parser holds a \c *DisambigTable and calls:
///   - \c lookup(ident)         for unqualified names
///   - \c lookup(chain)         for qualified names from a \c ChainExpr
///   - \c is_type / is_value    for quick boolean disambiguation
///   - \c enter(name)           to get a child \c DisambigNode for manual walking
///
/// \par Population
/// The \c Indexer calls \c insert() and \c insert_into() during the index
/// pass. After the pass completes the scope is read-only.
class DisambigTable {
    priv var _root: DisambigNode;
    priv var _ctx:  obs::<ASTContext>;

    fn DisambigTable(self, ctx: *ASTContext) {
        self._ctx = ctx;
    }

    // --- Interning -----------------------------------------------------------
    //
    // Post interner-consolidation the key space IS the per-fid ImmediateTable
    // ident index, unified with Token.imm. String inputs (synth names, path
    // segments spanning multiple tokens) are copied in via intern_ident_copy;
    // token inputs use their resolved imm directly (see lookup_tok / intern_tok).

    priv fn _tbl(self) -> *ImmediateTable {
        return self._ctx->get_imm_table();
    }

    /// Interns \p s and returns its imm ident index. String path only prefer
    /// \c intern_tok when a token is in hand to avoid the byte copy.
    fn intern(self, s: string) -> u32 {
        return self._tbl()->intern_ident_copy(s);
    }

    /// Imm ident index for an identifier token, using its resolved imm directly.
    /// Returns u32(-1) for non-identifier tokens (never matches an entry).
    fn intern_tok(self, tok: Token) -> u32 {
        return self._ctx->get_ident_imm(tok);
    }

    fn str(self, h: u32) -> string {
        return self._tbl()->get_ident(h);
    }

    // --- Population ----------------------------------------------------------

    /// Inserts \p entry at root scope under \p name.
    fn insert(self, name: string, entry: DisambigEntry) {
        var key        = self.intern(name);
        entry.name     = key;
        self._root.insert(key, entry);
    }

    /// Inserts \p entry at the scope reached by walking \p scope_path from root.
    /// Creates intermediate scope nodes as needed.
    /// \p scope_path is the sequence of parent names, e.g. ["A", "B"] for A::B::Foo.
    fn insert_into(self, scope_path: *vec::<string>, name: string, entry: DisambigEntry) {
        var node = &self._root;
        for s: string in *scope_path {
            var k = self.intern(s);
            node  = node->get_or_create_child(k, self._ctx);
        }
        var key    = self.intern(name);
        entry.name = key;
        node->insert(key, entry);
    }

    // --- Parser API ----------------------------------------------------------

    /// Looks up an unqualified name at root scope.
    fn lookup(self, name: string) -> LookupResult {
        var key = self.intern(name);
        return self._lookup_in(&self._root, key);
    }

    /// Looks up an already-interned imm ident index at root scope. O(1).
    fn lookup(self, name: u32) -> LookupResult {
        return self._lookup_in(&self._root, name);
    }

    /// Looks up an identifier token at root scope by its resolved imm. O(1),
    /// no byte copy the sanctioned hot-path lookup for the parser.
    fn lookup_tok(self, tok: Token) -> LookupResult {
        var key = self.intern_tok(tok);
        if key == u32(-1) { return LookupResult::not_found(); }
        return self._lookup_in(&self._root, key);
    }

    /// Walks a qualified name chain and returns the final entry.
    /// \p segments is the sequence of names from a parsed \c ChainExpr,
    /// e.g. ["foo", "bar", "Baz"] for foo::bar::Baz.
    /// Returns \c LookupResult::not_found() if any segment is missing.
    fn lookup(self, segments: *vec::<string>) -> LookupResult {
        if segments->empty() { return LookupResult::not_found(); }

        var node = &self._root;
        for var i: usize = 0; i < segments->size() - 1; ++i {
            var k    = self.intern((*segments)[i]);
            var next = node->get_child(k);
            if next == &null { return LookupResult::not_found(); }
            node = next;
        }

        var last = self.intern(segments->back());
        return self._lookup_in(node, last);
    }

    fn insert_extension(self, scope_path: *vec::<string>, name: string, entry: DisambigEntry) {
        assert(entry.extended && r"insert_extension: entry.extended must be true");
        self.insert_into(scope_path, name, entry);
    }

    // DisambigTable::lookup_extensions - new
    fn lookup_extensions(self, type_name: u32) -> vec::<*DisambigEntry> {
        var result = vec::<*DisambigEntry>();
        self._collect_extensions(&self._root, type_name, &result);
        return result;
    }

    /// Returns the child scope node for \p name at root, or null.
    /// Used by the parser to manually walk a scope chain one segment at a time.
    fn enter(self, name: string) -> *DisambigNode {
        var k = self.intern(name);
        return self._root.get_child(k);
    }

    fn enter(self, name: u32) -> *DisambigNode {
        return self._root.get_child(name);
    }

    fn enter(self, segments: *vec::<string>) -> *DisambigNode {
        var node = &self._root;
        for s in *segments {
            var k = self.intern(s);
            node  = node->get_child(k);
            if node == &null { return &null; }
        }
        return node;
    }

    /// Quick boolean queries on root scope.
    fn is_type(self, name: string)  -> bool { return self.lookup(name).is_type();  }
    fn is_value(self, name: string) -> bool { return self.lookup(name).is_value(); }
    fn is_macro(self, name: string) -> bool { return self.lookup(name).is_macro(); }

    fn root(self) -> *DisambigNode { return &self._root; }

    fn dump(self) {
        std::print("=== DisambigTable Dump ===");
        self._dump_node(&self._root, "", true);
        std::print("=========================");
    }


    // --- Private -------------------------------------------------------------

    priv fn _lookup_in(self, node: *DisambigNode, key: u32) -> LookupResult {
        var entries = node->lookup(key);
        if entries == &null {
            return LookupResult::not_found();
        }
        var r    = LookupResult{};
        r.entries = entries;
        r.node    = node;
        return r;
    }

    priv fn _collect_extensions(self, node: *DisambigNode, type_name: u32, result: *vec::<*DisambigEntry>) {
        for var it = node->entries.begin(); it != node->entries.end(); ++it {
            for var i: usize = 0; i < it->second.size(); ++i {
                var entry = &it->second[i];
                if entry->extended {
                    if entry->extend_of_name == type_name {
                        result->push_back(entry);
                    }
                }
            }
        }
        for var it = node->children.begin(); it != node->children.end(); ++it {
            self._collect_extensions(it->second, type_name, result);
        }
    }

    priv fn _dump_node(self, node: *DisambigNode, prefix: string, is_root: bool) {
        var entries_it = node->entries.begin();
        var total_entries: usize = 0;

        // count total entry vectors for branching logic
        for var it = node->entries.begin(); it != node->entries.end(); ++it {
            total_entries += 1;
        }
        var total_children: usize = node->children.size();
        var total_items: usize    = total_entries + total_children;

        var item_idx: usize = 0;

        // print entries
        for var it = node->entries.begin(); it != node->entries.end(); ++it {
            ++item_idx;
            var is_last    = (item_idx == total_items);
            var connector  = (("└── ") if (is_last) else ("├── "));
            var child_pfx  = (("    ") if (is_last) else ("│   "));

            var name = self.str(it->first);
            var vec  = it->second;

            if vec.size() == 1 {
                std::print(f"{prefix}{connector}{name}  [{self._kind_str(vec[0].kind)}]{self._flags_str(vec[0])}");
            } else {
                std::print(f"{prefix}{connector}{name}  (overloaded x{vec.size()})");
                for var i: usize = 0; i < vec.size(); ++i {
                    var sub_last      = (i == vec.size() - 1);
                    var sub_connector = (("└── ") if (sub_last) else ("├── "));
                    std::print(f"{prefix}{child_pfx}{sub_connector}[{self._kind_str(vec[i].kind)}]{self._flags_str(vec[i])}");
                }
            }
        }

        // print children (nested scopes)
        for var it = node->children.begin(); it != node->children.end(); ++it {
            ++item_idx;
            var is_last   = (item_idx == total_items);
            var connector = (("└── ") if (is_last) else ("├── "));
            var child_pfx = (("    ") if (is_last) else ("│   "));

            var name = self.str(it->first);
            std::print(f"{prefix}{connector}{name}/");
            self._dump_node(it->second, prefix + child_pfx, false);
        }
    }

    priv static fn _kind_str(kind: DisambigKind) -> string {
        switch kind {
            case DisambigKind::ClassType     { return "class";     }
            case DisambigKind::EnumType      { return "enum";      }
            case DisambigKind::UnionType     { return "union";     }
            case DisambigKind::StructType    { return "struct";    }
            case DisambigKind::InterfaceType { return "interface"; }
            case DisambigKind::TypeAlias     { return "type";      }
            case DisambigKind::Function      { return "fn";        }
            case DisambigKind::Operator      { return "fn op";     }
            case DisambigKind::Variable      { return "var";       }
            case DisambigKind::ProcMacro     { return "@macro";    }
            case DisambigKind::BasicMacro    { return "macro!";    }
            case DisambigKind::Module        { return "module";    }
            default                         { return "?";         }
        }
    }

    priv static fn _flags_str(entry: ref!(DisambigEntry)) -> string {
        var s: string = "";
        if entry.is_generic()  { s = (s + "  <generic>"); }
        if entry.is_from_foreign()  { s = (s + "  [foreign]");  }
        if entry.extended      { s = (s + "  [extension]"); }
        return s;
    }
}