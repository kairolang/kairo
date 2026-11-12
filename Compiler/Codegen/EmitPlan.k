/// --- The Kairo Project --------------------------- Codegen/EmitPlan.k --- ///
///
///   \brief Per emitted TU, work out every declaration the C++ needs, how
///          much of each (`class X;` or the body-less definition), and the
///          order they must appear in.
///
///   \detail
///     Compiler/Spec/Imports.md#model: imports are erased at name resolution.
///     After N and ChainBinding every use site holds a `*Decl`, and the decl
///     knows its own home through the DeclContext chain. Nothing here reads an
///     `ImportDecl`. What a C++ TU needs is a DECLARATION of everything it
///     names -- own decls included, since the class definition text must
///     come from one emitter wherever it lands (invariant 12).
///
///     Four tiers (Compiler/Spec/Codegen.md#tiers plus the instantiation tier):
///
///       0  every namespace-scope type as a forward declaration, and every
///          extension scope (`struct __kairo_ext_X;`) the plan touches
///       1  type definitions, topologically sorted on Complete edges only;
///          an extension scope's definition after its target's
///       2  function and namespace-scope variable declarations (`extern`),
///          any order (extension members are not here: they are static
///          members of their scope)
///       3  explicit instantiations: `template class X<A>;` in the instance's
///          home TU, `extern template ...` everywhere else
///
///     Three modes decide the ROOTS; the closure and ordering are identical:
///
///       Preamble  every own decl (all visibilities) + everything foreign it
///                 reaches. What the TU's .cpp starts with.
///       Header    own `pub` decls + what they reach. What the module's
///                 .hh contains; the emitter turns a foreign Complete entry
///                 into an `#include` and a foreign Fwd entry into a
///                 forward declaration.
///       Include   a Header's roots and bodies, emitted as a Preamble is:
///                 foreign entries inline, no directive. What
///                 `#include "foo.k"` gives a C++ TU (Backend/
///                 IncludeEmitter.k): a priv or internal decl gets there
///                 only when an inline or template body names it.
///
///     A Complete cycle is TypeCycleCheck's to report, in sema; here the
///     sort asserts. Output is ordered by (fid, offset) inside a tier so the
///     same input produces the same plan on every machine.
///
///   Import law: CodegenContext only.
///
///   Phase: CODEGEN (produces CodegenPhase::Planned)
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
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
}
import AST::Context::SymbolTable::OverloadCell
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LowerTargets,
    WellKnownType,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    BuiltinType,
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    AlignOfExpr,   BinaryOperatorExpr, CallExpr, ClosureExpr, ConstraintExpr, SizeOfExpr,
    TypeTraitExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    DeclStmt,
    IterKind,
    RangedForStmt,
}
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, GenericParamType,
    NullableType,     PointerType,      TupleType,      TypeExpr,            ValueOp,
}
import AST::ParamMode::ParamMode
import AST::VisibilityFacts::{
    default_visibility_of,
    is_operator_fn,
    tu_module_dir,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
import Codegen::CodegenICE::codegen_ice
import Codegen::Emit::CXXSpell::{
    CXXSpell,
    VIS_INTERNAL,
    VIS_NONE,
    VIS_PRIV,
    VIS_PROT,
    VIS_PUB,
}
import Codegen::Emit::EmitWitness::{
    EmitWitness,
    WitnessPiece,
}
import Codegen::PlanVisitors::{
    EarlyNeeds,
    GlobalInitReach,
    HoistedLocals,
}
import Codegen::Sink::EmitSink::EmitSink
import Location::SourceRange::SourceRange
import std::io

/// A module's header carries what another module may name. `priv` is out by
/// definition, and so is `internal`: it is visible within its own module and
/// nowhere else, which is exactly what a header crosses.
pub fn _hidden_in_header(v: u8) -> bool {
    return v == VIS_PRIV() || v == VIS_INTERNAL()
}

pub enum PlanNeed derives u8 {
    Fwd = 0,  ///< `class X;` is enough.
    Complete, ///< the body-less definition must precede.
}

pub enum PlanTier derives u8 {
    FwdDecls = 0,
    Definitions,
    Functions,
    Instantiations,
}

pub enum PlanMode derives u8 {
    Preamble = 0,
    Header,
    Include,
}

/// `struct N::__kairo_ext_X`: every extension member of target X declared in
/// namespace N, as one struct of static members (Compiler/Spec/Generics.md#partial-selection). One per
/// (N, X); every extend block in that scope contributes. Always COMPLETE --
/// all its blocks, priv members included -- so its text is the same in every
/// TU and header that carries it (invariant 11).
pub class ExtScope {
    pub var ns:   cxx::std::vector<string>
    pub var name: string                   ///< `__kairo_ext_X`.
    /// The target's layout decl for a record (a generic one's primary), or
    /// null for a builtin, which is keyed by `target_ty` instead.
    pub var target: unsafe *Decl = &null
    /// The record target's TEMPLATE (EmitPlan::_scope_key): what scopes are
    /// matched on, so every specialization's extensions share one struct.
    pub var key:       unsafe *Decl = &null
    pub var target_ty: unsafe *Type = &null
    /// The first extend block in source order: where the scope sits.
    pub var anchor: unsafe *Declarations::ExtensionDecl = &null
    /// Every member, in source order, parallel to the block it was written in.
    pub var members: cxx::std::vector<unsafe *Declarations::FunctionDecl>
    pub var exts:    cxx::std::vector<unsafe *Declarations::ExtensionDecl>
    /// What the definition and its operator forwarders need complete: the
    /// target, and every by-value record a forwarder's signature names (a
    /// forwarder is an inline DEFINITION, and a definition lays them out).
    pub var deps: cxx::std::vector<unsafe *Decl>
    /// A member is reachable from the plan's roots. Header mode defines only
    /// reachable scopes; an unreachable one is declared for a friend line.
    pub var reachable: bool = false

    fn ExtScope(self) { }
}

/// What a record's definition befriends (EmitPlan::file_friends): the
/// entities of its OWN file that may reach its `private:` / `protected:`
/// members, read off that file's declarations alone, so the list -- like
/// the rest of the record's text -- is the same in every TU, header and
/// include stream that defines the record. Friends change neither layout
/// nor mangling on any target; the access levels do, which is why they
/// cannot vary by view and these lines carry the difference instead.
pub class FileFriends {
    /// The record has a non-public member at all; nothing else is filled
    /// when it has none.
    pub var needed: bool = false
    /// Every other outermost record of the file, and every hoisted local
    /// one (`friend ::ns::X;`, `template <...> friend class ::ns::G;`): a
    /// friend class covers its members and nested classes.
    pub var records: cxx::std::vector<unsafe *Decl>
    /// The file's free functions in the record's namespace, generic ones
    /// and hoisted locals included (unqualified `friend R f(P);`).
    pub var fns: cxx::std::vector<unsafe *Declarations::FunctionDecl>
    /// Parallel to `fns`: befriended by its qualified name, after its own
    /// declaration ahead of every record (EmitPlan::friend_early).
    pub var far: cxx::std::vector<u8>
    /// One extension of each scope struct in the record's namespace whose
    /// target is another type (unqualified `friend struct __kairo_ext_X;`);
    /// the record's own scopes are friend_scopes_of's.
    pub var scopes: cxx::std::vector<unsafe *Declarations::ExtensionDecl>
    /// The interfaces the file declares the record implements, with what
    /// they derive: their witness primaries forward to its members.
    pub var ifaces: cxx::std::vector<unsafe *Decl>
    /// The program's `main`, when it is in this file.
    pub var main: unsafe *Declarations::FunctionDecl = &null
    /// The file's namespace-scope variables in the record's namespace
    /// initialized through a thunk (GlobalInitReach): the thunk is the
    /// friend (`friend T __kairo_ginit_x();`).
    pub var globals: cxx::std::vector<unsafe *Declarations::VariableDecl>

    fn FileFriends(self) { }
}

pub class PlanEntry {
    pub var decl: unsafe *Decl = &null
    pub var need: PlanNeed     = PlanNeed::Fwd
    pub var tier: PlanTier     = PlanTier::FwdDecls
    pub var fid:  u32          = 0
    pub var off:  usize        = 0
    pub var own:  bool         = false              ///< declared by the TU being emitted.
    /// Tier 3 only: the instance. `decl` is the primary.
    pub var inst: unsafe *InstanceEntry = &null
    /// Tier 3 only: this TU defines the instantiation.
    pub var is_home: bool = false
    /// Tiers 0 and 1: the extension scope this entry declares or defines,
    /// or null. `decl` is then the scope's anchor, for position only.
    pub var scope: unsafe *ExtScope = &null
    /// Tiers 0 and 1: the witness piece this entry declares or defines
    /// (Compiler/Spec/Witnesses.md#emission), or null. `decl` is then its InterfaceDecl.
    pub var witness: unsafe *WitnessPiece = &null
    /// Tier 0 only, with `witness` a primary: this entry defines its
    /// concept, not its forward declaration.
    pub var is_concept: bool = false
    /// Tier 1 only: an early item (EmitPlan::early, Compiler/Spec/Eval.md#value-nodes) -- a
    /// compile-time body or an eval binding this entry DEFINES, ahead of
    /// the records whose types need it. `decl` is the item too.
    pub var eval_item: unsafe *Decl = &null

    fn PlanEntry(self) { }
}

/// _needs_complete(who, *) for one who (EmitPlan::_need_row): true for dep
/// exactly when dep is in `direct` or layout_decl(dep) is in `layout`.
pub struct NeedRow {
    var direct: llvm::DenseSet<u64>
    var layout: llvm::DenseSet<u64>
}

/// One memoized _names_vp_template answer set (EmitPlan::_vp_row).
pub struct VpNames {
    var vp:   llvm::DenseSet<u64>
    var nest: llvm::DenseSet<u64>
}

/// # Graph-independent order and homes (Compiler/Spec/Incremental.md#shared-across-graphs)
///
/// A TU's stream is its incremental object key, and one cache is shared by
/// every graph that holds the TU (kairo, kcc, kfmt are built from one tree).
/// Two things the plan used to read were facts of the GRAPH, not of the TU:
/// file ids (minted in the PP walk's order from the entry, so Kairo.k and
/// Kcc.k number the same modules differently) ordered every tier, and an
/// instance's home was its first namer in the one-thread order (which the
/// entry decides too). Both are replaced here for the length of a codegen,
/// set by the driver before any plan runs and read-only after.

/// fid -> its rank in the build's files sorted by module path (set_file_ranks);
/// u32::MAX, or past the end, for a file that has none (it sorts after every
/// ranked file, by fid).
var _FILE_RANK: cxx::std::vector<u32> = cxx::std::vector<u32>()
/// The import graph (set_graph): per Kairo module fid, its import edge
/// targets in declaration order (empty for any other file), and the
/// prelude's fid (0: none).
var _G_EDGES:   cxx::std::vector<cxx::std::vector<u32>> = cxx::std::vector<cxx::std::vector<u32>>()
var _G_IS_MOD:  cxx::std::vector<u8>                    = cxx::std::vector<u8>()
var _G_PRELUDE: u32                                     = 0
/// InstanceEntry (by address) -> the fid of its codegen home (assign_homes).
/// An instance not in it keeps InstanceEntry::home_fid.
var _HOMES: llvm::DenseMap<u64, u32> = llvm::DenseMap<u64, u32>()

/// Where a codegen is in setting the facts above: set_file_ranks, then
/// set_graph, then assign_homes (whose homing plans run on Graphed), then
/// reset_graph_facts. All four are the driver thread's, between pool
/// waits, so every plan of the codegen reads them settled. A plan outside
/// that window (a header, --print-cxx, an emptiness probe) runs on Unset
/// and gets fid order and Sema's homes, by design; one between the ranks
/// and the graph would rank by a file table with no import walk to match.
pub enum GraphPhase derives u8 {
    Unset = 0,
    Ranked,
    Graphed,
    Homed,
}

var _G_PHASE: GraphPhase = GraphPhase::Unset

pub class EmitPlan derives RecursiveASTVisitor<EmitPlan> {
    priv var _cg:    unsafe *CodegenContext
    priv var _spell: CXXSpell
    priv var _mode:  PlanMode               = PlanMode::Preamble
    priv var _home:  u32                    = 0

    priv var _set:   cxx::std::vector<unsafe *Decl>
    priv var _need:  cxx::std::vector<PlanNeed>
    priv var _queue: cxx::std::vector<usize>
    priv var _insts: cxx::std::vector<unsafe *InstanceEntry>
    /// _rank_of's walk: fid -> this TU's order (u32::MAX: not met).
    priv var _rank:   cxx::std::vector<u32>
    priv var _ranked: bool                  = false
    /// Member-template instances admitted (no tier-3 line, so not _insts):
    /// their reach is followed once.
    priv var _members: cxx::std::vector<unsafe *InstanceEntry>
    /// Every extension scope the plan touches. Indexed while the closure
    /// runs (it grows); PlanEntry::scope points in only once it is done.
    priv var _scopes: cxx::std::vector<ExtScope>
    /// Every witness piece the plan holds: interface primaries and row
    /// specializations. Index-based while the closure runs, as _scopes.
    priv var _witnesses: cxx::std::vector<WitnessPiece>
    /// Rows whose ConformanceRow::assoc_rows _witness_row has followed.
    priv var _assoc_seen: cxx::std::vector<unsafe *ConformanceRow>

    /// Memo for param_by_value: (primary, index) -> answer. Pairs, linear
    /// scan; a build has tens of generic primaries, not thousands.
    priv var _pbv_key: cxx::std::vector<u64>
    /// Records _duck_reach has walked, once each.
    priv var _duck_seen: cxx::std::vector<unsafe *Decl>
    priv var _pbv_val:   cxx::std::vector<u8>
    priv var _pbv_depth: usize                          = 0

    pub var entries: cxx::std::vector<PlanEntry>

    /// Some type the plan admits is a Kairo `fn(A) -> R` value (a
    /// signature, a field, a local, a closure in a body): the preamble
    /// must define `::__kairo_fn` (InterfaceEmitter::_fn_value_helper).
    /// Only then, so a TU that names none keeps its text.
    pub var needs_fn_value: bool = false
    /// A body holds a `try`'s raw-storage slot (PanicLowering) with no Panic
    /// result in sight: a `try` with only C++ exception arms whose value is
    /// put in a slot. The preamble must define `::__kairo_raw`, which it
    /// otherwise writes with the Panic lang item's helpers.
    pub var needs_raw_slot: bool = false
    /// A function under a `<T: type>` parameter: its body's member calls
    /// through T go out wrapped in `(::__kairo_nopanic(), call)`, and the
    /// preamble must define the tag (InterfaceEmitter::_nopanic_helpers).
    pub var needs_nopanic: bool = false
    /// A function that returns a value holds an `eval for` or a `for` over
    /// a pack: a `return` out of one of its copies is built into a
    /// `::__kairo_slot<R>` (EmitIR::_ef_slot_decl), so the preamble must
    /// define the constructor slot helpers. Only then, so other TUs keep
    /// their text. `_ef_value_fn` is the walk's current function's answer.
    pub var needs_ef_slot: bool = false
    /// A body holds a deferred f-string hole (CallExpr::fmt_dyn): the
    /// preamble must define `::__kairo_fmt_put` (LowerTargets::fmt_dyn).
    /// Only then, so other TUs keep their text.
    pub var  needs_fmt_dyn: bool = false
    priv var _ef_value_fn:  bool = false
    /// Compile-time string literals too long for `__kairo_estr<...>`
    /// (LowerTargets::eval_str_inline_max, Compiler/Spec/Eval.md#value-nodes), once each by
    /// content: InterfaceEmitter defines each as a named `inline constexpr`
    /// array at global scope, ahead of every body and type that spells it.
    /// Parallel: the bytes, their count, their eval_str_hash.
    pub var big_str_bytes:  cxx::std::vector<kairo::std::ConstPtr<u8>>
    pub var big_str_lens:   cxx::std::vector<usize>
    pub var big_str_hashes: cxx::std::vector<u64>
    /// A type the plan admits holds a string value node (a string literal
    /// in an eval class's value argument, Compiler/Spec/Eval.md#eval-classes): its bytes are
    /// `__kairo_estr<...>`, so the eval helpers are written.
    pub var needs_eval_str: bool = false
    /// A record defined here befriends the program's `main`
    /// (FileFriends::main): `friend int ::main(...)` names it qualified, so
    /// InterfaceEmitter declares it at global scope ahead of every record.
    pub var main_friend: unsafe *Declarations::FunctionDecl = &null
    /// Functions a friend line names qualified (FileFriends::far): each is
    /// declared in its own namespace ahead of the records, by its own
    /// declaration's text.
    pub var friend_early: cxx::std::vector<unsafe *Declarations::FunctionDecl>

    /// Nothing of this TU's own to define. Written once, at the end of run().
    priv var _empty: bool = true
    /// run() was called: before it, _empty's true is no verdict.
    priv var _ran: bool = false
    /// This is _find_escaping's own plan, made while it fills the TU's
    /// cxx_escaping: it never fills it itself. The TU's flag says Done only
    /// once the set is whole.
    priv var _escaping_probe: bool = false

    /// The early items (Compiler/Spec/Eval.md#value-nodes): every compile-time body (eval fn,
    /// eval or constexpr method, eval field thunk) and eval binding that a
    /// DECLARATION's type names through a computed value (`[i32; f(3)]`,
    /// `Buf<twice(1)>`, `Grid<Pt(2, 3)>`), and everything those read,
    /// transitively. C++ evaluates such a type where the declaration is
    /// written, in the interface, so each item is defined in tier 1 ahead of
    /// the records needing it (an entry with eval_item), and declared ahead
    /// of all of tier 1 (InterfaceEmitter); EmitIR then skips them.
    pub var early: cxx::std::vector<unsafe *Decl>
    /// Order edges among tier-1 entries that involve an early item:
    /// _eo_who[i] is written after _eo_dep[i].
    priv var _eo_who: cxx::std::vector<unsafe *Decl>
    priv var _eo_dep: cxx::std::vector<unsafe *Decl>
    /// EarlyNeeds per item, flattened: for item _en_key[i], _en_val[i] is an
    /// item it reads (kind 0), one it evaluates at its definition (1), or a
    /// record it needs complete (2).
    priv var _en_done: cxx::std::vector<unsafe *Decl>
    priv var _en_key:  cxx::std::vector<unsafe *Decl>
    priv var _en_kind: cxx::std::vector<u8>
    /// _set's index by decl address: _admit asked _index_of for every
    /// use, a linear scan of the set. _set only grows, at one push site.
    priv var _set_at: llvm::DenseMap<u64, u64>
    /// _names_vp_template per `who`: the decls a record's definition
    /// names through a value-parameter template (vp) or as the owner of a
    /// nested type (nest), from one walk; _needs_complete asked it per pair.
    priv var _vp_memo:   llvm::DenseMap<u64, u64>
    priv var _vp_rows:   cxx::std::vector<VpNames>
    priv var _need_memo: llvm::DenseMap<u64, u64>
    priv var _need_rows: cxx::std::vector<NeedRow>
    priv var _en_val:    cxx::std::vector<unsafe *Decl>

    /// An Include plan for a C++ TU inside this TU's module (IncludeEmitter):
    /// `prot` declarations are its to see (AST/VisibilityFacts.k). A Header
    /// has no includer, so it carries `pub` only.
    pub var host_in_module: bool = false
    /// The root rule before the default became `priv` / `prot`: only a
    /// written `priv` (or `internal`) is left out. _find_escaping's nested
    /// plan, whose answer decides which hidden decls go to an anonymous
    /// namespace (CXXSpell::is_anon reads written visibility only).
    pub var legacy_roots: bool = false

    pub fn EmitPlan(self, cg: unsafe *CodegenContext, mode: PlanMode = PlanMode::Preamble) {
        self._cg    = cg
        self._spell = CXXSpell(cg)
        self._mode  = mode
    }

    /// ICE naming the Kairo source at \p at (CodegenICE).
    priv fn _ice(self, at: SourceRange, const msg: string) {
        codegen_ice(self._cg->ctx, at, msg)
    }

    fn mode(self) -> PlanMode {
        return self._mode
    }

    fn home(self) -> u32 {
        return self._home
    }

    /// The tier-3 instances the plan admitted (run() first).
    pub fn instances(self) -> unsafe *cxx::std::vector<unsafe *InstanceEntry> {
        return unsafe &self._insts
    }

    /// \brief the build's file order: \p keys[i] names \p fids[i] (a module
    ///        path, or a file name for a file that has none), and every plan
    ///        sorts by the rank of its key instead of by fid.
    ///
    /// \details Fids are minted in the order the PP walk meets files from
    ///          the entry, so two entries over one tree number its modules
    ///          differently, and a TU's stream (its object key) differed
    ///          between kairo and kcc in order alone. Ties (two files, one
    ///          key) go by fid; the caller makes keys unique where it can.
    ///          Driver thread, before any plan of the codegen runs.
    pub static fn set_file_ranks(const keys: cxx::std::vector<string>,
                                 const fids: cxx::std::vector<u32>) {
        EmitPlan::_graph_step(GraphPhase::Unset, GraphPhase::Ranked)
        var ix = cxx::std::vector<usize>()
        for var i: usize = 0; i < keys.size(); ++i {
            ix.push_back(i)
        }

        var *kp = &keys
        var *fp = &fids
        llvm::sort(
            ix.begin(),
            ix.end(),
            fn (a: usize, b: usize) |kp, fp| -> bool {
                if (*kp)[a] != (*kp)[b] {
                    return (*kp)[a] < (*kp)[b]
                }

                return (*fp)[a] < (*fp)[b]
            },
        )

        _FILE_RANK.clear()
        for var r: usize = 0; r < ix.size(); ++r {
            var f = fids[ix[r]]
            if f == u32::MAX {
                continue
            }

            while _FILE_RANK.size() <= (f as usize) {
                _FILE_RANK.push_back(u32::MAX)
            }

            _FILE_RANK[f as usize] = (r as u32)
        }
    }

    /// \brief the build's import graph: \p edges[i] are module \p mods[i]'s
    ///        import edge targets in declaration order (TranslationUnit::
    ///        import_edges), \p prelude the prelude's fid (0: none). What a
    ///        TU's own file order (_rank_of) and assign_homes walk.
    pub static fn set_graph(const mods:  cxx::std::vector<u32>,
                            const edges: cxx::std::vector<cxx::std::vector<u32>>,
                            prelude:     u32) {
        EmitPlan::_graph_step(GraphPhase::Ranked, GraphPhase::Graphed)
        _G_EDGES.clear()
        _G_IS_MOD.clear()
        for var i: usize = 0; i < mods.size(); ++i {
            var f = (mods[i] as usize)
            while _G_EDGES.size() <= f {
                _G_EDGES.push_back(cxx::std::vector<u32>())
                _G_IS_MOD.push_back(0 as u8)
            }

            _G_EDGES[f]  = edges[i]
            _G_IS_MOD[f] = (1 as u8)
        }

        _G_PRELUDE = prelude
    }

    /// Whether module \p from imports \p to, transitively (set_graph's
    /// edges); \p memo holds each asked module's marks.
    static fn _reaches(memo: *cxx::std::vector<cxx::std::vector<u8>>, from: u32, to: u32) -> bool {
        while memo->size() <= (from as usize) {
            memo->push_back(cxx::std::vector<u8>())
        }

        if (*memo)[from as usize].empty() {
            var marks = cxx::std::vector<u8>()
            marks.resize(_G_EDGES.size() + 1, 0 as u8)
            var stack = cxx::std::vector<u32>()
            if EmitPlan::_is_mod(from) {
                for var t: u32 in _G_EDGES[from as usize] {
                    stack.push_back(t)
                }
            }

            while !stack.empty() {
                var f = stack[stack.size() - 1]
                stack.pop_back()
                if !EmitPlan::_is_mod(f) || marks[f as usize] != (0 as u8) {
                    continue
                }

                marks[f as usize] = (1 as u8)
                for var t: u32 in _G_EDGES[f as usize] {
                    stack.push_back(t)
                }
            }

            (*memo)[from as usize] = marks
        }

        var *mk = &(*memo)[from as usize]
        return (to as usize) < mk->size() && (*mk)[to as usize] != (0 as u8)
    }

    static fn _is_mod(f: u32) -> bool {
        return (f as usize) < _G_IS_MOD.size() && _G_IS_MOD[f as usize] != (0 as u8)
    }

    /// \brief the sort key of \p fid in THIS TU: the order in which a
    ///        depth-first walk of the imports from this TU (then from the
    ///        prelude) meets the file, then every other file by module path
    ///        (set_file_ranks), then by fid.
    ///
    /// \details The walk is the one the PP's dependency scan makes from the
    ///          entry, which mints fids, so the entry TU's order is what
    ///          ordering by fid gave; but it starts from this TU, so it reads
    ///          only this TU's own imports, transitively: the same in every
    ///          graph that holds the TU (Compiler/Spec/Incremental.md#shared-across-graphs).
    fn _rank_of(self, fid: u32) -> u64 {
        eval if defined!(DEBUG) {
            if _G_PHASE == GraphPhase::Ranked {
                kairo::std::ice_fail(
                    r"EmitPlan: a plan ranked files between set_file_ranks and set_graph (driver schedule bug)",
                )
            }
        }

        if !self._ranked {
            self._rank_walk()
        }

        if (fid as usize) < self._rank.size() && self._rank[fid as usize] != u32::MAX {
            return self._rank[fid as usize] as u64
        }

        if (fid as usize) < _FILE_RANK.size() && _FILE_RANK[fid as usize] != u32::MAX {
            return ((1 as u64) << 32) + (_FILE_RANK[fid as usize] as u64)
        }

        return ((2 as u64) << 32) + (fid as u64)
    }

    fn _rank_walk(self) {
        self._ranked = true
        var next: u32 = 0
        var roots     = cxx::std::vector<u32>()
        roots.push_back(self._home)
        if _G_PRELUDE != 0 {
            roots.push_back(_G_PRELUDE)
        }

        for var r: u32 in roots {
            if !EmitPlan::_is_mod(r) {
                continue
            }

            var stack = cxx::std::vector<u32>()
            stack.push_back(r)
            while !stack.empty() {
                var f = stack[stack.size() - 1]
                stack.pop_back()
                while self._rank.size() <= (f as usize) {
                    self._rank.push_back(u32::MAX)
                }

                if self._rank[f as usize] != u32::MAX {
                    continue
                }

                self._rank[f as usize] = next
                next += 1
                // Children in reverse, so the first import is walked first.
                var *es = &_G_EDGES[f as usize]
                var k   = es->size()
                while k > 0 {
                    k -= 1
                    var t = (*es)[k]
                    if EmitPlan::_is_mod(t)
                        && ((t as usize) >= self._rank.size()
                            || self._rank[t as usize] == u32::MAX) {
                        stack.push_back(t)
                    }
                }
            }
        }
    }

    /// The codegen home of \p ie: assign_homes' choice, else its home_fid.
    pub static fn home_of(ie: unsafe *InstanceEntry) -> u32 {
        var it = _HOMES.find(ie as usize as u64)
        if it != _HOMES.end() {
            return it->second
        }

        return ie->home_fid
    }

    /// One step of GraphPhase, which only runs forward from \p from: a
    /// fact set out of order is read by plans that assume the ones before it.
    static fn _graph_step(from: GraphPhase, to: GraphPhase) {
        eval if defined!(DEBUG) {
            if _G_PHASE != from {
                kairo::std::ice_fail(
                    r"EmitPlan: graph facts set out of order (set_file_ranks, set_graph, assign_homes, reset_graph_facts)",
                )
            }
        }

        _G_PHASE = to
    }

    /// Forgets set_file_ranks and assign_homes: the next codegen sets its own.
    pub static fn reset_graph_facts() {
        _G_PHASE = GraphPhase::Unset
        _FILE_RANK.clear()
        _HOMES.clear()
        _G_EDGES.clear()
        _G_IS_MOD.clear()
        _G_PRELUDE = 0
    }

    /// \brief each tier-3 instance's home, from the TUs that hold it and
    ///        nothing else in the graph.
    ///
    /// \param plans  every TU of this codegen, its Preamble plan run.
    /// \param keys   parallel: each TU's module path, the graph-stable name.
    ///
    /// \details The rule (Compiler/Spec/Generics.md's one home, Incremental.md):
    ///          the users of an instance are the TUs whose plan ADMITTED it
    ///          (only they can define it: a plan that holds an instance has
    ///          its body visible, and is_home is all that changes), in the
    ///          root of its Sema home (home_fid; a root's objects ship
    ///          together, as header mode assumes). The home is the user with
    ///          the least module path among those that import no other user
    ///          (transitively; two in one import cycle do not count as below
    ///          each other). That is Sema's first namer (D3: the generic's own
    ///          TU when it uses the instance, else the first user in
    ///          dependency order) with its graph-wide parts taken out: which
    ///          entry the build started from and the import order of
    ///          siblings, for which the module path stands in. It depends only
    ///          on the users and their imports, so a TU shared by kairo and
    ///          kcc homes the same instances in both, and a new user takes an
    ///          instance over only when no other user imports it and its path
    ///          sorts first. An instance whose Sema home is not a TU of this
    ///          codegen (a library built separately), or that no plan
    ///          admitted, keeps home_fid. Driver thread, plans finished,
    ///          set_graph called.
    pub static fn assign_homes(const plans: cxx::std::vector<unsafe *EmitPlan>,
                               const keys:  cxx::std::vector<string>) {
        EmitPlan::_graph_step(GraphPhase::Graphed, GraphPhase::Homed)
        _HOMES.clear()
        // fid -> index into plans.
        var at = llvm::DenseMap<u64, usize>()
        for var i: usize = 0; i < plans.size(); ++i {
            at.try_emplace(plans[i]->_home as u64, i)
        }

        // Instance -> its users, in plan order; and the instances in first-seen order.
        var users = llvm::DenseMap<u64, usize>()
        var lists = cxx::std::vector<cxx::std::vector<usize>>()
        var order = cxx::std::vector<unsafe *InstanceEntry>()
        for var i: usize = 0; i < plans.size(); ++i {
            var unsafe *v = plans[i]->instances()
            for var k: usize = 0; k < v->size(); ++k {
                var unsafe *ie = (*v)[k]
                var        key = ie as usize as u64
                var        it  = users.find(key)
                if it == users.end() {
                    users.try_emplace(key, lists.size())
                    lists.push_back(cxx::std::vector<usize>())
                    order.push_back(ie)
                    lists[lists.size() - 1].push_back(i)
                } else {
                    lists[it->second as usize].push_back(i)
                }
            }
        }

        // Each instance's candidates and C++ name. Two instances can be one
        // C++ entity (`*T` and `unsafe *T`, `usize` and `u64` on LP64): they
        // are homed as one, from the union of their users, or one TU would
        // write the entity's explicit instantiation twice (CL001E) or two TUs
        // once each. The name: the primary's module and place in its file,
        // and the arguments as the user with the least module path spells
        // them with sizes folded (tier 3's key), so it is no fact of the graph.
        var gname    = cxx::std::vector<string>()
        var gcand    = cxx::std::vector<cxx::std::vector<usize>>()
        var gmembers = cxx::std::vector<cxx::std::vector<unsafe *InstanceEntry>>()
        var gdef     = cxx::std::vector<u32>()
        var by_name  = llvm::StringMap<u32>()
        for var n: usize = 0; n < order.size(); ++n {
            var unsafe *ie = order[n]
            var        hit = at.find(ie->home_fid as u64)
            if hit == at.end() { // homed outside this codegen: as Sema said.
                continue
            }

            var unsafe *sema_home = plans[hit->second as usize]
            var unsafe *list      = unsafe &lists[n]
            var        cand       = cxx::std::vector<usize>()
            for var k: usize = 0; k < list->size(); ++k {
                var u = (*list)[k]
                if sema_home->_same_root(plans[u]->_home, ie->home_fid) {
                    cand.push_back(u)
                }
            }

            if cand.empty() {
                continue
            }

            var least = cand[0]
            for var k: usize = 1; k < cand.size(); ++k {
                if keys[cand[k]] < keys[least] {
                    least = cand[k]
                }
            }

            var unsafe *lp   = plans[least]
            var unsafe *prim = CXXSpell::rep(ie->primary)
            var        def   = CXXSpell::fid_of(prim)
            var        name  = ""
            var        dit   = at.find(def as u64)
            var unsafe *sm   = lp->_cg->ctx->sm
            if dit != at.end() {
                name = keys[dit->second as usize]
            } else if sm != &null && def != u32::MAX {
                name = sm->get_filename(def)
            }

            if sm != &null && prim->range.start.is_valid() {
                name += f"@{sm->resolve(prim->range.start).offset}"
            }

            lp->_spell.fold_sizes   = true
            lp->_spell.sizes_folded = 0
            name += lp->_spell.args_str(ie->args)
            lp->_spell.fold_sizes = false
            var git       = by_name.find(kairo::sref(name))
            var g:  usize = 0
            if git == by_name.end() {
                g = gname.size()
                by_name.try_emplace(kairo::sref(name), g as u32)
                gname.push_back(name)
                gcand.push_back(cxx::std::vector<usize>())
                gmembers.push_back(cxx::std::vector<unsafe *InstanceEntry>())
                gdef.push_back(def)
            } else {
                g = (git->second as usize)
            }

            for var u: usize in cand {
                var dup = false
                for var w: usize in gcand[g] {
                    if w == u {
                        dup = true
                        break
                    }
                }

                if !dup {
                    gcand[g].push_back(u)
                }
            }

            gmembers[g].push_back(ie)
        }

        // Each user's transitive imports, on demand (fid -> marks by fid).
        var reach = cxx::std::vector<cxx::std::vector<u8>>()
        for var g: usize = 0; g < gname.size(); ++g {
            var unsafe *cand = unsafe &gcand[g]
            // In module-path order: the first user no other user lies below.
            var *kp = &keys
            llvm::sort(
                cand->begin(),
                cand->end(),
                fn (a: usize, b: usize) |kp| -> bool {
                    if (*kp)[a] != (*kp)[b] {
                        return (*kp)[a] < (*kp)[b]
                    }

                    return a < b
                },
            )

            var pick = usize::MAX
            for var k: usize = 0; k < cand->size() && pick == usize::MAX; ++k {
                var u     = plans[(*cand)[k]]->_home
                var below = false
                for var m: usize = 0; m < cand->size(); ++m {
                    if m == k {
                        continue
                    }

                    var v = plans[(*cand)[m]]->_home
                    if EmitPlan::_reaches(&reach, u, v) && !EmitPlan::_reaches(&reach, v, u) {
                        below = true
                        break
                    }
                }

                if !below {
                    pick = (*cand)[k]
                }
            }

            if pick == usize::MAX {
                pick = (*cand)[0]
            }

            for var ie: unsafe *InstanceEntry in gmembers[g] {
                _HOMES.try_emplace(ie as usize as u64, plans[pick]->_home)
            }
        }
    }

    fn spell(self) -> unsafe *CXXSpell {
        return unsafe &self._spell
    }

    /// The context the plan was made on; its sink is the emitter's to set.
    fn cg(self) -> unsafe *CodegenContext {
        return self._cg
    }

    /// # Entry point

    pub fn run(self) {
        self._ran = true
        var unsafe *tu = self._cg->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self._home = tu->fid
        if self._cg->instances == &null {
            kairo::std::ice_fail("EmitPlan: no InstantiationRegistry on the CodegenContext")
        }

        if !self._escaping_probe && !tu->cxx_escaping_done && CXXSpell::is_entry_tu(tu) {
            self._find_escaping(tu)
        }

        self._collect_own(tu)
        self._collect_own_globals()
        if self._mode == PlanMode::Preamble {
            self._collect_own_locals()
        }

        if self._mode == PlanMode::Preamble {
            self._collect_uses()
        }

        // To a fixed point: closing can make a record Complete whose inline
        // bodies the walk has not seen (a kcc include's string, reached only
        // through a signature), and those are emitted, so what they name must
        // be planned too. Re-walking is idempotent; the set only grows.
        var planned = usize::MAX
        while planned != self._set.size() {
            planned = self._set.size()
            self._walk_visible()
            self._close()
        }

        self._order()

        // The one writer of is_empty. Foreign entries alone do not count: they
        // are only here to support this TU's own bodies, and there are none.
        self._empty = true
        for var i: usize = 0; i < self.entries.size(); ++i {
            var *e = &self.entries[i]
            if e->witness != &null { // own everywhere, and only ever there for this TU's own code.
                continue
            }

            if e->own {
                self._empty = false
                break
            }

            if e->tier == PlanTier::Instantiations && e->is_home {
                self._empty = false
                break
            }
        }
    }

    /// What run() would otherwise fill in place on state OTHER TUs' plans read:
    /// TranslationUnit::cxx_escaping, which CXXSpell::is_anon reads for any
    /// TU's decl. The driver calls this for every TU, on its own thread, before
    /// TUs are emitted side by side (CodegenJob); run() then finds it done and
    /// writes nothing shared.
    pub fn prepare_shared(self) {
        var unsafe *tu = self._cg->tu
        if tu == &null || tu->program == &null {
            return
        }

        if !tu->cxx_escaping_done && CXXSpell::is_entry_tu(tu) {
            self._find_escaping(tu)
        }
    }

    /// Before a plan runs on a codegen worker (CodegenJob): the shared state
    /// run() would otherwise fill in place is filled. A miss is a driver that
    /// skipped prepare_shared, and run() would write the entry TU's
    /// cxx_escaping beside other workers reading it (CXXSpell::is_anon).
    pub fn require_shared(self) {
        eval if defined!(DEBUG) {
            var unsafe *tu = self._cg->tu
            if tu != &null
                && tu->program != &null
                && CXXSpell::is_entry_tu(tu)
                && !tu->cxx_escaping_done {
                kairo::std::ice_fail(
                    r"EmitPlan: a codegen worker would fill TranslationUnit::cxx_escaping (prepare_shared skipped)",
                )
            }
        }
    }

    /// TranslationUnit::cxx_escaping for pathless TU \p tu: a Header plan of the
    /// file roots at its pub decls and walks its inline and template bodies to
    /// a fixed point, admitting every hidden decl one names -- exactly the set.
    /// The nested plan is a probe (_escaping_probe), so it does not recurse,
    /// and the TU is marked done once the set is whole; nothing in planning
    /// reads is_anon.
    fn _find_escaping(self, tu: unsafe *TranslationUnit) {
        var hcg   = CodegenContext(self._cg->ctx, &null, self._cg->psym, self._cg->instances)
        var hplan = EmitPlan(unsafe &hcg, PlanMode::Header)
        hplan.legacy_roots    = true
        hplan._escaping_probe = true
        hplan.run()
        for var i: usize = 0; i < hplan.entries.size(); ++i {
            var *e = &hplan.entries[i]
            if !e->own || e->decl == &null || e->scope != &null {
                continue
            }

            if !_hidden_in_header(CXXSpell::vis_of(e->decl)) {
                continue
            }

            var dup = false
            for var k: usize = 0; k < tu->cxx_escaping.size(); ++k {
                if tu->cxx_escaping[k] == e->decl {
                    dup = true
                    break
                }
            }

            if !dup {
                tu->cxx_escaping.push_back(e->decl)
            }
        }

        tu->cxx_escaping_done = true
    }

    /// \p d is no root of a Header or Include plan: C++ outside the module may
    /// not name it (AST/VisibilityFacts.k). `priv` and `internal` never; `prot`
    /// only for a C++ TU of the module (host_in_module); an unmarked decl is
    /// what its file's default makes it. A hidden decl still gets there when a
    /// visible inline or template body names it, as a written `priv` always has.
    fn _hidden(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var v = CXXSpell::vis_of(d)
        if self.legacy_roots {
            return _hidden_in_header(v)
        }

        if _hidden_in_header(v) {
            return true
        }

        if v == VIS_PUB() {
            return false
        }

        if v == VIS_NONE() {
            var dv = default_visibility_of(d)
            if dv == VisibilityKind::Public {
                return false
            }

            // An operator C++ probes for stays (VisibilityFacts::is_operator_fn).
            if dv == VisibilityKind::Private {
                return !is_operator_fn(d)
            }
        }

        // prot, written or by default: a module's, never a file-only one's.
        return !self.host_in_module || tu_module_dir(CXXSpell::tu_of(d)).empty()
    }

    /// The TU has nothing to define: no entry of its own at any tier and no
    /// instantiation homed here. A property of the PLAN, not of the file's
    /// bytes -- a file of comments or of `pub import` lines is as empty as a
    /// zero-byte one. An empty TU gets no C++, no clang run, no object and no
    /// header. True for a TU with no program; asked before run(), it is no
    /// verdict (a debug build ICEs).
    pub fn is_empty(self) -> bool {
        eval if defined!(DEBUG) {
            if !self._ran {
                kairo::std::ice_fail(r"EmitPlan::is_empty before run(): not run is not empty")
            }
        }

        return self._empty
    }

    /// Every extension scope written in \p d's OWN file, for the definition's
    /// `friend struct` lines, in plan order. Usually one; `module Geo { extend
    /// Point {...} }` beside a file-scope `extend Point` is two scopes in two
    /// namespaces, and both are friends under invariant 18 -- the set is still
    /// closed at the file.
    fn friend_scopes_of(self, d: unsafe *Decl, @inout out: cxx::std::vector<unsafe *ExtScope>) {
        var unsafe *c   = self.layout_decl(d)
        var unsafe *key = self._scope_key(d)
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var unsafe *s = unsafe &self._scopes[i]
            if s->target == &null || s->key != key {
                continue
            }

            if CXXSpell::fid_of(unsafe (s->anchor as unsafe *Decl)) != CXXSpell::fid_of(c) {
                continue
            }

            // In source order, not plan order: two TUs touch the scopes in the
            // order their own code does, and the record's text must not care.
            var at = out.size()
            while at > 0 && (out)[at - 1]->anchor->range.start.id > s->anchor->range.start.id {
                at -= 1
            }

            out.push_back(s)
            var k = out.size() - 1
            while k > at {
                (out)[k] = (out)[k - 1]
                k -= 1
            }

            (out)[at] = s
        }
    }

    /// # File friends

    /// The record has a member C++ will see non-public (CXXSpell::cxx_access).
    /// A compiler-made one never counts: only the record's own members call
    /// it. A function of the record's declaration, so of its file.
    fn needs_friends(self, d_in: unsafe *Decl) -> bool {
        var unsafe *d = CXXSpell::rep(d_in)
        if d == &null
            || !(isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d)) {
            return false
        }

        var fields:  FrozenList<unsafe *Declarations::FieldDecl>
        var methods: FrozenList<unsafe *Declarations::FunctionDecl>
        if isa<Declarations::ClassDecl>(d) {
            // A `derives priv` / `prot` edge narrows the inherited names with
            // `private:` / `protected:` usings (InterfaceEmitter::_edge_narrowing),
            // which the file must still reach through d.
            var unsafe *cd = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < cd->derives_list.size(); ++i {
                var unsafe *e = cd->derives_list.get(i)
                if e != &null && (e->visibility == VIS_PRIV() || e->visibility == VIS_PROT()) {
                    return true
                }
            }
        }

        if isa<Declarations::ClassDecl>(d) {
            fields  = cast<Declarations::ClassDecl>(d)->fields
            methods = cast<Declarations::ClassDecl>(d)->methods
        } else if isa<Declarations::UnionDecl>(d) {
            fields  = cast<Declarations::UnionDecl>(d)->fields
            methods = cast<Declarations::UnionDecl>(d)->methods
        } else {
            fields  = cast<Declarations::StructDecl>(d)->fields
            methods = cast<Declarations::StructDecl>(d)->methods
        }

        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f == &null || f->is_implicit {
                continue
            }

            if self._spell.cxx_access(f) != VIS_PUB() {
                return true
            }
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || m->is_implicit {
                continue
            }

            if self._spell.cxx_access(m) != VIS_PUB() {
                return true
            }
        }

        var unsafe *dc = CXXSpell::dc_of(d)
        if dc == &null {
            return false
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || nd->is_implicit {
                continue
            }

            if !self._is_type_decl(nd) && !isa<Declarations::TypeAliasDecl>(nd) {
                continue
            }

            if self._spell.cxx_access(nd) != VIS_PUB() {
                return true
            }
        }

        return false
    }

    /// Record \p d's friends (FileFriends), from \p d's file's declarations.
    /// Coarse on purpose: everything of the file that may name a member Kairo
    /// lets it name, whether it does or not, so no walk of any body -- which
    /// another TU may not have lowered -- decides the text.
    ///
    /// Left out, because C++ cannot befriend it from here, and so still unable
    /// to reach a private member in the C++ (ClangDiagAdapter makes the clang
    /// error a loud internal one): a function whose signature names a nested
    /// type, not declarable ahead of the record. A function in another
    /// namespace of the file (a `module` block's), or an `ffi "c"` or `-> !`
    /// one, is befriended by its qualified name after a declaration of its own
    /// (_ff_fn_kind); a generic friend's parameters are spelled under names of
    /// their own (CXXSpell::rename_tparams), so they never redeclare the
    /// record's.
    fn file_friends(self, d_in: unsafe *Decl, out: unsafe *FileFriends) {
        var unsafe *d = CXXSpell::rep(d_in)
        if !self.needs_friends(d) {
            return
        }

        out->needed = true
        var unsafe *tu = CXXSpell::tu_of(d)
        if tu == &null || tu->program == &null {
            return
        }

        var ns = self._spell.ns_segments(d)
        // Only d itself is left out: a nested d befriends its outermost
        // record too, since C++ gives an enclosing class no access to a nested
        // one's private members.
        var unsafe *mine = d
        self._ff_dc(tu, d, mine, unsafe &ns, out)
        var hl = HoistedLocals()
        hl.run(tu)
        for var i: usize = 0; i < hl.found.size(); ++i {
            var unsafe *h = CXXSpell::rep(hl.found[i])
            if h == &null || h->is_poisoned() || h == mine {
                continue
            }

            if isa<Declarations::ClassDecl>(h)
                || isa<Declarations::StructDecl>(h)
                || isa<Declarations::UnionDecl>(h) {
                self._ff_record(h, out)
                continue
            }

            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(h)
            if f != &null {
                self._ff_add_fn(f, unsafe &ns, out)
            }
        }

        // The witnesses of what the file declares d implements: on d itself,
        // and on every `extend d impl I` of the file.
        if isa<Declarations::ClassDecl>(d) {
            var *ce = &cast<Declarations::ClassDecl>(d)->implements
            for var i: usize = 0; i < ce->size(); ++i {
                if ce->get(i) != &null {
                    self._ff_iface(ce->get(i)->base, out, 0)
                }
            }
        } else if isa<Declarations::StructDecl>(d) {
            var *se = &cast<Declarations::StructDecl>(d)->implements
            for var i: usize = 0; i < se->size(); ++i {
                if se->get(i) != &null {
                    self._ff_iface(se->get(i)->base, out, 0)
                }
            }
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind == TopLevelKind::Stmt {
                var unsafe *ds = dyn_cast<DeclStmt>(item.as_stmt())
                var unsafe *v = if (ds != &null
                                    && ds->decl != &null) => (dyn_cast<Declarations::VariableDecl>(
                                    ds->decl,
                                ))
                                else => &null
                if v == &null || !GlobalInitReach::needs_thunk(unsafe &self._spell, v) {
                    continue
                }

                var vns = self._spell.ns_segments(v)
                if self._same_ns_vec(vns, ns) {
                    out->globals.push_back(v)
                }

                continue
            }

            if item.kind != TopLevelKind::Decl {
                continue
            }

            self._ff_ifaces_in(item.as_decl(), d, out)
        }
    }

    fn _ff_dc(self,
              dc:   unsafe *DeclContext,
              d:    unsafe *Decl,
              mine: unsafe *Decl,
              ns:   unsafe *cxx::std::vector<string>,
              out:  unsafe *FileFriends) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *x = *dc->dc_decls.get(i)
            if x != &null {
                self._ff_decl(x, d, mine, ns, out)
            }
        }
    }

    fn _ff_decl(self,
                x:    unsafe *Decl,
                d:    unsafe *Decl,
                mine: unsafe *Decl,
                ns:   unsafe *cxx::std::vector<string>,
                out:  unsafe *FileFriends) {
        if x->is_poisoned() {
            return
        }

        if isa<Declarations::ModuleDecl>(x) {
            self._ff_dc(
                unsafe (cast<Declarations::ModuleDecl>(x) as unsafe *DeclContext),
                d,
                mine,
                ns,
                out,
            )

            return
        }

        if isa<Declarations::VisibilityGroupDecl>(x) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(x)
            for var i: usize = 0; i < g->members.size(); ++i {
                if g->members[i] != &null {
                    self._ff_decl(g->members[i], d, mine, ns, out)
                }
            }

            return
        }

        // An `ffi "c" { ... }` block is a group like a visibility one: its
        // members are top-level declarations stamped with the linkage.
        if isa<Declarations::FFIBlockDecl>(x) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(x)
            for var i: usize = 0; i < g->body.size(); ++i {
                if g->body[i] != &null {
                    self._ff_decl(g->body[i], d, mine, ns, out)
                }
            }

            return
        }

        if isa<Declarations::ExtensionDecl>(x) {
            var unsafe *e = cast<Declarations::ExtensionDecl>(x)
            if e->methods.size() == 0 || e->target == &null || e->target->canonical == &null {
                return
            }

            // d's own scopes are friend_scopes_of's, qualified and admitted.
            var unsafe *c = canon_unqual(e->target->canonical)
            if isa<RecordType>(c)
                && self._scope_key(cast<RecordType>(c)->decl) == self._scope_key(d) {
                return
            }

            // Unqualified, it names (or first declares) the struct in d's
            // namespace -- the one place it can, with no prior declaration.
            var sns = self._spell.scope_ns(e)
            if !self._same_ns_vec(sns, *ns) {
                return
            }

            var nm = self._spell.ext_scope_name(e)
            for var i: usize = 0; i < out->scopes.size(); ++i {
                if self._spell.ext_scope_name(out->scopes[i]) == nm {
                    return
                }
            }

            out->scopes.push_back(e)
            return
        }

        if isa<Declarations::ClassDecl>(x)
            || isa<Declarations::StructDecl>(x)
            || isa<Declarations::UnionDecl>(x) {
            var unsafe *r = CXXSpell::rep(x)
            if r != x
                || r == mine
                || r->is_implicit
                || CXXSpell::is_record_spec(r)
                || DeclFacts::decl_only_forward(r) {
                return
            }

            if DeclFacts::decl_ffi_tag_target(r) != &null || !self._plannable(r) {
                return
            }

            self._ff_record(r, out)
            return
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(x)
        if f == &null {
            return
        }

        var unsafe *rf = cast<Declarations::FunctionDecl>(CXXSpell::rep(x))
        if self._spell.is_main(unsafe (rf as unsafe *Decl)) {
            if out->main == &null && CXXSpell::c_linkage(rf).size() == 0 {
                out->main = rf
            }

            return
        }

        self._ff_add_fn(rf, ns, out)
    }

    fn _ff_add_fn(self,
                  f:   unsafe *Declarations::FunctionDecl,
                  ns:  unsafe *cxx::std::vector<string>,
                  out: unsafe *FileFriends) {
        var k = self._ff_fn_kind(f, ns)
        if k == 0 {
            return
        }

        for var i: usize = 0; i < out->fns.size(); ++i {
            if out->fns[i] == f {
                return
            }
        }

        out->fns.push_back(f)
        out->far.push_back((k == 2) as u8)
    }

    fn _ff_record(self, r: unsafe *Decl, out: unsafe *FileFriends) {
        for var i: usize = 0; i < out->records.size(); ++i {
            if out->records[i] == r {
                return
            }
        }

        out->records.push_back(r)
    }

    /// How \p f is befriended: 0 not at all; 1 unqualified, which names (or
    /// first declares) it in the record's namespace; 2 qualified, after an
    /// early declaration of its own (EmitPlan::friend_early) -- a function in
    /// another namespace of the file, or one whose first declaration must
    /// carry its `ffi "c"` linkage or `[[noreturn]]`, which a friend
    /// declaration may not.
    fn _ff_fn_kind(self,
                   f:  unsafe *Declarations::FunctionDecl,
                   ns: unsafe *cxx::std::vector<string>) -> u8 {
        if f->is_poisoned()
            || f->is_method()
            || DeclFacts::decl_extension_of(unsafe (f as unsafe *Decl)) != &null {
            return 0
        }

        if self._ff_nested(f->return_type, 0) || self._ff_nested(f->panic_result, 0) {
            return 0
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            var unsafe *pt = (if (p->is_pack && p->pack_type != &null) => (p->pack_type)
                              else => p->type_)
            if self._ff_nested(pt, 0) {
                return 0
            }
        }

        if f->is_noreturn || CXXSpell::c_linkage(f).size() > 0 {
            return 2
        }

        var fns = self._spell.ns_segments(unsafe (f as unsafe *Decl))
        if !self._same_ns_vec(fns, *ns) {
            return 2
        }

        return 1
    }

    /// \p t names a record nested in another type: a name only a complete
    /// outer type declares, which the befriending record's definition may
    /// precede.
    fn _ff_nested(self, t: unsafe *Type, depth: u32) -> bool {
        if t == &null || depth > 32 {
            return false
        }

        var unsafe *c = if (t->canonical != &null) => (t->canonical) else => t
        match c->kind {
            case TypeKind::QualifiedType {
                return self._ff_nested(cast<QualifiedType>(c)->inner, depth + 1)
            } case TypeKind::PointerType {
                return self._ff_nested(cast<PointerType>(c)->pointee, depth + 1)
            } case TypeKind::CXXLValueRefType {
                return self._ff_nested(cast<CXXLValueRefType>(c)->referee, depth + 1)
            } case TypeKind::CXXRValueRefType {
                return self._ff_nested(cast<CXXRValueRefType>(c)->referee, depth + 1)
            } case TypeKind::FixedArrayType {
                return self._ff_nested(cast<FixedArrayType>(c)->element, depth + 1)
            } case TypeKind::NullableType {
                return self._ff_nested(cast<NullableType>(c)->inner, depth + 1)
            } case TypeKind::TupleType {
                var unsafe *tt = cast<TupleType>(c)
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    if self._ff_nested(*tt->elements.get(i), depth + 1) {
                        return true
                    }
                }

                return false
            } case TypeKind::FunctionPointerType {
                var unsafe *ft = cast<FunctionPointerType>(c)
                if self._ff_nested(ft->return_type, depth + 1) {
                    return true
                }

                for var i: usize = 0; i < ft->params.size(); ++i {
                    if self._ff_nested(*ft->params.get(i), depth + 1) {
                        return true
                    }
                }

                return false
            } case TypeKind::RecordType {
                var unsafe *rt = cast<RecordType>(c)
                if rt->outer != &null {
                    return true
                }

                if rt->decl != &null && !DeclFacts::decl_is_imported(rt->decl) {
                    var unsafe *dc = CXXSpell::rep(rt->decl)->semantic_dc
                    if dc != &null
                        && dc->is_type_scope()
                        && dc->dc_kind != DeclContextKind::Extension {
                        return true
                    }
                }

                for var i: usize = 0; i < rt->args.size(); ++i {
                    if self._ff_nested(*rt->args.get(i), depth + 1) {
                        return true
                    }
                }

                return false
            } default {
                return false
            }
        }
    }

    /// Interface \p t's decl and everything it derives, once each.
    fn _ff_iface(self, t: unsafe *Type, out: unsafe *FileFriends, depth: u32) {
        if t == &null || t->canonical == &null || depth > 32 {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if !isa<RecordType>(c) {
            return
        }

        var unsafe *id = dyn_cast<Declarations::InterfaceDecl>(
            CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(cast<RecordType>(c)->decl))),
        )

        if id == &null {
            return
        }

        var unsafe *idd = unsafe (id as unsafe *Decl)
        for var i: usize = 0; i < out->ifaces.size(); ++i {
            if out->ifaces[i] == idd {
                return
            }
        }

        out->ifaces.push_back(idd)
        for var i: usize = 0; i < id->derives_list.size(); ++i {
            var unsafe *e = id->derives_list.get(i)
            if e != &null {
                self._ff_iface(e->base, out, depth + 1)
            }
        }
    }

    fn _ff_ifaces_in(self, cand: unsafe *Decl, d: unsafe *Decl, out: unsafe *FileFriends) {
        if cand == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(cand) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(cand)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._ff_ifaces_in(g->members[i], d, out)
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(cand) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(cand)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._ff_ifaces_in(g->body[i], d, out)
            }

            return
        }

        if isa<Declarations::ModuleDecl>(cand) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(cand) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                self._ff_ifaces_in(*dc->dc_decls.get(i), d, out)
            }

            return
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(cand)
        if x == &null || x->implements.size() == 0 {
            return
        }

        if self._ext_target(x) != self.layout_decl(d) {
            return
        }

        for var i: usize = 0; i < x->implements.size(); ++i {
            var unsafe *e = x->implements.get(i)
            if e != &null {
                self._ff_iface(e->base, out, 0)
            }
        }
    }

    /// Where record \p d is Complete, everything its friend lines name is
    /// declared ahead of it: each record (tier 0), each function's signature
    /// types (as its own declaration would need them; the function itself
    /// need not be), each witness primary, and `main` at global scope.
    fn _admit_friends(self, d: unsafe *Decl) {
        var ff = FileFriends()
        self.file_friends(d, unsafe &ff)
        if !ff.needed {
            return
        }

        for var i: usize = 0; i < ff.records.size(); ++i {
            self._admit(ff.records[i], PlanNeed::Fwd)
        }

        for var i: usize = 0; i < ff.fns.size(); ++i {
            var unsafe *f = ff.fns[i]
            if ff.far[i] != 0 {
                var have = false
                for var k: usize = 0; k < self.friend_early.size(); ++k {
                    if self.friend_early[k] == f {
                        have = true
                        break
                    }
                }

                if !have {
                    self.friend_early.push_back(f)
                }
            }

            self._witness_bounds(f)
            for var j: usize = 0; j < f->params.size(); ++j {
                var unsafe *p = f->params[j]
                if p == &null || p->is_self {
                    continue
                }

                self._admit_type(
                    (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                    PlanNeed::Fwd,
                )
            }

            self._admit_type(f->return_type, PlanNeed::Fwd)
            self._admit_type(f->panic_result, PlanNeed::Fwd)
        }

        for var i: usize = 0; i < ff.ifaces.size(); ++i {
            self._witness_primary(ff.ifaces[i])
        }

        for var i: usize = 0; i < ff.globals.size(); ++i {
            self._admit_type(ff.globals[i]->type_, PlanNeed::Fwd)
        }

        if ff.main != &null {
            self.main_friend = ff.main
            for var j: usize = 0; j < ff.main->params.size(); ++j {
                var unsafe *p = ff.main->params[j]
                if p != &null && !p->is_self {
                    self._admit_type(p->type_, PlanNeed::Fwd)
                }
            }
        }
    }

    /// # Dump

    pub fn dump(self, const path: string) {
        var m = if (self._mode == PlanMode::Preamble) => ("preamble")
                else => (if (self._mode == PlanMode::Header) => ("header") else => "include")
        io::println(f"===== EMIT PLAN fid {self._home} ({m}): {path} =====")
        if self.entries.size() == 0 {
            io::println("  (empty)")
            return
        }

        var tier = (255 as u8)
        // Names as the Kairo source spells their modules, not their renamed
        // C++ namespace (`::main::f`, emitted in `namespace main_`).
        self._spell.kairo_top = true
        for var i: usize = 0; i < self.entries.size(); ++i {
            var *e = &self.entries[i]
            if (e->tier as u8) != tier {
                tier = (e->tier as u8)
                io::println(f"  -- {self._tier_name(e->tier)} --")
            }

            var own   = if (e->own) => ("own") else => "foreign"
            var extra = ""
            var nm    = ""
            var kd    = "struct"
            if e->scope != &null {
                // The anchor is an ExtensionDecl, which has no name of its own.
                for var k: usize = 0; k < e->scope->ns.size(); ++k {
                    nm += "::"
                    nm += if (k == 0) => (CXXSpell::kairo_top_of(e->scope->ns[k]))
                          else => e->scope->ns[k]
                }

                nm += "::"
                nm += e->scope->name
                extra = f" extension scope, {e->scope->members.size()} members"
            } else {
                nm = self._spell.qual_name(e->decl)
                if e->inst != &null {
                    nm += self._spell.args_str(e->inst->args)
                }

                kd = self._kind_name(e->decl)
                if e->inst != &null {
                    extra = if (e->is_home) => (" home") else => " extern"
                }
            }

            io::println(
                f"    {kd} {nm}   [{self._need_name(e->need)}] {own} fid {e->fid} @ {e->off}{extra}",
            )
        }

        self._spell.kairo_top = false
    }

    fn _tier_name(self, t: PlanTier) -> string {
        match t {
            case PlanTier::FwdDecls {
                return "tier 0: forward declarations"
            } case PlanTier::Definitions {
                return "tier 1: definitions"
            } case PlanTier::Functions {
                return "tier 2: function declarations"
            } case PlanTier::Instantiations {
                return "tier 3: instantiations"
            }
        }
    }

    fn _need_name(self, n: PlanNeed) -> string {
        return if (n == PlanNeed::Complete) => ("complete") else => "fwd"
    }

    fn _kind_name(self, d: unsafe *Decl) -> string {
        match d->kind {
            case DeclKind::ClassDecl {
                return "class"
            } case DeclKind::StructDecl {
                return "struct"
            } case DeclKind::UnionDecl {
                return "union"
            } case DeclKind::EnumDecl {
                return "enum"
            } case DeclKind::FunctionDecl {
                return "fn"
            } case DeclKind::VariableDecl {
                return "var"
            } default {
                return "decl"
            }
        }
    }

    /// # Roots: own decls

    /// Every plannable decl the TU declares, at the strength its own kind
    /// demands: a type is defined here (Complete), a function is declared.
    /// Header mode takes only `pub` ones. Modules and visibility groups are
    /// walked through; an extension block puts its scope in the plan.
    fn _collect_own(self, dc: unsafe *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            self._collect_own_decl(d)
        }
    }

    fn _collect_own_decl(self, d: unsafe *Decl) {
        if d->is_poisoned() {
            return
        }

        if isa<Declarations::ModuleDecl>(d) {
            self._collect_own((cast<Declarations::ModuleDecl>(d)))
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._collect_own_decl(g->members[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(d) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(d)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._collect_own_decl(g->body[i])
            }

            return
        }

        if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *x = cast<Declarations::ExtensionDecl>(d)
            // A header reaches the scope through any visible member, and then
            // carries the WHOLE struct; a block with none adds no root.
            if self._mode != PlanMode::Preamble && self._hidden(d) {
                return
            }

            var visible = false
            for var i: usize = 0; i < x->methods.size(); ++i {
                var unsafe *m = x->methods[i]
                if m == &null {
                    continue
                }

                if self._mode != PlanMode::Preamble && self._hidden(m) {
                    continue
                }

                visible = true
            }

            if visible {
                self._scope_for(x, true)
            }

            self._witness_declared(d)
            return
        }

        if !self._plannable(d) {
            return
        }

        if self._mode != PlanMode::Preamble && self._hidden(d) {
            return
        }

        if self._is_type_decl(d) {
            // A definition here means every own type is Complete; its own
            // dependencies come in through _expand.
            self._admit(d, PlanNeed::Complete)
            self._witness_declared(d)
        } else {
            self._admit(d, PlanNeed::Fwd)
            if self._mode != PlanMode::Preamble && isa<Declarations::FunctionDecl>(d) {
                self._own_sig_complete(cast<Declarations::FunctionDecl>(d))
            }
        }
    }

    /// A header or include is read by C++ code that CALLS the file's `pub`
    /// functions, and a call whose return or by-value parameter is an
    /// incomplete class is ill-formed: `lib::name()` returning `string` was
    /// "incomplete return type '::builtin::string::string'" (P303), as was a
    /// record of another Kairo module. So an own function's signature is
    /// held as a complete class's member signature is (_expand_member_sig:
    /// by value Complete, a pointer still Fwd). An object build's preamble
    /// only declares, and keeps _expand_fn's Fwd.
    fn _own_sig_complete(self, n: unsafe *Declarations::FunctionDecl) {
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null || p->is_self {
                continue
            }

            self._admit_type(
                (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                PlanNeed::Complete,
            )
        }

        self._admit_type(n->return_type, PlanNeed::Complete)
        self._admit_type(n->panic_result, PlanNeed::Complete)
    }

    /// File-scope `var`/`const`/`static`/`eval`. They parse as DeclStmts in
    /// program->items and never enter tu->dc_decls (ASTParse::_build_symbols),
    /// so the dc walk above cannot see them; without this a TU whose only
    /// definitions are globals is is_empty, and a function naming one finds no
    /// prior `extern`, which for a `const` is the difference between external
    /// and internal linkage.
    /// The `fn`s, classes and enums written in this TU's function bodies: each
    /// is an own declaration at namespace scope (CXXSpell::is_hoisted_local),
    /// defined here whether or not a body names it. A header and an include
    /// take one only through a use -- an inline or template body that calls
    /// it, which the body walk admits.
    fn _collect_own_locals(self) {
        var hl = HoistedLocals()
        hl.run(self._cg->tu)
        for var i: usize = 0; i < hl.found.size(); ++i {
            self._collect_own_decl(hl.found[i])
        }
    }

    fn _collect_own_globals(self) {
        var unsafe *prog = self._cg->tu->program
        for var i: usize = 0; i < prog->items.size(); ++i {
            var item = *prog->items.get(i)
            if item.kind != TopLevelKind::Stmt {
                continue
            }

            var unsafe *ds = dyn_cast<DeclStmt>(item.as_stmt())
            if ds == &null || ds->decl == &null {
                continue
            }

            self._collect_own_decl(ds->decl)
        }
    }

    /// # Extension scopes

    /// The scope \p x contributes to, created on first touch; \p reach marks it
    /// reachable. Index-based: the closure below can grow _scopes.
    ///
    /// Filled COMPLETELY at creation, never from the use that touched it: with
    /// members appended per use, TU A's struct would have the three it calls
    /// and TU B's the five it calls, two definitions of one class.
    fn _scope_for(self, x: unsafe *Declarations::ExtensionDecl, reach: bool) -> usize {
        if x == &null || x->target == &null || x->target->canonical == &null {
            kairo::std::ice_fail("EmitPlan: extension with an unresolved target reached codegen")
        }

        var ns   = self._spell.scope_ns(x)
        var name = self._spell.ext_scope_name(x)
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var *s = &self._scopes[i]
            if s->name != name || !self._same_ns_vec(s->ns, ns) {
                continue
            }

            // Same N, same struct name: it must be the same target, or two
            // targets (`a::Point`, `b::Point`) would share one struct.
            if !self._same_scope(i, x) {
                self._ice(
                    x->range,
                    f"EmitPlan: two extension targets in one namespace both spell '{name}'; the scope naming rule needs a disambiguator",
                )
            }

            if reach {
                s->reachable = true
            }

            return i
        }

        var fresh = ExtScope()
        fresh.ns   = ns
        fresh.name = name
        var unsafe *c = canon_unqual(x->target->canonical)
        if isa<RecordType>(c) {
            fresh.target = self.layout_decl(cast<RecordType>(c)->decl)
            fresh.key    = self._scope_key(cast<RecordType>(c)->decl)
        } else {
            fresh.target_ty = c
        }

        fresh.reachable = reach
        self._scopes.push_back(fresh)
        var k = self._scopes.size() - 1

        // Every block of this (N, X) lives in x's file: N is that file's
        // module path plus its module blocks.
        var unsafe *tu = CXXSpell::tu_of(x)
        if tu == &null || tu->program == &null {
            self._ice(x->range, "EmitPlan: extension with no owning TU")
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            self._fill_scope(k, item.as_decl())
        }

        if self._scopes[k].anchor == &null {
            self._ice(x->range, "EmitPlan: an extension's own file does not contain it")
        }

        // A static member's signature names its types and lays none out; the
        // definition and its forwarders need the deps complete.
        //
        // EVERY member is expanded, priv included: the struct is emitted whole
        // in every TU that touches it, so a type only a priv member names must
        // be declared in a preamble whose own code never mentions it. A nested
        // type there is a dep too -- `Other::Inner` cannot be named through
        // the bare `class Other;` that Fwd gives.
        self._scope_dep(k, x->target)
        var nm = self._scopes[k].members.size()
        for var i: usize = 0; i < nm; ++i {
            var unsafe *m = self._scopes[k].members[i]
            // Each block's own target: one scope holds the blocks of every
            // specialization (`extend <> Store<bool>` beside `extend <T>
            // Store<T>`), and a member's receiver names its block's.
            self._scope_dep(k, self._scopes[k].exts[i]->target)
            self._expand_fn(m)
            self._scope_sig_dep(k, m->return_type)
            if m->panic_result != &null {
                self._scope_sig_dep(k, m->panic_result)
            }

            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = m->params[j]
                if p == &null || p->is_self {
                    continue
                }

                self._scope_sig_dep(k, (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_))
            }

            if !m->is_operator || self._spell.ext_forwarder_name(m).size() == 0 {
                continue
            }

            self._scope_dep(k, m->return_type)
            if m->panic_result != &null {
                self._scope_dep(k, m->panic_result)
            }

            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = m->params[j]
                if p == &null || p->is_self || p->mode != ParamMode::Value {
                    continue
                }

                self._scope_dep(k, p->type_)
            }
        }

        return k
    }

    /// Walk \p cand (modules, visibility groups) for every extend block of
    /// scope \p k, adding its members in source order.
    fn _fill_scope(self, k: usize, cand: unsafe *Decl) {
        if cand == &null || cand->is_poisoned() {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(cand) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(cand)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._fill_scope(k, g->members[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(cand) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(cand)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._fill_scope(k, g->body[i])
            }

            return
        }

        if isa<Declarations::ModuleDecl>(cand) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(cand) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                self._fill_scope(k, *dc->dc_decls.get(i))
            }

            return
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(cand)
        if x == &null || x->target == &null || x->target->canonical == &null {
            return
        }

        if !self._same_scope(k, x) {
            return
        }

        var ns = self._spell.scope_ns(x)
        if !self._same_ns_vec(self._scopes[k].ns, ns) {
            return
        }

        if self._scopes[k].anchor == &null {
            self._scopes[k].anchor = x
        }

        for var i: usize = 0; i < x->methods.size(); ++i {
            var unsafe *m = x->methods[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            var unsafe *c  = cast<Declarations::FunctionDecl>(CXXSpell::rep(m))
            var        dup = false
            for var j: usize = 0; j < self._scopes[k].members.size(); ++j {
                if self._scopes[k].members[j] == c {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            self._scopes[k].members.push_back(c)
            self._scopes[k].exts.push_back(x)
        }
    }

    /// \p x's target is scope \p k's: the same layout decl for a record, the
    /// same canonical type for a builtin. Namespace is the caller's to compare.
    fn _same_scope(self, k: usize, x: unsafe *Declarations::ExtensionDecl) -> bool {
        var unsafe *c = canon_unqual(x->target->canonical)
        var        *s = &self._scopes[k]
        if isa<RecordType>(c) {
            return s->target != &null && self._scope_key(cast<RecordType>(c)->decl) == s->key
        }

        return s->target == &null && s->target_ty == c
    }

    /// A by-value record \p t is a Complete dependency of scope \p k, recorded
    /// as the tier-1 entry that defines it (an outermost type, a primary).
    fn _scope_dep(self, k: usize, t: unsafe *Type) {
        if t == &null || t->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if isa<NullableType>(c) {
            self._scope_dep(k, self._nullable_record(c))
            return
        }

        if !isa<RecordType>(c) {
            return
        }

        var unsafe *d = self.layout_decl(cast<RecordType>(c)->decl)
        if d == &null || DeclFacts::decl_is_imported(d) || isa<Declarations::InterfaceDecl>(d) {
            return
        }

        self._admit_type(t, PlanNeed::Complete)
        self._scope_add_dep(k, self._outermost_type(d))
    }

    /// The record a canonical `T?` is to C++ (NullableType::lowered). None means
    /// NullableTypeLowering never saw it: the same ICE CXXSpell raises.
    fn _nullable_record(self, c: unsafe *Type) -> unsafe *Type {
        var unsafe *lw = cast<NullableType>(c)->lowered
        if lw == &null {
            self._ice(
                c->range,
                "EmitPlan: T? reached codegen with no lowered record; NullableTypeLowering must run first",
            )
        }

        return lw
    }

    /// A NESTED record anywhere in a member signature \p t -- behind pointers,
    /// references, arrays, as a generic argument -- makes its outermost owner a
    /// Complete dep of scope \p k: a member type is named only through a
    /// complete enclosing class.
    fn _scope_sig_dep(self, k: usize, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                self._scope_sig_dep(k, cast<QualifiedType>(c)->inner)
            } case TypeKind::PointerType {
                self._scope_sig_dep(k, cast<PointerType>(c)->pointee)
            } case TypeKind::CXXLValueRefType {
                self._scope_sig_dep(k, cast<CXXLValueRefType>(c)->referee)
            } case TypeKind::CXXRValueRefType {
                self._scope_sig_dep(k, cast<CXXRValueRefType>(c)->referee)
            } case TypeKind::NullableType {
                self._scope_sig_dep(k, self._nullable_record(c))
            } case TypeKind::FixedArrayType {
                self._scope_sig_dep(k, cast<FixedArrayType>(c)->element)
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self._scope_sig_dep(k, *tp->elements.get(i))
                }
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    self._scope_sig_dep(k, *fp->params.get(i))
                }

                self._scope_sig_dep(k, fp->return_type)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    self._scope_sig_dep(k, *r->args.get(i))
                }

                if r->outer != &null {
                    self._scope_sig_dep(k, r->outer)
                }

                var unsafe *d = self.layout_decl(r->decl)
                if d == &null
                    || DeclFacts::decl_is_imported(d)
                    || isa<Declarations::InterfaceDecl>(d) {
                    return
                }

                var unsafe *outer = self._outermost_type(d)
                // An ADT's layout record sits in the enum's scope, but it IS the
                // enum, not a type nested in it.
                if outer == d || self.adt_record(outer) == d {
                    return
                }

                self._admit(outer, PlanNeed::Complete)
                self._scope_add_dep(k, outer)
            } default { }
        }
    }

    fn _scope_add_dep(self, k: usize, d: unsafe *Decl) {
        for var i: usize = 0; i < self._scopes[k].deps.size(); ++i {
            if self._scopes[k].deps[i] == d {
                return
            }
        }

        self._scopes[k].deps.push_back(d)
    }

    /// # Witnesses (Compiler/Spec/Witnesses.md#emission)

    /// \p iface's primary and concept, created on first touch. Its deps are the
    /// by-value records its forwarders' signatures name (an inline definition
    /// lays them out); a concept conjoins its bases' concepts, so their
    /// primaries come first.
    fn _witness_primary(self, iface_in: unsafe *Decl) -> usize {
        var unsafe *iface = CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(iface_in)))
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].iface == iface && self._witnesses[i].row == &null {
                return i
            }
        }

        var fresh = WitnessPiece()
        fresh.iface = iface
        fresh.key   = self._spell.witness_name(iface)
        self._witnesses.push_back(fresh)
        var k = self._witnesses.size() - 1

        // Every requirement it derives is its own member (InterfaceComposition),
        // and its concept conjoins no base's: no base primary is needed first.
        var ms = EmitWitness(self._cg, unsafe &self._spell).members(
            cast<Declarations::InterfaceDecl>(iface),
        )

        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            self._witness_sig(k, m)
        }

        return k
    }

    /// \p row's specialization, when the primary does not serve it (§7b.4):
    /// after the primary, the conformer complete, and every extension scope
    /// it forwards to defined.
    fn _witness_row(self, row: unsafe *ConformanceRow) {
        if row == &null || row->iface_decl == &null {
            return
        }

        // The rows its associated types' bounds rest on come with it, whether
        // or not this row needs a specialization of its own: a body reaching
        // `T::Item::Inner` spells `Holder_witness<Purse>` (ConformanceRow::
        // assoc_rows). Once each: a row may name itself through a bound.
        var seen = false
        for var i: usize = 0; i < self._assoc_seen.size(); ++i {
            if self._assoc_seen[i] == row {
                seen = true
            }
        }

        if !seen {
            self._assoc_seen.push_back(row)
            for var i: usize = 0; i < row->assoc_rows.size(); ++i {
                self._witness_row(row->assoc_rows[i])
            }
        }

        // The conformer complete, whichever witness serves the row: the
        // primary's members are `requires`-guarded on `&A::alloc` and the like,
        // which an incomplete A fails, so a concept on a type this TU only
        // names as a generic argument (`alloc_bytes<System>`) would be false
        // and the call rejected. A specialization's _witness_dep below makes it
        // complete too, but a row the primary serves never reaches that. A
        // generic row's conformer is dependent: its template is handled there.
        if !EmitWitness::is_generic_row(row) {
            self._admit_type(row->conformer, PlanNeed::Complete)
        }

        var unsafe *iface = CXXSpell::rep(row->iface_decl)
        self._witness_primary(iface)
        var ew = EmitWitness(self._cg, unsafe &self._spell)
        // A generic declared row's partial specialization is this row's witness
        // already (§7b.3): admitting it, never a full one beside it, keeps one
        // definition per conformance. Only when it is emitted at all -- were the
        // primary to serve the generic row but not this one, the full one is
        // still the only witness this row has.
        var unsafe *g = row->covered_by
        if g != &null && ew.needs_specialization(g) {
            self._witness_row(g)
            return
        }

        if !ew.needs_specialization(row) {
            return
        }

        // Keyed with usize / isize folded (Compiler/Spec/Witnesses.md#open-questions, question 3): where
        // the target spells usize as u64's C++ type, `Hash_witness<usize>` and
        // `Hash_witness<u64>` are one C++ class, and a second definition is a
        // clang redefinition. The first row in wins; two conformances of one C++
        // type must agree (base/hash.k's do: both hash the 64-bit value).
        self._spell.fold_sizes = true
        var key = self._spell.witness_name(iface) + self._spell.witness_args(
            self._spell._type(row->conformer),
            row->iface,
        )

        self._spell.fold_sizes = false
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].row == row
                || self._witnesses[i].row != &null && self._witnesses[i].key == key {
                return
            }
        }

        var fresh = WitnessPiece()
        fresh.iface = iface
        fresh.row   = row
        fresh.key   = key
        fresh.after.push_back(iface)
        self._witnesses.push_back(fresh)
        var k = self._witnesses.size() - 1

        self._witness_dep(k, row->conformer)
        if EmitWitness::is_generic_row(row) && isa<RecordType>(row->conformer) {
            // A partial specialization names the conformer's template, which
            // _witness_dep leaves alone as dependent: the primary must be
            // declared, and is defined first, as a full specialization's is.
            var unsafe *cd = self.layout_decl(cast<RecordType>(row->conformer)->decl)
            if cd != &null && !DeclFacts::decl_is_imported(cd) {
                var unsafe *o = self._outermost_type(cd)
                self._admit(o, PlanNeed::Complete)
                var have = false
                for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i {
                    if self._witnesses[k].deps[i] == o {
                        have = true
                    }
                }

                if !have {
                    self._witnesses[k].deps.push_back(o)
                }
            }
        }

        var ms = ew.members(cast<Declarations::InterfaceDecl>(iface))
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            self._witness_sig(k, m)
        }

        for var i: usize = 0; i < row->witnesses.size(); ++i {
            var unsafe *w = row->witnesses[i]
            if w == &null {
                continue
            }

            // An associated type's witness is an alias (or the requirement, for
            // a default): what the specialization needs is the TYPE, complete,
            // since its inline members return it by value.
            if isa<Declarations::TypeAliasDecl>(w) {
                if i < row->assoc_types.size() && row->assoc_types[i] != &null {
                    self._witness_dep(k, row->assoc_types[i])
                }

                continue
            }

            // A constructor slot is forwarded to by nothing: the bounded body
            // constructs `T(args)` itself, wherever the conformer is complete.
            if i < ms.size() && ms[i] != &null && DeclFacts::decl_is_ctor_requirement(ms[i]) {
                continue
            }

            // A native operation (the requirement itself as the witness, e.g. a
            // builtin's `==`) forwards to no decl: nothing to admit.
            if DeclFacts::decl_is_requirement(w) {
                continue
            }

            var unsafe *x = DeclFacts::decl_extension_of(w)
            if x != &null {
                self._witness_scope(k, x)
                continue
            }

            self._admit_use(w) // an own member: its owner complete.
        }
    }

    /// `std::hash<K>` for a Kairo record K that conforms to Hash: \p e is that
    /// imported instance, which a C++ container keyed by K names as its default
    /// hasher (`unordered_map<K, V, std::hash<K>, ...>`, as the registry spells
    /// it). The primary is disabled for a type C++ knows nothing of, so this TU
    /// specializes it (WitnessPiece::std_hash) over the row's witness, pulled
    /// in here: the TU that declares the conformance is not the one that keys
    /// the map. A record that conforms structurally has no recorded row, and a
    /// nested one cannot be declared ahead of the records that hold the map;
    /// both are left to C++'s own error, as a C++ type without a hash is.
    fn _std_hash(self, prim: unsafe *Decl, e: unsafe *InstanceEntry) {
        if e->args.size() != 1 || isa<Declarations::FunctionDecl>(prim) {
            return
        }

        var sp = DeclFacts::decl_cxx_spelling(prim)
        if !LowerTargets::is_cxx_std_hash(sp) {
            return
        }

        var unsafe *k = e->args[0]
        if k == &null || k->is_dependent() {
            return
        }

        var unsafe *kc = canon_unqual(if (k->canonical != &null) => (k->canonical) else => k)
        if !isa<RecordType>(kc) {
            return
        }

        var unsafe *kd = CXXSpell::rep(cast<RecordType>(kc)->decl)
        if kd == &null || DeclFacts::decl_is_imported(kd) {
            return
        }

        var unsafe *pd = CXXSpell::rep(DeclFacts::decl_pattern(kd))
        if self._outermost_type(pd) != pd {
            return
        }

        var *gs = self._cg->tu->global_scope
        if gs == &null {
            return
        }

        var unsafe *hd = gs->well_known()->get(WellKnownType::Hash)
        if hd == &null {
            return
        }

        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        self._cg->instances->rows_of(kc, unsafe &rows)
        var row: unsafe *ConformanceRow = &null
        for var i: usize = 0; i < rows.size(); ++i {
            if rows[i]->ok
                && rows[i]->iface_decl != &null
                && CXXSpell::rep(rows[i]->iface_decl) == CXXSpell::rep(hd) {
                row = rows[i]
                break
            }
        }

        if row == &null {
            return
        }

        if self._mode != PlanMode::Preamble && self._hidden(kd) {
            return
        }

        self._witness_row(row)
        // Keyed with usize / isize folded, as a row's specialization is: one
        // C++ class per C++ type.
        self._spell.fold_sizes = true
        var key = LowerTargets::cxx_std_hash() + "<" + self._spell._type(row->conformer) + ">"
        self._spell.fold_sizes = false
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].std_hash && self._witnesses[i].key == key {
                return
            }
        }

        var unsafe *iface = CXXSpell::rep(row->iface_decl)
        var        fresh  = WitnessPiece()
        fresh.iface    = iface
        fresh.row      = row
        fresh.key      = key
        fresh.std_hash = true
        fresh.after.push_back(iface)
        self._witnesses.push_back(fresh)
        self._witness_dep(self._witnesses.size() - 1, row->conformer)
    }

    /// The rows \p d DECLARES (`class X impl I`, `extend X impl I`), where \p d
    /// is emitted: there both X and I are complete -- \p d defines or extends
    /// X and names I -- and a C++ host instantiating a bounded template with X
    /// finds the specialization in the header that defines X, though no Kairo
    /// instance ever paired them (§7b.6). A header leaves out a row whose X or
    /// I it does not carry: the host cannot name either.
    fn _witness_declared(self, d: unsafe *Decl) {
        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        self._cg->instances->declared_rows(d, unsafe &rows)
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *row = rows[i]
            if self._mode != PlanMode::Preamble {
                if self._hidden(row->iface_decl) {
                    continue
                }

                if isa<RecordType>(row->conformer)
                    && self._hidden(cast<RecordType>(row->conformer)->decl) {
                    continue
                }
            }

            self._witness_row(row)
        }
    }

    /// The primaries of every interface \p f's bounds name: its template head
    /// carries their concepts (CXXSpell::requires_clause), so its declaration
    /// needs them, not only its body. A primary record's head carries none
    /// (CXXSpell::defers_bounds), but its member bodies still call through
    /// `I_witness<A>`, and they are written where the record is defined: in
    /// its own TU, a header has the primaries too (P900: base/alloc.hh's
    /// AllocatorScope<A impl ScopedFullAllocator> named a witness no header
    /// declared).
    fn _witness_bounds(self, f: unsafe *Decl) {
        if f == &null {
            return
        }

        // Not in the escaping probe: its answer is what ordinary codegen puts
        // in an anonymous namespace, which no header concerns.
        var own_deferred = self._mode != PlanMode::Preamble && (!self._escaping_probe) && CXXSpell::defers_bounds(f)
                        && CXXSpell::fid_of(f) == self._home && CXXSpell::template_params(f).size() > 0
        if (!own_deferred) && (self._spell.requires_clause(f).size() == 0) {
            return
        }

        var        cs = cxx::std::vector<unsafe *ConstraintExpr>()
        var unsafe *x = DeclFacts::decl_extension_of(f)
        if x != &null {
            CXXSpell::impl_bounds(DeclFacts::decl_requires_clause(x), unsafe &cs)
        }

        CXXSpell::impl_bounds(DeclFacts::decl_requires_clause(f), unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null
                || c->rhs->canonical == &null
                || !isa<RecordType>(canon_unqual(c->rhs->canonical)) {
                continue
            }

            var unsafe *d = cast<RecordType>(canon_unqual(c->rhs->canonical))->decl
            if isa<Declarations::InterfaceDecl>(
                CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(d))),
            ) {
                self._admit(d, PlanNeed::Complete)
            }
        }
    }

    /// Requirement \p f's by-value records, as a forwarder's are.
    fn _witness_sig(self, k: usize, f: unsafe *Declarations::FunctionDecl) {
        self._witness_dep(k, f->return_type)
        if f->panic_result != &null {
            self._witness_dep(k, f->panic_result)
        }

        for var j: usize = 0; j < f->params.size(); ++j {
            var unsafe *p = f->params[j]
            if p == &null || p->is_self || p->mode != ParamMode::Value {
                continue
            }

            self._witness_dep(k, p->type_)
        }
    }

    /// A by-value record \p t is a Complete dependency of witness \p k. An
    /// interface (the requirement's own `Self`) is spelled as Self, never laid
    /// out; an imported record is the header's.
    fn _witness_dep(self, k: usize, t: unsafe *Type) {
        if t == &null || t->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if !isa<RecordType>(c) {
            self._admit_type(t, PlanNeed::Complete)
            return
        }

        var unsafe *d = self.layout_decl(cast<RecordType>(c)->decl)
        if d == &null || DeclFacts::decl_is_imported(d) || isa<Declarations::InterfaceDecl>(d) {
            return
        }

        if c->is_dependent() {
            // A generic interface's panic result names its parameters (Compiler/Spec/Panic.md):
            // a full specialization's body returns it at the row's
            // arguments, which C++ instantiates right there -- from the Panic
            // template, defined first, over elements complete by then.
            var unsafe *en = dyn_cast<Declarations::EnumDecl>(
                CXXSpell::rep(cast<RecordType>(c)->decl),
            )

            if en == &null || !en->adt_explicit_tags {
                return
            }

            self._admit(d, PlanNeed::Complete)
            var unsafe *po  = self._outermost_type(d)
            var        seen = false
            for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i {
                if self._witnesses[k].deps[i] == po {
                    seen = true
                }
            }

            if !seen {
                self._witnesses[k].deps.push_back(po)
            }

            var unsafe *r = cast<RecordType>(c)
            for var i: usize = 0; i < r->args.size(); ++i {
                self._witness_dep(k, r->args[i])
            }

            return
        }

        self._admit_type(t, PlanNeed::Complete)
        var unsafe *o = self._outermost_type(d)
        for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i {
            if self._witnesses[k].deps[i] == o {
                return
            }
        }

        self._witnesses[k].deps.push_back(o)
    }

    fn _witness_scope(self, k: usize, x: unsafe *Declarations::ExtensionDecl) {
        var s = self._scope_for(x, true)
        for var i: usize = 0; i < self._witnesses[k].scopes.size(); ++i {
            if self._witnesses[k].scopes[i] == s {
                return
            }
        }

        self._witnesses[k].scopes.push_back(s)
    }

    /// # Roots: uses (preamble only)

    fn _collect_uses(self) {
        var unsafe *tu    = self._cg->tu
        var        *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// Walk visible_bodies() at body strengths, both modes: a preamble's foreign
    /// template and inline bodies, a header's own.
    fn _walk_visible(self) {
        // Every template and inline body visible here is this TU's body too:
        // EmitIR emits each one into this TU (emit_tu), so what it names has to
        // be in this preamble -- `alignof(YieldPromise<T>)`, `p->cur`, `return Suspend {}`
        // -- at the body strengths, exactly as this TU's own bodies are walked.
        // To a fixed point: a walked body can make another type Complete, and
        // that type's template bodies become visible in turn. In a header the
        // same walk is what declares the priv helpers and types an own inline
        // body names: _collect_own left them out, _admit does not.
        var walked      = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        var walked_vars = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        var progressed  = true
        while progressed {
            progressed = false
            var vis = self.visible_bodies()
            for var i: usize = 0; i < vis.size(); ++i {
                var seen = false
                for var k: usize = 0; k < walked.size(); ++k {
                    if walked[k] == vis[i] {
                        seen = true
                        break
                    }
                }

                if seen {
                    continue
                }

                walked.push_back(vis[i])
                self._walk_body(vis[i])
                progressed = true
            }

            // An eval binding's definition is interface too (Compiler/Spec/Eval.md#eval-bindings):
            // what its initializer names -- the eval fn it calls, the eval
            // constant it reads -- is this TU's to declare and define.
            var vv = self.visible_eval_vars()
            for var i: usize = 0; i < vv.size(); ++i {
                var seen = false
                for var k: usize = 0; k < walked_vars.size(); ++k {
                    if walked_vars[k] == vv[i] {
                        seen = true
                        break
                    }
                }

                if seen {
                    continue
                }

                walked_vars.push_back(vv[i])
                self.dispatch_decl(unsafe (vv[i] as unsafe *Decl))
                progressed = true
            }
        }
    }

    /// The eval bindings (namespace scope) whose `inline constexpr`
    /// definitions this TU writes beside its own (Compiler/Spec/Eval.md#eval-bindings), chosen as
    /// visible_bodies chooses: the foreign ones a preamble declares, a header's
    /// own, both for an include. An importer cannot read an `extern const` in
    /// a constant expression, so the definition, like a consteval body, is part
    /// of the interface.
    fn visible_eval_vars(self) -> cxx::std::vector<unsafe *Declarations::VariableDecl> {
        if self._mode == PlanMode::Include {
            return self.include_eval_vars()
        }

        return self._eval_vars(self._mode == PlanMode::Header)
    }

    fn include_eval_vars(self) -> cxx::std::vector<unsafe *Declarations::VariableDecl> {
        var out = self._eval_vars(false)
        var own = self._eval_vars(true)
        for var i: usize = 0; i < own.size(); ++i {
            out.push_back(own[i])
        }

        return out
    }

    /// In dependency order: a constant expression reads another constant only
    /// once it is defined, and declarations across files have no order of
    /// their own. A cycle is not a constant at all; C++ reports it.
    fn _eval_vars(self, want_own: bool) -> cxx::std::vector<unsafe *Declarations::VariableDecl> {
        var pick = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *v = dyn_cast<Declarations::VariableDecl>(self._set[i])
            if v == &null || !v->is_eval() || v->init == &null || v->is_poisoned() {
                continue
            }

            if CXXSpell::fid_of(v) == self._home != want_own {
                continue
            }

            pick.push_back(v)
        }

        var out   = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        var state = cxx::std::vector<u8>() // 0 new, 1 on the path, 2 placed; parallel to pick.
        for var i: usize = 0; i < pick.size(); ++i {
            state.push_back(0 as u8)
        }

        for var i: usize = 0; i < pick.size(); ++i {
            self._place_eval_var(i, unsafe &pick, unsafe &state, unsafe &out)
        }

        return out
    }

    fn _place_eval_var(self,
                       i:     usize,
                       pick:  unsafe *cxx::std::vector<unsafe *Declarations::VariableDecl>,
                       state: unsafe *cxx::std::vector<u8>,
                       out:   unsafe *cxx::std::vector<unsafe *Declarations::VariableDecl>) {
        if (*state)[i] != (0 as u8) {
            return
        }

        (*state)[i] = (1)
        // What the initializer reads, through the eval fns it calls too: `eval
        // A = f()` with f returning B needs B defined first, though A's
        // initializer never names it.
        var unsafe *me = unsafe ((*pick)[i] as unsafe *Decl)
        self._early_needs(me)
        var seeds = cxx::std::vector<unsafe *Decl>()
        for var r: usize = 0; r < self._en_key.size(); ++r {
            if self._en_key[r] == me && self._en_kind[r] == (0 as u8) {
                seeds.push_back(self._en_val[r])
            }
        }

        var refs = cxx::std::vector<unsafe *Decl>()
        self._early_close(seeds, 0, unsafe &refs)
        for var r: usize = 0; r < refs.size(); ++r {
            for var k: usize = 0; k < pick->size(); ++k {
                if ((*pick)[k]) == refs[r] {
                    self._place_eval_var(k, pick, state, out)
                }
            }
        }

        (*state)[i] = (2)
        out->push_back((*pick)[i])
    }

    /// # Early items (Compiler/Spec/Eval.md#value-nodes)

    /// Which compile-time items a declaration's type needs defined ahead of it
    /// (EmitPlan::early), and the order edges that put them in tier 1. Seeds:
    /// the computed values in the type of every record this plan defines
    /// (fields, bases, method signatures, nested types), of every function it
    /// declares and of every namespace-scope variable. Closed over what each
    /// item reads. A record follows every item its own types reach; an item
    /// follows the records its definition needs complete, and a binding every
    /// item it evaluates (a body only the items it evaluates at its definition:
    /// what it merely calls is defined by the time anything evaluates it, and
    /// mutual recursion stays free of cycles).
    fn _early(self) {
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d    = self._set[i]
            var        seeds = cxx::std::vector<unsafe *Decl>()
            var        rec   = self._is_type_decl(d)
            if rec {
                if self._need[i] != PlanNeed::Complete {
                    continue
                }

                self._decl_type_items(d, unsafe &seeds)
            } else if isa<Declarations::FunctionDecl>(d) {
                var unsafe *f = cast<Declarations::FunctionDecl>(d)
                for var p: usize = 0; p < f->params.size(); ++p {
                    var unsafe *pd = f->params[p]
                    if pd != &null && !pd->is_self {
                        self._type_items(pd->type_, unsafe &seeds)
                    }
                }

                self._type_items(f->return_type, unsafe &seeds)
            } else if isa<Declarations::VariableDecl>(d) {
                self._type_items(cast<Declarations::VariableDecl>(d)->type_, unsafe &seeds)
            }

            if seeds.size() == 0 {
                continue
            }

            var cl = cxx::std::vector<unsafe *Decl>()
            self._early_close(seeds, 0, unsafe &cl)
            for var k: usize = 0; k < cl.size(); ++k {
                EarlyNeeds::_once(&self.early, cl[k])
                if rec {
                    self._eo_add(d, cl[k])
                }
            }
        }

        for var k: usize = 0; k < self.early.size(); ++k {
            var unsafe *x = self.early[k]
            self._early_needs(x)
            var defs = cxx::std::vector<unsafe *Decl>()
            var want = if (isa<Declarations::VariableDecl>(x)) => (0 as u8) else => (1)
            for var i: usize = 0; i < self._en_key.size(); ++i {
                if self._en_key[i] != x {
                    continue
                }

                if self._en_kind[i] == (2 as u8) {
                    var unsafe *r = self._layout_key(self._en_val[i])
                    if r != &null && r != x {
                        var at = self._index_of(r)
                        if at != usize::MAX && self._need[at] == PlanNeed::Complete {
                            self._eo_add(x, r)
                        }
                    }
                } else if self._en_kind[i] == want {
                    defs.push_back(self._en_val[i])
                }
            }

            var cl = cxx::std::vector<unsafe *Decl>()
            self._early_close(defs, 0, unsafe &cl)
            for var i: usize = 0; i < cl.size(); ++i {
                if cl[i] != x {
                    self._eo_add(x, cl[i])
                }
            }

            // An early fn x names whose signature computes from other items is
            // declared only once those are defined (InterfaceEmitter): x's
            // definition follows them, so that declaration precedes it.
            for var i: usize = 0; i < self._en_key.size(); ++i {
                if self._en_key[i] != x || self._en_kind[i] != (0 as u8) {
                    continue
                }

                var unsafe *y = dyn_cast<Declarations::FunctionDecl>(self._en_val[i])
                if y == &null || (unsafe (y as unsafe *Decl)) == x {
                    continue
                }

                var sig = cxx::std::vector<unsafe *Decl>()
                self.sig_items(y, unsafe &sig)
                for var si: usize = 0; si < sig.size(); ++si {
                    if sig[si] != x {
                        self._eo_add(x, sig[si])
                    }
                }
            }
        }
    }

    /// The early items \p f's own signature computes from (`eval fn f(a: [i32;
    /// g(1)])`, a computed return type): C++ evaluates them where f is
    /// DECLARED, so f is declared only after they are defined. Never f itself.
    fn sig_items(self,
                 f:   unsafe *Declarations::FunctionDecl,
                 out: unsafe *cxx::std::vector<unsafe *Decl>) {
        if f == &null {
            return
        }

        var all = cxx::std::vector<unsafe *Decl>()
        for var p: usize = 0; p < f->params.size(); ++p {
            var unsafe *pd = f->params[p]
            if pd != &null && !pd->is_self {
                self._type_items(pd->type_, unsafe &all)
            }
        }

        self._type_items(f->return_type, unsafe &all)
        for var i: usize = 0; i < all.size(); ++i {
            if all[i] != (unsafe (f as unsafe *Decl)) && self.is_early(all[i]) {
                EarlyNeeds::_once(&*out, all[i])
            }
        }
    }

    /// \p x's EarlyNeeds, computed once into the _en_ tables.
    fn _early_needs(self, x: unsafe *Decl) {
        for var i: usize = 0; i < self._en_done.size(); ++i {
            if self._en_done[i] == x {
                return
            }
        }

        self._en_done.push_back(x)
        var        n  = EarlyNeeds()
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(x)
        if f != &null {
            // A member's definition is out of line: its class is complete first.
            n.named(x)
            n.dispatch_decl(x)
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(x)
        if v != &null {
            n.rec_type(v->type_)
            if v->init != &null {
                n.dispatch_expr(v->init)
            }
        }

        for var i: usize = 0; i < n.items.size(); ++i {
            if n.items[i] == x {
                continue
            }

            self._en_key.push_back(x)
            self._en_kind.push_back(0 as u8)
            self._en_val.push_back(n.items[i])
        }

        for var i: usize = 0; i < n.const_items.size(); ++i {
            if n.const_items[i] == x {
                continue
            }

            self._en_key.push_back(x)
            self._en_kind.push_back(1 as u8)
            self._en_val.push_back(n.const_items[i])
        }

        for var i: usize = 0; i < n.recs.size(); ++i {
            self._en_key.push_back(x)
            self._en_kind.push_back(2 as u8)
            self._en_val.push_back(n.recs[i])
        }
    }

    /// \p seeds and every item they read (kind 0), transitively, into \p out.
    fn _early_close(self,
                    const seeds: cxx::std::vector<unsafe *Decl>,
                    kind:        u8,
                    out:         unsafe *cxx::std::vector<unsafe *Decl>) {
        for var i: usize = 0; i < seeds.size(); ++i {
            EarlyNeeds::_once(&*out, (seeds)[i])
        }

        for var k: usize = 0; k < out->size(); ++k {
            var unsafe *it = (*out)[k]
            self._early_needs(it)
            for var i: usize = 0; i < self._en_key.size(); ++i {
                if self._en_key[i] == it && self._en_kind[i] == kind {
                    EarlyNeeds::_once(&*out, self._en_val[i])
                }
            }
        }
    }

    /// The items the types written in record \p d's definition compute from:
    /// fields, bases, method signatures, nested records' (they are defined
    /// inside it).
    fn _decl_type_items(self, d: unsafe *Decl, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        var unsafe *rec = self.adt_record(d)
        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(rec) {
            var unsafe *c = cast<Declarations::ClassDecl>(rec)
            fields  = unsafe &c->fields
            methods = unsafe &c->methods
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e = c->derives_list.get(i)
                if e != &null {
                    self._type_items(e->base, out)
                }
            }
        } else if isa<Declarations::StructDecl>(rec) {
            fields  = unsafe &cast<Declarations::StructDecl>(rec)->fields
            methods = unsafe &cast<Declarations::StructDecl>(rec)->methods
        } else if isa<Declarations::UnionDecl>(rec) {
            fields  = unsafe &cast<Declarations::UnionDecl>(rec)->fields
            methods = unsafe &cast<Declarations::UnionDecl>(rec)->methods
        }

        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var unsafe *f = (*fields)[i]
                if f != &null {
                    self._type_items(f->type_, out)
                }
            }
        }

        if methods != &null {
            for var i: usize = 0; i < methods->size(); ++i {
                var unsafe *m = (*methods)[i]
                if m == &null {
                    continue
                }

                for var p: usize = 0; p < m->params.size(); ++p {
                    var unsafe *pd = m->params[p]
                    if pd != &null && !pd->is_self {
                        self._type_items(pd->type_, out)
                    }
                }

                self._type_items(m->return_type, out)
            }
        }

        // A generic record's value predicates C++ cannot evaluate on the
        // template head are its body's static_asserts (InterfaceEmitter::
        // _record_def): the items they name are declared, and defined, ahead of
        // the template, as a computed field type's are. EvalUsageChecking::
        // _check_record has refused an item that needs the record back.
        // An ADT enum's clause is the enum's, not its layout record's.
        var unsafe *rq = DeclFacts::decl_requires_clause(d)
        if rq == &null {
            rq = DeclFacts::decl_requires_clause(rec)
        }

        if CXXSpell::template_params(rec).size() > 0 || CXXSpell::template_params(d).size() > 0 {
            var vps = cxx::std::vector<unsafe *Expr>()
            CXXSpell::value_predicates(rq, unsafe &vps)
            for var i: usize = 0; i < vps.size(); ++i {
                var n = EarlyNeeds()
                n.dispatch_expr(vps[i])
                for var k: usize = 0; k < n.items.size(); ++k {
                    EarlyNeeds::_once(&*out, n.items[k])
                }
            }
        }

        var unsafe *dc = CXXSpell::dc_of(rec)
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || !self._is_type_decl(nd) {
                continue
            }

            if isa<Declarations::UnionDecl>(nd) && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                continue
            }

            self._decl_type_items(CXXSpell::rep(nd), out)
        }
    }

    /// The items computed values in \p t name.
    fn _type_items(self, t: unsafe *Type, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        if t == &null {
            return
        }

        var n = EarlyNeeds()
        self._type_items_walk(t, unsafe &n, 0)
        for var i: usize = 0; i < n.items.size(); ++i {
            EarlyNeeds::_once(&*out, n.items[i])
        }
    }

    /// _type_items' walk: EarlyNeeds::rec_type on \p t, and on every type
    /// written inside it, through pointers, references and arguments too. A
    /// computed value behind a pointer (`*Widget<Pt(2, 3)>`) is evaluated
    /// where the declaration is written all the same, though its
    /// record is not needed complete -- only the items are read from \p n.
    fn _type_items_walk(self, t: unsafe *Type, n: unsafe *EarlyNeeds, depth: u32) {
        if t == &null || depth > (16 as u32) {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        var d1 = depth + (1 as u32)
        match c->kind {
            case TypeKind::QualifiedType {
                self._type_items_walk(cast<QualifiedType>(c)->inner, n, d1)
            } case TypeKind::PointerType {
                self._type_items_walk(cast<PointerType>(c)->pointee, n, d1)
            } case TypeKind::CXXLValueRefType {
                self._type_items_walk(cast<CXXLValueRefType>(c)->referee, n, d1)
            } case TypeKind::CXXRValueRefType {
                self._type_items_walk(cast<CXXRValueRefType>(c)->referee, n, d1)
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    self._type_items_walk(*fp->params.get(i), n, d1)
                }

                self._type_items_walk(fp->return_type, n, d1)
            } case TypeKind::RecordType {
                n->rec_type(c)
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    self._type_items_walk(*r->args.get(i), n, d1)
                }
            } default {
                n->rec_type(c)
            }
        }
    }

    fn _eo_add(self, who: unsafe *Decl, dep: unsafe *Decl) {
        if who == &null || dep == &null || who == dep {
            return
        }

        if self._eo_has(who, dep) {
            return
        }

        self._eo_who.push_back(who)
        self._eo_dep.push_back(dep)
    }

    fn _eo_has(self, who: unsafe *Decl, dep: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self._eo_who.size(); ++i {
            if self._eo_who[i] == who && self._eo_dep[i] == dep {
                return true
            }
        }

        return false
    }

    /// The tier-1 decl whose definition lays out record \p d: its primary for
    /// an instance, its outermost record for a nested one.
    fn _layout_key(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *c = CXXSpell::rep(d)
        if c == &null {
            return &null
        }

        if DeclFacts::decl_is_instance(c) {
            var unsafe *e = self._cg->instances->entry_of(c)
            if e == &null {
                return &null
            }

            c = CXXSpell::rep(e->primary)
            if c == &null {
                return &null
            }
        }

        if !self._is_type_decl(c) {
            return &null
        }

        return self._outermost_type(c)
    }

    /// \p d (a defining link) is defined in tier 1 as an early item.
    fn is_early(self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self.early.size(); ++i {
            if self.early[i] == d {
                return true
            }
        }

        return false
    }

    /// THE list of foreign bodies this TU emits, beside its own (which EmitIR
    /// walks off the program): every template and `inline` definition visible
    /// here, once each, as the defining link. EmitIR emits exactly this list and
    /// _walk_visible walks exactly this list, so what is planned and what is
    /// emitted cannot drift.
    ///
    /// In Header mode the same rule picks the OWN bodies instead: a header is
    /// the interface for C++ consumers and for nothing else, so it carries
    /// exactly what an importing Kairo TU would emit from this module (the
    /// foreign ones arrive through the headers it includes).
    ///
    /// The rule is C++'s template model: a template's definition must be
    /// visible in every TU that can instantiate it, and Kairo cannot list every
    /// instantiation -- clang makes some on its own (a coroutine promise,
    /// `await_suspend<coroutine_handle<...>>`, std::sort calling a Kairo
    /// comparator). So, wherever the owner is held Complete:
    ///
    ///   - every member body of a class template (members of its nested
    ///     records included -- they are templated by the enclosing one);
    ///   - every member TEMPLATE of any class, template or not;
    ///   - every free function template the plan declares;
    ///   - every generic extension member (its own or its extension's params).
    ///
    /// And `inline` bodies, by the same rule for a different reason: `inline`
    /// puts a body in the interface, so importers compile it themselves.
    ///
    ///   - every `inline` member of every record held Complete -- ALL of them,
    ///     never pruned by Kairo-visible references, because Kairo never sees
    ///     clang's own calls (`await_ready`, `initial_suspend`, ...);
    ///   - every `inline` free function or extension member the plan declares,
    ///     at any strength.
    ///
    /// Read off _set rather than this TU's roots, so it is transitive: a
    /// `priv inline` helper that an inline body calls is admitted by the walk
    /// below and its body joins the list on the next pass. That one matters --
    /// clang emits an inline definition only in objects that use it, so the
    /// helper's own object may well not hold it.
    ///
    /// Cheap because of `extern template`: a registry instance is still
    /// compiled once, in its home TU (InterfaceEmitter's tier 3 declares it
    /// `extern` everywhere else, which stops implicit instantiation of its
    /// members there). The bodies emitted everywhere are parsed everywhere but
    /// only instantiated for the instances Kairo never saw. Those `extern
    /// template` lines are NOT redundant with this; removing them would compile
    /// every known instance in every TU that uses it.
    fn visible_bodies(self) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        // Preamble: foreign only (own bodies are emitted off the program).
        // Header: own only.
        // Include: both. The host is a C++ TU that includes nothing else of
        // Kairo's, and it compiles foo's templates and inline functions itself;
        // _walk_visible walks the same list, so whatever they name is planned.
        if self._mode == PlanMode::Include {
            return self.include_bodies()
        }

        return self._bodies(self._mode == PlanMode::Header)
    }

    /// The foreign bodies, then the own ones: what an Include plan carries.
    fn include_bodies(self) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        var out = self._bodies(false)
        var own = self._bodies(true)
        for var i: usize = 0; i < own.size(); ++i {
            out.push_back(own[i])
        }

        return out
    }

    fn _bodies(self, want_own: bool) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        var out = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if CXXSpell::fid_of(d) == self._home != want_own {
                continue
            }

            if self._is_type_decl(d) {
                if self._need[i] != PlanNeed::Complete {
                    continue
                }

                self._visible_record_bodies(d, false, unsafe &out)
                continue
            }

            if d->kind != DeclKind::FunctionDecl {
                continue
            }

            if CXXSpell::template_params(d).size() == 0
                && (!cast<Declarations::FunctionDecl>(d)->is_inline())
                && !cast<Declarations::FunctionDecl>(d)->is_eval() {
                continue
            }

            self._push_body(cast<Declarations::FunctionDecl>(d), &out)
        }

        // Extension members are never in _set: their scope declares them, and a
        // preamble defines every scope it touches.
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var *sc = &self._scopes[i]
            for var k: usize = 0; k < sc->members.size(); ++k {
                var unsafe *m = sc->members[k]
                if m == &null {
                    continue
                }

                if CXXSpell::fid_of(m) == self._home != want_own {
                    continue
                }

                if CXXSpell::template_params(unsafe (m as unsafe *Decl)).size() == 0
                    && !m->is_inline()
                    && !m->is_eval() {
                    continue
                }

                self._push_body(m, &out)
            }
        }

        return out
    }

    /// \p d's member bodies that are part of its interface: all of them under a
    /// class template (\p in_template), only its member templates and `inline`
    /// members otherwise. Nested records recurse, as EmitIR::_record_bodies does.
    fn _visible_record_bodies(
        self,
        d:           unsafe *Decl,
        in_template: bool,
        out:         unsafe *cxx::std::vector<unsafe *Declarations::FunctionDecl>,
    ) {
        var templ = in_template || DeclFacts::decl_generic_params(d).size() > 0
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(d) {
            methods = unsafe &cast<Declarations::ClassDecl>(d)->methods
        } else if isa<Declarations::StructDecl>(d) {
            methods = unsafe &cast<Declarations::StructDecl>(d)->methods
        } else if isa<Declarations::UnionDecl>(d) {
            methods = unsafe &cast<Declarations::UnionDecl>(d)->methods
        }

        if methods != &null {
            for var i: usize = 0; i < methods->size(); ++i {
                var unsafe *m = (*methods)[i]
                if m == &null {
                    continue
                }

                // Neither template nor inline: linked from its own TU.
                if !templ && m->generic_params.size() == 0 && !m->is_inline() && !m->is_eval() {
                    continue
                }

                self._push_body(m, &*out)
            }
        }

        var unsafe *dc = CXXSpell::dc_of(d)
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null {
                continue
            }

            if isa<Declarations::ClassDecl>(nd)
                || isa<Declarations::StructDecl>(nd)
                || isa<Declarations::UnionDecl>(nd) {
                self._visible_record_bodies(nd, templ, out)
            }
        }
    }

    /// The DEFINING link of \p f -- an in-class declaration whose body is out of
    /// line is in the member list, the body is on the chain -- once. Nothing
    /// without a block body: there is nothing to make visible.
    fn _push_body(self,
                  f:          unsafe *Declarations::FunctionDecl,
                  @inout out: cxx::std::vector<unsafe *Declarations::FunctionDecl>) {
        var unsafe *def = f
        if !def->has_body() {
            var unsafe *d = def->definition()
            if d == &null || d->is_poisoned() {
                return
            }

            def = d
        }

        if def->is_poisoned() || def->body_kind != Declarations::FnBodyKind::Block {
            return
        }

        for var i: usize = 0; i < out.size(); ++i {
            if (out)[i] == def {
                return
            }
        }

        out.push_back(def)
    }

    /// One visible body, walked as this TU's own bodies are. An extension
    /// member's receiver is emitted as its first parameter, so the extension's
    /// target is laid out here.
    fn _walk_body(self, f: unsafe *Declarations::FunctionDecl) {
        var unsafe *x = DeclFacts::decl_extension_of(f)
        if x != &null && x->target != &null {
            self._admit_type(x->target, PlanNeed::Complete)
        }

        self.dispatch_decl(f)
    }

    /// Every expression: its resolved links, and its TYPE. An expression of
    /// class type is a prvalue or an lvalue clang has to lay out, so a
    /// by-value record type at any expression is Complete -- that is how a
    /// call's return type enters at full strength while the callee's
    /// declaration only names it.
    fn visit_expr(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return true
        }

        if e->kind == ExprKind::CallExpr && cast<CallExpr>(e)->fmt_dyn {
            self.needs_fmt_dyn = true
        }

        if e->type_ != &null {
            self._admit_type(e->type_, PlanNeed::Complete)
        }

        // A pointer to a class with bases converts to a base pointer at any
        // return, argument or initializer EmitIR::_value finds a different
        // pointer type at -- a `static_cast<Base *>` no node of the tree
        // records -- and C++ relates the two only through a complete class
        // ("not related by inheritance" otherwise).
        self._admit_derived_pointee(e->type_)
        match e->kind {
            case ExprKind::NamedIdentExpr {
                var unsafe *n = cast<NamedIdentExpr>(e)
                self._admit_use(n->resolved_decl)
                self._admit_cell(n->candidate_cell)
            } case ExprKind::ChainExpr {
                var unsafe *c = cast<ChainExpr>(e)
                for var i: usize = 0; i < c->steps.size(); ++i {
                    var unsafe *s = c->steps.get(i)
                    if s == &null {
                        continue
                    }

                    self._admit_use(s->resolved_decl)
                    self._admit_cell(s->candidate_cell)
                    // `n->k` with k a member of n's BASE: _admit_use made the
                    // base complete, but C++ looks k up in n's own class, so the
                    // receiver is complete too. A `.` on a value is already
                    // complete through its expression type; a `::` step names a
                    // scope, not an object.
                    if s->access_kind != ChainExpr::AccessKind::ColonColon {
                        if i > 0 {
                            self._admit_receiver(c->steps.get(i - 1)->resolved_type)
                        } else if c->base != &null {
                            self._admit_receiver(c->base->type_)
                        }
                    }

                    // `Box<int>::count`: the member is looked up in the class,
                    // so the instance is complete here (as CallExpr::qualifier).
                    self._admit_type(s->through, PlanNeed::Complete)
                }
            } case ExprKind::ClosureExpr {
                // A panicking closure's lambda returns its Panic result.
                self._admit_type(cast<ClosureExpr>(e)->panic_result, PlanNeed::Complete)
            } case ExprKind::StringLiteralExpr {
                // A byte literal C++ reads at compile time (Compiler/Spec/Eval.md#strings-at-compile-time): a long
                // one is a named array this plan's interface defines.
                var unsafe *sl = cast<StringLiteralExpr>(e)
                if sl->const_eval && sl->imm != &null && sl->imm->has_owned_text() {
                    self.note_eval_str(sl->imm->owned_ptr, sl->imm->owned_len as usize)
                }
            } case ExprKind::ConstraintExpr {
                // `eval if A impl I` in a body is I's concept (EmitIR::_constraint),
                // which only a requires clause would otherwise have planned.
                var unsafe *ce = cast<ConstraintExpr>(e)
                if !ce->is_derives()
                    && ce->rhs != &null
                    && ce->rhs->canonical != &null
                    && isa<RecordType>(canon_unqual(ce->rhs->canonical)) {
                    var unsafe *cd = cast<RecordType>(canon_unqual(ce->rhs->canonical))->decl
                    if isa<Declarations::InterfaceDecl>(
                        CXXSpell::rep(DeclFacts::decl_pattern(CXXSpell::rep(cd))),
                    ) {
                        self._admit(cd, PlanNeed::Complete)
                    }
                }
            } case ExprKind::SizeOfExpr {
                // The operand is laid out, not just named: Complete, whatever
                // visit_type (Fwd, for a type merely spelled) would say.
                self._admit_type(cast<SizeOfExpr>(e)->type_arg, PlanNeed::Complete)
            } case ExprKind::AlignOfExpr {
                self._admit_type(cast<AlignOfExpr>(e)->type_arg, PlanNeed::Complete)
            } case ExprKind::TypeTraitExpr {
                // clang's trivially-* builtins need the type complete, as sizeof does.
                self._admit_type(cast<TypeTraitExpr>(e)->type_arg, PlanNeed::Complete)
            } case ExprKind::BinaryOperatorExpr {
                // `typeof T == U`: `__is_same` only names its types.
                var unsafe *bo = cast<BinaryOperatorExpr>(e)
                if bo->type_cmp_lhs != &null {
                    self._admit_type(bo->type_cmp_lhs, PlanNeed::Fwd)
                    self._admit_type(bo->type_cmp_rhs, PlanNeed::Fwd)
                }
            } case ExprKind::CallExpr {
                // A generic callee's instance: tier 3, homed where it was first
                // named, `extern template` elsewhere. A FUNCTION instance's decl
                // is the primary itself (InstantiationRegistry::_new_instance),
                // so it never comes through _admit's instance-shell path.
                var unsafe *ie = cast<CallExpr>(e)->instance
                if ie != &null {
                    self._admit_instance(ie, PlanNeed::Fwd)
                }

                // `Box<int>::zero()`: the member is looked up in the class, so
                // the instance is complete here, and homed like any named one.
                self._admit_type(cast<CallExpr>(e)->qualifier, PlanNeed::Complete)
                // `I::m(x)` on a concrete x: its row rides on the call.
                var unsafe *wr = cast<CallExpr>(e)->witness_row
                if wr != &null {
                    self._witness_row(wr)
                }
            } default { }
        }

        return true
    }

    /// A compile-time literal's bytes, \p n of them at \p p: one past the
    /// inline limit is recorded for its named definition, once per content
    /// (the name is the content's, so equal bytes are one definition).
    fn note_eval_str(self, p: kairo::std::ConstPtr<u8>, n: usize) {
        if n <= LowerTargets::eval_str_inline_max() {
            return
        }

        var h = LowerTargets::eval_str_hash(p, n)
        for var i: usize = 0; i < self.big_str_hashes.size(); ++i {
            if self.big_str_hashes[i] == h && self.big_str_lens[i] == n {
                return
            }
        }

        self.big_str_bytes.push_back(p)
        self.big_str_lens.push_back(n)
        self.big_str_hashes.push_back(h)
    }

    /// Naming a type in syntax declares it; layout strength comes from the
    /// declaration positions in visit_decl.
    fn visit_type(self, t: unsafe *Type) -> bool {
        if t == &null {
            return true
        }

        var unsafe *c = t->canonical
        if c == &null {
            return true
        }

        if c->kind != TypeKind::RecordType {
            return true
        }

        self._admit(cast<RecordType>(c)->decl, PlanNeed::Fwd)
        return true
    }

    /// Whether a `return` from this function's expansion copies carries a
    /// value: EmitIR::_eval_for's has_val, read before its body is walked.
    fn visit_function_decl(self, n: unsafe *Declarations::FunctionDecl) -> bool {
        if n == &null {
            return true
        }

        var rt: unsafe *Type = &null
        if !n->is_noreturn {
            rt = n->return_type
        }

        if n->panic_result != &null {
            rt = n->panic_result
        }

        var val = rt != &null && rt->canonical != &null
        if val {
            var unsafe *c = canon_unqual(rt->canonical)
            if c != &null && isa<BuiltinType>(c) {
                var k = cast<BuiltinType>(c)->builtin
                if k == BuiltinKind::Void || k == BuiltinKind::Never {
                    val = false
                }
            }
        }

        self._ef_value_fn = val
        return true
    }

    fn visit_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> bool {
        if n == &null {
            return true
        }

        if (n->is_eval || n->iter_kind == IterKind::Pack) && self._ef_value_fn {
            self.needs_ef_slot = true
        }

        return true
    }

    /// Declared types are LAYOUT positions: Complete, weakened by the shape.
    fn visit_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return true
        }

        match d->kind {
            case DeclKind::VariableDecl {
                if cast<Declarations::VariableDecl>(d)->raw_slot {
                    self.needs_raw_slot = true
                }

                self._admit_type(cast<Declarations::VariableDecl>(d)->type_, PlanNeed::Complete)
            } case DeclKind::FieldDecl {
                self._admit_type(cast<Declarations::FieldDecl>(d)->type_, PlanNeed::Complete)
            } case DeclKind::ParamDecl {
                var unsafe *p = cast<Declarations::ParamDecl>(d)
                self._admit_type(
                    (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                    PlanNeed::Complete,
                )
            } case DeclKind::FunctionDecl {
                self._admit_type(
                    cast<Declarations::FunctionDecl>(d)->return_type,
                    PlanNeed::Complete,
                )

                self._admit_type( // Compiler/Spec/Panic.md#paniclowering: what C++ returns.
                    cast<Declarations::FunctionDecl>(d)->panic_result,
                    PlanNeed::Complete,
                )

                if !self.needs_nopanic && plan_under_duck(d) {
                    self.needs_nopanic = true
                }
            } case DeclKind::TypeAliasDecl {
                self._admit_type(cast<Declarations::TypeAliasDecl>(d)->aliased, PlanNeed::Complete)
            } default { }
        }

        return true
    }

    /// A use site. A member of a type (method, field, static, nested type)
    /// needs its OWNER complete: C++ cannot look into an incomplete class.
    /// A free function or a type needs a declaration.
    fn _admit_use(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var unsafe *owner = self._member_owner(d)
        if owner != &null {
            self._admit(owner, PlanNeed::Complete)
            return
        }

        self._admit(d, PlanNeed::Fwd)
    }

    fn _admit_cell(self, cell: unsafe *OverloadCell) {
        if cell == &null {
            return
        }

        for var i: usize = 0; i < cell->size(); ++i {
            self._admit_use(cell->get(i))
        }
    }

    /// The object of a member step: \p t itself, or what it points at. C++
    /// looks the member up in that class, so it is complete.
    fn _admit_receiver(self, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = canon_unqual(if (t->canonical != &null) => (t->canonical) else => t)
        if c != &null && isa<PointerType>(c) {
            c = canon_unqual(cast<PointerType>(c)->pointee)
        }

        if c != &null && isa<RecordType>(c) {
            self._admit_type(c, PlanNeed::Complete)
        }
    }

    /// \p t a pointer to a class with bases: that class complete (see
    /// visit_expr). Anything else is left as its shape admits it.
    fn _admit_derived_pointee(self, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = canon_unqual(if (t->canonical != &null) => (t->canonical) else => t)
        if c == &null || !isa<PointerType>(c) {
            return
        }

        var unsafe *p = canon_unqual(cast<PointerType>(c)->pointee)
        if p == &null || !isa<RecordType>(p) {
            return
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(CXXSpell::rep(cast<RecordType>(p)->decl))
        if cd != &null && cd->has_bases() {
            self._admit_type(p, PlanNeed::Complete)
        }
    }

    /// \p t is a tuple by value: the record TupleRecords made for one (a
    /// TupleType too, though none is canonical after T).
    fn is_tuple_type(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(if (t->canonical != &null) => (t->canonical) else => t)
        if c == &null {
            return false
        }

        if isa<TupleType>(c) {
            return true
        }

        if !isa<RecordType>(c) {
            return false
        }

        // The arity is the pattern's (TupleRecords), never an instance's.
        var unsafe *sd = dyn_cast<Declarations::StructDecl>(
            self.layout_decl(cast<RecordType>(c)->decl),
        )

        return sd != &null && sd->tuple_arity > 0
    }

    /// Every record \p t reaches through pointers, fields, method results and
    /// generic arguments, each complete (see _admit_instance, O36b). Once per
    /// record per plan: _duck_seen.
    fn _duck_reach(self, t: unsafe *Type, depth: u32) {
        if t == &null || depth > 64 {
            return
        }

        var unsafe *c = canon_unqual(if (t->canonical != &null) => (t->canonical) else => t)
        if c == &null {
            return
        }

        match c->kind {
            case TypeKind::PointerType {
                self._duck_reach(cast<PointerType>(c)->pointee, depth + 1)
                return
            } case TypeKind::CXXLValueRefType {
                self._duck_reach(cast<CXXLValueRefType>(c)->referee, depth + 1)
                return
            } case TypeKind::CXXRValueRefType {
                self._duck_reach(cast<CXXRValueRefType>(c)->referee, depth + 1)
                return
            } case TypeKind::NullableType {
                self._duck_reach(self._nullable_record(c), depth + 1)
                return
            } case TypeKind::FixedArrayType {
                self._duck_reach(cast<FixedArrayType>(c)->element, depth + 1)
                return
            }

            // A record falls out of the switch to the walk below; Stage 1 has no
            // `break` out of a switch, so the default arm tests for it instead.
            default {
                if c->kind != TypeKind::RecordType {
                    return
                }
            }
        }

        var unsafe *r = cast<RecordType>(c)
        var unsafe *d = CXXSpell::rep(r->decl)
        if d == &null {
            return
        }

        for var i: usize = 0; i < self._duck_seen.size(); ++i {
            if self._duck_seen[i] == d {
                return
            }
        }

        self._duck_seen.push_back(d)
        self._admit_type(c, PlanNeed::Complete)
        for var i: usize = 0; i < r->args.size(); ++i {
            self._duck_reach(*r->args.get(i), depth + 1)
        }

        if DeclFacts::decl_is_imported(d) {
            return
        }

        var unsafe *rec = self.adt_record(d)
        if rec == &null {
            return
        }

        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        match rec->kind {
            case DeclKind::ClassDecl {
                fields  = unsafe &cast<Declarations::ClassDecl>(rec)->fields
                methods = unsafe &cast<Declarations::ClassDecl>(rec)->methods
            } case DeclKind::StructDecl {
                fields  = unsafe &cast<Declarations::StructDecl>(rec)->fields
                methods = unsafe &cast<Declarations::StructDecl>(rec)->methods
            } case DeclKind::UnionDecl {
                fields  = unsafe &cast<Declarations::UnionDecl>(rec)->fields
                methods = unsafe &cast<Declarations::UnionDecl>(rec)->methods
            } default {
                return
            }
        }

        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *f = *fields->get(i)
            if f != &null {
                self._duck_reach(f->type_, depth + 1)
            }
        }

        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = *methods->get(i)
            if m != &null {
                self._duck_reach(m->return_type, depth + 1)
            }
        }
    }

    /// The type whose scope holds \p d, or null for a namespace-scope decl.
    fn _member_owner(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return &null
        }

        if !dc->is_type_scope() {
            return &null
        }

        if dc->dc_kind == DeclContextKind::Extension { // its scope's static member, not the target's.
            return &null
        }

        return dc->dc_owner
    }

    /// # The working set

    /// Everything funnels through here. Decides what is plannable, redirects
    /// instances to their primary and nested types to their outermost owner.
    fn _admit(self, d: unsafe *Decl, need: PlanNeed) {
        if d == &null {
            return
        }

        var unsafe *c = CXXSpell::rep(d)
        if c == &null {
            return
        }

        // A record declared in a function body (FinallyLowering's guard) is part
        // of that body: EmitIR emits it in place, and nothing about it belongs
        // in the preamble or the header. Its fields' owner and its destructor
        // land here too and are skipped the same way.
        if CXXSpell::in_function_scope(c) {
            return
        }

        // The header declares it (Compiler/Spec/Interop.md#ffi-imports) -- but an instance of an
        // imported C++ template is written out in THIS TU's text with its
        // arguments spelled whole (`std::vector<Loc::File::File *>`), so the
        // Kairo types they name must be declared here (_admit_instance).
        if DeclFacts::decl_is_imported(c) && !DeclFacts::decl_is_instance(c) {
            return
        }

        if DeclFacts::decl_ffi_tag_target(c) != &null { // `ffi "c" struct T`: the header's tag, not a Kairo type (§5.2).
            return
        }

        // An interface's C++ entity is its witness: named by a call through a
        // bound (_admit_use on the requirement), or by a bound's concept.
        if isa<Declarations::InterfaceDecl>(c) {
            self._witness_primary(c)
            return
        }

        // An extension member reached through a use (`l.pos.len()`) is not a
        // member by _member_owner, so without this it is admitted a second time
        // as an ordinary function; it is its scope's static member instead.
        var unsafe *x = DeclFacts::decl_extension_of(c)
        if x != &null {
            self._scope_for(x, true)
            return
        }

        if DeclFacts::decl_is_instance(c) {
            var unsafe *e = self._cg->instances->entry_of(c)
            if e == &null && DeclFacts::decl_is_imported(c) { // no registry entry: nothing of ours to name.
                return
            }

            if e == &null {
                self._ice(c->range, "EmitPlan: instance shell with no registry entry")
            }

            self._admit_instance(e, need)
            return
        }

        if !self._plannable(c) {
            return
        }

        // A nested type is part of its outermost owner's definition.
        var unsafe *outer = self._outermost_type(c)
        if outer != c {
            self._admit(outer, need)
            return
        }

        // A payload struct is minted inside its ADT (its semantic_dc is the
        // enum), so the fold above always takes it to the enum, whose layout
        // record defines it. One planned here as a record of its own would be
        // defined twice -- inside the ADT and again beside it.
        var unsafe *ps = dyn_cast<Declarations::StructDecl>(c)
        if ps != &null && ps->is_adt_payload {
            self._ice(
                c->range,
                "EmitPlan: an ADT payload struct reached the plan as a record of its own; EnumLayoutLowering places it in its enum",
            )
        }

        var at = self._index_of(c)
        if at == usize::MAX {
            self._set_at.try_emplace(c as usize as u64, (self._set.size() as u64))
            self._set.push_back(c)
            self._need.push_back(need)
            self._queue.push_back(self._set.size() - 1)
            self._admit_specs(c, need)
            return
        }

        if (need as u8) > (self._need[at] as u8) {
            self._need[at] = need
            self._queue.push_back(at)
            self._admit_specs(c, need)
        }
    }

    /// A generic record's specializations ride with it at the same strength:
    /// every C++ TU that can name `Store<X>` must have seen each `Store<P*>` /
    /// `Store<bool>` before the first use that would instantiate one, or it
    /// instantiates the primary for it ([temp.expl.spec]/7, no diagnostic
    /// required). A Complete primary admits them Complete so an instance
    /// selected into a partial is laid out by it.
    fn _admit_specs(self, c: unsafe *Decl, need: PlanNeed) {
        if DeclFacts::decl_generic_params(c).size() == 0 || CXXSpell::is_record_spec(c) {
            return
        }

        var specs = cxx::std::vector<unsafe *Decl>()
        self._cg->instances->specs_of(c, unsafe &specs)
        for var i: usize = 0; i < specs.size(); ++i {
            var unsafe *sd = CXXSpell::rep(specs[i])
            if sd == &null || sd->is_poisoned() {
                continue
            }

            self._admit(sd, need)
        }
    }

    /// `Box<Foo>`: the primary at \p need, each argument at \p need only
    /// where the primary stores it by value, else Fwd; the instance itself
    /// recorded for tier 3.
    fn _admit_instance(self, e: unsafe *InstanceEntry, need: PlanNeed) {
        var unsafe *prim = CXXSpell::rep(e->primary)
        // clang instantiates it from the PCH, but its arguments are spelled in
        // THIS TU's text: `std::vector<Loc::File::File *>` in a foreign class's
        // field needs `File` declared here, or the qualified name does not
        // resolve. Naming the instance asks only Fwd of them; an instance held
        // at Complete is one whose members this TU instantiates -- the
        // destructor an owner's implicit one calls, size(), the allocator's
        // sizeof -- and every one of those needs a by-value argument complete.
        // _admit_type still weakens an argument behind a pointer
        // (`vector<File *>`) to Fwd. Strength only: definition order is the
        // layout's (_needs_complete), which a template argument never is.
        //
        // An imported FUNCTION template (`kairo::std::create<T>(a)`, which is
        // `new T(a)`) is instantiated in this TU at its arguments whatever the
        // call's strength, so each is complete (O36b), as a Kairo one's is below.
        if DeclFacts::decl_is_imported(prim) {
            var imp_need = if (isa<Declarations::FunctionDecl>(prim)) => (PlanNeed::Complete)
                           else => need
            for var i: usize = 0; i < e->args.size(); ++i {
                self._admit_type(e->args[i], imp_need)
            }

            self._std_hash(prim, e)
            return
        }

        // A `<T: type>` instance (O36b): its body is checked by C++ alone, and a
        // chain through T (`self.dyn()->sc->g->is_builtin_fid(...)`) is spelled
        // as written, untyped, so no node names the classes it walks through.
        // The C++ that instantiates the body here needs every one complete:
        // what an argument reaches through its fields and method results.
        // A header carries no body of a foreign instance, and the wider
        // closure would only turn its forward declarations into includes.
        if self._mode != PlanMode::Header && plan_under_duck(prim) {
            for var i: usize = 0; i < e->args.size(); ++i {
                self._duck_reach(e->args[i], 0)
            }
        }

        // A generic REQUIREMENT's instance names no C++ function: the call goes
        // through the witness's member template, instantiated implicitly. No
        // tier-3 line, ever (Compiler/Spec/Witnesses.md#rows-instances-and-odr); its arguments are still named.
        if self._is_requirement(prim) {
            for var i: usize = 0; i < e->args.size(); ++i {
                self._admit_type(e->args[i], PlanNeed::Fwd)
            }

            return
        }

        // A member template of a CLASS TEMPLATE: the entry holds the member's own
        // arguments only, not the owner's, so it names no one C++ entity
        // (`Box<A>::both<X>` and `Box<B>::both<X>` are one entry) and no tier-3
        // line can spell it. Its body is visible wherever the owner is complete
        // (§7), so the C++ instantiates it implicitly; its rows still apply.
        if self._member_of_template(prim) {
            for var i: usize = 0; i < e->rows.size(); ++i {
                self._witness_row(e->rows[i])
            }

            for var i: usize = 0; i < e->args.size(); ++i {
                self._admit_type(e->args[i], PlanNeed::Fwd)
            }

            // Its body is compiled wherever the owner is, so what it reaches is
            // needed there too, rows included (no tier-3 line of its own).
            var mseen = false
            for var i: usize = 0; i < self._members.size(); ++i {
                if self._members[i] == e {
                    mseen = true
                    break
                }
            }

            if !mseen {
                self._members.push_back(e)
                self._admit_reached(e)
                for var i: usize = 0; i < e->panic_types.size(); ++i {
                    self._admit_type(e->panic_types[i], PlanNeed::Complete)
                }
            }

            return
        }

        var seen = false
        for var i: usize = 0; i < self._insts.size(); ++i {
            if self._insts[i] == e {
                seen = true
                break
            }
        }

        if !seen {
            self._insts.push_back(e)
            self._admit_reached(e)
            // The panic results its body names at these arguments (Compiler/Spec/Panic.md,
            // InstanceEntry::panic_types): C++ forms them only when it
            // instantiates the body, so their elements' ids must be written
            // wherever it may.
            for var i: usize = 0; i < e->panic_types.size(); ++i {
                self._admit_type(e->panic_types[i], PlanNeed::Complete)
            }
        }

        self._admit(prim, PlanNeed::Complete)
        // Every TU holding the instance may compile its body (it is a visible
        // C++ inline body), so every one needs the specializations its bounds
        // bind, or it compiles the primary instead (Compiler/Spec/Witnesses.md#emission).
        for var i: usize = 0; i < e->rows.size(); ++i {
            self._witness_row(e->rows[i])
        }

        // A panic result's elements are complete wherever it is named, even
        // where a declaration only names it (a header's `Panic<T, E...> f()`):
        // its tier-3 line asserts its size, and a C++ caller receives it by
        // value and reads its error (Compiler/Spec/Panic.md#the-c-view).
        var unsafe *en   = dyn_cast<Declarations::EnumDecl>(prim)
        var        whole = en != &null && en->adt_explicit_tags
        // A FUNCTION template is instantiated here at its arguments -- its
        // tier-3 line in the home TU, implicitly in any TU that sees the body
        // -- and a `<T: type>` body may do anything with T (`T::classof(p)`
        // in Casting's isa): each argument is complete, a pointer one at Fwd
        // as _admit_type has it. A record's argument is held as its
        // layout says.
        var fn_inst = isa<Declarations::FunctionDecl>(prim)
        for var i: usize = 0; i < e->args.size(); ++i {
            var n = if (whole || fn_inst) => (PlanNeed::Complete) else => need
            if !fn_inst && !self._arg_by_value(prim, i) {
                n = PlanNeed::Fwd
            }

            self._admit_type(e->args[i], n)
        }

        // Laid out by a partial specialization: what IT holds by value is what
        // the instance needs complete, read off its own parameters' bindings.
        if e->pattern != &null {
            var unsafe *part = CXXSpell::rep(e->pattern)
            for var i: usize = 0; i < e->pattern_args.size(); ++i {
                if self.param_by_value(part, i as u32) {
                    self._admit_type(e->pattern_args[i], need)
                }
            }
        }
    }

    /// Follow a type to the records it needs at the strength the SHAPE
    /// dictates: an indirection weakens to Fwd, the by-value spine keeps
    /// \p need.
    fn _admit_type(self, t: unsafe *Type, need: PlanNeed) {
        if t == &null {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                self._admit_type(cast<QualifiedType>(c)->inner, need)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = CXXSpell::rep(r->decl)
                // Naming `L<i32>::P` at all -- through a pointer too -- looks P
                // up inside L<i32>, which C++ must have instantiated.
                if r->outer != &null {
                    self._admit_type(r->outer, PlanNeed::Complete)
                }

                if d != &null && DeclFacts::decl_is_instance(d) {
                    self._admit(d, need) // _admit_instance handles the args.
                } else {
                    self._admit(d, need)
                    // `Outer::Inner` spelled anywhere -- behind a pointer or as an
                    // argument a template holds only by pointer (`FrozenList<
                    // ChainType::GenericArg>`) -- is a nested-name-specifier: C++
                    // needs Outer complete, whatever the layout needs of Inner.
                    if d != &null && d->semantic_dc != &null {
                        var unsafe *own = self._outermost_type(d)
                        if own != d {
                            self._admit(own, PlanNeed::Complete)
                        }
                    }

                    for var i: usize = 0; i < r->args.size(); ++i {
                        var n = need
                        if !self._arg_by_value(d, i) {
                            n = PlanNeed::Fwd
                        }

                        self._admit_type(*r->args.get(i), n)
                    }
                }
            } case TypeKind::PointerType {
                self._admit_type(cast<PointerType>(c)->pointee, PlanNeed::Fwd)
            } case TypeKind::CXXLValueRefType {
                self._admit_type(cast<CXXLValueRefType>(c)->referee, PlanNeed::Fwd)
            } case TypeKind::CXXRValueRefType {
                self._admit_type(cast<CXXRValueRefType>(c)->referee, PlanNeed::Fwd)
            }

            // `T?` is its record to C++ (NullableTypeLowering), held by value.
            case TypeKind::NullableType {
                self._admit_type(self._nullable_record(c), need)
            }

            // No Vector/Set/Map/Tuple arms: they are RecordTypes now and admit
            // through the record path, which already walks their generic
            // arguments (a tuple's elements are by value, so at \p need).
            case TypeKind::FixedArrayType {
                self._admit_type(cast<FixedArrayType>(c)->element, need)
                self._admit_type(cast<FixedArrayType>(c)->extent_param, PlanNeed::Fwd)
            }

            // A computed value (Compiler/Spec/Eval.md#value-nodes) names what C++ computes it from:
            // the eval fn it calls (consteval, so its body comes too), the eval
            // constant it reads (its definition comes too, visible_eval_vars),
            // a cast's type.
            case TypeKind::TypeExpr {
                var unsafe *v = cast<TypeExpr>(c)
                if !v->is_value || v->is_exact() {
                    return
                }

                // A string (Compiler/Spec/Eval.md#eval-classes): the string record is constructed right
                // in the argument, over `__kairo_estr<...>` or a named array.
                if v->vop == ValueOp::Str {
                    self.needs_eval_str = true
                    self._admit_type(v->vty, PlanNeed::Complete)
                    self.note_eval_str(v->vbytes, v->vmag as usize)
                    return
                }

                // Not an `eval for` binding: a local, declared where it stands.
                var local = v->vdecl != &null
                    && (v->vdecl->semantic_dc == &null || CXXSpell::in_function_scope(v->vdecl))
                if v->vdecl != &null && !local {
                    self._admit_use(v->vdecl)
                }

                if v->vty != &null {
                    self._admit_type(v->vty, PlanNeed::Fwd)
                }

                for var i: usize = 0; i < v->vops.size(); ++i {
                    self._admit_type(v->vops[i], PlanNeed::Fwd)
                }
            } case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(c)
                if !f->is_unprototyped {
                    self.needs_fn_value = true
                }

                for var i: usize = 0; i < f->params.size(); ++i {
                    self._admit_type(*f->params.get(i), PlanNeed::Fwd)
                }

                self._admit_type(f->return_type, PlanNeed::Fwd)
                self._admit_type(f->panic_result, PlanNeed::Complete) // its value returns this (Compiler/Spec/Panic.md#paniclowering).
            }

            // `T::Node` names the bound's witness (its member type) and T.
            case TypeKind::AssocType {
                var unsafe *a = cast<AssocType>(c)
                self._admit_type(a->base, PlanNeed::Fwd)
                for var i: usize = 0; i < a->args.size(); ++i {
                    self._admit_type(a->args[i], PlanNeed::Fwd)
                }

                var unsafe *ic = canon_unqual(a->iface)
                if ic != &null && isa<RecordType>(ic) {
                    self._admit(cast<RecordType>(ic)->decl, PlanNeed::Complete)
                }
            } case TypeKind::BuiltinType {
                // A builtin spelled as a Kairo declaration (`byte` -> Byte): an
                // opaque `enum class : unsigned char;` is already complete, so
                // any strength will do. f256 / f512 are classes whose members
                // C++ calls where Kairo sees a builtin operator (`a + b`), and
                // nothing else admits those: always the complete class.
                var unsafe *bt = cast<BuiltinType>(c)
                if bt->lang_decl != &null {
                    var bneed = need
                    if bt->builtin == BuiltinKind::F256 || bt->builtin == BuiltinKind::F512 {
                        bneed = PlanNeed::Complete
                    }

                    self._admit(bt->lang_decl, bneed)
                }
            } default { } // generic param, opaque: nothing to declare.
        }
    }

    /// # Closure

    fn _close(self) {
        while self._queue.size() > 0 {
            var at = self._queue[self._queue.size() - 1]
            self._queue.pop_back()
            self._expand(self._set[(at)], self._need[(at)])
        }
    }

    fn _expand(self, d: unsafe *Decl, need: PlanNeed) {
        if isa<Declarations::FunctionDecl>(d) {
            self._expand_fn(cast<Declarations::FunctionDecl>(d))
            return
        }

        // `extern T x;` only names T; the defining TU's own walk (visit_decl)
        // asks for Complete where the definition lays it out.
        if isa<Declarations::VariableDecl>(d) {
            self._admit_type(cast<Declarations::VariableDecl>(d)->type_, PlanNeed::Fwd)
            return
        }

        // A bounded record's head carries its concepts, and even its tier-0
        // forward declaration is a head: at any strength.
        self._witness_bounds(d)
        // So is a value parameter's class (Compiler/Spec/Eval.md#eval-classes): C++ needs it complete
        // at the forward declaration too (InterfaceEmitter::_vp_fwd_decls).
        var vgps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < vgps.size(); ++i {
            var unsafe *gp = vgps[i]
            if gp != &null
                && gp->is_const_param
                && gp->value_type != &null
                && self.value_param_record(d, &null) {
                self._admit_type(gp->value_type, PlanNeed::Complete)
            }
        }

        if need != PlanNeed::Complete {
            return
        }

        self._expand_type(d)
    }

    /// A declaration names its types, it does not lay them out.
    /// A declaration written with `= __kairo_default_f_x()` (InterfaceEmitter::
    /// _default_arg) makes clang build that call where the declaration sits, and
    /// a call needs the thunk's return type COMPLETE, whatever the shape of the
    /// parameter: a signature alone only names it. Function templates carry
    /// no C++ default (their friend line declares them first), so they add nothing.
    fn _admit_default_returns(self, n: unsafe *Declarations::FunctionDecl) {
        if CXXSpell::template_params(unsafe (n as unsafe *Decl)).size() > 0 {
            return
        }

        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null
                || p->is_self
                || p->is_pack
                || p->default_thunk == &null
                || !p->default_thunk_home {
                continue
            }

            self._admit_type(p->type_, PlanNeed::Complete)
        }
    }

    fn _expand_fn(self, n: unsafe *Declarations::FunctionDecl) {
        self._witness_bounds(unsafe (n as unsafe *Decl))
        self._admit_default_returns(n)
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null || p->is_self {
                continue
            }

            self._admit_type(
                (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                PlanNeed::Fwd,
            )
        }

        self._admit_type(n->return_type, PlanNeed::Fwd)
        self._admit_type(n->panic_result, PlanNeed::Fwd)
    }

    /// The whole definition (invariant 11): bases and by-value fields at
    /// Complete, the by-value types of method signatures at Complete too
    /// (_expand_member_sig), nested types recursively, and the same-file
    /// extension members that will be named as friends. An ADT is defined as
    /// its layout record (adt_record): its fields, role functions, nested tag
    /// enum and payload structs, and the friends written on it.
    fn _expand_type(self, d: unsafe *Decl) {
        // A value parameter's class (Compiler/Spec/Eval.md#eval-classes) is part of the template's head.
        var gps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp != &null && gp->is_const_param && gp->value_type != &null {
                self._admit_type(gp->value_type, PlanNeed::Complete)
            }
        }

        var unsafe *rec = self.adt_record(d)
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                self._bases(&n->derives_list)
                self._fields(&n->fields)
                self._methods(&n->methods)
            } case DeclKind::StructDecl {
                var unsafe *n = cast<Declarations::StructDecl>(rec)
                self._fields(&n->fields)
                self._methods(&n->methods)
            } case DeclKind::UnionDecl {
                var unsafe *n = cast<Declarations::UnionDecl>(rec)
                self._fields(&n->fields)
                self._methods(&n->methods)
            } case DeclKind::EnumDecl {
                // A plain enum, or an ADT whose record was never built.
                var unsafe *n = cast<Declarations::EnumDecl>(rec)
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var unsafe *v = *n->variants.get(i)
                    if v == &null {
                        continue
                    }

                    self._fields(&v->payload)
                }
            } case DeclKind::TypeAliasDecl {
                self._admit_type(
                    cast<Declarations::TypeAliasDecl>(rec)->aliased,
                    PlanNeed::Complete,
                )
            } default { }
        }

        // Nested types ride inside this definition. So do member aliases
        // (InterfaceEmitter writes them as `using`), and what one names is held
        // at Complete for the reason _expand_member_sig gives: whoever reads
        // `R::promise_type` -- <coroutine>'s traits, any C++ user -- gets the
        // type itself, not a declaration of it.
        var unsafe *dc = CXXSpell::dc_of(rec)
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *nd = *dc->dc_decls.get(i)
                if nd == &null {
                    continue
                }

                if isa<Declarations::TypeAliasDecl>(nd) {
                    self._admit_type(
                        cast<Declarations::TypeAliasDecl>(nd)->aliased,
                        PlanNeed::Complete,
                    )

                    continue
                }

                if !self._is_type_decl(nd) {
                    continue
                }

                // An anonymous union is not a nested type: it has no name and no
                // definition of its own, and its members were walked through its
                // field by _fields. Expanding it here would walk them twice.
                if isa<Declarations::UnionDecl>(nd)
                    && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                    continue
                }

                self._expand_type(CXXSpell::rep(nd))
            }
        }

        self._collect_same_file_extensions(rec)
        self._admit_friends(rec)
    }

    fn _bases(self, bases: *FrozenList<Declarations::InheritEdge>) {
        for var i: usize = 0; i < bases->size(); ++i {
            var unsafe *e = bases->get(i)
            if e == &null {
                continue
            }

            self._admit_type(e->base, PlanNeed::Complete)
        }
    }

    fn _fields(self, fields: *FrozenList<unsafe *Declarations::FieldDecl>) {
        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *f = *fields->get(i)
            if f == &null {
                continue
            }

            // The union is written inline as this field (`union { ... };`), so
            // what its members hold by value is this record's dependency, at the
            // same strength as an ordinary field's. Admitting the union type
            // itself would only land on the owner again (_outermost_type).
            if f->is_anonymous_union {
                self._fields(&self.anon_union_of(f)->fields)
                continue
            }

            self._admit_type(f->type_, PlanNeed::Complete)
        }
    }

    fn _methods(self, methods: *FrozenList<unsafe *Declarations::FunctionDecl>) {
        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = *methods->get(i)
            if m == &null {
                continue
            }

            self._expand_member_sig(m)
        }
    }

    /// A method of a record this TU holds COMPLETE: what its signature names by
    /// value is Complete too, shape-weakened as always (a pointer stays Fwd).
    ///
    /// A free function's declaration only names its types, and _expand_fn keeps
    /// them Fwd. A complete class is different: anything in this TU may call
    /// any of its members, and a call whose return or parameter is an incomplete
    /// class is ill-formed -- including calls Kairo never sees. clang's
    /// coroutine machinery calls `promise.initial_suspend()` on a YieldPromise<T>
    /// the plan only ever held at Complete for its layout, and Suspend, named in
    /// nothing but those signatures, stayed `class Suspend;` in every TU but its
    /// own. The body-less definition is all that is needed; no bodies follow.
    ///
    /// Strength only, never ORDER: _needs_complete reads bases and fields, so a
    /// method returning a type that returns this one is two definitions in
    /// either order, not a tier-1 cycle.
    fn _expand_member_sig(self, n: unsafe *Declarations::FunctionDecl) {
        self._witness_bounds(unsafe (n as unsafe *Decl)) // a bounded member template's head.
        self._admit_default_returns(n)
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null || p->is_self {
                continue
            }

            self._admit_type(
                (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                PlanNeed::Complete,
            )
        }

        self._admit_type(n->return_type, PlanNeed::Complete)
        self._admit_type(n->panic_result, PlanNeed::Complete)
    }

    /// Extensions targeting \p d written in d's OWN file: their scope is the
    /// definition's friend struct (Compiler/Spec/Generics.md#partial-selection), so it must be declared
    /// before it. Touched, not reached. Found by walking that file's program;
    /// an extension index lives in sema and codegen keeps no second one.
    fn _collect_same_file_extensions(self, d: unsafe *Decl) {
        var unsafe *tu = CXXSpell::tu_of(d)
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            self._collect_ext_in(item.as_decl(), d)
        }
    }

    fn _collect_ext_in(self, cand: unsafe *Decl, target: unsafe *Decl) {
        if cand == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(cand) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(cand)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._collect_ext_in(g->members[i], target)
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(cand) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(cand)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._collect_ext_in(g->body[i], target)
            }

            return
        }

        if isa<Declarations::ModuleDecl>(cand) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(cand) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                self._collect_ext_in(*dc->dc_decls.get(i), target)
            }

            return
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(cand)
        if x == &null {
            return
        }

        if self._ext_target(x) != target {
            return
        }

        if x->methods.size() == 0 {
            return
        }

        self._scope_for(x, self._mode == PlanMode::Preamble)
    }

    /// The layout decl an extension targets: the primary for a generic one.
    fn _ext_target(self, x: unsafe *Declarations::ExtensionDecl) -> unsafe *Decl {
        if x == &null || x->target == &null {
            return &null
        }

        var unsafe *c = x->target->canonical
        if c == &null || c->kind != TypeKind::RecordType {
            return &null
        }

        return self.layout_decl(cast<RecordType>(c)->decl)
    }

    /// What \p e's body reaches once its arguments are known (`outer<M>`
    /// calling `inner(Wrap<T>{...})`: `inner<Wrap<M>>`, `Wrap<M>`) is named in
    /// no tree, yet this TU compiles that body or links against it: hold each
    /// reached instance too, so tier 3 writes its explicit instantiation in its
    /// home and `extern template` everywhere else, and its witness rows are
    /// admitted with it -- an instance's rows are its own bounds', never its
    /// reach's (the discovery walk checks each instance once, Compiler/Spec/Generics.md#m1-enumeration).
    /// Callers run this once per instance, so a body that reaches itself
    /// stops. A function instance comes in as a call's does, its arguments
    /// Fwd. A record instance as a type naming it does (_admit: an interface's
    /// is its witness, an imported one clang's), Complete: its explicit
    /// instantiation lays it out.
    fn _admit_reached(self, e: unsafe *InstanceEntry) {
        var rs = cxx::std::vector<unsafe *InstanceEntry>()
        self._cg->instances->reached_of(e, unsafe &rs)
        for var i: usize = 0; i < rs.size(); ++i {
            var unsafe *r = rs[i]
            if isa<Declarations::FunctionDecl>(r->primary) {
                self._admit_instance(r, PlanNeed::Fwd)
            } else if r->decl != &null {
                self._admit(r->decl, PlanNeed::Complete)
            }
        }
    }

    /// # Layout queries (LayoutSpine + _admit_instance)

    /// The decl whose fields define a record's layout: an instance's pattern
    /// (its shell is empty until M2 fills it), and for an ADT enum its layout
    /// record (adt_record); the representative otherwise.
    fn layout_decl(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *r = CXXSpell::rep(d)
        if r != &null && DeclFacts::decl_is_instance(r) {
            // Laid out by the partial specialization the registry selected for
            // it, when one was: `Store<*i32>` has the partial's fields, not T's.
            var unsafe *e = self._cg->instances->entry_of(r)
            if e != &null && e->pattern != &null {
                r = CXXSpell::rep(e->pattern)
            } else {
                r = CXXSpell::rep(DeclFacts::decl_pattern(r))
            }
        }

        return self.adt_record(r)
    }

    /// The extension scope a record-targeted extension belongs to, keyed by
    /// TEMPLATE: the primary's layout decl for every form of it. One struct
    /// per name (ext_scope_name spells the primary), so `extend <> Store<bool>`
    /// and `extend <P> Store<*P>` join `extend <T> Store<T>`'s scope, each
    /// member over its own receiver, rather than three structs named alike.
    fn _scope_key(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *r = CXXSpell::rep(d)
        if r == &null {
            return &null
        }

        return self.adt_record(CXXSpell::rep(DeclFacts::decl_pattern(r)))
    }

    /// THE redirect from an ADT enum to the record it is written as
    /// (EnumDecl::adt_layout). Every walk that reads a record's members comes
    /// through here -- layout_decl, _expand_type, _needs_complete,
    /// _param_by_value_walk -- so no two of them can disagree about whether an
    /// ADT is its variants or its record. A plain enum, every other decl, and an
    /// ADT whose record was never built (sema stopped before the lowerings) are
    /// themselves.
    fn adt_record(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(d)
        if en == &null || !en->is_adt || en->adt_layout == &null {
            return d
        }

        return en->adt_layout
    }

    /// The anonymous union that field \p f (`is_anonymous_union`) declares. One
    /// resolver for every walk that sees through such a field -- the plan's,
    /// LayoutSpine's and InterfaceEmitter's -- so none of them can disagree on
    /// what the members are. A flag on a field whose type is anything else is a
    /// broken lowering, not a shape to tolerate.
    fn anon_union_of(self, f: unsafe *Declarations::FieldDecl) -> unsafe *Declarations::UnionDecl {
        var u: unsafe *Declarations::UnionDecl = &null
        if f->type_ != &null && f->type_->canonical != &null {
            var unsafe *c = canon_unqual(f->type_->canonical)
            if isa<RecordType>(c) {
                u = dyn_cast<Declarations::UnionDecl>(CXXSpell::rep(cast<RecordType>(c)->decl))
            }
        }

        if u == &null || !u->is_anonymous {
            self._ice(
                f->range,
                "EmitPlan: a field marked is_anonymous_union whose type is not an anonymous union",
            )
        }

        return u
    }

    /// True iff \p prim's layout reaches its \p idx-th generic parameter by
    /// value. `Box<T> { var v: T }` yes; `Box<T> { var p: *T }` no. Memoized.
    /// Recursion through another generic's field bottoms out at a depth cap
    /// and answers "by value", the safe direction (an over-strong edge can
    /// only trip the cycle assert, never miss a definition).
    /// param_by_value for argument \p i of an instance of \p prim, flat. An
    /// element of a pack-expanded variant's pack is held by value (a pack field
    /// is the pack itself), in the variant's `__kairo_pu` union, which the
    /// field walk does not see through: a header declaring a function that
    /// returns `Panic<T, E...>` needs every E complete (Compiler/Spec/Panic.md#the-c-view).
    fn _arg_by_value(self, prim: unsafe *Decl, i: usize) -> bool {
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(prim)
        if en != &null && en->is_adt {
            var p = DeclFacts::adt_pack_param(en)
            if p != usize::MAX && i >= p {
                return true
            }
        }

        return self.param_by_value(prim, i as u32)
    }

    fn param_by_value(self, prim: unsafe *Decl, idx_in: u32) -> bool {
        if prim == &null {
            return false
        }

        // An instance's arguments past a pack's position are the pack's
        // elements (InstanceEntry::args, flat): each is held as the pack is.
        var idx = idx_in
        var pgs = DeclFacts::decl_generic_params(prim)
        for var i: usize = 0; i < pgs.size(); ++i {
            if pgs[i] != &null && pgs[i]->is_pack && (idx as usize) > i {
                idx = (i as u32)
                break
            }
        }

        // One question per record: an ADT asked as its enum or as its layout
        // record is the same one, so it gets one memo key.
        var unsafe *p  = self.layout_decl(prim)
        var        key = (p as usize as u64) << 8 ^ (idx as u64)
        for var i: usize = 0; i < self._pbv_key.size(); ++i {
            if self._pbv_key[i] == key {
                return self._pbv_val[i] != 0
            }
        }

        if self._pbv_depth > 32 {
            return true
        }

        self._pbv_depth += 1
        var ans = self._param_by_value_walk(p, idx)
        self._pbv_depth -= 1
        self._pbv_key.push_back(key)
        self._pbv_val.push_back(ans as u8)
        return ans
    }

    /// An ADT's fields are its layout record's (adt_record). \p prim stays what
    /// a generic parameter's owner is compared against (_type_reaches_param).
    fn _param_by_value_walk(self, prim: unsafe *Decl, idx: u32) -> bool {
        var unsafe *rec = self.adt_record(prim)
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                if self._edges_reach_param(&n->derives_list, prim, idx) {
                    return true
                }

                return self._fields_reach_param(&n->fields, prim, idx)
            } case DeclKind::StructDecl {
                return self._fields_reach_param(
                    &cast<Declarations::StructDecl>(rec)->fields,
                    prim,
                    idx,
                )
            } case DeclKind::UnionDecl {
                return self._fields_reach_param(
                    &cast<Declarations::UnionDecl>(rec)->fields,
                    prim,
                    idx,
                )
            } case DeclKind::EnumDecl {
                var unsafe *n = cast<Declarations::EnumDecl>(rec)
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var unsafe *v = *n->variants.get(i)
                    if v != &null && self._fields_reach_param(&v->payload, prim, idx) {
                        return true
                    }
                }

                return false
            } default {
                return false
            }
        }
    }

    fn _edges_reach_param(self,
                          list: *FrozenList<Declarations::InheritEdge>,
                          prim: unsafe *Decl,
                          idx:  u32) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *e = list->get(i)
            if e != &null && self._type_reaches_param(e->base, prim, idx) {
                return true
            }
        }

        return false
    }

    fn _fields_reach_param(self,
                           list: *FrozenList<unsafe *Declarations::FieldDecl>,
                           prim: unsafe *Decl,
                           idx:  u32) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *f = *list->get(i)
            if f == &null {
                continue
            }

            // An anonymous union's members are stored in the record by value.
            if f->is_anonymous_union {
                if self._fields_reach_param(&self.anon_union_of(f)->fields, prim, idx) {
                    return true
                }

                continue
            }

            if self._type_reaches_param(f->type_, prim, idx) {
                return true
            }
        }

        return false
    }

    fn _type_reaches_param(self, t: unsafe *Type, prim: unsafe *Decl, idx: u32) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                return self._type_reaches_param(cast<QualifiedType>(c)->inner, prim, idx)
            } case TypeKind::NullableType {
                return self._type_reaches_param(cast<NullableType>(c)->lowered, prim, idx)
            } case TypeKind::GenericParamType {
                var unsafe *g = cast<GenericParamType>(c)
                // Both through layout_decl: walking an ADT's record, \p prim is
                // that record while T's owner is the enum.
                return self.layout_decl(g->owner) == self.layout_decl(prim) && g->param_index == idx
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = self.layout_decl(r->decl)
                // A payload struct is laid out inside its ADT (LayoutSpine::reaches).
                var unsafe *ps = dyn_cast<Declarations::StructDecl>(d)
                if ps != &null && ps->is_adt_payload {
                    return self._fields_reach_param(&ps->fields, prim, idx)
                }

                for var i: usize = 0; i < r->args.size(); ++i {
                    if !self.param_by_value(d, i as u32) {
                        continue
                    }

                    if self._type_reaches_param(*r->args.get(i), prim, idx) {
                        return true
                    }
                }

                return false
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    if self._type_reaches_param(*tp->elements.get(i), prim, idx) {
                        return true
                    }
                }

                return false
            } case TypeKind::FixedArrayType {
                return self._type_reaches_param(cast<FixedArrayType>(c)->element, prim, idx)
            } default {
                return false
            }
        }
    }

    /// # Ordering

    fn _order(self) {
        self._early()
        // Tier 0: forward declarations. Namespace-scope types only; a nested
        // type cannot be forward-declared outside its owner.
        var t0: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if !self._is_type_decl(d) {
                continue
            }

            t0.push_back(self._entry(d, PlanNeed::Fwd, PlanTier::FwdDecls))
        }

        // The closure is done: _scopes no longer grows, so entries may point in.
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var e = self._entry(self._scopes[i].anchor, PlanNeed::Fwd, PlanTier::FwdDecls)
            e.scope = unsafe &self._scopes[i]
            t0.push_back(e)
        }

        // A witness primary is declared up front, so a specialization or a
        // body can name it in any order tier 1 settles on.
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].row != &null {
                continue
            }

            var e = self._entry(self._witnesses[i].iface, PlanNeed::Fwd, PlanTier::FwdDecls)
            e.witness = unsafe &self._witnesses[i]
            e.own     = true // written wherever it is needed; one text everywhere (§7b.6).
            t0.push_back(e)
        }

        self._sort(&t0)
        self._specs_after_primary(&t0)
        // Three runs: every forward declaration whose head names no concept,
        // then the concepts (a requires-parameter needs its type declared, not
        // complete; a base's concept first), then the bounded records' forward
        // declarations, whose heads name them (Compiler/Spec/Witnesses.md#the-concept).
        var bounded = cxx::std::vector<PlanEntry>()
        for var i: usize = 0; i < t0.size(); ++i {
            var *e = &t0[i]
            if e->witness == &null
                && e->scope == &null
                && self._spell.requires_clause(e->decl).size() > 0 {
                bounded.push_back(t0[i])
                continue
            }

            self.entries.push_back(t0[i])
        }

        var cs = cxx::std::vector<PlanEntry>()
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].row != &null {
                continue
            }

            var e = self._entry(self._witnesses[i].iface, PlanNeed::Fwd, PlanTier::FwdDecls)
            e.witness    = unsafe &self._witnesses[i]
            e.is_concept = true
            e.own        = true
            cs.push_back(e)
        }

        self._sort(&cs)
        self._toposort(&cs)
        for var i: usize = 0; i < cs.size(); ++i {
            self.entries.push_back(cs[i])
        }

        for var i: usize = 0; i < bounded.size(); ++i {
            self.entries.push_back(bounded[i])
        }

        // Last, the std::hash adapters' classes (WitnessPiece::std_hash): each
        // names its K, now declared, and every record definition below may
        // instantiate it through a container's hasher.
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if !self._witnesses[i].std_hash {
                continue
            }

            var e = self._entry(self._witnesses[i].iface, PlanNeed::Fwd, PlanTier::FwdDecls)
            e.witness = unsafe &self._witnesses[i]
            e.own     = true
            self.entries.push_back(e)
        }

        // Tier 1: definitions, toposorted on Complete edges.
        var t1: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if !self._is_type_decl(d) {
                continue
            }

            if self._need[i] != PlanNeed::Complete {
                continue
            }

            t1.push_back(self._entry(d, PlanNeed::Complete, PlanTier::Definitions))
        }

        // Every scope a preamble touches is defined (its members' out-of-line
        // definitions and every call need the class); a header defines the ones
        // its roots reach and only declares the rest.
        for var i: usize = 0; i < self._scopes.size(); ++i {
            if self._mode != PlanMode::Preamble && !self._scopes[i].reachable {
                continue
            }

            var e = self._entry(self._scopes[i].anchor, PlanNeed::Complete, PlanTier::Definitions)
            e.scope = unsafe &self._scopes[i]
            t1.push_back(e)
        }

        for var i: usize = 0; i < self._witnesses.size(); ++i {
            var e = self._entry(self._witnesses[i].iface, PlanNeed::Complete, PlanTier::Definitions)
            e.witness = unsafe &self._witnesses[i]
            e.own     = true
            t1.push_back(e)
        }

        // The early items (Compiler/Spec/Eval.md#value-nodes), each where its edges put it: after the
        // records its definition needs complete, before the records whose
        // types evaluate it.
        for var i: usize = 0; i < self.early.size(); ++i {
            var e = self._entry(self.early[i], PlanNeed::Complete, PlanTier::Definitions)
            e.eval_item = self.early[i]
            t1.push_back(e)
        }

        self._sort(&t1)
        self._toposort(&t1)
        for var i: usize = 0; i < t1.size(); ++i {
            self.entries.push_back(t1[i])
        }

        // Tier 2: functions and globals. Extension members are declared by
        // their scope's definition and never listed here.
        var t2: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if d->kind != DeclKind::FunctionDecl && d->kind != DeclKind::VariableDecl {
                continue
            }

            t2.push_back(self._entry(d, PlanNeed::Fwd, PlanTier::Functions))
        }

        self._sort(&t2)
        for var i: usize = 0; i < t2.size(); ++i {
            self.entries.push_back(t2[i])
        }

        // Tier 3: instantiations. Home = the entry's home_fid; in header mode
        // only instances homed inside this file's own root are listed, as
        // `extern`, because the header ships with that root's objects.
        var t3: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._insts.size(); ++i {
            var unsafe *ie   = self._insts[i]
            var unsafe *prim = CXXSpell::rep(ie->primary)
            var        e     = self._entry(prim, PlanNeed::Complete, PlanTier::Instantiations)
            // The codegen home (assign_homes), graph-independent; home_fid
            // when the driver set none.
            var hf = EmitPlan::home_of(ie)
            e.inst    = ie
            e.is_home = hf == self._home
            if self._mode == PlanMode::Header {
                if !self._same_root(hf, self._home) {
                    continue
                }

                e.is_home = false
            }

            // Tie-break on the instance's home, so two TUs list one
            // instance in the same relative order.
            e.fid = hf
            e.own = e.fid == self._home // own was computed from the primary's fid, before the override.
            t3.push_back(e)
        }

        self._sort(&t3)
        // Two Kairo instances can be one C++ entity: `usize` is its own type to
        // Kairo, but on Linux size_t IS `unsigned long`, so `Box<usize>` beside
        // `Box<u64>` (or `Panic<i32, usize>` beside `Panic<i32, u64>`) would be
        // `template struct Box<unsigned long>;` twice, clang's "duplicate
        // explicit instantiation". Key each instance by its arguments
        // spelled with usize / isize folded to what the target says they are
        // (CXXSpell::size_fold), and list one per key: the home
        // one when either is, since a definition after an `extern template`
        // is fine and the reverse is not.
        var keys   = cxx::std::vector<string>()
        var folded = cxx::std::vector<u8>()
        var drop   = cxx::std::vector<u8>()
        for var i: usize = 0; i < t3.size(); ++i {
            // An instance over a value C++ computes writes no line at all
            // (InterfaceEmitter::_instantiation); nothing to collide.
            var computed = false
            var *ia      = &t3[i].inst->args
            for var k: usize = 0; k < ia->size(); ++k {
                var unsafe *v = dyn_cast<TypeExpr>((*ia)[k])
                if v != &null && v->is_value && !v->is_exact() {
                    computed = true
                    break
                }
            }

            if computed {
                keys.push_back("")
                folded.push_back(0)
                drop.push_back(0)
                continue
            }

            self._spell.fold_sizes   = true
            self._spell.sizes_folded = 0
            keys.push_back(self._spell.args_str(t3[i].inst->args))
            folded.push_back((self._spell.sizes_folded > 0) as u8)
            self._spell.fold_sizes = false
            drop.push_back(0)
        }

        // A pair with a folded side is checked as above. Two instances one
        // C++ entity with no folded side (`*T` and
        // `unsafe *T` spell alike) share a home (assign_homes), so both are
        // home or neither: two homes write the instantiation twice
        // (CL001E), so the second goes; two `extern template`s are legal and
        // stay as they were.
        for var i: usize = 0; i < t3.size(); ++i {
            if drop[i] != 0 {
                continue
            }

            if folded[i] == 0 && !t3[i].is_home {
                continue
            }

            for var j: usize = 0; j < t3.size(); ++j {
                if j == i || drop[j] != 0 || t3[j].decl != t3[i].decl || keys[j] != keys[i] {
                    continue
                }

                if folded[i] == 0 && folded[j] == 0 && !t3[j].is_home {
                    continue
                }

                var keep_i = t3[i].is_home && !t3[j].is_home
                    || t3[i].is_home == t3[j].is_home && i < j
                if keep_i {
                    drop[j] = 1
                    continue
                }

                drop[i] = 1
                break
            }
        }

        for var i: usize = 0; i < t3.size(); ++i {
            if drop[i] == 0 {
                self.entries.push_back(t3[i])
            }
        }
    }

    fn _same_root(self, a: u32, b: u32) -> bool {
        var unsafe *sm  = self._cg->ctx->sm
        var unsafe *res = self._cg->ctx->resolver
        if sm == &null || res == &null {
            return a == b
        }

        return res->root_for_dir(sm->get_file_dir(a)) == res->root_for_dir(sm->get_file_dir(b))
    }

    fn _same_ns_vec(self,
                    const a: cxx::std::vector<string>,
                    const b: cxx::std::vector<string>) -> bool {
        if a.size() != b.size() {
            return false
        }

        for var i: usize = 0; i < a.size(); ++i {
            if (a)[i] != (b)[i] {
                return false
            }
        }

        return true
    }

    fn _entry(self, d: unsafe *Decl, need: PlanNeed, tier: PlanTier) -> PlanEntry {
        var e = PlanEntry()
        e.decl = d
        e.need = need
        e.tier = tier
        e.fid  = CXXSpell::fid_of(d)
        e.off  = self._off_of(d)
        e.own  = e.fid == self._home
        // A tuple record (TupleRecords) is minted from no file and sits in no
        // module's header: it is OWN everywhere, so a header defines it (under
        // InterfaceEmitter's guard) instead of including the builtin root's,
        // which never declares it.
        var unsafe *ts = dyn_cast<Declarations::StructDecl>(d)
        if ts != &null && ts->tuple_arity > 0 {
            e.own = true
        }

        return e
    }

    /// (file rank, offset) ascending. Insertion sort: tens of entries, stable.
    fn _sort(self, @inout v: cxx::std::vector<PlanEntry>) {
        for var i: usize = 1; i < v.size(); ++i {
            var j = i
            while j > 0 {
                var *a   = &(v)[j - 1]
                var *b   = &(v)[j]
                var swap = false
                // By the file's rank (set_file_ranks), not its fid: the
                // order is then the same in every graph that holds the TU.
                var ra = self._rank_of(a->fid)
                var rb = self._rank_of(b->fid)
                if ra > rb {
                    swap = true
                } else if ra == rb && a->off > b->off {
                    swap = true
                }

                if !swap {
                    break
                }

                var tmp = (v)[j - 1]
                (v)[j - 1] = (v)[j]
                (v)[j]     = tmp
                j -= 1
            }
        }
    }

    /// Stable topological sort on Complete edges. Nothing takeable means a
    /// by-value cycle sema should have rejected (TypeCycleCheck): assert.
    ///
    /// Each round takes the LOWEST-index entry none of whose untaken entries it
    /// needs. The edges are asked once each (n^2 _entry_needs calls, each a walk
    /// of a record's fields and methods) into a matrix, and a per-entry count of
    /// untaken needs replaces the rescan: asking them per round was n^3 calls,
    /// the single biggest cost of codegen's serial pre-pass on a large graph.
    /// Same picks in the same order as the rescanning form.
    fn _toposort(self, @inout v: cxx::std::vector<PlanEntry>) {
        var n = v.size()
        if n < 2 {
            return
        }

        var out:   cxx::std::vector<PlanEntry>
        var taken: cxx::std::vector<u8>
        // needs[i * n + j]: entry i must follow entry j. pending[i]: how many
        // untaken j entry i still needs.
        var needs:   cxx::std::vector<u8>
        var pending: cxx::std::vector<usize>
        needs.resize(n * n, 0 as u8)
        for var i: usize = 0; i < n; ++i {
            taken.push_back(0)
            var c: usize = 0
            for var j: usize = 0; j < n; ++j {
                if j == i {
                    continue
                }

                if self._entry_needs(unsafe &(v)[i], unsafe &(v)[j]) {
                    needs[i * n + j] = (1)
                    c += 1
                }
            }

            pending.push_back(c)
        }

        for var round: usize = 0; round < n; ++round {
            var picked = usize::MAX
            for var i: usize = 0; i < n; ++i {
                if taken[i] == 0 && pending[i] == 0 {
                    picked = i
                    break
                }
            }

            if picked == usize::MAX {
                // A cycle through an early item (Compiler/Spec/Eval.md#value-nodes) is EvalUsageChecking's
                // to report; one of records alone, TypeCycleCheck's.
                for var i: usize = 0; i < n; ++i {
                    if taken[i] == 0 && (v)[i].eval_item != &null {
                        self._ice(
                            (v)[i].decl->range,
                            "EmitPlan: no order defines the eval items a declaration's type computes from ahead of it; EvalUsageChecking::_check_order should have reported the cycle",
                        )
                    }
                }
            }

            eval if defined!(DEBUG) {
                if !(picked != usize::MAX) {
                    kairo::std::ice_fail(
                        r"EmitPlan: Complete-edge cycle in tier 1; TypeCycleCheck should have rejected this in sema",
                    )
                }
            }

            taken[picked] = 1
            out.push_back((v)[picked])
            for var i: usize = 0; i < n; ++i {
                if taken[i] == 0 && needs[i * n + picked] != (0 as u8) {
                    pending[i] -= 1
                }
            }
        }

        for var i: usize = 0; i < n; ++i {
            (v)[i] = out[i]
        }
    }

    /// True when entry \p who must follow entry \p dep. A scope follows its
    /// deps; nothing waits on a scope (a friend line needs only tier 0).
    fn _entry_needs(self, who: unsafe *PlanEntry, dep: unsafe *PlanEntry) -> bool {
        if who->eval_item != &null || dep->eval_item != &null {
            if who->witness != &null
                || who->scope != &null
                || dep->witness != &null
                || dep->scope != &null {
                return false
            }

            return self._eo_has(who->decl, dep->decl)
        }

        if who->witness != &null {
            var unsafe *w = who->witness
            if dep->witness != &null {
                // A std::hash adapter's operator calls its row's specialization.
                if w->std_hash && !dep->witness->std_hash && dep->witness->row == w->row {
                    return true
                }

                if dep->witness->row != &null { // nothing waits on a specialization.
                    return false
                }

                for var i: usize = 0; i < w->after.size(); ++i {
                    if w->after[i] == dep->witness->iface {
                        return true
                    }
                }

                return false
            }

            if dep->scope != &null {
                for var i: usize = 0; i < w->scopes.size(); ++i {
                    var unsafe *sp = unsafe &self._scopes[w->scopes[i]]
                    if sp == dep->scope {
                        return true
                    }
                }

                return false
            }

            for var i: usize = 0; i < w->deps.size(); ++i {
                if w->deps[i] == dep->decl {
                    return true
                }
            }

            return false
        }

        if dep->witness != &null {
            return false
        }

        if dep->scope != &null {
            return false
        }

        if who->scope != &null {
            for var i: usize = 0; i < who->scope->deps.size(); ++i {
                if who->scope->deps[i] == dep->decl {
                    return true
                }
            }

            return false
        }

        // A specialization's definition follows its primary's: a partial
        // whose pattern instantiates the primary (`Store<Store<P>*>`) needs it
        // defined, and keeping the pair in order costs nothing otherwise.
        if CXXSpell::is_record_spec(who->decl)
            && CXXSpell::rep(DeclFacts::decl_instantiated_from(who->decl)) == dep->decl {
            return true
        }

        return self._needs_complete(who->decl, dep->decl)
    }

    /// Tier 0 is (fid, offset) order, which puts a specialization written
    /// above its primary, or in a file sorting before the primary's, ahead of
    /// the primary's declaration: C++ rejects a specialization of an
    /// undeclared template. Each such entry moves to just after its primary;
    /// everything else keeps its place.
    fn _specs_after_primary(self, @inout v: cxx::std::vector<PlanEntry>) {
        var moved        = true
        var guard: usize = 0
        while moved && guard < v.size() + 1 {
            moved = false
            guard += 1
            for var i: usize = 0; i < v.size(); ++i {
                var unsafe *d = (v)[i].decl
                if (v)[i].scope != &null
                    || (v)[i].witness != &null
                    || !CXXSpell::is_record_spec(d) {
                    continue
                }

                var unsafe *prim = CXXSpell::rep(DeclFacts::decl_instantiated_from(d))
                var        at    = usize::MAX
                for var j: usize = i + 1; j < v.size(); ++j {
                    if (v)[j].scope == &null && (v)[j].witness == &null && (v)[j].decl == prim {
                        at = j
                        break
                    }
                }

                if at == usize::MAX {
                    continue
                }

                var e = (v)[i]
                for var j: usize = i; j < at; ++j {
                    (v)[j] = (v)[j + 1]
                }

                (v)[at] = e
                moved   = true
                break
            }
        }
    }

    /// True when \p who's definition requires \p dep's definition first. An
    /// ADT's definition is its layout record's (adt_record); LayoutSpine sees
    /// through its anonymous union and payload structs.
    fn _needs_complete(self, who: unsafe *Decl, dep: unsafe *Decl) -> bool {
        if who == &null || dep == &null {
            return false
        }

        // Asked for every pair of tier-1 entries: the answer for one
        // `who` is two sets built by one walk (_need_row), so a pair is a lookup.
        var *r = &self._need_rows[self._need_row(who)]
        if r->direct.contains(dep as usize as u64) {
            return true
        }

        return r->layout.contains(self.layout_decl(dep) as usize as u64)
    }

    /// What `who`'s definition needs complete before it, for every dep at once:
    /// - direct: a value parameter of class type (`<eval C: Config>`, Compiler/Spec/Eval.md
    ///   7e) -- C++ needs the class complete wherever the template is declared
    ///   -- and every class whose value-parameter template `who` names at all,
    ///   through a pointer too (its forward declaration follows the class),
    ///   or whose nested type it names.
    /// - layout: what `who` holds by value (LayoutSpine): its bases, fields
    ///   and C++ default arguments, an ADT's payloads.
    /// A record nested in `who` is defined INSIDE its body (`struct Entry` in
    /// a class), so what it needs orders `who` exactly as `who`'s own fields
    /// do; an Entry reached only through a template argument (`vector<Entry>`)
    /// or not at all would otherwise leave the outer record ahead of a field
    /// type it needs complete. Its row is folded in.
    fn _need_row(self, who: unsafe *Decl) -> usize {
        var key = (who as usize as u64)
        var hit = self._need_memo.find(key)
        if hit != self._need_memo.end() {
            return hit->second as usize
        }

        var row = NeedRow()
        var gps = DeclFacts::decl_generic_params(who)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null
                || !gp->is_const_param
                || gp->value_type == &null
                || gp->value_type->canonical == &null {
                continue
            }

            var unsafe *c = canon_unqual(gp->value_type->canonical)
            if !isa<RecordType>(c) {
                continue
            }

            row.direct.insert(CXXSpell::rep(cast<RecordType>(c)->decl) as usize as u64)
        }

        {
            var vr  = self._vp_row(who)
            var *vn = &self._vp_rows[vr]
            for var it = vn->vp.begin(); it != vn->vp.end(); ++it {
                row.direct.insert(*it)
            }

            for var it = vn->nest.begin(); it != vn->nest.end(); ++it {
                row.direct.insert(*it)
            }
        }

        var unsafe *rec = self.adt_record(who)
        var unsafe *ndc = CXXSpell::dc_of(rec)
        if ndc != &null {
            for var i: usize = 0; i < ndc->dc_decls.size(); ++i {
                var unsafe *nd = *ndc->dc_decls.get(i)
                if nd == &null || !self._is_type_decl(nd) {
                    continue
                }

                if isa<Declarations::UnionDecl>(nd)
                    && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                    continue
                }

                var unsafe *nr = CXXSpell::rep(nd)
                if nr == who {
                    continue
                }

                var ni  = self._need_row(nr)   // may grow _need_rows: index, not pointer.
                var *nn = &self._need_rows[ni]
                for var it = nn->direct.begin(); it != nn->direct.end(); ++it {
                    row.direct.insert(*it)
                }

                for var it = nn->layout.begin(); it != nn->layout.end(); ++it {
                    row.layout.insert(*it)
                }
            }
        }

        var probe = LayoutSpine(&self, who)
        probe.collect = unsafe &row.layout
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                probe.bases(&n->derives_list)
                probe.fields(unsafe &n->fields)
                probe.defaults(&n->methods)
            } case DeclKind::StructDecl {
                var unsafe *sn = cast<Declarations::StructDecl>(rec)
                probe.fields(unsafe &sn->fields)
                probe.defaults(&sn->methods)
            } case DeclKind::UnionDecl {
                probe.fields(unsafe &cast<Declarations::UnionDecl>(rec)->fields)
            } case DeclKind::EnumDecl {
                var unsafe *n = cast<Declarations::EnumDecl>(rec)
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var unsafe *vr = *n->variants.get(i)
                    if vr != &null {
                        probe.fields(unsafe &vr->payload)
                    }
                }
            } default { }
        }

        var at = self._need_rows.size()
        self._need_rows.push_back(row)
        self._need_memo.try_emplace(key, at as u64)
        return at
    }

    /// # Predicates

    /// \p who has a generic value parameter whose type is a record (Compiler/Spec/Eval.md
    /// 7e): \p dep that record, or with \p dep null, any. C++ needs that class
    /// complete at every declaration of the template, its forward one included.
    fn value_param_record(self, who: unsafe *Decl, dep: unsafe *Decl) -> bool {
        if who == &null {
            return false
        }

        var gps = DeclFacts::decl_generic_params(who)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null
                || !gp->is_const_param
                || gp->value_type == &null
                || gp->value_type->canonical == &null {
                continue
            }

            var unsafe *c = canon_unqual(gp->value_type->canonical)
            if !isa<RecordType>(c) {
                continue
            }

            if dep == &null {
                return true
            }

            if CXXSpell::rep(cast<RecordType>(c)->decl) == dep {
                return true
            }
        }

        return false
    }

    /// \p who's definition names a template over a value parameter of class
    /// \p dep (value_param_record), in any position -- a field's type through
    /// pointers and arguments, a base, a method signature. That template is
    /// declared only once \p dep is complete (InterfaceEmitter::_vp_fwd_decls),
    /// so \p who's definition follows \p dep's even where its layout does not.
    fn _names_vp_template(self, who: unsafe *Decl, dep: unsafe *Decl, nested: bool) -> bool {
        if who == &null || dep == &null {
            return false
        }

        var unsafe *r = unsafe &self._vp_rows[self._vp_row(who)]
        if nested {
            return r->nest.contains(dep as usize as u64)
        }

        return r->vp.contains(dep as usize as u64)
    }

    /// \p who's VpNames, walked once: the same positions _type_names_vp
    /// searched for one dep -- bases, fields, method returns and non-self
    /// parameters, through the same type shapes and depth limit -- collecting
    /// every dep it would have answered true for.
    fn _vp_row(self, who: unsafe *Decl) -> usize {
        var key = (who as usize as u64)
        var hit = self._vp_memo.find(key)
        if hit != self._vp_memo.end() {
            return hit->second as usize
        }

        var row = VpNames()
        var unsafe *rec = self.adt_record(who)
        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                for var i: usize = 0; i < n->derives_list.size(); ++i {
                    var unsafe *e = n->derives_list.get(i)
                    if e != &null {
                        self._vp_collect(e->base, 0, &row)
                    }
                }

                fields  = unsafe &n->fields
                methods = unsafe &n->methods
            } case DeclKind::StructDecl {
                fields  = unsafe &cast<Declarations::StructDecl>(rec)->fields
                methods = unsafe &cast<Declarations::StructDecl>(rec)->methods
            } case DeclKind::UnionDecl {
                fields  = unsafe &cast<Declarations::UnionDecl>(rec)->fields
                methods = unsafe &cast<Declarations::UnionDecl>(rec)->methods
            } default { }
        }

        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var unsafe *f = *fields->get(i)
                if f != &null {
                    self._vp_collect(f->type_, 0, &row)
                }
            }

            for var i: usize = 0; i < methods->size(); ++i {
                var unsafe *m = *methods->get(i)
                if m == &null {
                    continue
                }

                self._vp_collect(m->return_type, 0, &row)
                for var j: usize = 0; j < m->params.size(); ++j {
                    var unsafe *p = *m->params.get(j)
                    if p != &null && !p->is_self {
                        self._vp_collect(p->type_, 0, &row)
                    }
                }
            }
        }

        var at = self._vp_rows.size()
        self._vp_rows.push_back(row)
        self._vp_memo.try_emplace(key, at as u64)
        return at
    }

    fn _vp_collect(self, t: unsafe *Type, depth: u32, row: *VpNames) {
        if t == &null || depth > (16 as u32) {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        var d1 = depth + (1 as u32)
        match c->kind {
            case TypeKind::QualifiedType {
                self._vp_collect(cast<QualifiedType>(c)->inner, d1, row)
            } case TypeKind::PointerType {
                self._vp_collect(cast<PointerType>(c)->pointee, d1, row)
            } case TypeKind::CXXLValueRefType {
                self._vp_collect(cast<CXXLValueRefType>(c)->referee, d1, row)
            } case TypeKind::CXXRValueRefType {
                self._vp_collect(cast<CXXRValueRefType>(c)->referee, d1, row)
            } case TypeKind::NullableType {
                self._vp_collect(cast<NullableType>(c)->lowered, d1, row)
            } case TypeKind::FixedArrayType {
                self._vp_collect(cast<FixedArrayType>(c)->element, d1, row)
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self._vp_collect(*tp->elements.get(i), d1, row)
                }
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    self._vp_collect(*fp->params.get(i), d1, row)
                }

                self._vp_collect(fp->return_type, d1, row)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = CXXSpell::rep(r->decl)
                if d != &null {
                    // value_param_record(rep(pattern), dep) for any dep: the
                    // record-typed value parameters of the named template.
                    var unsafe *pat = CXXSpell::rep(DeclFacts::decl_pattern(d))
                    if pat != &null {
                        var gps = DeclFacts::decl_generic_params(pat)
                        for var i: usize = 0; i < gps.size(); ++i {
                            var unsafe *gp = gps[i]
                            if gp == &null
                                || !gp->is_const_param
                                || gp->value_type == &null
                                || gp->value_type->canonical == &null {
                                continue
                            }

                            var unsafe *vc = canon_unqual(gp->value_type->canonical)
                            if !isa<RecordType>(vc) {
                                continue
                            }

                            row->vp.insert(
                                CXXSpell::rep(cast<RecordType>(vc)->decl) as usize as u64,
                            )
                        }
                    }

                    // A nested type's outermost owner (d != dep there, so only
                    // an owner that is not d itself).
                    var unsafe *o = self._outermost_type(d)
                    if o != d {
                        row->nest.insert(o as usize as u64)
                    }
                }

                for var i: usize = 0; i < r->args.size(); ++i {
                    self._vp_collect(*r->args.get(i), d1, row)
                }
            } default { }
        }
    }

    fn _type_names_vp(self, t: unsafe *Type, dep: unsafe *Decl, depth: u32, nested: bool) -> bool {
        if t == &null || depth > (16 as u32) {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        var d1 = depth + (1 as u32)
        match c->kind {
            case TypeKind::QualifiedType {
                return self._type_names_vp(cast<QualifiedType>(c)->inner, dep, d1, nested)
            } case TypeKind::PointerType {
                return self._type_names_vp(cast<PointerType>(c)->pointee, dep, d1, nested)
            } case TypeKind::CXXLValueRefType {
                return self._type_names_vp(cast<CXXLValueRefType>(c)->referee, dep, d1, nested)
            } case TypeKind::CXXRValueRefType {
                return self._type_names_vp(cast<CXXRValueRefType>(c)->referee, dep, d1, nested)
            } case TypeKind::NullableType {
                return self._type_names_vp(cast<NullableType>(c)->lowered, dep, d1, nested)
            } case TypeKind::FixedArrayType {
                return self._type_names_vp(cast<FixedArrayType>(c)->element, dep, d1, nested)
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    if self._type_names_vp(*tp->elements.get(i), dep, d1, nested) {
                        return true
                    }
                }

                return false
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    if self._type_names_vp(*fp->params.get(i), dep, d1, nested) {
                        return true
                    }
                }

                return self._type_names_vp(fp->return_type, dep, d1, nested)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = CXXSpell::rep(r->decl)
                if d != &null
                    && !nested
                    && self.value_param_record(CXXSpell::rep(DeclFacts::decl_pattern(d)), dep) {
                    return true
                }

                // `ClosureExpr::Capture`: a nested type is spelled through
                // its owner, which C++ needs complete at the declaration.
                if d != &null && nested && d != dep && self._outermost_type(d) == dep {
                    return true
                }

                for var i: usize = 0; i < r->args.size(); ++i {
                    if self._type_names_vp(*r->args.get(i), dep, d1, nested) {
                        return true
                    }
                }

                return false
            } default {
                return false
            }
        }
    }

    /// \p d is a member of a generic record (its own generic params aside).
    fn _member_of_template(self, d: unsafe *Decl) -> bool {
        if d == &null || !isa<Declarations::FunctionDecl>(d) || d->semantic_dc == &null {
            return false
        }

        var unsafe *dc = d->semantic_dc
        if !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return false
        }

        var unsafe *owner = dc->owner_decl()
        return owner != &null && DeclFacts::decl_generic_params(owner).size() > 0
    }

    /// \p d is declared in an interface: a requirement, never a C++ function.
    fn _is_requirement(self, d: unsafe *Decl) -> bool {
        if d == &null || !isa<Declarations::FunctionDecl>(d) || d->semantic_dc == &null {
            return false
        }

        var unsafe *home = (d->semantic_dc)->owner_decl()
        return home != &null && isa<Declarations::InterfaceDecl>(home)
    }

    fn _plannable(self, d: unsafe *Decl) -> bool {
        return self._is_type_decl(d) || d->kind == DeclKind::FunctionDecl || self._is_global_var(d)
    }

    /// A variable with namespace scope: its home is the TU or a module. Every
    /// local reaches _admit too (_admit_use on each NamedIdentExpr) and must
    /// stay out; a static data member never gets here (_member_owner
    /// redirects it to its owner). Same predicate as EmitIR::_is_local.
    fn _is_global_var(self, d: unsafe *Decl) -> bool {
        if d->kind != DeclKind::VariableDecl {
            return false
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return false
        }

        return dc->dc_kind == DeclContextKind::TranslationUnit
            || dc->dc_kind == DeclContextKind::Module
    }

    /// The kinds with a C++ type. Interfaces are excluded on purpose.
    fn _is_type_decl(self, d: unsafe *Decl) -> bool {
        return d->kind == DeclKind::ClassDecl
            || d->kind == DeclKind::StructDecl
            || d->kind == DeclKind::UnionDecl
            || d->kind == DeclKind::EnumDecl
    }

    fn _outermost_type(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *cur = d
        var unsafe *dc  = d->semantic_dc
        while dc != &null && dc->is_type_scope() && dc->dc_kind != DeclContextKind::Extension {
            cur = CXXSpell::rep(dc->dc_owner)
            dc  = dc->dc_parent
        }

        return cur
    }

    fn _index_of(self, d: unsafe *Decl) -> usize {
        var it = self._set_at.find(d as usize as u64)
        if it == self._set_at.end() {
            return usize::MAX
        }

        return it->second as usize
    }

    fn _off_of(self, d: unsafe *Decl) -> usize {
        var unsafe *sm = self._cg->ctx->sm
        if sm == &null {
            return 0
        }

        if !d->range.start.is_valid() {
            return 0
        }

        return sm->get_offset(d->range.start)
    }
}

