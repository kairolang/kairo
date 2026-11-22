/// --- The Kairo Project --------------- Sema/Check/LocalDisposition.k --- ///
///
/// How each automatic local's destructor runs (LocalDtor), and the
/// one place that writes it.
///
///   \detail
///     A block-scope local whose destructor is non-trivial is `T x` in C++,
///     destroyed at every exit of its scope, unless something ends its
///     lifetime earlier. Then it is stored as the member of a union whose
///     own destructor does nothing, and its mode says what runs the
///     destructor (Compiler/Spec/Lowering.md#union-storage-locals):
///
///       Scope    `T x`; nothing ends it early.
///       Cleanup  union storage and a cleanup hook that runs at every exit.
///       Elided   union storage and no hook: every exit is reached only
///                after a site that ended the object.
///       Flagged  union storage, a `live` flag and a hook that tests it:
///                some exits are reached with the object alive, some not.
///
///     A site that ends a local is a `x.finally()` call (CallExpr::finalize)
///     or a disarmed move (a move site recorded by disarm_local_at). Every
///     mode a provider asks for is joined into what the local already has
///     (join_local_dtor): Flagged is correct wherever any mode is, so two
///     providers that disagree get the flag, never a double destruction or
///     a leak.
///
///     LocalEnds is MoveCheck's record of both providers: the locals each
///     body declares, which of them a `finally()` ends, which a real
///     transfer moves out of (a destructive type's moved-from object needs
///     no destructor, destructive_type), and which are still alive (or may
///     be) at some exit of their scope. settle() turns that into each
///     local's mode when the body's walk ends, and writes every local of
///     the body, so a second check of the same tree (the language
///     server's) leaves no stale mode behind.
///
///     A by-value parameter C++ passes as `T&&` (DeclFacts::
///     fn_keeps_value_params) names the caller's storage, so nothing in the
///     body destroys it. It has a row too (LocalEnds::declare_param), and
///     the same walk says who ends the object (ParamOwner): the body, when
///     every exit is reached with the value moved out by a real transfer
///     (Moved), or moved out on some and untouched on the others, where a
///     guard moves it into a temporary and destroys that (Consumed); the
///     caller otherwise, which is always correct.
///
///   Phase: CHECK (MoveCheck). EmitIR reads VariableDecl::dtor_mode and
///   ParamDecl::owner.
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
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::{
    decl_is_imported,
    decl_pattern,
    tu_of,
}
import AST::Kind::TypeKind::TypeKind
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
    ClassDecl,    FieldDecl,  FnBodyKind,   FunctionDecl, LocalDtor, ParamDecl, ParamOwner,
    StorageClass, StructDecl, VariableDecl,
}
import AST::Node::Expressions
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import Sema::Check::ClassLifecycle::{
    LifecycleTri,
    lifecycle_of,
}
import Sema::SemaContext::SemaContext
import Token::TokenKind::TokenKind

/// The move at `site` is a real transfer of the whole local `d`
/// (MoveKind::Transfer: a Kairo move construction, move assignment or
/// return of its value). MoveCheck records it as it marks the move, for a
/// provider to ask after the walk (is_real_transfer).
pub fn record_real_transfer(sc: unsafe *SemaContext, site: unsafe *Expr, d: unsafe *Decl) {
    var unsafe *v = dyn_cast<VariableDecl>(d)
    if v == &null || v->is_static() {
        return
    }

    sc->real_moves[site as usize as u64] = d as usize as u64
}

/// The query a provider asks before it disarms: the move at `site` is a
/// real transfer of the WHOLE local `v`. Every other move MoveCheck
/// counts (MoveKind) may leave the object owning its resource.
pub fn is_real_transfer(sc:   unsafe *SemaContext,
                        site: unsafe *Expr,
                        v:    unsafe *VariableDecl) -> bool {
    var it = sc->real_moves.find(site as usize as u64)
    return it != sc->real_moves.end() && it->second == (v as usize as u64)
}

