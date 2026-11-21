/// --- The Kairo Project ------------------ Sema/Check/ClassLifecycle.k --- ///
///
/// Per record: copyable, movable, trivially so, destructible -- and
/// the one OOP rule those facts decide, the virtual-destructor rule.
///
///   \detail
///     For an IMPORTED record the facts are clang's (FFILinkage::
///     ForeignLayout: trivially_copyable, trivial_dtor) plus the imported
///     constructors (`= delete` on a copy/move ctor arrives as
///     TransferKind + FnBodyKind::Delete). For a Kairo record they come from
///     the declared constructors, `op delete`, `= delete`, and the
///     @copy/@move transfer ctors, by the C++ rules the record will be
///     lowered under:
///
///       copyable   no deleted copy ctor, and no user move ctor without a
///                  user copy ctor (declaring a move deletes the implicit
///                  copy); every base and by-value field copyable, unless
///                  the copy ctor is user-provided.
///       movable    no deleted move ctor, and (a user move ctor, or
///                  copyable -- an rvalue falls back to the copy); every
///                  base and by-value field movable, unless the move or
///                  copy ctor is user-provided.
///
///     User-provided is neither `= default` nor `= delete`: the body decides
///     what the transfer does, so the components do not. A defaulted
///     transfer, or the one C++ generates when none is declared, is
///     memberwise and does ask them.
///       trivial_dtor  no destructor that is user-provided, deleted or
///                  virtual on this type, its bases, or its by-value fields.
///       trivially_copyable  that, and no transfer ctor that is user-provided
///                  or deleted on any of them either, and no virtual method
///                  or virtual base: a copy that must set up a vptr is not a
///                  memcpy.
///                  `= default` is not user-provided, so a defaulted member
///                  is trivial exactly when its parts are, as C++ has it for
///                  one defaulted on its first declaration.
///                  A NON_TRANSFER record is never trivially copyable,
///                  whatever its parts or clang say: nothing copies or moves
///                  it, and the lowering picks defaulted transfers off this
///                  bit, so a Yes would hand it a transfer it does not have.
///       destructible  no `op delete = delete` on this type, its bases, or
///                  its by-value fields.
///       relocatable  a value may be moved by copying its bytes and
///                  abandoning the source, which is what C++ calls trivial
///                  for the purposes of calls. A record marked
///                  `@relocatable` is, by declaration; one that is not is
///                  when it has no destructor or transfer constructor that
///                  is user-provided or deleted, no vptr, and every base and
///                  by-value field is relocatable. An imported record has
///                  clang's answer (ForeignLayout::trivial_for_calls). An
///                  ADT, and a `T?` that is not a pointer, are lowered with
///                  special members of their own, so they are relocatable
///                  only when trivially copyable and trivially destroyed.
///                  `@relocatable` is `trivial_abi`, which clang drops from
///                  a record that has a base or field without this fact, is
///                  polymorphic, or has every transfer deleted; that is an
///                  error here (_check_relocatable), asked again of each
///                  instance of a generic record (instance_failures).
///
///     An ENUM is the same question with no members to declare. A plain enum
///     is an integer: COPY, trivially everything, destructible. An ADT is a
///     tag beside a union of its payloads, so it follows the struct rule over
///     every payload field of every variant: copyable, movable, destructible
///     and trivially so only when each payload type is, and its category is
///     the weakest any payload allows (COPY > MOVE > NON_TRANSFER).
///
///   \par Unknown
///     Every fact a component decides is a LifecycleTri, Unknown when it
///     depends on a generic parameter: a field, payload or base whose type is
///     dependent. Folding is Kleene AND -- one definite No decides, an
///     Unknown only spoils a Yes -- so `{ s: string, v: T }` is definitely
///     not trivially copyable. A pointer is a pointer whatever it points at,
///     so `*T` stays trivial. Every rule that diagnoses from a fact, here and
///     in MoveCheck, skips an Unknown one rather than guessing either way.
///
///   \par Instances (Compiler/Spec/Ownership.md#instances-of-generic-records)
///     Unknown is the PATTERN's answer only. A concrete instance of a Kairo
///     generic (`Opt<i32>`, `Opt<Mv>`) has facts of its own: the same rules
///     over the pattern's declared members -- or the selected partial's --
///     with the instance's arguments substituted into every field, payload
///     and base type (Substitution), so `Opt<i32>` is COPY
///     and `Opt<Mv>` MOVE, and every reader that is handed the instance
///     (MoveCheck, moves_on_pass, assignment, the non-generic-ADT gate,
///     lifecycle requirements) reads them. A fact only, never a re-typed
///     body (Compiler/Spec/Generics.md#decisions). The memo below is the side table: keyed by the
///     instance decl, which is one per registry entry. An imported
///     template's instance keeps clang's facts (ensure_filled), except that
///     one HOLDING a value that cannot be copied (a `value_type`, field or
///     base) cannot be copied either (_imported_elements, GH#87); one that
///     only points at its argument (`shared_ptr<Mv>`) keeps clang's COPY.
///     Clang sees a Kairo argument through a stand-in that declares the
///     record's own transfers (TypeExport::_mirror_transfers), so a copy
///     C++ conditionally deletes (`optional<Mv>`, `tuple<Mv, i32>`,
///     `variant`, `pair`) is deleted in clang's facts already.
///
///     The rules a generic class's declaration skipped on an Unknown --
///     rule 5, rule 6 and the virtual-destructor rule -- are asked again of
///     each LIVE instance (instance_failures): ConformanceChecking reports
///     what fails at the instance's use with its instantiation chain
///     (Compiler/Spec/Generics.md#instance-diagnostics), once per instance, as it does an unmet bound.
///
///     A record that writes a @copy or @move constructor has the category it
///     DECLARED, read off the copyable / movable rules above: @copy is COPY,
///     @move is MOVE, and a deleted one -- either alone, or both -- is
///     NON_TRANSFER, since a deleted copy suppresses the implicit move and a
///     deleted move deletes the implicit copy. It reads Unknown only when a
///     dependent component leaves a defaulted transfer open, and never when
///     the transfer is user-provided or it declared NON_TRANSFER: nothing a
///     field holds brings a deleted transfer back. A record that writes
///     neither has no category of its own to declare: C++ generates its
///     transfers from its bases and fields, so its category is the weakest
///     they allow, read off the folded facts exactly as an ADT's is
///     (_folded_category). So does an IMPORTED record that declares both
///     transfers `= default` (std::pair): C++ defines such a copy over a
///     move-only member as deleted and keeps the move. A class holding a move-only field is MOVE, and
///     one holding a std::mutex is NON_TRANSFER.
///
///     Facts are computed on demand and memoized per TU, keyed on the
///     representative, so a foreign or cross-TU record is asked once. A
///     record mid-computation that is reached again (a by-value cycle) reads
///     as trivial: TypeCycleCheck owns that diagnostic.
///
///   \par The virtual-destructor rule
///     A class with a non-trivial destructor whose base has no virtual
///     destructor is a leak waiting for a `delete` through the base pointer:
///     C++ runs only the base's destructor. Error at the derived class,
///     naming both. A destructor is virtual when declared `virtual`/
///     `override`, when clang says so on an imported one, or when any base
///     has one (C++ makes it virtual implicitly then).
///
///   \par Transfer-constructor shapes
///     C++ makes every constructor whose first parameter is the class itself
///     (every later one defaulted) a copy or move constructor, whatever it
///     was meant as. Kairo admits exactly two spellings of one:
///
///       @copy fn X(self, const other: Self)   C++ X(const X& other)
///       @copy fn X(self, other: Self)         C++ X(X& other)
///       @move fn X(self, other: Self)         C++ X(X&& other)
///
///     with `other` otherwise bare: no mode, no default, nothing after it,
///     and no `const` under `@move`. Anything else of that shape is an error
///     at the declaration. The accepted ones are STAMPED: `other` gets the
///     mode the marker means (`@copy` -> Inout, `@move` -> Move), so Speller
///     and MoveCheck read an ordinary parameter mode and never the marker.
///     The stamp lands after ExprTyper on purpose: X ranks a copy's argument
///     against the by-value view, which is what C++ overload resolution does
///     for `const X&` too, whereas an Inout parameter in X is a `T&` that
///     wants the call-site `&` and refuses a temporary.
///
///   \par Assignment
///     `op =` is never written (rule 2): it is derived from the transfer
///     constructor, and the derivation is decided here and written on the
///     record (assign_from, assign_form; Declarations.k AssignForm) for
///     InterfaceEmitter. A defaulted transfer, or none at all, assigns
///     member by member, so a part that cannot be assigned leaves none. A
///     deleted transfer leaves none. A transfer with a body destroys the old
///     value and builds the new one in place through that constructor,
///     which neither a polymorphic record takes -- it may be a base
///     subobject, and the rebuild would leave the derived object with this
///     record's vptr -- nor one that cannot be destroyed. `assignable` is
///     that verdict and `polymorphic` the vptr fact it reads; assigning a
///     record left with none is an error here (SC071E) rather than in
///     clang. A generic record whose parts leave a body's verdict open gets
///     it constrained per instance (AssignForm::Constrained).
///
///   \par Ownership
///     One instance per TU run, owned by Sema and published on
///     SemaContext::lifecycle. Readers reach it through lifecycle_of(sc), so
///     the memo is one table: a second instance would compute every fact
///     twice and could answer differently mid-run.
///
///   Phase: CHECK, after ExprTyper. MoveCheck and SemaDump read facts_of().
///   EvalIfLateFolding reads facts_of_type_concrete earlier, in the T stage
///   right after RedeclMerge: every canonical it reads exists by then.
///
///   \par Asked too early
///     A null type, or a record type with no decl, has no facts: it reads
///     Unknown, never the trivially-everything a builtin gets. A reader that
///     acts on the answer for a CONCRETE type (no generic parameter, not
///     inside a generic owner) asks facts_of_type_concrete, which ICEs naming
///     the reader when such a type's facts are still open: from T on they
///     are all definite, so an open one means the question came too early,
///     and a silent Yes would pick a different lowering, or a different
///     `eval if` branch, than C++ will.
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
ffi "c++" import "llvm/Support/Allocator.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"

import AST::ASTSupport::FrozenList
import AST::AttrFacts::AttrFacts
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_in_generic_owner,
    decl_is_ctor,
    decl_is_imported,
    decl_is_instance,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
}
import AST::Mixin::FFILinkage::ForeignLayout
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AbiKind,
    AdtRole,
    AssignForm,
    ClassDecl,
    EnumDecl,
    FieldDecl,
    FnBodyKind,
    FunctionDecl,
    ImplicitTransfer,
    InterfaceDecl,
    ParamDecl,
    StorageClass,
    StructDecl,
    TransferKind,
    TypeAliasDecl,
    UnionDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    CallExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    GenericParamType,
    NullableType,
    PointerType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::NoteText::type_declared_here
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::MoveSourceScan::MoveSourceScan
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

pub enum LifecycleCategory derives u8 {
    Copy = 0,    ///< @copy, explicit or implicit; DEFAULT reads as this.
    Move,        ///< @move.
    NonTransfer, ///< a deleted transfer ctor (one or both): stack-only.
    Unknown,     ///< hangs on a generic parameter (see LifecycleTri).
}

/// One lifecycle fact. Unknown is not a third answer but the absence of one:
/// the pattern cannot say, an instance can (file header).
pub enum LifecycleTri derives u8 {
    No = 0,
    Yes,
    Unknown, ///< a dependent field, payload or base decides it.
}

pub fn lifecycle_tri(b: bool) -> LifecycleTri {
    return if (b) => (LifecycleTri::Yes) else => LifecycleTri::No
}

/// Every part has it. A definite No wins over an Unknown: `{ s: string,
/// v: T }` is not trivially copyable whatever T turns out to be.
pub fn lifecycle_and(a: LifecycleTri, b: LifecycleTri) -> LifecycleTri {
    if a == LifecycleTri::No || b == LifecycleTri::No {
        return LifecycleTri::No
    }

    if a == LifecycleTri::Unknown || b == LifecycleTri::Unknown {
        return LifecycleTri::Unknown
    }

    return LifecycleTri::Yes
}

/// Some part has it. A definite Yes wins over an Unknown.
pub fn lifecycle_or(a: LifecycleTri, b: LifecycleTri) -> LifecycleTri {
    if a == LifecycleTri::Yes || b == LifecycleTri::Yes {
        return LifecycleTri::Yes
    }

    if a == LifecycleTri::Unknown || b == LifecycleTri::Unknown {
        return LifecycleTri::Unknown
    }

    return LifecycleTri::No
}

pub fn lifecycle_not(a: LifecycleTri) -> LifecycleTri {
    if a == LifecycleTri::Yes {
        return LifecycleTri::No
    }

    if a == LifecycleTri::No {
        return LifecycleTri::Yes
    }

    return LifecycleTri::Unknown
}

/// Every fact below that a field, payload or base can decide is a
/// LifecycleTri. The bools are the record's own declarations, never unknown.
/// One writer for all of it: the fact computation in ClassLifecycle
/// (_compute, _compute_enum, facts_of_type, folded through _absorb).
pub class LifecycleFacts {
    pub var in_progress:        bool         = false
    pub var copyable:           LifecycleTri = LifecycleTri::Yes
    pub var movable:            LifecycleTri = LifecycleTri::Yes
    pub var trivially_copyable: LifecycleTri = LifecycleTri::Yes
    pub var trivial_dtor:       LifecycleTri = LifecycleTri::Yes
    pub var has_user_dtor:      bool         = false
    pub var virtual_dtor:       LifecycleTri = LifecycleTri::No
    pub var why_not_movable:    string       = ""
    pub var why_not_copyable:   string       = ""
    /// Its bytes may be moved and the source abandoned (file header). The
    /// reason is a clause about the type: "it has a destructor".
    pub var relocatable:         LifecycleTri = LifecycleTri::Yes
    pub var why_not_relocatable: string       = ""
    /// Doc: Lifecycle Categories. DEFAULT (no transfer ctor written) is
    /// reported as the weakest its bases and fields allow, which is Copy
    /// whenever they all copy; the implicit-copy warning tells DEFAULT
    /// apart by reading `user_transfer` instead.
    pub var category:      LifecycleCategory = LifecycleCategory::Copy
    pub var user_transfer: bool              = false ///< wrote a @copy or @move ctor at all.
    /// Destruction work of this record's OWN: a user destructor, or a
    /// by-value field whose destructor is non-trivial. Bases deliberately do
    /// not contribute -- a `delete` through a base pointer still runs the
    /// base's destructor, so the base's work is never the part that leaks.
    /// The virtual-destructor rule reads this, not `trivial_dtor`.
    pub var own_dtor_work: LifecycleTri = LifecycleTri::No
    /// No when the destructor is `= delete` here, on a base, or on a
    /// by-value field (an ADT: on any payload field).
    pub var destructible: LifecycleTri = LifecycleTri::Yes
    /// A vptr: a virtual method of its own (a pure one included), a virtual
    /// base, or a polymorphic base. Unknown under a dependent base.
    pub var polymorphic: LifecycleTri = LifecycleTri::No
    /// The derived `op =` exists (file header, Assignment). Folded over the
    /// parts by _absorb_assign, never by _absorb: an ADT rebuilds its
    /// payloads rather than assigning them.
    pub var assignable:         LifecycleTri = LifecycleTri::Yes
    pub var why_not_assignable: string       = ""
    /// No `op =` only because a transfer body would rebuild a polymorphic
    /// record in place. The one case where building a new value is the fix:
    /// a deleted transfer or an unassignable member has nothing to rebuild.
    pub var poly_rebuild: bool = false
    /// The `@deprecated` `@copy` constructor a copy of this type runs: its
    /// own, or, when the copy is memberwise, the one a base, a by-value
    /// field or an element brings (`deprecated_copy_via` names that part,
    /// and is empty for its own). Null when a copy runs none.
    pub var deprecated_copy:     unsafe *FunctionDecl = &null
    pub var deprecated_copy_via: string               = ""
    fn LifecycleFacts(self) { }

