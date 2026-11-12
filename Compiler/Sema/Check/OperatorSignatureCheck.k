/// --- The Kairo Project ---------- Sema/Check/OperatorSignatureCheck.k --- ///
///
///   \brief The rules an operator DECLARATION obeys, checked once, here, so
///          no lowering ever meets a shape it cannot render.
///
///   \detail
///     - `=` is generated from the constructors and `===` is a builtin on
///       nullables: neither is overloadable.
///     - `&&`, `||`, `!`, unary `&` and `*`, `.`, `::`, `..`: not overloadable.
///     - An operator takes no defaults and no pack: OperatorLowering mints
///       positional calls, and CallLowering never sees them.
///     - Arity follows the table in the Operators reference: `+`/`-` unary
///       or binary, `in` containment (one) or iteration (none), `as`,
///       `delete`, `await`, `spawn`, `thread`, `panic`, `~` unary, `->` unary,
///       everything else binary.
///       A free operator's first parameter is the receiver.
///     - Results: comparisons and `in` containment return bool, `<=>` returns
///       Ordering, a compound assignment returns nothing (it is a statement).
///       `[]` returning a safe `*T` / `*const T` is a place
///       (C++ gets `T&`); any other result makes it a value operator, so a
///       pointer returned BY VALUE from one is not expressible. `unsafe *T`
///       is neither and is rejected. `->` returns a safe pointer, always.
///     - One definition per pair: a type declares `op +` OR `op +=`; the
///       other is derived (OperatorTyping). Both in one type is an error.
///     - Extension operators are free functions taking `Self*`, which C++
///       accepts for every operator that can be a non-member; `as`, `[]`,
///       `->`, `delete` must be members and are declared in
///       the type's body.
///     - `++`/`--` without `l`/`r`: prefix, with a warning.
///     - `@implicit` goes on a member `op as` and nowhere else; it opens the
///       conversion to Conversion::implicit's user rung.
///
///   Phase: CHECK, after T (canonical return types), before X.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::{
    DeclName,
    SymbolTable,
}
import AST::DeclFacts::{
    decl_bases,
    decl_is_imported,
    decl_pattern,
}
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    ExtensionDecl,
    FunctionDecl,
    ParamDecl,
    StructDecl,
    UnionDecl,
}
import AST::Node::Program::TopLevelKind
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

