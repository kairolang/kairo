/// --- The Kairo Project ---------- AST/Context/InstantiationRegistry.k --- ///
///
///   \brief THE instantiation registry: (primary, canonical args) -> the decl
///          that IS that instance. One per build, beside the canonical type
///          store, for the same reason: RecordType::decl is a pointer identity
///          and pointers only compare inside one domain.
///
///   \detail
///     Compiler/Spec/Pipeline.md hard invariant #12. A CONCRETE `Foo<i32>` has
///     exactly one
///     decl behind it for the whole build:
///
///       - an EXPLICIT full specialization the user wrote
///         (`class <> Foo<i32> { ... }`), registered by T once its spec_args
///         are canonical; or
///       - an IMPLICIT instantiation node, created HERE on first mention: the
///         primary's DeclKind, `spec_kind = Instantiated`,
///         `instantiated_from = primary`, empty body, own (empty) table. M2
///         fills it. The partial specialization its args select, if any, is
///         chosen here at mint (_select) and kept on the entry (`pattern`,
///         `pattern_args`); `instantiated_from` stays the primary. Until M2
///         name lookup walks that body: the partial, else the primary
///         (MemberLookup::_walk_record, SemaContext::body_of).
///
///     Dependent uses (`Foo<T>`, `Self` in a generic body) never come here:
///     their RecordType::decl is the primary -- a pattern -- and that is what
///     "deferred" means (#5). Partial specializations never back a RecordType
///     at all; they are patterns, kept per primary for the selection at mint.
///
///     The node is created at NAMING time, not at instantiation time, for the
///     same reason Clang does it: the type needs a decl to point at the moment
///     it exists, and retargeting RecordType::decl later would break the
///     pointer identity everything after T keys on.
///
///   \par Order (M1, Compiler/Spec/Generics.md#m1-enumeration)
///     Every entry is inserted into one worklist as it is minted, whoever
///     mints it, at its request key (see "Order" below: the order a
///     one-thread Sema would have minted it in, whichever thread mints
///     first); the discovery fixpoint (ConformanceChecking::discover, run
///     by each TU's checks and again by M1, Sema.k::_stage_mono_collect)
///     drains its live entries, walking each one's reach. That order, not
///     the hash table's, is the registry's iteration order. An instance a
///     generic body reaches is linked to the instance that reached it
///     (InstanceEntry::reached), which is how a plan holding the outer one
///     homes or `extern`s the inner one, named in no tree.
///
///   \par Arena / threading
///     Own arena: an implicit node first named by fid A is referenced by every
///     importer of A and must outlive A's ast_alloc reset. Mutex-guarded: the
///     typed checks of TUs that do not import each other run on pool workers
///     and two of them WILL name `Vec<i32>` at once.
///     The arena is shared() under `_arena_mu`, not `_mu`: a shell's own
///     lists (dc_decls, annotations) allocate from it too, and their writer
///     is not this class -- ForeignInstantiate fills an imported template's
///     shell under its own lock while another worker mints an entry here
///     under `_mu`. Both bumped one arena at once and handed out the same
///     bytes: an entry's `args` overwritten by a shell's slab.
///
///   Layer: AST/Context. Imports AST only, never Sema (cycle rule).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/AddrRanges.hh"
ffi "c++" import "llvm/Support/Allocator.h"
ffi "c++" import "Native/KPlacement.hh" // construct_at
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KThread.hh" // sema_mint_rank / sema_mint_counter / sema_fill_record
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "cstring"

import AST::Context::ASTContext::ASTContext
import AST::Context::DepLog::dep_log_current
import AST::Context::CanonicalTypes::{
    canon_hash_ptr,
    canon_hash_u64,
}
import AST::Context::DeclContext::DeclContextKind
import AST::DeclFacts::{
    PackSetOrder, decl_dedup_pack_args, decl_generic_params, decl_is_imported, decl_pack_set_at,
    decl_pattern, decl_requires_clause, decl_spec_args,
}
import AST::Kind::DeclKind::DeclKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinType,
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,     EnumDecl, EnumVariantDecl, FieldDecl, FunctionDecl, GenericParamDecl,
    InterfaceDecl, SpecKind, StructDecl,      UnionDecl,
}
import AST::Node::Expressions::{
    AlignOfExpr,
    BinaryOperatorExpr,
    ParenExpr,
    SizeOfExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    IntegerLiteralExpr,
}
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    GenericParamType,
    NullableType,
    PointerType,
}
import Location::SourceRange::SourceRange
import Memory::ArenaAllocator::ArenaAllocator
import Token::TokenKind::TokenKind

/// \class ConformanceRow
/// \brief `(conformer, interface)` and, for each of the interface's OWN
///        requirements, the decl that implements it (Compiler/Spec/Generics.md#partial-selection, "The
///        conformance table"). Sema records the decls and nothing else;
///        EmitWitness decides from their spellings whether the row needs a
///        specialization (Compiler/Spec/Witnesses.md#when-a-row-needs-a-specialization).
///
///   Kept here, beside the instances, for the reason the registry is one
///   per build: a row TU A found is the row every TU holding the same
///   instance needs, and it is keyed on canonical pointers, which compare
///   only inside one domain.
pub class ConformanceRow {
    pub var conformer:  unsafe *Type = &null ///< canonical, unqualified: `Metric`, `i32`.
    pub var iface:      unsafe *Type = &null ///< the canonical interface instance (a RecordType).
    pub var iface_decl: unsafe *Decl = &null ///< its InterfaceDecl's representative.
    /// The `impl` that declared it (`class X impl I`, `extend X impl I`), or
    /// null for a STRUCTURAL row found at a use.
    pub var declared: unsafe *Decl = &null
    /// Parallel to `iface_decl`'s methods: the implementing decl, or null
    /// where the conformer has none (then `ok` is false).
    pub var witnesses: cxx::std::vector<unsafe *Decl>
    /// Parallel to `witnesses`: the requirement each implements (the
    /// interface's composed list), for the checks that hold a witness to its
    /// requirement (PanicEffectChecking: its panic set within the
    /// requirement's).
    pub var reqs: cxx::std::vector<unsafe *Decl>
    /// A witness that is a GENERIC extension's member is called with the
    /// extension's arguments, as the conformer binds them (`extend <E>
    /// Wrap<E>` met by `Wrap<i32>`: E := i32): flat, `ext_arg_count[i]` of
    /// them per witness, in witness order, zero for any other.
    pub var ext_args:      cxx::std::vector<unsafe *Type>
    pub var ext_arg_count: cxx::std::vector<usize>
    /// Parallel to `witnesses`: the interface instance requirement i came
    /// through, at THIS row's arguments (`interface <T> F derives
    /// Container<T>` met as `F<i32>`: Container<i32>). The composed list
    /// keeps a source in the composing interface's own parameters, which
    /// codegen cannot substitute; a specialization spells the requirement
    /// through this instance instead.
    pub var sources: cxx::std::vector<unsafe *Type>
    /// Parallel to `witnesses`: for an associated-type requirement, the
    /// type the conformer supplies (its alias, or the default an explicit
    /// conformance takes; Substitution::assoc_witness), null for any other
    /// requirement. Its witness is the alias decl, or the requirement
    /// itself for a default. EmitWitness spells it as the specialization's
    /// member type.
    pub var assoc_types: cxx::std::vector<unsafe *Type>
    /// The rows proving each supplied associated type meets that
    /// associated type's own bounds (`type Item impl Holder`, Item := Purse:
    /// `Purse impl Holder`). They are this row's facts too: a body bounded
    /// by the interface reaches members through the associated type, and
    /// those spell the bound's witness at the supplied type, so EmitPlan
    /// admits them wherever it admits this row.
    pub var assoc_rows: cxx::std::vector<unsafe *ConformanceRow>
    /// A concrete row that a GENERIC declared row (`extend <E> Wrap<E> impl
    /// I`, conformer over its own parameters) covers -- same witnesses, its
    /// conformer and interface at this row's arguments -- or null. EmitPlan
    /// admits that row's partial specialization in place of a full one.
    pub var covered_by: unsafe *ConformanceRow = &null
    pub var ok:         bool                   = false
    /// The TUs (fids) this row is USABLE in, as far as any has asked: its
    /// implementing decls are in that TU's transitive import set, the
    /// extension-visibility rule (Compiler/Spec/Generics.md#partial-selection, Visibility; Compiler/Spec/Generics.md
    /// D7). The row itself is a program-wide fact -- codegen emits it in
    /// every TU holding an instance that binds it, whatever that TU imports
    /// -- and this is the per-TU filter Sema's lookup applies to it. The
    /// declaring TU first, then each one that found it visible, in the
    /// order they asked. Writer: row_mark_visible, under the lock.
    pub var seen_by: cxx::std::vector<u32>
    /// A DETACHED row only (row_detached, never in the table): the
    /// requirement match for one TU that could not use the table's row.
    /// `hidden` is an implementing decl the match skipped because the TU
    /// cannot see it (the reason it is not ok), `clash` the table's row when
    /// the match found a DIFFERENT implementation that this TU can see -- one
    /// conformance with two implementations, which C++ cannot hold (ODR).
    pub var hidden: unsafe *Decl           = &null
    pub var clash:  unsafe *ConformanceRow = &null
    pub fn ConformanceRow(self) { }

    /// Witness \p i's extension arguments, appended to \p out.
    pub fn ext_args_of(self, i: usize, @inout out: cxx::std::vector<unsafe *Type>) {
        var at: usize = 0
        for var k: usize = 0; k < i && k < self.ext_arg_count.size(); ++k {
            at += self.ext_arg_count[k]
        }

        if i >= self.ext_arg_count.size() {
            return
        }

        for var k: usize = 0; k < self.ext_arg_count[i]; ++k {
            out.push_back(self.ext_args[at + k])
        }
    }
}

/// One step of a `requires` clause evaluated by InstantiationRegistry
/// (requires_holds): \p v when \p known.
pub struct PartialPredValue {
    pub var known: bool = false
    pub var v:     i64  = 0
}

/// \enum InstanceLatch
/// \brief An InstanceEntry's one-shot facts: each goes true once per build,
///        for the first claimant only (InstantiationRegistry::claim). The
///        T fronts on the pool and the driver's Conformance meet the same
///        build-wide entry, so a plain check-then-set let two of them both
///        report SC157E / SC158E, or both compute its panic facts.
pub enum InstanceLatch derives u8 {
    Ambiguity = 0, ///< ambiguity_reported: SC157E at a naming site.
    Undecided,     ///< undecided_reported: SC158E at a naming site.
    PanicChecked,  ///< panic_checked: PanicEffectChecking asked its `try` arms.
    PanicDone,     ///< panic_done: PanicLowering computed its panic facts.
}

/// \enum InstLiveness
/// \brief Where an InstanceEntry is in M1's discovery (Compiler/Spec/Generics.md#m1-enumeration):
///        minted (nothing has needed it: a losing candidate's substitution,
///        say, whose bounds must not be checked), live (a use needs it; its
///        reach not walked yet: drain hands it out), walked (its reach is in
///        the registry and bound-checked). Forward only, under the registry
///        lock: mark_live, set_checked. The one way back is a live check's
///        re-arm (Sema/Incremental/Retract.k), which runs with nothing else
///        in flight. `depth` stays the chain length, nonzero exactly when
///        the entry is past Minted (_check_live). `failed` is not a state of
///        this: it is the bounds verdict, written by mark_failed only and
///        read without the lock by Conformance, which mark_live must not
///        race on the same byte.
pub enum InstLiveness derives u8 {
    Minted = 0,
    Live,
    Walked,
}