    /// A copy of every field; the strings are not copyable by assignment.
    pub fn copy(const self) -> LifecycleFacts {
        var o = LifecycleFacts()
        o.in_progress         = self.in_progress
        o.copyable            = self.copyable
        o.movable             = self.movable
        o.trivially_copyable  = self.trivially_copyable
        o.trivial_dtor        = self.trivial_dtor
        o.has_user_dtor       = self.has_user_dtor
        o.virtual_dtor        = self.virtual_dtor
        o.why_not_movable     = self.why_not_movable.copy()
        o.why_not_copyable    = self.why_not_copyable.copy()
        o.relocatable         = self.relocatable
        o.why_not_relocatable = self.why_not_relocatable.copy()
        o.category            = self.category
        o.user_transfer       = self.user_transfer
        o.own_dtor_work       = self.own_dtor_work
        o.destructible        = self.destructible
        o.polymorphic         = self.polymorphic
        o.assignable          = self.assignable
        o.why_not_assignable  = self.why_not_assignable.copy()
        o.poly_rebuild        = self.poly_rebuild
        o.deprecated_copy     = self.deprecated_copy
        o.deprecated_copy_via = self.deprecated_copy_via.copy()
        return o
    }
}

/// One of the five facts an ADT's special members are picked from --
/// trivial_dtor, trivially_copyable, destructible, copyable, movable -- is
/// still Unknown. FeatureGateCheck rejects a non-generic ADT for which this
/// holds and EnumLayoutLowering ICEs on one, so both read this one
/// predicate: the gate then covers the ICE exactly. The category needs no
/// test of its own: with copyable and movable known it is decided.
pub fn lifecycle_open(f: unsafe *LifecycleFacts) -> bool {
    return f->trivial_dtor == LifecycleTri::Unknown
        || f->trivially_copyable == LifecycleTri::Unknown
        || f->destructible == LifecycleTri::Unknown
        || f->copyable == LifecycleTri::Unknown
        || f->movable == LifecycleTri::Unknown
}

/// One lifecycle rule an instance fails (ClassLifecycle::instance_failures),
/// as data: ConformanceChecking reports it, at the instance's use and with
/// its chain, which this file cannot (it is imported by that one).
pub class LifecycleFailure {
    pub var id:  DiagID = DiagID::SC001E
    pub var msg: string = ""
    /// Where a failure of the declaration itself is reported; an instance's
    /// is reported at its use.
    pub var at: SourceRange = SourceRange::invalid()
    /// Parallel: each note's code (I900N for a plain one), place, text.
    pub var note_ids: [DiagID]
    pub var note_at:  [SourceRange]
    pub var note_msg: [string]
    fn LifecycleFailure(self) { }

    fn add_note(self, id: DiagID, at: SourceRange, const msg: string) {
        self.note_ids.push(id)
        self.note_at.push(at)
        self.note_msg.push(msg.copy())
    }
}

