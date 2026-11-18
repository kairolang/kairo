/// --- The Kairo Project --------------------------- Codegen/EmitPlan.k --- ///
///
/// Per emitted TU, work out every declaration the C++ needs, how
/// much of each (`class X;` or the body-less definition), and the
/// order they must appear in.
///
///   \par Where its parts are
///     This file holds the plan's types, the class with its fields, run(),
///     the RecursiveASTVisitor hooks (visit_*, kept in the class body with
///     the base they override), the dump and the predicates every part uses.
///     The rest of its methods are `extend EmitPlan` blocks, one file per
///     concern, reaching the fields as `prot` (Codegen/module.k makes
///     Codegen/ one module); a helper only its own part calls stays `priv`
///     there. Callers in other files use members of every part, so this file
///     re-exports the parts (`pub import`):
///       EmitPlanHomes.k    file order, the import graph, instance homes
///       EmitPlanFriends.k  borrowed hidden decls, record friends
///       EmitPlanRoots.k    own decls, extension scopes, uses, eval vars
///       EmitPlanWitness.k  witness pieces
///       EmitPlanEarly.k    early items, visible bodies, a body's admits
///       EmitPlanAdmit.k    the working set and its closure
///       EmitPlanLayout.k   layout queries, value-parameter records
///       EmitPlanOrder.k    the emission order
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
import AST::Context::DeclContext::DeclContextKind
import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts
import AST::ExprFacts::checked_array_index
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
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
    AlignOfExpr,   BinaryOperatorExpr, CallExpr,      ClosureExpr, ConstraintExpr, SizeOfExpr,
    SubscriptExpr, TypeCastExpr,       TypeTraitExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Statements::{
    IterKind,
    RangedForStmt,
}
import AST::Node::Types::{
    FixedArrayType,
    NullableType,
    TupleType,
}
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
import Codegen::Emit::EmitWitness::WitnessPiece
import Codegen::Emit::Spell::{
    Speller,
    VIS_INTERNAL,
    VIS_NONE,
    VIS_PRIV,
    VIS_PUB,
}
pub import Codegen::EmitPlanAdmit
pub import Codegen::EmitPlanEarly
pub import Codegen::EmitPlanFriends
pub import Codegen::EmitPlanHomes
pub import Codegen::EmitPlanLayout
pub import Codegen::EmitPlanOrder
pub import Codegen::EmitPlanRoots
pub import Codegen::EmitPlanWitness
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

/// One thing an early item needs (EmitPlan::_early_needs): `val` is an item
/// `item` reads (kind 0), one it evaluates at its definition (1), or a record
/// it needs complete (2).
pub struct EarlyNeed {
    var item: unsafe *Decl
    var kind: u8
    var val:  unsafe *Decl
}

/// A compile-time string literal held by name: its bytes, their count and
/// their LowerTargets::eval_str_hash.
pub struct BigStr {
    var bytes: kairo::std::ConstPtr<u8>
    var len:   usize
    var hash:  u64
    /// A literal object of the two-word library (LowerTargets::lit_str):
    /// the codepoint count goes in front of the bytes.
    var header: bool = false
}

/// _needs_complete(who, *) for one who (EmitPlan::_need_row): true for dep
/// exactly when dep is in `direct` or layout_decl(dep) is in `layout`.
pub struct NeedRow {
    var direct: llvm::DenseSet<u64>
    var layout: llvm::DenseSet<u64>
}

/// One record's value-parameter template names and nested-type owners,
/// memoized (EmitPlan::_vp_row).
pub struct VpNames {
    var vp:   llvm::DenseSet<u64>
    var nest: llvm::DenseSet<u64>
}

/// # Graph-independent order and homes (Compiler/Spec/Incremental.md#shared-across-graphs)
///
/// A TU's stream is its incremental object key, and one cache is shared by
/// every graph that holds the TU (kairo, kcc, kfmt are built from one tree).
/// Two facts of the GRAPH, not of the TU, would otherwise leak into the plan:
/// file ids (minted in the PP walk's order from the entry, so Kairo.k and
/// Kcc.k number the same modules differently) would order every tier, and an
/// instance's home would be its first namer in the one-thread order (which
/// the entry decides too). Both are replaced here for the length of a codegen,
/// set by the driver before any plan runs and read-only after.

