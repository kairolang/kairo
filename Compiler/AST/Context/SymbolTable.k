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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import Token::TokenKind::*;
import AST::Context::ASTContext::*;
import Lexer::Immediate::*;

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
enum DeclNameKind derives u8 {
    /// Plain identifier. payload = this TU's imm ident index.
    Identifier = 0,
    /// Overloaded operator. payload = packed op-token kinds (see op_name).
    Operator,
    /// Constructor of the enclosing type scope. payload = 0.
    Constructor,
    /// Destructor of the enclosing type scope. payload = 0.
    /// NOTE: `fn op delete` currently keys as Operator(delete); this kind is
    ///       reserved for when sema canonicalizes lifecycle members.
    Destructor,
}

/// \class DeclName
/// \brief 8-byte lookup key for SymbolTable. kind + u32 payload.
///
/// \invariant Identifier payloads are PER-TU imm indices. A DeclName built
///            in TU A never keys a table of TU B import folding re-interns
///            (RESOLUTION.md hard invariant #2).
class DeclName {
    pub var kind:    DeclNameKind = DeclNameKind::Identifier;
    pub var payload: u32          = u32(-1);

    fn DeclName(self) { }

    static fn ident(imm: u32) -> DeclName {
        var n = DeclName{};
        n.kind    = DeclNameKind::Identifier;
        n.payload = imm;
        return n;
    }

    /// Operator key from the (up to two) operator tokens of `fn op <x>`.
    /// payload = (k0 & 0xFFFF) << 16 | (k1 & 0xFFFF); k1 = TkUnknown for
    /// single-token operators. Deterministic per spelling within a build
    /// TokenKind is stable across TUs, so operator keys, unlike identifier
    /// keys, are safe to compare cross-TU (ADL relies on this).
    static fn op_name(k0: TokenKind, k1: TokenKind) -> DeclName {
        var n = DeclName{};
        n.kind    = DeclNameKind::Operator;
        n.payload = ((static_cast::<u32>(k0) & 0xFFFF) << 16)
                  |  (static_cast::<u32>(k1) & 0xFFFF);
        return n;
    }

    static fn op_name(k0: TokenKind) -> DeclName {
        return DeclName::op_name(k0, TokenKind::TkUnknown);
    }

    /// Context-relative constructor key. The context being queried already
    /// identifies the type, so the key carries none.
    static fn ctor() -> DeclName {
        var n = DeclName{};
        n.kind    = DeclNameKind::Constructor;
        n.payload = 0;
        return n;
    }

    static fn dtor() -> DeclName {
        var n = DeclName{};
        n.kind    = DeclNameKind::Destructor;
        n.payload = 0;
        return n;
    }

    /// The map key. Integer hash, no string compares on the hot path.
    fn as_key(self) -> u64 {
        return (static_cast::<u64>(static_cast::<u8>(self.kind)) << 32)
             |  static_cast::<u64>(self.payload);
    }

    fn is_ident(self) -> bool { return self.kind == DeclNameKind::Identifier;  }
    fn is_op(self)    -> bool { return self.kind == DeclNameKind::Operator;    }
    fn is_ctor(self)  -> bool { return self.kind == DeclNameKind::Constructor; }

    /// A default-constructed / failed-intern name. Never insert these.
    fn is_valid(self) -> bool {
        return (self.kind != DeclNameKind::Identifier) || (self.payload != u32(-1));
    }