pub class ClassLifecycle derives RecursiveASTVisitor<ClassLifecycle> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// The arguments of the instance whose facts _compute is computing, or
    /// null for a pattern or a non-generic record: what _through reads a
    /// field, payload or base type with. Saved and restored around every
    /// computation (facts_of), since computing one instance recurses into
    /// its components' own.
    priv var _sub: unsafe *Substitution = &null
    /// Facts live in _facts_arena, the map holds their address: facts_of
    /// hands out a *LifecycleFacts that _compute keeps writing while it
    /// recurses into bases and fields -- each recursion inserts here, and a
    /// DenseMap rehash moves its values. Keyed by decl address, never a
    /// reserved key; never iterated.
    priv var _facts:       llvm::DenseMap<u64, unsafe *LifecycleFacts>
    priv var _facts_arena: llvm::SpecificBumpPtrAllocator<LifecycleFacts>
    pub var  n_checked:    usize                                          = 0
    pub var  n_errored:    usize                                          = 0
    /// Bases with no virtual destructor that a class with destructor work
    /// derives from, and the `destroy` calls met, both of this TU: a
    /// `destroy` of the base type is checked once the whole TU is walked,
    /// since a derived class may follow the call.
    priv var _plain_bases:   [unsafe *Decl]
    priv var _destroy_calls: [unsafe *CallExpr]

    /// Unwired. Exists for the by-value member Sema::lifecycle, which is
    /// assigned the wired form once the SemaContext it borrows sits at its
    /// final address.
    fn ClassLifecycle(self) {
        self.sc = &null
    }

    fn ClassLifecycle(self, sc: unsafe *SemaContext) {
        self.bind(sc)
    }

    /// Wire an already-constructed instance to `sc`. The way an owner
    /// that holds this by value sets it up: _facts_arena cannot be
    /// assigned, so `x = ClassLifecycle(sc)` does not compile.
    fn bind(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    /// PRE: TypesResolved (canonicals exist; base types resolved).
    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self.run(tu)
        self._check_destroy_calls()
    }

    /// # destroy through a base

    fn visit_call_expr(self, n: unsafe *CallExpr) -> bool {
        if n == &null || n->args.size() != 1 {
            return true
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(n->callee)
        if ni != &null && self._is_destroy(ni->resolved_decl) {
            self._destroy_calls.push(n)
        }

        return true
    }

    priv fn _is_destroy(self, d: unsafe *Decl) -> bool {
        if d == &null || self.sc->well_known == &null {
            return false
        }

        var unsafe *ld = self.sc->well_known->get(WellKnownType::Destroy)
        return ld != &null && NameLookup::representative(d) == NameLookup::representative(ld)
    }

    /// `@destroy p` with `p: *Base`, where Base has no virtual destructor
    /// and a class with destructor work derives from it: the derived part
    /// of whatever `p` points at is never destroyed. SC056E at the
    /// declaration covers a polymorphic base; this covers the others, which
    /// are only unsafe at a `destroy` of the base type.
    priv fn _check_destroy_calls(self) {
        for var i: usize = 0; i < self._destroy_calls.size(); ++i {
            var unsafe *c = self._destroy_calls[i]
            if c->args[0] == &null {
                continue
            }

            var unsafe *bd = self._tu.record_decl(
                self._tu.pointee(c->args[0]->type_),
            )

            if bd == &null {
                continue
            }

            var unsafe *rep = NameLookup::representative(bd)
            var        hit  = false
            for var j: usize = 0; j < self._plain_bases.size(); ++j {
                if self._plain_bases[j] == rep {
                    hit = true
                }
            }

            if !hit {
                continue
            }

            var bn = self._tu.decl_name(bd)
            var b = self.sc->diag->report(
                DiagID::SC056E,
                c->range.start,
                f"'{bn}' has no virtual destructor and a class with a destructor derives from it; destroying a '*{bn}' would run only '{bn}''s destructor and leak the rest",
            )

            b.first(c->range)
            b.note(
                bd->range.start,
                f"declare 'virtual fn op finally(self)' in '{bn}', or destroy through a pointer to the most derived type",
            )->child_first(bd->range)
            b.emit()
            self.n_errored += 1
        }
    }

    /// # facts

    /// The facts for the entity `d` belongs to. Any record kind, any TU. An
    /// unfilled instance of an imported template is filled first (clang's
    /// facts); a concrete Kairo instance has its own, its pattern's members
    /// over its arguments (file header, Instances). Anything else unfilled
    /// reads its pattern.
    fn facts_of(self, d_in: unsafe *Decl) -> unsafe *LifecycleFacts {
        var unsafe *d = NameLookup::representative(d_in)
        MemberLookup::ensure_filled(self.sc, d)
        var        inst: unsafe *InstanceEntry = &null
        var unsafe *body                       = d
        if MemberLookup::unfilled(d) {
            inst = self._concrete_instance(d)
            var unsafe *pat = self.sc->body_of(d) // the selected partial spec's, if one was.
            if pat != &null {
                body = NameLookup::representative(pat)
                if inst == &null {
                    d = body
                }
            }
        }

        var key = (d as usize as u64)
        var it  = self._facts.find(key)
        if it != self._facts.end() {
            return it->second
        }

        var unsafe *f = self._facts_arena.Allocate(1)
        cxx::std::construct_at(f)
        // Published BEFORE _compute: its in_progress mark is how a cyclic
        // recursion back to `d` is caught.
        self._facts[key] = f
        var unsafe *saved = self._sub
        self._sub = &null
        if inst != &null {
            var sub = Substitution(self.sc)
            sub.bind_from_record(
                self.sc->types->record(inst->decl, unsafe &inst->args),
            )

            self._sub = unsafe &sub
            self._compute(body, f)
        } else {
            self._compute(d, f)
            if MemberLookup::filled_by_clang(d) {
                self._imported_elements(d, f)
            }
        }

        self._sub = saved
        return f
    }

    /// An imported template's instance over an element that cannot be
    /// copied (GH#87). Clang's facts say `std::vector<Mv>` copies: its copy
    /// constructor is declared and not deleted, and only instantiating its
    /// body would find Mv's deleted one -- a hard error in clang, never a
    /// fact Sema can read (phase A's stand-in for Mv copies; TypeExport).
    /// So the instance read COPY, every transfer of it stayed a copy, and
    /// the copy failed in clang. An instance (one clang does not call
    /// trivially copyable) that HOLDS a value it cannot copy is taken as not
    /// copyable either: the category falls to MOVE, and a transfer moves it.
    ///
    /// Holding is read off what the instance declares, never off a list of
    /// template names: a `value_type` member type that cannot be copied
    /// (the standard's container requirement: a container's copy copies
    /// each `value_type` element -- vector, deque, list, map's
    /// `pair<const K, V>`, optional), or a field or base that cannot be.
    /// A template that only points at its argument declares neither
    /// (`shared_ptr<Mv>` / `weak_ptr<Mv>` hold an `element_type *` and a
    /// control block), so it keeps clang's COPY, as a trivially copyable
    /// one (a span, a reference_wrapper) does: copying it copies no Mv.
    priv fn _imported_elements(self, d: unsafe *Decl, f: unsafe *LifecycleFacts) {
        if self.sc->instances == &null || f->copyable != LifecycleTri::Yes {
            return
        }

        if f->trivially_copyable == LifecycleTri::Yes {
            return
        }

        var unsafe *e = self.sc->instances->entry_of(d)
        if e == &null {
            return
        }

        var elem = false
        for var i: usize = 0; i < e->args.size(); ++i {
            var unsafe *a = e->args[i]
            if a == &null || a->is_dependent() || a->is_instantiation_dependent() {
                continue
            }

            if self.facts_of_type(a).copyable == LifecycleTri::No {
                elem = true
                break
            }
        }

        if !elem {
            return
        }

        var held = self._held_uncopyable(d)
        if held.size() == 0 {
            return
        }

        f->copyable         = LifecycleTri::No
        f->why_not_copyable = held.copy()
        f->category         = self._folded_category(f)
        self._settle_non_transfer(f)
    }

    /// The part that keeps imported record `d`'s deleted copy from being
    /// generated, or "": a by-value field of a Kairo type (worded as the
    /// member fold words it), a type argument of the instance that cannot be copied
    /// (`tuple<Mv, i32>` holds it in a base the import does not keep), else
    /// what _held_uncopyable finds (an element type, a base).
    priv fn _imported_copy_reason(self, d: unsafe *Decl) -> string {
        var fs = self._fields(d)
        for var i: usize = 0; i < fs.size(); ++i {
            var unsafe *fd = fs[i]
            if fd == &null
                || fd->is_static()
                || fd->type_ == &null
                || fd->type_->canonical == &null {
                continue
            }

            if fd->type_->canonical->is_dependent() {
                continue
            }

            // A library-internal member (`tuple::__base_`) names nothing
            // the user wrote: those are left to the steps below.
            var unsafe *fr = self._tu.record_decl(
                canon_unqual(fd->type_->canonical),
            )

            if fr != &null && decl_is_imported(fr) {
                continue
            }

            if self.facts_of_type(fd->type_->canonical).copyable == LifecycleTri::No {
                return f"its field '{self.sc->ctx->get_spelling(fd->name)}' is not copyable"
            }
        }

        var unsafe *e = if (self.sc->instances != &null) => (self.sc->instances->entry_of(
                            d,
                        ))
                        else => &null
        if e != &null {
            for var i: usize = 0; i < e->args.size(); ++i {
                var unsafe *a = e->args[i]
                if a == &null || a->is_dependent() || a->is_instantiation_dependent() {
                    continue
                }

                if self.facts_of_type(a).copyable == LifecycleTri::No {
                    return f"its type argument '{self._tu.str(canon_unqual(a))}' is not copyable"
                }
            }
        }

        return self._held_uncopyable(d)
    }

    /// Why imported instance `d` holds a value it cannot copy (see
    /// _imported_elements), or "" when it declares none.
    priv fn _held_uncopyable(self, d: unsafe *Decl) -> string {
        var unsafe *dc = NameLookup::context_of(d)
        if dc != &null {
            var vt = "value_type"
            var im = self.sc->imm_table()->find_ident(vt)
            var r  = self.sc->lookup.in_context(dc, DeclName::ident(im), vt)
            if r.found() && r.cell->size() == 1 && isa<TypeAliasDecl>(r.cell->get(0)) {
                var unsafe *a = cast<TypeAliasDecl>(r.cell->get(0))->aliased
                if a != &null
                    && !a->is_dependent()
                    && self.facts_of_type(a).copyable == LifecycleTri::No {
                    return f"its element type '{self._tu.str(canon_unqual(a))}' is not copyable"
                }
            }
        }

        var fs = self._fields(d)
        for var i: usize = 0; i < fs.size(); ++i {
            var unsafe *fd = fs[i]
            if fd == &null || fd->is_static() || fd->type_ == &null || fd->type_->is_dependent() {
                continue
            }

            if self.facts_of_type(fd->type_).copyable == LifecycleTri::No {
                return f"its field of type '{self._tu.str(canon_unqual(fd->type_))}' is not copyable"
            }
        }

        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *be = c->derives_list.get(i)
                if be == &null || be->base == &null || be->base->canonical == &null {
                    continue
                }

                var unsafe *bt = be->base->canonical
                if bt->is_dependent() {
                    continue
                }

                if self.facts_of_type(bt).copyable == LifecycleTri::No {
                    return f"its base '{self._tu.str(canon_unqual(bt))}' is not copyable"
                }
            }
        }

        return ""
    }

    /// Drop every memoized fact. EvalIfLateFolding calls it after a round
    /// that changed a record's member set: a fact computed before it (of a
    /// record holding the folded one by value) describes members the record
    /// no longer has. The arena keeps the old values; nothing holds one
    /// across a round, the late fold reads facts by value.
    fn forget_facts(self) {
        self._facts.clear()
    }

    /// `d`'s registry entry when it is an instance of a KAIRO generic at
    /// concrete arguments -- the one kind of record whose facts are its own
    /// but computed from another's members. Null for an imported template's
    /// (clang's facts) and for anything still dependent.
    priv fn _concrete_instance(self, d: unsafe *Decl) -> unsafe *InstanceEntry {
        if d == &null || !decl_is_instance(d) || self.sc->instances == &null {
            return &null
        }

        var unsafe *e = self.sc->instances->entry_of(d)
        if e == &null || e->primary == &null || decl_is_imported(e->primary) {
            return &null
        }

        for var i: usize = 0; i < e->args.size(); ++i {
            var unsafe *a = e->args[i]
            if a == &null || a->is_dependent() || a->is_instantiation_dependent() {
                return &null
            }
        }

        return e
    }

    /// `t` as the instance being computed sees it (`T` of `Opt<Mv>` is Mv),
    /// or `t` itself: outside an instance, or where a substitution does not
    /// go through, in which case the component stays Unknown, as the
    /// pattern's is.
    priv fn _through(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null || self._sub == &null {
            return t
        }

        if !t->is_dependent() && !t->is_instantiation_dependent() {
            return t
        }

        var unsafe *s = self._sub->substitute(t)
        return if (s != &null) => (s) else => t
    }

    /// Facts for a canonical TYPE: a record's are its decl's; everything
    /// else is trivially everything, except the library containers, which
    /// are movable, copyable and non-trivially destroyed, and a by-value
    /// type that depends on a generic parameter, which is Unknown throughout.
    fn facts_of_type(self, t_in: unsafe *Type) -> LifecycleFacts {
        var out = LifecycleFacts()
        // No type is no answer (file header, Asked too early): Yes here would
        // make a question asked before T a silent "trivially everything".
        if t_in == &null {
            return self._unknown_facts()
        }

        var unsafe *t = canon_unqual(t_in)

        // The OWNING library containers, restated against the lang records
        // they canonicalize to since the container migration. Lib/builtin
        // declares their layout but no destructor -- bodies live in std -- so
        // the RecordType arm below reads them off its decl as trivially
        // destructible, and a class holding a `[i32]` would silently lose its
        // non-trivial destructor, taking the virtual-destructor diagnostic
        // with it.
        //
        // Slice is deliberately absent: it is a non-owning ptr+len view, and
        // it IS trivial in both senses.
        //
        // The two-word library's four declare their transfer constructor
        // and destructor, so their facts are read off the declaration like
        // any record's: they are MOVE types there.
        if !self._tu.sc->well_known->two_word()
            && (self._tu.is_vector_like(t)
                || self._tu.is_map_like(t)
                || self._tu.is_set_like(t)
                || self._tu.is_string(t)) {
            out.trivially_copyable = LifecycleTri::No
            out.trivial_dtor       = LifecycleTri::No
            // The one fact read off the declaration: the container says
            // itself whether its bytes may be moved.
            var unsafe *cd = self._tu.record_decl(t)
            if cd == &null || !AttrFacts::is_relocatable(self._pattern(cd)) {
                self._not_relocatable(
                    unsafe &out,
                    "it has a destructor and is not marked '@relocatable'",
                )
            }

            self._held_deprecated_copy(t, unsafe &out)
            return out
        }

        // A tuple is its arity's record, but its facts are its ELEMENTS'
        // folded: the record is a lang item whose fields are typed by its
        // parameters, and its element types are the tuple's own, packs
        // included, so the fold needs no instance entry to read them from.
        if self._tu.is_tuple(t) {
            var elems = self._tu.tuple_elems(t)
            for var i: usize = 0; i < elems.size(); ++i {
                var ef = self.facts_of_type(elems[i])
                self._absorb(unsafe &out, unsafe &ef, f"element {i}")
                self._absorb_assign(unsafe &out, unsafe &ef, f"element {i}")
            }

            // The record declares no transfer, so its category is the
            // weakest its elements allow, as a user record's fold is:
            // `(Mv, i32)` is MOVE and `var u = t` moves it.
            out.category = self._folded_category(unsafe &out)
            self._settle_non_transfer(unsafe &out)
            return out
        }

        match t->kind {
            case TypeKind::RecordType {
                var unsafe *d = cast<RecordType>(t)->decl
                if d == &null { // nothing to ask (Asked too early).
                    return self._unknown_facts()
                }

                // An imported template over a generic parameter
                // (`cxx::std::vector<T>`): clang's facts are the template's,
                // not an instance's, and the instance's argument decides
                // whether it copies (_imported_elements), so each instance
                // is asked.
                if t->is_dependent() && decl_is_imported(d) {
                    return self._unknown_facts()
                }

                return self.facts_of(d)->copy()
            } case TypeKind::FixedArrayType {
                return self.facts_of_type(cast<FixedArrayType>(t)->element)
            } case TypeKind::VectorType {
                out.trivially_copyable = LifecycleTri::No
                out.trivial_dtor       = LifecycleTri::No
                self._not_relocatable(
                    unsafe &out,
                    "it has a destructor and is not marked '@relocatable'",
                )

                return out
            } case TypeKind::MapType {
                out.trivially_copyable = LifecycleTri::No
                out.trivial_dtor       = LifecycleTri::No
                self._not_relocatable(
                    unsafe &out,
                    "it has a destructor and is not marked '@relocatable'",
                )

                return out
            } case TypeKind::SetType {
                out.trivially_copyable = LifecycleTri::No
                out.trivial_dtor       = LifecycleTri::No
                self._not_relocatable(
                    unsafe &out,
                    "it has a destructor and is not marked '@relocatable'",
                )

                return out
            } case TypeKind::OpaqueFFIType {
                out.trivially_copyable = LifecycleTri::No
                out.trivial_dtor       = LifecycleTri::No
                self._not_relocatable(
                    unsafe &out,
                    "it has a destructor and is not marked '@relocatable'",
                )

                return out
            }

            // An address, whatever it addresses: `*T` is as trivial as `*i32`,
            // and asking T would make every generic node type unknown.
            case TypeKind::PointerType {
                return out
            }

            // A `fn` value may own a capturing closure, which it copies and
            // frees with itself (Speller: `::__kairo_fn`), so it is not the
            // bits of an address: a record holding one is not trivial. A
            // raw `unsafe fn` is the address alone.
            case TypeKind::FunctionPointerType {
                if cast<FunctionPointerType>(t)->is_unprototyped
                    || cast<FunctionPointerType>(t)->is_raw {
                    return out
                }

                out.trivially_copyable = LifecycleTri::No
                out.trivial_dtor       = LifecycleTri::No
                self._not_relocatable(
                    unsafe &out,
                    "a 'fn' value owns the closure it holds",
                )

                return out
            } case TypeKind::CXXLValueRefType {
                return out
            } case TypeKind::CXXRValueRefType {
                return out
            } case TypeKind::NullableType {
                var unsafe *inner = cast<NullableType>(t)->inner
                if inner != &null && isa<PointerType>(canon_unqual(inner)) {
                    return out
                }

                if t->is_dependent() || t->is_instantiation_dependent() {
                    return self._unknown_facts()
                }

                // A `T?` that is no pointer is a record with constructors
                // and a destructor of its own, defaulted only over a trivial
                // T: a relocatable T does not make it relocatable.
                var vf = self.facts_of_type(inner)
                out.relocatable = lifecycle_and(
                    vf.trivially_copyable,
                    vf.trivial_dtor,
                )

                if out.relocatable == LifecycleTri::No {
                    out.why_not_relocatable = "a nullable value is relocatable only when the value is trivially copyable and trivially destroyed"
                }

                self._held_deprecated_copy(t, unsafe &out)
                return out
            } default {
                // A generic parameter, or a type built from one by value.
                if t->is_dependent() || t->is_instantiation_dependent() {
                    return self._unknown_facts()
                }

                return out // builtins.
            }
        }
    }

    /// The facts of a by-value type that depends on a generic parameter: all
    /// of them are the instance's to decide.
    priv fn _unknown_facts(self) -> LifecycleFacts {
        var out = LifecycleFacts()
        out.copyable           = LifecycleTri::Unknown
        out.movable            = LifecycleTri::Unknown
        out.trivially_copyable = LifecycleTri::Unknown
        out.trivial_dtor       = LifecycleTri::Unknown
        out.destructible       = LifecycleTri::Unknown
        out.own_dtor_work      = LifecycleTri::Unknown
        out.virtual_dtor       = LifecycleTri::Unknown
        out.polymorphic        = LifecycleTri::Unknown
        out.assignable         = LifecycleTri::Unknown
        out.relocatable        = LifecycleTri::Unknown
        out.category           = LifecycleCategory::Unknown
        return out
    }

    priv fn _not_relocatable(self, f: unsafe *LifecycleFacts, const why: string) {
        f->relocatable         = LifecycleTri::No
        f->why_not_relocatable = why.copy()
    }

    /// The declaration `d`'s attributes are written on: an instance's are
    /// its pattern's.
    priv fn _pattern(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *pat = self.sc->body_of(d)
        return if (pat != &null) => (NameLookup::representative(pat)) else => d
    }

    /// facts_of_type for a reader that acts on the answer (file header,
    /// Asked too early). For a CONCRETE `t` every fact is definite from T
    /// on, so an open one is an ICE naming `caller` rather than a guess.
    /// A dependent type, and a record inside a generic owner (a non-generic
    /// ADT nested in a generic class), are open legitimately and come back
    /// as they are.
    fn facts_of_type_concrete(self, t: unsafe *Type, const caller: string) -> LifecycleFacts {
        var f = self.facts_of_type(t)
        if !lifecycle_open(unsafe &f) {
            return f
        }

        if t != &null {
            var unsafe *c = canon_unqual(t)
            if c != &null && (c->is_dependent() || c->is_instantiation_dependent()) {
                return f
            }

            var unsafe *d = self._tu.record_decl(c)
            if d != &null && decl_in_generic_owner(d) {
                return f
            }
        }

        if true {
            kairo::std::ice_fail(
                f"{caller}: the lifecycle facts of a concrete type are still open; they were asked before T resolved its parts",
            )
        }

        return f
    }

    /// Fold a component's facts into its owner's. A reason is recorded only
    /// for a definite No, and only the first: an Unknown has no reason yet.
    priv fn _absorb(self,
                    f:          unsafe *LifecycleFacts,
                    c:          unsafe *LifecycleFacts,
                    const what: string) {
        f->trivially_copyable = lifecycle_and(
            f->trivially_copyable,
            c->trivially_copyable,
        )

        f->trivial_dtor = lifecycle_and(f->trivial_dtor, c->trivial_dtor)
        f->destructible = lifecycle_and(f->destructible, c->destructible)
        var cp = lifecycle_and(f->copyable, c->copyable)
        if cp == LifecycleTri::No && f->copyable != LifecycleTri::No {
            f->why_not_copyable = f"{what} is not copyable"
        }

        f->copyable = cp
        var mv = lifecycle_and(f->movable, c->movable)
        if mv == LifecycleTri::No && f->movable != LifecycleTri::No {
            f->why_not_movable = f"{what} is not movable"
        }

        f->movable = mv
        var rl = lifecycle_and(f->relocatable, c->relocatable)
        if rl == LifecycleTri::No && f->relocatable != LifecycleTri::No {
            f->why_not_relocatable = f"{what} is not relocatable"
        }

        f->relocatable = rl
        if f->deprecated_copy == &null && c->deprecated_copy != &null {
            f->deprecated_copy     = c->deprecated_copy
            f->deprecated_copy_via = what.copy()
        }
    }

    /// The parts a library container or a nullable copies with itself: its
    /// own `@copy` when that is deprecated, else the first type argument
    /// (or the nullable's value) whose copy is.
    priv fn _held_deprecated_copy(self, t: unsafe *Type, out: unsafe *LifecycleFacts) {
        if t->kind == TypeKind::NullableType {
            var unsafe *inner = cast<NullableType>(t)->inner
            if inner == &null || inner->is_dependent() || inner->is_instantiation_dependent() {
                return
            }

            var nf = self.facts_of_type(inner)
            if nf.deprecated_copy != &null {
                out->deprecated_copy     = nf.deprecated_copy
                out->deprecated_copy_via = "its value"
            }

            return
        }

        var unsafe *d = self._tu.record_decl(t)
        if d == &null {
            return
        }

        var unsafe *pd = self._tu.pattern_of(d)
        var        ms  = self._methods(if (pd != &null) => (pd) else => d)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m != &null
                && m->transfer == TransferKind::Copy
                && AttrFacts::find(
                    unsafe (m as unsafe *Decl),
                    LangAttrs::deprecated(),
                ) != &null {
                out->deprecated_copy = m
                return
            }
        }

        if self.sc->instances == &null {
            return
        }

        var unsafe *e = self.sc->instances->entry_of(d)
        if e == &null {
            return
        }

        for var i: usize = 0; i < e->args.size(); ++i {
            var unsafe *a = e->args[i]
            if a == &null || a->is_dependent() || a->is_instantiation_dependent() {
                continue
            }

            var af = self.facts_of_type(a)
            if af.deprecated_copy != &null {
                out->deprecated_copy     = af.deprecated_copy
                out->deprecated_copy_via = f"its element type '{self._tu.str(canon_unqual(a))}'"
                return
            }
        }
    }

    priv fn _compute(self, d: unsafe *Decl, f: unsafe *LifecycleFacts) {
        if isa<EnumDecl>(d) {
            self._compute_enum(cast<EnumDecl>(d), f)
            return
        }

        f->in_progress = true

        var user_copy                            = false
        var user_move                            = false
        var copy_deleted                         = false
        var copy_written                         = false // deleted by `= delete` in a header, not by C++ (FFILinkage::ffi_deleted).
        var move_deleted                         = false
        var copy_provided                        = false
        var move_provided                        = false
        var user_dtor                            = false
        var dtor_deleted                         = false
        var dtor_provided                        = false
        var dtor_virtual                         = false
        var polymorphic                          = false
        var own_deprecated: unsafe *FunctionDecl = &null

        var methods = self._methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null {
                continue
            }

            // A pure `= virtual` one too: InterfaceEmitter declares it
            // `virtual`, so the class has a vptr all the same.
            if m->abi == AbiKind::Virtual
                || m->abi == AbiKind::Override
                || m->ffi_virtual
                || m->body_kind == FnBodyKind::Virtual {
                polymorphic = true
            }

            // Provided: neither `= default` nor `= delete`. A body-less
            // declaration counts -- an out-of-line definition, or an
            // imported ctor clang did not default -- since the user wrote it.
            var provided = m->body_kind != FnBodyKind::Default && m->body_kind != FnBodyKind::Delete
            if m->transfer == TransferKind::Copy {
                user_copy = true
                if AttrFacts::find(
                    unsafe (m as unsafe *Decl),
                    LangAttrs::deprecated(),
                ) != &null {
                    own_deprecated = m
                }

                if m->body_kind == FnBodyKind::Delete {
                    copy_deleted = true
                    copy_written = copy_written || m->ffi_deleted
                }

                if provided {
                    copy_provided = true
                }
            }

            if m->transfer == TransferKind::Move {
                user_move = true
                if m->body_kind == FnBodyKind::Delete {
                    move_deleted = true
                }

                if provided {
                    move_provided = true
                }
            }

            if self._is_dtor(m) {
                user_dtor = true
                if m->body_kind == FnBodyKind::Delete {
                    dtor_deleted = true
                }

                if provided {
                    dtor_provided = true
                }

                if m->abi == AbiKind::Virtual || m->abi == AbiKind::Override || m->ffi_virtual {
                    dtor_virtual = true
                }
            }
        }

        // C++ rules, since that is what the record lowers under.
        var copyable = !copy_deleted && (user_copy || !user_move)
        var movable  = !move_deleted && (user_move || copyable)
        f->copyable      = lifecycle_tri(copyable)
        f->movable       = lifecycle_tri(movable)
        f->user_transfer = user_copy || user_move
        // The declared category is whatever those two bits leave, not which
        // marker was written: a lone `@copy = delete` suppresses the implicit
        // move and a lone `@move = delete` deletes the implicit copy, so
        // either one alone is NON_TRANSFER, the same as both.
        if copyable {
            f->category = LifecycleCategory::Copy
        } else if movable {
            f->category = LifecycleCategory::Move
        } else {
            f->category = LifecycleCategory::NonTransfer
        }

        f->has_user_dtor = user_dtor
        // A defaulted destructor only runs the fields', which the field loop
        // below folds in; it does no work of its own.
        f->own_dtor_work = lifecycle_tri(dtor_provided)
        f->destructible  = lifecycle_tri(!dtor_deleted)
        f->virtual_dtor  = lifecycle_tri(dtor_virtual)
        if !copyable {
            f->why_not_copyable = if (copy_deleted) => ("its copy constructor is deleted")
                                  else => "it declares a move constructor and no copy constructor"
        }

        if !movable {
            f->why_not_movable = if (move_deleted) => ("its move constructor is deleted")
                                 else => f"it declares no move constructor and {f->why_not_copyable}"
        }

        // A transfer the user wrote a body for does whatever that body does,
        // so no base or field can take it away: a hand-written @copy over a
        // std::mutex builds a fresh mutex and copies, and a copy is a valid
        // move. Only a defaulted transfer, or one C++ generates because none
        // was declared, is memberwise and asks the components.
        var copy_pinned = copyable && copy_provided
        var move_pinned = movable && (move_provided || copy_provided)

        // clang's triviality bits for an imported record; ours otherwise.
        // Ours are C++'s for a member defaulted on its first declaration: it
        // is trivial when every base and field is, so `= default` decides
        // nothing here and the folding below does. A body (or a body-less
        // out-of-line declaration) is never trivial, and neither is a virtual
        // destructor. A deleted transfer leaves no transfer to be trivial --
        // the derived `op =` is deleted with it -- and a deleted destructor
        // makes nothing trivially copyable or destroyed.
        var unsafe *lay = self._layout(d)
        if lay != &null && lay->known {
            f->trivially_copyable = lifecycle_tri(lay->trivially_copyable)
            f->trivial_dtor       = lifecycle_tri(lay->trivial_dtor)
        } else {
            var dtor_trivial = !dtor_provided && !dtor_deleted && !dtor_virtual
            f->trivially_copyable = lifecycle_tri(
                !copy_provided && !move_provided && !copy_deleted && !move_deleted && dtor_trivial,
            )

            f->trivial_dtor = lifecycle_tri(dtor_trivial)
            if copy_deleted || move_deleted {
                self._not_relocatable(
                    f,
                    "it has a deleted transfer constructor",
                )
            } else if copy_provided || move_provided {
                self._not_relocatable(
                    f,
                    "it has a transfer constructor with a body and is not marked '@relocatable'",
                )
            } else if !dtor_trivial {
                self._not_relocatable(
                    f,
                    "it has a destructor and is not marked '@relocatable'",
                )
            }
        }

        // A vptr (a virtual method of its own) or a virtual-base offset
        // makes every copy rewrite part of the object instead of copying its
        // bytes, so a polymorphic record is not trivially copyable however
        // its transfers are declared. A base that is itself polymorphic
        // reaches here through the base fold below. Clang's bit already says
        // so for an imported record; asking again is the same answer. An
        // interface edge adds nothing: a virtual interface dispatches through
        // a witness table built outside the object, not a vptr inside it.
        // The destructor is untouched: only a virtual one is non-trivial,
        // and dtor_virtual already decided that above.
        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e  = c->derives_list.get(i)
                var unsafe *bd = self._base_decl(e->base)
                if bd != &null && isa<InterfaceDecl>(bd) {
                    continue
                }

                if e->is_virtual {
                    polymorphic = true
                }
            }
        }

        if polymorphic {
            f->trivially_copyable = LifecycleTri::No
            if f->relocatable != LifecycleTri::No {
                self._not_relocatable(f, "it is polymorphic")
            }
        }

        f->polymorphic = lifecycle_tri(polymorphic)

        // Bases.
        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e  = c->derives_list.get(i)
                var unsafe *bd = self._base_decl(e->base)
                if bd == &null {
                    // `derives T`: no decl to ask, and everything the base
                    // would fold in is the instance's.
                    if self._dependent_base(e->base) {
                        var uf = self._unknown_facts()
                        f->virtual_dtor = lifecycle_or(
                            f->virtual_dtor,
                            uf.virtual_dtor,
                        )

                        f->polymorphic = lifecycle_or(
                            f->polymorphic,
                            uf.polymorphic,
                        )

                        self._absorb(f, unsafe &uf, "its base")
                        self._absorb_assign(f, unsafe &uf, "its base")
                    }

                    continue
                }

                if isa<InterfaceDecl>(bd) {
                    continue
                }

                var unsafe *bf = self.facts_of(bd)
                if bf->in_progress { // a cycle; TypeCycleCheck's.
                    continue
                }

                f->virtual_dtor = lifecycle_or(
                    f->virtual_dtor,
                    bf->virtual_dtor,
                )

                f->polymorphic = lifecycle_or(f->polymorphic, bf->polymorphic)
                self._absorb(f, bf, f"its base '{self._tu.decl_name(bd)}'")
                self._absorb_assign(
                    f,
                    bf,
                    f"its base '{self._tu.decl_name(bd)}'",
                )
            }
        }

        // By-value fields.
        var fields = self._fields(d)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *fd = fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            if fd->type_ == &null || fd->type_->canonical == &null {
                continue
            }

            var ff = self.facts_of_type(self._through(fd->type_->canonical))
            if ff.in_progress {
                continue
            }

            f->own_dtor_work = lifecycle_or(
                f->own_dtor_work,
                lifecycle_not(ff.trivial_dtor),
            )

            self._absorb(
                f,
                unsafe &ff,
                f"its field '{self.sc->ctx->get_spelling(fd->name)}'",
            )

            self._absorb_assign(
                f,
                unsafe &ff,
                f"its field '{self.sc->ctx->get_spelling(fd->name)}'",
            )

            // Member by member, a const field cannot be assigned at all (C++
            // deletes the implicit `op =`). A transfer constructor with a body
            // rebuilds in place instead, which a const member does not stop;
            // that branch below overwrites this verdict.
            if fd->is_const() && f->assignable != LifecycleTri::No {
                f->assignable = LifecycleTri::No
                f->why_not_assignable = f"its field '{self.sc->ctx->get_spelling(fd->name)}' is const"
            }
        }

        // Undo what the folding did to a pinned transfer (see above). The
        // folding still ran for it: triviality and destructibility are the
        // components' whatever the transfer ctor's body says.
        if copy_pinned {
            f->copyable         = LifecycleTri::Yes
            f->why_not_copyable = ""
        }

        // A copy the record declares is the one that runs: its own mark
        // counts, and a part's does not reach through a written body (a
        // copy inside that body is reported there). A record that cannot
        // be copied runs none.
        if own_deprecated != &null || copy_pinned {
            f->deprecated_copy     = own_deprecated
            f->deprecated_copy_via = ""
        }

        if f->copyable == LifecycleTri::No {
            f->deprecated_copy     = &null
            f->deprecated_copy_via = ""
        }

        if move_pinned {
            f->movable         = LifecycleTri::Yes
            f->why_not_movable = ""
        }

        // An imported record whose copy C++ deleted because a part cannot
        // be copied (a defaulted copy over a move-only Kairo class: pair,
        // optional, tuple, since the stand-in carries the class's transfers,
        // TypeExport::_mirror_transfers) says which part, not only that the
        // copy is deleted. The verdict is clang's either way. A copy the
        // header deletes itself (`unique_ptr(const unique_ptr&) = delete`)
        // keeps "its copy constructor is deleted": no part is why.
        if copy_deleted && (!copy_written) && decl_is_imported(d) {
            var why = self._imported_copy_reason(d)
            if !why.is_empty() {
                f->why_not_copyable = why.copy()
            }
        }

        // Nothing declared: the weakest category the bases and fields allow
        // (file header), so the ones C++ would generate are what it reports.
        // Declared: it stands unless a dependent component left a defaulted
        // transfer open (a provided one is pinned above, so it never is).
        // NON_TRANSFER stands regardless: no field brings a deleted transfer
        // back.
        // An imported record whose transfers are all `= default` is the
        // same case as one that declares none: C++ defines a
        // defaulted copy that would copy a move-only member as DELETED and
        // keeps the defaulted move, so `std::pair<Mv, i32>` is MOVE. Both
        // must be declared: with the copy alone, C++ declares no move and an
        // rvalue falls back to the deleted copy. Only a
        // Kairo record keeps what it declared over its fields (a defaulted
        // `@copy` over a move-only field is SC129E there).
        var imported_defaulted = user_copy
            && user_move
            && (!copy_provided)
            && (!move_provided)
            && (!copy_deleted)
            && (!move_deleted)
            && decl_is_imported(d)
        if (!f->user_transfer) || imported_defaulted {
            f->category = self._folded_category(f)
        } else if f->category != LifecycleCategory::NonTransfer
            && (f->copyable == LifecycleTri::Unknown || f->movable == LifecycleTri::Unknown) {
            f->category = LifecycleCategory::Unknown
        }

        self._settle_non_transfer(f)

        // The derived `op =` (file header, Assignment). The fold above is
        // member by member, which is what a defaulted transfer or none
        // gives; a deleted transfer gives none; a body destroys and rebuilds,
        // which no part's `op =` takes part in but which a polymorphic or an
        // indestructible record cannot take. An imported record's
        // assignment is its own, never derived.
        if lay != &null && lay->known {
            f->assignable         = LifecycleTri::Yes
            f->why_not_assignable = ""
        } else if copy_deleted || move_deleted {
            f->assignable         = LifecycleTri::No
            f->why_not_assignable = "its transfer constructor is deleted"
        } else if copy_provided || move_provided {
            f->assignable = lifecycle_and(
                lifecycle_not(f->polymorphic),
                f->destructible,
            )

            f->why_not_assignable = ""
            if f->polymorphic == LifecycleTri::Yes {
                f->why_not_assignable = "it is polymorphic, and assigning it would destroy it and rebuild it in place through its transfer constructor"
                f->poly_rebuild = true
            } else if f->destructible == LifecycleTri::No {
                f->why_not_assignable = "assigning it destroys the old value first, and it cannot be destroyed"
            }
        }

        // The declaration decides, not the parts: `@relocatable` says the
        // bytes may be moved (a part that cannot be is _check_relocatable's
        // error), and an imported record passes the way clang says it does.
        if AttrFacts::is_relocatable(d) {
            f->relocatable         = LifecycleTri::Yes
            f->why_not_relocatable = ""
        } else if lay != &null && lay->known {
            f->relocatable         = lifecycle_tri(lay->trivial_for_calls)
            f->why_not_relocatable = ""
            if !lay->trivial_for_calls {
                f->why_not_relocatable = "it is a C++ type with a non-trivial copy constructor, move constructor or destructor"
            }
        }

        f->in_progress = false
    }

    /// An enum's facts (file header). A plain enum has no payload, so the
    /// LifecycleFacts defaults stand. An ADT declares no transfer ctor or
    /// destructor of its own, so everything it has comes from the payloads.
    priv fn _compute_enum(self, en: unsafe *EnumDecl, f: unsafe *LifecycleFacts) {
        f->in_progress = true

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null {
                continue
            }

            for var j: usize = 0; j < v->payload.size(); ++j {
                var unsafe *fd = v->payload[j]
                if fd == &null {
                    continue
                }

                // Unresolved: T reported it, and guessing here would only add
                // a second error about a type nobody could name.
                if fd->type_ == &null || fd->type_->canonical == &null {
                    continue
                }

                var fname = self.sc->ctx->get_spelling(fd->name)
                var vname = self.sc->ctx->get_spelling(v->name)
                // A field naming the pack of a pack-expanded variant is one
                // field per element at an instance, so each element is
                // folded: the pack substitutes as no single type.
                var pes = cxx::std::vector<unsafe *Type>()
                if v->is_pack_expansion && self._pack_elems(fd, unsafe &pes) {
                    for var k: usize = 0; k < pes.size(); ++k {
                        var ef = self.facts_of_type(pes[k])
                        self._absorb_payload(
                            f,
                            unsafe &ef,
                            f"the payload field '{fname}: {self._tu.str(pes[k])}' of variant '{vname}'",
                        )
                    }

                    continue
                }

                var pf = self.facts_of_type(self._through(fd->type_->canonical))
                self._absorb_payload(
                    f,
                    unsafe &pf,
                    f"the payload field '{fname}' of variant '{vname}'",
                )
            }
        }

        // The weakest category the payloads allow.
        f->category = self._folded_category(f)
        // Not left to the payload fold: two payloads that are each still
        // trivially copyable (one move-only, one an import with its move
        // deleted) can together leave an ADT that transfers neither way.
        self._settle_non_transfer(f)
        // An ADT's `op =` rebuilds the payload through the payload's own
        // transfer constructor (EnumLayoutLowering) and never assigns it, so
        // it exists whenever the ADT transfers at all.
        f->assignable = lifecycle_or(f->copyable, f->movable)
        if f->assignable == LifecycleTri::No {
            f->why_not_assignable = "it can be neither copied nor moved"
        }

        // Its special members are written out unless every payload is
        // trivial, so a relocatable payload does not make it relocatable.
        f->relocatable = lifecycle_and(f->trivially_copyable, f->trivial_dtor)
        f->why_not_relocatable = ""
        if f->relocatable == LifecycleTri::No {
            f->why_not_relocatable = "an enum with payloads is relocatable only when every payload is trivially copyable and trivially destroyed"
        }

        f->in_progress = false
    }

    /// One payload field's facts `pf` folded into its ADT's `f`.
    priv fn _absorb_payload(self,
                            f:          unsafe *LifecycleFacts,
                            pf:         unsafe *LifecycleFacts,
                            const what: string) {
        if pf->in_progress { // a cycle; TypeCycleCheck's.
            return
        }

        f->own_dtor_work = lifecycle_or(
            f->own_dtor_work,
            lifecycle_not(pf->trivial_dtor),
        )

        self._absorb(f, pf, what)
    }

    /// The elements, in `out`, of the type pack payload field `fd` names
    /// bare (`error: E`) at the instance being computed; false outside an
    /// instance or for any other field.
    priv fn _pack_elems(self,
                        fd:  unsafe *FieldDecl,
                        out: unsafe *cxx::std::vector<unsafe *Type>) -> bool {
        if self._sub == &null {
            return false
        }

        var unsafe *g = dyn_cast<GenericParamType>(
            canon_unqual(fd->type_->canonical),
        )

        if g == &null || !g->is_pack {
            return false
        }

        return self._sub->pack_elems(g->owner, g->param_index, out)
    }

    /// The weakest category folded facts allow (COPY > MOVE > NON_TRANSFER),
    /// for an ADT and for a record that declares no transfer constructor.
    /// Read off the copyable / movable bits rather than each component's own
    /// `category`: a declared one records what was WRITTEN, so a defaulted
    /// `@copy` over a move-only field still declares COPY (SC129E's case)
    /// while the folded bits say it copies nothing. A definite NON_TRANSFER
    /// is decided even beside an Unknown (the folding is Kleene AND);
    /// anything else open is Unknown.
    priv fn _folded_category(self, f: unsafe *LifecycleFacts) -> LifecycleCategory {
        if f->copyable == LifecycleTri::Yes {
            return LifecycleCategory::Copy
        }

        if f->copyable == LifecycleTri::No && f->movable == LifecycleTri::Yes {
            return LifecycleCategory::Move
        }

        if f->copyable == LifecycleTri::No && f->movable == LifecycleTri::No {
            return LifecycleCategory::NonTransfer
        }

        return LifecycleCategory::Unknown
    }

    /// A NON_TRANSFER record is not trivially copyable (file header). Run
    /// once the category is final -- a derived category is only known after
    /// the fold -- and only for a definite one: an Unknown category leaves
    /// the bit to the instance. Overrides clang too: std::mutex deletes both
    /// transfers yet reads trivially copyable there, and a later lowering
    /// that read that Yes would default a copy the type forbids.
    priv fn _settle_non_transfer(self, f: unsafe *LifecycleFacts) {
        if f->category == LifecycleCategory::NonTransfer {
            f->trivially_copyable = LifecycleTri::No
        }
    }

    /// # the virtual-destructor rule

    fn visit_class_decl(self, n: unsafe *ClassDecl) -> bool {
        if n == &null {
            return true
        }

        if n->is_poisoned() {
            return true
        }

        // Every class, not only derived ones: rules 1-4 are about the
        // class's own members, so this sits above the no-base early-out.
        self._check_transfer_shapes(n, self.sc->ctx->get_spelling(n->name))
        self._check_lifecycle_rules(n)
        self._check_relocatable(unsafe (n as unsafe *Decl))
        self._derive_assign(n)
        if n->derives_list.size() == 0 {
            return true
        }

        self.n_checked += 1

        var unsafe *df = self.facts_of(unsafe (n as unsafe *Decl))
        // Own work, not `trivial_dtor`: that absorbs the base's destructor,
        // which made every class deriving a non-trivial base an error -- even
        // one adding nothing a base-typed `delete` would skip.
        if df->own_dtor_work == LifecycleTri::No {
            return true
        }

        // An Unknown is the pattern's; each instance is asked again (instance_failures).
        if df->own_dtor_work == LifecycleTri::Unknown {
            return true
        }

        var dn = self.sc->ctx->get_spelling(n->name)

        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var unsafe *e  = n->derives_list.get(i)
            var unsafe *bd = self._base_decl(e->base)
            if bd == &null {
                continue
            }

            if isa<InterfaceDecl>(bd) {
                continue
            }

            var unsafe *bf = self.facts_of(bd)
            if bf->virtual_dtor == LifecycleTri::Yes {
                continue
            }

            // An Unknown is the pattern's; each instance is asked again (instance_failures).
            if bf->virtual_dtor == LifecycleTri::Unknown {
                continue
            }

            // A base that is not polymorphic is reported at a `destroy` of
            // its type instead (_check_destroy_calls).
            if bf->polymorphic != LifecycleTri::Yes {
                self._plain_bases.push(NameLookup::representative(bd))
            }

            // Only a POLYMORPHIC base is deleted through, as clang's
            // -Wdelete-non-virtual-dtor has it: a base with no virtual
            // method is a mixin (Decl, DeclContext, Redeclarable), never the
            // static type of a `delete`. Unknown is the pattern's, as above.
            if bf->polymorphic != LifecycleTri::Yes {
                continue
            }

            var bn = self._tu.decl_name(bd)
            var b = self.sc->diag->report(
                DiagID::SC056E,
                e->range.start,
                f"class '{dn}' has a non-trivial destructor, but its base '{bn}' does not have a virtual destructor; deleting a '{dn}' through a '*{bn}' would run only '{bn}''s destructor and leak the rest",
            )

            b.first(e->range)
            b.note(
                bd->range.start,
                f"declare 'virtual fn op finally(self)' in '{bn}' and 'override fn op finally(self)' in '{dn}'",
            )->child_first(bd->range)
            b.emit()
            self.n_errored += 1
        }

        return true
    }

    fn visit_struct_decl(self, n: unsafe *StructDecl) -> bool {
        if n == &null {
            return true
        }

        if n->is_poisoned() {
            return true
        }

        self._check_transfer_shapes(
            unsafe (n as unsafe *Decl),
            self.sc->ctx->get_spelling(n->name),
        )

        self._check_relocatable(unsafe (n as unsafe *Decl))
        self._derive_assign(unsafe (n as unsafe *Decl))
        return true
    }

    fn visit_union_decl(self, n: unsafe *UnionDecl) -> bool {
        if n != &null && !n->is_poisoned() {
            self._check_union_defaults(n)
            self._check_relocatable(unsafe (n as unsafe *Decl))
        }

        return true
    }

    /// A union's default constructor makes one field the live one: the field
    /// with a default. A second field with a default would be a second live
    /// field. `static` and `eval` fields are not part of the value.
    priv fn _check_union_defaults(self, n: unsafe *UnionDecl) {
        var first: unsafe *FieldDecl = &null
        for var i: usize = 0; i < n->fields.size(); ++i {
            var unsafe *fd = n->fields[i]
            if fd == &null || fd->init == &null {
                continue
            }

            if fd->storage == StorageClass::Static || fd->storage == StorageClass::Eval {
                continue
            }

            if first == &null {
                first = fd
                continue
            }

            var un  = self.sc->ctx->get_spelling(n->name)
            var fn_ = self.sc->ctx->get_spelling(fd->name)
            var b = self.sc->diag->report(
                DiagID::SC359E,
                fd->range.start,
                f"only one field of a union may have a default: '{fn_}' and '{self.sc->ctx->get_spelling(first->name)}' of '{un}' both have one",
            )

            // From the end of the written type (else the name) through the
            // initializer: `var f: f32 = 1.0` keeps `var f: f32`.
            var from = if (fd->type_ != &null
                           && fd->type_->range.is_valid()) => (fd->type_->range.end)
                       else => fd->name.range.end
            b.first(fd->init->range)
            b.remove(
                SourceRange(from, fd->init->range.end),
                "remove this default",
            )

            b.note(first->range.start, "the first field with a default is here")->child_first(
                first->init->range,
            )

            b.emit()
            fd->poison()
            self.n_errored += 1
        }
    }

    /// # `@relocatable`

    /// What stops `@relocatable` on `d` (a pattern, or an instance's body
    /// read through `sub` and named `dn`): one failure per base and
    /// by-value field that is not relocatable, else the record's own
    /// reason. A part `sub` leaves Unknown is skipped, and so is one the
    /// pattern already answered No for when `sub` is set: the declaration
    /// reported it.
    priv fn _relocatable_failures(self,
                                  d:          unsafe *Decl,
                                  sub:        unsafe *Substitution,
                                  const dn:   string,
                                  @inout out: [LifecycleFailure]) {
        var at   = AttrFacts::find(d, LangAttrs::relocatable())->range
        var head = f"'{LangAttrs::at(LangAttrs::relocatable())}' cannot be applied to '{dn}'"
        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e  = c->derives_list.get(i)
                var unsafe *pb = self._base_decl(e->base)
                var unsafe *bd = pb
                if sub != &null {
                    if pb != &null
                        && (isa<InterfaceDecl>(pb)
                            || self.facts_of(pb)->relocatable == LifecycleTri::No) {
                        continue
                    }

                    bd = self._inst_base(&*sub, e->base)
                }

                if bd == &null || isa<InterfaceDecl>(bd) {
                    continue
                }

                var unsafe *bf = self.facts_of(bd)
                if bf->in_progress || bf->relocatable != LifecycleTri::No {
                    continue
                }

                var bn = self._tu.decl_name(bd)
                if sub != &null {
                    bn = self._tu.str(
                        self._inst_type(&*sub, e->base->canonical),
                    )
                }

                var x = LifecycleFailure()
                x.id  = DiagID::SC356E
                x.at  = at
                x.msg = f"{head}: its base '{bn}' is not relocatable"
                x.add_note(
                    DiagID::SC356N,
                    e->range,
                    f"'{bn}' is not relocatable: {bf->why_not_relocatable}",
                )

                if sub != &null {
                    x.add_note(DiagID::I900N, at, f"'{dn}' is marked here")
                }

                out.push(x)
            }
        }

        var fields = self._fields(d)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *fd = fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            if fd->type_ == &null || fd->type_->canonical == &null {
                continue
            }

            var unsafe *ft = canon_unqual(fd->type_->canonical)
            if sub != &null {
                if self.facts_of_type(ft).relocatable == LifecycleTri::No {
                    continue
                }

                ft = self._inst_type(&*sub, ft)
            }

            var ff = self.facts_of_type(ft)
            if ff.in_progress || ff.relocatable != LifecycleTri::No {
                continue
            }

            var fname = self.sc->ctx->get_spelling(fd->name)
            var tn    = self._tu.str(ft)
            var x     = LifecycleFailure()
            x.id  = DiagID::SC356E
            x.at  = at
            x.msg = f"{head}: its field '{fname}' of type '{tn}' is not relocatable"
            x.add_note(
                DiagID::SC356N,
                fd->range,
                f"'{tn}' is not relocatable: {ff.why_not_relocatable}",
            )

            if sub != &null {
                x.add_note(DiagID::I900N, at, f"'{dn}' is marked here")
            }

            out.push(x)
        }

        if out.size() != 0 || sub != &null {
            return
        }

        // The record's own shape, which no instance changes.
        var unsafe *f  = self.facts_of(d)
        var        why = ""
        if f->polymorphic == LifecycleTri::Yes {
            why = "it is polymorphic, and its bytes hold the address of its virtual table"
        } else if f->category == LifecycleCategory::NonTransfer {
            why = "its transfer constructors are deleted, so nothing moves it"
        }

        if why.is_empty() {
            return
        }

        var x = LifecycleFailure()
        x.id  = DiagID::SC356E
        x.at  = at
        x.msg = f"{head}: {why}"
        out.push(x)
    }

    priv fn _check_relocatable(self, d: unsafe *Decl) {
        if !AttrFacts::is_relocatable(d) {
            return
        }

        var fails: [LifecycleFailure]
        self._relocatable_failures(d, &null, self._tu.decl_name(d), &fails)

        for var i: usize = 0; i < fails.size(); ++i {
            var *x = &fails[i]
            var b  = self.sc->diag->report(x->id, x->at.start, x->msg.copy())
            b.first(x->at)
            for var j: usize = 0; j < x->note_ids.size(); ++j {
                b.note(
                    DiagCode(x->note_ids[j]),
                    x->note_at[j].start,
                    x->note_msg[j],
                )->child_first(x->note_at[j])
            }

            b.emit()
            self.n_errored += 1
        }
    }

    /// # transfer-constructor shapes

    /// Classify every constructor of `d`, reject the shapes C++ would read
    /// as a transfer constructor Kairo did not declare as one, and stamp the
    /// accepted ones (see the file header). The one writer of both: this is
    /// where the transfer constructor is found, so the rule and the stamp
    /// cannot disagree about which constructor it is.
    priv fn _check_transfer_shapes(self, d: unsafe *Decl, const dn: string) {
        var methods = self._methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || m->is_operator || m->is_poisoned() {
                continue
            }

            if self._tu.decl_name(unsafe (m as unsafe *Decl)) != dn { // not a constructor.
                continue
            }

            // `self`, then the first parameter after it.
            var selfp: unsafe *ParamDecl = &null
            var at                       = usize::MAX
            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *q = m->params[j]
                if q == &null {
                    continue
                }

                if q->is_self {
                    selfp = q
                    continue
                }

                if at == usize::MAX {
                    at = j
                }
            }

            if selfp == &null || at == usize::MAX {
                continue
            }

            var unsafe *p = m->params[at]

            // `Self`, any cv, any mode. The receiver's own canonical IS Self
            // (TypeResolution synthesizes it), generic records included, and
            // canonicals are uniqued, so this is identity, not a structural
            // compare that `Box<i32>` inside `class <T> Box` could fool.
            if p->type_ == &null || p->type_->canonical == &null {
                continue
            }

            if selfp->type_ == &null || selfp->type_->canonical == &null {
                continue
            }

            if canon_unqual(p->type_->canonical) != canon_unqual(
                selfp->type_->canonical,
            ) {
                continue
            }

            // Every later parameter defaulted, or C++ does not read it as a
            // transfer constructor: `X(self, other: Self, extra: i32)` is an
            // ordinary constructor that happens to take a Self first. A pack
            // has no default and makes it a template, never a copy ctor.
            var tail           = false
            var tail_defaulted = true
            for var j: usize = at + 1; j < m->params.size(); ++j {
                var unsafe *q = m->params[j]
                if q == &null {
                    continue
                }

                tail = true
                if q->is_pack || q->default_val == &null && !q->has_default {
                    tail_defaulted = false
                }
            }

            if !tail_defaulted {
                continue
            }

            if m->transfer == TransferKind::NotTransfer {
                self._report_unmarked_transfer(m, p, dn)
                continue
            }

            // Marked: `other` is written bare, so the marker is the only
            // thing that decides the C++ shape.
            var marker = if (m->transfer == TransferKind::Copy) => (LangAttrs::at(
                             LangAttrs::transfer_copy(),
                         ))
                         else => LangAttrs::at(LangAttrs::transfer_move())
            if p->mode != ParamMode::Value || p->default_val != &null || tail {
                var b = self.sc->diag->report(
                    DiagID::SC110E,
                    p->range.start,
                    f"the parameter of a '{marker}' constructor is written 'other: Self', with no mode, no default and nothing after it",
                )

                b.first(p->range)
                if p->mode != ParamMode::Value {
                    b.remove(
                        p->mode_range,
                        f"remove the parameter mode; '{marker}' on the constructor already decides how 'other' is passed",
                    )
                }

                b.emit()
                self.n_errored += 1
                continue
            }

            if m->transfer == TransferKind::Move && p->is_const {
                self.sc->diag->report(
                    DiagID::SC110E,
                    p->range.start,
                    "a move constructor cannot take a const source; it leaves the source empty",
                ).first(p->range)->emit()
                self.n_errored += 1
                continue
            }

            // The stamp. `@copy` keeps `const` as written: `const X&` is the
            // usual copy, plain `X&` is legal C++ and X reports a const or
            // temporary source where the copy is made.
            if m->transfer == TransferKind::Copy {
                p->mode = ParamMode::Inout
            } else {
                p->mode = ParamMode::Move
            }
        }
    }

    /// A constructor of transfer shape with no `@copy` / `@move`. C++ would
    /// make it a copy or move constructor anyway (or reject it outright as a
    /// by-value one), so it is an error at the declaration, never a second
    /// spelling -- that would bypass every rule keyed on the marker.
    priv fn _report_unmarked_transfer(self,
                                      m:        unsafe *FunctionDecl,
                                      p:        unsafe *ParamDecl,
                                      const dn: string) {
        var b = self.sc->diag->report(
            DiagID::SC110E,
            m->range.start,
            f"a constructor taking 'Self' first is a transfer constructor; declare it '{LangAttrs::at(LangAttrs::transfer_copy())} fn {dn}(self, const other: Self)' or '{LangAttrs::at(LangAttrs::transfer_move())} fn {dn}(self, other: Self)'",
        )

        b.first(m->range)
        if p->mode != ParamMode::Value {
            var mw = if (p->mode == ParamMode::Move) => (LangAttrs::at(
                         LangAttrs::param_move(),
                     ))
                     else => LangAttrs::at(LangAttrs::param_inout())
            b.note(
                p->mode_range.start,
                f"'{mw}' on the parameter is not a transfer constructor",
            )->child_first(p->mode_range)
        }

        b.emit()
        self.n_errored += 1
    }

    /// The doc's rules about the lifecycle itself (Classes: Lifecycle
    /// Categories). One error per rule per class, at the offending member.
    priv fn _check_lifecycle_rules(self, n: unsafe *ClassDecl) {
        var unsafe *f = self.facts_of(unsafe (n as unsafe *Decl))
        var        dn = self.sc->ctx->get_spelling(n->name)

        // The first transfer ctor of each kind, and the first one that
        // repeats a kind already seen (with the one it repeats).
        var copy_ctor: unsafe *FunctionDecl = &null
        var move_ctor: unsafe *FunctionDecl = &null
        var dup_of:    unsafe *FunctionDecl = &null
        var dup:       unsafe *FunctionDecl = &null
        var dtor:      unsafe *FunctionDecl = &null
        var assign:    unsafe *FunctionDecl = &null
        for var i: usize = 0; i < n->methods.size(); ++i {
            var unsafe *m = n->methods[i]
            if m == &null {
                continue
            }

            // Compiler-made, not declared: "one transfer constructor" and "no
            // user `op =`" are rules about what a user writes (see _methods).
            if m->adt_role != AdtRole::None {
                continue
            }

            if m->transfer == TransferKind::Copy {
                if copy_ctor == &null {
                    copy_ctor = m
                } else if dup == &null {
                    dup_of = copy_ctor
                    dup    = m
                }
            }

            if m->transfer == TransferKind::Move {
                if move_ctor == &null {
                    move_ctor = m
                } else if dup == &null {
                    dup_of = move_ctor
                    dup    = m
                }
            }

            if self._is_dtor(m) {
                dtor = m
            }

            if m->is_operator
                && m->op_token.size() > 0
                && m->op_token[0].kind == TokenKind::OpEqual {
                assign = m
            }
        }

        // 1. One transfer constructor. Both is legal only as NON_TRANSFER
        //    (both `= delete`), the ScopeLock shape. Two of one kind never
        //    are: RedeclMerge keeps any two marked constructors apart so
        //    the error is this one, not a redeclaration -- `@copy` with and
        //    without `const` on `other` would otherwise merge as one member,
        //    since top-level const is not in a signature.
        if dup != &null {
            var marker = if (dup->transfer == TransferKind::Copy) => (LangAttrs::at(
                             LangAttrs::transfer_copy(),
                         ))
                         else => LangAttrs::at(LangAttrs::transfer_move())
            self.sc->diag->report(
                DiagID::SC057E,
                dup->range.start,
                f"'{dn}' declares more than one '{marker}' transfer constructor; a class has exactly one transfer constructor",
            ).first(dup->range)->note(
                dup_of->range.start,
                "the other transfer constructor is here",
            )->child_first(dup_of->range)->emit()
            dup->poison()
            self.n_errored += 1
        } else if copy_ctor != &null
            && move_ctor != &null
            && !(copy_ctor->body_kind == FnBodyKind::Delete
                && move_ctor->body_kind == FnBodyKind::Delete) {
            self.sc->diag->report(
                DiagID::SC057E,
                move_ctor->range.start,
                f"'{dn}' declares both a {LangAttrs::quoted(LangAttrs::transfer_copy())} and a {LangAttrs::quoted(LangAttrs::transfer_move())} transfer constructor; pick one " + "(both may be '= delete' together, which makes the class non-transferable)",
            ).first(move_ctor->range)->note(
                copy_ctor->range.start,
                "the other transfer constructor is here",
            )->child_first(copy_ctor->range)->emit()
            move_ctor->poison()
            self.n_errored += 1
        }

        // 2. `op =` is auto-derived from the transfer constructor; writing
        //    it is an error.
        if assign != &null {
            self.sc->diag->report(
                DiagID::SC058E,
                assign->range.start,
                f"'{dn}' defines 'op ='; assignment is derived from the transfer constructor and cannot be written",
            ).first(assign->range)->emit()
            assign->poison()
            self.n_errored += 1
        }

        // 3. A transfer ctor with a BODY derives an `op =` that destroys
        //    self first; a deleted destructor makes that impossible.
        var unsafe *xfer = if (move_ctor != &null) => (move_ctor) else => copy_ctor
        if xfer != &null
            && dtor != &null
            && (xfer->body_kind == FnBodyKind::Block || xfer->body_kind == FnBodyKind::Expr)
            && dtor->body_kind == FnBodyKind::Delete {
            self.sc->diag->report(
                DiagID::SC059E,
                xfer->range.start,
                f"'{dn}' has a transfer constructor with a body and a deleted destructor; the derived 'op =' must destroy the old value first and cannot",
            ).first(xfer->range)->note(
                dtor->range.start,
                "destructor deleted here",
            )->child_first(dtor->range)->note(
                xfer->range.start,
                "provide a destructor, or make the transfer constructor '= default' / '= delete'",
            )->emit()
            xfer->poison()
            self.n_errored += 1
        }

        // 3b. A move constructor with a body that only reads `other`, in a
        //     class with a destructor and an address to release: source
        //     and target both hold the address, and the destructor runs on
        //     both. Fields of trivially destroyed non-pointer types hold
        //     nothing to release twice, and a field whose type has a
        //     destructor releases what it holds itself.
        if move_ctor != &null
            && dtor != &null
            && dtor->body_kind != FnBodyKind::Default
            && dtor->body_kind != FnBodyKind::Delete
            && move_ctor->body_kind == FnBodyKind::Block
            && move_ctor->body_block != &null
            && self._holds_address(unsafe (n as unsafe *Decl), 0) {
            var src: unsafe *ParamDecl = &null
            for var i: usize = 0; i < move_ctor->params.size(); ++i {
                var unsafe *q = move_ctor->params[i]
                if q != &null && !q->is_self {
                    src = q
                    break
                }
            }

            if src != &null {
                var scan = MoveSourceScan(unsafe (src as unsafe *Decl))
                scan.scan(move_ctor->body_block)
                if !scan.may_write() {
                    self.sc->diag->report(
                        DiagID::SC001W,
                        move_ctor->range.start,
                        f"the {LangAttrs::quoted(LangAttrs::transfer_move())} constructor of '{dn}' never writes '{self.sc->ctx->get_spelling(src->name)}', so both objects keep the resource and the destructor runs on each",
                    ).first(move_ctor->range)->note(
                        dtor->range.start,
                        "the destructor is here; reset the source's fields in the constructor",
                    )->child_first(dtor->range)->emit()
                }
            }
        }

        // 4. Custom destructor, implicit copy: almost always an owned
        //    resource that will be silently copied. Warning, per the doc.
        //    Only when the derived category really is COPY: a move-only or
        //    non-transferable field already keeps C++ from generating the
        //    copy, so there is nothing silent to warn about.
        //    Not re-asked per instance: an instance of a generic that left
        //    the category open would warn about a declaration it cannot
        //    change.
        if dtor != &null
            && dtor->body_kind != FnBodyKind::Default
            && dtor->body_kind != FnBodyKind::Delete
            && !f->user_transfer
            && f->category == LifecycleCategory::Copy {
            self.sc->diag->report(
                DiagID::SC060W,
                dtor->range.start,
                f"'{dn}' has a custom destructor but no {LangAttrs::quoted(LangAttrs::transfer_copy())} or {LangAttrs::quoted(LangAttrs::transfer_move())} transfer constructor; it is implicitly copyable",
            ).first(dtor->range)->note(
                dtor->range.start,
                f"declare it move-only: '{LangAttrs::at(LangAttrs::transfer_move())} fn {dn}(self, other: Self) = default'",
            )->note(
                dtor->range.start,
                f"or make it non-transferable: '{LangAttrs::at(LangAttrs::transfer_copy())} fn {dn}(self, const other: Self) = delete'",
            )->emit()
        }

        // 4b. A move-only record with a destructor and no constructor is a
        //     C++ aggregate, and C++ declares no implicit move beside a
        //     user-declared destructor: no value of it could be moved.
        //     Declaring the move would end aggregate initialization, so the
        //     record has to say how it is built or how it moves.
        if dtor != &null
            && !f->user_transfer
            && f->category == LifecycleCategory::Move
            && !self._declares_ctor(n) {
            var b = self.sc->diag->report(
                DiagID::SC358E,
                n->range.start,
                f"'{dn}' is move-only and has a destructor but no constructor, so it cannot be moved: write a constructor or a {LangAttrs::quoted(LangAttrs::transfer_move())} constructor",
            )

            b.first(n->name.range)
            b.note(dtor->range.start, "the destructor is declared here")->child_first(
                dtor->range,
            )

            b.note(
                f"declare a constructor 'fn {dn}(self)', or the move '{LangAttrs::at(LangAttrs::transfer_move())} fn {dn}(self, other: Self) = default'",
            )

            b.emit()
            self.n_errored += 1
        }

        // 5. Category compatibility with every base (doc table): a COPY
        //    base admits COPY / NON_TRANSFER; MOVE admits MOVE / NON_TRANSFER;
        //    NON_TRANSFER admits NON_TRANSFER only. The bad case is a
        //    copyable base under a move-only derived: slicing through a
        //    base pointer would copy a subobject that promised not to be.
        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var unsafe *e  = n->derives_list.get(i)
            var unsafe *bd = self._base_decl(e->base)
            if bd == &null || isa<InterfaceDecl>(bd) {
                continue
            }

            var unsafe *bf = self.facts_of(bd)
            // An Unknown is the pattern's; each instance is asked again (instance_failures).
            if f->category == LifecycleCategory::Unknown
                || bf->category == LifecycleCategory::Unknown {
                continue
            }

            var ok = f->category == LifecycleCategory::NonTransfer || f->category == bf->category
            if ok {
                continue
            }

            var bn = self._tu.decl_name(bd)
            self.sc->diag->report(
                DiagID::SC061E,
                e->range.start,
                f"'{dn}' is {self._cat_word(f->category)}, but its base '{bn}' is {self._cat_word(bf->category)}; a derived class's lifecycle category must match its base's, or be non-transferable",
            ).first(e->range)->note(bd->range.start, "base declared here")->child_first(
                bd->range,
            )->emit()
            self.n_errored += 1
        }

        // 6. A defaulted transfer constructor transfers memberwise, so every
        //    base and by-value field must transfer that way: a defaulted
        //    `@copy` needs each copyable, a defaulted `@move` each movable (a
        //    COPY-only field is copied as part of the move, per the doc). C++
        //    would quietly define it as deleted instead, and the class would
        //    claim a category it cannot transfer as.
        if copy_ctor != &null
            && !copy_ctor->is_poisoned()
            && copy_ctor->body_kind == FnBodyKind::Default {
            self._check_defaulted_transfer(n, copy_ctor, dn)
        }

        if move_ctor != &null
            && !move_ctor->is_poisoned()
            && move_ctor->body_kind == FnBodyKind::Default {
            self._check_defaulted_transfer(n, move_ctor, dn)
        }
    }

    /// Rule 6 for one defaulted transfer ctor `x` of `n`: the first base,
    /// then the first field, that cannot be transferred the way `x` does,
    /// in the order C++ constructs them. One error per constructor.
    priv fn _check_defaulted_transfer(self,
                                      n:        unsafe *ClassDecl,
                                      x:        unsafe *FunctionDecl,
                                      const dn: string) {
        var is_copy = x->transfer == TransferKind::Copy
        var kind    = if (is_copy) => ("copy") else => "move"

        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var unsafe *e  = n->derives_list.get(i)
            var unsafe *bd = self._base_decl(e->base)
            if bd == &null || isa<InterfaceDecl>(bd) {
                continue
            }

            var unsafe *bf = self.facts_of(bd)
            if bf->in_progress { // a cycle; TypeCycleCheck's.
                continue
            }

            var why = self._untransferable(bf, is_copy)
            if why.size() == 0 {
                continue
            }

            var bn = self._tu.decl_name(bd)
            var b = self.sc->diag->report(
                DiagID::SC129E,
                x->range.start,
                f"'{dn}' cannot have a defaulted {kind} constructor: base '{bn}' is {why}",
            )

            b.first(x->range)
            b.note(
                DiagCode(DiagID::SC129N),
                e->range.start,
                f"'{bn}' is a base of '{dn}' here",
            )->child_first(e->range)
            b.emit()
            self.n_errored += 1
            return
        }

        var fields = self._fields(unsafe (n as unsafe *Decl))
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *fd = fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            if fd->type_ == &null || fd->type_->canonical == &null {
                continue
            }

            var ff = self.facts_of_type(fd->type_->canonical)
            if ff.in_progress { // a cycle; TypeCycleCheck's.
                continue
            }

            var why = self._untransferable(unsafe &ff, is_copy)
            if why.size() == 0 {
                continue
            }

            var fname = self.sc->ctx->get_spelling(fd->name)
            var tn    = self._tu.str(fd->type_->canonical)
            var b = self.sc->diag->report(
                DiagID::SC129E,
                x->range.start,
                f"'{dn}' cannot have a defaulted {kind} constructor: field '{fname}' of type '{tn}' is {why}",
            )

            b.first(x->range)
            b.note(
                DiagCode(DiagID::SC129N),
                fd->range.start,
                f"'{fname}' declared here",
            )->child_first(fd->range)

            b.emit()
            self.n_errored += 1
            return
        }
    }

    /// Why a component with facts `c` cannot be transferred by a defaulted
    /// copy (`is_copy`) or move, or "" when it can or cannot be told yet.
    priv fn _untransferable(self, c: unsafe *LifecycleFacts, is_copy: bool) -> string {
        // An Unknown is the pattern's; each instance is asked again (instance_failures).
        if is_copy {
            if c->copyable != LifecycleTri::No {
                return ""
            }

            if c->movable == LifecycleTri::Yes {
                return "move-only"
            }

            if c->movable == LifecycleTri::No {
                return "not transferable"
            }

            return "not copyable"
        }

        if c->movable != LifecycleTri::No {
            return ""
        }

        // An imported type can delete its move and keep its copy; a defaulted
        // move then picks the deleted move all the same.
        if c->copyable == LifecycleTri::No {
            return "not transferable"
        }

        return "not movable"
    }

    priv fn _cat_word(self, c: LifecycleCategory) -> string {
        match c {
            case LifecycleCategory::Move {
                return "move-only (" + LangAttrs::at(LangAttrs::transfer_move()) + ")"
            } case LifecycleCategory::NonTransfer {
                return "non-transferable (deleted transfer)"
            } case LifecycleCategory::Unknown {
                return "undecided until instantiation"
            } default {
                return "copyable (" + LangAttrs::at(LangAttrs::transfer_copy()) + ")"
            }
        }
    }

    /// # per instance

    /// The rules a generic class's declaration could not decide -- an
    /// Unknown fact skips them (file header, Unknown) -- asked again of
    /// instance `e` with its own facts (file header, Instances), appended
    /// to `out`: rule 6 (a defaulted transfer over a component the
    /// instance cannot transfer that way), rule 5 (its category against
    /// each base's), the virtual-destructor rule. Only what the pattern did
    /// NOT already report, so a failure the declaration shows is never
    /// reported again per instance. Nothing for an explicit specialization
    /// (it is a declaration of its own, checked as one) or a non-class.
    fn instance_failures(self, e: unsafe *InstanceEntry, out: unsafe *[LifecycleFailure]) {
        if e == &null || out == &null || e->is_explicit || e->decl == &null {
            return
        }

        if self._concrete_instance(e->decl) != e {
            return
        }

        var unsafe *body = self.sc->body_of(e->decl)
        if body == &null {
            return
        }

        body = NameLookup::representative(body)
        if AttrFacts::is_relocatable(body) && !body->is_poisoned() {
            var rsub = Substitution(self.sc)
            rsub.bind_from_record(
                self.sc->types->record(e->decl, unsafe &e->args),
            )

            self._relocatable_failures(
                body,
                unsafe &rsub,
                self._tu.str(self.sc->types->record(e->decl, unsafe &e->args)),
                &*out,
            )
        }

        if !isa<ClassDecl>(body) {
            return
        }

        var unsafe *n = cast<ClassDecl>(body)
        if n->is_poisoned() {
            return
        }

        var unsafe *pf = self.facts_of(body) // the pattern's: what its declaration already decided.
        var unsafe *f  = self.facts_of(e->decl) // the instance's own.
        // The category the pattern left open, as the instance decides it.
        e->copy_denied = pf->category == LifecycleCategory::Unknown
            && (f->category == LifecycleCategory::Move
                || f->category == LifecycleCategory::NonTransfer)
        var sub = Substitution(self.sc)
        sub.bind_from_record(self.sc->types->record(e->decl, unsafe &e->args))
        var iname = self._tu.str(
            self.sc->types->record(e->decl, unsafe &e->args),
        )

        // Rule 6, per defaulted transfer constructor; rule 4b for an
        // instance whose pattern left the category open.
        var copy_ctor: unsafe *FunctionDecl = &null
        var move_ctor: unsafe *FunctionDecl = &null
        var dtor:      unsafe *FunctionDecl = &null
        for var i: usize = 0; i < n->methods.size(); ++i {
            var unsafe *m = n->methods[i]
            if m == &null || m->is_poisoned() || m->adt_role != AdtRole::None {
                continue
            }

            if self._is_dtor(m) {
                dtor = m
            }

            if m->transfer == TransferKind::Copy && copy_ctor == &null {
                copy_ctor = m
            }

            if m->transfer == TransferKind::Move && move_ctor == &null {
                move_ctor = m
            }
        }

        if copy_ctor != &null && copy_ctor->body_kind == FnBodyKind::Default {
            self._instance_defaulted(n, &sub, iname, copy_ctor, &*out)
        }

        if move_ctor != &null && move_ctor->body_kind == FnBodyKind::Default {
            self._instance_defaulted(n, &sub, iname, move_ctor, &*out)
        }

        if dtor != &null
            && copy_ctor == &null
            && move_ctor == &null
            && pf->category == LifecycleCategory::Unknown
            && f->category == LifecycleCategory::Move
            && !self._declares_ctor(n) {
            var x = LifecycleFailure()
            x.id = DiagID::SC358E
            x.msg = f"'{iname}' is move-only and has a destructor but no constructor, so it cannot be moved: write a constructor or a {LangAttrs::quoted(LangAttrs::transfer_move())} constructor in '{self.sc->ctx->get_spelling(n->name)}'"
            x.add_note(
                DiagID::I900N,
                dtor->range,
                "the destructor is declared here",
            )

            out->push(x)
        }

        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var unsafe *edge = n->derives_list.get(i)
            var unsafe *pb   = self._base_decl(edge->base)
            var unsafe *ib   = self._inst_base(&sub, edge->base)
            if ib == &null || isa<InterfaceDecl>(ib) {
                continue
            }

            var unsafe *bf = self.facts_of(ib)
            if bf->in_progress {
                continue
            }

            var pbf: unsafe *LifecycleFacts = &null
            if pb != &null && !isa<InterfaceDecl>(pb) {
                pbf = self.facts_of(pb)
            }

            var bn = self._tu.str(self._inst_type(&sub, edge->base->canonical))

            // Rule 5.
            var p_open = pbf == &null
                || pf->category == LifecycleCategory::Unknown
                || pbf->category == LifecycleCategory::Unknown
            if p_open
                && f->category != LifecycleCategory::Unknown
                && bf->category != LifecycleCategory::Unknown
                && f->category != LifecycleCategory::NonTransfer
                && f->category != bf->category {
                var x = LifecycleFailure()
                x.id = DiagID::SC061E
                x.msg = f"'{iname}' is {self._cat_word(f->category)}, but its base '{bn}' is {self._cat_word(bf->category)}; a derived class's lifecycle category must match its base's, or be non-transferable"
                x.add_note(
                    DiagID::I900N,
                    edge->range,
                    f"'{bn}' is a base of '{iname}' here",
                )

                if ib->range.is_valid() {
                    x.add_note(DiagID::I900N, ib->range, "base declared here")
                }

                out->push(x)
            }

            // The virtual-destructor rule.
            var p_said = pf->own_dtor_work == LifecycleTri::Yes
                && pbf != &null
                && pbf->virtual_dtor == LifecycleTri::No
            // A polymorphic base only, as at the pattern (visit_class_decl).
            if !p_said
                && f->own_dtor_work == LifecycleTri::Yes
                && bf->virtual_dtor == LifecycleTri::No
                && bf->polymorphic == LifecycleTri::Yes {
                var x = LifecycleFailure()
                x.id = DiagID::SC056E
                x.msg = f"class '{iname}' has a non-trivial destructor, but its base '{bn}' does not have a virtual destructor; deleting a '{iname}' through a '*{bn}' would run only '{bn}''s destructor and leak the rest"
                x.add_note(
                    DiagID::I900N,
                    edge->range,
                    f"'{bn}' is a base of '{iname}' here",
                )

                if ib->range.is_valid() {
                    x.add_note(
                        DiagID::I900N,
                        ib->range,
                        f"declare 'virtual fn op finally(self)' in '{bn}'",
                    )
                }

                out->push(x)
            }
        }
    }

    /// Rule 6 for defaulted transfer `x` of `n`'s instance `iname` (its
    /// arguments in `sub`): the first base, then the first field, that the
    /// instance cannot transfer the way `x` does and the pattern did not
    /// already report. One failure per constructor, as the rule has.
    priv fn _instance_defaulted(self,
                                n:           unsafe *ClassDecl,
                                sub:         *Substitution,
                                const iname: string,
                                x:           unsafe *FunctionDecl,
                                @inout out:  [LifecycleFailure]) {
        var is_copy = x->transfer == TransferKind::Copy
        var kind    = if (is_copy) => ("copy") else => "move"
        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var unsafe *edge = n->derives_list.get(i)
            var unsafe *pb   = self._base_decl(edge->base)
            if pb != &null
                && (!isa<InterfaceDecl>(pb))
                && self._untransferable(self.facts_of(pb), is_copy).size() > 0 {
                return
            }

            var unsafe *ib = self._inst_base(sub, edge->base)
            if ib == &null || isa<InterfaceDecl>(ib) {
                continue
            }

            var unsafe *bf = self.facts_of(ib)
            if bf->in_progress {
                continue
            }

            var why = self._untransferable(bf, is_copy)
            if why.size() == 0 {
                continue
            }

            var bn = self._tu.str(self._inst_type(sub, edge->base->canonical))
            var f  = LifecycleFailure()
            f.id  = DiagID::SC129E
            f.msg = f"'{iname}' cannot have a defaulted {kind} constructor: base '{bn}' is {why}"
            f.add_note(
                DiagID::SC129N,
                edge->range,
                f"'{bn}' is a base of '{iname}' here",
            )

            f.add_note(
                DiagID::I900N,
                x->range,
                f"the defaulted {kind} constructor is declared here",
            )

            out.push(f)
            return
        }

        var fields = self._fields(unsafe (n as unsafe *Decl))
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *fd = fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            if fd->type_ == &null || fd->type_->canonical == &null {
                continue
            }

            var pff = self.facts_of_type(fd->type_->canonical)
            if self._untransferable(unsafe &pff, is_copy).size() > 0 { // the declaration's own SC129E.
                return
            }

            var unsafe *it = self._inst_type(sub, fd->type_->canonical)
            var        ff  = self.facts_of_type(it)
            if ff.in_progress {
                continue
            }

            var why = self._untransferable(unsafe &ff, is_copy)
            if why.size() == 0 {
                continue
            }

            var fname = self.sc->ctx->get_spelling(fd->name)
            var f     = LifecycleFailure()
            f.id = DiagID::SC129E
            f.msg = f"'{iname}' cannot have a defaulted {kind} constructor: field '{fname}' of type '{self._tu.str(it)}' is {why}"
            f.add_note(DiagID::SC129N, fd->range, f"'{fname}' declared here")
            f.add_note(
                DiagID::I900N,
                x->range,
                f"the defaulted {kind} constructor is declared here",
            )

            out.push(f)
            return
        }
    }

    /// `t` (a canonical) under `sub`, or `t` where it does not go through.
    priv fn _inst_type(self, sub: *Substitution, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return t
        }

        var unsafe *c = canon_unqual(t)
        if !c->is_dependent() && !c->is_instantiation_dependent() {
            return c
        }

        var unsafe *s = sub->substitute(c)
        return if (s != &null) => (canon_unqual(s)) else => c
    }

    /// The record a base edge names under `sub`: an instance's own base.
    priv fn _inst_base(self, sub: *Substitution, t: unsafe *Type) -> unsafe *Decl {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *c = self._inst_type(sub, t->canonical)
        if !isa<RecordType>(c) {
            return &null
        }

        return cast<RecordType>(c)->decl
    }

    /// # the derived `op =`

    /// Fold a part's assignability into its owner's, for an `op =` that
    /// assigns member by member (file header, Assignment). A reason is kept
    /// for a definite No only, the first, as _absorb keeps its own.
    priv fn _absorb_assign(self,
                           f:          unsafe *LifecycleFacts,
                           c:          unsafe *LifecycleFacts,
                           const what: string) {
        var a = lifecycle_and(f->assignable, c->assignable)
        if a == LifecycleTri::No && f->assignable != LifecycleTri::No {
            f->why_not_assignable = f"{what} cannot be assigned"
        }

        f->assignable = a
    }

    /// The transfer constructor `d`'s `op =` is derived from: the first
    /// `@copy` / `@move` constructor that takes `Self` (the shape
    /// _check_transfer_shapes accepts and stamps). Null when none is
    /// written: C++'s implicit assignment is then the derived one. A marker
    /// on a constructor that does not take `Self` makes no transfer
    /// constructor to C++, so nothing derives from it. Rules 1 and 3 poison
    /// the ones they reject.
    priv fn _assign_source(self, d: unsafe *Decl) -> unsafe *FunctionDecl {
        var methods = self._methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || m->is_poisoned() || m->transfer == TransferKind::NotTransfer {
                continue
            }

            var selfp: unsafe *ParamDecl = &null
            var other: unsafe *ParamDecl = &null
            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *q = m->params[j]
                if q == &null {
                    continue
                }

                if q->is_self {
                    selfp = q
                    continue
                }

                if other == &null {
                    other = q
                }
            }

            if selfp == &null || other == &null {
                continue
            }

            if selfp->type_ == &null || selfp->type_->canonical == &null {
                continue
            }

            if other->type_ == &null || other->type_->canonical == &null {
                continue
            }

            if canon_unqual(other->type_->canonical) != canon_unqual(
                selfp->type_->canonical,
            ) {
                continue
            }

            return m
        }

        return &null
    }

    /// Whether a value of `d` holds an address its destructor could
    /// release: a pointer field, directly or inside a by-value part whose
    /// type has no destructor of its own (a fixed array, a nullable, a
    /// tuple, a trivially destroyed record), or a base that holds one. A
    /// part whose type has a destructor releases what it holds itself, and
    /// a part whose type depends on a generic parameter is not counted.
    /// `depth` bounds the walk on an ill-formed by-value cycle.
    priv fn _holds_address(self, d: unsafe *Decl, depth: u32) -> bool {
        if d == &null || depth > 16 {
            return false
        }

        var fields = self._fields(d)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *fd = fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            if fd->type_ != &null && self._type_holds_address(fd->type_->canonical, depth) {
                return true
            }
        }

        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *bd = self._base_decl(c->derives_list.get(i)->base)
                if bd != &null && self._holds_address(bd, depth + 1) {
                    return true
                }
            }
        }

        return false
    }

    /// _holds_address for one by-value part of type `t_in`.
    priv fn _type_holds_address(self, t_in: unsafe *Type, depth: u32) -> bool {
        if t_in == &null || depth > 16 {
            return false
        }

        var unsafe *t = canon_unqual(self._through(t_in))
        if t == &null || t->is_dependent() || t->is_instantiation_dependent() {
            return false
        }

        if isa<PointerType>(t) {
            return true
        }

        if isa<FixedArrayType>(t) {
            return self._type_holds_address(
                cast<FixedArrayType>(t)->element,
                depth + 1,
            )
        }

        if isa<NullableType>(t) {
            return self._type_holds_address(
                cast<NullableType>(t)->inner,
                depth + 1,
            )
        }

        if self._tu.is_tuple(t) {
            var elems = self._tu.tuple_elems(t)
            for var i: usize = 0; i < elems.size(); ++i {
                if self._type_holds_address(elems[i], depth + 1) {
                    return true
                }
            }

            return false
        }

        if isa<RecordType>(t) {
            var unsafe *rd = cast<RecordType>(t)->decl
            if rd == &null || self.facts_of(rd)->trivial_dtor != LifecycleTri::Yes {
                return false
            }

            return self._holds_address(rd, depth + 1)
        }

        return false
    }

    /// A by-value field or a base whose type depends on a generic
    /// parameter (_dependent_base asks any type): what leaves a body's
    /// verdict open in the pattern, and what InterfaceEmitter constrains a
    /// Constrained `op =` on -- the same test over the same lists.
    priv fn _has_dependent_part(self, d: unsafe *Decl) -> bool {
        var fields = self._fields(d)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *fd = fields[i]
            if fd == &null || fd->is_static() {
                continue
            }

            if self._dependent_base(fd->type_) {
                return true
            }
        }

        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                if self._dependent_base(c->derives_list.get(i)->base) {
                    return true
                }
            }
        }

        return false
    }

    /// How `d`'s `op =`, derived from `x`, is given to C++.
    priv fn _assign_form(self, d: unsafe *Decl, x: unsafe *FunctionDecl) -> AssignForm {
        if x == &null {
            return AssignForm::Implicit
        }

        if x->body_kind == FnBodyKind::Delete {
            return AssignForm::Deleted
        }

        var unsafe *f = self.facts_of(d)
        if f->assignable == LifecycleTri::No {
            return AssignForm::Deleted
        }

        // Member by member: C++'s `= default` is the derived one, and an
        // instance whose part cannot be assigned has it deleted by C++.
        if x->body_kind == FnBodyKind::Default {
            return AssignForm::Default
        }

        // Open only where a dependent part leaves destruction or a vptr to
        // the instance. A record open only because an instance it holds
        // reads its pattern's facts depends on nothing, so it has nothing to
        // constrain on; it is rebuilt, as its destructor already assumes.
        if f->assignable == LifecycleTri::Unknown && self._has_dependent_part(d) {
            return AssignForm::Constrained
        }

        return AssignForm::Body
    }

    /// The transfers `d` declares beside its destructor when it writes no
    /// transfer constructor (Declarations.k ImplicitTransfer). C++ declares
    /// no implicit move beside a user-declared destructor, so a MOVE record
    /// left to C++ falls back to its copy, which a move-only part deletes.
    /// A COPY record keeps C++'s implicit copy and gets no move: a record
    /// has one transfer, its category's. A record with no constructor is an
    /// aggregate to C++ and is built as one; declaring a constructor of any
    /// kind would end that, so it declares nothing.
    priv fn _implicit_transfer(self, d: unsafe *Decl) -> ImplicitTransfer {
        if decl_is_imported(d) {
            return ImplicitTransfer::None
        }

        var dtor    = false
        var ctor    = false
        var methods = self._methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null {
                continue
            }

            if m->transfer != TransferKind::NotTransfer {
                return ImplicitTransfer::None
            }

            if self._is_dtor(m) {
                dtor = true
            } else if decl_is_ctor(m, self.sc->ctx) {
                ctor = true
            }
        }

        if !dtor || !ctor {
            return ImplicitTransfer::None
        }

        var unsafe *f = self.facts_of(d)
        if f->category == LifecycleCategory::Move {
            return ImplicitTransfer::Move
        }

        if f->category != LifecycleCategory::Unknown {
            return ImplicitTransfer::None
        }

        // A part that is known not to copy decides against the copy for
        // every instance; C++ defines the defaulted move as deleted for an
        // instance whose parts cannot move either.
        if f->copyable == LifecycleTri::No {
            return ImplicitTransfer::Move
        }

        return ImplicitTransfer::Open
    }

    /// `n` declares a constructor of its own (a transfer one included).
    priv fn _declares_ctor(self, n: unsafe *ClassDecl) -> bool {
        for var i: usize = 0; i < n->methods.size(); ++i {
            var unsafe *m = n->methods[i]
            if m != &null && m->adt_role == AdtRole::None && decl_is_ctor(m, self.sc->ctx) {
                return true
            }
        }

        return false
    }

    /// The one writer of ClassDecl / StructDecl::assign_from, assign_form
    /// (file header, Assignment) and implicit_transfer.
    priv fn _derive_assign(self, d: unsafe *Decl) {
        var unsafe *x   = self._assign_source(d)
        var        form = self._assign_form(d, x)
        var        it   = self._implicit_transfer(d)
        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            c->assign_from       = x
            c->assign_form       = form
            c->implicit_transfer = it
        } else if isa<StructDecl>(d) {
            var unsafe *s = cast<StructDecl>(d)
            s->assign_from       = x
            s->assign_form       = form
            s->implicit_transfer = it
        }
    }

    /// # assignment

    /// `self.k` naming a const field of the record (CtorInitCheck's
    /// ctor_init_self_field, restated: this pass does not import it).
    priv fn _is_self_const_field(self, e: unsafe *Expr) -> bool {
        var unsafe *c = dyn_cast<ChainExpr>(e)
        if c == &null || c->steps.size() != 1 {
            return false
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(c->base)
        if ni == &null || ni->resolved_decl == &null {
            return false
        }

        var unsafe *p = dyn_cast<ParamDecl>(ni->resolved_decl)
        if p == &null || !p->is_self {
            return false
        }

        var unsafe *fd = dyn_cast<FieldDecl>(c->steps.get(0)->resolved_decl)
        return fd != &null && !fd->is_static() && fd->is_const()
    }

    /// `a = b` where the derived `op =` of a's record does not exist (file
    /// header, Assignment): an error here, in Kairo's terms, rather than
    /// clang's about a deleted operator. A definite No only. A compound
    /// operator is a user or a builtin one, never this.
    fn visit_assign_operator_expr(self, n: unsafe *AssignOperatorExpr) -> bool {
        if n == &null || n->is_poisoned() {
            return true
        }

        if n->op_token.kind != TokenKind::OpEqual {
            return true
        }

        if n->lhs == &null || n->lhs->type_ == &null {
            return true
        }

        var unsafe *c  = canon_unqual(n->lhs->type_)
        var unsafe *rd = self._tu.record_decl(c)
        if rd == &null {
            return true
        }

        var unsafe *f = self.facts_of(rd)
        if f->assignable != LifecycleTri::No {
            return true
        }

        // `self.k = v` on a const field is its one initialization, a
        // mem-initializer (Compiler/Spec/Codegen.md#emitir split) that constructs rather than
        // assigns; CtorInitCheck reports any other write to it.
        if self._is_self_const_field(n->lhs) {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC071E,
            n->range.start,
            f"cannot assign a '{self._tu.str(c)}': {f->why_not_assignable}",
        )

        b.first(n->range)
        b.note(rd->range.start, type_declared_here())->child_first(rd->range)
        // `op =` cannot be written (rule 2), so there is no assignment to
        // suggest: the value has to be built anew.
        if f->poly_rebuild {
            b.note(
                rd->range.start,
                "a polymorphic class whose transfer constructor has a body cannot be assigned; construct a new value",
            )
        }

        b.emit()
        self.n_errored += 1
        return true
    }

    /// # helpers

    /// `fn op finally(self)`: the destructor. DeclImport keys an imported one
    /// the same way (KwFinally).
    priv fn _is_dtor(self, m: unsafe *FunctionDecl) -> bool {
        if !m->is_operator {
            return false
        }

        if m->op_token.size() == 0 {
            return false
        }

        return m->op_token[0].kind == TokenKind::KwFinally
    }

    /// The `@copy` constructor that makes a copy of Kairo record `d_in`
    /// need a non-const source that is not a temporary, or null: the
    /// record's own `@copy fn X(self, other: Self)` (C++ `X(X&)`; a class
    /// declares one transfer constructor, so it then has no move either),
    /// or, for a record that declares no transfer constructor, that of a
    /// base or a by-value field: C++ then gives it `X(X&)` and defines its
    /// move as deleted. `via` is set to the first field on that path, and
    /// left null for the record's own constructor or a base's; `owner` to
    /// the record that declares the constructor. An imported record is
    /// clang's to diagnose; a dependent field decides nothing.
    pub fn mutable_source_copy(self,
                               d_in:  unsafe *Decl,
                               via:   unsafe *(unsafe *FieldDecl),
                               owner: unsafe *(unsafe *Decl)) -> unsafe *FunctionDecl {
        return self._mutable_source_copy(d_in, via, owner, 0)
    }

    priv fn _mutable_source_copy(self,
                                 d_in:  unsafe *Decl,
                                 via:   unsafe *(unsafe *FieldDecl),
                                 owner: unsafe *(unsafe *Decl),
                                 depth: u32) -> unsafe *FunctionDecl {
        if d_in == &null || depth > 8 {
            return &null
        }

        var unsafe *d = NameLookup::representative(d_in)
        if d == &null || decl_is_imported(d) {
            return &null
        }

        var unsafe *pat = self._tu.pattern_of(d)
        if pat == &null {
            pat = d
        }

        var ms                           = self._methods(pat)
        var written                      = false
        var nc:     unsafe *FunctionDecl = &null
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->transfer == TransferKind::NotTransfer {
                continue
            }

            written = true
            if m->transfer == TransferKind::Move || m->body_kind == FnBodyKind::Delete {
                return &null
            }

            if ClassLifecycle::copy_source_param(m) == &null
                || ClassLifecycle::copy_source_param(m)->is_const {
                return &null
            }

            nc = m
        }

        if written {
            if nc != &null && owner != &null {
                *owner = pat
            }

            return nc
        }

        if isa<ClassDecl>(pat) {
            var unsafe *c = cast<ClassDecl>(pat)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *be = c->derives_list.get(i)
                if be == &null || be->base == &null || be->base->canonical == &null {
                    continue
                }

                if be->base->canonical->is_dependent() {
                    continue
                }

                var none: unsafe *FieldDecl = &null
                var unsafe *r = self._mutable_source_copy(
                    self._tu.record_decl(canon_unqual(be->base->canonical)),
                    unsafe &none,
                    owner,
                    depth + 1,
                )

                if r != &null {
                    return r
                }
            }
        }

        var fs = self._fields(pat)
        for var i: usize = 0; i < fs.size(); ++i {
            var unsafe *fd = fs[i]
            if fd == &null
                || fd->is_static()
                || fd->type_ == &null
                || fd->type_->canonical == &null
                || fd->type_->canonical->is_dependent() {
                continue
            }

            var none: unsafe *FieldDecl = &null
            var unsafe *r = self._mutable_source_copy(
                self._tu.record_decl(canon_unqual(fd->type_->canonical)),
                unsafe &none,
                owner,
                depth + 1,
            )

            if r != &null {
                if via != &null && *via == &null {
                    *via = fd
                }

                return r
            }
        }

        return &null
    }

    /// The source parameter of transfer constructor `m` (the first after
    /// `self`), or null.
    pub static fn copy_source_param(m: unsafe *FunctionDecl) -> unsafe *ParamDecl {
        if m == &null {
            return &null
        }

        for var j: usize = 0; j < m->params.size(); ++j {
            var unsafe *q = m->params[j]
            if q != &null && !q->is_self {
                return q
            }
        }

        return &null
    }

    priv fn _methods(self, d: unsafe *Decl) -> [unsafe *FunctionDecl] {
        var out: [unsafe *FunctionDecl]
        var lst: unsafe *FrozenList<unsafe *FunctionDecl> = &null
        if isa<ClassDecl>(d) {
            lst = unsafe &cast<ClassDecl>(d)->methods
        } else if isa<StructDecl>(d) {
            lst = unsafe &cast<StructDecl>(d)->methods
        } else if isa<UnionDecl>(d) {
            lst = unsafe &cast<UnionDecl>(d)->methods
        }

        if lst == &null {
            return out
        }

        for var i: usize = 0; i < lst->size(); ++i {
            var unsafe *m = (*lst)[i]
            // An ADT layout record's role functions are compiler-made C++
            // (EnumLayoutLowering): no rule about what a user may declare,
            // and no fact a user's declaration decides, is about them.
            if m != &null && m->adt_role != AdtRole::None {
                continue
            }

            out.push(m)
        }

        return out
    }

    priv fn _fields(self, d: unsafe *Decl) -> [unsafe *FieldDecl] {
        var out: [unsafe *FieldDecl]
        var lst: unsafe *FrozenList<unsafe *FieldDecl> = &null
        if isa<ClassDecl>(d) {
            lst = unsafe &cast<ClassDecl>(d)->fields
        } else if isa<StructDecl>(d) {
            lst = unsafe &cast<StructDecl>(d)->fields
        } else if isa<UnionDecl>(d) {
            lst = unsafe &cast<UnionDecl>(d)->fields
        }

        if lst == &null {
            return out
        }

        for var i: usize = 0; i < lst->size(); ++i {
            out.push((*lst)[i])
        }

        return out
    }

    priv fn _layout(self, d: unsafe *Decl) -> unsafe *ForeignLayout {
        if isa<ClassDecl>(d) {
            return unsafe &cast<ClassDecl>(d)->layout
        }

        if isa<StructDecl>(d) {
            return unsafe &cast<StructDecl>(d)->layout
        }

        if isa<UnionDecl>(d) {
            return unsafe &cast<UnionDecl>(d)->layout
        }

        return &null
    }

    /// The record decl a base edge names, or null (unresolved, dependent).
    /// Read through the instance being computed, if any (_through): an
    /// instance's `derives Base<T>` is its own `Base<i32>`.
    priv fn _base_decl(self, t: unsafe *Type) -> unsafe *Decl {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(self._through(canon_unqual(t->canonical)))
        if !isa<RecordType>(c) {
            return &null
        }

        return cast<RecordType>(c)->decl
    }

    /// A base edge _base_decl has no decl for because it names a generic
    /// parameter (`derives T`), as opposed to one T could not resolve.
    priv fn _dependent_base(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(self._through(canon_unqual(t->canonical)))
        return c->is_dependent() || c->is_instantiation_dependent()
    }
}