/// fid -> its rank in the build's files sorted by module path (set_file_ranks);
/// u32::MAX, or past the end, for a file that has none (it sorts after every
/// ranked file, by fid).
var _FILE_RANK: cxx::std::vector<u32> = cxx::std::vector<u32>()
/// The import graph (set_graph): per Kairo module fid, its import edge
/// targets in declaration order (empty for any other file), and the
/// prelude's fid (0: none).
var _G_EDGES: cxx::std::vector<cxx::std::vector<u32>> = cxx::std::vector<cxx::std::vector<u32>>()
var _G_IS_MOD:  cxx::std::vector<u8> = cxx::std::vector<u8>()
var _G_PRELUDE: u32                  = 0
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

/// Functions and globals a header leaves out by its root rule (_hidden) that
/// a visible body in ANOTHER file's header names (`prot inline fn
/// scope_push`, called from AllocatorScope's template bodies in
/// base/alloc.hh). The other header reaches them through an `#include` of
/// their home's, so the HOME header declares them, as it declares a hidden
/// helper its own inline body names: one copy, under the home's `#pragma
/// once`, with the linkage the module's own object gives them. Filled by
/// note_borrowed on the driver thread before any header is made, read-only
/// after; cleared by clear_borrowed.
var _BORROWED: cxx::std::vector<unsafe *Decl> = cxx::std::vector<unsafe *Decl>()

/// The headers of this `--emit-headers` run that sit in an include cycle
/// (modules of the builtin directory may import each other), by header
/// path, each with the index of its cycle group (strongly connected
/// component, from 1). Filled by note_header_cycles on the driver thread
/// before any header is made, read-only after; cleared by clear_borrowed.
var _HDR_CYCLE_PATH: cxx::std::vector<string> = cxx::std::vector<string>()
var _HDR_CYCLE_SCC:  cxx::std::vector<u32>    = cxx::std::vector<u32>()

pub class EmitPlan derives RecursiveASTVisitor<EmitPlan> {
    prot var _cg:    unsafe *CodegenContext
    prot var _spell: Speller
    prot var _mode:  PlanMode               = PlanMode::Preamble
    prot var _home:  u32                    = 0

    prot var _set:  cxx::std::vector<unsafe *Decl>
    prot var _need: cxx::std::vector<PlanNeed>
    /// Per _set entry, the strongest need reached from the declarations
    /// rather than from a body walk (_walk_visible), as a PlanNeed's value;
    /// u8::MAX when only bodies reach it. A header in an include cycle reads
    /// it to split its includes (decl_complete).
    prot var _decl_need: cxx::std::vector<u8>
    /// The admission in progress comes from a body walk, or from the
    /// expansion of an entry only bodies reach at its strength.
    prot var _in_body: bool                                    = false
    prot var _queue:   cxx::std::vector<usize>
    prot var _insts:   cxx::std::vector<unsafe *InstanceEntry>
    /// _insts' members by address: what _insts already holds.
    prot var _inst_seen: llvm::DenseSet<u64>
    /// _rank_of's walk: fid -> this TU's order (u32::MAX: not met).
    prot var _rank:   cxx::std::vector<u32>
    prot var _ranked: bool                  = false
    /// Member-template instances admitted (no tier-3 line, so not _insts):
    /// their reach is followed once.
    prot var _members: cxx::std::vector<unsafe *InstanceEntry>
    /// Every extension scope the plan touches. Indexed while the closure
    /// runs (it grows); PlanEntry::scope points in only once it is done.
    prot var _scopes: cxx::std::vector<ExtScope>
    /// Every witness piece the plan holds: interface primaries and row
    /// specializations. Index-based while the closure runs, as _scopes.
    prot var _witnesses: cxx::std::vector<WitnessPiece>
    /// Rows whose ConformanceRow::assoc_rows _witness_row has followed.
    prot var _assoc_seen: cxx::std::vector<unsafe *ConformanceRow>

