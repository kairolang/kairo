/// --- The Kairo Project ----------------------- Sema/Check/PackChecking.k --- ///
///
///   \brief Where a type pack, a pack parameter and a pack-expanded variant
///          may appear (PANIC.md §1.2, functions-parameters.mdx, enums-adt.mdx
///          "Variadic enums").
///
///   \detail
///     A type pack `...T` stands for several types, so it has no meaning on
///     its own: it is written expanded (`Box<T...>`), as the type of a pack
///     parameter (`...xs: T`), or in the payload of a pack-expanded variant
///     (`Err { e: E }...`), which is one variant per element. A pack
///     parameter `xs` likewise is several values: it is forwarded (`xs...`,
///     as a call argument) or iterated (`for x in xs`). Everything else is
///     an error here, before typing, so no later pass meets a pack in a
///     position it cannot render:
///
///       a field, variable, return or plain parameter typed by a bare pack
///       a pack named, unexpanded, inside a type argument list (`Box<T>`)
///       a pack parameter read as a value (`var y = xs`)
///       an expansion `e...` outside a call's argument list, or of anything
///         but a pack parameter's name
///
///     And on an enum, the pack-expanded variant's own rules:
///
///       `V...` with no payload               it has nothing to expand
///       a payload that names no type pack    nothing to expand either
///       two pack-expanded variants           one pack, one expansion
///       an expanded variant that is not last the variants after it would
///                                            move with the pack's size
///       a pack in a variant with no `...`    which element would it be?
///
///     An offending enum is poisoned, so no layout or pattern is built over
///     it; any other offender is poisoned where it stands.
///
///   SC001E is the placeholder until the monthly sweep gives these a code.
///
///   Phase: CHECK, before ExprTyper: it reads only resolved names and
///   types (N and T), and typing a pack where it means nothing would only
///   produce a second, worse error.
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
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

/// The first type node under a written type that names a type pack without
/// expanding it; an expansion's pattern is not looked into.
class BarePackFinder derives RecursiveASTVisitor::<BarePackFinder> {
    pub var found: *Type = &null;

    fn BarePackFinder(self) { }

    fn visit_type(self, n: *Type) -> bool {
        if (n == &null) || (self.found != &null) { return false; }
        if isa::<PackExpansionType>(n) || isa::<VariadicPackType>(n) { return false; }
        var c = canon_unqual(n->canonical);
        if (c != &null) && isa::<GenericParamType>(c) && cast::<GenericParamType>(c)->is_pack {
            self.found = n;
            self.stop  = true;
            return false;
        }
        return true;
    }
}