    /// Reverse-decode this key to a human-readable name for dumps ONLY.
    /// Never use in a hot path diagnostics/dump.
    fn describe(self, ctx: *ASTContext) -> string {
        switch self.kind {
            case DeclNameKind::Identifier {
                if ctx == &null { return "<ident?>"; }
                var tbl = ctx->get_imm_table();
                if tbl == &null { return "<ident?>"; }
                return tbl->get_ident(self.payload);
            }
            case DeclNameKind::Operator {
                // The operator key packs two u32 TokenKind hashes lossily into
                // one u32 payload   good enough to key/disambiguate, but NOT
                // reversible to a spelling. Callers that have the decl in hand
                // (e.g. the symbol dumper) render the name from the operator's
                // op_token via ctx->get_spelling instead. This is only the
                // keyless fallback for when no decl is available.
                return "op";
            }
            case DeclNameKind::Constructor { return "<ctor>"; }
            case DeclNameKind::Destructor  { return "<dtor>"; }
        }
        return "<name?>";
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
class OverloadCell {
    pub var first: obs::<Decl>;    ///< first decl appended; non-null once the cell exists.
    pub var rest:  vec::<*Decl>;   ///< 2nd+ decls; empty in the common case.

    fn OverloadCell(self) {
        self.first = &null;
    }

    fn append(self, d: *Decl) {
        if self.first == &null {
            self.first = d;
            return;
        }
        self.rest.push_back(d);
    }

    fn size(self) -> usize {
        if self.first == &null { return 0; }
        return 1 + self.rest.size();
    }

    fn get(self, i: usize) -> *Decl {
        if i == 0 { return self.first; }
        if (i - 1) < self.rest.size() { return self.rest[(i - 1)]; }
        return &null;
    }

    fn is_single(self)     -> bool { return (self.first != &null) && (self.rest.empty()); }
    fn is_overloaded(self) -> bool { return !self.rest.empty(); }
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
///   Backed by libcxx::unordered_map for now. This API is the contract; a
///   flat open-addressing u64 map can replace the container later without
///   touching any caller.
class SymbolTable {
    priv var _cells:  libcxx::unordered_map::<u64, OverloadCell>;
    priv var _frozen: bool = false;

    fn SymbolTable(self) {
        self._cells.reserve(16);
        self._frozen = false;
    }

    // --- Population (parse-time only) ----------------------------------------

    fn append(self, name: DeclName, d: *Decl) {
        assert((!self._frozen) && r"SymbolTable::append after freeze: post-parse source tables take no inserts (RESOLUTION.md hard invariant #1)");
        if !name.is_valid() { return; }
        self._cells[name.as_key()].append(d);
    }

    fn append_ident(self, imm: u32, d: *Decl) {
        self.append(DeclName::ident(imm), d);
    }

    fn freeze(self)          { self._frozen = true;  }
    fn is_frozen(self) -> bool { return self._frozen; }

    // --- Lookup ---------------------------------------------------------------

    /// This scope only, no parent walk. Null if absent. Unqualified lookup
    /// (DC parent chain, then import_overlay at TU level) and qualified
    /// lookup (follow decl->dc_symbols per segment) are built on top of
    /// this by NameResolution.
    fn lookup(self, name: DeclName) -> *OverloadCell {
        var it = self._cells.find(name.as_key());
        if it == self._cells.end() { return &null; }
        return &it->second;
    }

    fn lookup_ident(self, imm: u32) -> *OverloadCell {
        return self.lookup(DeclName::ident(imm));
    }

    /// \brief Cross-TU boundary lookup (ImportResolution ONLY).
    ///
    /// \details Frozen tables are keyed by PER-TU imm indices (RESOLUTION.md
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
    static fn lookup_foreign(tbl: *SymbolTable, src_imms: *ImmediateTable,
                             spelling: string) -> *OverloadCell {
        if (tbl == &null) || (src_imms == &null) { return &null; }
        var src_imm = src_imms->find_ident(spelling);
        if src_imm == static_cast::<u32>(-1) { return &null; }  // absent in source
        return tbl->lookup_ident(src_imm);
    }

    fn has(self, name: DeclName) -> bool {
        return self._cells.count(name.as_key()) > 0;
    }

    fn size(self) -> usize {
        return self._cells.size();
    }

    fn empty(self) -> bool {
        return self._cells.size() == 0;
    }

    /// A single row, materialized for dumping.
    class Entry {
        pub var name: DeclName;            ///< reconstructed key; decode with name.describe(ctx).
        pub var cell: obs::<OverloadCell>;
    }

    fn collect_entries(self, out: ref!(vec::<Entry>)) {
        for var it = self._cells.begin(); it != self._cells.end(); ++it {
            var e = Entry{};
            e.name.kind    = static_cast::<DeclNameKind>(static_cast::<u8>((it->first >> 32) & 0xFF));
            e.name.payload = static_cast::<u32>(it->first & 0xFFFFFFFF);
            e.cell         = &(it->second);
            out.push_back(e);
        }
    }
}