/// The one call of a provider that proves a move ends a local's lifetime
/// ("definitely moved"): the move at `site` transfers the whole local
/// `v` (is_real_transfer), and the moved-from object is not destroyed.
/// `mode` is what the provider proved for every exit of `v`'s scope:
/// Elided when each is reached only after a site that ended `v` (this
/// one, another disarmed move, or a `finally()`), Flagged otherwise. The
/// site is recorded (SemaContext::disarm_sites; CopyMoveLowering puts it
/// on the cast, TypeCastExpr::disarms) and the mode is joined into the
/// local's, so a provider never weakens what another decided. The
/// provider is LocalEnds::settle, which writes the local's mode afresh on
/// every check first.
///
/// EmitIR does at the site what it does after `finally()` minus the
/// destructor call: flagged, it clears `live` with the move; elided,
/// nothing runs at the scope's end. A site on a local whose mode does
/// not end it, or an ending mode with no site, is an ICE there.
pub fn disarm_local_at(sc:   unsafe *SemaContext,
                       site: unsafe *Expr,
                       v:    unsafe *VariableDecl,
                       mode: LocalDtor) {
    if mode != LocalDtor::Elided && mode != LocalDtor::Flagged {
        kairo::std::ice_fail(
            "LocalDisposition: a disarmed move with a mode that destroys the object",
        )
    }

    if !is_real_transfer(sc, site, v) {
        kairo::std::ice_fail(
            "LocalDisposition: a disarmed move that is not a real transfer of the whole local",
        )
    }

    sc->disarm_sites[site as usize as u64] = v as usize as u64
    v->dtor_mode                           = join_local_dtor(v->dtor_mode, mode)
}

/// The mode that is correct wherever `a` or `b` is: Flagged over
/// everything, an ending mode (Elided) over a destroying one, union
/// storage (Cleanup) over plain.
pub fn join_local_dtor(a: LocalDtor, b: LocalDtor) -> LocalDtor {
    if a == LocalDtor::Flagged || b == LocalDtor::Flagged {
        return LocalDtor::Flagged
    }

    if a == LocalDtor::Elided || b == LocalDtor::Elided {
        return LocalDtor::Elided
    }

    if a == LocalDtor::Cleanup || b == LocalDtor::Cleanup {
        return LocalDtor::Cleanup
    }

    return LocalDtor::Scope
}

/// Whether `v`'s destructor is non-trivial: Yes / No / Unknown (a type
/// that depends on a generic parameter, or none known yet).
pub fn local_has_dtor(sc: unsafe *SemaContext, v: unsafe *VariableDecl) -> LifecycleTri {
    if v->type_ == &null || v->type_->canonical == &null || v->type_->canonical->is_dependent() {
        return LifecycleTri::Unknown
    }

    var f = lifecycle_of(sc)->facts_of_type(v->type_->canonical)
    if f.trivial_dtor == LifecycleTri::Yes {
        return LifecycleTri::No
    }

    if f.trivial_dtor == LifecycleTri::No {
        return LifecycleTri::Yes
    }

    return LifecycleTri::Unknown
}

/// Whether a moved-from object of type `t` need not be destroyed
/// (ClassLifecycle, destructive): Yes / No / Unknown (a type that depends
/// on a generic parameter, or none known yet). The one predicate every
/// provider of a disarmed move asks: skipping the destructor of a
/// moved-from object of any other type leaks what its move left behind.
pub fn destructive_type(sc: unsafe *SemaContext, t: unsafe *Type) -> LifecycleTri {
    if t == &null || t->canonical == &null || t->canonical->is_dependent() {
        return LifecycleTri::Unknown
    }

    return lifecycle_of(sc)->facts_of_type(t->canonical).destructive
}

/// Why `v`, a block-scope local with a non-trivial destructor, cannot be
/// stored in a union (""  when it can). Each reason is a local whose C++
/// declaration has no single `T` to wrap or whose storage is not
/// automatic.
pub fn union_storage_refusal(v: unsafe *VariableDecl) -> string {
    if v->storage == StorageClass::Static || v->is_thread {
        return "it has static storage"
    }

    if v->storage == StorageClass::Eval {
        return "it is an 'eval' constant"
    }

    if v->type_ == &null || v->type_->canonical == &null {
        return "its type is not known"
    }

    var unsafe *c = canon_unqual(v->type_->canonical)
    if c == &null || c->kind == TypeKind::FixedArrayType {
        return "it is a fixed-size array"
    }

    return ""
}

/// `t` names, through pointers, references, generic arguments and outer
/// records, an imported record declared inside a class. EmitIR spells a
/// local whose type names a private or protected one of those `auto`
/// (Speller::names_hidden_member), which no union member can be; this is
/// that test without the access check, so it refuses at least every type
/// EmitIR would.
pub fn names_cxx_member_type(t: unsafe *Type) -> bool {
    if t == &null || t->canonical == &null {
        return false
    }

    var unsafe *c = canon_unqual(t->canonical)
    if c == &null {
        return false
    }

    if c->kind == TypeKind::PointerType {
        return names_cxx_member_type(cast<PointerType>(c)->pointee)
    }

    if c->kind == TypeKind::CXXLValueRefType {
        return names_cxx_member_type(cast<CXXLValueRefType>(c)->referee)
    }

    if c->kind == TypeKind::CXXRValueRefType {
        return names_cxx_member_type(cast<CXXRValueRefType>(c)->referee)
    }

    var unsafe *r = dyn_cast<RecordType>(c)
    if r == &null {
        return false
    }

    if r->decl != &null && decl_is_imported(r->decl) {
        if _in_type_scope(r->decl) || _in_type_scope(decl_pattern(r->decl)) {
            return true
        }
    }

    for var i: usize = 0; i < r->args.size(); ++i {
        if names_cxx_member_type(r->args[i]) {
            return true
        }
    }

    return r->outer != &null && names_cxx_member_type(r->outer)
}

