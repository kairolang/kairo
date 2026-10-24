/// --- The Kairo Project ---------------------- Sema/Type/StmtTyping.k --- ///
///
///   \brief The statement half: function frames, `return` against the
///          signature, declarations that infer, conditions that must be bool,
///          binders that take their type from what they iterate or destructure.
///
///   \detail
///     This is what "TypeChecking" was going to be. A statement never has a
///     type; it decides what its expressions are expected to be and hands
///     that down. The RAV drives the walk; every override here calls
///     `type_of` with the right expected type BEFORE the base traversal
///     could reach the expression with none.
///
///     Frames: one per function or closure body, carrying the declared
///     return type (or null when inferring) and the join of the returns seen
///     so far. `fn_return_type(f)` is the demand entry other mixins use for a
///     callee: declared -> canonical; `-> !` -> Never; expression-bodied with
///     no annotation -> typed on demand under a rstate cycle guard, so a
///     recursive `fn f() = f()` is one diagnostic rather than a stack.
///
///     Inferred slots receive the canonical node itself. A canonical is
///     self-canonical, so every consumer that reads `->canonical` is
///     unchanged, and no node is allocated.
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
import Sema::Resolve::ResolutionState::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Lower::LowerSynth::*;
import Sema::Check::ConstEval::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Patterns::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::StmtKind::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Diagnostic::Registry::*;
import AST::ParamMode::*;

/// The first name in a default argument that binds to a parameter of \p fn,
/// `self` included. A default is evaluated by a nullary thunk (CallLowering),
/// so it has no parameters to read; this is a language rule, not a lowering
/// limit.
class DefaultRefScan derives RecursiveASTVisitor::<DefaultRefScan> {
    pub var fn_decl: *FunctionDecl  = &null;
    pub var hit:     *NamedIdentExpr = &null;

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if (self.hit != &null) || (n == &null) { return true; }
        var p = dyn_cast::<ParamDecl>(n->resolved_decl);
        if p == &null { return true; }
        for var i: usize = 0; i < self.fn_decl->params.size(); ++i {
            if self.fn_decl->params[i] == p { self.hit = n; return true; }
        }
        return true;
    }
}

class TyperFrame {
    pub var fn_decl:  *FunctionDecl = &null;   ///< null for a closure.
    pub var closure:  *ClosureExpr  = &null;
    pub var declared: *Type = &null;           ///< return type, null = infer.
    pub var inferred: *Type = &null;           ///< join of `return e` seen so far.
    pub var saw_return_value: bool = false;
    pub var saw_bare_return:  bool = false;
    /// `-> yield T`: `declared` is the canonical, which carries cv only and
    /// drops the qualifier, so the frame keeps it here.
    pub var is_generator:     bool = false;
    /// A generator's element: `T` of its Yield<T>, what each `yield` is
    /// typed against. Null otherwise, and null for a closure (which cannot
    /// yield yet).
    pub var yield_elem:       *Type = &null;
    fn TyperFrame(self) { }
}

/// Derives the RAV rather than sitting beside it: these traverse_ methods are
/// OVERRIDES, and two sibling bases declaring the same name is an ambiguity in
/// the emitted C++, not an override. ExprTyper therefore reaches the visitor
/// through this mixin and does not derive it a second time.
class <T> StmtTyping derives RecursiveASTVisitor::<T> {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === frames =============================================================

    fn push_fn_frame(self, f: *FunctionDecl, declared: *Type) {
        var fr = TyperFrame{};
        fr.fn_decl  = f;
        fr.declared = declared;
        fr.is_generator = (f != &null) && dyn()->tu.is_generator_return(f->return_type);
        if f != &null { fr.declared = self._effect_inner(f->return_type, declared); }
        if fr.is_generator && (declared != &null) && dyn()->tu.is_lang(declared, WellKnownType::Yield) {
            var args = dyn()->tu.record_args(declared);
            if args.size() > 0 { fr.yield_elem = args[0]; }
        }
        dyn()->frames.push_back(fr);
    }

    fn push_closure_frame(self, c: *ClosureExpr, declared: *Type) {
        var fr = TyperFrame{};
        fr.closure  = c;
        fr.declared = declared;
        fr.is_generator = (c != &null) && dyn()->tu.is_generator_return(c->return_type);
        if c != &null { fr.declared = self._effect_inner(c->return_type, declared); }
        dyn()->frames.push_back(fr);
    }

    /// `-> async T` canonicalizes to Future<T> (TypeResolve), but the body
    /// `return`s a T: the Future is what the CALLER sees. Unwrap it for the
    /// frame. A generator keeps Yield<T>; its returns are bare and the
    /// is_generator branch owns them.
    priv fn _effect_inner(self, written: *Type, declared: *Type) -> *Type {
        if (written == &null) || (declared == &null) { return declared; }
        if !written->is_async() { return declared; }
        if !dyn()->tu.is_lang(declared, WellKnownType::Future) { return declared; }
        var args = dyn()->tu.record_args(declared);
        return (args[0]) if (args.size() > 0) else (declared);
    }

    fn pop_frame(self) {
        if !dyn()->frames.empty() { dyn()->frames.pop_back(); }
    }

    fn cur_frame(self) -> *TyperFrame {
        if dyn()->frames.empty() { return &null; }
        return &(dyn()->frames[dyn()->frames.size() - 1]);
    }

    fn frame_inferred_return(self) -> *Type {
        var fr = self.cur_frame();
        if fr == &null { return &null; }
        if (fr->inferred == &null) && (!fr->saw_return_value) { return dyn()->tu.builtin(BuiltinKind::Void); }
        return fr->inferred;
    }

    fn in_unsafe(self) -> bool {
        if dyn()->unsafe_depth > 0 { return true; }
        var fr = self.cur_frame();
        if (fr != &null) && (fr->fn_decl != &null) && fr->fn_decl->is_unsafe() { return true; }
        return false;
    }

    // === return type on demand ==============================================