///
/// \class PackChecking
/// \brief The pass. Diagnoses and poisons; rewrites nothing.
///
class PackChecking derives RecursiveASTVisitor::<PackChecking> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    /// The expansion a call's argument list admits right now: the next
    /// PackExpansionExpr reached is that one, or it is misplaced.
    priv var _arg_ok: *Expr = &null;
    /// Inside an enum variant's payload: its fields are judged by the enum
    /// rules, not as fields.
    priv var _in_variant: bool = false;

    fn PackChecking(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // --- types in declarations ------------------------------------------------------

    priv fn _bare(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        var f = BarePackFinder();
        f.dispatch_type(t);
        return f.found;
    }

    priv fn _pack_name(self, t: *Type) -> string {
        var g = cast::<GenericParamType>(canon_unqual(t->canonical));
        var gps = decl_generic_params(g->owner);
        if usize(g->param_index) < gps.size() { return self._tu.decl_name(static_cast::<*Decl>(gps[usize(g->param_index)])); }
        return "?";
    }

    /// A bare pack in a declaration's written type \p t; \p what names the
    /// position ("a field", "a return type", ...).
    priv fn _check_type(self, t: *Type, what: string, owner: *Decl) -> bool {
        var b = self._bare(t);
        if b == &null { return true; }
        var nm = self._pack_name(b);
        var d = self.sc->diag->report(DiagID::SC001E, b->range.start,
            f"'{nm}' is a type pack and stands for several types; {what} cannot have it as its type");
        d.first(b->range, "a pack is written expanded, as an argument: X<" + nm + "...>");
        d.emit();
        if owner != &null { owner->poison(); }
        return false;
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        if (n != &null) && (!self._in_variant) && (n->type_ != &null) {
            self._check_type(n->type_, "a field", static_cast::<*Decl>(n));
        }
        return RecursiveASTVisitor::<PackChecking>::traverse_field_decl(n);
    }

    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if (n != &null) && (n->type_ != &null) && n->type_->range.is_valid() {
            self._check_type(n->type_, "a variable", static_cast::<*Decl>(n));
        }
        return RecursiveASTVisitor::<PackChecking>::traverse_variable_decl(n);
    }

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if (n != &null) && (!n->is_implicit) {
            if n->return_type != &null { self._check_type(n->return_type, "a return value", static_cast::<*Decl>(n)); }
            for var i: usize = 0; i < n->params.size(); ++i {
                var p = n->params[i];
                if (p == &null) || p->is_self || (p->type_ == &null) { continue; }
                // `...xs: T` is the one parameter a bare pack types.
                if p->is_pack && param_is_type_pack(p) { continue; }
                self._check_type(p->type_, "a parameter that is not a pack parameter", static_cast::<*Decl>(p));
            }
        }
        return RecursiveASTVisitor::<PackChecking>::traverse_function_decl(n);
    }

    // --- variadic enums ---------------------------------------------------------------

    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl {
        if (n != &null) && (!n->is_poisoned()) { self._enum_rules(n); }
        return RecursiveASTVisitor::<PackChecking>::traverse_enum_decl(n);
    }

    fn traverse_enum_variant_decl(self, n: *EnumVariantDecl) -> *EnumVariantDecl {
        var saved = self._in_variant;
        self._in_variant = true;
        var out = RecursiveASTVisitor::<PackChecking>::traverse_enum_variant_decl(n);
        self._in_variant = saved;
        return out;
    }

    priv fn _enum_rules(self, en: *EnumDecl) {
        var first: *EnumVariantDecl = &null;
        var bad = false;
        var en_nm = self._tu.decl_name(static_cast::<*Decl>(en));
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v == &null { continue; }
            var vn = self._tu.decl_name(static_cast::<*Decl>(v));
            if !v->is_pack_expansion {
                // A pack in an ordinary variant: one variant, many types.
                for var j: usize = 0; j < v->payload.size(); ++j {
                    var f = v->payload[j];
                    var b = (self._bare(f->type_)) if (f != &null) else (&null);
                    if b == &null { continue; }
                    var nm = self._pack_name(b);
                    var d = self.sc->diag->report(DiagID::SC001E, b->range.start,
                        f"variant '{vn}' names the type pack '{nm}', but is one variant; add ... after it to make one variant per element of '{nm}\x27");
                    d.first(b->range, "a pack stands for several types");
                    var fixmsg = "expand " + vn + " over " + nm;
                    d.insert(v->range.end, "...", fixmsg);
                    d.emit();
                    bad = true;
                    break;
                }
                continue;
            }
            if v->payload.size() == 0 {
                var d = self.sc->diag->report(DiagID::SC001E, v->pack_range.start,
                    f"variant '{vn}' is followed by ... but has no payload, so there is nothing to expand");
                d.first(v->pack_range, "one variant per element of a pack its payload names");
                d.remove(v->pack_range, "remove the ellipsis");
                d.emit();
                bad = true;
                continue;
            }
            var names_pack = false;
            for var j: usize = 0; j < v->payload.size(); ++j {
                var f = v->payload[j];
                if (f != &null) && (f->type_ != &null) && (f->type_->canonical != &null) && f->type_->canonical->contains_unexpanded_pack() { names_pack = true; }
            }
            if !names_pack {
                var d = self.sc->diag->report(DiagID::SC001E, v->pack_range.start,
                    f"variant '{vn}' is followed by ..., but its payload names no type pack of '{en_nm}\x27");
                d.first(v->pack_range, "this expands the variant once per element of a pack");
                d.remove(v->pack_range, "remove the ellipsis");
                d.emit();
                bad = true;
                continue;
            }
            // The pack as a field's whole type (`e: E`): at element k the
            // field is the element. A type built from it (`*E`, `Box<E>`)
            // would need its own substitution per element in the payload's
            // C++ template and in every read; not built yet.
            var shaped = false;
            for var j: usize = 0; j < v->payload.size(); ++j {
                var f = v->payload[j];
                if (f == &null) || (f->type_ == &null) || (f->type_->canonical == &null) { continue; }
                if !f->type_->canonical->contains_unexpanded_pack() { continue; }
                var g = dyn_cast::<GenericParamType>(canon_unqual(f->type_->canonical));
                if (g != &null) && g->is_pack { continue; }
                var fnm = self._tu.decl_name(static_cast::<*Decl>(f));
                var d = self.sc->diag->report(DiagID::SC116E, f->type_->range.start,
                    f"field '{fnm}' of pack-expanded variant '{vn}' builds a type from the pack; only the pack itself as the field's type is supported yet");
                d.first(f->type_->range, "write the pack as the whole type, as in 'e: E\x27");
                d.emit();
                shaped = true;
            }
            if shaped { bad = true; continue; }
            if first != &null {
                var fn_ = self._tu.decl_name(static_cast::<*Decl>(first));
                var d = self.sc->diag->report(DiagID::SC001E, v->pack_range.start,
                    f"'{en_nm}' already has a pack-expanded variant, '{fn_}'; an enum expands its pack once");
                d.first(v->pack_range);
                d.note(first->pack_range.start, "the first one").first(first->pack_range);
                d.emit();
                bad = true;
                continue;
            }
            first = v;
            if i + 1 != en->variants.size() {
                var nx = self._tu.decl_name(static_cast::<*Decl>(en->variants[i + 1]));
                var d = self.sc->diag->report(DiagID::SC001E, v->range.start,
                    f"pack-expanded variant '{vn}' must be the last variant of '{en_nm}\x27");
                d.first(v->range, "one variant per element: its size is the pack's");
                d.note(en->variants[i + 1]->range.start, f"'{nx}' follows it, and its tag would move with the pack").first(en->variants[i + 1]->range);
                d.emit();
                bad = true;
            }
        }
        if bad { en->poison(); }
    }

    // --- pack parameters in expressions ----------------------------------------------------

    fn traverse_call_expr(self, n: *CallExpr) -> *CallExpr {
        if n == &null { return n; }
        if n->callee != &null { self.dyn()->dispatch_expr(n->callee); }
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = *(n->args.get(i));
            var value = named_call_arg_value(a);
            if value != &null { a = value; }
            var saved = self._arg_ok;
            if isa::<PackExpansionExpr>(a) { self._arg_ok = a; }
            self.dyn()->dispatch_expr(a);
            self._arg_ok = saved;
        }
        return n;
    }

    fn traverse_pack_expansion_expr(self, n: *PackExpansionExpr) -> *PackExpansionExpr {
        if n == &null { return n; }
        var here = static_cast::<*Expr>(n);
        var ok_pos = self._arg_ok == here;
        self._arg_ok = &null;
        var opnd = n->operand;
        var pk = (self._type_pack_param(opnd)) if (opnd != &null) else (&null);
        if !ok_pos {
            var d = self.sc->diag->report(DiagID::SC001E, n->range.start,
                "a pack expansion is written only as a call argument, where it passes each element as its own argument");
            d.first(n->range);
            d.emit();
            n->poison();
            return n;
        }
        if pk == &null {
            var d = self.sc->diag->report(DiagID::SC001E, n->range.start,
                "only a pack parameter can be expanded");
            d.first((opnd->range) if (opnd != &null) else (n->range), "this is not a pack parameter");
            d.emit();
            n->poison();
            if opnd != &null { self.dyn()->dispatch_expr(opnd); }
            return n;
        }
        return n;   // the operand is the pack's own name: nothing more to check.
    }

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if n == &null { return n; }
        // `for x in xs`: the pack is iterated, once per element.
        if (n->iterable != &null) && (self._type_pack_param(n->iterable) != &null) {
            if n->body != &null { self.dyn()->traverse_block(n->body); }
            return n;
        }
        return RecursiveASTVisitor::<PackChecking>::traverse_ranged_for_stmt(n);
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        var p = dyn_cast::<ParamDecl>(n->resolved_decl);
        if !param_is_type_pack(p) { return true; }
        var nm = self._tu.param_name(p);
        var d = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"'{nm}' is a pack of values with different types; pass it on expanded as an argument, or iterate it with a for loop");
        d.first(n->range);
        d.note(static_cast::<*Decl>(p)->range.start, "declared as a pack here").first(static_cast::<*Decl>(p)->range);
        d.emit();
        n->poison();
        return true;
    }

    /// \p e names a type pack parameter, or null.
    priv fn _type_pack_param(self, e: *Expr) -> *ParamDecl {
        var u = self._tu.strip_parens(e);
        if (u == &null) || (!isa::<NamedIdentExpr>(u)) { return &null; }
        var p = dyn_cast::<ParamDecl>(cast::<NamedIdentExpr>(u)->resolved_decl);
        return (p) if (param_is_type_pack(p)) else (&null);
    }
}