fn _in_type_scope(d: unsafe *Decl) -> bool {
    return d != &null && d->semantic_dc != &null && d->semantic_dc->is_type_scope()
}

/// Why a real transfer out of `v` cannot skip the moved-from object's
/// destructor ("" when it can): its storage cannot be a union, it is a
/// binder or a local a lowering made, or its type's moved-from object
/// still owns something (destructive_type is not Yes: a COPY class, a C++
/// type, a type a generic parameter decides). The caller adds what only
/// the body knows (a constructor, an `eval` or constexpr function, a
/// C-style `for` variable). EmitIR (`_union_local_decl`) keeps a plain
/// `T x` for a declaration it cannot wrap and ICEs on an ending mode
/// there, so every such case is refused here first: an attribute covers
/// `@align`.
pub fn disarm_refusal(sc: unsafe *SemaContext, v: unsafe *VariableDecl) -> string {
    var u = disarm_storage_refusal(v)
    if u.size() > 0 {
        return u
    }

    if destructive_type(sc, v->type_) != LifecycleTri::Yes {
        return "its type's moved-from object is destroyed"
    }

    return ""
}

/// disarm_refusal without the question about the local's own type: why a
/// move out of `v`, whole or a part of it, cannot change how the rest of
/// it is destroyed ("" when it can). A part's type is asked on its own
/// (part_moved_refusal).
pub fn disarm_storage_refusal(v: unsafe *VariableDecl) -> string {
    var u = union_storage_refusal(v)
    if u.size() > 0 {
        return u
    }

    if v->has_attribute() {
        return "it has an attribute"
    }

    if names_cxx_member_type(v->type_) {
        return "its type names a member type of a C++ class"
    }

    if v->borrows
        || v->borrow_inst
        || v->place_ref
        || v->auto_copy
        || v->raw_slot
        || v->starts_empty
        || v->gen_iter
        || v->header_scope {
        return "it is a binder or a lowering's local"
    }

    return ""
}

/// Why a field of type `t` moved out of a local cannot be left out of the
/// local's destruction ("" when it can): its moved-from object must need
/// no destructor (destructive_type), and every transfer of it must be a
/// move (a type that copies has its moves decided later, per use), and it
/// must be a record, not an array, tuple, nullable or enum.
pub fn part_moved_refusal(sc: unsafe *SemaContext, t: unsafe *Type) -> string {
    if t == &null || t->canonical == &null || t->canonical->is_dependent() {
        return "its type is not known"
    }

    var unsafe *r = dyn_cast<RecordType>(canon_unqual(t->canonical))
    if r == &null || r->decl == &null || !(isa<ClassDecl>(r->decl) || isa<StructDecl>(r->decl)) {
        return "it is not a class"
    }

    if destructive_type(sc, t) != LifecycleTri::Yes {
        return "its moved-from object is destroyed"
    }

    if lifecycle_of(sc)->facts_of_type(t->canonical).copyable != LifecycleTri::No {
        return "its type copies"
    }

    return ""
}

