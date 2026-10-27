/// --- The Kairo Project -------------- Sema/Check/OperatorSignatureCheck.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import AST::OperatorFacts::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

class OperatorSignatureCheck derives RecursiveASTVisitor::<OperatorSignatureCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    fn OperatorSignatureCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                default { 0; }
            }
        }
    }

    // === one declaration ====================================================

    fn visit_function_decl(self, f: *FunctionDecl) -> bool {
        if (f == &null) || f->is_poisoned() { return true; }
        // `@implicit` means one thing: this `op as` may be applied without
        // being written. On anything else it would be silently ignored.
        if OperatorFacts::has_implicit_attr(f) && (!OperatorFacts::is_implicit_conv(f)) {
            self._err_id(f, DiagID::SC115E, "'@implicit' applies only to a conversion operator: 'fn op as (self) -> T' in a type's body");
            return true;
        }
        if !f->is_operator { return true; }
        if decl_is_imported(static_cast::<*Decl>(f)) { return true; }   // C++'s own rules applied already.

        var sym   = OperatorFacts::symbol(f);
        var lex   = reinterpret_cast::<*DeclContext>(f->lexical_dc);
        var in_ext = (lex != &null) && (lex->dc_kind == DeclContextKind::Extension);
        var member = f->is_method() || in_ext;

        if (sym == "=") {
            self._err(f, "'=' is not overloadable; assignment is generated from the type's constructors");
            return true;
        }
        if (sym == "===") {
            self._err(f, "'===' is not overloadable; it is 'both present and equal' on nullable operands");
            return true;
        }
        if (sym == "&&") || (sym == "||") || (sym == "!") || (sym == "and") || (sym == "or") || (sym == "not")
        || (sym == ".") || (sym == "::") || (sym == "..") || (sym == "..=") {
            self._err(f, f"'{sym}' is not overloadable");
            return true;
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if (p->default_val != &null) || p->has_default {
                self._err(f, f"'op {sym}' takes no default arguments; an operator is called with exactly its operands");
                return true;
            }
            if p->is_pack {
                self._err(f, f"'op {sym}' takes no pack; an operator has a fixed number of operands");
                return true;
            }
        }

        // The receiver: a member has `self`, a free operator's first parameter
        // stands in for it.
        var nargs = OperatorFacts::arity(f);
        if !member {
            if f->params.size() == 0 {
                self._err(f, f"free 'op {sym}' has no operands; its first parameter is the left operand");
                return true;
            }
            nargs -= 1;
        }

        if in_ext && ((sym == "as") || (sym == "[]") || (sym == "->") || (sym == "delete")) {
            self._err(f, f"'op {sym}' cannot be declared in an extension; it must be a member, so declare it in the type's body");
            return true;
        }

        if ((sym == "++") || (sym == "--")) && (!OperatorFacts::has_fixity(f)) {
            self.sc->diag->report(DiagID::SC053W, f->range.start,
                f"'op {sym}' does not say which form it is; prefix is assumed -- write 'op l{sym}' (prefix) or 'op r{sym}' (postfix)"
            ).first(f->range).emit();
        }

        if !self._arity_ok(sym, nargs) {
            self._err(f, f"'op {sym}' takes {self._arity_text(sym)}, not {nargs}");
            return true;
        }

        self._check_result(f, sym, nargs);
        return true;
    }

    priv fn _arity_ok(self, sym: string, n: usize) -> bool {
        if (sym == "+") || (sym == "-") || (sym == "in") { return n <= 1; }
        if (sym == "~") || (sym == "compl") || (sym == "as") || (sym == "delete") || (sym == "->")
        || (sym == "await") || (sym == "spawn") || (sym == "thread") || (sym == "panic")
        || (sym == "++") || (sym == "--") { return n == 0; }
        return n == 1;
    }

    priv fn _arity_text(self, sym: string) -> string {
        if (sym == "+") || (sym == "-") { return "zero or one operand"; }
        if sym == "in" { return "one operand (containment) or none (iteration)"; }
        if self._arity_ok(sym, 0) { return "no operand besides the receiver"; }
        return "exactly one operand besides the receiver";
    }

    /// Result-type rules. A dependent or unresolved return type is left to
    /// the instantiation.
    priv fn _check_result(self, f: *FunctionDecl, sym: string, nargs: usize) {
        var rt: *Type = &null;
        if f->return_type != &null { rt = f->return_type->canonical; }
        if (f->return_type != &null) && ((rt == &null) || rt->is_dependent()) { return; }

        // `fn op panic (const self) -> string` (PANIC.md §1.5): the display
        // path reads the message from a const caught error and through a C++
        // `const&`, so the receiver is const; and the message is a string.
        if sym == "panic" {
            self._check_op_panic(f, rt);
            return;
        }
        if sym == "->" {
            var p = (self._tu.pointee(rt)) if (rt != &null) else (&null);
            if (p == &null) || self._tu.is_unsafe_ptr(rt) {
                self._err_id(f, DiagID::SC113E, "'op ->' must return a pointer: '*T' or '*const T\x27");
            }
            return;
        }
        // The return decides place vs value (OperatorFacts::is_place); only
        // the two results that are neither are errors here.
        if sym == "[]" {
            if rt == &null {
                self._err(f, f"'op {sym}' must return a value or a place ('*T' / '*const T')");
            } else if self._tu.is_unsafe_ptr(rt) {
                self._err_id(f, DiagID::SC114E,
                    f"'op {sym}' cannot return 'unsafe *T'; a place is '*T' or '*const T', and an unsafe pointer is neither a place nor a value");
            }
            return;
        }
        if OperatorFacts::is_compound(OperatorFacts::op_kind(f)) {
            if f->return_type != &null {
                self._err(f, f"'op {sym}' returns nothing; a compound assignment is a statement, and '+' is derived from it when the type declares no 'op +' of its own");
            }
            return;
        }
        var wants_bool = (sym == "==") || (sym == "!=") || (sym == "not_eq") || (sym == "<") || (sym == "<=")
                      || (sym == ">") || (sym == ">=") || ((sym == "in") && (nargs == 1));
        if wants_bool {
            if (rt == &null) || (canon_unqual(rt) != self.sc->builtin(BuiltinKind::Bool)) {
                self._err(f, f"'op {sym}' must return 'bool\x27");
            }
            return;
        }
        if sym == "<=>" {
            var ord = self.sc->well_known->get(WellKnownType::Ordering);
            var d   = (cast::<RecordType>(canon_unqual(rt))->decl) if ((rt != &null) && isa::<RecordType>(canon_unqual(rt))) else (&null);
            if (ord == &null) || (d == &null) || (NameLookup::representative(d) != NameLookup::representative(ord)) {
                self._err(f, "'op <=>' must return 'Ordering\x27");
            }
            return;
        }
    }

    /// `op panic`'s two rules, each with the edit that makes it hold. A free
    /// operator's first parameter is its receiver and is not a `self`, so
    /// only a member's (or an extension member's) `self` is judged.
    priv fn _check_op_panic(self, f: *FunctionDecl, rt: *Type) {
        var recv: *ParamDecl = &null;
        for var i: usize = 0; i < f->params.size(); ++i {
            if (f->params[i] != &null) && f->params[i]->is_self { recv = f->params[i]; break; }
        }
        if (recv != &null) && (!recv->is_const) {
            var b = self.sc->diag->report(DiagID::SC001E, recv->range.start,
                "'op panic' takes 'const self': the message is read from a const caught error");
            b.first(recv->range, "not const");
            b.note(DiagID::SC001N, f->range.start, "the operator is declared here").first(f->range);
            b.insert(recv->range.start, "const ", "make the receiver 'const self\x27");
            b.emit();
        }
        if (rt != &null) && self._tu.is_string(rt) { return; }
        var at = (f->return_type->range) if ((f->return_type != &null) && f->return_type->range.is_valid()) else (f->range);
        var rb = self.sc->diag->report(DiagID::SC001E, at.start, "'op panic' must return 'string', the error's message");
        rb.first(at);
        rb.note(DiagID::SC001N, f->range.start, "the operator is declared here").first(f->range);
        if (f->return_type != &null) && f->return_type->range.is_valid() {
            rb.fix(f->return_type->range, "string", "return 'string\x27");
        } else if f->params_end.is_valid() {
            rb.insert(f->params_end.end, " -> string", "return 'string\x27");
        }
        rb.emit();
    }

    // === one definition per pair ===========================================

    fn visit_class_decl(self, n: *ClassDecl) -> bool   { self._table(static_cast::<*DeclContext>(n), static_cast::<*Decl>(n)); return true; }
    fn visit_struct_decl(self, n: *StructDecl) -> bool { self._table(static_cast::<*DeclContext>(n), static_cast::<*Decl>(n)); return true; }
    fn visit_union_decl(self, n: *UnionDecl) -> bool   { self._table(static_cast::<*DeclContext>(n), static_cast::<*Decl>(n)); return true; }

    priv fn _table(self, dc: *DeclContext, at: *Decl) {
        self._pairs(dc, at);
        self._cmp_shadows(dc, dc);
    }

    /// An extension's table against itself and against the target's own body.
    fn visit_extension_decl(self, n: *ExtensionDecl) -> bool {
        var dc = static_cast::<*DeclContext>(n);
        self._table(dc, static_cast::<*Decl>(n));
        if (n->target != &null) && (n->target->canonical != &null) && isa::<RecordType>(canon_unqual(n->target->canonical)) {
            var td = cast::<RecordType>(canon_unqual(n->target->canonical))->decl;
            var tdc = NameLookup::context_of(decl_pattern(td));
            if tdc != &null {
                self._pairs_across(dc, tdc, static_cast::<*Decl>(n));
                // Either side may hold the `<=>`; each warning lands on the
                // comparison, wherever it is declared.
                self._cmp_shadows(dc, tdc);
                self._cmp_shadows(tdc, dc);
            }
        }
        return true;
    }

    priv fn _pairs(self, dc: *DeclContext, at: *Decl) { self._pairs_across(dc, dc, at); }

    /// For every compound operator declared in \p a, its base operator must
    /// not be declared in \p b.
    priv fn _pairs_across(self, a: *DeclContext, b: *DeclContext, at: *Decl) {
        if (a == &null) || (b == &null) || (a->dc_symbols == &null) || (b->dc_symbols == &null) { return; }
        var rows = vec::<SymbolTable::Entry>();
        a->dc_symbols->collect_entries(rows);
        for var i: usize = 0; i < rows.size(); ++i {
            var cell = rows[i].cell;
            if (cell == &null) || (cell->size() == 0) { continue; }
            var f = dyn_cast::<FunctionDecl>(cell->get(0));
            if (f == &null) || (!f->is_operator) { continue; }
            var k = OperatorFacts::op_kind(f);
            if !OperatorFacts::is_compound(k) { continue; }
            var base = b->lookup_symbol(DeclName::op_name(OperatorFacts::compound_base(k), TokenKind::TkUnknown));
            if (base == &null) || (base->size() == 0) { continue; }
            var g = base->get(0);
            var sym = OperatorFacts::symbol(f);
            var bsym = OperatorFacts::symbol(cast::<FunctionDecl>(g));
            self.sc->diag->report(DiagID::SC054E, f->range.start,
                f"'op {sym}' and 'op {bsym}' are both declared; a type declares one of the pair and the other is derived from it"
            ).first(f->range)
             .note(g->range.start, f"'op {bsym}' is declared here").first(g->range)
             .emit();
            f->poison();
        }
    }

    // === comparisons beside `op <=>` ========================================

    /// The comparisons OperatorTyping derives from `op <=>`.
    priv fn _derived_from_cmp(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpLess) || (k == TokenKind::OpLessEqual)
            || (k == TokenKind::OpGreater) || (k == TokenKind::OpGreaterEqual)
            || (k == TokenKind::OpEqualEqual) || (k == TokenKind::OpExclaimEqual)
            || (k == TokenKind::KwNotEq);
    }

    /// A comparison declared in \p a beside an `op <=>` in \p b. Legal --
    /// an `op ==` cheaper than a three-way compare is a real reason to write
    /// one -- but the declared operator wins every use (OperatorTyping looks
    /// it up first), so the one derived from `<=>` is never reached, and a C++
    /// host gets the declared one too (InterfaceEmitter skips it). If the two
    /// disagree, `a < b` and `a <=> b` silently answer differently: warn, do
    /// not poison.
    priv fn _cmp_shadows(self, a: *DeclContext, b: *DeclContext) {
        if (a == &null) || (b == &null) || (a->dc_symbols == &null) { return; }
        var cmp = b->lookup_symbol(DeclName::op_name(TokenKind::OpLessEqualGreater, TokenKind::TkUnknown));
        if (cmp == &null) || (cmp->size() == 0) { return; }
        var g = cmp->get(0);
        if (g == &null) || decl_is_imported(g) { return; }
        var rows = vec::<SymbolTable::Entry>();
        a->dc_symbols->collect_entries(rows);
        for var i: usize = 0; i < rows.size(); ++i {
            var cell = rows[i].cell;
            if (cell == &null) || (cell->size() == 0) { continue; }
            var f = dyn_cast::<FunctionDecl>(cell->get(0));
            if (f == &null) || (!f->is_operator) || f->is_poisoned() { continue; }
            if !self._derived_from_cmp(OperatorFacts::op_kind(f)) { continue; }
            var sym = OperatorFacts::symbol(f);
            self.sc->diag->report(DiagID::SC001W, f->range.start,
                f"'op {sym}' shadows the '{sym}' derived from 'op <=>'; every '{sym}' calls this declaration instead"
            ).first(f->range)
             .note(g->range.start, "'op <=>' is declared here; it already derives '<', '<=', '>', '>=', '==' and '!=\x27").first(g->range)
             .emit();
        }
    }

    priv fn _err(self, f: *FunctionDecl, msg: string) { self._err_id(f, DiagID::SC055E, msg); }

    priv fn _err_id(self, f: *FunctionDecl, id: DiagID, msg: string) {
        self.sc->diag->report(id, f->range.start, msg).first(f->range).emit();
        f->poison();
    }
}