    /// Memo for param_by_value: (primary, index) -> answer. Pairs, linear
    /// scan; a build has tens of generic primaries, not thousands.
    prot var _pbv_key: cxx::std::vector<u64>
    /// Records _duck_reach has walked, once each.
    prot var _duck_seen: cxx::std::vector<unsafe *Decl>
    prot var _pbv_val:   cxx::std::vector<u8>
    prot var _pbv_depth: usize                          = 0

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
    /// A body declares a local with union storage (VariableDecl::dtor_mode
    /// is not Scope): the preamble must define `::__kairo_ul` and its
    /// helpers (InterfaceEmitter::_union_local_helpers).
    pub var needs_union_local: bool = false
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
    pub var needs_fmt_dyn: bool = false
    /// A body holds a move its generic instance decides (TypeCastExpr::
    /// instance_move): the preamble must define LowerTargets::instance_move.
    /// Only then, so other TUs keep their text.
    pub var needs_instance_move: bool = false
    /// A body indexes a fixed array with a run-time bounds check
    /// (checked_array_index): the preamble must define LowerTargets::
    /// index_check. Only then, so other TUs keep their text.
    pub var  needs_index_check: bool = false
    priv var _ef_value_fn:      bool = false
    /// Compile-time string literals too long for `__kairo_estr<...>`
    /// (LowerTargets::eval_str_inline_max, Compiler/Spec/Eval.md#value-nodes), once each by
    /// content: InterfaceEmitter defines each as a named `inline constexpr`
    /// array at global scope, ahead of every body and type that spells it.
    pub var big_strs: cxx::std::vector<BigStr>
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
    prot var _empty: bool = true
    /// run() was called: before it, _empty's true is no verdict.
    prot var _ran: bool = false
    /// This is _find_escaping's own plan, made while it fills the TU's
    /// cxx_escaping: it never fills it itself. The TU's flag says Done only
    /// once the set is whole.
    prot var _escaping_probe: bool = false

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
    prot var _eo_who: cxx::std::vector<unsafe *Decl>
    prot var _eo_dep: cxx::std::vector<unsafe *Decl>
    /// EarlyNeeds per item, flattened: one row per thing an item needs.
    prot var _en_done: cxx::std::vector<unsafe *Decl>
    prot var _en:      cxx::std::vector<EarlyNeed>
    /// _set's index by decl address: _admit asked _index_of for every
    /// use, a linear scan of the set. _set only grows, at one push site.
    prot var _set_at: llvm::DenseMap<u64, u64>
    /// _vp_row per `who`: the decls a record's definition names through a
    /// value-parameter template (vp) or as the owner of a nested type
    /// (nest), from one walk, as _needs_complete asks per pair.
    prot var _vp_memo:   llvm::DenseMap<u64, u64>
    prot var _vp_rows:   cxx::std::vector<VpNames>
    prot var _need_memo: llvm::DenseMap<u64, u64>
    prot var _need_rows: cxx::std::vector<NeedRow>

    /// An Include plan for a C++ TU inside this TU's module (IncludeEmitter):
    /// `prot` declarations are its to see (AST/VisibilityFacts.k). A Header
    /// has no includer, so it carries `pub` only.
    pub var host_in_module: bool = false
    /// The root rule before the default became `priv` / `prot`: only a
    /// written `priv` (or `internal`) is left out. _find_escaping's nested
    /// plan, whose answer decides which hidden decls go to an anonymous
    /// namespace (Speller::is_anon reads written visibility only).
    pub var legacy_roots: bool = false

    pub fn EmitPlan(self, cg: unsafe *CodegenContext, mode: PlanMode = PlanMode::Preamble) {
        self._cg    = cg
        self._spell = Speller(cg)
        self._mode  = mode
    }

