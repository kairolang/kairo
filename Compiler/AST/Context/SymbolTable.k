/// --- The Kairo Project -------------------- AST/Context/SymbolTable.k --- ///
///
///   The REAL per-DeclContext symbol table (see Sema/RESOLUTION.md §1).
///   One SymbolTable per decl-owning scope (TU, module, type, extension).
///   Populated by ASTParse::_build_symbols at parse exit, frozen immediately
///   after. Consumed by ImportResolution / NameResolution / TypeResolution.
///
///   Principle: the AST is the trie; these are per-DeclContext leaf maps.
///   Qualified lookup walks decl -> dc_symbols per segment; there is no
///   parallel scope tree to reconcile.
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
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DepLog::{
    DepLog,
    dep_log_current,
}
import AST::Node::Base::Decl
import Lexer::Immediate::ImmediateTable
import Token::TokenKind::{
    TokenKind,
    canonical_operator_kind,
}

/// \enum DeclNameKind
/// \brief Discriminates the kind of a lookup key.
///
/// \details Names are pure name-domain data: constructing a DeclName never
///          requires type information, which keeps name resolution strictly
///          ahead of type resolution. Constructors/destructors are keyed
///          context-relatively (the queried DeclContext identifies the type),
///          unlike Clang's CanQualType-keyed constructor names   Kairo ctors
///          are only declarable inside the type body, so no global key is
///          ever needed.
pub enum DeclNameKind derives u8 {
    /// Plain identifier. payload = this TU's imm ident index.
    Identifier = 0,
    /// Overloaded operator. payload = packed op-token kinds (see op_name).
    Operator,
    /// Constructor of the enclosing type scope. payload = 0.
    Constructor,
    /// Destructor of the enclosing type scope. payload = 0.
    /// NOTE: `fn op finally` currently keys as Operator(finally); this kind is
    ///       reserved for when sema canonicalizes lifecycle members.
    Destructor,
}

/// \class DeclName
/// \brief 8-byte lookup key for SymbolTable. kind + u32 payload.
///
/// \invariant Identifier payloads are PER-TU imm indices. A DeclName built
///            in TU A never keys a table of TU B import folding re-interns
///            (Compiler/Spec/Pipeline.md hard invariant #2).
pub class DeclName {
    pub var kind:    DeclNameKind = DeclNameKind::Identifier
    pub var payload: u32          = u32::MAX

    fn DeclName(self) { }

    pub static fn ident(imm: u32) -> DeclName {
        var n = DeclName()
        n.kind    = DeclNameKind::Identifier
        n.payload = imm
        return n
    }

    /// Operator key from the (up to two) operator tokens of `fn op <x>`.
    /// payload = (k0 & 0xFFFF) << 16 | (k1 & 0xFFFF); k1 = TkUnknown for
    /// single-token operators. Deterministic per spelling within a build
    /// TokenKind is stable across TUs, so operator keys, unlike identifier
    /// keys, are safe to compare cross-TU (ADL relies on this).
    /// Keyed on the canonical kinds, so a word-form operator (`op bitand`)
    /// and its symbol (`a & b`) are one cell.
    pub static fn op_name(k0: TokenKind, k1: TokenKind) -> DeclName {
        var c0 = canonical_operator_kind(k0)
        var c1 = canonical_operator_kind(k1)
        var n  = DeclName()
        n.kind    = DeclNameKind::Operator
        n.payload = ((c0 as u32) & 0xFFFF) << 16 | (c1 as u32) & 0xFFFF
        return n
    }

    pub static fn op_name(k0: TokenKind) -> DeclName {
        return DeclName::op_name(k0, TokenKind::TkUnknown)
    }

    /// Context-relative constructor key. The context being queried already
    /// identifies the type, so the key carries none.
    pub static fn ctor() -> DeclName {
        var n = DeclName()
        n.kind    = DeclNameKind::Constructor
        n.payload = 0
        return n
    }

    static fn dtor() -> DeclName {
        var n = DeclName()
        n.kind    = DeclNameKind::Destructor
        n.payload = 0
        return n
    }

    /// The map key. Integer hash, no string compares on the hot path.
    pub fn as_key(self) -> u64 {
        return ((self.kind as u8) as u64) << 32 | (self.payload as u64)
    }

    pub fn is_ident(self) -> bool {
        return self.kind == DeclNameKind::Identifier
    }

    pub fn is_op(self) -> bool {
        return self.kind == DeclNameKind::Operator
    }

    fn is_ctor(self) -> bool {
        return self.kind == DeclNameKind::Constructor
    }

    /// A default-constructed / failed-intern name. Never insert these.
    fn is_valid(self) -> bool {
        return self.kind != DeclNameKind::Identifier || self.payload != u32::MAX
    }