/// Why the record `t`, the local's type or a field's on the way to a
/// moved part, cannot be destroyed field by field in the body of `f`
/// ("" when it can). The residual hook (VariableDecl::moved_parts) runs
/// the destructor of each field the moves left, which is all the
/// record's own destructor does only when that is the implicit one: a
/// Kairo class with no `op finally` body, no base and no vptr. The hook
/// is a lambda in `f` naming the record's fields, which a private field
/// allows only to the functions the record befriends; a free function of
/// the record's own file and namespace is one (EmitPlan::file_friends),
/// and anything else is refused.
pub fn part_record_refusal(sc: unsafe *SemaContext,
                           t:  unsafe *Type,
                           f:  unsafe *FunctionDecl) -> string {
    if t == &null || t->canonical == &null || t->canonical->is_dependent() {
        return "its type is not known"
    }

    var unsafe *r = dyn_cast<RecordType>(canon_unqual(t->canonical))
    if r == &null || r->decl == &null || !isa<ClassDecl>(r->decl) {
        return "it is not a class"
    }

    var unsafe *c = dyn_cast<ClassDecl>(decl_pattern(r->decl))
    if c == &null || decl_is_imported(r->decl) || decl_is_imported(unsafe (c as unsafe *Decl)) {
        return "it is not a Kairo class"
    }

    if c->derives_list.size() > 0 || cast<ClassDecl>(r->decl)->derives_list.size() > 0 {
        return "it has a base"
    }

    if lifecycle_of(sc)->facts_of_type(t->canonical).polymorphic != LifecycleTri::No {
        return "it is polymorphic"
    }

    for var i: usize = 0; i < c->methods.size(); ++i {
        var unsafe *m = c->methods[i]
        if m != &null
            && m->is_operator
            && m->op_token.size() > 0
            && m->op_token[0].kind == TokenKind::KwFinally
            && m->body_kind != FnBodyKind::Default {
            return "it has a destructor of its own"
        }
    }

    if f == &null
        || f->is_method()
        || f->generic_params.size() > 0
        || f->semantic_dc == &null
        || f->semantic_dc != c->semantic_dc
        || f->lexical_dc == &null
        || c->lexical_dc == &null
        || tu_of(f->lexical_dc) != tu_of(c->lexical_dc) {
        return "its fields are reached only by the functions of its own file and namespace"
    }

    return ""
}

/// One local a body declares, as both providers follow it, or one by-value
/// parameter of the function whose body it is (`p`).
pub class LocalEndRow {
    pub var d: unsafe *VariableDecl = &null
    /// The parameter this row follows, null for a local's row; `key` is
    /// the declaration a use resolves to, either one.
    pub var p:   unsafe *ParamDecl = &null
    pub var key: unsafe *Decl      = &null
    /// `p` only: a guard may end it where the body did not move it
    /// (ParamOwner::Consumed). False where no guard can be declared (a
    /// constructor, whose parameters cross its split; a generic type; an
    /// `eval` or constexpr function).
    pub var guard_ok: bool = false
    /// `p` only: its type depends on a generic parameter, so its transfers
    /// are pending moves (MoveCheck::_dependent_transfer), which leave no
    /// mark in the moved set.
    pub var dep: bool = false
    /// `p` only: something in the body may move it, or a part of it, some
    /// other way than by a real transfer of the whole of it (or an exit is
    /// reached with such a transfer's mark taken back). The object may
    /// then be moved-from where no site of the row said so, and only its
    /// owner's destructor is safe on it.
    pub var dirty: bool  = false
    pub var ends:  usize = 0 ///< sites that end it (a `finally()` call).
    pub var alive: bool  = false ///< some exit of its scope is reached with it not finalized on every path.
    /// Why its declaration cannot take union storage ("" when it can): it
    /// keeps `Scope`, and a `finally()` of it is SC116E.
    pub var refusal: string = ""
    /// A real transfer out of it may skip the moved-from object's
    /// destructor (disarm_refusal and the body's own refusals passed).
    pub var cand: bool = false
    /// Some real transfer of it cannot disarm (inside a `finally { }` body,
    /// an unevaluated operand, a self-assignment): none of them does.
    pub var bad: bool = false
    /// Its real transfers other than `return x`, each once, a dead path's
    /// included (EmitIR writes every one), and its `return x` values.
    pub var sites: [unsafe *Expr]
    pub var rets:  [unsafe *Expr]
    /// Its Move captures: the closure and the index of the capture row
    /// (ClosureExpr::Held::disarms, written by settle), each once.
    pub var caps:   [unsafe *Expressions::ClosureExpr]
    pub var cap_at: [usize]
    /// Visits of its sites, loop passes included: an assignment to it
    /// compares the count before and after its right-hand side.
    pub var visits: usize = 0
    /// Some exit of its scope is reached with it neither finalized nor
    /// moved by a real transfer on every path.
    pub var alive_unmoved: bool = false
    /// Whole assignments that construct it again after a `finally()`
    /// (AssignOperatorExpr::remake).
    pub var remakes: [unsafe *Expressions::AssignOperatorExpr]
    /// Whole assignments reached after a move of it, with the states they
    /// are reached in (REMAKE_DEAD / REMAKE_MAYBE): written onto the node
    /// only when its moves are disarmed (settle), since until then the
    /// moved-from object is still there and `op =` is what runs.
    pub var mremakes: [unsafe *Expressions::AssignOperatorExpr]
    pub var mbits:    [u8]
    /// A move of a field out of it may leave that field out of its
    /// destruction (disarm_storage_refusal and the body's own refusals
    /// passed; LocalEnds::part_moved_at asks the rest per move).
    pub var pcand: bool = false
    /// Some part move of it, or something done to it, rules that out.
    pub var pbad: bool = false
    /// Each path a part move takes out of it, once, and the fields of
    /// each (MovePlace::segs), every path's ended by a null.
    pub var ppaths: [string]
    pub var psegs:  [unsafe *Decl]
    /// The exits of its scope seen, and the parts moved out at the first:
    /// every other exit must have exactly these moved out, on every path.
    pub var pexits: usize    = 0
    pub var pset:   [string]
    fn LocalEndRow(self) { }

