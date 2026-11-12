/// --- The Kairo Project --------------------- Sema/Type/MemberTyping.k --- ///
///
///   \brief Chains and subscripts: the value each step of `a.b->c::d` yields.
///
///   \detail
///     ChainBinding already bound every step whose left side had a DECLARED
///     type. What it left as NeedsInference -- a step after a call, after an
///     inferred `var`, after an overload set -- is bound here, by handing
///     ChainBinding the anchor this pass can now compute
///     (`ChainBinding::bind_step`, see spec). One binder, two callers.
///
///     What a step yields:
///       field / var / param      its declared type, seen through the
///                                receiver's generic args   -- LValue
///       enum variant             the enum                   -- RValue
///       method / overload set    nothing: callable; only legal as a callee
///       nested type / alias      nothing: a type; legal as a ctor callee or
///                                initializer head
///       module                   nothing
///       tuple index `.0`         the element                 -- LValue
///       operator step            callable
///     `?.` peels the nullable and the whole chain's result is re-wrapped.
///
///     The chain's shape (receiver before the last step, whether the last
///     step is callable/type) is recorded in ExprTyper::_chains so CallTyping
///     does not re-walk it.
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

import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::decl_is_imported
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::TypeKind::to_string
import AST::LangItems::{
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    QUAL_CONST,
    RecordType,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumVariantDecl, FieldDecl,     FunctionDecl, InterfaceDecl, ParamDecl, StorageClass, TypeAliasDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    RangeExpr,
    SubscriptExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    GenericParamType,
}
import AST::OperatorFacts::OperatorFacts
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::NullnessFlow::{
    NULL_READ_NARROWED,
    NULL_READ_NONE,
    NULL_READ_REFUSED,
    null_flow_type_is_nullable,
    null_place_of,
}
import Sema::Type::OverloadResolution::{
    ArgInfo,
    OvlOutcome,
}
import Sema::Type::Substitution::Substitution
import Token::TokenKind::TokenKind

/// SubscriptExpr::place_ctx (P880): what the consumer of `x[i]` does with
/// the element, set by mark_subscript_use before the subscript is typed. A
/// SPLIT subscript (its type declares `op []=`) selects by it; a type with
/// no `op []=` ignores it (today's single `op []`, place or value by its
/// return).
///   READ   the read form, `op []`; no fallback to `op []=` (SC279E).
///   WRITE  the place form, `op []=`; no fallback (SC071E on a const
///          container): `=` / `op=` / `++` / `--`, a member written through,
///          the container of a written subscript.
///   SOFT   the place form on a mutable container, else the read form:
///          `&x[i]` (P880-4: `*const T` on a const container), `for *e in`.
///   BIND   `var t = a[i..j]` (P880-2): as SOFT.
///   RECV   a method receiver: as SOFT, then settle_receiver_subscript moves
///          it to the read form unless the chosen method takes `self`.
pub
const SUB_READ: u8 = 0
pub
const SUB_WRITE: u8 = 1
pub
const SUB_SOFT: u8 = 2
pub
const SUB_BIND: u8 = 3
pub
const SUB_RECV: u8 = 4

/// \enum ChainKind
/// \brief What the position a chain walk has reached denotes: the walk's
///        state (MemberTyping::type_chain), one step at a time. `cur_type`
///        is meaningful only in Type and `cur` only in Value; a step from
///        Callable is SC100E and from Unknown stops the walk.
pub enum ChainKind derives u8 {
    Value = 0, ///< a value of type `cur`.
    Type,      ///< the type `cur_type` (`Foo::`, `T::Item::`).
    Module,    ///< a module or namespace.
    Callable,  ///< a function or an overload set (`info.callable_cands`).
    Unknown,   ///< dependent or foreign: nothing to say.
}

/// \class ChainInfo
/// \brief What the typer learned about one ChainExpr, for CallTyping.
///        Its flags stay apart rather than one ChainKind: has_receiver
///        (`.` on a value) is orthogonal to what the last step names, and a
///        chain that failed sets neither of the other two.
pub class ChainInfo {
    pub var receiver:       unsafe *Type                   = &null ///< value type before the last step, if any.
    pub var has_receiver:   bool                           = false ///< last step was reached through `.`/`->`/`?.`/`?->` on a value.
    pub var last_is_type:   bool                           = false ///< last step names a type.
    pub var callable_cands: cxx::std::vector<unsafe *Decl> ///< last step is a method / set / operator.
    pub var unknown:        bool                           = false ///< dependent or foreign; nothing to say.
    /// The receiver OBJECT's value category: what a ref-qualified method's
    /// implicit object parameter binds (`q() &` an lvalue, `q() &&` an
    /// rvalue). `p->m()` and a field of an lvalue are lvalues, a field of
    /// an rvalue an xvalue ([expr.ref]/7).
    pub var receiver_cat: Expr::ValueCategory = Expr::ValueCategory::LValue
    fn ChainInfo(self) { }
}