/// \class PlanLease
/// \brief A plan run ahead (CodegenJob::make_plan), bound to one stream's
///        sink for one fill and given back as it was found.
///
/// \details A fill prunes the plan's entries by what its host already holds
///          (the interface PCH's keys, an earlier include's), and the same
///          plan fills again: the interface PCH's stream, then each kind of
///          the TU's compile, then the compile again without the PCH when
///          clang had something to say (CodegenJob::run). Left pruned, a
///          later fill emits a stream missing every declaration the pruning
///          dropped. op finally restores, so no return between the bind and
///          the end of the fill can skip it.
///
///          The context stays Planned (CodegenPhase): it fills again. Each
///          plan is one TU's and its fills run one after another (the
///          interface PCH's stream before the fan-out, then its own job's),
///          so the lease is never contended; holding a bound plan's sink is
///          what the debug check below catches.
///
///          A null plan leases nothing: the fill planned on its own context,
///          which dies with it.
pub class PlanLease {
    priv var _plan:  unsafe *EmitPlan = &null
    priv var _saved: cxx::std::vector<PlanEntry>

    fn PlanLease(self, plan: unsafe *EmitPlan, sink: unsafe *EmitSink, ctx: unsafe *ASTContext) {
        self._plan = plan
        if plan == &null {
            return
        }

        var unsafe *cg = plan->cg()
        eval if defined!(DEBUG) {
            if cg->sink != &null {
                kairo::std::ice_fail(
                    r"PlanLease: plan already bound to a sink (a lease outlived its fill, or two fills share one plan)",
                )
            }
        }

        cg->require_phase(CodegenPhase::Planned)
        cg->sink      = sink
        sink->ice_ctx = ctx
        self._saved   = plan->entries
    }