/// THE ClassLifecycle of `sc`'s run: Sema owns it and publishes it on
/// SemaContext::lifecycle, untyped there because this file imports that one.
/// Every reader comes through here, so the facts are one memo per TU.
pub fn lifecycle_of(sc: unsafe *SemaContext) -> unsafe *ClassLifecycle {
    if sc == &null || sc->lifecycle == &null {
        kairo::std::ice_fail("lifecycle facts read before Sema created them")
    }

    return unsafe (sc->lifecycle as unsafe *ClassLifecycle)
}

/// `t` is a record whose category is MOVE, so passing a value of it moves
/// the value (Doc: Ownership, Function Parameters). Overload resolution
/// binds such an lvalue as an xvalue and MoveCheck counts the move, both
/// from this one answer. A category that hangs on a generic parameter is
/// not MOVE here; the instance decides.
pub fn moves_on_pass(sc: unsafe *SemaContext, t: unsafe *Type) -> bool {
    if t == &null {
        return false
    }

    var        tu = TypeUtil(sc)
    var unsafe *d = tu.record_decl(t)
    if d == &null || isa<InterfaceDecl>(d) {
        return false
    }

    // A tuple's facts are its elements' (facts_of_type), not its pattern's,
    // which hang on the parameters and would read Unknown.
    if tu.is_tuple(t) {
        return lifecycle_of(sc)->facts_of_type_concrete(
            t,
            "moves_on_pass",
        ).category == LifecycleCategory::Move
    }

    return lifecycle_of(sc)->facts_of(d)->category == LifecycleCategory::Move
}