pub class OperatorSignatureCheck derives RecursiveASTVisitor<OperatorSignatureCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil

    fn OperatorSignatureCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } default {
                    0
                }
            }
        }
    }

    /// # one declaration

    fn visit_function_decl(self, f: unsafe *FunctionDecl) -> bool {
        if f == &null || f->is_poisoned() {
            return true
        }

        // `@implicit` means one thing: this `op as` may be applied without
        // being written. On anything else it would be silently ignored.
        if OperatorFacts::has_implicit_attr(f) && !OperatorFacts::is_implicit_conv(f) {
            self._err_id(
                f,
                DiagID::SC115E,
                LangAttrs::quoted(
                    LangAttrs::implicit_conversion(),
                ) + " applies only to a conversion operator: 'fn op as (self) -> T' in a type's body",
            )

            return true
        }

        if !f->is_operator {
            return true
        }

        if decl_is_imported(f) { // C++'s own rules applied already.
            return true
        }

        var sym = OperatorFacts::symbol(f)      // for the messages; identity is by kind.
        var k   = OperatorFacts::single_kind(f)
        var subs = OperatorFacts::is_subscript(f) || OperatorFacts::is_subscript_set(f)
        var unsafe *lex   = f->lexical_dc
        var        in_ext = lex != &null && lex->dc_kind == DeclContextKind::Extension
        var        member = f->is_method() || in_ext

        if k == TokenKind::OpEqual {
            self._err(
                f,
                "'=' is not overloadable; assignment is generated from the type's constructors",
            )

            return true
        }

        if k == TokenKind::OpEqualEqualEqual {
            self._err(
                f,
                "'===' is not overloadable; it is 'both present and equal' on nullable operands",
            )

            return true
        }

        if OperatorFacts::is_not_overloadable(k) {
            self._err(f, f"'{sym}' is not overloadable")
            return true
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->default_val != &null || p->has_default {
                self._err(
                    f,
                    f"'op {sym}' takes no default arguments; an operator is called with exactly its operands",
                )

                return true
            }

            if p->is_pack {
                self._err(
                    f,
                    f"'op {sym}' takes no pack; an operator has a fixed number of operands",
                )

                return true
            }
        }

        // The receiver: a member has `self`, a free operator's first parameter
        // stands in for it.
        var nargs = OperatorFacts::arity(f)
        if !member {
            if f->params.size() == 0 {
                self._err(
                    f,
                    f"free 'op {sym}' has no operands; its first parameter is the left operand",
                )

                return true
            }

            nargs -= 1
        }

        // `op []=` is member-only as `op []` is, and a free one would be a
        // place form no receiver owns.
        if OperatorFacts::is_subscript_set(f) && !member {
            self._err(
                f,
                f"'op {sym}' cannot be a free function; it must be a member, so declare it in the type's body",
            )

            return true
        }

        if in_ext
            && (k == TokenKind::KwAs
                || subs
                || k == TokenKind::OpArrow
                || k == TokenKind::KwFinally) {
            self._err(
                f,
                f"'op {sym}' cannot be declared in an extension; it must be a member, so declare it in the type's body",
            )

            return true
        }

        if (k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus)
            && !OperatorFacts::has_fixity(f) {
            self.sc->diag->report(
                DiagID::SC053W,
                f->range.start,
                f"'op {sym}' does not say which form it is; prefix is assumed -- write 'op l{sym}' (prefix) or 'op r{sym}' (postfix)",
            ).first(f->range)->emit()
        }

        if !self._arity_ok(k, nargs) {
            self._err(f, f"'op {sym}' takes {self._arity_text(k)}, not {nargs}")
            return true
        }

        if OperatorFacts::is_subscript_set(f) {
            self._check_subscript_set(f, sym)
            return true
        }

        self._check_result(f, sym, k, subs, nargs)
        if subs && !f->is_poisoned() && OperatorFacts::in_split_subscript(f) {
            self._check_split_read(f)
        }

        return true
    }

    /// # the split subscript
    ///
    /// A type that declares `op []=` splits its subscript: `op []` is the
    /// read form, `op []=` the place form, and MemberTyping picks one for
    /// each use by what the use does (Compiler/Spec/ExprTyping.md). Each
    /// form's own rules are here; the pair's (one element type) are
    /// _split_pairs'. A type with no `op []=` is not split, and its `op []`
    /// keeps the one-operator rules of _check_result.

    /// `op []=`: takes `self` and returns what a write goes through, a safe
    /// `*T` or a mutable view `[T;]`. A `const self` place form (a view a
    /// const binding can still write through) is not decided yet, so it is
    /// refused rather than given a meaning here.
    priv fn _check_subscript_set(self, f: unsafe *FunctionDecl, const sym: string) {
        var unsafe *recv = self._self_param(f)
        if recv != &null && recv->is_const {
            var b = self.sc->diag->report(
                DiagID::SC280E,
                recv->range.start,
                f"'op {sym}' takes 'self': it hands out the place a write goes through, and a 'const self' place form is not supported",
            )

            b.first(recv->range)
            if recv->name.range.is_valid()
                && recv->range.start.raw() < recv->name.range.start.raw() {
                b.remove(
                    SourceRange::from_bounds(
                        recv->range.start,
                        recv->name.range.start,
                    ),
                    "take 'self'",
                )
            }

            b.emit()
            f->poison()
            return
        }

        var want = f"'op {sym}' must return the place a write goes through, '*T', or a mutable view '[T;]'"
        if f->return_type == &null {
            self._err_id(f, DiagID::SC280E, want)
            return
        }

        var unsafe *rt = f->return_type->canonical
        if rt == &null { // unresolved: T diagnosed it.
            return
        }

        if self._tu.is_unsafe_ptr(rt) {
            self._err_id(
                f,
                DiagID::SC114E,
                f"'op {sym}' cannot return 'unsafe *T'; a place is '*T', and an unsafe pointer is not one",
            )

            return
        }

        var unsafe *p = self._tu.pointee(rt)
        if p != &null {
            if self._tu.has_const(p) {
                self._err_id(
                    f,
                    DiagID::SC280E,
                    f"'op {sym}' returns '*const T', which cannot be written through; return '*T' (the read form, 'op []', returns '*const T')",
                )
            }

            return
        }

        if self._tu.is_slice(rt) {
            var unsafe *e = self._tu.container_elem(rt)
            if e != &null && self._tu.has_const(e) {
                self._err_id(
                    f,
                    DiagID::SC280E,
                    f"'op {sym}' returns a read-only view, which cannot be written through; return '[T;]'",
                )
            }

            return
        }

        // A value, or a type parameter that is not known to be a pointer:
        // neither is a place. A value subscript is the read form's.
        self._err_id(
            f,
            DiagID::SC280E,
            want + "; a value cannot be written through (a value subscript is 'op []')",
        )
    }

    /// `op []` beside an `op []=`: the read form. A `*T` result would be a
    /// second place form, a write the selection never routes there.
    priv fn _check_split_read(self, f: unsafe *FunctionDecl) {
        if f->return_type == &null || f->return_type->canonical == &null {
            return
        }

        var unsafe *rt = f->return_type->canonical
        var unsafe *p  = self._tu.pointee(rt)
        if p == &null || self._tu.is_unsafe_ptr(rt) || self._tu.has_const(p) {
            return
        }

        var b = self.sc->diag->report(
            DiagID::SC280E,
            f->range.start,
            "'op []' is the read form in a type that declares 'op []=', so it returns '*const T', a value or a read-only view; '*T' would let a write go through the read form",
        )

        b.first(f->range)
        var unsafe *g = self._first_set_of(f)
        if g != &null {
            b.note(
                DiagCode(DiagID::SC280N),
                g->range.start,
                "'op []=' is declared here",
            )->child_first(g->range)
        }

        b.emit()
        f->poison()
    }

    /// The first `op []=` of \p f's own type, or null.
    priv fn _first_set_of(self, f: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            dc = f->lexical_dc
        }

        if dc == &null {
            return &null
        }

        var unsafe *cell = dc->lookup_symbol(DeclName::subscript_set_name())
        if cell == &null || cell->size() == 0 {
            return &null
        }

        return dyn_cast<FunctionDecl>(cell->get(0))
    }

    priv fn _self_param(self, f: unsafe *FunctionDecl) -> unsafe *ParamDecl {
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && f->params[i]->is_self {
                return f->params[i]
            }
        }

        return &null
    }

    /// The first operand's type of a subscript form (its index), unqualified.
    priv fn _index_of(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if p->type_ == &null {
                return &null
            }

            return canon_unqual(p->type_->canonical)
        }

        return &null
    }

    /// The element a subscript form hands out, const dropped: the pointee
    /// of `*T` / `*const T`, a view's element, or the value itself.
    priv fn _element_of(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        if f->return_type == &null || f->return_type->canonical == &null {
            return &null
        }

        var unsafe *rt = f->return_type->canonical
        var unsafe *p  = self._tu.pointee(rt)
        if p != &null {
            return canon_unqual(p)
        }

        if self._tu.is_slice(rt) {
            return canon_unqual(self._tu.container_elem(rt))
        }

        return canon_unqual(rt)
    }

    /// The pair's rules: for one index type, `op []` and `op []=` name one
    /// element (MemberTyping may move a use from the read form to the place
    /// form once its consumer is known, which must change nothing but
    /// const), and a split type inherits no place-returning `op []`, which
    /// would be a place form beside its own.
    priv fn _split_pairs(self, dc: unsafe *DeclContext, at: *Decl) {
        if !OperatorFacts::declares_subscript_set(dc) {
            return
        }

        var unsafe *gets = dc->lookup_symbol(
            DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare),
        )

        var unsafe *sets = dc->lookup_symbol(DeclName::subscript_set_name())
        if gets != &null && sets != &null {
            for var i: usize = 0; i < gets->size(); ++i {
                var unsafe *g = dyn_cast<FunctionDecl>(gets->get(i))
                if g == &null || g->is_poisoned() || g->is_out_of_line() {
                    continue
                }

                for var j: usize = 0; j < sets->size(); ++j {
                    var unsafe *s = dyn_cast<FunctionDecl>(sets->get(j))
                    if s == &null || s->is_poisoned() || s->is_out_of_line() {
                        continue
                    }

                    self._agree(g, s)
                }
            }
        }

        var bases = decl_bases(unsafe (at as unsafe *Decl))
        for var i: usize = 0; i < bases.size(); ++i {
            var unsafe *e = bases.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *rec = dyn_cast<RecordType>(
                canon_unqual(e->base->canonical),
            )

            if rec == &null {
                continue
            }

            var unsafe *bdc = NameLookup::context_of(decl_pattern(rec->decl))
            if bdc == &null || OperatorFacts::declares_subscript_set(bdc) {
                continue
            }

            var unsafe *bg = bdc->lookup_symbol(
                DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare),
            )

            if bg == &null {
                continue
            }

            for var k: usize = 0; k < bg->size(); ++k {
                var unsafe *g = dyn_cast<FunctionDecl>(bg->get(k))
                if g == &null || !OperatorFacts::is_place(g) {
                    continue
                }

                var unsafe *pp = self._tu.pointee(g->return_type->canonical)
                if pp == &null || self._tu.has_const(pp) {
                    continue
                }

                var bn = self._tu.decl_name(rec->decl)
                var b = self.sc->diag->report(
                    DiagID::SC280E,
                    at->range.start,
                    f"a type that declares 'op []=' cannot inherit a place-returning 'op []' ('*T') from '{bn}': that one would be a second place form",
                )

                b.first(at->range)
                b.note(
                    DiagCode(DiagID::SC280N),
                    g->range.start,
                    f"'{bn}::op []' is declared here",
                )->child_first(g->range)
                b.emit()
                return
            }
        }
    }

    /// \p g (`op []`) and \p s (`op []=`) taking one index type name one
    /// element, const aside.
    priv fn _agree(self, g: unsafe *FunctionDecl, s: unsafe *FunctionDecl) {
        var unsafe *gi = self._index_of(g)
        var unsafe *si = self._index_of(s)
        if gi == &null || si == &null || gi != si {
            return
        }

        var unsafe *ge = self._element_of(g)
        var unsafe *se = self._element_of(s)
        if ge == &null || se == &null || ge == se || ge->is_dependent() || se->is_dependent() {
            return
        }

        var b = self.sc->diag->report(
            DiagID::SC280E,
            s->range.start,
            f"'op []' and 'op []=' taking '{self._tu.str(gi)}' disagree on the element: '{self._tu.str(ge)}' and '{self._tu.str(se)}'; the two forms of one subscript hand out one element type",
        )

        b.first(s->range)
        b.note(
            DiagCode(DiagID::SC280N),
            g->range.start,
            "the read form is declared here",
        )->child_first(g->range)
        b.emit()
        s->poison()
    }

    /// \p k is OperatorFacts::single_kind: TkUnknown for `[]` / `()`.
    priv fn _arity_ok(self, k: TokenKind, n: usize) -> bool {
        if k == TokenKind::OpPlus || k == TokenKind::OpMinus || k == TokenKind::KwIn {
            return n <= 1
        }

        if OperatorFacts::is_unary_only(k) {
            return n == 0
        }

        return n == 1
    }

    priv fn _arity_text(self, k: TokenKind) -> string {
        if k == TokenKind::OpPlus || k == TokenKind::OpMinus {
            return "zero or one operand"
        }

        if k == TokenKind::KwIn {
            return "one operand (containment) or none (iteration)"
        }

        if self._arity_ok(k, 0) {
            return "no operand besides the receiver"
        }

        return "exactly one operand besides the receiver"
    }

    /// Result-type rules. A dependent or unresolved return type is left to
    /// the instantiation.
    priv fn _check_result(self,
                          f:         unsafe *FunctionDecl,
                          const sym: string,
                          k:         TokenKind,
                          subs:      bool,
                          nargs:     usize) {
        var rt: unsafe *Type = &null
        if f->return_type != &null {
            rt = f->return_type->canonical
        }

        // A dependent result is the instance's to check, except an unsafe
        // pointer: `-> unsafe *T` is one whatever T is, so a generic class's
        // `op []` / `op ->` returning it is the same error as a plain one's
        // (Compiler/Memory/ArenaList.k's `op []` is the case this catches).
        var unsafe_dep = rt != &null
            && rt->is_dependent()
            && (subs || k == TokenKind::OpArrow)
            && self._tu.is_unsafe_ptr(rt)
        if f->return_type != &null && (rt == &null || rt->is_dependent()) && !unsafe_dep {
            return
        }

        // `fn op panic (const self) -> string` (Compiler/Spec/Panic.md#error-types): the display
        // path reads the message from a const caught error and through a C++
        // `const&`, so the receiver is const; and the message is a string.
        if k == TokenKind::KwPanic {
            self._check_op_panic(f, rt)
            return
        }

        if k == TokenKind::OpArrow {
            var unsafe *p = if (rt != &null) => (self._tu.pointee(rt)) else => &null
            if p == &null || self._tu.is_unsafe_ptr(rt) {
                self._err_id(
                    f,
                    DiagID::SC113E,
                    "'op ->' must return a pointer: '*T' or '*const T'",
                )
            }

            return
        }

        // The return decides place vs value (OperatorFacts::is_place); only
        // the two results that are neither are errors here.
        if subs {
            if rt == &null {
                self._err(
                    f,
                    f"'op {sym}' must return a value or a place ('*T' / '*const T')",
                )
            } else if self._tu.is_unsafe_ptr(rt) {
                self._err_id(
                    f,
                    DiagID::SC114E,
                    f"'op {sym}' cannot return 'unsafe *T'; a place is '*T' or '*const T', and an unsafe pointer is neither a place nor a value",
                )
            }

            return
        }

        if OperatorFacts::is_compound(OperatorFacts::op_kind(f)) {
            if f->return_type != &null {
                self._err(
                    f,
                    f"'op {sym}' returns nothing; a compound assignment is a statement, and '+' is derived from it when the type declares no 'op +' of its own",
                )
            }

            return
        }

        var wants_bool = OperatorFacts::returns_bool(k) || k == TokenKind::KwIn && nargs == 1
        if wants_bool {
            if rt == &null || canon_unqual(rt) != self.sc->builtin(BuiltinKind::Bool) {
                self._err(f, f"'op {sym}' must return 'bool'")
            }

            return
        }

        if k == TokenKind::OpLessEqualGreater {
            var unsafe *ord = self.sc->well_known->get(WellKnownType::Ordering)
            var unsafe *d = if (rt != &null
                                && isa<RecordType>(canon_unqual(rt))) => (cast<RecordType>(
                                canon_unqual(rt),
                            )->decl)
                            else => &null
            if ord == &null
                || d == &null
                || NameLookup::representative(d) != NameLookup::representative(
                    ord,
                ) {
                self._err(f, "'op <=>' must return 'Ordering'")
            }

            return
        }
    }

    /// `op panic`'s two rules, each with the edit that makes it hold. A free
    /// operator's first parameter is its receiver and is not a `self`, so
    /// only a member's (or an extension member's) `self` is judged.
    priv fn _check_op_panic(self, f: unsafe *FunctionDecl, rt: unsafe *Type) {
        var recv: unsafe *ParamDecl = &null
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && f->params[i]->is_self {
                recv = f->params[i]
                break
            }
        }

        if recv != &null && !recv->is_const {
            var b = self.sc->diag->report(
                DiagID::SC201E,
                recv->range.start,
                "'op panic' takes 'const self': the message is read from a const caught error",
            )

            b.first(recv->range, "not const")
            b.note(
                DiagCode(DiagID::SC201N),
                f->range.start,
                "the operator is declared here",
            )->child_first(f->range)
            b.insert(
                recv->range.start,
                "const ",
                "make the receiver 'const self'",
            )

            b.emit()
        }

        if rt != &null && self._tu.is_string(rt) {
            return
        }

        var at = if (f->return_type != &null
                     && f->return_type->range.is_valid()) => (f->return_type->range)
                 else => f->range
        var rb = self.sc->diag->report(
            DiagID::SC201E,
            at.start,
            "'op panic' must return 'string', the error's message",
        )

        rb.first(at)
        rb.note(
            DiagCode(DiagID::SC201N),
            f->range.start,
            "the operator is declared here",
        )->child_first(f->range)

        if f->return_type != &null && f->return_type->range.is_valid() {
            rb.fix(f->return_type->range, "string", "return 'string'")
        } else if f->params_end.is_valid() {
            rb.insert(f->params_end.end, " -> string", "return 'string'")
        }

        rb.emit()
    }

    /// # one definition per pair

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        self._table(unsafe (n as unsafe *DeclContext), n)
        return true
    }

    fn visit_struct_decl(self, n: *StructDecl) -> bool {
        self._table(unsafe (n as unsafe *DeclContext), n)
        return true
    }

    fn visit_union_decl(self, n: *UnionDecl) -> bool {
        self._table(unsafe (n as unsafe *DeclContext), n)
        return true
    }

    priv fn _table(self, dc: unsafe *DeclContext, at: *Decl) {
        self._pairs(dc, at)
        self._cmp_shadows(dc, dc)
        if !isa<ExtensionDecl>(at) {
            self._split_pairs(dc, at)
        }
    }

    /// An extension's table against itself and against the target's own body.
    fn visit_extension_decl(self, n: *ExtensionDecl) -> bool {
        var unsafe *dc = unsafe (n as unsafe *DeclContext)
        self._table(dc, n)
        if n->target != &null
            && n->target->canonical != &null
            && isa<RecordType>(canon_unqual(n->target->canonical)) {
            var unsafe *td = cast<RecordType>(
                canon_unqual(n->target->canonical),
            )->decl
            var unsafe *tdc = NameLookup::context_of(decl_pattern(td))
            if tdc != &null {
                self._pairs_across(dc, tdc, n)
                // Either side may hold the `<=>`; each warning lands on the
                // comparison, wherever it is declared.
                self._cmp_shadows(dc, tdc)
                self._cmp_shadows(tdc, dc)
            }
        }

        return true
    }

    priv fn _pairs(self, dc: unsafe *DeclContext, at: *Decl) {
        self._pairs_across(dc, dc, at)
    }

    /// For every compound operator declared in \p a, its base operator must
    /// not be declared in \p b.
    priv fn _pairs_across(self, a: unsafe *DeclContext, b: unsafe *DeclContext, at: *Decl) {
        if a == &null || b == &null || a->dc_symbols == &null || b->dc_symbols == &null {
            return
        }

        var rows = cxx::std::vector<SymbolTable::Entry>()
        a->dc_symbols->collect_entries(&rows)
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *cell = rows[i].cell
            if cell == &null || cell->size() == 0 {
                continue
            }

            var unsafe *f = dyn_cast<FunctionDecl>(cell->get(0))
            if f == &null || !f->is_operator {
                continue
            }

            var k = OperatorFacts::op_kind(f)
            if !OperatorFacts::is_compound(k) {
                continue
            }

            var unsafe *base = b->lookup_symbol(
                DeclName::op_name(
                    OperatorFacts::compound_base(k),
                    TokenKind::TkUnknown,
                ),
            )

            if base == &null || base->size() == 0 {
                continue
            }

            var unsafe *g   = base->get(0)
            var        sym  = OperatorFacts::symbol(f)
            var        bsym = OperatorFacts::symbol(cast<FunctionDecl>(g))
            self.sc->diag->report(
                DiagID::SC054E,
                f->range.start,
                f"'op {sym}' and 'op {bsym}' are both declared; a type declares one of the pair and the other is derived from it",
            ).first(f->range)->note(
                g->range.start,
                f"'op {bsym}' is declared here",
            )->child_first(g->range)->emit()
            f->poison()
        }
    }

    /// # comparisons beside `op <=>`

    /// The comparisons OperatorTyping derives from `op <=>`.
    priv fn _derived_from_cmp(self, k: TokenKind) -> bool {
        return k == TokenKind::OpLess
            || k == TokenKind::OpLessEqual
            || k == TokenKind::OpGreater
            || k == TokenKind::OpGreaterEqual
            || k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::KwNotEq
    }

    /// A comparison declared in \p a beside an `op <=>` in \p b. Legal --
    /// an `op ==` cheaper than a three-way compare is a real reason to write
    /// one -- but the declared operator wins every use (OperatorTyping looks
    /// it up first), so the one derived from `<=>` is never reached, and a C++
    /// host gets the declared one too (InterfaceEmitter skips it). If the two
    /// disagree, `a < b` and `a <=> b` silently answer differently: warn, do
    /// not poison.
    priv fn _cmp_shadows(self, a: unsafe *DeclContext, b: unsafe *DeclContext) {
        if a == &null || b == &null || a->dc_symbols == &null {
            return
        }

        var unsafe *cmp = b->lookup_symbol(
            DeclName::op_name(
                TokenKind::OpLessEqualGreater,
                TokenKind::TkUnknown,
            ),
        )

        if cmp == &null || cmp->size() == 0 {
            return
        }

        var unsafe *g = cmp->get(0)
        if g == &null || decl_is_imported(g) {
            return
        }

        var rows = cxx::std::vector<SymbolTable::Entry>()
        a->dc_symbols->collect_entries(&rows)
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *cell = rows[i].cell
            if cell == &null || cell->size() == 0 {
                continue
            }

            var unsafe *f = dyn_cast<FunctionDecl>(cell->get(0))
            if f == &null || !f->is_operator || f->is_poisoned() {
                continue
            }

            if !self._derived_from_cmp(OperatorFacts::op_kind(f)) {
                continue
            }

            // Not in the builtin library: its files are type-checked in every
            // compile, so a warning there is every user's noise, and the one
            // pair it has is on purpose (string's `op ==` is the same test its
            // `op <=>` derives, declared so it can meet Hash's requirement).
            if self.sc->g != &null && self.sc->g->is_builtin_fid(self._tu.fid_of(f)) {
                continue
            }

            var sym = OperatorFacts::symbol(f)
            self.sc->diag->report(
                DiagID::SC202W,
                f->range.start,
                f"'op {sym}' shadows the '{sym}' derived from 'op <=>'; every '{sym}' calls this declaration instead",
            ).first(f->range)->note(
                g->range.start,
                "'op <=>' is declared here; it already derives '<', '<=', '>', '>=', '==' and '!='",
            )->child_first(g->range)->emit()
        }
    }

    priv fn _err(self, f: unsafe *FunctionDecl, const msg: string) {
        self._err_id(f, DiagID::SC055E, msg)
    }

    priv fn _err_id(self, f: unsafe *FunctionDecl, id: DiagID, const msg: string) {
        self.sc->diag->report(id, f->range.start, msg).first(f->range)->emit()
        f->poison()
    }
}
