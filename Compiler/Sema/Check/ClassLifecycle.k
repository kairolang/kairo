/// --- The Kairo Project ------------------- Sema/Check/ClassLifecycle.k --- ///
///
///   \brief Per record: copyable, movable, trivially so, destructible -- and
///          the one OOP rule those facts decide, the virtual-destructor rule.
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
///                  copy); every base and by-value field copyable.
///       movable    no deleted move ctor, and (a user move ctor, or
///                  copyable -- an rvalue falls back to the copy); every
///                  base and by-value field movable.
///       trivial    nothing user-provided on this type, its bases, or its
///                  by-value fields.
///       destructible  no `op delete = delete` on this type, its bases, or
///                  its by-value fields.
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
///     so `*T` stays trivial. An instance reads its pattern (nothing computes
///     facts per instance yet; that is M2's), so `Opt<i32>` reads exactly as
///     unknown as `Opt<T>`. Every rule that diagnoses from a fact, here and
///     in MoveCheck, skips an Unknown one rather than guessing either way.
///
///     A record that writes a @copy or @move constructor has the category it
///     DECLARED (@copy, @move, both deleted). It reads Unknown only when a
///     dependent component leaves copyable or movable open, and never when it
///     declared NON_TRANSFER: nothing a field holds brings a deleted transfer
///     back. A record that writes neither has no category of its own to
///     declare: C++ generates its transfers from its bases and fields, so its
///     category is the weakest they allow, read off the folded facts exactly
///     as an ADT's is (_folded_category). A class holding a move-only field is
///     MOVE, and one holding a std::mutex is NON_TRANSFER.
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
///     mode the marker means (`@copy` -> Inout, `@move` -> Move), so CXXSpell
///     and MoveCheck read an ordinary parameter mode and never the marker.
///     The stamp lands after ExprTyper on purpose: X ranks a copy's argument
///     against the by-value view, which is what C++ overload resolution does
///     for `const X&` too, whereas an Inout parameter in X is a `T&` that
///     wants the call-site `&` and refuses a temporary.
///
///   \par Ownership
///     One instance per TU run, owned by Sema and published on
///     SemaContext::lifecycle. Readers reach it through lifecycle_of(sc), so
///     the memo is one table: a second instance would compute every fact
///     twice and could answer differently mid-run.
///
///   Phase: CHECK, after ExprTyper. MoveCheck and SemaDump read facts_of().
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::MemberLookup::*;
import Sema::Type::TypeUtil::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::ParamMode::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Mixin::FFILinkage::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