/// `t` (through a C++ reference) definitely cannot be copied: a record or a
/// tuple whose facts say so. A type that hangs on a generic parameter is
/// not one here; its instance decides (binder_mode_by_instance).
///
/// A plain `for` or `case` binder of such a type borrows its element
/// read-only rather than copying it (control-flow.mdx, Loop binders).
pub fn cannot_copy(sc: unsafe *SemaContext, t: unsafe *Type) -> bool {
    if t == &null {
        return false
    }

    var        tu = TypeUtil(sc)
    var unsafe *c = tu.as_value(t)
    if c == &null || c->is_dependent() || c->is_instantiation_dependent() {
        return false
    }

    var unsafe *r = tu.record_decl(c)
    if r == &null || isa<InterfaceDecl>(r) {
        return false
    }

    if tu.is_tuple(c) {
        return lifecycle_of(sc)->facts_of_type(c).copyable == LifecycleTri::No
    }

    return lifecycle_of(sc)->facts_of(r)->copyable == LifecycleTri::No
}

/// `t` hangs on a generic parameter, so whether a plain binder of it copies
/// or borrows is each instance's: it borrows where the instance cannot copy
/// the value.
pub fn binder_mode_by_instance(t: unsafe *Type) -> bool {
    return t != &null && (t->is_dependent() || t->is_instantiation_dependent())
}