    /// PRE: T ran. Declared -> canonical; `!` -> Never; expr-bodied without an
    /// annotation -> typed now under a cycle guard; a foreign one is read.
    fn fn_return_type(self, f: *FunctionDecl) -> *Type {
        if f == &null { return &null; }
        if f->is_noreturn { return dyn()->tu.builtin(BuiltinKind::Never); }
        if f->return_type != &null { return f->return_type->canonical; }
        if f->body_kind != FnBodyKind::Expr { return dyn()->tu.builtin(BuiltinKind::Void); }
        if f->body_expr == &null { return dyn()->tu.builtin(BuiltinKind::Void); }

        if dyn()->tu.is_foreign(static_cast::<*Decl>(f)) {
            // DAG order: its own TU typed it and wrote the slot. Null here means
            // it failed there, and that TU reported it.
            return (f->body_expr->type_) if (f->body_expr->type_ != &null) else (&null);
        }

        var st = dyn()->sc->rstate.decl_state(static_cast::<*Decl>(f));
        if st == ResolveState::Resolved { return (f->return_type->canonical) if (f->return_type != &null) else (f->body_expr->type_); }
        if st == ResolveState::Errored  { return &null; }
        if st == ResolveState::InProgress {
            dyn()->sc->diag->report(DiagID::SC043E, f->range.start,
                f"cannot infer the return type of '{dyn()->tu.decl_name(static_cast::<*Decl>(f))}': its body refers to itself; annotate the return type"
            ).first(f->range).emit();
            f->poison();
            dyn()->sc->rstate.set_decl_state(static_cast::<*Decl>(f), ResolveState::Errored);
            return &null;
        }
        if !dyn()->sc->rstate.begin_decl(static_cast::<*Decl>(f), f->range) { return &null; }

        self.push_fn_frame(f, &null);
        var saved_unsafe = dyn()->unsafe_depth;
        dyn()->unsafe_depth = 0;
        var t = dyn()->type_of(f->body_expr, &null);
        dyn()->unsafe_depth = saved_unsafe;
        self.pop_frame();

        var ok = (t != &null) && (!f->body_expr->is_poisoned());
        if ok { f->return_type = canon_unqual(t); }   // inferred slot := canonical.
        dyn()->sc->rstate.finish_decl(static_cast::<*Decl>(f), ok || (!f->body_expr->is_poisoned()));
        return t;
    }

    /// A variable's canonical, inferring a file-scope `var x = e` on demand
    /// when a use precedes its declaration in walk order.
    fn var_type(self, v: *VariableDecl) -> *Type {
        if v == &null { return &null; }
        if v->type_ != &null { return v->type_->canonical; }
        if v->init == &null { return &null; }
        if dyn()->tu.is_foreign(static_cast::<*Decl>(v)) { return v->init->type_; }
        var st = dyn()->sc->rstate.decl_state(static_cast::<*Decl>(v));
        if st == ResolveState::Errored { return &null; }
        if st == ResolveState::InProgress {
            dyn()->sc->diag->report(DiagID::SC043E, v->range.start,
                f"cannot infer the type of '{dyn()->tu.decl_name(static_cast::<*Decl>(v))}': its initializer refers to itself"
            ).first(v->range).emit();
            v->poison();
            dyn()->sc->rstate.set_decl_state(static_cast::<*Decl>(v), ResolveState::Errored);
            return &null;
        }
        if st == ResolveState::Resolved { return (v->type_->canonical) if (v->type_ != &null) else (&null); }
        if !dyn()->sc->rstate.begin_decl(static_cast::<*Decl>(v), v->range) { return &null; }
        var t = dyn()->type_of(v->init, &null);
        dyn()->mark_list_storage(v->init);
        self._reject_array_copy(v, t);
        if t != &null { v->type_ = canon_unqual(t); }
        dyn()->sc->rstate.finish_decl(static_cast::<*Decl>(v), t != &null);
        return t;
    }

