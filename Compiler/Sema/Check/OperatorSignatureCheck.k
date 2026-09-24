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
///       `delete`, `await`, `~` unary, `->` unary, everything else binary.
///       A free operator's first parameter is the receiver.
///     - Results: comparisons and `in` containment return bool, `<=>` returns
///       Ordering, a compound assignment returns nothing (it is a statement).
///     - One definition per pair: a type declares `op +` OR `op +=`; the
///       other is derived (OperatorTyping). Both in one type is an error.
///     - Extension operators are free functions taking `Self*`, which C++
///       accepts for every operator that can be a non-member; `as`, `[]`,
///       `->`, `.*`, `->*`, `delete` must be members and are declared in
///       the type's body.
///     - `++`/`--` without `l`/`r`: prefix, with a warning.
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
        if (f == &null) || (!f->is_operator) || f->is_poisoned() { return true; }
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

        if in_ext && ((sym == "as") || (sym == "[]") || (sym == "->") || (sym == ".*") || (sym == "->*") || (sym == "delete")) {
            self._err(f, f"'op {sym}' cannot be declared in an extension; it must be a member, so declare it in the type's body");
            return true;
        }

        if ((sym == "++") || (sym == "--")) && (!OperatorFacts::has_fixity(f)) {
            self.sc->diag->report(DiagID::SC001W, f->range.start,
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
        if (sym == "~") || (sym == "compl") || (sym == "as") || (sym == "delete") || (sym == "await") || (sym == "->")
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

        if (sym == "[]") || (sym == ".*") || (sym == "->*") || (sym == "->") {
            var p = (self._tu.pointee(rt)) if (rt != &null) else (&null);
            if (p == &null) || self._tu.is_unsafe_ptr(rt) {
                self._err(f, f"'op {sym}' must return a place into 'self': '*T' or '*const T\x27");
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

    // === one definition per pair ===========================================

    fn visit_class_decl(self, n: *ClassDecl) -> bool   { self._pairs(static_cast::<*DeclContext>(n), static_cast::<*Decl>(n)); return true; }
    fn visit_struct_decl(self, n: *StructDecl) -> bool { self._pairs(static_cast::<*DeclContext>(n), static_cast::<*Decl>(n)); return true; }
    fn visit_union_decl(self, n: *UnionDecl) -> bool   { self._pairs(static_cast::<*DeclContext>(n), static_cast::<*Decl>(n)); return true; }

    /// An extension's table against itself and against the target's own body.
    fn visit_extension_decl(self, n: *ExtensionDecl) -> bool {
        var dc = static_cast::<*DeclContext>(n);
        self._pairs(dc, static_cast::<*Decl>(n));
        if (n->target != &null) && (n->target->canonical != &null) && isa::<RecordType>(canon_unqual(n->target->canonical)) {
            var td = cast::<RecordType>(canon_unqual(n->target->canonical))->decl;
            var tdc = NameLookup::context_of(decl_pattern(td));
            if tdc != &null { self._pairs_across(dc, tdc, static_cast::<*Decl>(n)); }
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
            self.sc->diag->report(DiagID::SC001E, f->range.start,
                f"'op {sym}' and 'op {bsym}' are both declared; a type declares one of the pair and the other is derived from it"
            ).first(f->range)
             .note(g->range.start, f"'op {bsym}' is declared here").first(g->range)
             .emit();
            f->poison();
        }
    }

    priv fn _err(self, f: *FunctionDecl, msg: string) {
        self.sc->diag->report(DiagID::SC001E, f->range.start, msg).first(f->range).emit();
        f->poison();
    }
}