    /// What is left of it after its part moves is destroyed field by
    /// field (VariableDecl::moved_parts): the same parts are moved out at
    /// every exit, and nothing else ends, moves or rebuilds the whole, nor
    /// can leave the body where the walk does not see (`may_unwind`).
    fn partial(self, may_unwind: bool) -> bool {
        return self.pcand
            && !self.pbad
            && !self.bad
            && !may_unwind
            && self.refusal.size() == 0
            && self.sites.size() == 0
            && self.rets.size() == 0
            && self.caps.size() == 0
            && self.ends == 0
            && self.remakes.size() == 0
            && self.mremakes.size() == 0
            && self.pset.size() > 0
    }

    /// Its real transfers are disarmed: it can take the storage, every one
    /// of them can disarm, and there is one that is not a `return`, or a
    /// `finally()` gives it the storage anyway. A local only returned
    /// stays a plain `T x`, which C++ elides into the result.
    fn managed(self) -> bool {
        if !self.cand || self.bad || self.refusal.size() > 0 {
            return false
        }

        return self.sites.size() > 0
            || self.caps.size() > 0
            || self.ends > 0 && self.rets.size() > 0
    }
}

/// MoveCheck's record of the locals of the body being walked; one per
/// body (saved and restored around a nested one).
pub class LocalEnds {
    pub var rows: [LocalEndRow]
    fn LocalEnds(self) { }

    /// `d` is a local this body declares (a DeclStmt of one of its blocks);
    /// `refusal` as LocalEndRow::refusal, `cand` as LocalEndRow::cand.
    /// `pcand` as LocalEndRow::pcand.
    fn declare(self, d: unsafe *VariableDecl, const refusal: string, cand: bool, pcand: bool) {
        if self.index_of(d) != usize::MAX {
            return
        }

        var r = LocalEndRow()
        r.d       = d
        r.key     = unsafe (d as unsafe *Decl)
        r.refusal = refusal.copy()
        r.cand    = cand && refusal.size() == 0
        r.pcand   = pcand && refusal.size() == 0
        self.rows.push(r)
    }

    /// `p` is a by-value parameter of the function whose body this is that
    /// C++ passes as `T&&` (or may, at an instance: `dep`). Its real
    /// transfers are followed as a local's are; `guard_ok` as
    /// LocalEndRow::guard_ok.
    fn declare_param(self, p: unsafe *ParamDecl, dep: bool, guard_ok: bool) {
        if self.index_of(unsafe (p as unsafe *Decl)) != usize::MAX {
            return
        }

        var r = LocalEndRow()
        r.p        = p
        r.key      = unsafe (p as unsafe *Decl)
        r.cand     = true
        r.dep      = dep
        r.guard_ok = guard_ok && !dep
        self.rows.push(r)
    }

    /// `d` is a parameter's row.
    fn is_param(self, d: unsafe *Decl) -> bool {
        var i = self.index_of(d)
        return i != usize::MAX && self.rows[i].p != &null
    }

    /// `d` is a parameter's row whose type an instance decides.
    fn is_dep_param(self, d: unsafe *Decl) -> bool {
        var i = self.index_of(d)
        return i != usize::MAX && self.rows[i].p != &null && self.rows[i].dep
    }

    /// The parameter rows, in declaration order.
    fn params(self) -> [unsafe *Decl] {
        var out: [unsafe *Decl]
        for var i: usize = 0; i < self.rows.size(); ++i {
            if self.rows[i].p != &null {
                out.push(self.rows[i].key)
            }
        }

        return out
    }

    /// `e` is one of the real transfers the row of `d` counts (a site or a
    /// `return`).
    fn is_site(self, d: unsafe *Decl, e: unsafe *Expr) -> bool {
        var i = self.index_of(d)
        if i == usize::MAX || e == &null {
            return false
        }

        for var k: usize = 0; k < self.rows[i].sites.size(); ++k {
            if self.rows[i].sites[k] == e {
                return true
            }
        }

        for var k: usize = 0; k < self.rows[i].rets.size(); ++k {
            if self.rows[i].rets[k] == e {
                return true
            }
        }

        return false
    }