    priv fn _reject_array_return(self, f: *FunctionDecl, t: *Type) {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<FixedArrayType>(c)) { return; }
        dyn()->sc->diag->report(DiagID::SC044E, f->range.start,
            f"'{dyn()->tu.decl_name(static_cast::<*Decl>(f))}' returns an array; an array is not returned by value, return '[T]' or fill an '@inout' parameter"
        ).first(f->name.range).emit();
    }

    /// An array is initialized from a list literal and from nothing else
    /// (LiteralTyping::reject_array_copy, shared with a field initializer).
    priv fn _reject_array_copy(self, v: *VariableDecl, t: *Type) {
        dyn()->reject_array_copy(v->init, t);
    }

    // === traversal overrides (scope) ========================================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        if n->is_poisoned() { return n; }

        // signature pieces first: defaults against their param types. A
        // default may not read another parameter or `self`, and may not be a
        // slice literal (its thunk would return a view of a dead array).
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if (p == &null) || (p->default_val == &null) { continue; }
            var pt = (p->type_->canonical) if (p->type_ != &null) else (&null);
            dyn()->type_of(p->default_val, pt);
            if dyn()->reject_slice_literal(p->default_val, "used as a default argument") { continue; }
            if pt != &null { dyn()->check_convertible(p->default_val, pt); }
            var scan = DefaultRefScan();
            scan.fn_decl = n;
            scan.dispatch_expr(p->default_val);
            if scan.hit != &null {
                var rp = cast::<ParamDecl>(scan.hit->resolved_decl);
                var what = ("'self\x27") if (rp->is_self) else (f"parameter '{dyn()->tu.param_name(rp)}\x27");
                dyn()->fail(scan.hit, DiagID::SC106E,
                    f"a default argument cannot refer to {what}; a default is evaluated with no access to the call's other arguments");
            }
        }
        // `[T; N]` is a C array: by value it would decay to a pointer and
        // pass by reference. `const` and `@inout` say what is meant.
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if (p == &null) || p->is_self || (p->type_ == &null) { continue; }
            var pc = canon_unqual(p->type_->canonical);
            if (pc == &null) || (!isa::<FixedArrayType>(pc)) { continue; }
            if p->is_const || (p->mode != ParamMode::Value) { continue; }
            dyn()->sc->diag->report(DiagID::SC045E, p->range.start,
                f"parameter '{dyn()->tu.param_name(p)}' takes an array by value; write 'const', '@inout', or take a slice"
            ).first(p->range).emit();
        }
        self._stamp_no_unwind(n);

        // The generator fact, before anything reads it: the body's `yield`s
        // and `return`s below, then ReturnPathCheck and EmitIR. The WRITTEN
        // `-> yield T` decides, not the canonical Yield<T> (see
        // TypeUtil::is_generator_return).
        n->is_generator = dyn()->tu.is_generator_return(n->return_type);
        n->has_yield    = false;
        if n->is_generator { self._check_generator_kind(n); }

        if n->requires_clause != &null { dyn()->type_of(n->requires_clause, dyn()->tu.builtin(BuiltinKind::Bool)); }
        if n->where_clause != &null    { dyn()->require_bool(n->where_clause, "a 'where' clause"); }

        var declared: *Type = &null;
        if n->return_type != &null { declared = n->return_type->canonical; }
        if n->is_noreturn { declared = dyn()->tu.builtin(BuiltinKind::Never); }
        if (n->return_type == &null) && (!n->is_noreturn) && (n->body_kind != FnBodyKind::Expr) {
            declared = dyn()->tu.builtin(BuiltinKind::Void);
        }

        // An expression body abbreviates `{ return e }` (ExprBodyDesugar), so a
        // written return type types it exactly as that `return` would. Only
        // an unwritten one goes through the demand path, which owns the
        // inference slot; routing a declared one there too would make a
        // recursive call in the body read its own InProgress state (SC043E).
        if n->body_kind == FnBodyKind::Expr {
            if declared == &null {
                self.fn_return_type(n);
                if n->return_type != &null { self._reject_array_return(n, n->return_type->canonical); }
                return n;
            }
            self._reject_array_return(n, declared);
            if n->body_expr == &null { return n; }
            self.push_fn_frame(n, declared);
            var saved_unsafe_e = dyn()->unsafe_depth;
            dyn()->unsafe_depth = 0;
            var want = self.cur_frame()->declared;
            var bt = dyn()->type_of(n->body_expr, want);
            dyn()->reject_slice_literal(n->body_expr, "returned from a function");
            if (want != &null) && dyn()->tu.is_void(want) {
                // desugars to `return e;` in a void function: legal C++ only
                // for a void (or never-returning) `e`.
                if (bt != &null) && (!dyn()->tu.is_void(bt)) && (!dyn()->tu.is_never(bt)) {
                    dyn()->sc->diag->report(DiagID::SC050E, n->body_expr->range.start,
                        f"an expression body of type '{dyn()->tu.str(bt)}' in a function returning 'void\x27"
                    ).first(n->body_expr->range).emit();
                }
            } else if want != &null {
                dyn()->check_convertible(n->body_expr, want);
            }
            dyn()->unsafe_depth = saved_unsafe_e;
            self.pop_frame();
            return n;
        }
        self._reject_array_return(n, declared);

        self.push_fn_frame(n, declared);
        var saved_unsafe = dyn()->unsafe_depth;
        dyn()->unsafe_depth = 0;
        if n->body_block != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body_block)); }
        dyn()->unsafe_depth = saved_unsafe;
        self.pop_frame();
        return n;
    }

    /// `@no_unwind` on any link marks the whole chain (FunctionDecl::no_unwind).
    /// Probed, never interned: a name this file never spelled is on no decl.
    priv fn _stamp_no_unwind(self, n: *FunctionDecl) {
        var k = dyn()->sc->imm_table()->find_ident("no_unwind");
        if k == u32(-1) { return; }
        if !n->has_attribute_named(k) { return; }
        var head = n->first_decl();
        var cur  = head;
        while true {
            cur->no_unwind = true;
            cur = cur->next_in_chain();
            if cur == head { break; }
        }
    }

    /// The functions that cannot be generators, each for a reason C++ makes
    /// fatal or Kairo makes meaningless. One error, at the name.
    priv fn _check_generator_kind(self, n: *FunctionDecl) {
        var why = "";
        if n->is_operator && (n->op_token.size() > 0) && (n->op_token[0].kind == TokenKind::KwDelete) {
            why = "a destructor cannot be a generator; it runs to completion when the object dies";
        } else if self._is_ctor(n) {
            why = "a constructor cannot be a generator; it returns the object it builds, not a sequence";
        } else if self._is_main(n) {
            why = "'main' cannot be a generator; it returns the process\x27s exit status";
        } else if n->is_eval() {
            why = "an 'eval' function cannot be a generator; it runs at compile time, where nothing suspends";
        } else if n->ffi_c_variadic {
            why = "a C-variadic function cannot be a generator; its '...' arguments do not outlive the call";
        } else if n->is_noreturn {
            why = "a function returning '!' cannot be a generator; a generator ends";
        }
        if why.size() == 0 { return; }
        var at = (n->range) if (n->is_operator) else (n->name.range);
        dyn()->sc->diag->report(DiagID::SC112E, at.start, why).first(at).emit();
    }

    /// A method named after the type it is declared in. Operators have no
    /// name token to compare.
    priv fn _is_ctor(self, f: *FunctionDecl) -> bool {
        if f->is_operator || (!f->is_method()) { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_owner == &null) { return false; }
        return dyn()->tu.decl_name(static_cast::<*Decl>(f)) == dyn()->tu.decl_name(dc->dc_owner);
    }

    /// A free function named `main` outside any type. Whether this TU is the
    /// entry is codegen's question; a generator `main` is wrong in any TU.
    priv fn _is_main(self, f: *FunctionDecl) -> bool {
        if f->is_operator || f->is_method() { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc != &null) && dc->is_type_scope() { return false; }
        return dyn()->tu.decl_name(static_cast::<*Decl>(f)) == "main";
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        if n == &null { return n; }
        if n->init != &null {
            var ft = (n->type_->canonical) if (n->type_ != &null) else (&null);
            dyn()->type_of(n->init, ft);
            dyn()->reject_slice_literal(n->init, "used as a field default");
            if ft != &null { dyn()->check_convertible(n->init, ft); }
        }
        return n;
    }

    fn traverse_enum_variant_decl(self, n: *EnumVariantDecl) -> *EnumVariantDecl {
        if n == &null { return n; }
        var edc = reinterpret_cast::<*DeclContext>(n->semantic_dc);
        var ed  = (dyn_cast::<EnumDecl>(edc->owner_decl())) if (edc != &null) else (&null);
        var under: *Type = dyn()->tu.builtin(BuiltinKind::U32);
        if (ed != &null) && (ed->underlying != &null) && (ed->underlying->canonical != &null) { under = ed->underlying->canonical; }
        var typed_ok = true;
        if n->discriminant != &null {
            // An earlier variant named here is its integer value, not an enum
            // object; see ExprTyper::discr_enum.
            var saved = dyn()->discr_enum;
            dyn()->discr_enum = (NameLookup::representative(static_cast::<*Decl>(ed))) if (ed != &null) else (&null);
            dyn()->type_of(n->discriminant, under);
            typed_ok = dyn()->check_convertible(n->discriminant, under);
            dyn()->discr_enum = saved;
        }
        self._enum_variant_value(n, ed, under, typed_ok);
        for var i: usize = 0; i < n->payload.size(); ++i { self.traverse_field_decl(n->payload[i]); }
        return n;
    }

    /// Write EnumVariantDecl::value (this is its one writer): the
    /// discriminant's value, else the previous variant's plus one, else 0.
    /// The RAV visits `variants` in order, so the previous variant's slot,
    /// and every slot a discriminant may name, is already written. An
    /// imported C++ enum is clang's to number and is left alone.
    priv fn _enum_variant_value(self, n: *EnumVariantDecl, ed: *EnumDecl, under: *Type, typed_ok: bool) {
        n->value = IntConst{};
        if (ed != &null) && ed->is_imported() { return; }
        var ce = ConstEval(dyn()->sc);
        var pos = usize(n->index);
        if ed != &null {
            for var i: usize = 0; i < ed->variants.size(); ++i {
                if ed->variants[i] == n { pos = i; break; }
            }
        }

        if n->discriminant != &null {
            // X has already said what is wrong with a discriminant that
            // did not type or convert (SC075E for `256` in a u8 enum).
            if (!typed_ok) || n->discriminant->is_poisoned() { return; }
            var c = ce.eval_discriminant(n->discriminant, ed, pos);
            if c.ok && ce.fits(c, under) {
                n->value = c;
                self._reject_duplicate_value(n, ed, pos);
                return;
            }
            if (!c.ok) && ce.quiet { return; }
            if !c.ok {
                var at = (ce.bad) if (ce.bad != &null) else (n->discriminant);
                var why = (ce.bad_why) if (ce.bad_why.size() > 0) else ("it is not a constant");
                var b = dyn()->sc->diag->report(DiagID::SC128E, at->range.start,
                    f"an enum discriminant must be an integer constant that fits '{dyn()->tu.str(under)}'; this one does not evaluate: {why}"
                );
                b.first(at->range);
                if ce.bad_decl != &null {
                    b.note(ce.bad_decl->range.start, f"'{dyn()->tu.decl_name(ce.bad_decl)}' is declared here");
                }
                b.emit();
                return;
            }
            self._report_value_misfit(ed, under, n->discriminant->range, f"it is {ce.str(c)}");
            return;
        }

        if pos == 0 { n->value = ce.make(false, u64(0)); return; }
        var prev = (ed->variants[pos - 1]) if ((ed != &null) && (pos < ed->variants.size())) else (&null);
        if (prev == &null) || (!prev->value.ok) { return; }   // the previous one failed, and said so.
        var c = ce.add(prev->value, ce.make(false, u64(1)));
        if ce.fits(c, under) {
            n->value = c;
            self._reject_duplicate_value(n, ed, pos);
            return;
        }
        // C++ rejects the enumerator too; say it here, where the cause is.
        self._report_value_misfit(ed, under, n->name.range,
            f"'{dyn()->tu.decl_name(static_cast::<*Decl>(n))}' is one past '{dyn()->tu.decl_name(static_cast::<*Decl>(prev))}', so it is {ce.str(c)}");
    }

    /// SC130E when \p n, just given its value, repeats the value of a
    /// variant above it. A closed-enum match switches on the enumerators, so
    /// two with one value would be two case labels with one value, which
    /// C++ rejects in the emitted switch, and no arm could tell the two
    /// apart anyway. How either value came about does not matter: written,
    /// computed, or one past the previous. Only the variants above are
    /// compared, so each pair is reported once, at the later one. A variant
    /// whose value failed has no ok slot and takes no part; its error is
    /// already out. An ADT is not checked: its match switches on the tag,
    /// which is the variant's position (MatchLowering), never its value.
    priv fn _reject_duplicate_value(self, n: *EnumVariantDecl, ed: *EnumDecl, pos: usize) {
        if (ed == &null) || ed->is_adt || (!n->value.ok) { return; }
        var lim = (pos) if (pos < ed->variants.size()) else (ed->variants.size());
        for var i: usize = 0; i < lim; ++i {
            var a = ed->variants[i];
            if (a == &null) || (a == n) || (!a->value.ok) || a->value.overflow { continue; }
            if (a->value.neg != n->value.neg) || (a->value.mag != n->value.mag) { continue; }
            var ce = ConstEval(dyn()->sc);
            var an = dyn()->tu.decl_name(static_cast::<*Decl>(a));
            var b = dyn()->sc->diag->report(DiagID::SC130E, n->name.range.start,
                f"'{dyn()->tu.decl_name(static_cast::<*Decl>(n))}' has the same value as '{an}' ({ce.str(n->value)})"
            );
            b.first(n->name.range);
            b.note(DiagID::SC130N, a->name.range.start, f"'{an}' is declared here");
            b.emit();
            return;
        }
    }

    /// SC128E for a value outside the underlying type, with a note on
    /// where that type comes from.
    priv fn _report_value_misfit(self, ed: *EnumDecl, under: *Type, at: SourceRange, what: string) {
        var b = dyn()->sc->diag->report(DiagID::SC128E, at.start,
            f"an enum discriminant must be an integer constant that fits '{dyn()->tu.str(under)}'; {what}, which does not fit"
        );
        b.first(at);
        if (ed != &null) && (ed->underlying != &null) && ed->underlying->range.is_valid() {
            b.note(ed->underlying->range.start, "the underlying type is declared here");
        } else if ed != &null {
            b.note(ed->name.range.start,
                f"'{dyn()->tu.decl_name(static_cast::<*Decl>(ed))}' has the default underlying type 'u32'; name a wider one with 'derives\x27"
            );
        }
        b.emit();
    }

    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }
        if n->is_poisoned() { return n; }
        var declared: *Type = &null;
        if n->type_ != &null {
            if n->type_->is_poisoned() { if n->init != &null { dyn()->type_of(n->init, &null); } return n; }
            declared = n->type_->canonical;
        }
        if n->init == &null {
            if (n->type_ == &null) {
                dyn()->sc->diag->report(DiagID::SC046E, n->range.start,
                    f"'{dyn()->tu.decl_name(static_cast::<*Decl>(n))}' has neither a type nor an initializer"
                ).first(n->range).emit();
                n->poison();
            }
            return n;
        }
        var st = dyn()->sc->rstate.decl_state(static_cast::<*Decl>(n));
        if st != ResolveState::Unresolved { return n; }   // demand-typed already.
        dyn()->sc->rstate.begin_decl(static_cast::<*Decl>(n), n->range);
        var t = dyn()->type_of(n->init, declared);
        dyn()->mark_list_storage(n->init);
        self._reject_array_copy(n, (declared) if (declared != &null) else (t));
        var ok = true;
        if declared != &null {
            ok = dyn()->check_convertible(n->init, declared);
        } else if t != &null {
            if dyn()->tu.is_void(t) {
                dyn()->sc->diag->report(DiagID::SC047E, n->range.start,
                    f"'{dyn()->tu.decl_name(static_cast::<*Decl>(n))}' is initialized with an expression of type 'void\x27"
                ).first(n->range).emit();
                n->poison(); ok = false;
            } else {
                n->type_ = canon_unqual(t);   // inferred slot := the value's type; a copy has no cv.
            }
        } else if n->init->is_poisoned() {
            ok = false;
        }
        dyn()->sc->rstate.finish_decl(static_cast::<*Decl>(n), ok);
        return n;
    }

    // === statements =========================================================

    fn traverse_expression_stmt(self, n: *ExpressionStmt) -> *ExpressionStmt {
        if (n == &null) || (n->expr == &null) { return n; }
        dyn()->type_of(n->expr, &null);
        return n;
    }

    fn traverse_return_stmt(self, n: *ReturnStmt) -> *ReturnStmt {
        if n == &null { return n; }
        var fr = self.cur_frame();
        if fr == &null {
            if n->value != &null { dyn()->type_of(n->value, &null); }
            return n;
        }
        // A generator's `-> yield T` types what it YIELDS. A bare `return`
        // ends the sequence early (functions.md); a value has nowhere to go.
        if fr->is_generator {
            if n->value == &null { fr->saw_bare_return = true; return n; }
            dyn()->type_of(n->value, &null);
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                "a generator ends with 'return' and yields its values; it has no return value"
            ).first(n->range).emit();
            return n;
        }
        if n->value == &null {
            fr->saw_bare_return = true;
            if (fr->declared != &null) && (!dyn()->tu.is_void(fr->declared)) && (!dyn()->tu.is_never(fr->declared)) {
                dyn()->sc->diag->report(DiagID::SC048E, n->range.start,
                    f"'return' with no value in a function returning '{dyn()->tu.str(fr->declared)}\x27"
                ).first(n->range).emit();
            }
            return n;
        }
        fr->saw_return_value = true;
        var t = dyn()->type_of(n->value, fr->declared);
        dyn()->reject_slice_literal(n->value, "returned from a function");
        if fr->declared != &null {
            if dyn()->tu.is_never(fr->declared) {
                dyn()->sc->diag->report(DiagID::SC049E, n->range.start, "a function returning '!' cannot return").first(n->range).emit();
                return n;
            }
            if dyn()->tu.is_void(fr->declared) {
                if (t != &null) && (!dyn()->tu.is_void(t)) {
                    dyn()->sc->diag->report(DiagID::SC050E, n->range.start,
                        f"'return' with a value of type '{dyn()->tu.str(t)}' in a function returning 'void\x27"
                    ).first(n->range).emit();
                }
                return n;
            }
            dyn()->check_convertible(n->value, fr->declared);
            return n;
        }
        // inferring
        if t == &null { return n; }
        var j = dyn()->conv.join(fr->inferred, t);
        if j == &null {
            dyn()->sc->diag->report(DiagID::SC039E, n->range.start,
                f"this 'return' has type '{dyn()->tu.str(t)}', which does not unify with an earlier return of type '{dyn()->tu.str(fr->inferred)}\x27"
            ).first(n->range).emit();
            return n;
        }
        fr->inferred = j;
        return n;
    }

    fn traverse_conditional_stmt(self, n: *ConditionalStmt) -> *ConditionalStmt {
        if n == &null { return n; }
        if n->cond != &null { dyn()->require_bool(n->cond, "the 'if' condition"); }
        if n->then_ != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->then_)); }
        if n->else_ != &null { dyn()->dispatch_stmt(n->else_); }
        return n;
    }

    fn traverse_while_loop_stmt(self, n: *WhileLoopStmt) -> *WhileLoopStmt {
        if n == &null { return n; }
        if n->cond != &null { dyn()->require_bool(n->cond, "the 'while' condition"); }
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        if n == &null { return n; }
        if n->init   != &null { dyn()->dispatch_stmt(n->init); }
        if n->cond   != &null { dyn()->require_bool(n->cond, "the loop condition"); }
        if n->update != &null { dyn()->type_of(n->update, &null); }
        if n->body   != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    /// The element type an iterable yields, or null (diagnosed). With \p rf,
    /// also records on the loop how IterLowering walks it.
    fn iter_elem_type(self, at: *Expr, t: *Type, rf: *RangedForStmt = &null) -> *Type {
        if t == &null { return &null; }
        var kind = IterKind::None;
        var _op: *Decl = &null;
        var elem = self._iter_classify(at, t, &kind, &_op, rf);
        if (rf != &null) && (elem != &null) {
            rf->iter_kind = kind;
            rf->iter_op   = _op;
            rf->iter_elem = canon_unqual(elem);
        }
        return elem;
    }

    priv fn _iter_classify(self, at: *Expr, t: *Type, kind: *IterKind, _op: *(*Decl), rf: *RangedForStmt) -> *Type {
        var arr = dyn()->tu.element_of(t);
        if arr != &null { (*kind) = IterKind::Array; return arr; }

        if dyn()->tu.is_slice(t)       { (*kind) = IterKind::Slice;  return dyn()->tu.container_elem(t); }
        if dyn()->tu.is_vector_like(t) { (*kind) = IterKind::Vector; return dyn()->tu.container_elem(t); }
        if dyn()->tu.is_set_like(t)    { (*kind) = IterKind::Set;    return dyn()->tu.container_elem(t); }

        var k: *Type = &null; var v: *Type = &null;
        if dyn()->tu.map_key_value(t, &k, &v) {
            (*kind) = IterKind::Map;
            var e = vec::<*Type>(); e.push_back(k); e.push_back(v);
            return dyn()->tu.tuple_of(&e);
        }

        if dyn()->tu.is_string(t) { (*kind) = IterKind::String; return dyn()->tu.builtin(BuiltinKind::Char); }

        if dyn()->tu.is_lang(t, WellKnownType::Range) {
            var r = dyn_cast::<RangeExpr>(dyn()->tu.strip_parens(at));
            if r != &null {
                if (r->begin == &null) || (r->end == &null) {
                    dyn()->fail(at, DiagID::SC095E, "an open range cannot be iterated; give it both bounds");
                    return &null;
                }
                (*kind) = IterKind::RangeLit;
            } else {
                (*kind) = IterKind::RangeValue;
            }
            var args = dyn()->tu.record_args(t);
            return (args[0]) if (args.size() > 0) else (dyn()->tu.builtin(BuiltinKind::I32));
        }

        // A Yield<T> value is a generator already -- a call of a `-> yield T`
        // function, or a variable holding one -- so the loop drives it with
        // no `op in` to call (IterLowering::_user reads the null op).
        if dyn()->tu.is_lang(t, WellKnownType::Yield) {
            var yargs = dyn()->tu.record_args(t);
            if yargs.size() > 0 {
                (*kind) = IterKind::User;
                (*_op)   = &null;
                return yargs[0];
            }
        }

        // `fn op in (self) -> yield T`: the iteration form takes `self` only;
        // `op in (self, x)` is containment and is never picked here.
        var cands = vec::<*Decl>();
        dyn()->ml.lookup(dyn()->tu.strip_nullable(t), DeclName::op_name(TokenKind::KwIn, TokenKind::TkUnknown), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cands[i]);
            if f == &null { continue; }
            var extra: usize = 0;
            for var p: usize = 0; p < f->params.size(); ++p {
                if (f->params[p] != &null) && (!f->params[p]->is_self) { extra += 1; }
            }
            if extra != 0 { continue; }
            var rt = self.fn_return_type(f);
            if rt == &null { continue; }
            rt = dyn()->ded_scratch()->member_through(t, rt);
            if !dyn()->tu.is_lang(rt, WellKnownType::Yield) { continue; }
            var args = dyn()->tu.record_args(rt);
            if args.size() == 0 { continue; }
            (*kind) = IterKind::User;
            (*_op)   = cands[i];
            return args[0];
        }

        var cxx_ok = false;
        var ce = self._cxx_range(at, t, rf, &cxx_ok);
        if cxx_ok { (*kind) = IterKind::Cxx; return ce; }
        if (ce == &null) && at->is_poisoned() { return &null; }   // the protocol applied and failed: reported.

        // A Kairo type has one iteration protocol, so its message names one.
        var how = "no 'op in (self) -> yield T\x27";
        if self._is_cxx_record(t) { how = "no 'op in (self) -> yield T' and no 'begin()'/'end()\x27"; }
        dyn()->fail(at, DiagID::SC095E, f"'{dyn()->tu.str(t)}' is not iterable; it has {how}");
        return &null;
    }

    // --- C++'s range protocol -------------------------------------------------

    /// [stmt.ranged]/1 for a class: a member named `begin` or `end` makes the
    /// loop `r.begin()` / `r.end()`; with neither, `begin(r)` / `end(r)` by
    /// argument-dependent lookup. X does what a C++ compiler does there:
    /// resolves both calls on the range's own cv (a const vector's `begin()
    /// const` returns a const_iterator), mints `__it` / `__end`, and types
    /// `__it != __end`, `*__it` and `++__it` over them, so every overload --
    /// a free operator template, C++20's `!=` from `==` -- is resolved the
    /// way any expression's is. The element is `*__it` read as a value; `*x`
    /// binds its address.
    ///
    /// Imported C++ records only. A Kairo type has exactly one way to be
    /// iterable, `op in (self) -> yield T`: a second protocol would need a
    /// precedence rule when a class has both, would silently reroute a class
    /// that defines begin()/end() only for its C++ callers, and would put
    /// iterator records and pointer steps outside `op in` where Tether does
    /// not follow them. A Kairo class's begin()/end() are ordinary methods.
    ///
    /// \p ok: the protocol applied and every piece typed. Not applying (a
    /// Kairo type, or no begin or end anywhere) reports nothing, so the
    /// caller's SC095E speaks; applying and failing reports, and poisons \p at.
    priv fn _cxx_range(self, at: *Expr, t: *Type, rf: *RangedForStmt, ok: *bool) -> *Type {
        (*ok) = false;
        // The object, cv kept: a const range must pick `begin() const`, so
        // only a reference is looked through (peel_ref would drop the const).
        var obj = t;
        if isa::<CXXLValueRefType>(obj)      { obj = cast::<CXXLValueRefType>(obj)->referee; }
        else if isa::<CXXRValueRefType>(obj) { obj = cast::<CXXRValueRefType>(obj)->referee; }
        if !self._is_cxx_record(obj) { return &null; }

        var mb = vec::<*Decl>();
        var me = vec::<*Decl>();
        var nb = self._cxx_name("begin");
        var ne = self._cxx_name("end");
        dyn()->ml.lookup(obj, nb, &mb);
        dyn()->ml.lookup(obj, ne, &me);
        // A hidden friend `friend It begin(R&)` sits in the class's table but
        // is no member ([stmt.ranged] asks for a MEMBER named begin): it is
        // one of the free candidates, which ADL alone would never reach.
        var hb = vec::<*Decl>();
        var he = vec::<*Decl>();
        self._split_friends(&mb, &hb);
        self._split_friends(&me, &he);

        var bt: *Type = &null;
        var et: *Type = &null;
        var bf: *FunctionDecl = &null;
        var ef: *FunctionDecl = &null;
        var bi: *void = &null;
        var ei: *void = &null;
        var free = false;
        if (mb.size() > 0) || (me.size() > 0) {
            // Members, both or neither: one alone is not a fallback to the
            // free pair ([stmt.ranged]/1.2), it is an error.
            if (mb.size() == 0) || (me.size() == 0) {
                var have = "begin";
                var miss = "end";
                if mb.size() == 0 { have = "end"; miss = "begin"; }
                dyn()->fail(at, DiagID::SC095E, f"'{dyn()->tu.str(t)}' has a member '{have}' but no '{miss}'; a C++ range needs both");
                return &null;
            }
            bf = self._cxx_member(at, obj, &mb, "begin", &bt, &bi);
            ef = self._cxx_member(at, obj, &me, "end",   &et, &ei);
        } else {
            var scopes = vec::<*DeclContext>();
            dyn()->ml.associated_scopes(obj, &scopes);
            var fb = hb;
            var fe = he;
            dyn()->ml.adl_candidates(&scopes, nb, "begin", &hb, &fb);
            dyn()->ml.adl_candidates(&scopes, ne, "end",   &he, &fe);
            if (fb.size() == 0) && (fe.size() == 0) { return &null; }
            // A `begin` that cannot take this range is some other type's:
            // ADL reaches every free `begin` in the namespace. Not iterable,
            // not a failed call.
            var probe = vec::<ArgInfo>();
            probe.push_back(dyn()->arg_info(at));
            var nofree = vec::<*Decl>();
            if !dyn()->ovl.any_viable(&nofree, &probe, false, &fb, &probe) { return &null; }
            if (fb.size() == 0) || (fe.size() == 0) {
                var have = "begin";
                var miss = "end";
                if fb.size() == 0 { have = "end"; miss = "begin"; }
                dyn()->fail(at, DiagID::SC095E, f"'{dyn()->tu.str(t)}' has a free '{have}' but no '{miss}'; a C++ range needs both");
                return &null;
            }
            free = true;
            bf = self._cxx_free(at, &fb, "begin", &bt, &bi);
            ef = self._cxx_free(at, &fe, "end",   &et, &ei);
        }
        if (bf == &null) || (ef == &null) { dyn()->poison_only(at); return &null; }

        var synth = LowerSynth(dyn()->sc);
        var r     = at->range;
        var it    = synth.local(r, "it",  bt, &null);
        var end   = synth.local(r, "end", et, &null);

        var ctx  = dyn()->sc->ctx;
        var cond = static_cast::<*Expr>(BinaryOperatorExpr::create(ctx, r,
                       synth.use_of(it, r, Expr::ValueCategory::LValue),
                       synth.use_of(end, r, Expr::ValueCategory::LValue),
                       synth.punct(r, TokenKind::OpExclaimEqual)));
        var deref = static_cast::<*Expr>(UnaryOperatorExpr::create(ctx, r,
                       synth.use_of(it, r, Expr::ValueCategory::LValue),
                       synth.punct(r, TokenKind::OpStar), UnaryOperatorExpr::Fix::Prefix));
        var next = static_cast::<*Expr>(UnaryOperatorExpr::create(ctx, r,
                       synth.use_of(it, r, Expr::ValueCategory::LValue),
                       synth.punct(r, TokenKind::OpPlusPlus), UnaryOperatorExpr::Fix::Prefix));

        dyn()->require_bool(cond, "a C++ range\x27s 'begin() != end()\x27");
        var elem = dyn()->type_of(deref, &null);
        // A pointer iterator (std::array, span, a C array member) steps by
        // C++'s builtin `++`. Kairo has no `++` on pointers for user code, and
        // this one is the loop's own step over [begin, end), so it is minted
        // typed rather than offered to the operator table.
        if isa::<PointerType>(canon_unqual(bt)) {
            next->type_          = bt;
            next->value_category = Expr::ValueCategory::LValue;
        } else {
            dyn()->type_of(next, &null);
        }
        if cond->is_poisoned() || deref->is_poisoned() || next->is_poisoned() || (elem == &null) {
            dyn()->poison_only(at);
            return &null;
        }

        if rf != &null {
            rf->cxx_begin_fn   = static_cast::<*Decl>(bf);
            rf->cxx_end_fn     = static_cast::<*Decl>(ef);
            rf->cxx_free       = free;
            rf->cxx_begin_inst = bi;
            rf->cxx_end_inst   = ei;
            rf->cxx_it         = static_cast::<*Decl>(it);
            rf->cxx_end        = static_cast::<*Decl>(end);
            rf->cxx_cond       = cond;
            rf->cxx_deref      = deref;
            rf->cxx_next       = next;
        }
        (*ok) = true;
        return dyn()->tu.as_value(elem);
    }

    /// A record imported from a C++ header, or an instance of an imported
    /// template (only its primary carries the import stamp).
    priv fn _is_cxx_record(self, t: *Type) -> bool {
        var c = t;
        if (c != &null) && isa::<CXXLValueRefType>(c)      { c = cast::<CXXLValueRefType>(c)->referee; }
        else if (c != &null) && isa::<CXXRValueRefType>(c) { c = cast::<CXXRValueRefType>(c)->referee; }
        var d = dyn()->tu.record_decl(c);
        if d == &null { return false; }
        if decl_is_imported(d) { return true; }
        return decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d));
    }

    /// Move the non-methods member lookup found (hidden friends) to \p frees.
    priv fn _split_friends(self, found: *vec::<*Decl>, frees: *vec::<*Decl>) {
        var keep = vec::<*Decl>();
        for var i: usize = 0; i < found->size(); ++i {
            var f = dyn_cast::<FunctionDecl>((*found)[i]);
            if (f != &null) && (!f->is_method()) { frees->push_back((*found)[i]); continue; }
            keep.push_back((*found)[i]);
        }
        (*found) = keep;
    }

    /// This TU's DeclName for the identifier \p s.
    priv fn _cxx_name(self, s: string) -> DeclName {
        return DeclName::ident(dyn()->sc->imm_table()->intern_ident_copy(s));
    }

    /// `obj.<name>()` resolved on \p obj's cv: the method, its result type
    /// read as the value the hidden local holds, and the instance.
    priv fn _cxx_member(self, at: *Expr, obj: *Type, cands: *vec::<*Decl>, name: string,
                        ty: *(*Type), inst: *(*void)) -> *FunctionDecl {
        var args = vec::<ArgInfo>();
        var r = dyn()->ovl.resolve(cands, &args, true, at->range, name, obj);
        if r.outcome != OvlOutcome::Selected { return &null; }
        r.ded.bind_from_record(canon_unqual(obj));
        var rt = dyn()->call_result_type(r.decl, &r);
        if rt == &null { return &null; }
        (*ty)   = canon_unqual(dyn()->tu.as_value(rt));
        (*inst) = reinterpret_cast::<*void>(r.instance);
        return r.decl;
    }

    /// `<name>(r)` among the ADL candidates \p cands, the range as its one
    /// argument.
    priv fn _cxx_free(self, at: *Expr, cands: *vec::<*Decl>, name: string,
                      ty: *(*Type), inst: *(*void)) -> *FunctionDecl {
        var args = vec::<ArgInfo>();
        args.push_back(dyn()->arg_info(at));
        var r = dyn()->ovl.resolve(cands, &args, false, at->range, name);
        if r.outcome != OvlOutcome::Selected { return &null; }
        var rt = dyn()->call_result_type(r.decl, &r);
        if rt == &null { return &null; }
        (*ty)   = canon_unqual(dyn()->tu.as_value(rt));
        (*inst) = reinterpret_cast::<*void>(r.instance);
        return r.decl;
    }

    /// Apply binding shorthands and write the binder's type.
    priv fn _bind_one(self, b: *Binding, t: *Type) {
        if (b == &null) || b->is_discard || (b->decl == &null) { return; }
        var vd = dyn_cast::<VariableDecl>(b->decl);
        if vd == &null { return; }
        if (b->type_ != &null) && (b->type_->canonical != &null) {
            vd->type_ = canon_unqual(b->type_->canonical);
            if (t != &null) && (!dyn()->conv.convertible(t, vd->type_->canonical)) {
                dyn()->sc->diag->report(DiagID::SC041E, b->range.start,
                    f"binding annotated '{dyn()->tu.str(vd->type_->canonical)}' cannot take a value of type '{dyn()->tu.str(t)}\x27"
                ).first(b->range).emit();
                vd->poison();
            }
            return;
        }
        if t == &null { return; }
        var shaped = canon_unqual(t);
        var sh = static_cast::<u8>(b->shorthand);
        if (sh & static_cast::<u8>(BindingShorthand::Pointer)) != 0 {
            shaped = dyn()->sc->types->pointer(shaped, (sh & static_cast::<u8>(BindingShorthand::Unsafe)) != 0);
        }
        if (sh & static_cast::<u8>(BindingShorthand::Nullable)) != 0 {
            shaped = dyn()->sc->types->nullable(shaped);
        }
        vd->type_ = shaped;
    }

    priv fn _bind_list(self, list: *FrozenList::<Binding>, t: *Type, at: *Expr) {
        if list->size() == 1 { self._bind_one(list->get(0), t); return; }
        var tu_  = canon_unqual(t);
        var have = (tu_ != &null) && dyn()->tu.is_tuple(tu_);
        var elems = dyn()->tu.tuple_elems(tu_);
        if have && (elems.size() != list->size()) {
            dyn()->fail(at, DiagID::SC042E, f"{list->size()} binding(s) but '{dyn()->tu.str(t)}' has {elems.size()} element(s)");
            have = false;
        }
        if (tu_ != &null) && (!dyn()->tu.is_tuple(tu_)) {
            dyn()->fail(at, DiagID::SC096E, f"cannot destructure '{dyn()->tu.str(t)}' into {list->size()} bindings");
        }
        for var i: usize = 0; i < list->size(); ++i {
            self._bind_one(list->get(i), (elems[i]) if (have) else (&null));
        }
    }

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if n == &null { return n; }
        var it = dyn()->type_of(n->iterable, &null);
        var elem = (self.iter_elem_type(n->iterable, it, n)) if (it != &null) else (&null);
        self._bind_list(&(n->bindings), elem, n->iterable);
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    fn traverse_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> *DestructuringDeclStmt {
        if n == &null { return n; }
        var t = dyn()->type_of(n->value, &null);
        if n->kind_ == DestructureKind::Tuple {
            self._bind_list(&(n->bindings), t, n->value);
            return n;
        }
        // struct destructure: by field name.
        var d = dyn()->tu.record_decl(dyn()->tu.strip_nullable(t));
        if (t != &null) && (d == &null) { dyn()->fail(n->value, DiagID::SC096E, f"cannot destructure '{dyn()->tu.str(t)}' by field name"); return n; }
        var dc = (NameLookup::context_of(dyn()->tu.pattern_of(d))) if (d != &null) else (&null);
        for var i: usize = 0; i < n->bindings.size(); ++i {
            var b = n->bindings.get(i);
            if (b == &null) || b->is_discard || (b->name == &null) { continue; }
            var ft: *Type = &null;
            if dc != &null {
                var spelled = dyn()->sc->ctx->get_spelling(b->name->name);
                var imm = dyn()->sc->ctx->get_ident_imm(b->name->name);
                var cell = dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), spelled);
                var fd = (dyn_cast::<FieldDecl>(cell.first())) if (cell.found()) else (&null);
                if fd == &null {
                    dyn()->sc->diag->report(DiagID::SC040E, b->range.start,
                        f"'{dyn()->tu.decl_name(d)}' has no field named '{spelled}\x27"
                    ).first(b->range).emit();
                    continue;
                }
                if fd->type_ != &null { ft = dyn()->ded_scratch()->member_through(t, fd->type_->canonical); }
            }
            self._bind_one(b, ft);
        }
        return n;
    }

    fn traverse_context_binding_stmt(self, n: *ContextBindingStmt) -> *ContextBindingStmt {
        if n == &null { return n; }
        var t = dyn()->type_of(n->value, &null);
        // enter/exit protocol lowering is a lang-item question; the binder
        // takes the value's type until ContextLowering says otherwise.
        self._bind_list(&(n->bindings), t, n->value);
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    fn traverse_match_stmt(self, n: *MatchStmt) -> *MatchStmt {
        if n == &null { return n; }
        var st = dyn()->type_of(n->scrutinee, &null);
        for var i: usize = 0; i < n->cases.size(); ++i {
            var mc = n->cases.get(i);
            for var j: usize = 0; j < mc->patterns.size(); ++j { dyn()->type_pattern(mc->patterns[j], st); }
            if mc->guard != &null { dyn()->require_bool(mc->guard, "a 'where' guard"); }
            if mc->body  != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(mc->body)); }
            if mc->expression != &null { dyn()->type_of(mc->expression, &null); }
        }
        return n;
    }

    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        if n == &null { return n; }
        if n->try_body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->try_body)); }
        for var i: usize = 0; i < n->arms.size(); ++i {
            var arm = n->arms.get(i);
            var vd = dyn_cast::<VariableDecl>(arm->decl);
            if (vd != &null) && (vd->type_ == &null) {
                var ft: *Type = &null;
                if (arm->filter != &null) && (arm->filter->canonical != &null) { ft = arm->filter->canonical; }
                if ft == &null { var a = vec::<*Type>(); ft = dyn()->tu.lang_record(WellKnownType::Panic, &a); }
                if ft != &null { vd->type_ = canon_unqual(ft); }
            }
            if arm->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(arm->body)); }
        }
        return n;
    }

    fn traverse_unsafe_block_stmt(self, n: *UnsafeBlockStmt) -> *UnsafeBlockStmt {
        if n == &null { return n; }
        dyn()->unsafe_depth += 1;
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        dyn()->unsafe_depth -= 1;
        return n;
    }

    fn traverse_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> *RuntimeAssertStmt {
        if n == &null { return n; }
        if n->condition != &null { dyn()->require_bool(n->condition, "an 'assert' condition"); }
        if n->message   != &null { dyn()->type_of(n->message, dyn()->tu.string_type()); }
        return n;
    }

    fn traverse_static_assert_stmt(self, n: *StaticAssertStmt) -> *StaticAssertStmt {
        if n == &null { return n; }
        if n->condition != &null { dyn()->require_bool(n->condition, "a static assertion"); }
        if n->message   != &null { dyn()->type_of(n->message, dyn()->tu.string_type()); }
        return n;
    }

    fn traverse_panic_stmt(self, n: *PanicStmt) -> *PanicStmt {
        if n == &null { return n; }
        if n->payload != &null { dyn()->type_of(n->payload, &null); }
        return n;
    }

    /// `yield e` types against the enclosing generator's element. Every
    /// other place a `yield` can sit is an error here, so EmitIR only ever
    /// meets one inside a function it knows is a generator.
    fn traverse_yield_stmt(self, n: *YieldStmt) -> *YieldStmt {
        if n == &null { return n; }
        var fr = self.cur_frame();
        if (fr == &null) || (fr->closure != &null) || (!fr->is_generator) {
            if n->value != &null { dyn()->type_of(n->value, &null); }
            if fr == &null {
                dyn()->sc->diag->report(DiagID::SC111E, n->range.start, "'yield' outside a function").first(n->range).emit();
            } else if fr->closure != &null {
                // Lifts when closures are emitted at all; a closure frame has
                // no FunctionDecl to carry the generator fact yet.
                dyn()->sc->diag->report(DiagID::SC111E, n->range.start, "a closure cannot yield yet").first(n->range).emit();
            } else {
                var f = fr->fn_decl;
                var b = dyn()->sc->diag->report(DiagID::SC111E, n->range.start,
                    "'yield' in a function that does not return 'yield T\x27"
                );
                b.first(n->range);
                if (f != &null) && (f->return_type != &null) && f->return_type->range.is_valid() {
                    b.note(f->return_type->range.start, "declare the return type 'yield T' to make this a generator").first(f->return_type->range);
                } else if (f != &null) && (!f->is_operator) {
                    b.note(f->name.range.start, "this function has no return type; declare '-> yield T' to make it a generator").first(f->name.range);
                }
                b.emit();
            }
            return n;
        }

        if fr->fn_decl != &null { fr->fn_decl->has_yield = true; }
        if n->value == &null { return n; }
        var elem = fr->yield_elem;
        dyn()->type_of(n->value, elem);
        // The backing array of `[1, 2]` as a slice dies at the suspension.
        if dyn()->reject_slice_literal(n->value, "yielded from a generator") { return n; }
        if elem == &null { return n; }
        // Either side dependent is the instance's question.
        var vt = n->value->type_;
        if elem->is_dependent() || ((vt != &null) && vt->is_dependent()) { return n; }
        dyn()->check_convertible(n->value, elem);
        return n;
    }
}