    // Not transferable: op finally restores the plan, and a copy would
    // restore it twice, the second time over a later lease's binding.
    @copy fn PlanLease(self, const other: Self) = delete

    fn op finally(self) {
        if self._plan == &null {
            return
        }

        self._plan->entries = self._saved
        // The sink is this stream's, gone before the plan fills again.
        self._plan->cg()->sink = &null
    }
}

/// "Does this layout reach \p target by value?" over the by-value spine:
/// records, tuples, fixed arrays, and a generic ARGUMENT only where the
/// primary stores that parameter by value. Pointers, references and the
/// (pre-migration) structural containers stop the walk.
pub class LayoutSpine {
    priv var _plan:   *EmitPlan
    priv var _target: unsafe *Decl
    /// Collect mode (EmitPlan::_need_row): every layout decl the walk would
    /// compare against the target goes in here, and nothing answers true,
    /// so the walk covers the whole spine once for every target.
    pub var collect: unsafe *llvm::DenseSet<u64> = &null

    fn LayoutSpine(self, plan: *EmitPlan, target: unsafe *Decl) {
        self._plan = plan
        // In the form reaches() compares against: layout_decl's, which for
        // an ADT is its layout record.
        self._target = plan->layout_decl(target)
    }

    fn bases(self, list: *FrozenList<Declarations::InheritEdge>) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *e = list->get(i)
            if e == &null {
                continue
            }