    /// The parameter `d` may be moved some other way than by one of its
    /// row's real transfers (LocalEndRow::dirty).
    fn dirty_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].dirty = true
        }
    }

    /// `d` is a row whose part moves may be left out of its destruction
    /// (LocalEndRow::pcand).
    fn is_pcand(self, d: unsafe *Decl) -> bool {
        var i = self.index_of(d)
        return i != usize::MAX && self.rows[i].pcand
    }

    /// A real transfer moves the part `path` (fields `segs`) out of `d`;
    /// `ok` false when this one cannot be left out, which rules out all.
    fn part_moved_at(self,
                     d:          unsafe *Decl,
                     const path: string,
                     const segs: [unsafe *Decl],
                     ok:         bool) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].pcand {
            return
        }

        if !ok {
            self.rows[i].pbad = true
        }

        for var k: usize = 0; k < self.rows[i].ppaths.size(); ++k {
            if self.rows[i].ppaths[k] == path {
                return
            }
        }

        self.rows[i].ppaths.push(path.copy())
        for var k: usize = 0; k < segs.size(); ++k {
            self.rows[i].psegs.push(segs[k])
        }

        self.rows[i].psegs.push(&null)
    }

    /// An exit of `d`'s scope is reached with the parts `may` moved out on
    /// some path and `must` on every path (`""`: the whole of it).
    fn part_exit(self, d: unsafe *Decl, const may: [string], const must: [string]) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].pcand {
            return
        }

        var *r = &self.rows[i]
        if !_same_paths(may, must) || _has_path(may, "") || _paths_overlap(must) {
            r->pbad = true
        }

        if r->pexits == 0 {
            r->pset = must.copy()
        } else if !_same_paths(r->pset, must) {
            r->pbad = true
        }

        r->pexits += 1
    }

    /// No part move of `d` may be left out of its destruction.
    fn spoil_parts(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].pbad = true
        }
    }

    /// LocalEndRow::refusal of `d` ("" when it is not a row).
    fn refusal_of(self, d: unsafe *Decl) -> string {
        var i = self.index_of(d)
        return if (i != usize::MAX) => (self.rows[i].refusal.copy()) else => ""
    }

    fn index_of(self, d: unsafe *Decl) -> usize {
        for var i: usize = 0; i < self.rows.size(); ++i {
            if self.rows[i].key == d {
                return i
            }
        }

        return usize::MAX
    }

    fn has(self, d: unsafe *Decl) -> bool {
        return self.index_of(d) != usize::MAX
    }

    /// `d` is a row whose real transfers may disarm (LocalEndRow::cand).
    fn is_cand(self, d: unsafe *Decl) -> bool {
        var i = self.index_of(d)
        return i != usize::MAX && self.rows[i].cand
    }

    /// A site ends `d` here.
    fn ended_at_site(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].ends += 1
        }
    }

    /// `site` is a real transfer of the whole local `d`; `ok` false when
    /// this one cannot disarm, which rules out all of them.
    fn moved_at(self, d: unsafe *Decl, site: unsafe *Expr, ok: bool) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].cand {
            return
        }

        self.rows[i].visits += 1
        if !ok {
            self.rows[i].bad = true
        }

        for var k: usize = 0; k < self.rows[i].sites.size(); ++k {
            if self.rows[i].sites[k] == site {
                return
            }
        }

        self.rows[i].sites.push(site)
    }

    /// Capture row `k` of closure `c` moves the whole local `d` in; `ok`
    /// as for moved_at.
    fn captured_at(self, d: unsafe *Decl, c: unsafe *Expressions::ClosureExpr, k: usize, ok: bool) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].cand {
            return
        }

        self.rows[i].visits += 1
        if !ok {
            self.rows[i].bad = true
        }

        for var j: usize = 0; j < self.rows[i].caps.size(); ++j {
            if self.rows[i].caps[j] == c && self.rows[i].cap_at[j] == k {
                return
            }
        }

        self.rows[i].caps.push(c)
        self.rows[i].cap_at.push(k)
    }

    /// `v` is a `return d` of the whole local `d`.
    fn returned_at(self, d: unsafe *Decl, v: unsafe *Expr, ok: bool) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].cand {
            return
        }

        if !ok {
            self.rows[i].bad = true
        }

        for var k: usize = 0; k < self.rows[i].rets.size(); ++k {
            if self.rows[i].rets[k] == v {
                return
            }
        }

        self.rows[i].rets.push(v)
    }

    /// LocalEndRow::visits of `d` (0 when it is not a row).
    fn visits_of(self, d: unsafe *Decl) -> usize {
        var i = self.index_of(d)
        return if (i != usize::MAX) => (self.rows[i].visits) else => 0
    }

    /// None of `d`'s real transfers may disarm.
    fn spoil(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].bad = true
        }
    }

    /// `asn` constructs `d` again after a `finally()`.
    fn remade_at(self, d: unsafe *Decl, asn: unsafe *Expressions::AssignOperatorExpr) {
        var i = self.index_of(d)
        if i == usize::MAX {
            return
        }

        for var k: usize = 0; k < self.rows[i].remakes.size(); ++k {
            if self.rows[i].remakes[k] == asn {
                return
            }
        }

        self.rows[i].remakes.push(asn)
    }

    /// `asn` assigns the whole of `d` reached after a move of it, in the
    /// state `bit` (REMAKE_DEAD: moved by a real transfer on every path;
    /// REMAKE_MAYBE: on some, or by another kind of move).
    fn move_remade_at(self,
                      d:   unsafe *Decl,
                      asn: unsafe *Expressions::AssignOperatorExpr,
                      bit: u8) {
        var i = self.index_of(d)
        if i == usize::MAX {
            return
        }

        for var k: usize = 0; k < self.rows[i].mremakes.size(); ++k {
            if self.rows[i].mremakes[k] == asn {
                self.rows[i].mbits[k] = self.rows[i].mbits[k] | bit
                return
            }
        }

        self.rows[i].mremakes.push(asn)
        self.rows[i].mbits.push(bit)
    }

    /// An exit of `d`'s scope is reached with `d` not ended on every path.
    fn alive_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].alive = true
        }
    }

    /// ...and with `d` not moved by a real transfer on every path either.
    fn alive_unmoved_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].alive_unmoved = true
        }
    }

    /// Each local's mode, written onto the declaration, and the disarmed
    /// moves of the locals whose real transfers skip the moved-from
    /// object's destructor (disarm_local_at). `may_unwind`: a C++
    /// exception can leave the body at a point the walk does not see (an
    /// `@unwind` function, `-funwind`, a closure), so a local some site
    /// ends is never elided there: the hook must still run on that path.
    ///
    /// A local's move-driven assignments (LocalEndRow::mremakes) become
    /// constructions only when its moves are disarmed; otherwise the
    /// moved-from object is there and each is an ordinary assignment
    /// (REMAKE_LIVE), which also makes one a `finally()` reached dead a
    /// maybe-dead construction. Each `return x` of a disarmed local is a
    /// move site of its own, so CopyMoveLowering casts it and EmitIR
    /// clears the flag there.
    fn settle(self, sc: unsafe *SemaContext, may_unwind: bool) {
        for var i: usize = 0; i < self.rows.size(); ++i {
            var *r = &self.rows[i]
            if r->p != &null {
                _settle_param(sc, *r, may_unwind)
                continue
            }

            var managed = r->managed()
            for var k: usize = 0; k < r->rets.size(); ++k {
                sc->move_sites.erase(r->rets[k] as usize as u64)
            }

            for var k: usize = 0; k < r->mremakes.size(); ++k {
                var unsafe *asn = r->mremakes[k]
                asn->remake = asn->remake | (if (managed) => (r->mbits[k])
                                             else => Expressions::REMAKE_LIVE)
            }

            // A construction that may find an object there tests `live`.
            var maybe = _maybe_remade(r->remakes) || managed && _maybe_remade(r->mremakes)
            var partial = !managed && r->partial(may_unwind)
            r->d->moved_parts = FrozenList<unsafe *FieldDecl>::empty()
            var m = LocalDtor::Scope
            if r->refusal.size() > 0 {
                m = LocalDtor::Scope
            } else if partial {
                m                 = LocalDtor::Cleanup
                r->d->moved_parts = _moved_parts(sc, *r)
            } else if managed {
                m = if (r->alive_unmoved || maybe || may_unwind) => (LocalDtor::Flagged)
                    else => LocalDtor::Elided
            } else if r->ends > 0 {
                m = if (r->alive || maybe || may_unwind) => (LocalDtor::Flagged)
                    else => LocalDtor::Elided
            } else if sc->opts.union_locals_all
                && union_storage_refusal(r->d).size() == 0
                && local_has_dtor(sc, r->d) == LifecycleTri::Yes {
                m = LocalDtor::Cleanup
            }

            r->d->dtor_mode = m
            for var k: usize = 0; k < r->caps.size(); ++k {
                r->caps[k]->held.get(r->cap_at[k])->disarms = managed
            }

            if !managed {
                continue
            }

            for var k: usize = 0; k < r->sites.size(); ++k {
                disarm_local_at(sc, r->sites[k], r->d, m)
            }

            for var k: usize = 0; k < r->rets.size(); ++k {
                sc->move_sites.insert(r->rets[k] as usize as u64)
                disarm_local_at(sc, r->rets[k], r->d, m)
            }
        }
    }
}