/// \class InstanceEntry
/// \brief One concrete instance of a generic type. Both halves of "an
///        instantiation" hang here: the CHECKING-side decl (what RecordType
///        points at, what M2 fills) and the EMIT-side fact (the explicit
///        instantiation directive EmitPlan writes, once, in `home_fid`).
pub class InstanceEntry {
    pub var primary:     unsafe *Decl                   = &null ///< the primary's representative.
    pub var args:        cxx::std::vector<unsafe *Type> ///< canonical, parameter order, packs flat.
    pub var decl:        unsafe *Decl                   = &null ///< THE instance: explicit spec (representative) or implicit node.
    pub var is_explicit: bool                           = false ///< `decl` is user-written.
    pub var home_fid:    u32                            = 0 ///< TU that first named it; EmitPlan's home.
    /// One per `P impl I` bound of the primary, in bound order, then the
    /// rows of each bound interface's `derives` closure: every witness
    /// specialization this instance's body can name (Compiler/Spec/Witnesses.md#emission).
    /// PROGRAM-WIDE (Compiler/Spec/Interfaces.md#program-wide-rows-per-tu-visibility): the union of what every TU that checked
    /// the instance found, each row once, in first-found order -- TU (DAG)
    /// order, then bound order -- so every TU holding the instance emits the
    /// same rows in the same order (ODR), whichever TU wrote it first or
    /// what that TU imports. Which rows a TU's own Sema may USE is
    /// ConformanceRow::seen_by. Writer: add_rows; `rows_done` says some TU
    /// checked it, so an instance with no bound and one not yet checked are
    /// told apart.
    pub var rows:      cxx::std::vector<unsafe *ConformanceRow>
    pub var rows_done: bool                                     = false
    /// Its bounds failed where it first became live (reported there, once
    /// per build): a later TU's use reports nothing again (Compiler/Spec/Generics.md#instance-diagnostics).
    pub var failed: bool = false
    /// The partial specialization whose BODY an implicit instance takes, or
    /// null for the primary's. `decl`'s `instantiated_from` stays the
    /// primary either way: every reader of that link asks "which template
    /// is this an instance of" (deduction compares it, is_lang and the
    /// tuple tests key on it), and only the table walks want the body --
    /// they ask Sema's body_of, which reads this.
    pub var pattern: unsafe *Decl = &null
    /// Parallel to `pattern`'s generic params: each one's binding for
    /// `args`. `Store<*i32>` against `<P> Store<*P>` is [i32], where `args`
    /// is [*i32]: args are in the PRIMARY's parameter space, so nothing
    /// positional may bind a partial's parameters from them.
    pub var pattern_args: cxx::std::vector<unsafe *Type>
    /// Two partials both match and neither is more specialized: `pattern`
    /// stays null and these name the first two for Sema's diagnostic,
    /// reported once (`ambiguity_reported`) at a naming site.
    pub var ambiguous_a:        unsafe *Decl = &null
    pub var ambiguous_b:        unsafe *Decl = &null
    pub var ambiguity_reported: bool         = false
    /// A partial whose pattern matches but whose `requires` clause this
    /// layer could not decide at these arguments (Compiler/Spec/Generics.md#where-groups-on-generic-functions: a `sizeof`
    /// of a record, an `eval` call): it is not selected, and Sema reports
    /// the instance at a naming site, once (`undecided_reported`), rather
    /// than let C++ pick a body Kairo did not type against.
    pub var undecided:          unsafe *Decl = &null
    pub var undecided_reported: bool         = false
    /// A generic ADT's instance: the layout Sema's niche engine predicts C++
    /// picks (0 unknown, 1 tagged, 2 niche-filled) and its size in bytes (0
    /// unknown). One writer, EnumLayoutQuery::sweep; InterfaceEmitter pins
    /// both with static_asserts beside the instantiation.
    pub var adt_shape: u8  = 0
    pub var adt_size:  u64 = 0
    /// An ADT instance whose pack elements are tagged by type id (the Panic
    /// lang item, Compiler/Spec/Panic.md#canonical-sets): each element's id, and the 64-bit hash of
    /// its C++ spelling that keys its `__kairo_tid` specialization's guard,
    /// in element order. Empty for every other instance. One writer,
    /// EnumLayoutQuery::sweep; InterfaceEmitter writes the specializations.
    pub var type_ids:  cxx::std::vector<u32>
    pub var type_keys: cxx::std::vector<u64>
    /// Each element's Kairo name (`ConfigError`, `i64`), the one the C++
    /// view's `what()` prints (Compiler/Spec/Panic.md#the-c-view): its specialization carries it.
    pub var type_names: cxx::std::vector<string>
    /// Where its payloads start (the union's alignment), 0 unknown.
    pub var payload_offset: u64 = 0
    /// Where such an instance's set was first formed, and in which TU: the
    /// one place its register-cliff remark (Compiler/Spec/Panic.md#layout) is reported.
    /// One writer, the first former (PanicSets::note_formed).
    pub var formed_at:  SourceRange = SourceRange::invalid()
    pub var formed_fid: u32         = u32::MAX
    /// A generic function's (or a generic record's methods') panic facts at
    /// THIS instance (Compiler/Spec/Panic.md#generic-bodies, Compiler/Spec/Generics.md#decisions: by substitution, never by
    /// re-checking the body): `panic_result` the function's `Panic<T, E...>`
    /// at the arguments, canonical (what the explicit instantiation spells
    /// and the C++ alias must agree with, a static_assert pinning it); and
    /// `panic_types` every dependent panic result its body names (its
    /// FunctionDecl::panic_deps), formed here, which EmitPlan admits so their
    /// elements' `__kairo_tid` specializations are written. `panic_done`
    /// once computed (PanicInstances, Sema's M2 stage, in the first TU after
    /// the entry is live); `panic_checked` once its `try` arms were asked
    /// for duplicates at its arguments (PanicEffectChecking).
    pub var panic_result:  unsafe *Type                   = &null
    pub var panic_types:   cxx::std::vector<unsafe *Type>
    pub var panic_done:    bool                           = false
    pub var panic_checked: bool                           = false
    /// Its index in the registry's worklist when it was minted. Not kept up
    /// to date (a later mint can sort before it) and read by nothing; the
    /// order itself is `ord_rank` / `ord_seq`.
    pub var seq: u32 = 0
    /// Its worklist key: the import group (rank) whose Sema first
    /// asked for it in the one-thread order, and that group's request count
    /// at the time. The worklist is sorted by it, and `home_fid` is that
    /// request's, so both are what a one-thread run, which mints in exactly
    /// this order, produces, whichever thread asks first
    /// (Compiler/Spec/Generics.md#m1-enumeration).
    pub var ord_rank: u64 = 0
    pub var ord_seq:  u64 = 0
    /// The key of the request behind `formed_fid` (note_formed), the same
    /// rule: the first former in the one-thread order wins.
    pub var formed_rank: u64 = u64::MAX
    pub var formed_seq:  u64 = u64::MAX
    /// For a foreign shell: the rank of the TU whose demand filled it, and
    /// every registry request the fill made (ForeignInstantiate::fill). A
    /// TU earlier in the order that finds it filled re-requests them, as its
    /// own fill would have (rerequest).
    pub var fill_rank: u64 = u64::MAX
    pub var fill_fid:  i64 = -1       ///< the demanding TU it was filled for.
    /// The fill went through the demanding TU's own header set (its `alt`,
    /// the primary's set could not spell an argument), and which set that
    /// was: only a demander with the same set would have filled it alike.
    pub var fill_alt:      unsafe *void                            = &null
    pub var fill_used_alt: bool                                    = false
    pub var fill_reqs:     cxx::std::vector<unsafe *InstanceEntry>
    pub var fill_req_fids: cxx::std::vector<u32> ///< parallel: the fid each request named.
    /// Minted, Live, or Walked (InstLiveness): Walked once its reach has
    /// been walked (ConformanceChecking::discover), every instance its body
    /// reaches in the registry, linked by `reached`, and bound-checked. Only
    /// a Live entry is ever walked.
    pub var liveness: InstLiveness = InstLiveness::Minted
    /// Live: some use needs it. 1 for an instance a tree names at a use
    /// (ConformanceChecking's instantiation site), the reacher's + 1 for one
    /// only a generic body reaches; 0 for an entry nothing has needed yet --
    /// minted by substitution into a losing overload candidate, say, whose
    /// bounds must not be checked (Compiler/Spec/Generics.md#m1-enumeration: depth is a limit, reported).
    pub var depth: u32 = 0
    /// The use site that made its chain's root live, inherited down the
    /// chain: where every diagnostic about this instance is reported (D6),
    /// and the range an instance minted with none of its own takes (D4).
    pub var use_at: SourceRange = SourceRange::invalid()
    /// The live instance whose body made this one live, and the use in that
    /// body (a call, a type) that did: one hop of the instantiation chain
    /// D6's notes print. Null / invalid at a root. Unlike `reached_by` (the
    /// first reacher, for homing) this is the hop that gave it its depth.
    pub var via:    unsafe *InstanceEntry = &null
    pub var via_at: SourceRange           = SourceRange::invalid()
    /// The instances its body reaches once its arguments are known
    /// (ConformanceChecking's reach: `outer<M>` calling `inner(Wrap<T>
    /// {...})` reaches `inner<Wrap<M>>` and `Wrap<M>`), in reach order,
    /// deduplicated. None of them is named in any TU's tree, so this edge is
    /// how EmitPlan finds them: every plan holding this instance holds these
    /// too, their explicit instantiation in their home and `extern template`
    /// elsewhere. Writer: add_reach, under the lock.
    pub var reached: cxx::std::vector<unsafe *InstanceEntry>
    /// The first instance whose body reached this one, or null (never
    /// reached). The chain diagnostics follow `via` instead: an instance a
    /// tree names is a root whoever reaches it later.
    pub var reached_by: unsafe *InstanceEntry = &null
    fn InstanceEntry(self) { }
}

