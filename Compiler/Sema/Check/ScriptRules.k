/// --- The Kairo Project ----------------------- Sema/Check/ScriptRules.k --- ///
///
///   \brief What makes a file a script, and which of its top-level bindings
///          are DEFERRED: the questions every pass that treats a script's
///          top level as main's body asks, answered once (SCRIPT.md 1-2).
///
///   \detail
///     A script is the program's ROOT file (SemaContext::script_root, the
///     driver's answer) with at least one top-level statement and no
///     `fn main`. A binding (`var` / `const` / `static` / `thread` / `eval`)
///     is not a statement: a file of declarations and bindings only is left
///     as it is.
///
///     A top-level binding is deferred -- its initializer runs at its line
///     in main, not as a C++ static initializer -- unless it is `eval`,
///     `thread`, has no initializer, or its initializer is a constant: an
///     integer, float, char, bool or `null` literal, a non-format string
///     literal, `sizeof` / `alignof`, or an integer ConstEval folds that fits
///     the declared type.
///
///     One predicate, several readers, so they cannot disagree about which
///     line is a line: ScriptLowering moves exactly these initializers into
///     main, JumpLabelCheck rejects a `jump!` that crosses one, and
///     ControlFlowAnalysis calls one after a top-level `return` dead code.
///     Deferring is always correct, only slower, so the constant list may
///     grow; it grows HERE, for all of them at once.
///
///   Phase: any pass after ExprTyper (the constant test reads X's types and
///   ConstEval). The structural questions (is_script, binding_of) need only
///   the parsed tree.
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
import Sema::Check::ConstEval::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::LangItems::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Memory::ArenaList::*;
import Location::SourceRange::*;

class ScriptRules {
    priv var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var ce: ConstEval;

    fn ScriptRules(self) { self.sc = &null; }
    fn ScriptRules(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
        self.ce = ConstEval(sc);
    }

    // --- structure ------------------------------------------------------------------

    /// The binding a top-level item declares, or null: a `var` / `const`
    /// statement, or a `static` / `thread` / `eval` declaration.
    fn binding_of(self, item: TopLevelItem) -> *VariableDecl {
        if item.kind == TopLevelKind::Decl { return dyn_cast::<VariableDecl>(item.as_decl()); }
        if item.kind != TopLevelKind::Stmt { return &null; }
        var ds = dyn_cast::<DeclStmt>(item.as_stmt());
        if ds == &null { return &null; }
        return dyn_cast::<VariableDecl>(ds->decl);
    }

    /// A top-level item that is code: neither a declaration nor a binding.
    fn is_statement(self, item: TopLevelItem) -> bool {
        if item.kind == TopLevelKind::Decl { return false; }
        return self.binding_of(item) == &null;
    }

    /// A free function named `main` at file scope (CXXSpell::is_main's test).
    fn is_main(self, d: *Decl) -> bool {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f == &null) || f->is_method() || f->is_operator { return false; }
        return self.tu.decl_name(d) == entry_point_name();
    }

    /// The file's `fn main`, or null.
    fn main_of(self) -> *Decl {
        var items = self._items();
        if items == &null { return &null; }
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            if (item.kind == TopLevelKind::Decl) && self.is_main(item.as_decl()) { return item.as_decl(); }
        }
        return &null;
    }

    /// The first top-level statement's range, invalid when there is none.
    fn first_statement(self) -> SourceRange {
        var items = self._items();
        if items == &null { return SourceRange::invalid(); }
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            if self.is_statement(item) { return item.get_range(); }
        }
        return SourceRange::invalid();
    }

    /// This TU is a script: the root, a statement, no `fn main`. A file
    /// that is not the root, or that has `fn main`, is not one even with
    /// statements (ScriptLowering reports those, and nothing else should
    /// treat their top level as main's body).
    fn is_script(self) -> bool {
        if (self.sc == &null) || (!self.sc->script_root) { return false; }
        if !self.first_statement().is_valid() { return false; }
        return self.main_of() == &null;
    }

    // --- deferral -------------------------------------------------------------------

    /// The binding's initializer runs at its line in main (file header):
    /// not `eval`, not `thread`, and not a constant.
    fn defers(self, v: *VariableDecl) -> bool {
        if v == &null { return false; }
        if v->is_poisoned() || v->is_eval() || v->is_thread { return false; }
        if (v->init == &null) || v->init->is_poisoned() { return false; }
        if (v->type_ == &null) || (v->type_->canonical == &null) { return false; }
        return !self.constant(v->init, v->type_->canonical);
    }

    /// An initializer with no observable effect and no read of anything a
    /// statement could change first: the static initializer C++ runs before
    /// main loses nothing by running early. FieldInitLowering::_fold's
    /// constants plus the other literals.
    fn constant(self, e: *Expr, t: *Type) -> bool {
        var x = self.tu.strip_parens(e);
        if x == &null { return false; }
        switch x->kind {
            case ExprKind::IntegerLiteralExpr   { return true; }
            case ExprKind::FloatingLiteralExpr  { return true; }
            case ExprKind::CharacterLiteralExpr { return true; }
            case ExprKind::BooleanLiteralExpr   { return true; }
            case ExprKind::NullLiteralExpr      { return true; }
            case ExprKind::SizeOfExpr           { return true; }
            case ExprKind::AlignOfExpr          { return true; }
            case ExprKind::TypeTraitExpr        { return true; }
            case ExprKind::StringLiteralExpr    { return !cast::<StringLiteralExpr>(x)->is_format(); }
            default { return self._constant_int(x, t); }
        }
        return false;
    }

    /// An integer ConstEval folds and that fits \p t (a `-1`, an `eval`
    /// name, `1 << 4`).
    priv fn _constant_int(self, x: *Expr, t: *Type) -> bool {
        if !self.tu.is_integer(t) { return false; }
        var c = self.ce.eval_int(x);
        return c.ok && (!c.overflow) && self.ce.fits(c, t);
    }

    priv fn _items(self) -> *ArenaList::<TopLevelItem> {
        if self.sc == &null { return &null; }
        var t = self.sc->tu;
        if (t == &null) || (t->program == &null) { return &null; }
        return &(t->program->items);
    }
}