/// Who ends the object the parameter of row `r` names (ParamDecl::owner),
/// written onto the declaration, and the sites a guard's flag is cleared
/// at. The body ends it only when every exit is reached with it moved out
/// by a real transfer of the whole of it or, with a guard, not moved at
/// all, and nothing else was done to its storage: no `finally()`, no
/// assignment after a move, no move capture, no site that cannot be placed
/// on its path, and no C++ exception that leaves where the walk does not
/// see (`may_unwind`). Anything else leaves it the caller's, which destroys
/// what it passed as C++ destroys a by-value argument.
///
/// A `return p` of such a parameter is a move site either way: the C++
/// parameter is a reference, which no copy elision applies to.
fn _settle_param(sc: unsafe *SemaContext, const r: LocalEndRow, may_unwind: bool) {
    r.p->owner = ParamOwner::Caller
    for var k: usize = 0; k < r.mremakes.size(); ++k {
        var unsafe *asn = r.mremakes[k]
        asn->remake = asn->remake | Expressions::REMAKE_LIVE
    }

    if !r.dep {
        for var k: usize = 0; k < r.rets.size(); ++k {
            sc->move_sites.insert(r.rets[k] as usize as u64)
        }
    }

    var ok = r.cand
        && !r.bad
        && !r.dirty
        && !may_unwind
        && r.ends == 0
        && r.caps.size() == 0
        && r.remakes.size() == 0
        && r.mremakes.size() == 0
        && r.ppaths.size() == 0
        && r.sites.size() + r.rets.size() > 0
    if !ok {
        return
    }

    if !r.alive_unmoved {
        r.p->owner = ParamOwner::Moved
        return
    }

    if !r.guard_ok {
        return
    }

    r.p->owner = ParamOwner::Consumed
    for var k: usize = 0; k < r.sites.size(); ++k {
        sc->disarm_sites[r.sites[k] as usize as u64] = r.p as usize as u64
    }

    for var k: usize = 0; k < r.rets.size(); ++k {
        sc->disarm_sites[r.rets[k] as usize as u64] = r.p as usize as u64
    }
}