pub class InstantiationRegistry {
    /// The same PackSetOrder the CanonicalTypeStore holds (one set order for
    /// a type's identity and its entry). Set once by the driver.
    pub var  pack_order: unsafe *PackSetOrder    = &null
    priv var _arena:     ArenaAllocator          = ArenaAllocator(256 * 1024)
    priv var _arena_mu:  kairo::std::Mutex ///< _arena's, a leaf lock (see the file header).
    priv var _mu:        kairo::std::SharedMutex
    /// bucket hash -> entries. Every hit is confirmed by a structural compare.
    /// Keys are _hash's, which keeps clear of DenseMap's reserved values.
    /// Its order means nothing -- hashes of pointers -- so nothing iterates
    /// it for output: collect() reads _order instead.
    priv var _table: llvm::DenseMap<u64, cxx::std::vector<unsafe *InstanceEntry>>
    /// primary -> its partial specializations, in registration order. The
    /// lists live in _partials_arena: partials_of() hands one out, and a
    /// DenseMap rehash would move it.
    priv var _partials:       llvm::DenseMap<u64, unsafe *cxx::std::vector<unsafe *Decl>>
    priv var _partials_arena: llvm::SpecificBumpPtrAllocator<cxx::std::vector<unsafe *Decl>>
    /// implicit node -> the entry it was minted for. An implicit node's own
    /// `spec_args` stay EMPTY (they are the user-written `<...>` of an
    /// explicit spec, and every printer reads them that way), so this is how
    /// a holder of the node alone gets back its args.
    priv var _by_node: llvm::DenseMap<u64, unsafe *InstanceEntry>
    /// The conformance table: hash of (conformer, interface) -> rows. Same
    /// arena and lock as the instances; rows are immutable once added.
    priv var _rows: llvm::DenseMap<u64, cxx::std::vector<unsafe *ConformanceRow>>
    /// The same rows keyed by their conformer alone (canonical, unqualified):
    /// a reader that knows the interface by its DECL, not its type, finds
    /// them here (rows_of: EmitPlan's std::hash adapter, which has the Hash
    /// lang item's decl but no canonical interface type to probe with).
    priv var _rows_by_conformer: llvm::DenseMap<u64, cxx::std::vector<unsafe *ConformanceRow>>
    /// DECLARED rows (`class X impl I`, `extend X impl I`), keyed by the
    /// declaring decl's address: the rows EmitPlan admits where that decl is
    /// emitted, with no Kairo instance to reach them (Compiler/Spec/Witnesses.md#emission). A
    /// row here is also in `_rows` -- the same identity a use finds -- since
    /// `ConformanceRow::declared` is first-writer and a use may build the
    /// row before the declaration is checked.
    priv var _declared: llvm::DenseMap<u64, cxx::std::vector<unsafe *ConformanceRow>>
    /// THE worklist (Compiler/Spec/Generics.md#m1-enumeration): every entry, in mint order. Every mint --
    /// T and X naming one, Deduction::substitute, ConformanceChecking's
    /// reach, the lang records, CallLowering's thunks, foreign -- goes
    /// through _new_entry, which appends here, so nothing can mint around
    /// it. collect() reads this, never the hash table: anything that
    /// iterates the registry gets the same order on every run.
    priv var _order: cxx::std::vector<unsafe *InstanceEntry>
    /// The entries drop_entries took out and sweep_dead has not cleared
    /// yet: a live check's, between a retraction and the moment the
    /// replaced trees are freed.
    priv var _dropped: cxx::std::vector<unsafe *InstanceEntry>
    /// The rows sweep_dead took out of the tables and has not cleared yet.
    priv var _dead_rows: cxx::std::vector<unsafe *ConformanceRow>
    /// When set (FrontendAction::refresh), every mark_live of an entry
    /// that is already live is recorded here with the use that asked: in a
    /// fresh run the FIRST use in the one-thread order owns the entry's
    /// reports, and a re-check has to know when it added an earlier one.
    pub var relive_log: unsafe *cxx::std::vector<unsafe *InstanceEntry> = &null
    pub var relive_at:  unsafe *cxx::std::vector<SourceRange>           = &null
    /// The key of a request made outside any group's Sema (header indexing
    /// before Sema: rank 0; codegen after it: the driver raises the floor),
    /// which keeps such mints in time order around Sema's.
    priv var _floor_rank: u64 = 0
    priv var _floor_seq:  u64 = 0
    priv var _ranks_used: u64 = 0 ///< reserve_ranks

    fn InstantiationRegistry(self) {
        self._arena.shared(unsafe &self._arena_mu)
        self._table.reserve(128)
    }

    /// # Lookup / create