    /// Reverse-decode this key to a human-readable name for dumps ONLY.
    /// Never use in a hot path diagnostics/dump.
    pub fn describe(self, ctx: unsafe *ASTContext) -> string {
        match self.kind {
            case DeclNameKind::Identifier {
                if ctx == &null {
                    return "<ident?>"
                }

                var unsafe *tbl = ctx->get_imm_table()
                if tbl == &null {
                    return "<ident?>"
                }

                return tbl->get_ident(self.payload)
            } case DeclNameKind::Operator {
                // The operator key packs two u32 TokenKind hashes lossily into
                // one u32 payload   good enough to key/disambiguate, but NOT
                // reversible to a spelling. Callers that have the decl in hand
                // (e.g. the symbol dumper) render the name from the operator's
                // op_token via ctx->get_spelling instead. This is only the
                // keyless fallback for when no decl is available.
                return "op"
            } case DeclNameKind::Constructor {
                return "<ctor>"
            } case DeclNameKind::Destructor {
                return "<dtor>"
            }
        }
    }
}

/// \class OverloadCell
/// \brief All decls bound to one DeclName within one scope. SmallVec<*Decl,1>
///        in spirit: most names bind exactly one decl, so the first pointer
///        is inline and the heap vec only exists for overload sets.
///
/// \details Pre-NameResolution a cell is a RAW append-only stack: fwd decl +
///          definition, primary + specializations, duplicate names all just
///          pile in. The parser records; sema judges (redefinition errors,
///          Redeclarable chain linking, and overload validation are N(a)'s
///          job, nowhere else).
pub class OverloadCell {
    pub var first: unsafe *Decl ///< first decl appended; non-null once the cell exists.
    pub var rest:  cxx::std::vector<unsafe *Decl> ///< 2nd+ decls; empty in the common case.

    pub fn OverloadCell(self) {
        self.first = &null
    }

    pub fn append(self, d: unsafe *Decl) {
        if self.first == &null {
            self.first = d
            return
        }

        self.rest.push_back(d)
    }

    pub fn size(self) -> usize {
        if self.first == &null {
            return 0
        }

        return 1 + self.rest.size()
    }

    pub fn get(self, i: usize) -> unsafe *Decl {
        if i == 0 {
            return self.first
        }

        if i - 1 < self.rest.size() {
            return self.rest[i - 1]
        }

        return &null
    }

    pub fn is_single(self) -> bool {
        return self.first != &null && self.rest.empty()
    }

    pub fn is_overloaded(self) -> bool {
        return !self.rest.empty()
    }
}

/// \class SymbolTable
/// \brief Per-DeclContext leaf map: DeclName -> OverloadCell.
///
/// \par Lifecycle
///   parse:  ASTParse::_build_symbols appends every named decl of the scope.
///           Append-only multimap, ZERO diagnostics, ZERO judgment.
///   freeze: at parse exit. FROZEN MEANS FROZEN (hard invariant #1): later
///           phases add links on NODES (redecl chains), overlays
///           (TranslationUnit::import_overlay), or separate registries
///           (instantiations) never entries here.
///   read:   ImportResolution verifies imported names exist; NameResolution
///           binds idents and validates cells; TypeResolution resolves type
///           names through the same maps.
///
/// \par Container
///   MapVector: collect_entries walks the cells in INSERTION order, which is
///   declaration order. That walk feeds import folding and the redecl /
///   name / operator checks, where "the first one" is observable -- it is
///   a language rule, not an accident of bucket order (which differed
///   between standard libraries). Keys are DeclName::as_key, whose top 24
///   bits are 0, so DenseMap's reserved ~0 / ~0-1 are unreachable.
///
///   Cells live in the owning ASTContext's arena, the map holds their
///   address: lookup() hands out an *OverloadCell that must survive later
///   appends, and MapVector's values move as it grows. One arena per
///   context, not per table -- there is a table per DeclContext.
pub class SymbolTable {
    priv var _cells:  llvm::MapVector<u64, unsafe *OverloadCell>
    priv var _ctx:    unsafe *ASTContext ///< arena the cells come from.
    priv var _frozen: bool                                       = false

    fn SymbolTable(self, ctx: unsafe *ASTContext) {
        self._ctx    = ctx
        self._frozen = false
    }

    /// # Population (parse-time only)

    pub fn append(self, name: DeclName, d: unsafe *Decl) {
        eval if defined!(DEBUG) {
            if self._frozen {
                kairo::std::ice_fail(
                    r"SymbolTable::append after freeze: post-parse source tables take no inserts (Compiler/Spec/Pipeline.md hard invariant #1)",
                )
            }
        }

        if !name.is_valid() {
            return
        }

        var unsafe **slot = unsafe &self._cells[name.as_key()]
        if *slot == &null {
            *slot = self._ctx->alloc<OverloadCell>()
        }

        (*slot)->append(d)
    }

    pub fn append_ident(self, imm: u32, d: unsafe *Decl) {
        self.append(DeclName::ident(imm), d)
    }

    pub fn freeze(self) {
        self._frozen = true
    }

    pub fn is_frozen(self) -> bool {
        return self._frozen
    }

    /// # Lookup