// TODO(DUCK-GENERIC): T uses arg_info, bound_scopes, call_result_type, cb, check_convertible, ded_scratch, denoted_type, denotes_module, discr_enum, fail, finish_call_args, flow, ... (32). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> MemberTyping {
    @move
    fn MemberTyping(self, other: Self) = default
    fn MemberTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// Step \p i of \p n is `?.` / `?->` on \p val, which is not nullable:
    /// SC001E, with the fix-it that drops the `?`.
    priv fn _not_nullable_step(self, n: unsafe *ChainExpr, i: usize, val: unsafe *Type) {
        var unsafe *st = n->steps.get(i)
        var sep = if (st->access_kind == ChainExpr::AccessKind::QuestionArrow) => ("?->")
                  else => "?."
        var to = if (st->access_kind == ChainExpr::AccessKind::QuestionArrow) => ("->") else => "."
        var end  = if (i == 0) => (n->base->range.end) else => n->steps.get(i - 1)->range.end
        var r    = SourceRange(n->range.start, end)
        var text = self.dyn()->sc->ctx->get_spelling(r)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC260E,
            st->range.start,
            f"'{text}' is not nullable ('{self.dyn()->tu.str(val)}'); '{sep}' guards a null it cannot hold, write '{to}'",
        )

        b.first(SourceRange(st->range.start, st->range.start.with_offset(1)))
        // The declaration that gave it the non-nullable type.
        var d: unsafe *Decl = &null
        if i > 0 {
            d = n->steps.get(i - 1)->resolved_decl
        } else if isa<NamedIdentExpr>(self.dyn()->tu.strip_parens(n->base)) {
            d = cast<NamedIdentExpr>(self.dyn()->tu.strip_parens(n->base))->resolved_decl
        }

        if d != &null && d->range.is_valid() {
            b.note(
                d->range.start,
                f"'{self.dyn()->tu.decl_name(d)}' is declared '{self.dyn()->tu.str(val)}' here",
            )
        }

        b.remove(SourceRange(st->range.start, st->range.start.with_offset(1)), f"write '{to}'")
        b.emit()
        self.dyn()->poison_only(n)
    }

    /// \p st's written generic arguments as canonicals, into \p out; false
    /// when one is unresolved (its own error, or dependent past knowing).
    priv fn _step_type_args(self,
                            st:         unsafe *ChainExpr::Step,
                            @inout out: cxx::std::vector<unsafe *Type>) -> bool {
        for var i: usize = 0; i < st->generic_args.size(); ++i {
            var unsafe *g = st->generic_args.get(i)
            if g->ty == &null || g->ty->is_poisoned() || g->ty->canonical == &null {
                return false
            }

            out.push_back(g->ty->canonical)
        }

        return true
    }

    /// `X::Name` / `X::Name<A>` on dependent head \p head (a bounded
    /// parameter, or an associated type at any depth): the associated type
    /// one of its bounds declares under that name and arity, or null.
    priv fn _assoc_step(self,
                        head:       unsafe *Type,
                        st:         unsafe *ChainExpr::Step,
                        const name: string) -> unsafe *Type {
        var unsafe *c = canon_unqual(head)
        if c == &null || (!isa<GenericParamType>(c)) && !isa<AssocType>(c) {
            return &null
        }

        var args = cxx::std::vector<unsafe *Type>()
        if !self._step_type_args(st, &args) {
            return &null
        }

        return Substitution(self.dyn()->sc).assoc_named(c, name, unsafe &args)
    }

    /// `Box<i32>::count`: the record a `::` step names its member through
    /// (ChainExpr::Step::through), when that record is a generic one's
    /// instance or a nested type of one (`L<i32>::P::k`), else null. The
    /// member's decl is the pattern's, and the arguments are on \p cur_type
    /// and nowhere else once this chain is typed. The value-chain twin of
    /// CallTyping::_instance_qualifier.
    priv fn _instance_through(self,
                              st:       unsafe *ChainExpr::Step,
                              cur_kind: ChainKind,
                              cur_type: unsafe *Type) -> unsafe *Type {
        if cur_kind != ChainKind::Type
            || cur_type == &null
            || st->access_kind != ChainExpr::AccessKind::ColonColon {
            return &null
        }

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(cur_type))
        if r == &null || r->args.size() == 0 && r->outer == &null {
            return &null
        }

        return r
    }

    fn type_chain(self, n: unsafe *ChainExpr, expected: unsafe *Type) -> unsafe *Type {
        var info = self.dyn()->new_chain_info(n)

        /// ## base
        var cur:          unsafe *Type            = &null // value type of the current position
        var cur_kind:     ChainKind               = ChainKind::Value
        var cur_type:     unsafe *Type            = &null // the type named, while cur_kind is Type
        var saw_optional                          = false
        var last_variant: unsafe *EnumVariantDecl = &null // the chain ends naming this variant

        if n->base == &null {
            cur_kind = ChainKind::Module
        } else if self._is_cxx_head(n->base) {
            // `cxx` as a chain HEAD is the overlay's scope, which is what it
            // is for; _type_ident's R053E is for `cxx` standing alone, and
            // typing the head through it rejected `cxx::std::vector<i32>()`.
            self.dyn()->note_module_expr(n->base)
            cur_kind = ChainKind::Module
        } else {
            var bt = self.dyn()->type_of(n->base, &null)
            if n->base->is_poisoned() {
                self.dyn()->poison_only(n)
                return &null
            }

            // `p->f` goes where p points: the pointer is no escape (Compiler/Spec/Nullables.md#aliases-and-closures).
            if n->steps.size() > 0
                && (n->steps.get(0)->access_kind == ChainExpr::AccessKind::Arrow
                    || n->steps.get(0)->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                self.dyn()->flow.consumed(n->base)
            }

            var denoted = self.dyn()->denoted_type(n->base)
            if denoted != &null {
                cur_kind = ChainKind::Type
                cur_type = denoted
            } else if self.dyn()->denotes_module(n->base) {
                cur_kind = ChainKind::Module
            } else if bt == &null {
                cur_kind = ChainKind::Unknown
            } else {
                cur_kind = ChainKind::Value
                cur      = bt
            }
        }

        // The object's category, carried along the value steps (ChainInfo::
        // receiver_cat). The base's own when it is a value; Unknown is a
        // name whose arm decided nothing, which is an lvalue's place.
        var obj_cat = Expr::ValueCategory::LValue
        if n->base != &null && n->base->value_category != Expr::ValueCategory::Unknown {
            obj_cat = n->base->value_category
        }

        /// ## steps
        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st == &null {
                break
            }

            var is_last = i + 1 == n->steps.size()
            var ak      = st->access_kind
            if ak == ChainExpr::AccessKind::Arrow || ak == ChainExpr::AccessKind::QuestionArrow {
                obj_cat = Expr::ValueCategory::LValue
            } else if i > 0 && obj_cat == Expr::ValueCategory::RValue {
                obj_cat = Expr::ValueCategory::XValue // a member of a temporary.
            }

            if cur_kind == ChainKind::Unknown {
                info->unknown = true
                self.dyn()->mark_unknown(n)
                return &null
            }

            if cur_kind == ChainKind::Callable {
                self.dyn()->fail(
                    n,
                    DiagID::SC100E,
                    "cannot access a member of a function; call it first",
                )

                return &null
            }

            // `.` / `->` on a nullable reads its value (Compiler/Spec/Nullables.md#narrowed-reads): the
            // base, or the field path so far, narrowed when its place is
            // proven non-null here, else the nullness error. ChainBinding
            // left the step unbound for this (its anchor was nullable), so
            // it binds below on the narrowed type. A nullable that is no
            // place (`f().v`) keeps the old answer, "no member in 'T?'".
            if cur_kind == ChainKind::Value
                && cur != &null
                && (st->access_kind == ChainExpr::AccessKind::Dot
                    || st->access_kind == ChainExpr::AccessKind::Arrow)
                && self.dyn()->tu.nullable_inner(self.dyn()->ml.peel_ref(cur)) != &null
                && !self.dyn()->cb.nullable_member_step(n, st, cur) { // `extend T?`'s own member reads no value (P325-1).
                var o = self.dyn()->flow.read_prefix(n, i)
                if o == NULL_READ_REFUSED {
                    self.dyn()->poison_only(n)
                    return &null
                }

                if o == NULL_READ_NONE && self.dyn()->flow.refuse_unplaced(n, i) {
                    return &null
                }

                if o == NULL_READ_NARROWED {
                    cur = if (i == 0) => (n->base->type_) else => n->steps.get(i - 1)->resolved_type
                }
            }

            // NeedsInference: bind now with the anchor T could not see.
            if st->resolved_decl == &null
                && st->candidate_cell == &null
                && (st->name == &null || !st->name->is_poisoned())
                && !st->is_tuple_index() {
                // A value of an associated type (`x.show()`, `x: T::Item`)
                // binds through the associated type's own bounds: the
                // anchor is Dependent on it, and ChainBinding reads them.
                if cur_kind == ChainKind::Value && cur != &null {
                    var a = self.dyn()->cb.anchor_for_value(&null, cur)
                    self.dyn()->cb.bind_step(n, st, a)
                } else if cur_kind == ChainKind::Type {
                    // `X::Node` on a dependent head -- a bounded parameter or
                    // an associated type, at any depth (`T::Item::Inner`) --
                    // naming an associated type of its bounds is that type
                    // (as in type position), not unknown.
                    var unsafe *head0 = canon_unqual(cur_type)
                    var dep_head = head0 != &null
                        && (isa<GenericParamType>(head0) || isa<AssocType>(head0))
                    if dep_head
                        && st->access_kind == ChainExpr::AccessKind::ColonColon
                        && st->name != &null {
                        var at = self._assoc_step(
                            head0,
                            st,
                            self.dyn()->sc->ctx->get_spelling(st->name->name),
                        )

                        if at != &null {
                            cur_type          = at
                            st->resolved_type = at
                            // The requirement, as ChainBinding binds `T::Node`:
                            // `T::Item::Made()` is then the associated type's
                            // construction for codegen, as `T::Made()` is.
                            st->resolved_decl = cast<AssocType>(at)->assoc
                            if is_last {
                                info->receiver     = at
                                info->has_receiver = false
                            }

                            continue
                        }
                    }

                    // A step ChainBinding left unbound on a type PARAMETER is
                    // dependent by its decision (`: type`, or no bound
                    // answered): M2's, not a lookup to retry on T here.
                    if head0 != &null && isa<GenericParamType>(head0) {
                        info->unknown = true
                        self.dyn()->mark_unknown(n)
                        return &null
                    }

                    // A C++ class template over a Kairo parameter
                    // (`cxx::std::is_trivially_destructible<T>::value`): a
                    // dependent qualified name, which C++ looks up per
                    // instantiation. Its members can come from a base over
                    // a builtin of the arguments (every libc++ trait derives
                    // integral_constant<bool, __is_xxx(T)>) or from a partial
                    // specialization, neither of which the pattern shows, so
                    // a name the pattern lacks is decided per instance (the
                    // concrete `<i32>` binds now), not R025E here.
                    if head0 != &null
                        && isa<RecordType>(head0)
                        && head0->is_dependent()
                        && decl_is_imported(cast<RecordType>(head0)->decl)
                        && st->access_kind == ChainExpr::AccessKind::ColonColon
                        && st->name != &null {
                        var imm0  = self.dyn()->sc->ctx->get_ident_imm(st->name->name)
                        var probe = cxx::std::vector<*Decl>()
                        if imm0 != u32::MAX {
                            self.dyn()->ml.lookup(head0, DeclName::ident(imm0), &probe)
                        }

                        if probe.empty() {
                            info->unknown = true
                            self.dyn()->mark_unknown(n)
                            return &null
                        }
                    }

                    // An associated type's statics (`T::Item::make()`) bind
                    // through its own bounds, as a value's members do.
                    var a = self.dyn()->cb.anchor_for_type(cur_type)
                    self.dyn()->cb.bind_step(n, st, a)
                }
            }

            if st->name != &null && st->name->is_poisoned() {
                self.dyn()->poison_only(n)
                return &null
            }

            // separators on a value: `?.`/`?->` peel the nullable, `->` the pointer.
            // A C++ reference is transparent to every separator, so it goes
            // first -- the same helper ChainBinding binds with.
            var unsafe *val = cur
            // The receiver OBJECT's cv, read before peel_ref strips it:
            // `s.data()` on a const `s` must rank `data() const` alone.
            var recv_q: u8 = 0
            if cur_kind == ChainKind::Value {
                recv_q = self._object_quals(val)
                val    = self.dyn()->ml.peel_ref(val)
                if st->access_kind == ChainExpr::AccessKind::QuestionDot
                    || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                    var inner = self.dyn()->tu.nullable_inner(val)
                    if inner != &null {
                        val          = inner
                        saw_optional = true
                    } else if val != &null
                        && !val->is_dependent()
                        && !val->is_instantiation_dependent() {
                        // `?.` guards a null that cannot happen: the value is
                        // read as it is (Compiler/Spec/Nullables.md#safe-access), so say which
                        // separator was meant rather than make it `M?`.
                        self._not_nullable_step(n, i, val)
                        return &null
                    }
                }

                if st->access_kind == ChainExpr::AccessKind::Arrow
                    || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                    var p = self.dyn()->tu.pointee(val)
                    // A record with `op ->` reads the member through it, as
                    // ChainBinding bound it (Substitution::arrow_target).
                    if p == &null {
                        p = Substitution(self.dyn()->sc).arrow_target(val, &self.dyn()->ml)
                    }

                    if p != &null {
                        val    = p
                        recv_q = self._object_quals(p)
                    }
                }

                // The pointee of a `*const T` is `const T`; peel_ref now
                // peels quals too.
                val = self.dyn()->ml.peel_ref(val)
            }

            if is_last {
                // Qualified with the object's cv: OverloadResolution ranks
                // the receiver on it and strips it for everything else. A
                // `::` call off a type has that type as its receiver, so a
                // static on `Vec<i64>::` seeds the extension's parameters.
                var unsafe *recv_ty = if (cur_kind == ChainKind::Type) => (cur_type) else => val
                info->receiver = if (recv_ty != &null) => (self.dyn()->sc->types->qualified(
                                     recv_ty,
                                     recv_q,
                                 ))
                                 else => &null
                info->has_receiver = cur_kind == ChainKind::Value
                    && st->access_kind != ChainExpr::AccessKind::ColonColon
                info->receiver_cat = obj_cat
            }

            /// ### tuple index
            if st->is_tuple_index() {
                if cur_kind != ChainKind::Value || val == &null || !self.dyn()->tu.is_tuple(val) {
                    self.dyn()->fail(n, DiagID::SC101E, "tuple index on a non-tuple")
                    return &null
                }

                var elems = self.dyn()->tu.tuple_elems(val)
                if (st->index as usize) >= elems.size() {
                    self.dyn()->fail(
                        n,
                        DiagID::SC101E,
                        f"tuple index {st->index} is out of range for '{self.dyn()->tu.str(val)}'",
                    )

                    return &null
                }

                // The element is the record's argument at that position: the
                // pattern's field `_i` is typed `Ti`, which is args[i] in
                // this instance by construction. The step is bound to the
                // field so TupleLowering has a name to spell for it.
                cur               = elems[st->index as usize]
                st->resolved_type = cur
                st->resolved_decl = unsafe (self.dyn()->tu.tuple_field(val, st->index as usize) as unsafe *Decl)
                cur_kind          = ChainKind::Value
                n->value_category = Expr::ValueCategory::LValue // a field: `t.0 = x` assigns through.
                continue
            }

            /// ### operator step: `x.op+` / `Foo::op[]`
            if st->is_operator() {
                var owner_ty: unsafe *Type = if (cur_kind == ChainKind::Type) => (cur_type) else => val
                if owner_ty == &null {
                    info->unknown = true
                    self.dyn()->mark_unknown(n)
                    return &null
                }

                var k0 = TokenKind::TkUnknown
                var k1 = TokenKind::TkUnknown
                var k2 = TokenKind::TkUnknown
                if st->op_tokens.size() > 0 {
                    k0 = st->op_tokens[0].kind
                }

                if st->op_tokens.size() > 1 {
                    k1 = st->op_tokens[1].kind
                }

                // `op []=` is three tokens (DeclName::op_name_of).
                if st->op_tokens.size() > 2 {
                    k2 = st->op_tokens[2].kind
                }

                info->callable_cands.clear()
                self.dyn()->ml.lookup(
                    self.dyn()->tu.strip_nullable(owner_ty),
                    DeclName::op_name_of(k0, k1, k2),
                    &info->callable_cands,
                )

                if k0 == TokenKind::KwFinally {
                    // `x.finally()` is rejected at the parse (SC116E, planned
                    // for 0.3); stay silent here so one call is one error.
                    info->unknown = true
                    self.dyn()->mark_unknown(n)
                    return &null
                }

                if info->callable_cands.size() == 0 {
                    self.dyn()->fail(
                        n,
                        DiagID::SC102E,
                        f"no such operator on '{self.dyn()->tu.str(owner_ty)}'",
                    )

                    return &null
                }

                cur_kind = ChainKind::Callable
                continue
            }

            /// ### named step
            var unsafe *d = st->resolved_decl
            if d == &null && st->candidate_cell != &null {
                // `Box<T>::f` names the pattern's overloads; the instance
                // (or the dependent pattern) is what spells them.
                st->through = self._instance_through(st, cur_kind, cur_type)
                info->callable_cands.clear()
                for var j: usize = 0; j < st->candidate_cell->size(); ++j {
                    info->callable_cands.push_back(st->candidate_cell->get(j))
                }

                cur_kind = ChainKind::Callable
                continue
            }

            if d == &null {
                // ChainBinding recorded a reason: dependent / foreign / inference hole.
                info->unknown = true
                self.dyn()->mark_unknown(n)
                return &null
            }

            match d->kind {
                case DeclKind::FieldDecl {
                    var unsafe *f  = cast<FieldDecl>(d)
                    var unsafe *ft = if (f->type_ != &null) => (f->type_->canonical) else => &null
                    if ft == &null {
                        info->unknown = true
                        self.dyn()->mark_unknown(n)
                        return &null
                    }

                    // Reached through a `T derives Base` bound, `seen` is the
                    // PARAMETER, not a record: member_through then binds
                    // nothing and hands back the base's declared field type,
                    // which is the right answer. Do not "fix" this into
                    // resolving the base record -- the field is not seen
                    // through Base's generic args, it is seen through T's.
                    var unsafe *seen = if (cur_kind == ChainKind::Value) => (val) else => cur_type
                    cur               = self.dyn()->ded_scratch()->member_through(seen, ft)
                    st->through       = self._instance_through(st, cur_kind, cur_type)
                    cur_kind          = ChainKind::Value
                    st->resolved_type = cur
                    n->value_category = Expr::ValueCategory::LValue
                } case DeclKind::VariableDecl {
                    var unsafe *v = cast<VariableDecl>(d)
                    cur = self.dyn()->var_type(v)
                    if cur == &null {
                        info->unknown = true
                        self.dyn()->mark_unknown(n)
                        return &null
                    }

                    // A const binding is a const object; see ExprTyper::_type_ident.
                    if v->is_const() {
                        cur = self.dyn()->sc->types->qualified(cur, QUAL_CONST)
                    }

                    st->through       = self._instance_through(st, cur_kind, cur_type)
                    cur_kind          = ChainKind::Value
                    st->resolved_type = cur
                    n->value_category = Expr::ValueCategory::LValue
                } case DeclKind::ParamDecl {
                    // A pack reads as its Slice<E>; see ExprTyper::param_value_type.
                    cur = self.dyn()->param_value_type(cast<ParamDecl>(d))
                    if cur == &null {
                        info->unknown = true
                        self.dyn()->mark_unknown(n)
                        return &null
                    }

                    cur_kind          = ChainKind::Value
                    st->resolved_type = cur
                    n->value_category = Expr::ValueCategory::LValue
                } case DeclKind::EnumVariantDecl {
                    var unsafe *edc = d->semantic_dc
                    var unsafe *ed  = if (edc != &null) => (edc->owner_decl()) else => &null
                    if ed == &null {
                        self.dyn()->fail(n, DiagID::SC093E, "enum variant has no owning enum")
                        return &null
                    }

                    cur = self.dyn()->variant_value_type(ed)
                    // `Foo<i32>::V` keeps the instance -- only when the
                    // qualifier IS the variant's enum. A C++ unscoped
                    // enumerator named through its enclosing record
                    // (`LangStandard::lang_gnucxx26`, of `LangStandard::Kind`)
                    // is the enum's, not the record's.
                    if cur_kind == ChainKind::Type && self.dyn()->discr_enum == &null {
                        var qd = self.dyn()->tu.record_decl(cur_type)
                        if qd != &null
                            && NameLookup::representative(
                                self.dyn()->tu.pattern_of(qd),
                            ) == NameLookup::representative(self.dyn()->tu.pattern_of(ed)) {
                            cur = cur_type
                        }
                    }

                    cur_kind          = ChainKind::Value
                    st->resolved_type = cur
                    n->value_category = Expr::ValueCategory::RValue
                    if is_last {
                        last_variant = cast<EnumVariantDecl>(d)
                    }
                } case DeclKind::FunctionDecl {
                    // `H<A>::get` / `Self::get` as a value: without it the
                    // member is spelled `H::get`, the template with no
                    // arguments. A call has CallExpr::qualifier too.
                    st->through = self._instance_through(st, cur_kind, cur_type)
                    info->callable_cands.clear()
                    info->callable_cands.push_back(d)
                    cur_kind = ChainKind::Callable
                } case DeclKind::ModuleDecl {
                    cur_kind = ChainKind::Module
                } case DeclKind::GenericParamDecl {
                    info->unknown = true
                    self.dyn()->mark_unknown(n)
                    return &null
                } default {
                    // `T::Node` that ChainBinding bound through T's bound to
                    // the requirement itself: the associated type of T.
                    if isa<TypeAliasDecl>(d) && cast<TypeAliasDecl>(d)->is_associated {
                        var at: unsafe *Type = &null
                        if cur_kind == ChainKind::Type && cur_type != &null {
                            var unsafe *ct0 = canon_unqual(cur_type)
                            if isa<GenericParamType>(ct0) || isa<AssocType>(ct0) {
                                at = self._assoc_step(ct0, st, self.dyn()->tu.decl_name(d))
                            } else if self.dyn()->tu.record_decl(ct0) != &null
                                && isa<InterfaceDecl>(
                                    NameLookup::representative(
                                        self.dyn()->tu.pattern_of(self.dyn()->tu.record_decl(ct0)),
                                    ),
                                ) {
                                var ai    = self.dyn()->tu.assoc_iface(ct0, d)
                                var sargs = cxx::std::vector<unsafe *Type>()
                                if ai != &null && self._step_type_args(st, &sargs) {
                                    at = Substitution(self.dyn()->sc).assoc_type(ct0, ai, d, &sargs)
                                }
                            }
                        }

                        if at == &null {
                            info->unknown = true
                            self.dyn()->mark_unknown(n)
                            return &null
                        }

                        // A further step (`T::Item::make()`) binds on it as on
                        // any dependent head, below.
                        cur_type           = at
                        cur_kind           = ChainKind::Type
                        st->resolved_type  = at
                        info->receiver     = at
                        info->has_receiver = false
                        continue
                    }

                    if self.dyn()->tu.is_type_decl(d) {
                        var unsafe *outer_t = if (cur_kind == ChainKind::Type) => (cur_type) else => &null
                        cur_type = self.dyn()->type_from_type_decl(d, st->generic_args, n)
                        if cur_type == &null {
                            self.dyn()->poison_only(n)
                            return &null
                        }

                        // `L<i32>::P { .. }` / `L<i32>::Color::Red`: a member
                        // type named through an instance is that instance's
                        // (GH#91), as in type position (TypeResolve).
                        if outer_t != &null
                            && (cur_type->in_generic_owner() || cur_type->is_dependent())
                            && isa<RecordType>(canon_unqual(outer_t)) {
                            var sd = Deduction(self.dyn()->sc, &null)
                            sd.bind_from_record(canon_unqual(outer_t))
                            var unsafe *sub = sd.substitute(cur_type)
                            if sub != &null {
                                cur_type = sub
                            }
                        }

                        cur_kind          = ChainKind::Type
                        st->resolved_type = cur_type
                    } else {
                        self.dyn()->fail(
                            n,
                            DiagID::SC094E,
                            f"'{self.dyn()->tu.decl_name(d)}' is not a value",
                        )

                        return &null
                    }
                }
            }
        }

        /// ## result
        match cur_kind {
            case ChainKind::Value {
                if cur == &null {
                    return &null
                }

                // `Opt::None` as a value is a construction (ControlTyping).
                if last_variant != &null {
                    return self.dyn()->type_variant_value(n, last_variant, cur)
                }

                // `x?.m` is `if x? => x.m else null` (Compiler/Spec/Nullables.md#safe-access): an
                // rvalue `M?`, never `(M?)?`. CoalesceLowering expands it.
                if saw_optional {
                    n->value_category = Expr::ValueCategory::RValue
                    return self.dyn()->sc->types->nullable(self.dyn()->tu.strip_nullable(cur))
                }

                // A nullable field path is a use of its place, as a name is
                // (ExprTyper::_note_place_read).
                if null_flow_type_is_nullable(cur) {
                    var place = null_place_of(n)
                    if place.size() > 0 {
                        self.dyn()->flow.note_read(n, &place)
                    }
                }

                return cur
            } case ChainKind::Type {
                info->last_is_type = true
                self.dyn()->note_type_expr(n, cur_type)
                return &null
            } case ChainKind::Module {
                self.dyn()->note_module_expr(n)
                return &null
            } case ChainKind::Callable {
                // a unique non-method function named through a path is a value.
                if info->callable_cands.size() == 1 && !info->has_receiver {
                    var f = dyn_cast<FunctionDecl>(info->callable_cands[0])
                    if f != &null && !f->is_method() && f->generic_params.size() == 0 {
                        n->value_category = Expr::ValueCategory::RValue
                        return self.dyn()->fn_pointer_type(f)
                    }

                    // `ns::pick<i32>`: one instance, as the bare name.
                    if f != &null && !f->is_method() && n->steps.size() > 0 {
                        var gt = self.dyn()->generic_fn_value_type(
                            f,
                            &n->steps.get(n->steps.size() - 1)->generic_args,
                        )

                        if gt != &null {
                            n->value_category = Expr::ValueCategory::RValue
                            return gt
                        }
                    }
                }

                return &null // callable; CallTyping reads info.
            } case ChainKind::Unknown {
                info->unknown = true
                self.dyn()->mark_unknown(n)
                return &null
            }
        }
    }

    /// # subscript

    /// The cv of the object \p t denotes: through any C++ reference (a
    /// reference is its referee), not through a pointer.
    /// \p e is the bare identifier `cxx`, bound to this TU's std overlay.
    priv fn _is_cxx_head(self, e: unsafe *Expr) -> bool {
        if !isa<NamedIdentExpr>(e) {
            return false
        }

        var unsafe *id = cast<NamedIdentExpr>(e)
        if !id->is_bound() || !id->generic_args.is_empty() {
            return false
        }

        var tu = self.dyn()->sc->tu
        return tu != &null && tu->cxx_module != &null && id->resolved_decl == tu->cxx_module
    }

    priv fn _object_quals(self, t: unsafe *Type) -> u8 {
        var unsafe *c = t
        while c != &null {
            if isa<CXXLValueRefType>(c) {
                c = cast<CXXLValueRefType>(c)->referee
                continue
            }

            if isa<CXXRValueRefType>(c) {
                c = cast<CXXRValueRefType>(c)->referee
                continue
            }

            break
        }

        return canon_quals(c)
    }

    /// `b[i]` through the record's own `op []`: \p cands is what the
    /// lookup on \p recv (the receiver, or an array's slice view) found.
    priv fn _type_subscript_op(self,
                               n:           *SubscriptExpr,
                               bt:          *Type,
                               recv:        *Type,
                               obj:         *Type,
                               cands:       unsafe *cxx::std::vector<*Decl>,
                               const label: string = "op []") -> unsafe *Type {
        if cands->size() == 0 {
            self.dyn()->type_of(n->index, &null)
            self.dyn()->fail(
                n,
                DiagID::SC103E,
                f"'{self.dyn()->tu.str(bt)}' has no subscript operator",
            )

            return &null
        }

        var args = cxx::std::vector<ArgInfo>()
        args.push_back(self.dyn()->arg_info(n->index))
        var r = self.dyn()->ovl.resolve(cands, &args, true, n->range, label, obj)
        if r.outcome == OvlOutcome::Dependent {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if r.outcome != OvlOutcome::Selected {
            self.dyn()->poison_only(n)
            return &null
        }

        // Member-only resolution, so via_free is false here by
        // construction; assigned from r anyway so the two never drift.
        n->resolved_op = r.decl
        n->op_via_free = r.via_free
        r.ded.bind_from_record(recv)
        self.dyn()->finish_call_args(r.decl, &args, &r)
        // Already through the receiver's generic args: bind_from_record
        // seeded r.ded, and call_result_type substitutes a dependent
        // result through it.
        var rt = self.dyn()->call_result_type(r.decl, &r)
        // call_result_type registers a generic winner's instance, so
        // EmitIR spells its arguments rather than leaving them to
        // C++ deduction (resolve_user_op's order).
        n->op_instance = r.instance
        // A result still dependent ends unknown, as a call's does
        // (CallTyping): returned bare, the node finished in no terminal
        // state and ExprTyper ICE'd.
        if rt == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        // A C++ `operator[]` (std::unordered_map, ...) already returns
        // the place as `T&`, and one returning a real `T*` means the
        // pointer: its result is taken as declared. Decided by the
        // declaring TU, not by the result's shape, for that reason.
        var oc  = NameLookup::ctx_of(r.decl)
        var otu = if (oc != &null) => (oc->tu) else => &null
        if otu != &null && otu->is_foreign {
            n->value_category = Expr::ValueCategory::LValue
            return rt
        }

        // A Kairo place returns `*T` / `*const T` and the subscript IS
        // the T it points to, an lvalue, const if the pointer was. Any
        // other result is a value operator: the subscript is that
        // value, an rvalue, so `&b[0..1]` is the ordinary
        // address-of-rvalue error.
        var fd = cast<FunctionDecl>(r.decl)
        if OperatorFacts::is_place(fd) {
            n->value_category = Expr::ValueCategory::LValue
            var place = self.dyn()->tu.pointee(rt)
            if place == &null {
                kairo::std::ice_fail(
                    "MemberTyping: place `op []` without a pointee; OperatorFacts::is_place disagrees",
                )
            }

            return place
        }

        n->value_category = Expr::ValueCategory::RValue
        return rt
    }

    /// The receiver a subscript's `op []` is chosen against: \p recv (the
    /// container, unqualified) carrying the object's const \p obj_q, so a
    /// const container offers only its `const self` overload (P921; the
    /// unqualified receiver let the `self` overload win in Sema and clang
    /// pick again from the real object, CL001E on every write). Today the
    /// object's constness is the whole decision; whatever else chooses the
    /// form of a subscript belongs here too.
    priv fn _subscript_receiver(self, recv: unsafe *Type, obj_q: u8) -> unsafe *Type {
        return self._with_object_const(recv, obj_q)
    }

    /// \p t, const when the object's quals \p obj_q are: an element of a
    /// const container, or the receiver that container is.
    priv fn _with_object_const(self, t: unsafe *Type, obj_q: u8) -> unsafe *Type {
        if t == &null || (obj_q & QUAL_CONST) == 0 {
            return t
        }

        return self.dyn()->sc->types->qualified(t, QUAL_CONST)
    }

    /// # the split subscript (P880)

    /// \p e is used as \p ctx (a SUB_* value): marks every subscript it
    /// reaches before it is typed, so a split subscript selects its form
    /// once, when it is typed. Through parens, `.field` / `.0` steps and a
    /// subscript's container: writing `x[i].a` or `x[i][j]` writes `x[i]`
    /// (the container of a place is a place), and a softer use only
    /// prefers the place form there. Not through `->`, `*p` or a call: what
    /// they reach is not the container's own storage. `.` never reads
    /// through a pointer (R027E), so a `.field` path stays in the element.
    fn mark_subscript_use(self, e: unsafe *Expr, ctx: u8) {
        var unsafe *cur = e
        var        c    = ctx
        for var guard: usize = 0; cur != &null && guard < 256; ++guard {
            cur = self.dyn()->tu.strip_parens(cur)
            if cur == &null {
                return
            }

            var unsafe *s = dyn_cast<SubscriptExpr>(cur)
            if s != &null {
                if s->place_ctx == SUB_READ || c == SUB_WRITE {
                    s->place_ctx = c
                }

                if c != SUB_WRITE && c != SUB_RECV {
                    c = SUB_SOFT
                }

                cur = s->base
                continue
            }

            var unsafe *ch = dyn_cast<ChainExpr>(cur)
            if ch != &null && ch->base != &null && self.member_path(ch, ch->steps.size()) {
                cur = ch->base
                continue
            }

            return
        }
    }

    /// Steps [0, \p upto) of \p ch are `.field` / `.0` steps: the object
    /// they reach is a member of the chain's base.
    fn member_path(self, ch: unsafe *ChainExpr, upto: usize) -> bool {
        if upto > ch->steps.size() {
            return false
        }

        for var i: usize = 0; i < upto; ++i {
            var unsafe *st = ch->steps.get(i)
            if st == &null
                || st->access_kind != ChainExpr::AccessKind::Dot
                || st->is_operator()
                || st->generic_args.size() > 0 {
                return false
            }
        }

        return true
    }

    /// `x[i]` on a split subscript: \p gets are its `op []` (read) forms,
    /// \p sets its `op []=` (place) forms, \p obj the receiver with the
    /// container's const. The form is the use's (SubscriptExpr::place_ctx),
    /// never a fallback from the other: a read never calls `op []=` and a
    /// write never calls `op []` (P880-1), so the type's const pair does
    /// not decide, and neither does the return type.
    priv fn _type_split_subscript(self,
                                  n:    *SubscriptExpr,
                                  bt:   *Type,
                                  recv: *Type,
                                  obj:  *Type,
                                  gets: unsafe *cxx::std::vector<*Decl>,
                                  sets: unsafe *cxx::std::vector<*Decl>) -> unsafe *Type {
        var ctx        = n->place_ctx
        var recv_const = canon_has_const(unsafe (obj as unsafe *Type))
        var place      = ctx == SUB_WRITE || (ctx != SUB_READ && !recv_const)
        if place && recv_const {
            self.dyn()->type_of(n->index, &null)
            self._const_split_write(n)
            return &null
        }

        if place {
            return self._type_subscript_op(n, bt, recv, obj, sets, "op []=")
        }

        if gets->size() == 0 {
            self.dyn()->type_of(n->index, &null)
            self._missing_read_form(n, bt, sets)
            return &null
        }

        return self._type_subscript_op(n, bt, recv, obj, gets, "op []")
    }

    /// `x[i]` as source text for a message, or a description when it is
    /// long or spans lines.
    priv fn _use_text(self, n: *SubscriptExpr) -> string {
        var t = self.dyn()->sc->ctx->get_spelling(n->range)
        if t.size() == 0 || t.size() > 40 {
            return "the subscript"
        }

        for var i: usize = 0; i < t.size(); ++i {
            if t[i] == ('\n' as u8) || t[i] == ('\r' as u8) {
                return "the subscript"
            }
        }

        return "\x27" + t + "\x27"
    }

    /// SC279E: a read of a split subscript whose type declares only the
    /// place form. No fallback (P880-1): `op []=` may do what a read must
    /// not (insert a key, mark its owner changed).
    priv fn _missing_read_form(self,
                               n:    *SubscriptExpr,
                               bt:   *Type,
                               sets: unsafe *cxx::std::vector<*Decl>) {
        if !n->is_poisoned() {
            var b = self.dyn()->sc->diag->report(
                DiagID::SC279E,
                n->range.start,
                f"'{self.dyn()->tu.str(bt)}' declares no read subscript 'op []'; {self._use_text(n)} here is a read",
            )

            b.first(n->range)
            if sets->size() > 0 && (*sets)[0] != &null {
                var d = (*sets)[0]
                b.note(DiagCode(DiagID::SC279N), d->range.start, "only the place form, 'op []=', is declared")->child_first(
                    d->range,
                )
            }

            b.emit()
        }

        self.dyn()->poison_only(n)
    }

    /// A write through a split subscript of a const container: `op []=`
    /// takes `self`, and the read form is no fallback for a write (P880-1).
    /// Named after the container when a const binding is what made it
    /// const, with the `var` fix-it on a local.
    priv fn _const_split_write(self, n: *SubscriptExpr) {
        if n->is_poisoned() {
            return
        }

        var unsafe *b0 = self.dyn()->tu.strip_parens(n->base)
        var d: unsafe *Decl = &null
        var unsafe *id = dyn_cast<NamedIdentExpr>(b0)
        if id != &null {
            d = id->resolved_decl
        }

        var unsafe *vd = if (d != &null) => (dyn_cast<VariableDecl>(d)) else => &null
        var unsafe *pd = if (d != &null) => (dyn_cast<ParamDecl>(d)) else => &null
        var nm = ""
        var at = SourceRange::invalid()
        if vd != &null && vd->is_const() {
            nm = self.dyn()->sc->ctx->get_spelling(vd->name)
            at = vd->name.range
        } else if pd != &null && pd->is_const {
            nm = self.dyn()->sc->ctx->get_spelling(pd->name)
            at = pd->name.range
        }

        var msg = f"cannot write through {self._use_text(n)}: its container is const, and 'op []=' takes 'self'"
        if nm.size() > 0 {
            msg = f"cannot write an element of '{nm}': '{nm}' is const, and 'op []=' takes 'self'"
        }

        var b = self.dyn()->sc->diag->report(DiagID::SC071E, n->range.start, msg)
        b.first(n->range)
        if at.is_valid() {
            b.note(at.start, f"'{nm}' declared const here")->child_first(at)
        }

        if vd != &null && nm.size() > 0 && vd->storage == StorageClass::Const && vd->storage_kw.is_valid() {
            b.fix(vd->storage_kw, "var", "declare it with \x27var\x27 to make it assignable")
        }

        b.emit()
        self.dyn()->poison_only(n)
    }

    /// The method call through `ce` resolved to \p w: a split subscript at
    /// the root of its receiver (`x[i].m()`, `x[i].f.m()`), typed with the
    /// place form while the method was unknown (SUB_RECV), keeps it only if
    /// \p w takes `self`; otherwise the use is a read, and moves to the read
    /// form (`.` reaches the element itself: it never reads through a
    /// pointer, and `->` is not marked a receiver at all). The
    /// two forms name one element (OperatorSignatureCheck::_agree), so only
    /// const changes, and nothing the call resolved against.
    fn settle_receiver_subscript(self, ce: unsafe *ChainExpr, w: unsafe *Decl) {
        if ce == &null || ce->base == &null || ce->steps.size() == 0 || w == &null {
            return
        }

        var upto = ce->steps.size() - 1
        if ce->steps.get(upto)->access_kind != ChainExpr::AccessKind::Dot || !self.member_path(ce, upto) {
            return
        }

        var unsafe *s = dyn_cast<SubscriptExpr>(self.dyn()->tu.strip_parens(ce->base))
        if s == &null || !self._holds_place_form(s) {
            return
        }

        self._settle(s, w)
    }

    /// `for e in x[i]`: as settle_receiver_subscript, for the iteration's
    /// `op in` \p w (RangedForStmt::iter_op). Null is an iteration with no
    /// user operator (an array, a slice): a read.
    fn settle_iterable_subscript(self, iterable: unsafe *Expr, w: unsafe *Decl) {
        var unsafe *s = dyn_cast<SubscriptExpr>(self.dyn()->tu.strip_parens(iterable))
        if s == &null || !self._holds_place_form(s) {
            return
        }

        if w == &null {
            self._demote(s)
            return
        }

        self._settle(s, w)
    }

    /// \p s keeps its place form only for a \p w that takes `self`.
    priv fn _settle(self, s: unsafe *SubscriptExpr, w: unsafe *Decl) {
        var unsafe *wf = dyn_cast<FunctionDecl>(w)
        var mutating = wf != &null
            && wf->is_method()
            && !wf->is_const()
            && wf->params.size() > 0
            && wf->params[0] != &null
            && !wf->params[0]->is_const
        if mutating {
            return
        }

        self._demote(s)
    }

    /// \p s was typed with the place form while it was only a receiver.
    priv fn _holds_place_form(self, s: unsafe *SubscriptExpr) -> bool {
        if s->place_ctx != SUB_RECV || s->resolved_op == &null || s->is_poisoned() {
            return false
        }

        var unsafe *f = dyn_cast<FunctionDecl>(s->resolved_op)
        return f != &null && OperatorFacts::is_subscript_set(f)
    }

    /// Moves \p s, typed with the place form, to the read form: its
    /// container first when that was a receiver's container too
    /// (`x[i][j].get()` reads `x[i]` as well). In place: the base and the
    /// index are typed already and stay so.
    priv fn _demote(self, s: unsafe *SubscriptExpr) {
        var unsafe *bs = dyn_cast<SubscriptExpr>(self.dyn()->tu.strip_parens(s->base))
        if bs != &null && self._holds_place_form(bs) {
            self._demote(bs)
        }

        s->place_ctx = SUB_READ
        var unsafe *bt = s->base->type_
        if bt == &null {
            return
        }

        if self.dyn()->tu.nullable_inner(bt) != &null {
            bt = self.dyn()->tu.nullable_inner(bt)
        }

        while true {
            var u = canon_unqual(bt)
            if isa<CXXLValueRefType>(u) {
                bt = cast<CXXLValueRefType>(u)->referee
                continue
            }

            if isa<CXXRValueRefType>(u) {
                bt = cast<CXXRValueRefType>(u)->referee
                continue
            }

            break
        }

        var obj_q = canon_quals(bt)
        bt = canon_unqual(bt)
        var unsafe *recv = self.dyn()->tu.strip_nullable(bt)
        var is_range = s->index != &null && isa<RangeExpr>(self.dyn()->tu.strip_parens(s->index))
        var array_range = is_range && self.dyn()->tu.element_of(bt) != &null
        if array_range {
            recv = self.dyn()->tu.array_view(s->base->type_)
        }

        if recv == &null {
            return
        }

        var gets  = cxx::std::vector<*Decl>()
        var sets  = cxx::std::vector<*Decl>()
        var bound = self.dyn()->bound_scopes(recv)
        if bound.size() > 0 {
            for var i: usize = 0; i < bound.size(); ++i {
                self.dyn()->ml.lookup(bound[i], DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare), &gets)
                self.dyn()->ml.lookup(bound[i], DeclName::subscript_set_name(), &sets)
            }
        } else {
            self.dyn()->ml.lookup(recv, DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare), &gets)
            self.dyn()->ml.lookup(recv, DeclName::subscript_set_name(), &sets)
        }

        if gets.size() == 0 {
            self._missing_read_form(unsafe (s as *SubscriptExpr), unsafe (bt as *Type), unsafe &sets)
            return
        }

        var obj = if (array_range) => (recv) else => self._subscript_receiver(recv, obj_q)
        var t   = self._type_subscript_op(s, bt, recv, obj, &gets, "op []")
        if t == &null {
            if !s->is_poisoned() {
                self.dyn()->poison_only(s)
            }

            return
        }

        s->type_ = t
    }

    fn type_subscript(self, n: unsafe *SubscriptExpr, expected: unsafe *Type) -> unsafe *Type {
        var bt = self.dyn()->type_of(n->base, &null)
        // An unknown base (`self.dyn()->xs[i]`, a field of a duck parameter)
        // still has an index to type: left alone, a call inside it
        // (`xs[xs.size() - 1]`) reaches codegen untyped and ICEs "unbound
        // callee" instead of being spelled per instance.
        if self.dyn()->propagate(n, n->base) {
            self.dyn()->type_of(n->index, &null)
            return &null
        }

        if bt == &null {
            self.dyn()->type_of(n->index, &null)
            return &null
        }

        // `xs[i]` on a nullable reads its value (Compiler/Spec/Nullables.md#narrowed-reads).
        if self.dyn()->tu.nullable_inner(bt) != &null {
            bt = self.dyn()->read_value(n->base)
            if bt == &null {
                self.dyn()->poison_only(n)
                self.dyn()->type_of(n->index, &null)
                return &null
            }
        }

        // A C++ reference is its referee. `m[2][1]` subscripts what the
        // inner `op []` returned, `array<i32, 2>&`, and member lookup has no
        // table for a reference type: unstripped, every chained subscript
        // into an imported container was SC103E "has no subscript operator".
        while true {
            var u = canon_unqual(bt)
            if isa<CXXLValueRefType>(u) {
                bt = cast<CXXLValueRefType>(u)->referee
                continue
            }

            if isa<CXXRValueRefType>(u) {
                bt = cast<CXXRValueRefType>(u)->referee
                continue
            }

            break
        }

        // Kept before the strip: an element of a const array, vector or map
        // is const, and a const container's `op []` is its `const self` one.
        var obj_q = canon_quals(bt)
        bt = canon_unqual(bt)

        var ri = dyn_cast<RangeExpr>(self.dyn()->tu.strip_parens(n->index))
        if ri != &null {
            ri->as_index = true
        }

        var is_range = n->index != &null && isa<RangeExpr>(self.dyn()->tu.strip_parens(n->index))
        var usize_t  = self.dyn()->tu.builtin(BuiltinKind::USize)

        // `a[i..j]` on an array is the slice's: the array is viewed as
        // `[T;]` (the conversion an argument would take) and Slice's range
        // `op []` does the rest. OperatorLowering wraps the base in the view.
        var recv        = self.dyn()->tu.strip_nullable(bt)
        var array_range = is_range && self.dyn()->tu.element_of(bt) != &null
        if array_range {
            var view = self.dyn()->tu.array_view(n->base->type_)
            if view == &null {
                self.dyn()->missing_lang_item(n, to_string(WellKnownType::Slice))
                return &null
            }

            recv = view
        }

        // user `op []`. A builtin container's own `op []` wins as any
        // record's does: the shapes below are only what a vector, map or
        // string that declares NO `op []` falls back to. One that declares
        // some, none of which takes the index, gets the ordinary overload
        // error rather than the shape: a declared set is the type's whole
        // subscript surface, and a silent fallback would hide the mistake.
        // An array, tuple or pointer has no members to ask.
        if self.dyn()->tu.kind_of(bt) == BuiltinKind::COUNT {
            var has_shape = self.dyn()->tu.is_vector_like(bt)
                || self.dyn()->tu.is_map_like(bt)
                || self.dyn()->tu.is_string(bt)
            var no_members = self.dyn()->tu.element_of(bt) != &null
                || self.dyn()->tu.is_tuple(bt)
                || self.dyn()->tu.pointee(bt) != &null
            if !no_members || array_range {
                var cands    = cxx::std::vector<*Decl>()
                var sets     = cxx::std::vector<*Decl>()
                var sub_name = DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare)
                var set_name = DeclName::subscript_set_name()
                // A bounded parameter has no members of its own: its `op []`
                // is a bound's requirement, as a binary operator's is
                // (OperatorTyping::_gather), which sends the call through the
                // interface's witness (Compiler/Spec/Witnesses.md#call-sites) -- or a `derives`
                // bound's base's own `op []`, an ordinary member. `op []=`
                // the same way.
                var bound = self.dyn()->bound_scopes(recv)
                if bound.size() > 0 {
                    for var i: usize = 0; i < bound.size(); ++i {
                        self.dyn()->ml.lookup(bound[i], sub_name, &cands)
                        self.dyn()->ml.lookup(bound[i], set_name, &sets)
                    }
                } else {
                    self.dyn()->ml.lookup(recv, sub_name, &cands)
                    self.dyn()->ml.lookup(recv, set_name, &sets)
                }

                // An array's slice view is a fresh value; the view's own
                // element type already carries the array's const.
                var obj = if (array_range) => (recv) else => self._subscript_receiver(recv, obj_q)
                if sets.size() > 0 {
                    return self._type_split_subscript(n, bt, recv, obj, &cands, &sets)
                }

                if cands.size() > 0 || !has_shape || array_range {
                    return self._type_subscript_op(n, bt, recv, obj, &cands)
                }
            }
        }

        // builtin shapes
        if self.dyn()->tu.is_tuple(bt) {
            self.dyn()->type_of(n->index, &null)
            self.dyn()->fail(n, DiagID::SC103E, "tuples are indexed with '.0', '.1', ..., not '[]'")
            return &null
        }

        var kt: unsafe *Type = &null
        var vt: unsafe *Type = &null
        if self.dyn()->tu.map_key_value(bt, &kt, &vt) {
            self.dyn()->type_of(n->index, kt)
            if !self.dyn()->check_convertible(n->index, kt) {
                self.dyn()->poison_only(n)
                return &null
            }

            n->value_category = Expr::ValueCategory::LValue
            return self._with_object_const(vt, obj_q)
        }

        var elem = self.dyn()->tu.container_elem(bt)
        // A pointer's const is the pointer's, not its pointee's: `p[i]`
        // through a `const p: *T` is a mutable `T`.
        var through_ptr = false
        if elem == &null && self.dyn()->tu.pointee(bt) != &null {
            elem        = self.dyn()->tu.pointee(bt)
            through_ptr = true
        }

        if elem == &null && self.dyn()->tu.is_string(bt) {
            elem = self.dyn()->tu.builtin(BuiltinKind::Char)
        }

        if elem == &null {
            self.dyn()->type_of(n->index, &null)
            self.dyn()->fail(n, DiagID::SC103E, f"'{self.dyn()->tu.str(bt)}' cannot be indexed")
            return &null
        }

        if is_range {
            self.dyn()->type_of(n->index, &null)
            // a slice of a container is the container type (the runtime views
            // it): a new value, not storage.
            n->value_category = Expr::ValueCategory::RValue
            return bt
        }

        var it = self.dyn()->type_of(n->index, usize_t)
        if self.dyn()->propagate(n, n->index) {
            return &null
        }

        if it != &null && !self.dyn()->tu.is_integer(it) {
            self.dyn()->fail(
                n->index,
                DiagID::SC103E,
                f"index must be an integer, not '{self.dyn()->tu.str(it)}'",
            )

            self.dyn()->poison_only(n)
            return &null
        }

        n->value_category = Expr::ValueCategory::LValue
        if through_ptr {
            return elem
        }

        return self._with_object_const(elem, obj_q)
    }
}