    /// The entry for (primary, args), or null if none was ever named.
    pub fn find(self,
                primary: unsafe *Decl,
                args_in: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *InstanceEntry {
        var        dd    = cxx::std::vector<unsafe *Type>()
        var unsafe *args = self._set_args(primary, args_in, unsafe &dd)
        var        rlock = kairo::std::SharedLock(self._mu)
        return self._probe(self._hash(primary, args), primary, *args)
    }

    /// The entry an IMPLICIT node was minted for, or null (an explicit spec,
    /// or not a registry node at all).
    pub fn entry_of(self, node: unsafe *Decl) -> unsafe *InstanceEntry {
        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._by_node.find(node as usize as u64)
        if it == self._by_node.end() {
            return &null
        }

        return it->second
    }

    /// Get-or-create. On create, mints the implicit instantiation node.
    /// \p ctx is the PRIMARY's context (NameLookup::ctx_of(primary)) -- the
    /// node's names are the primary's names, interned in the primary's TU.
    /// PRE: every arg canonical and non-dependent. Callers that cannot
    /// promise that (T on a dependent use) must not call this.
    pub fn instance_for(self,
                        primary: unsafe *Decl,
                        args_in: unsafe *cxx::std::vector<unsafe *Type>,
                        fid:     u32,
                        ctx:     unsafe *ASTContext) -> unsafe *InstanceEntry {
        if primary == &null || args_in == &null || ctx == &null {
            return &null
        }

        // Every REQUEST reads the pattern's body, not only the one that
        // mints: an instance is checked once, by its first namer, and a later
        // namer in another file depends on that body all the same.
        var unsafe *deps = dep_log_current()
        if deps != &null {
            deps->body(primary as usize as u64)
        }

        var        dd    = cxx::std::vector<unsafe *Type>()
        var unsafe *args = self._set_args(primary, args_in, unsafe &dd)
        var        h     = self._hash(primary, args)

        var lock     = kairo::std::LockGuard(self._mu)
        var kr:  u64 = 0
        var ks:  u64 = 0
        self._mint_key(unsafe &kr, unsafe &ks)
        var unsafe *hit = self._probe(h, primary, *args)
        if hit != &null {
            self._claim(hit, kr, ks, fid)
            return hit
        }

        var unsafe *node = self._new_instance(primary, ctx)
        if node == &null {
            return &null
        }

        var unsafe *e = self._new_entry(primary, *args, node, false, fid, kr, ks)
        self._table[h].push_back(e)
        self._by_node[node as usize as u64] = e
        self._select_into(e)
        return e
    }

    /// Record a user-written EXPLICIT full specialization. Returns the entry
    /// for its args, which the caller inspects:
    ///   entry->decl == spec          fresh; nothing else to do.
    ///   entry->is_explicit, != spec  a second explicit spec for the same
    ///                                args: a redecl chain (fwd + def) or a
    ///                                redefinition -- T links and judges.
    ///   !entry->is_explicit          an implicit node already exists: some
    ///                                use named these args before the spec
    ///                                was seen. T diagnoses.
    pub fn register_explicit(self,
                             primary: unsafe *Decl,
                             args_in: unsafe *cxx::std::vector<unsafe *Type>,
                             spec:    unsafe *Decl,
                             fid:     u32) -> unsafe *InstanceEntry {
        if primary == &null || args_in == &null || spec == &null {
            return &null
        }

        var        dd    = cxx::std::vector<unsafe *Type>()
        var unsafe *args = self._set_args(primary, args_in, unsafe &dd)
        var        h     = self._hash(primary, args)

        var lock     = kairo::std::LockGuard(self._mu)
        var kr:  u64 = 0
        var ks:  u64 = 0
        self._mint_key(unsafe &kr, unsafe &ks)
        var unsafe *hit = self._probe(h, primary, *args)
        if hit != &null {
            self._claim(hit, kr, ks, fid)
            return hit
        }

        var unsafe *e = self._new_entry(primary, *args, spec, true, fid, kr, ks)
        self._table[h].push_back(e)
        return e
    }

    /// After T links a fwd-declared spec to its definition the representative
    /// changes; the entry must point at it BEFORE any RecordType is minted.
    pub fn retarget(self, e: unsafe *InstanceEntry, rep: unsafe *Decl) {
        if e == &null || rep == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        e->decl = rep
    }

    /// # Partial specializations

    /// \p spec is a REPRESENTATIVE: its parameters' GenericParamType owner
    /// is that decl, and matching binds by owner identity. Entries already
    /// minted for \p primary are re-selected: T registers a TU's specs before
    /// it resolves anything else in it, so a re-selection here only ever
    /// moves an instance no body has been typed against yet.
    pub fn register_partial(self, primary: unsafe *Decl, spec: unsafe *Decl) {
        if primary == &null || spec == &null {
            return
        }

        var        lock   = kairo::std::LockGuard(self._mu)
        var unsafe **slot = unsafe &self._partials[primary as usize as u64]
        if *slot == &null {
            var unsafe *v = self._partials_arena.Allocate(1)
            cxx::std::construct_at(v)
            *slot = v
        }

        (*slot)->push_back(spec)
        for var it = self._table.begin(); it != self._table.end(); ++it {
            for var i: usize = 0; i < it->second.size(); ++i {
                var unsafe *e = it->second[i]
                if e->primary == primary && !e->is_explicit {
                    self._select_into(e)
                }
            }
        }
    }

    pub fn partials_of(self, primary: unsafe *Decl) -> unsafe *cxx::std::vector<unsafe *Decl> {
        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._partials.find(primary as usize as u64)
        if it == self._partials.end() {
            return &null
        }

        return it->second
    }

    /// Every user-written specialization of \p primary, partial and
    /// explicit, appended to \p out: partials in registration order, then
    /// the explicit ones in NO defined order (hash order, as collect()).
    /// EmitPlan declares them wherever it declares the primary -- a TU that
    /// sees `Store` but not `Store<bool>` would instantiate the primary for
    /// it, an ODR violation no linker reports.
    pub fn specs_of(self, primary: unsafe *Decl, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        if primary == &null || out == &null {
            return
        }

        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._partials.find(primary as usize as u64)
        if it != self._partials.end() {
            for var i: usize = 0; i < it->second->size(); ++i {
                out->push_back((*it->second)[i])
            }
        }

        for var t = self._table.begin(); t != self._table.end(); ++t {
            for var i: usize = 0; i < t->second.size(); ++i {
                var unsafe *e = t->second[i]
                if e->primary == primary && e->is_explicit {
                    out->push_back(e->decl)
                }
            }
        }
    }

    /// The partial specialization of \p primary that \p args select, with
    /// its parameters' bindings in \p out_args; null for the primary (none
    /// matched, or an ambiguity -- the instance path reports that one).
    /// For a DEPENDENT use (`Store<*P>` as an extension's receiver, a
    /// partial's own Self), which has no entry to cache on: the args'
    /// parameters are opaque here, so `*P` selects `<Q> Store<*Q>` with
    /// Q := P, and a bare `T` selects nothing.
    pub fn select_partial(self,
                          primary:  unsafe *Decl,
                          args:     unsafe *cxx::std::vector<unsafe *Type>,
                          out_args: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *Decl {
        if primary == &null || args == &null {
            return &null
        }

        var rlock              = kairo::std::SharedLock(self._mu)
        var a:    unsafe *Decl = &null
        var b:    unsafe *Decl = &null
        return self._select(primary, args, out_args, unsafe &a, unsafe &b)
    }

    /// ## matching (under the lock; pure: reads canonical types only)

    /// C++ partial-specialization selection, simplified: every partial whose
    /// pattern matches \p args, then the one strictly more specialized than
    /// each other match ([temp.class.order]); two with no order between them
    /// are ambiguous, reported through \p amb_a / \p amb_b. An IMPORTED
    /// primary's instances are clang's to fill, partial included
    /// (ForeignInstantiate), so it never selects here.
    priv fn _select(self,
                    primary:   unsafe *Decl,
                    args:      unsafe *cxx::std::vector<unsafe *Type>,
                    out_args:  unsafe *cxx::std::vector<unsafe *Type>,
                    amb_a:     unsafe *(unsafe *Decl),
                    amb_b:     unsafe *(unsafe *Decl),
                    undecided: unsafe *(unsafe *Decl) = &null) -> unsafe *Decl {
        if decl_is_imported(primary) {
            return &null
        }

        var it = self._partials.find(primary as usize as u64)
        if it == self._partials.end() {
            return &null
        }

        var unsafe *ps  = it->second
        var        hits = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < ps->size(); ++i {
            var binds = cxx::std::vector<unsafe *Type>()
            if !self._matches((*ps)[i], *args, unsafe &binds) {
                continue
            }

            // A `requires`-selected partial (Compiler/Spec/Generics.md#where-groups-on-generic-functions) also needs its
            // clause to hold at the bindings: C++ evaluates the same clause,
            // which the emitted partial carries, so both pick alike.
            var h = self.requires_holds((*ps)[i], unsafe &binds)
            if h == 0 {
                continue
            }

            if h < 0 {
                if undecided != &null && *undecided == &null {
                    *undecided = (*ps)[i]
                }

                continue
            }

            hits.push_back((*ps)[i])
        }

        if hits.size() == 0 {
            return &null
        }

        var best: unsafe *Decl = &null
        for var i: usize = 0; i < hits.size(); ++i {
            var wins = true
            for var j: usize = 0; j < hits.size(); ++j {
                if i == j {
                    continue
                }

                if !self._more_specialized(hits[i], hits[j]) {
                    wins = false
                    break
                }
            }

            if wins {
                best = hits[i]
                break
            }
        }

        if best == &null {
            *amb_a = hits[0]
            *amb_b = hits[1]
            return &null
        }

        if out_args != &null {
            out_args->clear()
            self._matches(best, *args, out_args)
        }

        return best
    }

    /// Under the write lock. Idempotent: a re-selection (register_partial)
    /// overwrites every field it owns.
    priv fn _select_into(self, e: unsafe *InstanceEntry) {
        e->pattern = &null
        e->pattern_args.clear()
        e->ambiguous_a = &null
        e->ambiguous_b = &null
        e->undecided   = &null
        var a: unsafe *Decl = &null
        var b: unsafe *Decl = &null
        var u: unsafe *Decl = &null
        e->pattern = self._select(
            e->primary,
            unsafe &e->args,
            unsafe &e->pattern_args,
            unsafe &a,
            unsafe &b,
            unsafe &u,
        )

        e->ambiguous_a = a
        e->ambiguous_b = b
        // A dependent instance decides nothing; only a concrete one is
        // reported.
        if !self._any_dependent(e->args) {
            e->undecided = u
        }
    }

    /// \p spec's pattern against \p args; \p binds gets one type per
    /// generic param of \p spec, all of them bound or the match fails (a
    /// parameter the pattern never names cannot be deduced, which C++
    /// rejects at the declaration).
    priv fn _matches(self,
                     spec:       unsafe *Decl,
                     const args: cxx::std::vector<unsafe *Type>,
                     binds:      unsafe *cxx::std::vector<unsafe *Type>) -> bool {
        var pat = decl_spec_args(spec)
        if pat.size() != args.size() {
            return false
        }

        var gps = decl_generic_params(spec)
        binds->clear()
        for var i: usize = 0; i < gps.size(); ++i {
            binds->push_back(&null)
        }

        for var i: usize = 0; i < pat.size(); ++i {
            var unsafe *p = pat[i]
            if p == &null || p->canonical == &null {
                return false
            }

            if !self._match(p->canonical, (args)[i], spec, binds) {
                return false
            }
        }

        for var i: usize = 0; i < binds->size(); ++i {
            if (*binds)[i] == &null {
                return false
            }
        }

        return true
    }

    /// \p a is strictly more specialized than \p b: b's pattern matches a's
    /// (a's parameters standing as opaque types) and not the reverse. Two
    /// EQUIVALENT patterns are ordered by their constraints, [temp.constr.
    /// order] simplified to presence (Compiler/Spec/Generics.md#where-groups-on-generic-functions): the one with a
    /// `requires` clause is more specialized than the one without; two
    /// with clauses are unordered (C++ would order them by subsumption of
    /// their atomic constraints, which Kairo does not compute: an ambiguity
    /// here, never a different pick).
    priv fn _more_specialized(self, a: unsafe *Decl, b: unsafe *Decl) -> bool {
        var ba = self._covers(b, a)
        var ab = self._covers(a, b)
        if ba && ab {
            return decl_requires_clause(a) != &null && decl_requires_clause(b) == &null
        }

        return ba && !ab
    }

    priv fn _any_dependent(self, const args: cxx::std::vector<unsafe *Type>) -> bool {
        for var i: usize = 0; i < args.size(); ++i {
            var unsafe *t = (args)[i]
            if t != &null && (t->is_dependent() || t->is_instantiation_dependent()) {
                return true
            }
        }

        return false
    }

    /// ## requires-selected partials (Compiler/Spec/Generics.md#where-groups-on-generic-functions)

    /// \p spec's `requires` clause at \p binds (its parameters' bindings):
    /// 1 holds, 0 does not, -1 undecidable here. No clause: 1. What this
    /// layer decides is pure and lock-free (it runs inside selection):
    /// integer and bool literals; `sizeof` / `alignof` of a builtin, a
    /// pointer, a fixed array of those, or a parameter bound to one;
    /// arithmetic, comparisons, `!`, `&&` / `||` (short-circuit, so a
    /// decided left side settles an undecidable right one). Anything else
    /// -- a record's size, an `eval` call or constant, a conformance -- is
    /// -1, and the partial is not selected.
    fn requires_holds(self,
                      spec:  unsafe *Decl,
                      binds: unsafe *cxx::std::vector<unsafe *Type>) -> i32 {
        var unsafe *rc = decl_requires_clause(spec)
        if rc == &null {
            return 1
        }

        var v = self._pred(rc, spec, binds)
        if !v.known {
            return -1
        }

        return if (v.v != 0) => (1) else => 0
    }

    priv fn _pred(self,
                  e:     unsafe *Expr,
                  spec:  unsafe *Decl,
                  binds: unsafe *cxx::std::vector<unsafe *Type>) -> PartialPredValue {
        var out = PartialPredValue{}
        if e == &null {
            return out
        }

        if isa<ParenExpr>(e) {
            return self._pred(cast<ParenExpr>(e)->inner, spec, binds)
        }

        if isa<BooleanLiteralExpr>(e) {
            out.known = true
            out.v     = if (cast<BooleanLiteralExpr>(e)->value) => (1) else => 0
            return out
        }

        if isa<IntegerLiteralExpr>(e) {
            var unsafe *il = cast<IntegerLiteralExpr>(e)
            if il->get_value_hi() != 0 || il->get_value_lo() > (9223372036854775807 as u64) {
                return out
            }

            out.known = true
            out.v     = (il->get_value_lo() as i64)
            return out
        }

        if isa<SizeOfExpr>(e) || isa<AlignOfExpr>(e) {
            var unsafe *ta = if (isa<SizeOfExpr>(e)) => (cast<SizeOfExpr>(e)->type_arg)
                             else => cast<AlignOfExpr>(e)->type_arg
            if ta == &null || ta->canonical == &null {
                return out
            }

            var sz: u64 = 0
            var al: u64 = 0
            if !self._layout(ta->canonical, spec, binds, unsafe &sz, unsafe &al) {
                return out
            }

            out.known = true
            out.v     = ((if (isa<SizeOfExpr>(e)) => (sz) else => al) as i64)
            return out
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u = cast<UnaryOperatorExpr>(e)
            var        x  = self._pred(u->operand, spec, binds)
            if !x.known {
                return out
            }

            var k = u->op_token.kind
            if k == TokenKind::OpExclaim || k == TokenKind::KwNot {
                out.known = true
                out.v     = if (x.v == 0) => (1) else => 0
                return out
            }

            if k == TokenKind::OpMinus {
                out.known = true
                out.v     = (0 as i64) - x.v
                return out
            }

            if k == TokenKind::OpPlus {
                return x
            }

            return out
        }

        if isa<BinaryOperatorExpr>(e) {
            var unsafe *bn = cast<BinaryOperatorExpr>(e)
            var        k   = bn->op_token.kind
            var        l   = self._pred(bn->lhs, spec, binds)
            if k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd {
                if l.known && l.v == 0 {
                    out.known = true
                    out.v     = 0
                    return out
                }

                var r = self._pred(bn->rhs, spec, binds)
                if r.known && r.v == 0 {
                    out.known = true
                    out.v     = 0
                    return out
                }

                if l.known && r.known {
                    out.known = true
                    out.v     = 1
                }

                return out
            }

            if k == TokenKind::OpPipePipe || k == TokenKind::KwOr {
                if l.known && l.v != 0 {
                    out.known = true
                    out.v     = 1
                    return out
                }

                var r = self._pred(bn->rhs, spec, binds)
                if r.known && r.v != 0 {
                    out.known = true
                    out.v     = 1
                    return out
                }

                if l.known && r.known {
                    out.known = true
                    out.v     = 0
                }

                return out
            }

            var r = self._pred(bn->rhs, spec, binds)
            if !l.known || !r.known {
                return out
            }

            out.known = true
            if k == TokenKind::OpLess {
                out.v = if (l.v < r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpLessEqual {
                out.v = if (l.v <= r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpGreater {
                out.v = if (l.v > r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpGreaterEqual {
                out.v = if (l.v >= r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpEqualEqual {
                out.v = if (l.v == r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpExclaimEqual {
                out.v = if (l.v != r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpPlus {
                out.v = l.v + r.v
                return out
            }

            if k == TokenKind::OpMinus {
                out.v = l.v - r.v
                return out
            }

            if k == TokenKind::OpStar {
                out.v = l.v * r.v
                return out
            }

            if k == TokenKind::OpSlash && r.v != 0 {
                out.v = l.v / r.v
                return out
            }

            if k == TokenKind::OpPercent && r.v != 0 {
                out.v = l.v % r.v
                return out
            }

            out.known = false
            return out
        }

        return out
    }

    /// Size and alignment in bytes of \p t with \p spec's parameters read
    /// through \p binds, for the types whose layout is target arithmetic
    /// only (EnumLayoutQuery::size_of's first rows); false for anything
    /// else, records included.
    priv fn _layout(self,
                    t:     unsafe *Type,
                    spec:  unsafe *Decl,
                    binds: unsafe *cxx::std::vector<unsafe *Type>,
                    size:  unsafe *u64,
                    align: unsafe *u64) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t
        while isa<QualifiedType>(c) {
            c = cast<QualifiedType>(c)->inner
        }

        if isa<GenericParamType>(c) {
            var unsafe *g = cast<GenericParamType>(c)
            if g->owner != spec || g->is_pack || (g->param_index as usize) >= binds->size() {
                return false
            }

            var unsafe *b = (*binds)[g->param_index as usize]
            if b == &null || b->canonical == &null || b->is_dependent() {
                return false
            }

            return self._layout(b->canonical, spec, binds, size, align)
        }

        if isa<FixedArrayType>(c) {
            var unsafe *fa = cast<FixedArrayType>(c)
            if fa->is_incomplete || fa->extent_param != &null {
                return false
            }

            var es: u64 = 0
            var ea: u64 = 0
            if !self._layout(fa->element, spec, binds, unsafe &es, unsafe &ea) {
                return false
            }

            *size  = es * (fa->size_bits as u64)
            *align = ea
            return true
        }

        if isa<BuiltinType>(c) || isa<PointerType>(c) {
            if isa<BuiltinType>(c) && cast<BuiltinType>(c)->lang_decl != &null {
                return false
            }

            if c->size_bits == 0 || c->align_bits == 0 || c->size_bits % 8 != 0 {
                return false
            }

            *size  = ((c->size_bits / 8) as u64)
            *align = ((c->align_bits / 8) as u64)
            return true
        }

        return false
    }

    priv fn _covers(self, general: unsafe *Decl, special: unsafe *Decl) -> bool {
        var sp   = decl_spec_args(special)
        var args = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < sp.size(); ++i {
            if sp[i] == &null || sp[i]->canonical == &null {
                return false
            }

            args.push_back(sp[i]->canonical)
        }

        var binds = cxx::std::vector<unsafe *Type>()
        return self._matches(general, args, unsafe &binds)
    }

    /// Exact structural match, never a conversion: a partial is chosen by
    /// what the argument IS. Canonicals are hash-consed, so a pattern with
    /// no parameter in it matches by identity. A qualifier must match
    /// exactly -- `const P` against `const volatile i32` (C++ would bind
    /// P := volatile i32) needs the type store to build the remainder,
    /// which this layer does not hold, so it is a non-match, never a wrong
    /// binding. A pack parameter never matches: pack patterns are not
    /// selected yet.
    priv fn _match(self,
                   p:     unsafe *Type,
                   a:     unsafe *Type,
                   spec:  unsafe *Decl,
                   binds: unsafe *cxx::std::vector<unsafe *Type>) -> bool {
        if p == &null || a == &null {
            return false
        }

        // Identity settles a concrete pattern only: a dependent one matched
        // against itself (a partial's own Self) must still bind its params.
        if p == a && !p->is_dependent() {
            return true
        }

        if isa<GenericParamType>(p) {
            var unsafe *g = cast<GenericParamType>(p)
            if g->owner == spec && !g->is_pack && (g->param_index as usize) < binds->size() {
                var idx = (g->param_index as usize)
                if (*binds)[idx] == &null {
                    (*binds)[idx] = a
                    return true
                }

                return (*binds)[idx] == a
            }

            return p == a // another template's parameter: only itself.
        }

        if !p->is_dependent() { // concrete and not identical.
            return false
        }

        if p->kind != a->kind {
            return false
        }

        match p->kind {
            case TypeKind::PointerType {
                var unsafe *pp = cast<PointerType>(p)
                var unsafe *ap = cast<PointerType>(a)
                if pp->is_unsafe != ap->is_unsafe {
                    return false
                }

                return self._match(pp->pointee, ap->pointee, spec, binds)
            } case TypeKind::QualifiedType {
                var unsafe *pq = cast<QualifiedType>(p)
                var unsafe *aq = cast<QualifiedType>(a)
                if pq->quals != aq->quals {
                    return false
                }

                return self._match(pq->inner, aq->inner, spec, binds)
            } case TypeKind::NullableType {
                return self._match(
                    cast<NullableType>(p)->inner,
                    cast<NullableType>(a)->inner,
                    spec,
                    binds,
                )
            } case TypeKind::FixedArrayType {
                if p->size_bits != a->size_bits {
                    return false
                }

                // `T[]` and `T[0]` share an extent of 0 and nothing else.
                if cast<FixedArrayType>(p)->is_incomplete != cast<FixedArrayType>(
                    a,
                )->is_incomplete {
                    return false
                }

                return self._match(
                    cast<FixedArrayType>(p)->element,
                    cast<FixedArrayType>(a)->element,
                    spec,
                    binds,
                )
            } case TypeKind::FunctionPointerType {
                var unsafe *pf = cast<FunctionPointerType>(p)
                var unsafe *af = cast<FunctionPointerType>(a)
                if pf->params.size() != af->params.size() {
                    return false
                }

                for var i: usize = 0; i < pf->params.size(); ++i {
                    if pf->modes[i] != af->modes[i] {
                        return false
                    }

                    if !self._match(pf->params[i], af->params[i], spec, binds) {
                        return false
                    }
                }

                if pf->return_type == &null || af->return_type == &null {
                    return pf->return_type == af->return_type
                }

                return self._match(pf->return_type, af->return_type, spec, binds)
            } case TypeKind::RecordType {
                // `Box<P>` against `Box<i32>`: the same template (an instance
                // node and an explicit spec both lead back to the primary),
                // then argument by argument.
                var unsafe *pr = cast<RecordType>(p)
                var unsafe *ar = cast<RecordType>(a)
                if decl_pattern(pr->decl) != decl_pattern(ar->decl) {
                    return false
                }

                if pr->args.size() != ar->args.size() {
                    return false
                }

                for var i: usize = 0; i < pr->args.size(); ++i {
                    if !self._match(pr->args[i], ar->args[i], spec, binds) {
                        return false
                    }
                }

                return true
            } default {
                return false
            }
        }
    }

    /// # Conformance rows

    /// The row for (\p conformer, \p iface), or null if none was recorded.
    pub fn row_find(self, conformer: unsafe *Type, iface: unsafe *Type) -> unsafe *ConformanceRow {
        var rlock = kairo::std::SharedLock(self._mu)
        return self._row_probe(conformer, iface)
    }

    /// Record \p r (built by the caller, outside the lock) unless a row for
    /// its key already exists; either way returns THE row for the key, so
    /// two TUs that both built one agree on a single identity.
    pub fn row_add(self, r: unsafe *ConformanceRow) -> unsafe *ConformanceRow {
        if r == &null {
            return &null
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._row_probe(r->conformer, r->iface)
        if hit != &null {
            return hit
        }

        var unsafe *row = self._row_copy(r)
        self._rows[self._row_hash(r->conformer, r->iface)].push_back(row)
        self._rows_by_conformer[self._conformer_hash(r->conformer)].push_back(row)
        return row
    }

    /// Every table row whose conformer is \p conformer (canonically, either
    /// side unqualified), in the order they were added, appended to \p out.
    pub fn rows_of(self,
                   conformer: unsafe *Type,
                   out:       unsafe *cxx::std::vector<unsafe *ConformanceRow>) {
        if conformer == &null || out == &null {
            return
        }

        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._rows_by_conformer.find(self._conformer_hash(conformer))
        if it == self._rows_by_conformer.end() {
            return
        }

        var unsafe *want = canon_unqual(conformer)
        for var i: usize = 0; i < it->second.size(); ++i {
            if canon_unqual(it->second[i]->conformer) == want {
                out->push_back(it->second[i])
            }
        }
    }

    /// A copy of \p r that is NOT recorded: one TU's requirement match that
    /// must not become the table's row (it failed, or it clashes with the
    /// table's; ConformanceRow::hidden / clash). Lives as long as the table.
    pub fn row_detached(self, r: unsafe *ConformanceRow) -> unsafe *ConformanceRow {
        if r == &null {
            return &null
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *row = self._row_copy(r)
        row->hidden = r->hidden
        row->clash  = r->clash
        return row
    }

    /// \p row is usable in TU \p fid (ConformanceRow::seen_by), once.
    pub fn row_mark_visible(self, row: unsafe *ConformanceRow, fid: u32) {
        if row == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        for var i: usize = 0; i < row->seen_by.size(); ++i {
            if row->seen_by[i] == fid {
                return
            }
        }

        row->seen_by.push_back(fid)
    }

    /// TU \p fid is already known to be able to use \p row.
    pub fn row_visible_in(self, row: unsafe *ConformanceRow, fid: u32) -> bool {
        if row == &null {
            return false
        }

        var rlock = kairo::std::SharedLock(self._mu)
        for var i: usize = 0; i < row->seen_by.size(); ++i {
            if row->seen_by[i] == fid {
                return true
            }
        }

        return false
    }

    /// Caller holds the lock.
    priv fn _row_copy(self, r: unsafe *ConformanceRow) -> unsafe *ConformanceRow {
        var mem: unsafe *void = self._arena.alloc(sizeof(ConformanceRow), alignof(ConformanceRow))
        var unsafe *row = kairo::construct_at<ConformanceRow>(mem)
        row->conformer  = r->conformer
        row->iface      = r->iface
        row->iface_decl = r->iface_decl
        row->declared   = r->declared
        row->covered_by = r->covered_by
        row->ok         = r->ok
        for var i: usize = 0; i < r->witnesses.size(); ++i {
            row->witnesses.push_back(r->witnesses[i])
        }

        for var i: usize = 0; i < r->reqs.size(); ++i {
            row->reqs.push_back(r->reqs[i])
        }

        for var i: usize = 0; i < r->ext_args.size(); ++i {
            row->ext_args.push_back(r->ext_args[i])
        }

        for var i: usize = 0; i < r->ext_arg_count.size(); ++i {
            row->ext_arg_count.push_back(r->ext_arg_count[i])
        }

        for var i: usize = 0; i < r->sources.size(); ++i {
            row->sources.push_back(r->sources[i])
        }

        for var i: usize = 0; i < r->seen_by.size(); ++i {
            row->seen_by.push_back(r->seen_by[i])
        }

        for var i: usize = 0; i < r->assoc_types.size(); ++i {
            row->assoc_types.push_back(r->assoc_types[i])
        }

        for var i: usize = 0; i < r->assoc_rows.size(); ++i {
            row->assoc_rows.push_back(r->assoc_rows[i])
        }

        return row
    }

    /// Record \p row as declared by \p by. Once per pair: a decl's TU
    /// checks it once, but a re-run must not double the list.
    pub fn declare_row(self, by: unsafe *Decl, row: unsafe *ConformanceRow) {
        if by == &null || row == &null {
            return
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *l   = unsafe &self._declared[by as usize as u64]
        for var i: usize = 0; i < l->size(); ++i {
            if (*l)[i] == row {
                return
            }
        }

        l->push_back(row)
    }

    /// The rows \p by declared, in declaration order, appended to \p out.
    pub fn declared_rows(self,
                         by:  unsafe *Decl,
                         out: unsafe *cxx::std::vector<unsafe *ConformanceRow>) {
        if by == &null || out == &null {
            return
        }

        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._declared.find(by as usize as u64)
        if it == self._declared.end() {
            return
        }

        for var i: usize = 0; i < it->second.size(); ++i {
            out->push_back(it->second[i])
        }
    }

    /// \p inner is reached by \p outer's body (ConformanceChecking's reach).
    /// Once per pair; \p inner keeps its first reacher. An instance that
    /// reaches itself (`f<T>` calling `f<T>`) records nothing.
    pub fn add_reach(self, outer: unsafe *InstanceEntry, inner: unsafe *InstanceEntry) {
        if outer == &null || inner == &null || outer == inner {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        for var i: usize = 0; i < outer->reached.size(); ++i {
            if outer->reached[i] == inner {
                return
            }
        }

        outer->reached.push_back(inner)
        if inner->reached_by == &null {
            inner->reached_by = outer
        }
    }

    /// \p e's reached instances, in reach order, appended to \p out. A copy:
    /// a later TU's reach may still append to the entry's own list.
    pub fn reached_of(self,
                      e:   unsafe *InstanceEntry,
                      out: unsafe *cxx::std::vector<unsafe *InstanceEntry>) {
        if e == &null || out == &null {
            return
        }

        var rlock = kairo::std::SharedLock(self._mu)
        for var i: usize = 0; i < e->reached.size(); ++i {
            out->push_back(e->reached[i])
        }
    }

    /// Union \p rows, what one TU's check of \p e found, into its
    /// program-wide list (InstanceEntry::rows, Compiler/Spec/Interfaces.md#program-wide-rows-per-tu-visibility): each row once,
    /// a new one after every earlier one, so the order is first-found order
    /// and the same on every run. Never a first-writer: a TU that checks
    /// the instance after another adds what it found, however it differs.
    pub fn add_rows(self,
                    e:    unsafe *InstanceEntry,
                    rows: unsafe *cxx::std::vector<unsafe *ConformanceRow>) {
        if e == &null || rows == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        for var i: usize = 0; i < rows->size(); ++i {
            var unsafe *r   = (*rows)[i]
            var        have = false
            for var k: usize = 0; k < e->rows.size(); ++k {
                if e->rows[k] == r {
                    have = true
                    break
                }
            }

            if !have {
                e->rows.push_back(r)
            }
        }

        e->rows_done = true
    }

    /// \brief Take \p l for \p e: true to the first caller only, which then
    ///        does the work the latch guards (reports, computes). The only
    ///        writer of the four latches, bar Retract's live-check re-arm,
    ///        which runs with the pool quiescent.
    ///
    /// \details A shared probe first: after the first TU every caller finds
    ///          the latch set, and the panic sweeps ask once per entry per
    ///          TU, so they should not queue on the exclusive lock.
    pub fn claim(self, e: unsafe *InstanceEntry, l: InstanceLatch) -> bool {
        if e == &null {
            return false
        }

        if self._latched(e, l) {
            return false
        }

        var lock = kairo::std::LockGuard(self._mu)
        var unsafe *bit = self._latch(e, l)
        if *bit {
            return false
        }

        *bit = true
        return true
    }

    priv fn _latched(self, e: unsafe *InstanceEntry, l: InstanceLatch) -> bool {
        var rlock = kairo::std::SharedLock(self._mu)
        return *self._latch(e, l)
    }

    priv fn _latch(self, e: unsafe *InstanceEntry, l: InstanceLatch) -> unsafe *bool {
        match l {
            case InstanceLatch::Ambiguity {
                return unsafe &e->ambiguity_reported
            } case InstanceLatch::Undecided {
                return unsafe &e->undecided_reported
            } case InstanceLatch::PanicChecked {
                return unsafe &e->panic_checked
            } case InstanceLatch::PanicDone {
                return unsafe &e->panic_done
            }
        }

        return unsafe &e->panic_done
    }

    pub fn mark_failed(self, e: unsafe *InstanceEntry) {
        if e == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        e->failed = true
    }

    /// ## a live check's sweep (Tooling/LiveCheck.k, before it frees trees)

    /// The nodes minted for the entries drop_entries took out since the
    /// last sweep_dead: dead with them, and still in this arena.
    pub fn dead_shells(self, out: unsafe *llvm::DenseSet<u64>) {
        var lock = kairo::std::LockGuard(self._mu)
        for var i: usize = 0; i < self._dropped.size(); ++i {
            var unsafe *e = self._dropped[i]
            if e->decl != &null && e->decl != e->primary && !e->is_explicit {
                out->insert(e->decl as usize as u64)
            }
        }
    }

    priv fn _decl_dead(self, d: unsafe *Decl, dead: unsafe *kairo::AddrRanges, shells: unsafe *llvm::DenseSet<u64>) -> bool {
        return d != &null && (dead->has(unsafe (d as unsafe *const void)) || shells->contains(d as usize as u64))
    }

    priv fn _row_dead(self,
                      r:      unsafe *ConformanceRow,
                      dead:   unsafe *kairo::AddrRanges,
                      types:  unsafe *llvm::DenseSet<u64>,
                      shells: unsafe *llvm::DenseSet<u64>,
                      rows:   unsafe *llvm::DenseSet<u64>) -> bool {
        if types->contains(r->conformer as usize as u64) || types->contains(r->iface as usize as u64) {
            return true
        }

        if self._decl_dead(r->iface_decl, dead, shells) || self._decl_dead(r->declared, dead, shells) || self._decl_dead(r->hidden, dead, shells) {
            return true
        }

        for var i: usize = 0; i < r->witnesses.size(); ++i {
            if self._decl_dead(r->witnesses[i], dead, shells) {
                return true
            }
        }

        for var i: usize = 0; i < r->reqs.size(); ++i {
            if self._decl_dead(r->reqs[i], dead, shells) {
                return true
            }
        }

        for var i: usize = 0; i < r->ext_args.size(); ++i {
            if types->contains(r->ext_args[i] as usize as u64) {
                return true
            }
        }

        for var i: usize = 0; i < r->sources.size(); ++i {
            if types->contains(r->sources[i] as usize as u64) {
                return true
            }
        }

        for var i: usize = 0; i < r->assoc_types.size(); ++i {
            if types->contains(r->assoc_types[i] as usize as u64) {
                return true
            }
        }

        for var i: usize = 0; i < r->assoc_rows.size(); ++i {
            if rows->contains(r->assoc_rows[i] as usize as u64) {
                return true
            }
        }

        return (r->covered_by != &null && rows->contains(r->covered_by as usize as u64)) || (r->clash != &null && rows->contains(r->clash as usize as u64))
    }

    priv fn _rows_filter(self, l: unsafe *cxx::std::vector<unsafe *ConformanceRow>, rows: unsafe *llvm::DenseSet<u64>) {
        var b = cxx::std::vector<unsafe *ConformanceRow>()
        for var k: usize = 0; k < l->size(); ++k {
            if !rows->contains((*l)[k] as usize as u64) {
                b.push_back((*l)[k])
            }
        }

        if b.size() != l->size() {
            *l = b
        }
    }

    /// \brief takes out of the conformance tables every row that names
    ///        something of a dead tree (\p dead: its address ranges; \p
    ///        types: the canonicals CanonicalTypeStore::sweep took out; the
    ///        dropped entries' nodes) or another such row, and clears what
    ///        the dropped entries and their nodes still point at. Returns
    ///        how many rows went.
    ///
    /// \details A row holds the declarations that implement a conformance;
    ///          the declared rows are keyed by the declaring declaration's
    ///          address. A file whose `impl` is re-read declares its rows
    ///          again; a freed tree's row would be read at a freed address,
    ///          and its key met by a new declaration.
    ///
    /// \param rows_only  a retraction's call (\p dead: the trees about to be
    ///                   re-read, still allocated): the rows leave the
    ///                   tables, so the re-check builds them from the new
    ///                   text, and nothing is cleared yet (a queued file's
    ///                   old tree may hold one until its turn).
    pub fn sweep_dead(self, dead: unsafe *kairo::AddrRanges, types: unsafe *llvm::DenseSet<u64>, rows_only: bool) -> usize {
        var lock   = kairo::std::LockGuard(self._mu)
        var shells = llvm::DenseSet<u64>()
        for var i: usize = 0; i < self._dropped.size(); ++i {
            var unsafe *e = self._dropped[i]
            if e->decl != &null && e->decl != e->primary && !e->is_explicit {
                shells.insert(e->decl as usize as u64)
            }
        }

        // Every row any list holds, once.
        var all  = cxx::std::vector<unsafe *ConformanceRow>()
        var seen = llvm::DenseSet<u64>()
        for var it = self._rows.begin(); it != self._rows.end(); ++it {
            for var k: usize = 0; k < it->second.size(); ++k {
                if seen.insert(it->second[k] as usize as u64).second {
                    all.push_back(it->second[k])
                }
            }
        }

        for var it = self._declared.begin(); it != self._declared.end(); ++it {
            for var k: usize = 0; k < it->second.size(); ++k {
                if seen.insert(it->second[k] as usize as u64).second {
                    all.push_back(it->second[k])
                }
            }
        }

        for var i: usize = 0; i < self._order.size(); ++i {
            for var k: usize = 0; k < self._order[i]->rows.size(); ++k {
                if seen.insert(self._order[i]->rows[k] as usize as u64).second {
                    all.push_back(self._order[i]->rows[k])
                }
            }
        }

        var rows = llvm::DenseSet<u64>()
        var grew = true
        while grew {
            grew = false
            for var i: usize = 0; i < all.size(); ++i {
                if rows.contains(all[i] as usize as u64) {
                    continue
                }

                if self._row_dead(all[i], dead, types, unsafe &shells, unsafe &rows) {
                    rows.insert(all[i] as usize as u64)
                    grew = true
                }
            }
        }

        if !rows.empty() {
            for var it = self._rows.begin(); it != self._rows.end(); ++it {
                self._rows_filter(unsafe &it->second, unsafe &rows)
            }

            for var it = self._rows_by_conformer.begin(); it != self._rows_by_conformer.end(); ++it {
                self._rows_filter(unsafe &it->second, unsafe &rows)
            }

            for var it = self._declared.begin(); it != self._declared.end(); ++it {
                self._rows_filter(unsafe &it->second, unsafe &rows)
            }

            for var i: usize = 0; i < self._order.size(); ++i {
                self._rows_filter(unsafe &self._order[i]->rows, unsafe &rows)
            }
        }

        // A declared list is keyed by the declaring declaration's address.
        var keys = cxx::std::vector<u64>()
        for var it = self._declared.begin(); it != self._declared.end(); ++it {
            if dead->has(unsafe ((it->first as usize) as unsafe *const void)) || shells.contains(it->first) {
                keys.push_back(it->first)
            }
        }

        for var i: usize = 0; i < keys.size(); ++i {
            self._declared.erase(keys[i])
        }

        for var i: usize = 0; i < all.size(); ++i {
            if rows.contains(all[i] as usize as u64) {
                self._dead_rows.push_back(all[i])
            }
        }

        if rows_only {
            return rows.size() as usize
        }

        var nrows = self._dead_rows.size()
        for var i: usize = 0; i < self._dead_rows.size(); ++i {
            var unsafe *r = self._dead_rows[i]
            r->iface_decl = &null
            r->declared   = &null
            r->hidden     = &null
            r->covered_by = &null
            r->clash      = &null
            r->witnesses.clear()
            r->reqs.clear()
            r->assoc_rows.clear()
            r->ok = false
        }

        // The dropped entries and their nodes: unreachable, and what they
        // name is about to be freed.
        for var i: usize = 0; i < self._dropped.size(); ++i {
            var unsafe *e = self._dropped[i]
            if e->decl != &null && e->decl != e->primary && !e->is_explicit {
                e->decl->lexical_dc  = &null
                e->decl->semantic_dc = &null
            }

            e->primary     = &null
            e->pattern     = &null
            e->ambiguous_a = &null
            e->ambiguous_b = &null
            e->undecided   = &null
            e->via         = &null
            e->reached_by  = &null
            e->rows.clear()
            e->reached.clear()
            e->fill_reqs.clear()
            e->fill_req_fids.clear()
        }

        self._dropped.clear()
        self._dead_rows.clear()
        return nrows
    }

    /// The arena's blocks, into \p out under \p label.
    pub fn ranges_into(self, out: unsafe *kairo::AddrRanges, label: u32) {
        var lock = kairo::std::LockGuard(self._arena_mu)
        self._arena.ranges_into(out, label)
    }

    /// \brief removes \p dead from the registry: the table, the node map,
    ///        the worklist, and every surviving entry's links to them.
    ///
    /// \details For a live check that re-reads the files those entries
    ///          name (Sema/Incremental/Retract.k). The entries and their
    ///          nodes stay allocated in the registry's arena: an address
    ///          handed out again could be met by a stale key.
    pub fn drop_entries(self, dead: *cxx::std::vector<unsafe *InstanceEntry>) {
        if dead->empty() {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        var gone = llvm::DenseSet<u64>()
        for var i: usize = 0; i < dead->size(); ++i {
            self._dropped.push_back((*dead)[i])
            gone.insert((*dead)[i] as usize as u64)
            // Only its own node: a function template's entries share the
            // template's declaration, which may map to a kept entry.
            if (*dead)[i]->decl != &null {
                var nit = self._by_node.find((*dead)[i]->decl as usize as u64)
                if nit != self._by_node.end() && nit->second == (*dead)[i] {
                    self._by_node.erase(nit)
                }
            }
        }

        var kept = cxx::std::vector<unsafe *InstanceEntry>()
        for var i: usize = 0; i < self._order.size(); ++i {
            var unsafe *e = self._order[i]
            if gone.contains(e as usize as u64) {
                continue
            }

            kept.push_back(e)
            if e->via != &null && gone.contains(e->via as usize as u64) {
                e->via = &null
            }

            if e->reached_by != &null && gone.contains(e->reached_by as usize as u64) {
                e->reached_by = &null
            }

            var r = cxx::std::vector<unsafe *InstanceEntry>()
            for var k: usize = 0; k < e->reached.size(); ++k {
                if !gone.contains(e->reached[k] as usize as u64) {
                    r.push_back(e->reached[k])
                }
            }

            if r.size() != e->reached.size() {
                e->reached = r
            }

            // What a kept shell's fill asked for: a dropped request is not
            // asked for again (rerequest would put it back on the worklist).
            var fq = cxx::std::vector<unsafe *InstanceEntry>()
            var ff = cxx::std::vector<u32>()
            for var k: usize = 0; k < e->fill_reqs.size(); ++k {
                if !gone.contains(e->fill_reqs[k] as usize as u64) {
                    fq.push_back(e->fill_reqs[k])
                    if k < e->fill_req_fids.size() {
                        ff.push_back(e->fill_req_fids[k])
                    }
                }
            }

            if fq.size() != e->fill_reqs.size() {
                e->fill_reqs     = fq
                e->fill_req_fids = ff
            }
        }

        self._order = kept
        for var it = self._table.begin(); it != self._table.end(); ++it {
            var b = cxx::std::vector<unsafe *InstanceEntry>()
            for var k: usize = 0; k < it->second.size(); ++k {
                if !gone.contains(it->second[k] as usize as u64) {
                    b.push_back(it->second[k])
                }
            }

            if b.size() != it->second.size() {
                it->second = b
            }
        }
    }

    /// # Enumeration (M1 / EmitPlan)

    /// Every entry, in worklist (mint) order: deterministic, though not
    /// sorted -- an output that must not move when an unrelated TU mints
    /// first (EmitPlan's tier 3, a golden dump) still sorts by its own key.
    pub fn collect(self, @inout out: cxx::std::vector<unsafe *InstanceEntry>) {
        var rlock = kairo::std::SharedLock(self._mu)
        for var i: usize = 0; i < self._order.size(); ++i {
            out.push_back(self._order[i])
        }
    }

    /// collect(), stopping at the first entry keyed after \p rank: the
    /// entries a one-thread run holds when the group of \p rank asks
    /// (`_order` is sorted by key). Past it are only later groups' mints,
    /// whose fronts may be running beside the caller. u64::MAX is collect().
    pub fn collect_upto(self, rank: u64, @inout out: cxx::std::vector<unsafe *InstanceEntry>) {
        var rlock = kairo::std::SharedLock(self._mu)
        for var i: usize = 0; i < self._order.size(); ++i {
            if self._order[i]->ord_rank > rank {
                break
            }

            out.push_back(self._order[i])
        }
    }

    fn size(self) -> usize {
        var rlock = kairo::std::SharedLock(self._mu)
        return self._order.size()
    }

    /// A use at \p at of \p e, which is live already: nothing to do in a
    /// run, and what a live check's re-check records (relive_log).
    pub fn note_reuse(self, e: unsafe *InstanceEntry, at: SourceRange) {
        if self.relive_log == &null || e == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        self.relive_log->push_back(e)
        self.relive_at->push_back(at)
    }

    /// Make \p e live at depth 1, used at \p at (\p via null), or one hop
    /// below live \p via, through the use \p via_at in its body. Once: the
    /// first need fixes the depth, the range and the hop. True when it was
    /// not live before.
    pub fn mark_live(self,
                     e:      unsafe *InstanceEntry,
                     at:     SourceRange,
                     via:    unsafe *InstanceEntry,
                     via_at: SourceRange) -> bool {
        if e == &null {
            return false
        }

        var lock = kairo::std::LockGuard(self._mu)
        if e->depth > 0 {
            // A live check asks which already-live entries a re-check
            // used, and from where (relive_log).
            if self.relive_log != &null {
                self.relive_log->push_back(e)
                self.relive_at->push_back(if (via != &null) => (via->use_at) else => at)
            }

            return false
        }

        e->use_at = at
        e->depth  = 1
        if via != &null {
            e->use_at = via->use_at
            e->depth  = via->depth + 1
            e->via    = via
            e->via_at = via_at
        }

        e->liveness = InstLiveness::Live
        self._check_live(e)
        return true
    }

    /// THE worklist's next batch (Compiler/Spec/Generics.md#m1-enumeration): every live entry whose reach
    /// is not walked yet, in mint order, appended to \p out. Walking a batch
    /// makes more entries live -- minted at the end of the order, or older
    /// ones newly needed -- and they come back on the next call, so draining
    /// until this yields nothing is the discovery fixpoint. Deterministic:
    /// liveness and the order are both functions of the input.
    pub fn drain(self, out: unsafe *cxx::std::vector<unsafe *InstanceEntry>) {
        if out == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        // A scan, not a cursor: an entry minted long ago (by T, by a losing
        // candidate) may become live only now, in a later TU.
        for var i: usize = 0; i < self._order.size(); ++i {
            var unsafe *e = self._order[i]
            self._check_live(e)
            if e->liveness == InstLiveness::Live {
                out->push_back(e)
            }
        }
    }

    pub fn set_checked(self, e: unsafe *InstanceEntry) {
        if e == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        // Only from Live, as `checked` was only ever set on a live entry:
        // drain hands out Live ones, and _check_bounds runs on one mark_live
        // just made live.
        e->liveness = InstLiveness::Walked
        self._check_live(e)
    }

    /// Debug: the liveness byte and the chain length agree. Under the lock,
    /// or with nothing else in flight.
    priv fn _check_live(self, e: unsafe *InstanceEntry) {
        eval if defined!(DEBUG) {
            if (e->depth == 0) != (e->liveness == InstLiveness::Minted) {
                kairo::std::ice_fail(r"InstantiationRegistry: an entry's liveness and depth disagree")
            }
        }
    }

    /// # Internals

    priv fn _hash(self,
                  primary: unsafe *Decl,
                  args:    unsafe *cxx::std::vector<unsafe *Type>) -> u64 {
        var h        = canon_hash_ptr(0, unsafe (primary as unsafe *void))
        var n: usize = 0
        if args != &null {
            n = args->size()
        }

        h = canon_hash_u64(h, n as u64)
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, unsafe ((*args)[i] as unsafe *void))
        }

        // Top bit cleared: the mix reaches every u64, including the ~0 / ~0-1
        // DenseMap reserves for empty / tombstone (assert in debug, silent
        // corruption in release). The bucket compares args, so the extra
        // collision this folds in costs one comparison, never correctness.
        return h >> 1
    }

    priv fn _row_hash(self, conformer: unsafe *Type, iface: unsafe *Type) -> u64 {
        var h = canon_hash_ptr(0, unsafe (conformer as unsafe *void))
        h = canon_hash_ptr(h, unsafe (iface as unsafe *void))
        return h >> 1 // clear of DenseMap's reserved keys, as _hash.
    }

    priv fn _conformer_hash(self, conformer: unsafe *Type) -> u64 {
        return canon_hash_ptr(0, unsafe (canon_unqual(conformer) as unsafe *void)) >> 1 // as _row_hash.
    }

    /// Under the lock (either mode).
    priv fn _row_probe(self,
                       conformer: unsafe *Type,
                       iface:     unsafe *Type) -> unsafe *ConformanceRow {
        var it = self._rows.find(self._row_hash(conformer, iface))
        if it == self._rows.end() {
            return &null
        }

        for var i: usize = 0; i < it->second.size(); ++i {
            var unsafe *r = it->second[i]
            if r->conformer == conformer && r->iface == iface {
                return r
            }
        }

        return &null
    }

    /// \p args with an expanded enum pack's duplicates gone
    /// (decl_dedup_pack_args), in \p scratch when anything was dropped.
    priv fn _set_args(self,
                      primary: unsafe *Decl,
                      args:    unsafe *cxx::std::vector<unsafe *Type>,
                      scratch: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *cxx::std::vector<unsafe *Type> {
        if args == &null || decl_pack_set_at(primary) == usize::MAX {
            return args
        }

        for var i: usize = 0; i < args->size(); ++i {
            scratch->push_back((*args)[i])
        }

        decl_dedup_pack_args(primary, scratch, self.pack_order)
        return scratch // fewer, or reordered (PackSetOrder).
    }

    /// Under the lock (either mode).
    priv fn _probe(self,
                   h:          u64,
                   primary:    unsafe *Decl,
                   const args: cxx::std::vector<unsafe *Type>) -> unsafe *InstanceEntry {
        var it = self._table.find(h)
        if it == self._table.end() {
            return &null
        }

        var unsafe *b = unsafe &it->second
        var        n  = args.size()
        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *e = (*b)[i]
            if e->primary != primary {
                continue
            }

            if e->args.size() != n {
                continue
            }

            var same = true
            for var j: usize = 0; j < n; ++j {
                if e->args[j] != (args)[j] {
                    same = false
                    break
                }
            }

            if same {
                return e
            }
        }

        return &null
    }

    priv fn _new_entry(self,
                       primary:     unsafe *Decl,
                       const args:  cxx::std::vector<unsafe *Type>,
                       decl:        unsafe *Decl,
                       is_explicit: bool,
                       fid:         u32,
                       kr:          u64,
                       ks:          u64) -> unsafe *InstanceEntry {
        var mem: unsafe *void = self._arena.alloc(sizeof(InstanceEntry), alignof(InstanceEntry))
        var unsafe *e = kairo::construct_at<InstanceEntry>(mem)
        e->primary     = primary
        e->decl        = decl
        e->is_explicit = is_explicit
        e->home_fid    = fid
        e->ord_rank    = kr
        e->ord_seq     = ks
        for var i: usize = 0; i < args.size(); ++i {
            e->args.push_back((args)[i])
        }

        // Every caller holds the lock: the worklist insert is the mint.
        self._insert_ordered(e)
        self._record(e, fid)
        return e
    }

    /// # Order
    ///
    /// The worklist and the homes must be the one-thread run's: the M1 walk
    /// drains in worklist order, EmitPlan writes an instance's explicit
    /// instantiation in its home, and the driver runs the typed checks of
    /// TUs that do not import each other side by side. So every request
    /// carries a key, (the requesting group's rank in import order, that
    /// group's request count), which orders requests exactly as a one-thread
    /// run makes them; the entry keeps the smallest key any request had, and
    /// the home that request named. A one-thread run's first request is the
    /// smallest key, so this changes nothing there.

    /// The key of a request from the calling thread. Under the lock.
    priv fn _mint_key(self, kr: unsafe *u64, ks: unsafe *u64) {
        var        r  = *kairo::sema_mint_rank()
        var unsafe *c = *kairo::sema_mint_counter()
        if r == u64::MAX || c == &null {
            self._floor_seq += 1
            *kr = self._floor_rank
            *ks = self._floor_seq
            return
        }

        *c += 1
        *kr = r
        *ks = *c
    }

    priv fn _key_less(ar: u64, as_: u64, br: u64, bs: u64) -> bool {
        if ar != br {
            return ar < br
        }

        return as_ < bs
    }

    /// A request for \p e that came earlier in the one-thread order than
    /// the one that minted it takes it over: its key, its home. Under the lock.
    priv fn _claim(self, e: unsafe *InstanceEntry, kr: u64, ks: u64, fid: u32) {
        self._record(e, fid)
        if !Self::_key_less(kr, ks, e->ord_rank, e->ord_seq) {
            return
        }

        var at = self._find_ordered(e)
        if at < self._order.size() {
            for var i: usize = at; i + 1 < self._order.size(); ++i {
                self._order[i] = self._order[i + 1]
            }

            self._order.pop_back()
        }

        e->ord_rank = kr
        e->ord_seq  = ks
        e->home_fid = fid
        self._insert_ordered(e)
    }

    /// Insert \p e at its key's place. Almost always the end: requests come
    /// in order but for the groups running beside each other.
    priv fn _insert_ordered(self, e: unsafe *InstanceEntry) {
        var hi        = self._order.size()
        var lo: usize = 0
        if hi == 0
            || !Self::_key_less(
                e->ord_rank,
                e->ord_seq,
                self._order[hi - 1]->ord_rank,
                self._order[hi - 1]->ord_seq,
            ) {
            e->seq = (hi as u32)
            self._order.push_back(e)
            return
        }

        while lo < hi {
            var        mid = lo + (hi - lo) / 2
            var unsafe *m  = self._order[mid]
            if Self::_key_less(m->ord_rank, m->ord_seq, e->ord_rank, e->ord_seq) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        e->seq = (lo as u32)
        self._order.push_back(e)
        for var i: usize = self._order.size() - 1; i > lo; --i {
            self._order[i] = self._order[i - 1]
        }

        self._order[lo] = e
    }

    /// \p e's index in the worklist, by its key; size() if absent.
    priv fn _find_ordered(self, e: unsafe *InstanceEntry) -> usize {
        var lo: usize = 0
        var hi        = self._order.size()
        while lo < hi {
            var        mid = lo + (hi - lo) / 2
            var unsafe *m  = self._order[mid]
            if Self::_key_less(m->ord_rank, m->ord_seq, e->ord_rank, e->ord_seq) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        for var i: usize = lo; i < self._order.size(); ++i {
            if self._order[i] == e {
                return i
            }

            if Self::_key_less(
                e->ord_rank,
                e->ord_seq,
                self._order[i]->ord_rank,
                self._order[i]->ord_seq,
            ) {
                break
            }
        }

        return self._order.size()
    }

    /// A request made while this thread fills a foreign shell joins that
    /// fill's list (InstanceEntry::fill_reqs). Under the lock.
    priv fn _record(self, e: unsafe *InstanceEntry, fid: u32) {
        var unsafe *rec = *kairo::sema_fill_record()
        if rec == &null {
            return
        }

        var unsafe *shell = unsafe (rec as unsafe *InstanceEntry)
        shell->fill_reqs.push_back(e)
        shell->fill_req_fids.push_back(fid)
    }

    /// Mints from here on, outside any group's Sema, key after every
    /// group's so far (the driver, once an action's Sema is done).
    pub fn set_floor_rank(self, r: u64) {
        var lock = kairo::std::LockGuard(self._mu)
        self._floor_rank = r
    }

    /// Ranks for one action's \p n groups, after every earlier action's:
    /// the registry is the build's, and a batch runs one action per input,
    /// in turn. Returns the base: the action's group g ranks
    /// ((base + g + 1) << 32), and its floor afterwards is
    /// ((base + n + 1) << 32), which the next action's ranks exceed.
    pub fn reserve_ranks(self, n: u64) -> u64 {
        var lock = kairo::std::LockGuard(self._mu)
        var base = self._ranks_used
        self._ranks_used += n + 1
        return base
    }

    /// Record \p at in \p fid as where \p e's panic set was formed, if no
    /// request earlier in the one-thread order has (PanicSets::note_formed;
    /// the register-cliff remark's anchor).
    pub fn note_formed(self, e: unsafe *InstanceEntry, fid: u32, at: SourceRange) {
        if e == &null {
            return
        }

        var lock     = kairo::std::LockGuard(self._mu)
        var kr:  u64 = 0
        var ks:  u64 = 0
        self._mint_key(unsafe &kr, unsafe &ks)
        if e->formed_fid != u32::MAX && !Self::_key_less(kr, ks, e->formed_rank, e->formed_seq) {
            return
        }

        e->formed_fid  = fid
        e->formed_at   = at
        e->formed_rank = kr
        e->formed_seq  = ks
    }

    /// The calling thread is about to fill \p shell's entry \p e: start
    /// recording its requests. Returns what end_fill restores.
    pub fn begin_fill(self, e: unsafe *InstanceEntry, fid: i64, alt: unsafe *void) -> unsafe *void {
        var unsafe **slot = kairo::sema_fill_record()
        var unsafe *prev  = *slot
        if e == &null {
            return prev
        }

        var lock = kairo::std::LockGuard(self._mu)
        e->fill_rank     = *kairo::sema_mint_rank()
        e->fill_fid      = fid
        e->fill_alt      = alt
        e->fill_used_alt = false
        e->fill_reqs.clear()
        e->fill_req_fids.clear()
        *slot = unsafe (e as unsafe *void)
        return prev
    }

    /// A nested fill's requests are the outer fill's too: a re-request of
    /// the outer one must make them all, as the outer fill did.
    pub fn end_fill(self, e: unsafe *InstanceEntry, prev: unsafe *void) {
        *kairo::sema_fill_record() = prev
        if e == &null || prev == &null {
            return
        }

        var        lock   = kairo::std::LockGuard(self._mu)
        var unsafe *outer = unsafe (prev as unsafe *InstanceEntry)
        for var i: usize = 0; i < e->fill_reqs.size(); ++i {
            outer->fill_reqs.push_back(e->fill_reqs[i])
            outer->fill_req_fids.push_back(e->fill_req_fids[i])
        }
    }

    /// \p e's shell is filled already, by a TU later in the one-thread order
    /// than the caller: make the requests that fill made, as the caller's
    /// own fill would have, so their homes and order are the caller's. A
    /// no-op for any later caller.
    pub fn rerequest(self, e: unsafe *InstanceEntry, fid: i64, alt: unsafe *void) {
        if e == &null {
            return
        }

        var r = *kairo::sema_mint_rank()
        if r == u64::MAX || r >= e->fill_rank {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        if r >= e->fill_rank {
            return
        }

        // Filled through the filler's own set: a demander with another set
        // would not have filled it this way (ForeignInstantiate::_fill_locked
        // retries in the demander's set), so its requests are not this one's.
        if e->fill_used_alt && e->fill_alt != alt {
            return
        }

        // A request that named the old demander (`home`, ForeignInstantiate)
        // names this one; one that named a header TU (TypeImport) still does.
        var old_fid = e->fill_fid
        e->fill_rank = r
        e->fill_fid  = fid
        var reqs = e->fill_reqs
        var fids = e->fill_req_fids
        for var i: usize = 0; i < reqs.size(); ++i {
            var kr: u64 = 0
            var ks: u64 = 0
            self._mint_key(unsafe &kr, unsafe &ks)
            var f = fids[i]
            if old_fid >= 0 && fid >= 0 && (f as i64) == old_fid {
                f = (fid as u32)
            }

            self._claim(reqs[i], kr, ks, f)
        }
    }

    priv fn <T> _alloc(self) -> unsafe *T {
        var mem: unsafe *void = self._arena.alloc(sizeof(T), alignof(T))
        cxx::std::memset(mem, 0, sizeof(T))
        return unsafe (mem as unsafe *T)
    }

    /// Everything a shell has in common, whatever its kind. The node's names
    /// are the PRIMARY's tokens: same TU, same imm space, so ctx_of() and every
    /// renderer land in the right interner.
    // TODO(DUCK-GENERIC): T uses dc_decls, generic_params, init_annotations, init_dc, init_redecl, foreign_fill, instantiated_from, is_implicit, is_this_definition, kind, lexical_dc, name, ... (17). Stage 0 was duck-typed; bound it or keep `: type`.
    priv fn <T: type> _shell(self,
                             n:    unsafe *T,
                             p:    unsafe *T,
                             kind: DeclKind,
                             dck:  DeclContextKind,
                             ctx:  unsafe *ASTContext) {
        n->kind  = kind
        n->range = p->range
        n->name  = p->name
        n->init_annotations(&self._arena)
        n->init_dc(dck, ctx, p->semantic_dc, n)
        n->dc_decls.set_allocator(&self._arena) // NOT the fid's ast_alloc (see file header).
        n->init_redecl()
        n->is_this_definition = true           // a definition-in-waiting; M2 fills it.
        n->is_implicit        = true
        n->lexical_dc         = p->semantic_dc
        n->semantic_dc        = p->semantic_dc
        n->generic_params.from_raw(unsafe (&null as unsafe *(unsafe *GenericParamDecl)), 0)
        n->spec_args.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        n->requires_clause   = &null
        n->spec_kind         = SpecKind::Instantiated
        n->instantiated_from = p
        n->foreign_fill      = 0 // ForeignFill::Shell: only ForeignInstantiate moves it.
    }

    /// The implicit node: the primary's DeclKind, empty body. Only the kinds
    /// that carry generic params exist here; an Interface instance is a
    /// conformance target, not a body, but it still needs an identity.
    priv fn _new_instance(self, primary: unsafe *Decl, ctx: unsafe *ASTContext) -> unsafe *Decl {
        if isa<ClassDecl>(primary) {
            var unsafe *p = cast<ClassDecl>(primary)
            var unsafe *n = self._alloc<ClassDecl>()
            self._shell<ClassDecl>(n, p, DeclKind::ClassDecl, DeclContextKind::Class, ctx)
            n->fields.from_raw(unsafe (&null as unsafe *(unsafe *FieldDecl)), 0)
            n->methods.from_raw(unsafe (&null as unsafe *(unsafe *FunctionDecl)), 0)
            n->derives_list.from_raw(&null, 0)
            n->implements.from_raw(&null, 0)
            n->is_final    = p->is_final
            n->is_abstract = p->is_abstract
            return n
        }

        if isa<StructDecl>(primary) {
            var unsafe *p = cast<StructDecl>(primary)
            var unsafe *n = self._alloc<StructDecl>()
            self._shell<StructDecl>(n, p, DeclKind::StructDecl, DeclContextKind::Struct, ctx)
            n->fields.from_raw(unsafe (&null as unsafe *(unsafe *FieldDecl)), 0)
            n->methods.from_raw(unsafe (&null as unsafe *(unsafe *FunctionDecl)), 0)
            n->implements.from_raw(&null, 0)
            return n
        }

        if isa<UnionDecl>(primary) {
            var unsafe *p = cast<UnionDecl>(primary)
            var unsafe *n = self._alloc<UnionDecl>()
            self._shell<UnionDecl>(n, p, DeclKind::UnionDecl, DeclContextKind::Union, ctx)
            n->fields.from_raw(unsafe (&null as unsafe *(unsafe *FieldDecl)), 0)
            n->methods.from_raw(unsafe (&null as unsafe *(unsafe *FunctionDecl)), 0)
            n->is_anonymous = p->is_anonymous
            return n
        }

        if isa<EnumDecl>(primary) {
            var unsafe *p = cast<EnumDecl>(primary)
            var unsafe *n = self._alloc<EnumDecl>()
            self._shell<EnumDecl>(n, p, DeclKind::EnumDecl, DeclContextKind::Enum, ctx)
            n->variants.from_raw(unsafe (&null as unsafe *(unsafe *EnumVariantDecl)), 0)
            n->underlying = p->underlying
            n->is_adt     = p->is_adt
            n->is_open    = p->is_open
            return n
        }

        if isa<InterfaceDecl>(primary) {
            var unsafe *p = cast<InterfaceDecl>(primary)
            var unsafe *n = self._alloc<InterfaceDecl>()
            self._shell<InterfaceDecl>(
                n,
                p,
                DeclKind::InterfaceDecl,
                DeclContextKind::Interface,
                ctx,
            )

            n->methods.from_raw(unsafe (&null as unsafe *(unsafe *FunctionDecl)), 0)
            n->derives_list.from_raw(&null, 0)
            return n
        }

        // A FUNCTION instance is the primary itself. The shell nodes above
        // exist so a member lookup on `Vec<i32>` has a table to walk; a
        // function instance has no table and nothing looks a name up inside
        // one, so minting an empty FunctionDecl would only create a second
        // identity for the same entity. EmitPlan/M1 read the entry's args to
        // write the explicit instantiation and never the node's body.
        if isa<FunctionDecl>(primary) {
            return primary
        }

        return &null
    }
}