    /// This scope only, no parent walk. Null if absent. Unqualified lookup
    /// (DC parent chain, then import_overlay at TU level) and qualified
    /// lookup (follow decl->dc_symbols per segment) are built on top of
    /// this by NameResolution.
    pub fn lookup(self, name: DeclName) -> unsafe *OverloadCell {
        // THE chokepoint of name-level dependency logging: every lookup of
        // every pass, hit or miss, ends in this probe, so logging here needs
        // no cooperation from the forty-odd callers (AST/Context/DepLog.k).
        var unsafe *deps = dep_log_current()
        if deps != &null {
            deps->probe(self._dep_root(), (unsafe ((&self) as unsafe *void)) as usize as u64, name.as_key())
        }

        var unsafe *it = self._cells.find(name.as_key())
        if it == self._cells.end() {
            return &null
        }

        return it->second
    }

    fn lookup_ident(self, imm: u32) -> unsafe *OverloadCell {
        return self.lookup(DeclName::ident(imm))
    }

    /// The TU this table's names belong to, as DepLog compares it.
    priv fn _dep_root(self) -> u64 {
        if self._ctx == &null {
            return 0
        }

        return (self._ctx->tu as usize as u64)
    }

    /// The scope this table was last installed on (DeclContext::set_symbols),
    /// for the dependency dump to name the scope a logged probe was made in.
    /// A file's table is shared with its implicit module, which is the same
    /// scope by another handle; the dump treats both as the file scope.
    pub var dep_scope: unsafe *void = &null

    /// \brief Cross-TU boundary lookup (ImportResolution ONLY).
    ///
    /// \details Frozen tables are keyed by PER-TU imm indices (Compiler/Spec/Pipeline.md
    ///          hard invariant #2): a raw u32 from the importing TU is
    ///          meaningless in the source TU. At the import boundary we spell
    ///          the importing token and re-intern it against the SOURCE TU's
    ///          imm table to obtain the source-local imm, then key the source
    ///          frozen table with it. One string trip per imported name, at I
    ///          time only the hot unqualified path (SymbolTable::lookup /
    ///          NameLookup primitives) stays integer-keyed and is never touched
    ///          by this.
    ///
    ///          The probe into the source imm table is NON-MUTATING
    ///          (ImmediateTable::find_ident): a miss means the spelling was
    ///          never interned in the source and is therefore provably absent
    ///          from its symbol tables. Ordinary imports resolve here; identity
    ///          imports, operators, and ctors do not route through this shim
    ///          (operator keys are build-stable and compared cross-TU directly;
    ///          ctors are context-relative).
    ///
    /// \param tbl       the SOURCE TU's frozen SymbolTable (the scope to search).
    /// \param src_imms  the SOURCE TU's imm table (tcm->get_imm_table_for_fid).
    /// \param spelling  the imported name as spelled in the importing TU.
    /// \return the matching OverloadCell in \p tbl, or null (absent/foreign).
    pub static fn lookup_foreign(tbl:            unsafe *SymbolTable,
                                 src_imms:       unsafe *ImmediateTable,
                                 const spelling: string) -> unsafe *OverloadCell {
        if tbl == &null || src_imms == &null {
            return &null
        }

        var src_imm = src_imms->find_ident(spelling)
        if src_imm != ((-1) as i32 as u32) {
            return tbl->lookup_ident(src_imm)
        }

        // Never interned there: no key for lookup() to log, and still a
        // dependency on the name staying absent. (The `#name` retry below is
        // logged by lookup() when it has a key; this row is the plain name.)
        var unsafe *deps = dep_log_current()
        if deps != &null {
            deps->probe_spelled(tbl->_dep_root(), tbl as usize as u64, spelling)
        }

        // `#name` is the escape for a foreign name that is a Kairo keyword:
        // `cxx::std::#thread`. Only on a miss, so a Kairo name declared with
        // the `#` keeps it, and a C or C++ name can never contain one.
        if spelling.size() > 1 && spelling[0] == ('#' as u8) {
            src_imm = src_imms->find_ident(spelling.subslice(1, spelling.size() - 1))
            if src_imm != ((-1) as i32 as u32) {
                return tbl->lookup_ident(src_imm)
            }
        }

        return &null // absent in source
    }

    fn has(self, name: DeclName) -> bool {
        return self._cells.count(name.as_key()) > 0
    }

    pub fn size(self) -> usize {
        return self._cells.size()
    }

    fn empty(self) -> bool {
        return self._cells.size() == 0
    }

    /// A single row, materialized for dumping.
    pub class Entry {
        pub var name: DeclName             ///< reconstructed key; decode with name.describe(ctx).
        pub var cell: unsafe *OverloadCell
    }

    pub fn collect_entries(self, @inout out: cxx::std::vector<Self::Entry>) {
        for var unsafe *it = self._cells.begin(); it != self._cells.end(); ++it {
            var e = Self::Entry{}
            e.name.kind    = (((it->first >> 32 & 0xFF) as u8) as DeclNameKind)
            e.name.payload = ((it->first & 0xFFFFFFFF) as u32)
            e.cell         = it->second
            out.push_back(e)
        }
    }
}