/// The fields of each path in `r.pset`, every path's ended by a null
/// (VariableDecl::moved_parts).
fn _moved_parts(sc: unsafe *SemaContext, const r: LocalEndRow) -> FrozenList<unsafe *FieldDecl> {
    var v = cxx::std::vector<unsafe *FieldDecl>()
    for var k: usize = 0; k < r.pset.size(); ++k {
        var at: usize = 0
        for var p: usize = 0; p < r.ppaths.size(); ++p {
            if r.ppaths[p] == r.pset[k] {
                break
            }

            while r.psegs[at] != &null {
                at += 1
            }

            at += 1
        }

        while r.psegs[at] != &null {
            v.push_back(cast<FieldDecl>(r.psegs[at]))
            at += 1
        }

        v.push_back(&null)
    }

    var out = FrozenList<unsafe *FieldDecl>::empty()
    out.from_vec(unsafe &v, sc->ctx)
    return out
}

/// `a` and `b` hold the same paths, in any order.
fn _same_paths(const a: [string], const b: [string]) -> bool {
    for var i: usize = 0; i < a.size(); ++i {
        if !_has_path(b, a[i]) {
            return false
        }
    }

    for var i: usize = 0; i < b.size(); ++i {
        if !_has_path(a, b[i]) {
            return false
        }
    }

    return true
}

fn _has_path(const v: [string], const p: string) -> bool {
    for var i: usize = 0; i < v.size(); ++i {
        if v[i] == p {
            return true
        }
    }

    return false
}

/// Two of `v`'s paths name overlapping storage (one is the other's part).
fn _paths_overlap(const v: [string]) -> bool {
    for var i: usize = 0; i < v.size(); ++i {
        for var k: usize = 0; k < v.size(); ++k {
            if i != k && (v[i] == v[k] || v[k].starts_with(v[i].copy() + ".")) {
                return true
            }
        }
    }

    return false
}

/// Some assignment of `v` is reached maybe dead: MAYBE, or DEAD on one
/// visit and LIVE on another.
fn _maybe_remade(const v: [unsafe *Expressions::AssignOperatorExpr]) -> bool {
    for var k: usize = 0; k < v.size(); ++k {
        var b = v[k]->remake
        if (b & Expressions::REMAKE_MAYBE) != 0
            || (b & Expressions::REMAKE_DEAD) != 0 && (b & Expressions::REMAKE_LIVE) != 0 {
            return true
        }
    }

    return false
}