            if self.reaches(e->base) {
                return true
            }
        }

        return false
    }

    fn fields(self, list: unsafe *FrozenList<unsafe *Declarations::FieldDecl>) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *f = *list->get(i)
            if f == &null {
                continue
            }

            // An anonymous union's members are laid out inside this record,
            // so they order it exactly as its own fields do.
            if f->is_anonymous_union {
                if self.fields(unsafe &self._plan->anon_union_of(f)->fields) {
                    return true
                }

                continue
            }

            if self.reaches(f->type_) {
                return true
            }
        }

        return false
    }

    /// A method written with a C++ default argument (`= __kairo_default_f_x()`)
    /// has clang call the thunk where the member is declared, inside the
    /// record's body, so the default's type is defined ahead of the record.
    fn defaults(self, list: *FrozenList<unsafe *Declarations::FunctionDecl>) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *m = *list->get(i)
            if m == &null || CXXSpell::template_params(unsafe (m as unsafe *Decl)).size() > 0 {
                continue
            }

            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = *m->params.get(j)
                if p == &null
                    || p->is_self
                    || p->is_pack
                    || p->default_thunk == &null
                    || !p->default_thunk_home {
                    continue
                }

                if self.reaches(p->type_) {
                    return true
                }
            }
        }

        return false
    }

    fn reaches(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                return self.reaches(cast<QualifiedType>(c)->inner)
            }

            // `T?` holds its record by value (NullableTypeLowering).
            case TypeKind::NullableType {
                return self.reaches(cast<NullableType>(c)->lowered)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = self._plan->layout_decl(r->decl)
                if self.collect != &null {
                    self.collect->insert(d as usize as u64)
                } else if d == self._target {
                    return true
                }

                // A payload struct is defined inside its ADT's body, so what it
                // holds by value orders the ADT exactly as its own fields
                // would. Its type names the struct, never the ADT.
                var unsafe *ps = dyn_cast<Declarations::StructDecl>(d)
                if ps != &null && ps->is_adt_payload {
                    return self.fields(unsafe &ps->fields)
                }

                // An imported C++ template may store an argument inline
                // (`llvm::SmallVector<(A, B), 4>`), which no Kairo field says.
                // A tuple record has no source position to fall into place by,
                // so one as such an argument orders the holder after it (O36b).
                // Other records keep (fid, offset) order: `vector<B>` in A and
                // `vector<A>` in B is valid C++ an edge would make a cycle.
                var imp = DeclFacts::decl_is_imported(d)
                for var i: usize = 0; i < r->args.size(); ++i {
                    var unsafe *a = *r->args.get(i)
                    if imp && self._plan->is_tuple_type(a) {
                        if self.reaches(a) {
                            return true
                        }

                        continue
                    }

                    if !self._plan->param_by_value(d, i as u32) {
                        continue
                    }

                    if self.reaches(a) {
                        return true
                    }
                }

                return false
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    if self.reaches(*tp->elements.get(i)) {
                        return true
                    }
                }

                return false
            } case TypeKind::FixedArrayType {
                return self.reaches(cast<FixedArrayType>(c)->element)
            } case TypeKind::BuiltinType {
                // A builtin spelled as a class (`f256` -> F256) is that class
                // held by value: a field of it needs the class defined first.
                var unsafe *ld = cast<BuiltinType>(c)->lang_decl
                if ld == &null {
                    return false
                }

                var unsafe *d = self._plan->layout_decl(ld)
                if self.collect != &null {
                    self.collect->insert(d as usize as u64)
                } else if d == self._target {
                    return true
                }

                return false
            } default {
                return false
            }
        }
    }
}

/// \p d_in, or a declaration enclosing it, has a `<T: type>` parameter
/// (Sema's panic_in_duck): the C++-checked regime, whose member calls
/// through T EmitIR wraps (LowerTargets::nopanic_call).
pub fn plan_under_duck(d_in: unsafe *Decl) -> bool {
    var unsafe *d = d_in
    for var depth: u32 = 0; d != &null && depth < 64; ++depth {
        var gps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i] != &null && gps[i]->kind_bound == Declarations::GenericParamKindBound::Duck {
                return true
            }
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return false
        }

        d = dc->owner_decl()
    }

    return false
}