    /// ICE naming the Kairo source at `at` (CodegenICE).
    prot fn _ice(self, at: SourceRange, const msg: string) {
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

    fn spell(self) -> unsafe *Speller {
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
            kairo::std::ice_fail(
                "EmitPlan: no InstantiationRegistry on the CodegenContext",
            )
        }

        if !self._escaping_probe && !tu->cxx_escaping_done && Speller::is_entry_tu(tu) {
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
    /// TranslationUnit::cxx_escaping, which Speller::is_anon reads for any
    /// TU's decl. The driver calls this for every TU, on its own thread, before
    /// TUs are emitted side by side (CodegenJob); run() then finds it done and
    /// writes nothing shared.
    pub fn prepare_shared(self) {
        var unsafe *tu = self._cg->tu
        if tu == &null || tu->program == &null {
            return
        }

        if !tu->cxx_escaping_done && Speller::is_entry_tu(tu) {
            self._find_escaping(tu)
        }
    }

    /// Before a plan runs on a codegen worker (CodegenJob): the shared state
    /// run() would otherwise fill in place is filled. A miss is a driver that
    /// skipped prepare_shared, and run() would write the entry TU's
    /// cxx_escaping beside other workers reading it (Speller::is_anon).
    pub fn require_shared(self) {
        eval if defined!(DEBUG) {
            var unsafe *tu = self._cg->tu
            if tu != &null
                && tu->program != &null
                && Speller::is_entry_tu(tu)
                && !tu->cxx_escaping_done {
                kairo::std::ice_fail(
                    r"EmitPlan: a codegen worker would fill TranslationUnit::cxx_escaping (prepare_shared skipped)",
                )
            }
        }
    }

    /// TranslationUnit::cxx_escaping for pathless TU `tu`: a Header plan of the
    /// file roots at its pub decls and walks its inline and template bodies to
    /// a fixed point, admitting every hidden decl one names -- exactly the set.
    /// The nested plan is a probe (_escaping_probe), so it does not recurse,
    /// and the TU is marked done once the set is whole; nothing in planning
    /// reads is_anon.
    fn _find_escaping(self, tu: unsafe *TranslationUnit) {
        var hcg = CodegenContext(
            self._cg->ctx,
            &null,
            self._cg->psym,
            self._cg->instances,
        )

        var hplan = EmitPlan(unsafe &hcg, PlanMode::Header)
        hplan.legacy_roots    = true
        hplan._escaping_probe = true
        hplan.run()
        for var i: usize = 0; i < hplan.entries.size(); ++i {
            var *e = &hplan.entries[i]
            if !e->own || e->decl == &null || e->scope != &null {
                continue
            }

            if !_hidden_in_header(Speller::vis_of(e->decl)) {
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

    /// `d` is no root of a Header or Include plan: C++ outside the module may
    /// not name it (AST/VisibilityFacts.k). `priv` and `internal` never; `prot`
    /// only for a C++ TU of the module (host_in_module); an unmarked decl is
    /// what its file's default makes it. A hidden decl still gets there when a
    /// visible inline or template body names it, as a written `priv` always has.
    fn _hidden(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var v = Speller::vis_of(d)
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
        return !self.host_in_module || tu_module_dir(Speller::tu_of(d)).is_empty()
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
                    nm += if (k == 0) => (Speller::kairo_top_of(e->scope->ns[k]))
                          else => e->scope->ns[k].copy()
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

        if e->kind == ExprKind::TypeCastExpr && cast<TypeCastExpr>(e)->instance_move {
            self.needs_instance_move = true
        }

        if e->kind == ExprKind::SubscriptExpr
            && checked_array_index(cast<SubscriptExpr>(e)) != &null {
            self.needs_index_check = true
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
                            self._admit_receiver(
                                c->steps.get(i - 1)->resolved_type,
                            )
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
                self._admit_type(
                    cast<ClosureExpr>(e)->panic_result,
                    PlanNeed::Complete,
                )
            } case ExprKind::StringLiteralExpr {
                // A byte literal C++ reads at compile time (Compiler/Spec/Eval.md#strings-at-compile-time): a long
                // one is a named array this plan's interface defines.
                var unsafe *sl = cast<StringLiteralExpr>(e)
                if sl->lit_header && sl->imm != &null && sl->imm->has_owned_text() {
                    self.note_lit_str(
                        sl->imm->owned_ptr,
                        sl->imm->owned_len as usize,
                    )
                } else if sl->const_eval && sl->imm != &null && sl->imm->has_owned_text() {
                    self.note_eval_str(
                        sl->imm->owned_ptr,
                        sl->imm->owned_len as usize,
                    )
                }
            } case ExprKind::ConstraintExpr {
                // `eval if A impl I` in a body is I's concept (EmitIR::_constraint),
                // which only a requires clause would otherwise have planned.
                var unsafe *ce = cast<ConstraintExpr>(e)
                if !ce->is_derives()
                    && ce->rhs != &null
                    && ce->rhs->canonical != &null
                    && isa<RecordType>(canon_unqual(ce->rhs->canonical)) {
                    var unsafe *cd = cast<RecordType>(
                        canon_unqual(ce->rhs->canonical),
                    )->decl
                    if isa<Declarations::InterfaceDecl>(
                        Speller::rep(DeclFacts::decl_pattern(Speller::rep(cd))),
                    ) {
                        self._admit(cd, PlanNeed::Complete)
                    }
                }
            } case ExprKind::SizeOfExpr {
                // The operand is laid out, not just named: Complete, whatever
                // visit_type (Fwd, for a type merely spelled) would say.
                self._admit_type(
                    cast<SizeOfExpr>(e)->type_arg,
                    PlanNeed::Complete,
                )
            } case ExprKind::AlignOfExpr {
                self._admit_type(
                    cast<AlignOfExpr>(e)->type_arg,
                    PlanNeed::Complete,
                )
            } case ExprKind::TypeTraitExpr {
                // clang's trivially-* builtins need the type complete, as sizeof does.
                self._admit_type(
                    cast<TypeTraitExpr>(e)->type_arg,
                    PlanNeed::Complete,
                )
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
                // A constructor's instance is checked (its bounds) but never
                // homed: C++ has no explicit instantiation of a constructor
                // by that spelling, and the call instantiates it implicitly.
                var unsafe *ie = cast<CallExpr>(e)->instance
                if ie != &null && cast<CallExpr>(e)->ctor_decl == &null {
                    self._admit_instance(ie, PlanNeed::Fwd)
                }

                // `Box<int>::zero()`: the member is looked up in the class, so
                // the instance is complete here, and homed like any named one.
                self._admit_type(
                    cast<CallExpr>(e)->qualifier,
                    PlanNeed::Complete,
                )

                // `I::m(x)` on a concrete x: its row rides on the call.
                var unsafe *wr = cast<CallExpr>(e)->witness_row
                if wr != &null {
                    self._witness_row(wr)
                }
            } default { }
        }

        return true
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
    /// A conditional block's bodies are not this file's own: what they name
    /// (the block's own conversions, C++ types this file's headers may not
    /// declare) enters a plan only where a use made one of them a visible
    /// body (_walk_visible), which walks the body itself.
    fn visit_extension_decl(self, n: unsafe *Declarations::ExtensionDecl) -> bool {
        return n->gate == &null
    }

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

                if cast<Declarations::VariableDecl>(d)->borrow_inst {
                    self.needs_instance_move = true
                }

                if cast<Declarations::VariableDecl>(
                    d,
                )->dtor_mode != Declarations::LocalDtor::Scope {
                    self.needs_union_local = true
                }

                self._admit_type(
                    cast<Declarations::VariableDecl>(d)->type_,
                    PlanNeed::Complete,
                )
            } case DeclKind::FieldDecl {
                self._admit_type(
                    cast<Declarations::FieldDecl>(d)->type_,
                    PlanNeed::Complete,
                )
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
                self._admit_type(
                    cast<Declarations::TypeAliasDecl>(d)->aliased,
                    PlanNeed::Complete,
                )
            } default { }
        }

        return true
    }

    /// # Predicates

    /// `d` is a member of a generic record (its own generic params aside).
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

    /// `d` is declared in an interface: a requirement, never a C++ function.
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
            cur = Speller::rep(dc->dc_owner)
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

/// A plan run ahead (CodegenJob::make_plan), bound to one stream's
/// sink for one fill and given back as it was found.
///
/// A fill prunes the plan's entries by what its host already holds
/// (the interface PCH's keys, an earlier include's), and the same
/// plan fills again: the interface PCH's stream, then each kind of
/// the TU's compile, then the compile again without the PCH when
/// clang had something to say (CodegenJob::run). Left pruned, a
/// later fill emits a stream missing every declaration the pruning
/// dropped. op finally restores, so no return between the bind and
/// the end of the fill can skip it.
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
    priv var _plan:  unsafe *EmitPlan            = &null
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

/// "Does this layout reach `target` by value?" over the by-value spine:
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
            if m == &null || Speller::template_params(unsafe (m as unsafe *Decl)).size() > 0 {
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

/// `d_in`, or a declaration enclosing it, has a `<T: type>` parameter
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