__inline_cpp("
#define RecursiveASTVisitor_ClassLifecycle RecursiveASTVisitor<ClassLifecycle>
");

enum LifecycleCategory derives u8 {
    Copy = 0,      ///< @copy, explicit or implicit; DEFAULT reads as this.
    Move,          ///< @move.
    NonTransfer,   ///< both deleted: stack-only.
    Unknown,       ///< hangs on a generic parameter (see LifecycleTri).
}

/// One lifecycle fact. Unknown is not a third answer but the absence of one:
/// the pattern cannot say, an instance can (file header).
enum LifecycleTri derives u8 {
    No = 0,
    Yes,
    Unknown,       ///< a dependent field, payload or base decides it.
}

fn lifecycle_tri(b: bool) -> LifecycleTri {
    return (LifecycleTri::Yes) if (b) else (LifecycleTri::No);
}

/// Every part has it. A definite No wins over an Unknown: `{ s: string,
/// v: T }` is not trivially copyable whatever T turns out to be.
fn lifecycle_and(a: LifecycleTri, b: LifecycleTri) -> LifecycleTri {
    if (a == LifecycleTri::No) || (b == LifecycleTri::No) { return LifecycleTri::No; }
    if (a == LifecycleTri::Unknown) || (b == LifecycleTri::Unknown) { return LifecycleTri::Unknown; }
    return LifecycleTri::Yes;
}

/// Some part has it. A definite Yes wins over an Unknown.
fn lifecycle_or(a: LifecycleTri, b: LifecycleTri) -> LifecycleTri {
    if (a == LifecycleTri::Yes) || (b == LifecycleTri::Yes) { return LifecycleTri::Yes; }
    if (a == LifecycleTri::Unknown) || (b == LifecycleTri::Unknown) { return LifecycleTri::Unknown; }
    return LifecycleTri::No;
}

fn lifecycle_not(a: LifecycleTri) -> LifecycleTri {
    if a == LifecycleTri::Yes { return LifecycleTri::No; }
    if a == LifecycleTri::No  { return LifecycleTri::Yes; }
    return LifecycleTri::Unknown;
}

/// Every fact below that a field, payload or base can decide is a
/// LifecycleTri. The bools are the record's own declarations, never unknown.
/// One writer for all of it: the fact computation in ClassLifecycle
/// (_compute, _compute_enum, facts_of_type, folded through _absorb).
class LifecycleFacts {
    pub var computed:           bool = false;
    pub var in_progress:        bool = false;
    pub var copyable:           LifecycleTri = LifecycleTri::Yes;
    pub var movable:            LifecycleTri = LifecycleTri::Yes;
    pub var trivially_copyable: LifecycleTri = LifecycleTri::Yes;
    pub var trivial_dtor:       LifecycleTri = LifecycleTri::Yes;
    pub var has_user_dtor:      bool = false;
    pub var virtual_dtor:       LifecycleTri = LifecycleTri::No;
    pub var why_not_movable:    string = "";
    pub var why_not_copyable:   string = "";
    /// Doc: Lifecycle Categories. DEFAULT (no transfer ctor written) is
    /// reported as the weakest its bases and fields allow, which is Copy
    /// whenever they all copy; the implicit-copy warning tells DEFAULT
    /// apart by reading `user_transfer` instead.
    pub var category:      LifecycleCategory = LifecycleCategory::Copy;
    pub var user_transfer: bool = false;   ///< wrote a @copy or @move ctor at all.
    /// Destruction work of this record's OWN: a user destructor, or a
    /// by-value field whose destructor is non-trivial. Bases deliberately do
    /// not contribute -- a `delete` through a base pointer still runs the
    /// base's destructor, so the base's work is never the part that leaks.
    /// The virtual-destructor rule reads this, not `trivial_dtor`.
    pub var own_dtor_work: LifecycleTri = LifecycleTri::No;
    /// No when the destructor is `= delete` here, on a base, or on a
    /// by-value field (an ADT: on any payload field).
    pub var destructible: LifecycleTri = LifecycleTri::Yes;
    fn LifecycleFacts(self) { }
}

class ClassLifecycle derives RecursiveASTVisitor::<ClassLifecycle> {
    pub var sc: *SemaContext;
    priv var _tu:    TypeUtil;
    priv var _facts: libcxx::unordered_map::<u64, LifecycleFacts>;
    pub var n_checked: usize = 0;
    pub var n_errored: usize = 0;

    /// Unwired. Exists for the by-value member Sema::lifecycle, which is
    /// assigned the wired form once the SemaContext it borrows sits at its
    /// final address.
    fn ClassLifecycle(self) {
        self.sc = &null;
    }

    fn ClassLifecycle(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    /// PRE: TypesResolved (canonicals exist; base types resolved).
    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === facts ==============================================================

    /// The facts for the entity \p d belongs to. Any record kind, any TU. An
    /// unfilled instance of an imported template is filled first (clang's
    /// facts); a Kairo instance M2 has not filled reads its pattern.
    fn facts_of(self, d_in: *Decl) -> *LifecycleFacts {
        var d = NameLookup::representative(d_in);
        MemberLookup::ensure_filled(self.sc, d);
        if MemberLookup::unfilled(d) {
            var pat = decl_instantiated_from(d);
            if pat != &null { d = NameLookup::representative(pat); }
        }
        var key = reinterpret_cast::<u64>(d);
        var it  = self._facts.find(key);
        if it != self._facts.end() { return &(it->second); }
        self._facts[key] = LifecycleFacts{};
        var f = &(self._facts[key]);
        self._compute(d, f);
        return f;
    }

    /// Facts for a canonical TYPE: a record's are its decl's; everything
    /// else is trivially everything, except the library containers, which
    /// are movable, copyable and non-trivially destroyed, and a by-value
    /// type that depends on a generic parameter, which is Unknown throughout.
    fn facts_of_type(self, t_in: *Type) -> LifecycleFacts {
        var out = LifecycleFacts{};
        out.computed = true;
        if t_in == &null { return out; }
        var t = canon_unqual(t_in);

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
        if self._tu.is_vector_like(t) || self._tu.is_map_like(t)
        || self._tu.is_set_like(t)    || self._tu.is_string(t) {
            out.trivially_copyable = LifecycleTri::No;
            out.trivial_dtor       = LifecycleTri::No;
            return out;
        }

        switch t->kind {
            case TypeKind::RecordType {
                var d = cast::<RecordType>(t)->decl;
                if d == &null { return out; }
                return *(self.facts_of(d));
            }
            case TypeKind::TupleType {
                var tt = cast::<TupleType>(t);
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    var ef = self.facts_of_type(tt->elements[i]);
                    self._absorb(&out, &ef, f"element {i}");
                }
                return out;
            }
            case TypeKind::FixedArrayType { return self.facts_of_type(cast::<FixedArrayType>(t)->element); }
            case TypeKind::VectorType     { out.trivially_copyable = LifecycleTri::No; out.trivial_dtor = LifecycleTri::No; return out; }
            case TypeKind::MapType        { out.trivially_copyable = LifecycleTri::No; out.trivial_dtor = LifecycleTri::No; return out; }
            case TypeKind::SetType        { out.trivially_copyable = LifecycleTri::No; out.trivial_dtor = LifecycleTri::No; return out; }
            case TypeKind::OpaqueFFIType  { out.trivially_copyable = LifecycleTri::No; out.trivial_dtor = LifecycleTri::No; return out; }
            // An address, whatever it addresses: `*T` is as trivial as `*i32`,
            // and asking T would make every generic node type unknown.
            case TypeKind::PointerType         { return out; }
            case TypeKind::FunctionPointerType { return out; }
            case TypeKind::CXXLValueRefType    { return out; }
            case TypeKind::CXXRValueRefType    { return out; }
            case TypeKind::NullableType {
                var inner = cast::<NullableType>(t)->inner;
                if (inner != &null) && isa::<PointerType>(canon_unqual(inner)) { return out; }
                if t->is_dependent() || t->is_instantiation_dependent() { return self._unknown_facts(); }
                return out;
            }
            default {
                // A generic parameter, or a type built from one by value.
                if t->is_dependent() || t->is_instantiation_dependent() { return self._unknown_facts(); }
                return out;                                  // builtins.
            }
        }
    }

    /// The facts of a by-value type that depends on a generic parameter: all
    /// of them are the instance's to decide.
    priv fn _unknown_facts(self) -> LifecycleFacts {
        var out = LifecycleFacts{};
        out.computed           = true;
        out.copyable           = LifecycleTri::Unknown;
        out.movable            = LifecycleTri::Unknown;
        out.trivially_copyable = LifecycleTri::Unknown;
        out.trivial_dtor       = LifecycleTri::Unknown;
        out.destructible       = LifecycleTri::Unknown;
        out.own_dtor_work      = LifecycleTri::Unknown;
        out.virtual_dtor       = LifecycleTri::Unknown;
        out.category           = LifecycleCategory::Unknown;
        return out;
    }

    /// Fold a component's facts into its owner's. A reason is recorded only
    /// for a definite No, and only the first: an Unknown has no reason yet.
    priv fn _absorb(self, f: *LifecycleFacts, c: *LifecycleFacts, what: string) {
        f->trivially_copyable = lifecycle_and(f->trivially_copyable, c->trivially_copyable);
        f->trivial_dtor       = lifecycle_and(f->trivial_dtor,       c->trivial_dtor);
        f->destructible       = lifecycle_and(f->destructible,       c->destructible);
        var cp = lifecycle_and(f->copyable, c->copyable);
        if (cp == LifecycleTri::No) && (f->copyable != LifecycleTri::No) {
            f->why_not_copyable = f"{what} is not copyable";
        }
        f->copyable = cp;
        var mv = lifecycle_and(f->movable, c->movable);
        if (mv == LifecycleTri::No) && (f->movable != LifecycleTri::No) {
            f->why_not_movable = f"{what} is not movable";
        }
        f->movable = mv;
    }

    priv fn _compute(self, d: *Decl, f: *LifecycleFacts) {
        if isa::<EnumDecl>(d) {
            self._compute_enum(cast::<EnumDecl>(d), f);
            return;
        }
        f->in_progress = true;

        var user_copy    = false;
        var user_move    = false;
        var copy_deleted = false;
        var move_deleted = false;
        var user_dtor    = false;
        var dtor_deleted = false;
        var dtor_virtual = false;

        var methods = self._methods(d);
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if m == &null { continue; }
            if m->transfer == TransferKind::Copy {
                user_copy = true;
                if m->body_kind == FnBodyKind::Delete { copy_deleted = true; }
            }
            if m->transfer == TransferKind::Move {
                user_move = true;
                if m->body_kind == FnBodyKind::Delete { move_deleted = true; }
            }
            if self._is_dtor(m) {
                user_dtor = true;
                if m->body_kind == FnBodyKind::Delete { dtor_deleted = true; }
                if (m->abi == AbiKind::Virtual) || (m->abi == AbiKind::Override) || m->ffi_virtual {
                    dtor_virtual = true;
                }
            }
        }

        // C++ rules, since that is what the record lowers under.
        var copyable = (!copy_deleted) && (user_copy || (!user_move));
        var movable  = (!move_deleted) && (user_move || copyable);
        f->copyable      = lifecycle_tri(copyable);
        f->movable       = lifecycle_tri(movable);
        f->user_transfer = user_copy || user_move;
        if copy_deleted && move_deleted      { f->category = LifecycleCategory::NonTransfer; }
        else if user_move && (!user_copy)    { f->category = LifecycleCategory::Move; }
        else                                 { f->category = LifecycleCategory::Copy; }
        f->has_user_dtor = user_dtor;
        f->own_dtor_work = lifecycle_tri(user_dtor);
        f->destructible  = lifecycle_tri(!dtor_deleted);
        f->virtual_dtor  = lifecycle_tri(dtor_virtual);
        if !copyable {
            f->why_not_copyable = ("its copy constructor is deleted") if (copy_deleted)
                                  else ("it declares a move constructor and no copy constructor");
        }
        if !movable {
            f->why_not_movable = ("its move constructor is deleted") if (move_deleted)
                                 else (f"it declares no move constructor and {f->why_not_copyable}");
        }

        // clang's triviality bits for an imported record; ours otherwise.
        var lay = self._layout(d);
        if (lay != &null) && lay->known {
            f->trivially_copyable = lifecycle_tri(lay->trivially_copyable);
            f->trivial_dtor       = lifecycle_tri(lay->trivial_dtor);
        } else {
            f->trivially_copyable = lifecycle_tri((!user_copy) && (!user_move) && (!user_dtor));
            f->trivial_dtor       = lifecycle_tri(!user_dtor);
        }

        // Bases.
        if isa::<ClassDecl>(d) {
            var c = cast::<ClassDecl>(d);
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var e  = c->derives_list.get(i);
                var bd = self._base_decl(e->base);
                if bd == &null {
                    // `derives T`: no decl to ask, and everything the base
                    // would fold in is the instance's.
                    if self._dependent_base(e->base) {
                        var uf = self._unknown_facts();
                        f->virtual_dtor = lifecycle_or(f->virtual_dtor, uf.virtual_dtor);
                        self._absorb(f, &uf, "its base");
                    }
                    continue;
                }
                if isa::<InterfaceDecl>(bd) { continue; }
                var bf = self.facts_of(bd);
                if bf->in_progress { continue; }             // a cycle; TypeCycleCheck's.
                f->virtual_dtor = lifecycle_or(f->virtual_dtor, bf->virtual_dtor);
                self._absorb(f, bf, f"its base '{self._tu.decl_name(bd)}\x27");
            }
        }

        // By-value fields.
        var fields = self._fields(d);
        for var i: usize = 0; i < fields.size(); ++i {
            var fd = fields[i];
            if (fd == &null) || fd->is_static() { continue; }
            if (fd->type_ == &null) || (fd->type_->canonical == &null) { continue; }
            var ff = self.facts_of_type(fd->type_->canonical);
            if ff.in_progress { continue; }
            f->own_dtor_work = lifecycle_or(f->own_dtor_work, lifecycle_not(ff.trivial_dtor));
            self._absorb(f, &ff, f"its field '{self.sc->ctx->get_spelling(fd->name)}\x27");
        }

        // Nothing declared: the weakest category the bases and fields allow
        // (file header), so the ones C++ would generate are what it reports.
        // Declared: it stands unless a dependent component left the
        // transfers open. NON_TRANSFER stands regardless: no field brings a
        // deleted transfer back.
        if !f->user_transfer {
            f->category = self._folded_category(f);
        } else if (f->category != LifecycleCategory::NonTransfer)
        && ((f->copyable == LifecycleTri::Unknown) || (f->movable == LifecycleTri::Unknown)) {
            f->category = LifecycleCategory::Unknown;
        }

        f->computed    = true;
        f->in_progress = false;
    }

    /// An enum's facts (file header). A plain enum has no payload, so the
    /// LifecycleFacts defaults stand. An ADT declares no transfer ctor or
    /// destructor of its own, so everything it has comes from the payloads.
    priv fn _compute_enum(self, en: *EnumDecl, f: *LifecycleFacts) {
        f->in_progress = true;

        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v == &null { continue; }
            for var j: usize = 0; j < v->payload.size(); ++j {
                var fd = v->payload[j];
                if fd == &null { continue; }
                // Unresolved: T reported it, and guessing here would only add
                // a second error about a type nobody could name.
                if (fd->type_ == &null) || (fd->type_->canonical == &null) { continue; }
                var pf = self.facts_of_type(fd->type_->canonical);
                if pf.in_progress { continue; }                // a cycle; TypeCycleCheck's.
                f->own_dtor_work = lifecycle_or(f->own_dtor_work, lifecycle_not(pf.trivial_dtor));
                self._absorb(f, &pf,
                    f"the payload field '{self.sc->ctx->get_spelling(fd->name)}' of variant '{self.sc->ctx->get_spelling(v->name)}\x27");
            }
        }

        // The weakest category the payloads allow.
        f->category = self._folded_category(f);

        f->computed    = true;
        f->in_progress = false;
    }

    /// The weakest category folded facts allow (COPY > MOVE > NON_TRANSFER),
    /// for an ADT and for a record that declares no transfer constructor.
    /// Read off the copyable / movable bits rather than each component's own
    /// `category`: a declared one records what was WRITTEN, and an imported
    /// type's is clang's ctors read the same way -- std::mutex deletes its
    /// copy and declares no move, which reads as a declared COPY while it
    /// transfers neither way. A definite NON_TRANSFER is decided even beside
    /// an Unknown (the folding is Kleene AND); anything else open is Unknown.
    priv fn _folded_category(self, f: *LifecycleFacts) -> LifecycleCategory {
        if f->copyable == LifecycleTri::Yes                                            { return LifecycleCategory::Copy;        }
        if (f->copyable == LifecycleTri::No) && (f->movable == LifecycleTri::Yes)      { return LifecycleCategory::Move;        }
        if (f->copyable == LifecycleTri::No) && (f->movable == LifecycleTri::No)       { return LifecycleCategory::NonTransfer; }
        return LifecycleCategory::Unknown;
    }

    // === the virtual-destructor rule =========================================

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        if n == &null { return true; }
        if n->is_poisoned() { return true; }
        // Every class, not only derived ones: rules 1-4 are about the
        // class's own members, so this sits above the no-base early-out.
        self._check_transfer_shapes(static_cast::<*Decl>(n), self.sc->ctx->get_spelling(n->name));
        self._check_lifecycle_rules(n);
        if n->derives_list.size() == 0 { return true; }
        self.n_checked += 1;

        var df = self.facts_of(static_cast::<*Decl>(n));
        // Own work, not `trivial_dtor`: that absorbs the base's destructor,
        // which made every class deriving a non-trivial base an error -- even
        // one adding nothing a base-typed `delete` would skip.
        if df->own_dtor_work == LifecycleTri::No { return true; }
        // Unknown facts are resolved per instance at M2, which does not exist yet.
        if df->own_dtor_work == LifecycleTri::Unknown { return true; }
        var dn = self.sc->ctx->get_spelling(n->name);

        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var e  = n->derives_list.get(i);
            var bd = self._base_decl(e->base);
            if bd == &null { continue; }
            if isa::<InterfaceDecl>(bd) { continue; }
            var bf = self.facts_of(bd);
            if bf->virtual_dtor == LifecycleTri::Yes { continue; }
            // Unknown facts are resolved per instance at M2, which does not exist yet.
            if bf->virtual_dtor == LifecycleTri::Unknown { continue; }

            var bn = self._tu.decl_name(bd);
            var b = self.sc->diag->report(DiagID::SC056E, e->range.start,
                f"class '{dn}' has a non-trivial destructor, but its base '{bn}' does not have a virtual destructor; deleting a '{dn}' through a '*{bn}' would run only '{bn}''s destructor and leak the rest"
            );
            b.first(e->range);
            b.note(bd->range.start,
                f"declare 'virtual fn op delete(self)' in '{bn}' and 'override fn op delete(self)' in '{dn}\x27"
            ).first(bd->range);
            b.emit();
            self.n_errored += 1;
        }
        return true;
    }

    fn visit_struct_decl(self, n: *StructDecl) -> bool {
        if n == &null { return true; }
        if n->is_poisoned() { return true; }
        self._check_transfer_shapes(static_cast::<*Decl>(n), self.sc->ctx->get_spelling(n->name));
        return true;
    }

    // === transfer-constructor shapes =========================================

    /// Classify every constructor of \p d, reject the shapes C++ would read
    /// as a transfer constructor Kairo did not declare as one, and stamp the
    /// accepted ones (see the file header). The one writer of both: this is
    /// where the transfer constructor is found, so the rule and the stamp
    /// cannot disagree about which constructor it is.
    priv fn _check_transfer_shapes(self, d: *Decl, dn: string) {
        var methods = self._methods(d);
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if (m == &null) || m->is_operator || m->is_poisoned() { continue; }
            if self._tu.decl_name(static_cast::<*Decl>(m)) != dn { continue; }   // not a constructor.

            // `self`, then the first parameter after it.
            var selfp: *ParamDecl = &null;
            var at = usize(-1);
            for var j: usize = 0; j < m->params.size(); ++j {
                var q = m->params[j];
                if q == &null { continue; }
                if q->is_self { selfp = q; continue; }
                if at == usize(-1) { at = j; }
            }
            if (selfp == &null) || (at == usize(-1)) { continue; }
            var p = m->params[at];

            // `Self`, any cv, any mode. The receiver's own canonical IS Self
            // (TypeResolution synthesizes it), generic records included, and
            // canonicals are uniqued, so this is identity, not a structural
            // compare that `Box<i32>` inside `class <T> Box` could fool.
            if (p->type_ == &null) || (p->type_->canonical == &null) { continue; }
            if (selfp->type_ == &null) || (selfp->type_->canonical == &null) { continue; }
            if canon_unqual(p->type_->canonical) != canon_unqual(selfp->type_->canonical) { continue; }

            // Every later parameter defaulted, or C++ does not read it as a
            // transfer constructor: `X(self, other: Self, extra: i32)` is an
            // ordinary constructor that happens to take a Self first. A pack
            // has no default and makes it a template, never a copy ctor.
            var tail = false;
            var tail_defaulted = true;
            for var j: usize = at + 1; j < m->params.size(); ++j {
                var q = m->params[j];
                if q == &null { continue; }
                tail = true;
                if q->is_pack || ((q->default_val == &null) && (!q->has_default)) { tail_defaulted = false; }
            }
            if !tail_defaulted { continue; }

            if m->transfer == TransferKind::NotTransfer {
                self._report_unmarked_transfer(m, p, dn);
                continue;
            }

            // Marked: `other` is written bare, so the marker is the only
            // thing that decides the C++ shape.
            var marker = ("@copy") if (m->transfer == TransferKind::Copy) else ("@move");
            if (p->mode != ParamMode::Value) || (p->default_val != &null) || tail {
                var b = self.sc->diag->report(DiagID::SC110E, p->range.start,
                    f"the parameter of a '{marker}' constructor is written 'other: Self', with no mode, no default and nothing after it"
                );
                b.first(p->range);
                if p->mode != ParamMode::Value {
                    b.remove(p->mode_range, f"remove the parameter mode; '{marker}' on the constructor already decides how 'other' is passed");
                }
                b.emit();
                self.n_errored += 1;
                continue;
            }
            if (m->transfer == TransferKind::Move) && p->is_const {
                self.sc->diag->report(DiagID::SC110E, p->range.start,
                    "a move constructor cannot take a const source; it leaves the source empty"
                ).first(p->range).emit();
                self.n_errored += 1;
                continue;
            }

            // The stamp. `@copy` keeps `const` as written: `const X&` is the
            // usual copy, plain `X&` is legal C++ and X reports a const or
            // temporary source where the copy is made.
            if m->transfer == TransferKind::Copy { p->mode = ParamMode::Inout; }
            else                                 { p->mode = ParamMode::Move;  }
        }
    }

    /// A constructor of transfer shape with no `@copy` / `@move`. C++ would
    /// make it a copy or move constructor anyway (or reject it outright as a
    /// by-value one), so it is an error at the declaration, never a second
    /// spelling -- that would bypass every rule keyed on the marker.
    priv fn _report_unmarked_transfer(self, m: *FunctionDecl, p: *ParamDecl, dn: string) {
        var b = self.sc->diag->report(DiagID::SC110E, m->range.start,
            f"a constructor taking 'Self' first is a transfer constructor; declare it '@copy fn {dn}(self, const other: Self)' or '@move fn {dn}(self, other: Self)\x27"
        );
        b.first(m->range);
        if p->mode != ParamMode::Value {
            var mw = ("@move") if (p->mode == ParamMode::Move) else ("@inout");
            b.note(p->mode_range.start, f"'{mw}' on the parameter is not a transfer constructor").first(p->mode_range);
        }
        b.emit();
        self.n_errored += 1;
    }

    /// The doc's rules about the lifecycle itself (Classes: Lifecycle
    /// Categories). One error per rule per class, at the offending member.
    priv fn _check_lifecycle_rules(self, n: *ClassDecl) {
        var f  = self.facts_of(static_cast::<*Decl>(n));
        var dn = self.sc->ctx->get_spelling(n->name);

        // The first transfer ctor of each kind, and the first one that
        // repeats a kind already seen (with the one it repeats).
        var copy_ctor: *FunctionDecl = &null;
        var move_ctor: *FunctionDecl = &null;
        var dup_of:    *FunctionDecl = &null;
        var dup:       *FunctionDecl = &null;
        var dtor:      *FunctionDecl = &null;
        var assign:    *FunctionDecl = &null;
        for var i: usize = 0; i < n->methods.size(); ++i {
            var m = n->methods[i];
            if m == &null { continue; }
            if m->transfer == TransferKind::Copy {
                if copy_ctor == &null { copy_ctor = m; }
                else if dup == &null  { dup_of = copy_ctor; dup = m; }
            }
            if m->transfer == TransferKind::Move {
                if move_ctor == &null { move_ctor = m; }
                else if dup == &null  { dup_of = move_ctor; dup = m; }
            }
            if self._is_dtor(m) { dtor = m; }
            if m->is_operator && (m->op_token.size() > 0) && (m->op_token[0].kind == TokenKind::OpEqual) { assign = m; }
        }

        // 1. One transfer constructor. Both is legal only as NON_TRANSFER
        //    (both `= delete`), the ScopeLock shape. Two of one kind never
        //    are: RedeclMerge keeps any two marked constructors apart so
        //    the error is this one, not a redeclaration -- `@copy` with and
        //    without `const` on `other` would otherwise merge as one member,
        //    since top-level const is not in a signature.
        if dup != &null {
            var marker = ("@copy") if (dup->transfer == TransferKind::Copy) else ("@move");
            self.sc->diag->report(DiagID::SC057E, dup->range.start,
                f"'{dn}' declares more than one '{marker}' transfer constructor; a class has exactly one transfer constructor"
            ).first(dup->range)
             .note(dup_of->range.start, "the other transfer constructor is here").first(dup_of->range)
             .emit();
            dup->poison();
            self.n_errored += 1;
        } else if (copy_ctor != &null) && (move_ctor != &null)
        && (!((copy_ctor->body_kind == FnBodyKind::Delete) && (move_ctor->body_kind == FnBodyKind::Delete))) {
            self.sc->diag->report(DiagID::SC057E, move_ctor->range.start,
                f"'{dn}' declares both a '@copy' and a '@move' transfer constructor; pick one "
                + "(both may be '= delete' together, which makes the class non-transferable)"
            ).first(move_ctor->range)
             .note(copy_ctor->range.start, "the other transfer constructor is here").first(copy_ctor->range)
             .emit();
            move_ctor->poison();
            self.n_errored += 1;
        }

        // 2. `op =` is auto-derived from the transfer constructor; writing
        //    it is an error.
        if assign != &null {
            self.sc->diag->report(DiagID::SC058E, assign->range.start,
                f"'{dn}' defines 'op ='; assignment is derived from the transfer constructor and cannot be written"
            ).first(assign->range).emit();
            assign->poison();
            self.n_errored += 1;
        }

        // 3. A transfer ctor with a BODY derives an `op =` that destroys
        //    self first; a deleted destructor makes that impossible.
        var xfer = (move_ctor) if (move_ctor != &null) else (copy_ctor);
        if (xfer != &null) && (dtor != &null)
        && ((xfer->body_kind == FnBodyKind::Block) || (xfer->body_kind == FnBodyKind::Expr))
        && (dtor->body_kind == FnBodyKind::Delete) {
            self.sc->diag->report(DiagID::SC059E, xfer->range.start,
                f"'{dn}' has a transfer constructor with a body and a deleted destructor; the derived 'op =' must destroy the old value first and cannot"
            ).first(xfer->range)
             .note(dtor->range.start, "destructor deleted here").first(dtor->range)
             .note(xfer->range.start, "provide a destructor, or make the transfer constructor '= default' / '= delete\x27")
             .emit();
            xfer->poison();
            self.n_errored += 1;
        }

        // 4. Custom destructor, implicit copy: almost always an owned
        //    resource that will be silently copied. Warning, per the doc.
        if (dtor != &null) && (dtor->body_kind != FnBodyKind::Default) && (dtor->body_kind != FnBodyKind::Delete)
        && (!f->user_transfer) {
            self.sc->diag->report(DiagID::SC060W, dtor->range.start,
                f"'{dn}' has a custom destructor but no '@copy' or '@move' transfer constructor; it is implicitly copyable"
            ).first(dtor->range)
             .note(dtor->range.start, f"declare it move-only: '@move fn {dn}(self, other: Self) = default\x27")
             .note(dtor->range.start, f"or delete copying: '@copy fn {dn}(self, other: Self) = delete\x27")
             .emit();
        }

        // 5. Category compatibility with every base (doc table): a COPY
        //    base admits COPY / NON_TRANSFER; MOVE admits MOVE / NON_TRANSFER;
        //    NON_TRANSFER admits NON_TRANSFER only. The bad case is a
        //    copyable base under a move-only derived: slicing through a
        //    base pointer would copy a subobject that promised not to be.
        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var e  = n->derives_list.get(i);
            var bd = self._base_decl(e->base);
            if (bd == &null) || isa::<InterfaceDecl>(bd) { continue; }
            var bf = self.facts_of(bd);
            // Unknown facts are resolved per instance at M2, which does not exist yet.
            if (f->category == LifecycleCategory::Unknown) || (bf->category == LifecycleCategory::Unknown) { continue; }
            var ok = (f->category == LifecycleCategory::NonTransfer)
                  || (f->category == bf->category);
            if ok { continue; }
            var bn = self._tu.decl_name(bd);
            self.sc->diag->report(DiagID::SC061E, e->range.start,
                f"'{dn}' is {self._cat_word(f->category)}, but its base '{bn}' is {self._cat_word(bf->category)}; a derived class's lifecycle category must match its base's, or be non-transferable"
            ).first(e->range)
             .note(bd->range.start, "base declared here").first(bd->range)
             .emit();
            self.n_errored += 1;
        }

        // 6. A defaulted transfer constructor transfers memberwise, so every
        //    base and by-value field must transfer that way: a defaulted
        //    `@copy` needs each copyable, a defaulted `@move` each movable (a
        //    COPY-only field is copied as part of the move, per the doc). C++
        //    would quietly define it as deleted instead, and the class would
        //    claim a category it cannot transfer as.
        if (copy_ctor != &null) && (!copy_ctor->is_poisoned()) && (copy_ctor->body_kind == FnBodyKind::Default) {
            self._check_defaulted_transfer(n, copy_ctor, dn);
        }
        if (move_ctor != &null) && (!move_ctor->is_poisoned()) && (move_ctor->body_kind == FnBodyKind::Default) {
            self._check_defaulted_transfer(n, move_ctor, dn);
        }
    }

    /// Rule 6 for one defaulted transfer ctor \p x of \p n: the first base,
    /// then the first field, that cannot be transferred the way \p x does,
    /// in the order C++ constructs them. One error per constructor.
    priv fn _check_defaulted_transfer(self, n: *ClassDecl, x: *FunctionDecl, dn: string) {
        var is_copy = x->transfer == TransferKind::Copy;
        var kind    = ("copy") if (is_copy) else ("move");

        for var i: usize = 0; i < n->derives_list.size(); ++i {
            var e  = n->derives_list.get(i);
            var bd = self._base_decl(e->base);
            if (bd == &null) || isa::<InterfaceDecl>(bd) { continue; }
            var bf = self.facts_of(bd);
            if bf->in_progress { continue; }                 // a cycle; TypeCycleCheck's.
            var why = self._untransferable(bf, is_copy);
            if why.size() == 0 { continue; }
            var bn = self._tu.decl_name(bd);
            var b = self.sc->diag->report(DiagID::SC129E, x->range.start,
                f"'{dn}' cannot have a defaulted {kind} constructor: base '{bn}' is {why}"
            );
            b.first(x->range);
            b.note(DiagID::SC129N, e->range.start, f"'{bn}' is a base of '{dn}' here").first(e->range);
            b.emit();
            self.n_errored += 1;
            return;
        }

        var fields = self._fields(static_cast::<*Decl>(n));
        for var i: usize = 0; i < fields.size(); ++i {
            var fd = fields[i];
            if (fd == &null) || fd->is_static() { continue; }
            if (fd->type_ == &null) || (fd->type_->canonical == &null) { continue; }
            var ff = self.facts_of_type(fd->type_->canonical);
            if ff.in_progress { continue; }                  // a cycle; TypeCycleCheck's.
            var why = self._untransferable(&ff, is_copy);
            if why.size() == 0 { continue; }
            var fname = self.sc->ctx->get_spelling(fd->name);
            var tn    = self._tu.str(fd->type_->canonical);
            var b = self.sc->diag->report(DiagID::SC129E, x->range.start,
                f"'{dn}' cannot have a defaulted {kind} constructor: field '{fname}' of type '{tn}' is {why}"
            );
            b.first(x->range);
            b.note(DiagID::SC129N, fd->range.start, f"'{fname}' declared here").first(fd->range);
            b.emit();
            self.n_errored += 1;
            return;
        }
    }

    /// Why a component with facts \p c cannot be transferred by a defaulted
    /// copy (\p is_copy) or move, or "" when it can or cannot be told yet.
    priv fn _untransferable(self, c: *LifecycleFacts, is_copy: bool) -> string {
        // Unknown facts are resolved per instance at M2, which does not exist yet.
        if is_copy {
            if c->copyable != LifecycleTri::No { return ""; }
            if c->movable == LifecycleTri::Yes { return "move-only"; }
            if c->movable == LifecycleTri::No  { return "not transferable"; }
            return "not copyable";
        }
        if c->movable != LifecycleTri::No { return ""; }
        // An imported type can delete its move and keep its copy; a defaulted
        // move then picks the deleted move all the same.
        if c->copyable == LifecycleTri::No { return "not transferable"; }
        return "not movable";
    }

    priv fn _cat_word(self, c: LifecycleCategory) -> string {
        switch c {
            case LifecycleCategory::Move        { return "move-only (@move)";           }
            case LifecycleCategory::NonTransfer { return "non-transferable (both deleted)"; }
            case LifecycleCategory::Unknown     { return "undecided until instantiation"; }
            default                             { return "copyable (@copy)";            }
        }
    }

    // === helpers =============================================================

    /// `fn op delete(self)`: the destructor. DeclImport keys an imported one
    /// the same way (KwDelete).
    priv fn _is_dtor(self, m: *FunctionDecl) -> bool {
        if !m->is_operator { return false; }
        if m->op_token.size() == 0 { return false; }
        return m->op_token[0].kind == TokenKind::KwDelete;
    }

    priv fn _methods(self, d: *Decl) -> vec::<*FunctionDecl> {
        var out = vec::<*FunctionDecl>();
        var lst: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(d)       { lst = &(cast::<ClassDecl>(d)->methods);  }
        else if isa::<StructDecl>(d) { lst = &(cast::<StructDecl>(d)->methods); }
        else if isa::<UnionDecl>(d)  { lst = &(cast::<UnionDecl>(d)->methods);  }
        if lst == &null { return out; }
        for var i: usize = 0; i < lst->size(); ++i { out.push_back((*lst)[i]); }
        return out;
    }

    priv fn _fields(self, d: *Decl) -> vec::<*FieldDecl> {
        var out = vec::<*FieldDecl>();
        var lst: *FrozenList::<*FieldDecl> = &null;
        if isa::<ClassDecl>(d)       { lst = &(cast::<ClassDecl>(d)->fields);  }
        else if isa::<StructDecl>(d) { lst = &(cast::<StructDecl>(d)->fields); }
        else if isa::<UnionDecl>(d)  { lst = &(cast::<UnionDecl>(d)->fields);  }
        if lst == &null { return out; }
        for var i: usize = 0; i < lst->size(); ++i { out.push_back((*lst)[i]); }
        return out;
    }

    priv fn _layout(self, d: *Decl) -> *ForeignLayout {
        if isa::<ClassDecl>(d)  { return &(cast::<ClassDecl>(d)->layout);  }
        if isa::<StructDecl>(d) { return &(cast::<StructDecl>(d)->layout); }
        if isa::<UnionDecl>(d)  { return &(cast::<UnionDecl>(d)->layout);  }
        return &null;
    }

    /// The record decl a base edge names, or null (unresolved, dependent).
    priv fn _base_decl(self, t: *Type) -> *Decl {
        if (t == &null) || (t->canonical == &null) { return &null; }
        var c = canon_unqual(t->canonical);
        if !isa::<RecordType>(c) { return &null; }
        return cast::<RecordType>(c)->decl;
    }

    /// A base edge _base_decl has no decl for because it names a generic
    /// parameter (`derives T`), as opposed to one T could not resolve.
    priv fn _dependent_base(self, t: *Type) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        var c = canon_unqual(t->canonical);
        return c->is_dependent() || c->is_instantiation_dependent();
    }
}

/// THE ClassLifecycle of \p sc's run: Sema owns it and publishes it on
/// SemaContext::lifecycle, untyped there because this file imports that one.
/// Every reader comes through here, so the facts are one memo per TU.
fn lifecycle_of(sc: *SemaContext) -> *ClassLifecycle {
    if (sc == &null) || (sc->lifecycle == &null) {
        ICE_FAIL("lifecycle facts read before Sema created them");
    }
    return reinterpret_cast::<*ClassLifecycle>(sc->lifecycle);
}
