/// --- The Kairo Project ---------- Compiler/AST/Printer/ASTPrinter.k ----- ///
///
///   AstDumper: the single AST renderer for the whole compiler.
///
///   Source-faithful path (src_*) is unchanged: diagnostic/canonical styles
///   reproduce one-line source for sema diagnostics.
///
///   The DEBUG TREE path (--print-ast) is now built on RecursiveASTVisitor.
///   AstDumper is the RAV's first real consumer. It overrides ONLY the five
///   family dispatchers (dispatch_decl/_stmt/_expr/_type/_pattern). Every
///   child recurse in RAV routes through dispatch_F(child) via self.dyn(),
///   so intercepting the five dispatchers captures the entire walk without
///   touching the ~113 per-node traverse_ bodies.
///
///   Why dispatch and not traverse/walkup:
///     - traverse_* bodies hard-code each node's children; overriding all of
///       them is 113 shims. dispatch_* is 5 methods and catches everything.
///     - the dumper needs its own child order + per-child is_last for the
///       `|-'/"-"` spine. The fixed traverse signature (self, n) -> *N has no
///       is_last slot, so is_last is stashed on self (_pending_last) and read
///       at the top of each dispatch override.
///
///   ATTRIBUTES + VISIBILITY: every decl row now prefixes written visibility
///   (pub/prot/priv) and renders each annotation entry (@name). Attribute
///   ARGS are not rendered: AnnotationEntry.args is FrozenList<*void> in
///   Stage 0 (no typed Expr, no labels stored) so there is nothing faithful
///   to print. See the honesty note at end of file / chat.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// --------------------------------------------------------------------- ///

import AST::Printer::PrintCore::*;
import AST::ASTContext::*;
import AST::DeclContext::*;
import AST::Support::*;
import AST::InternedStr::*;
import AST::TranslationUnit::*;
import AST::Mixin::TypeQual::*;
import AST::Mixin::Annotation::*;
import ASTVisitor::RecursiveASTVisitor::*;
import ASTNode::Base::*;
import ASTNode::Program::*;
import ASTNode::PrimaryExpressions::*;
import ASTNode::Expressions::*;
import ASTNode::Types::*;
import ASTNode::Patterns::*;
import ASTNode::Statements::*;
import ASTNode::Declarations::*;
import ASTNode::Casting::*;
import ASTKind::DeclKind::*;
import ASTKind::ExprKind::*;
import ASTKind::TypeKind::*;
import ASTKind::StmtKind::*;
import ASTKind::PatternKind::*;
import TokenKind::*;

/// AstDumper derives RecursiveASTVisitor::<AstDumper> so its dispatch_*
/// overrides are reached through the CRTP dyn() routing. The source-faithful
/// (src_*) methods are independent of RAV and unchanged.
class AstDumper derives RecursiveASTVisitor::<AstDumper> {
    pub var p:   Painter;
    pub var ctx: obs::<ASTContext>;

    /// Stashed is_last for the next dispatch_* call. The traverse/dispatch
    /// signature has no is_last slot, so the dumper sets this immediately
    /// before invoking a dispatcher and the override reads it once at entry.
    /// Defaults true so a bare top-level dispatch renders as a last child.
    pub var _pending_last: bool = true;

    fn AstDumper(self, ctx: *ASTContext, opts: PrintOptions) {
        self.ctx = ctx;
        self.p   = Painter(opts);
    }

    // ======================================================================
    //  SHARED HELPERS
    // ======================================================================

    /// Resolve a token to its real source spelling. THE fix for the
    /// "identifier" corruption  always source text, never a kind word.
    fn tok(self, t: Token) -> string {
        return TokenText::from_token(t, self.ctx).get_text();
    }

    /// Resolve an interned string. Falls back when the hoisted scope is not
    /// wired (FFI-origin symbols have no interner entry in this TU).
    fn istr(self, s: InternedStr) -> string {
        if self.ctx->hoisted != &null { return self.ctx->hoisted->str(s); }
        return "<ffi>";
    }

    /// True when istr() could not resolve a real name (hoisted unwired).
    /// Used by the attribute renderer to avoid printing the bare sentinel as
    /// if it were a real attribute name.
    fn _istr_unresolved(self) -> bool {
        return self.ctx->hoisted == &null;
    }

    fn _expr_list(self, open: string, close: string, xs: FrozenList::<*Expr>) {
        self.p.paint(Color::Punct, open);
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            self.src_expr(xs[i]);
        }
        self.p.paint(Color::Punct, close);
    }

    fn _pat_list(self, xs: FrozenList::<*Pattern>) {
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            self.src_pattern(xs[i]);
        }
    }

    /// Generic argument list `<...>`. Shared by NamedIdentExpr, ChainExpr
    /// steps, and ChainType segments  all carry ChainType::GenericArg.
    fn _generic_args(self, args: FrozenList::<ChainType::GenericArg>) {
        if args.is_empty() { return; }
        self.p.paint(Color::Punct, "<");
        for var i: usize = 0; i < args.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            var a = args.get(i);
            if a->name != &null {
                self.p.paint(Color::Ident, self.tok(a->name->name));
                self.p.paint(Color::Punct, ": ");
            }
            self.src_type(a->ty);
        }
        self.p.paint(Color::Punct, ">");
    }

    fn _access_op(self, k: ChainExpr::AccessKind) {
        type AK = ChainExpr::AccessKind;
        if      k == AK::Dot               { self.p.paint(Color::Operator, ".");    }
        else if k == AK::Arrow             { self.p.paint(Color::Operator, "->");   }
        else if k == AK::ColonColon        { self.p.paint(Color::Operator, "::");   }
        else if k == AK::QuestionDot       { self.p.paint(Color::Operator, "?.");   }
        else if k == AK::QuestionArrow     { self.p.paint(Color::Operator, "?->");  }
        else if k == AK::DotStar           { self.p.paint(Color::Operator, ".*");   }
        else if k == AK::ArrowStar         { self.p.paint(Color::Operator, "->*");  }
        else if k == AK::QuestionDotStar   { self.p.paint(Color::Operator, "?.*");  }
        else if k == AK::QuestionArrowStar { self.p.paint(Color::Operator, "?->*"); }
    }

    /// `pub `/`prot `/`priv ` prefix from the numeric visibility code
    /// (0 None / 1 priv / 2 prot / 3 pub). Source path.
    fn _vis(self, v: u8) {
        if      v == 3 { self.p.paint(Color::Keyword, "pub ");  }
        else if v == 2 { self.p.paint(Color::Keyword, "prot "); }
        else if v == 1 { self.p.paint(Color::Keyword, "priv "); }
    }

    // ======================================================================
    //  TYPES  source-faithful  (UNCHANGED)
    // ======================================================================

    fn _quals(self, ty: *Type) {
        type TQ = TypeQual::<Type>;
        var f = static_cast::<u8>(ty->flags);
        if (f & static_cast::<u8>(TQ::Flags::IsConst))    != 0 { self.p.paint(Color::Keyword, "const ");    }
        if (f & static_cast::<u8>(TQ::Flags::IsVolatile)) != 0 { self.p.paint(Color::Keyword, "volatile "); }
        if (f & static_cast::<u8>(TQ::Flags::IsAtomic))   != 0 { self.p.paint(Color::Keyword, "atomic ");   }
        if (f & static_cast::<u8>(TQ::Flags::IsUnsafe))   != 0 { self.p.paint(Color::Keyword, "unsafe ");   }
        if (f & static_cast::<u8>(TQ::Flags::IsEval))     != 0 { self.p.paint(Color::Keyword, "eval ");     }
        if (f & static_cast::<u8>(TQ::Flags::IsAsync))    != 0 { self.p.paint(Color::Keyword, "async ");    }
        if (f & static_cast::<u8>(TQ::Flags::IsYield))    != 0 { self.p.paint(Color::Keyword, "yield ");    }
        if (f & static_cast::<u8>(TQ::Flags::IsPanic))    != 0 { self.p.paint(Color::Keyword, "panic ");    }
    }

    fn src_type(self, ty: *Type) {
        if ty == &null    { self.p.paint(Color::Error, "<error>"); return; }
        if ty->is_error() { self.p.paint(Color::Error, "<error>"); return; }

        if isa::<ChainType>(ty)             { self._t_chain(cast::<ChainType>(ty));                       return; }
        if isa::<GenericParamType>(ty)      { self._t_generic_param(cast::<GenericParamType>(ty));        return; }
        if isa::<SubstGenericParamType>(ty) { self.src_type(cast::<SubstGenericParamType>(ty)->replacement); return; }
        if isa::<TypeOfType>(ty)            { self._quals(ty); self.p.paint(Color::Keyword, "typeof"); self.p.paint(Color::Punct, "(...)"); return; }
        if isa::<VariadicPackType>(ty)      { self.p.paint(Color::Punct, "..."); self.src_type(cast::<VariadicPackType>(ty)->param); return; }
        if isa::<PackExpansionType>(ty)     { self.src_type(cast::<PackExpansionType>(ty)->pattern); self.p.paint(Color::Punct, "..."); return; }
        if isa::<PointerType>(ty)           { self._quals(ty); self.p.paint(Color::Punct, "*"); self.src_type(cast::<PointerType>(ty)->pointee); return; }
        if isa::<NullableType>(ty)          { self._quals(ty); self.src_type(cast::<NullableType>(ty)->inner); self.p.paint(Color::Punct, "?"); return; }
        if isa::<TupleType>(ty)             { self._t_tuple(cast::<TupleType>(ty));                       return; }
        if isa::<FixedArrayType>(ty)        { self._t_fixed_array(cast::<FixedArrayType>(ty));            return; }
        if isa::<VectorType>(ty)            { self._quals(ty); self.p.paint(Color::Punct, "["); self.src_type(cast::<VectorType>(ty)->element); self.p.paint(Color::Punct, "]"); return; }
        if isa::<MapType>(ty)               { self._t_map(cast::<MapType>(ty));                           return; }
        if isa::<SetType>(ty)               { self._quals(ty); self.p.paint(Color::Punct, "{"); self.src_type(cast::<SetType>(ty)->element); self.p.paint(Color::Punct, "}"); return; }
        if isa::<SelfType>(ty)              { self._quals(ty); self.p.paint(Color::TypeName, "Self"); return; }
        if isa::<FunctionPointerType>(ty)   { self._t_fn_ptr(cast::<FunctionPointerType>(ty));            return; }
        if isa::<InferredType>(ty)          { self.p.paint(Color::Punct, "_");                           return; }
        if isa::<CXXLValueRefType>(ty)      { self._quals(ty); self.src_type(cast::<CXXLValueRefType>(ty)->referee); self.p.paint(Color::Punct, "&"); return; }
        if isa::<CXXRValueRefType>(ty)      { self._quals(ty); self.src_type(cast::<CXXRValueRefType>(ty)->referee); self.p.paint(Color::Punct, "&&"); return; }
        if isa::<OpaqueFFIType>(ty)         { self.p.paint(Color::TypeName, self.istr(cast::<OpaqueFFIType>(ty)->name)); return; }
        if isa::<TypeExpr>(ty)              { self._quals(ty); self.src_expr(cast::<TypeExpr>(ty)->expr); return; }

        self.p.paint(Color::Error, "<error>");
    }

    fn _t_chain(self, ty: *ChainType) {
        self._quals(ty);
        if ty->segments.is_empty() { self.p.paint(Color::Error, "<error>"); return; }
        for var i: usize = 0; i < ty->segments.size(); ++i {
            var seg = ty->segments.get(i);
            if seg->sep == ChainType::SegmentSeparator::ColonColon {
                self.p.paint(Color::Punct, "::");
            }
            if seg->name == &null { self.p.paint(Color::Error, "<error>"); continue; }
            self.p.paint(Color::TypeName, self.tok(seg->name->name));
            self._generic_args(seg->generic_args);
        }
    }

    fn _t_generic_param(self, ty: *GenericParamType) {
        self._quals(ty);
        if ty->is_pack { self.p.paint(Color::Punct, "..."); }
        if ty->param_name == &null { self.p.paint(Color::Error, "<error>"); return; }
        self.p.paint(Color::TypeName, self.tok(ty->param_name->name));
    }

    fn _t_tuple(self, ty: *TupleType) {
        self._quals(ty);
        self.p.paint(Color::Punct, "(");
        for var i: usize = 0; i < ty->elements.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            self.src_type(ty->elements[i]);
        }
        self.p.paint(Color::Punct, ")");
    }

    fn _t_fixed_array(self, ty: *FixedArrayType) {
        self._quals(ty);
        self.p.paint(Color::Punct, "[");
        self.src_type(ty->element);
        self.p.paint(Color::Punct, "; ");
        if (!ty->is_incomplete) && (ty->size_expr != &null) {
            self.src_expr(ty->size_expr);
        }
        self.p.paint(Color::Punct, "]");
    }

    fn _t_map(self, ty: *MapType) {
        self._quals(ty);
        self.p.paint(Color::Punct, "{");
        self.src_type(ty->key);
        self.p.paint(Color::Punct, ": ");
        self.src_type(ty->value);
        self.p.paint(Color::Punct, "}");
    }

    fn _t_fn_ptr(self, ty: *FunctionPointerType) {
        self._quals(ty);
        self.p.paint(Color::Keyword, "fn");
        self.p.paint(Color::Punct, "(");
        if ty->is_unprototyped {
            self.p.paint(Color::Punct, "...");
        } else {
            for var i: usize = 0; i < ty->params.size(); ++i {
                if i > 0 { self.p.paint(Color::Punct, ", "); }
                self.src_type(ty->params[i]);
            }
        }
        self.p.paint(Color::Punct, ")");
        if ty->return_type != &null {
            self.p.paint(Color::Punct, " -> ");
            self.src_type(ty->return_type);
        }
    }

    // ======================================================================
    //  EXPRESSIONS  source-faithful  (UNCHANGED)
    // ======================================================================

    fn src_expr(self, e: *Expr) {
        if e == &null    { self.p.paint(Color::Error, "<error>"); return; }
        if e->is_error() { self.p.paint(Color::Error, "<error>"); return; }

        if isa::<IntegerLiteralExpr>(e)   { self.p.paint(Color::Literal, cast::<IntegerLiteralExpr>(e)->get_text());   return; }
        if isa::<FloatingLiteralExpr>(e)  { self.p.paint(Color::Literal, cast::<FloatingLiteralExpr>(e)->get_text());  return; }
        if isa::<StringLiteralExpr>(e)    { self.p.paint(Color::Literal, cast::<StringLiteralExpr>(e)->get_text());    return; }
        if isa::<CharacterLiteralExpr>(e) { self.p.paint(Color::Literal, cast::<CharacterLiteralExpr>(e)->get_text()); return; }
        if isa::<BooleanLiteralExpr>(e)   { self.p.paint(Color::Literal, (("true") if (cast::<BooleanLiteralExpr>(e)->value) else ("false"))); return; }
        if isa::<NullLiteralExpr>(e)      { self.p.paint(Color::Literal, (("&null") if (cast::<NullLiteralExpr>(e)->is_ref) else ("null"))); return; }
        if isa::<NamedIdentExpr>(e)       { self._e_ident(cast::<NamedIdentExpr>(e));      return; }
        if isa::<ChainExpr>(e)            { self._chain(cast::<ChainExpr>(e));             return; }
        if isa::<CallExpr>(e)             { self._e_call(cast::<CallExpr>(e));             return; }
        if isa::<SubscriptExpr>(e)        { self._e_subscript(cast::<SubscriptExpr>(e));   return; }
        if isa::<UnaryOperatorExpr>(e)    { self._e_unary(cast::<UnaryOperatorExpr>(e));   return; }
        if isa::<BinaryOperatorExpr>(e)   { self._e_binary(cast::<BinaryOperatorExpr>(e)); return; }
        if isa::<AssignOperatorExpr>(e)   { self._e_assign(cast::<AssignOperatorExpr>(e)); return; }
        if isa::<ListLiteralExpr>(e)      { self._expr_list("[", "]", cast::<ListLiteralExpr>(e)->elements);  return; }
        if isa::<TupleLiteralExpr>(e)     { self._expr_list("(", ")", cast::<TupleLiteralExpr>(e)->elements); return; }
        if isa::<SetLiteralExpr>(e)       { self._expr_list("{", "}", cast::<SetLiteralExpr>(e)->elements);   return; }
        if isa::<MapLiteralExpr>(e)       { self._e_map(cast::<MapLiteralExpr>(e));               return; }
        if isa::<NamedInitializerExpr>(e) { self._e_named_init(cast::<NamedInitializerExpr>(e));  return; }
        if isa::<AnonInitializerExpr>(e)  { self._e_anon_init(cast::<AnonInitializerExpr>(e));    return; }
        if isa::<IfExpr>(e)               { self._e_if(cast::<IfExpr>(e));         return; }
        if isa::<TryCatchExpr>(e)         { self._e_try(cast::<TryCatchExpr>(e));  return; }
        if isa::<MatchExpr>(e)            { self._e_match(cast::<MatchExpr>(e));   return; }
        if isa::<RangeExpr>(e)            { self._e_range(cast::<RangeExpr>(e));   return; }
        if isa::<ClosureExpr>(e)          { self._e_closure(cast::<ClosureExpr>(e)); return; }
        if isa::<AwaitExpr>(e)            { self._kw_operand("await ",  cast::<AwaitExpr>(e)->operand);  return; }
        if isa::<SpawnExpr>(e)            { self._kw_operand("spawn ",  cast::<SpawnExpr>(e)->operand);  return; }
        if isa::<ThreadExpr>(e)           { self._kw_operand("thread ", cast::<ThreadExpr>(e)->operand); return; }
        if isa::<EvalExpr>(e)             { self._kw_operand("eval ",   cast::<EvalExpr>(e)->operand);   return; }
        if isa::<UnsafeExpr>(e)           { self._kw_operand("unsafe ", cast::<UnsafeExpr>(e)->operand); return; }
        if isa::<SizeOfExpr>(e)           { self._builtin_type("sizeof",  cast::<SizeOfExpr>(e)->type_arg);  return; }
        if isa::<AlignOfExpr>(e)          { self._builtin_type("alignof", cast::<AlignOfExpr>(e)->type_arg); return; }
        if isa::<TypeOfExpr>(e)           { self._e_typeof(cast::<TypeOfExpr>(e)); return; }
        if isa::<DeleteExpr>(e)           { self._e_delete(cast::<DeleteExpr>(e)); return; }
        if isa::<PackExpansionExpr>(e)    { self.src_expr(cast::<PackExpansionExpr>(e)->operand); self.p.paint(Color::Punct, "..."); return; }
        if isa::<TypeCastExpr>(e)         { self._e_cast(cast::<TypeCastExpr>(e));        return; }
        if isa::<ImplConformanceExpr>(e)  { self._e_impl(cast::<ImplConformanceExpr>(e)); return; }
        if isa::<DerivesRelationExpr>(e)  { self._e_derives(cast::<DerivesRelationExpr>(e)); return; }
        if isa::<ImplicitBoundaryCastExpr>(e) { self.src_expr(cast::<ImplicitBoundaryCastExpr>(e)->original); return; }

        self.p.paint(Color::Error, "<error>");
    }

    fn _e_ident(self, e: *NamedIdentExpr) {
        self.p.paint(Color::Ident, self.tok(e->name));
        self._generic_args(e->generic_args);
    }

    fn _chain(self, e: *ChainExpr) {
        if e->base != &null { self.src_expr(e->base); }
        for var i: usize = 0; i < e->steps.size(); ++i {
            var s = e->steps.get(i);
            self._access_op(s->access_kind);
            if s->name != &null {
                self.p.paint(Color::Ident, self.tok(s->name->name));
            } else {
                self.p.paint(Color::Error, "<error>");
            }
            self._generic_args(s->generic_args);
        }
    }

    fn _e_call(self, e: *CallExpr) {
        self.src_expr(e->callee);
        self._expr_list("(", ")", e->args);
    }

    fn _e_subscript(self, e: *SubscriptExpr) {
        self.src_expr(e->base);
        self.p.paint(Color::Punct, "[");
        self.src_expr(e->index);
        self.p.paint(Color::Punct, "]");
    }

    fn _e_unary(self, e: *UnaryOperatorExpr) {
        var opr = self.tok(e->op_token);
        if e->is_prefix() {
            self.p.paint(Color::Operator, opr);
            self.src_expr(e->operand);
        } else {
            self.src_expr(e->operand);
            self.p.paint(Color::Operator, opr);
        }
    }

    fn _e_binary(self, e: *BinaryOperatorExpr) {
        self.src_expr(e->lhs);
        self.p.put(" ");
        self.p.paint(Color::Operator, self.tok(e->op_token));
        self.p.put(" ");
        self.src_expr(e->rhs);
    }

    fn _e_assign(self, e: *AssignOperatorExpr) {
        self.src_expr(e->lhs);
        self.p.put(" ");
        self.p.paint(Color::Operator, self.tok(e->op_token));
        self.p.put(" ");
        self.src_expr(e->rhs);
    }

    fn _e_map(self, e: *MapLiteralExpr) {
        self.p.paint(Color::Punct, "{");
        for var i: usize = 0; i < e->entries.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            var en = e->entries.get(i);
            self.src_expr(en->key);
            self.p.paint(Color::Punct, ": ");
            self.src_expr(en->value);
        }
        self.p.paint(Color::Punct, "}");
    }

    fn _e_named_init(self, e: *NamedInitializerExpr) {
        self.src_expr(e->type_expr);
        self.p.paint(Color::Punct, " { ");
        for var i: usize = 0; i < e->fields.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            var fld = e->fields.get(i);
            self.p.paint(Color::Ident, self.tok(fld->name));
            self.p.paint(Color::Punct, ": ");
            self.src_expr(fld->value);
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _e_anon_init(self, e: *AnonInitializerExpr) {
        self.p.paint(Color::Punct, "{ ");
        for var i: usize = 0; i < e->fields.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            var fld = e->fields.get(i);
            self.p.paint(Color::Punct, ".");
            self.p.paint(Color::Ident, self.tok(fld->name));
            self.p.paint(Color::Punct, ": ");
            self.src_expr(fld->value);
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _e_if(self, e: *IfExpr) {
        self.p.paint(Color::Keyword, "if ");
        self.src_expr(e->condition);
        self.p.paint(Color::Punct, " { ");
        self.src_expr(e->then_expr);
        self.p.paint(Color::Punct, " }");
        for var i: usize = 0; i < e->else_ifs.size(); ++i {
            var arm = e->else_ifs.get(i);
            self.p.paint(Color::Keyword, " else if ");
            self.src_expr(arm->condition);
            self.p.paint(Color::Punct, " { ");
            self.src_expr(arm->body);
            self.p.paint(Color::Punct, " }");
        }
        self.p.paint(Color::Keyword, " else ");
        self.p.paint(Color::Punct, "{ ");
        self.src_expr(e->else_expr);
        self.p.paint(Color::Punct, " }");
    }

    fn _e_try(self, e: *TryCatchExpr) {
        self.p.paint(Color::Keyword, "try ");
        self.p.paint(Color::Punct, "{ ");
        self.src_expr(e->try_expr);
        self.p.paint(Color::Punct, " }");
        for var i: usize = 0; i < e->catch_arms.size(); ++i {
            var arm = e->catch_arms.get(i);
            self.p.paint(Color::Keyword, " catch");
            if arm->has_binding {
                self.p.put(" ");
                if arm->is_const { self.p.paint(Color::Keyword, "const "); }
                if arm->binding != &null { self.p.paint(Color::Ident, self.tok(arm->binding->name)); }
                if arm->filter != &null {
                    self.p.paint(Color::Punct, ": ");
                    self.src_type(arm->filter);
                }
            }
            self.p.paint(Color::Punct, " { ");
            self.src_expr(arm->body);
            self.p.paint(Color::Punct, " }");
        }
    }

    fn _e_match(self, e: *MatchExpr) {
        self.p.paint(Color::Keyword, "match ");
        self.src_expr(e->scrutinee);
        self.p.paint(Color::Punct, " { ");
        for var i: usize = 0; i < e->cases.size(); ++i {
            if i > 0 { self.p.put(" "); }
            self._src_match_case(e->cases.get(i));
        }
        self.p.paint(Color::Punct, " }");
    }

    /// Source form of one match case. Expr-form keeps the value in
    /// `expression`; stmt-form keeps it in `body`. We render whichever is set.
    fn _src_match_case(self, mc: *MatchCase) {
        if mc->is_default {
            self.p.paint(Color::Keyword, "default ");
        } else {
            self.p.paint(Color::Keyword, "case ");
            for var i: usize = 0; i < mc->patterns.size(); ++i {
                if i > 0 { self.p.paint(Color::Punct, ", "); }
                self.src_pattern(mc->patterns[i]);
            }
            if mc->guard != &null {
                self.p.paint(Color::Keyword, " where ");
                self.src_expr(mc->guard);
            }
            self.p.put(" ");
        }
        if mc->expression != &null {
            self.p.paint(Color::Punct, "{ ");
            self.src_expr(mc->expression);
            self.p.paint(Color::Punct, " }");
        } else if mc->body != &null {
            self.src_stmt(static_cast::<*Stmt>(mc->body));
        } else {
            self.p.paint(Color::Punct, "{}");
        }
    }

    fn _e_range(self, e: *RangeExpr) {
        if e->begin != &null { self.src_expr(e->begin); }
        self.p.paint(Color::Operator, (("..=") if (e->is_inclusive) else ("..")));
        if e->end != &null { self.src_expr(e->end); }
    }

    fn _e_closure(self, e: *ClosureExpr) {
        self.p.paint(Color::Keyword, "fn");
        self.p.paint(Color::Punct, "(...)");
        if e->return_type != &null {
            self.p.paint(Color::Punct, " -> ");
            self.src_type(e->return_type);
        }
        self.p.paint(Color::Punct, " { ");
        self.src_expr(e->body);
        self.p.paint(Color::Punct, " }");
    }

    fn _kw_operand(self, kw: string, operand: *Expr) {
        self.p.paint(Color::Keyword, kw);
        self.src_expr(operand);
    }

    fn _builtin_type(self, kw: string, t: *Type) {
        self.p.paint(Color::Keyword, kw);
        self.p.paint(Color::Punct, "(");
        self.src_type(t);
        self.p.paint(Color::Punct, ")");
    }

    fn _e_typeof(self, e: *TypeOfExpr) {
        self.p.paint(Color::Keyword, "typeof");
        self.p.paint(Color::Punct, "(");
        self.src_expr(e->operand);
        self.p.paint(Color::Punct, ")");
    }

    fn _e_delete(self, e: *DeleteExpr) {
        self.p.paint(Color::Keyword, "delete ");
        if e->is_array { self.p.paint(Color::Punct, "[] "); }
        self.src_expr(e->operand);
    }

    fn _e_cast(self, e: *TypeCastExpr) {
        self.src_expr(e->operand);
        self.p.paint(Color::Keyword, " as ");
        if e->is_unsafe { self.p.paint(Color::Keyword, "unsafe "); }
        self.src_type(e->target);
    }

    fn _e_impl(self, e: *ImplConformanceExpr) {
        self.src_type(e->subject);
        self.p.paint(Color::Keyword, " impl ");
        self.src_type(e->inter);
    }

    fn _e_derives(self, e: *DerivesRelationExpr) {
        self.src_type(e->subject);
        self.p.paint(Color::Keyword, " derives ");
        self.src_type(e->base);
    }

    // ======================================================================
    //  PATTERNS  source-faithful  (UNCHANGED)
    // ======================================================================

    fn src_pattern(self, pat: *Pattern) {
        if pat == &null    { self.p.paint(Color::Error, "<error>"); return; }
        if pat->is_error() { self.p.paint(Color::Error, "<error>"); return; }

        if isa::<WildcardPattern>(pat)              { self.p.paint(Color::Punct, "_"); return; }
        if isa::<LiteralPattern>(pat)               { self.src_expr(cast::<LiteralPattern>(pat)->value); return; }
        if isa::<BindingPattern>(pat)               { self._p_binding(cast::<BindingPattern>(pat));            return; }
        if isa::<TupleDestructurePattern>(pat)      { self._p_tuple(cast::<TupleDestructurePattern>(pat));     return; }
        if isa::<ConstructorPattern>(pat)           { self._p_ctor(cast::<ConstructorPattern>(pat));           return; }
        if isa::<UnresolvedConstructorPattern>(pat) { self._p_uctor(cast::<UnresolvedConstructorPattern>(pat)); return; }
        if isa::<AlternationPattern>(pat)           { self._p_alt(cast::<AlternationPattern>(pat));            return; }
        if isa::<RangePattern>(pat)                 { self._p_range(cast::<RangePattern>(pat));                return; }
        if isa::<SlicePattern>(pat)                 { self._p_slice(cast::<SlicePattern>(pat));                return; }

        self.p.paint(Color::Error, "<error>");
    }

    fn _p_binding(self, pat: *BindingPattern) {
        self.p.paint(Color::Keyword, (("const ") if (pat->is_const) else ("var ")));
        self.p.paint(Color::Ident, self.tok(pat->name));
        if pat->type_ != &null {
            self.p.paint(Color::Punct, ": ");
            self.src_type(pat->type_);
        }
    }

    fn _p_tuple(self, pat: *TupleDestructurePattern) {
        self.p.paint(Color::Punct, "(");
        self._pat_list(pat->elements);
        self.p.paint(Color::Punct, ")");
    }

    fn _p_ctor(self, pat: *ConstructorPattern) {
        if pat->is_dotted {
            self.p.paint(Color::Punct, ".");
            self.p.paint(Color::Ident, self.tok(pat->dotted_name));
        } else if pat->head != &null {
            self.src_expr(pat->head);
        }
        if pat->has_parens {
            self.p.paint(Color::Punct, "(");
            self._pat_list(pat->subpatterns);
            self.p.paint(Color::Punct, ")");
        }
    }

    fn _p_uctor(self, pat: *UnresolvedConstructorPattern) {
        if pat->head != &null { self.src_expr(pat->head); }
        if pat->has_parens {
            self.p.paint(Color::Punct, "(");
            self._pat_list(pat->subpatterns);
            self.p.paint(Color::Punct, ")");
        }
    }

    fn _p_alt(self, pat: *AlternationPattern) {
        for var i: usize = 0; i < pat->alternatives.size(); ++i {
            if i > 0 { self.p.paint(Color::Operator, " | "); }
            self.src_pattern(pat->alternatives[i]);
        }
    }

    fn _p_range(self, pat: *RangePattern) {
        if pat->lo != &null { self.src_expr(pat->lo); }
        self.p.paint(Color::Operator, (("..=") if (pat->is_inclusive) else ("..")));
        if pat->hi != &null { self.src_expr(pat->hi); }
    }

    fn _p_slice(self, pat: *SlicePattern) {
        self.p.paint(Color::Punct, "[");
        var first = true;
        for var i: usize = 0; i < pat->prefix.size(); ++i {
            if !first { self.p.paint(Color::Punct, ", "); }
            self.src_pattern(pat->prefix[i]);
            first = false;
        }
        if pat->has_rest {
            if !first { self.p.paint(Color::Punct, ", "); }
            self.p.paint(Color::Punct, "..");
            if pat->rest_binding != &null { self.src_pattern(pat->rest_binding); }
            first = false;
        }
        for var i: usize = 0; i < pat->suffix.size(); ++i {
            if !first { self.p.paint(Color::Punct, ", "); }
            self.src_pattern(pat->suffix[i]);
            first = false;
        }
        self.p.paint(Color::Punct, "]");
    }

    // ======================================================================
    //  BINDINGS  shared by destructure / for / context (source path)  (UNCHANGED)
    // ======================================================================

    fn _src_binding(self, b: *Binding) {
        if b->is_explicit {
            self.p.paint(Color::Keyword, (("const ") if (b->is_const) else ("var ")));
        }
        var sh = static_cast::<u8>(b->shorthand);
        if (sh & static_cast::<u8>(BindingShorthand::Unsafe))  != 0 { self.p.paint(Color::Keyword, "unsafe "); }
        if (sh & static_cast::<u8>(BindingShorthand::Pointer)) != 0 { self.p.paint(Color::Punct, "*"); }
        if b->is_discard {
            self.p.paint(Color::Punct, "_");
        } else if b->name != &null {
            self.p.paint(Color::Ident, self.tok(b->name->name));
        } else {
            self.p.paint(Color::Error, "<error>");
        }
        if (sh & static_cast::<u8>(BindingShorthand::Nullable)) != 0 { self.p.paint(Color::Punct, "?"); }
    }

    fn _src_binding_list(self, bs: FrozenList::<Binding>) {
        for var i: usize = 0; i < bs.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            self._src_binding(bs.get(i));
        }
    }

    // ======================================================================
    //  STATEMENTS  source-faithful  (UNCHANGED)
    // ======================================================================

    fn src_stmt(self, stmt: *Stmt) {
        if stmt == &null    { self.p.paint(Color::Error, "<error>"); return; }
        if stmt->is_error() { self.p.paint(Color::Error, "<error>"); return; }

        if isa::<CompoundStmt>(stmt)          { self._s_compound(cast::<CompoundStmt>(stmt));         return; }
        if isa::<ExpressionStmt>(stmt)        { self.src_expr(cast::<ExpressionStmt>(stmt)->expr);    return; }
        if isa::<DeclStmt>(stmt)              { self.src_decl(cast::<DeclStmt>(stmt)->decl);          return; }
        if isa::<ReturnStmt>(stmt)            { self._s_return(cast::<ReturnStmt>(stmt));             return; }
        if isa::<BreakStmt>(stmt)             { self._s_break(cast::<BreakStmt>(stmt));               return; }
        if isa::<ContinueStmt>(stmt)          { self._s_continue(cast::<ContinueStmt>(stmt));         return; }
        if isa::<PanicStmt>(stmt)             { self.p.paint(Color::Keyword, "panic "); self.src_expr(cast::<PanicStmt>(stmt)->payload); return; }
        if isa::<YieldStmt>(stmt)             { self.p.paint(Color::Keyword, "yield "); self.src_expr(cast::<YieldStmt>(stmt)->value); return; }
        if isa::<RuntimeAssertStmt>(stmt)     { self._s_assert(cast::<RuntimeAssertStmt>(stmt));      return; }
        if isa::<StaticAssertStmt>(stmt)      { self._s_static_assert(cast::<StaticAssertStmt>(stmt)); return; }
        if isa::<LabelIntrinsicStmt>(stmt)    { self._s_label_intrinsic(cast::<LabelIntrinsicStmt>(stmt)); return; }
        if isa::<JumpIntrinsicStmt>(stmt)     { self._s_jump_intrinsic(cast::<JumpIntrinsicStmt>(stmt)); return; }
        if isa::<ConditionalStmt>(stmt)       { self._s_conditional(cast::<ConditionalStmt>(stmt));   return; }
        if isa::<WhileLoopStmt>(stmt)         { self._s_while(cast::<WhileLoopStmt>(stmt));           return; }
        if isa::<LoopStmt>(stmt)              { self.p.paint(Color::Keyword, "loop "); self.src_stmt(static_cast::<*Stmt>(cast::<LoopStmt>(stmt)->body)); return; }
        if isa::<RangedForStmt>(stmt)         { self._s_ranged_for(cast::<RangedForStmt>(stmt));      return; }
        if isa::<IndexedForStmt>(stmt)        { self._s_indexed_for(cast::<IndexedForStmt>(stmt));    return; }
        if isa::<MatchStmt>(stmt)             { self._s_match(cast::<MatchStmt>(stmt));               return; }
        if isa::<LabeledStmt>(stmt)           { self._s_labeled(cast::<LabeledStmt>(stmt));           return; }
        if isa::<TryCatchStmt>(stmt)          { self._s_try(cast::<TryCatchStmt>(stmt));              return; }
        if isa::<FinallyStmt>(stmt)           { self.p.paint(Color::Keyword, "finally "); self.src_stmt(static_cast::<*Stmt>(cast::<FinallyStmt>(stmt)->body)); return; }
        if isa::<UnsafeBlockStmt>(stmt)       { self.p.paint(Color::Keyword, "unsafe "); self.src_stmt(static_cast::<*Stmt>(cast::<UnsafeBlockStmt>(stmt)->body)); return; }
        if isa::<ContextBindingStmt>(stmt)    { self._s_context(cast::<ContextBindingStmt>(stmt));    return; }
        if isa::<DestructuringDeclStmt>(stmt) { self._s_destructure(cast::<DestructuringDeclStmt>(stmt)); return; }
        if isa::<InlineBlockStmt>(stmt)       { self._s_inline(cast::<InlineBlockStmt>(stmt));        return; }
        if isa::<EvalBlockStmt>(stmt)         { self.p.paint(Color::Keyword, "eval"); self.p.paint(Color::Punct, " { ... }"); return; }

        self.p.paint(Color::Error, "<error>");
    }

    fn _s_compound(self, stmt: *CompoundStmt) {
        if stmt->body.is_empty() { self.p.paint(Color::Punct, "{}"); return; }
        self.p.paint(Color::Punct, "{ ");
        for var i: usize = 0; i < stmt->body.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, "; "); }
            self.src_stmt(stmt->body[i]);
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _s_return(self, stmt: *ReturnStmt) {
        self.p.paint(Color::Keyword, "return");
        if stmt->value != &null {
            self.p.put(" ");
            self.src_expr(stmt->value);
        }
    }

    fn _s_break(self, stmt: *BreakStmt) {
        self.p.paint(Color::Keyword, "break");
        if stmt->has_label {
            self.p.put(" ");
            self.p.paint(Color::Ident, self.tok(stmt->label));
        }
    }

    fn _s_continue(self, stmt: *ContinueStmt) {
        self.p.paint(Color::Keyword, "continue");
        if stmt->has_label {
            self.p.put(" ");
            self.p.paint(Color::Ident, self.tok(stmt->label));
        }
    }

    fn _s_assert(self, stmt: *RuntimeAssertStmt) {
        self.p.paint(Color::Keyword, "assert ");
        self.src_expr(stmt->condition);
        if stmt->message != &null {
            self.p.paint(Color::Punct, ", ");
            self.src_expr(stmt->message);
        }
    }

    fn _s_static_assert(self, stmt: *StaticAssertStmt) {
        self.p.paint(Color::Keyword, "assert static ");
        self.src_expr(stmt->condition);
        if stmt->message != &null {
            self.p.paint(Color::Punct, ", ");
            self.src_expr(stmt->message);
        }
    }

    fn _s_label_intrinsic(self, stmt: *LabelIntrinsicStmt) {
        self.p.paint(Color::Keyword, "label");
        self.p.paint(Color::Punct, "!(");
        self.p.paint(Color::Ident, self.tok(stmt->name));
        self.p.paint(Color::Punct, ")");
    }

    fn _s_jump_intrinsic(self, stmt: *JumpIntrinsicStmt) {
        self.p.paint(Color::Keyword, "jump");
        self.p.paint(Color::Punct, "!(");
        self.p.paint(Color::Ident, self.tok(stmt->target));
        self.p.paint(Color::Punct, ")");
    }

    fn _s_conditional(self, stmt: *ConditionalStmt) {
        self.p.paint(Color::Keyword, "if ");
        self.src_expr(stmt->cond);
        self.p.put(" ");
        self.src_stmt(static_cast::<*Stmt>(stmt->then_));
        if stmt->else_ != &null {
            self.p.paint(Color::Keyword, " else ");
            self.src_stmt(stmt->else_);
        }
    }

    fn _s_while(self, stmt: *WhileLoopStmt) {
        self.p.paint(Color::Keyword, "while ");
        self.src_expr(stmt->cond);
        self.p.put(" ");
        self.src_stmt(static_cast::<*Stmt>(stmt->body));
    }

    fn _s_ranged_for(self, stmt: *RangedForStmt) {
        self.p.paint(Color::Keyword, "for ");
        if stmt->is_eval { self.p.paint(Color::Keyword, "eval "); }
        self._src_binding_list(stmt->bindings);
        self.p.paint(Color::Keyword, " in ");
        self.src_expr(stmt->iterable);
        self.p.put(" ");
        self.src_stmt(static_cast::<*Stmt>(stmt->body));
    }

    fn _s_indexed_for(self, stmt: *IndexedForStmt) {
        self.p.paint(Color::Keyword, "for ");
        if stmt->is_eval { self.p.paint(Color::Keyword, "eval "); }
        self.src_stmt(stmt->init);
        self.p.paint(Color::Punct, "; ");
        self.src_expr(stmt->cond);
        self.p.paint(Color::Punct, "; ");
        self.src_expr(stmt->update);
        self.p.put(" ");
        self.src_stmt(static_cast::<*Stmt>(stmt->body));
    }

    fn _s_match(self, stmt: *MatchStmt) {
        self.p.paint(Color::Keyword, "match ");
        self.src_expr(stmt->scrutinee);
        self.p.paint(Color::Punct, " { ");
        for var i: usize = 0; i < stmt->cases.size(); ++i {
            if i > 0 { self.p.put(" "); }
            self._src_match_case(stmt->cases.get(i));
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _s_labeled(self, stmt: *LabeledStmt) {
        self.p.paint(Color::Ident, self.tok(stmt->label));
        self.p.paint(Color::Punct, ": ");
        self.src_stmt(stmt->inner);
    }

    fn _s_try(self, stmt: *TryCatchStmt) {
        self.p.paint(Color::Keyword, "try ");
        self.src_stmt(static_cast::<*Stmt>(stmt->try_body));
        for var i: usize = 0; i < stmt->arms.size(); ++i {
            var arm = stmt->arms.get(i);
            self.p.paint(Color::Keyword, " catch");
            if arm->binding != &null {
                self.p.put(" ");
                self.p.paint(Color::Ident, self.tok(arm->binding->name));
                if arm->filter != &null {
                    self.p.paint(Color::Punct, ": ");
                    self.src_type(arm->filter);
                }
            }
            self.p.put(" ");
            self.src_stmt(static_cast::<*Stmt>(arm->body));
        }
    }

    fn _s_context(self, stmt: *ContextBindingStmt) {
        self.src_expr(stmt->value);
        self.p.paint(Color::Keyword, " as ");
        if stmt->bindings.size() == 1 {
            self._src_binding_list(stmt->bindings);
        } else {
            self.p.paint(Color::Punct, "(");
            self._src_binding_list(stmt->bindings);
            self.p.paint(Color::Punct, ")");
        }
        self.p.put(" ");
        self.src_stmt(static_cast::<*Stmt>(stmt->body));
    }

    fn _s_destructure(self, stmt: *DestructuringDeclStmt) {
        var is_tuple = (stmt->kind_ == DestructureKind::Tuple);
        self.p.paint(Color::Keyword, (("const ") if (stmt->leading_is_const) else ("var ")));
        self.p.paint(Color::Punct, (("(") if (is_tuple) else ("{")));
        self._src_binding_list(stmt->bindings);
        self.p.paint(Color::Punct, ((")") if (is_tuple) else ("}")));
        self.p.paint(Color::Punct, " = ");
        self.src_expr(stmt->value);
    }

    fn _s_inline(self, stmt: *InlineBlockStmt) {
        self.p.paint(Color::Keyword, "inline ");
        self.p.paint(Color::Literal, f"\"{self._inline_lang(stmt->lang)}\"");
        self.p.paint(Color::Punct, " { ... }");
    }

    fn _inline_lang(self, lang: InlineLang) -> string {
        if lang == InlineLang::Asm    { return "asm";  }
        if lang == InlineLang::C      { return "c";    }
        if lang == InlineLang::Cpp    { return "c++";  }
        if lang == InlineLang::Cuda   { return "cuda"; }
        if lang == InlineLang::Hip    { return "hip";  }
        if lang == InlineLang::OpenCL { return "opencl"; }
        if lang == InlineLang::Hlsl   { return "hlsl"; }
        if lang == InlineLang::Metal  { return "metal"; }
        if lang == InlineLang::SpirV  { return "spirv"; }
        if lang == InlineLang::Wgsl   { return "wgsl"; }
        if lang == InlineLang::Glsl   { return "glsl"; }
        if lang == InlineLang::Kairo  { return "kairo"; }
        return "c++";
    }

    // ======================================================================
    //  DECLARATIONS  source-faithful  (UNCHANGED)
    // ======================================================================

    fn src_decl(self, decl: *Decl) {
        if decl == &null    { self.p.paint(Color::Error, "<error>"); return; }
        if decl->is_error() { self.p.paint(Color::Error, "<error>"); return; }

        if isa::<FunctionDecl>(decl)        { self._d_function(cast::<FunctionDecl>(decl));         return; }
        if isa::<VariableDecl>(decl)        { self._d_variable(cast::<VariableDecl>(decl));         return; }
        if isa::<FieldDecl>(decl)           { self._d_field(cast::<FieldDecl>(decl));               return; }
        if isa::<ParamDecl>(decl)           { self._d_param(cast::<ParamDecl>(decl));               return; }
        if isa::<GenericParamDecl>(decl)    { self._d_generic_param(cast::<GenericParamDecl>(decl)); return; }
        if isa::<StructDecl>(decl)          { self._d_struct(cast::<StructDecl>(decl));             return; }
        if isa::<ClassDecl>(decl)           { self._d_class(cast::<ClassDecl>(decl));               return; }
        if isa::<InterfaceDecl>(decl)       { self._d_interface(cast::<InterfaceDecl>(decl));       return; }
        if isa::<ExtensionDecl>(decl)       { self._d_extension(cast::<ExtensionDecl>(decl));       return; }
        if isa::<EnumDecl>(decl)            { self._d_enum(cast::<EnumDecl>(decl));                 return; }
        if isa::<EnumVariantDecl>(decl)     { self._d_enum_variant(cast::<EnumVariantDecl>(decl));  return; }
        if isa::<UnionDecl>(decl)           { self._d_union(cast::<UnionDecl>(decl));               return; }
        if isa::<TypeAliasDecl>(decl)       { self._d_type_alias(cast::<TypeAliasDecl>(decl));      return; }
        if isa::<ModuleDecl>(decl)          { self._d_module(cast::<ModuleDecl>(decl));             return; }
        if isa::<ImportDecl>(decl)          { self._d_import(cast::<ImportDecl>(decl));             return; }
        if isa::<VisibilityGroupDecl>(decl) { self._d_vis_group(cast::<VisibilityGroupDecl>(decl)); return; }
        if isa::<EvalBlockDecl>(decl)       { self._d_eval_block(cast::<EvalBlockDecl>(decl));      return; }
        if isa::<TestDecl>(decl)            { self._d_test(cast::<TestDecl>(decl));                 return; }
        if isa::<MacroDecl>(decl)           { self._d_macro(cast::<MacroDecl>(decl));               return; }
        if isa::<ProcedureMacroDecl>(decl)  { self._d_proc_macro(cast::<ProcedureMacroDecl>(decl)); return; }

        self.p.paint(Color::Error, "<error>");
    }

    // -- shared decl pieces -------------------------------------------------

    fn _generic_params(self, gps: FrozenList::<*GenericParamDecl>) {
        if gps.is_empty() { return; }
        self.p.paint(Color::Punct, "<");
        for var i: usize = 0; i < gps.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            self._d_generic_param(gps[i]);
        }
        self.p.paint(Color::Punct, ">");
    }

    fn _requires(self, req: *Expr) {
        if req == &null { return; }
        self.p.paint(Color::Keyword, " requires ");
        self.src_expr(req);
    }

    fn _inherit_list(self, kw: string, edges: FrozenList::<InheritEdge>) {
        if edges.is_empty() { return; }
        self.p.put(" ");
        self.p.paint(Color::Keyword, kw);
        self.p.put(" ");
        for var i: usize = 0; i < edges.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            var e = edges.get(i);
            if e->is_virtual { self.p.paint(Color::Keyword, "virtual "); }
            self._vis(e->visibility);
            self.src_type(e->base);
        }
    }

    /// Brace member body: fields then methods, "; "-separated on one line.
    /// NOTE: source path only. The DEBUG tree path walks dc_decls instead.
    fn _member_body(self, fields: FrozenList::<*FieldDecl>, methods: FrozenList::<*FunctionDecl>) {
        if fields.is_empty() && methods.is_empty() { self.p.paint(Color::Punct, " {}"); return; }
        self.p.paint(Color::Punct, " { ");
        var first = true;
        for var i: usize = 0; i < fields.size(); ++i {
            if !first { self.p.paint(Color::Punct, "; "); }
            self._d_field(fields[i]);
            first = false;
        }
        for var i: usize = 0; i < methods.size(); ++i {
            if !first { self.p.paint(Color::Punct, "; "); }
            self._d_function(methods[i]);
            first = false;
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _storage_kw(self, s: StorageClass) -> string {
        if s == StorageClass::Const  { return "const";  }
        if s == StorageClass::Static { return "static"; }
        if s == StorageClass::Eval   { return "eval";   }
        return "var";
    }

    // -- FunctionDecl -------------------------------------------------------

    fn _fn_modifiers(self, fd: *FunctionDecl) {
        if fd->is_const()  { self.p.paint(Color::Keyword, " const");  }
        if (static_cast::<u16>(fd->modifiers) & static_cast::<u16>(FnModifier::IsVolatile)) != 0 {
            self.p.paint(Color::Keyword, " volatile");
        }
        if fd->is_unsafe() { self.p.paint(Color::Keyword, " unsafe"); }
        if fd->is_eval()   { self.p.paint(Color::Keyword, " eval");   }
        if fd->is_async()  { self.p.paint(Color::Keyword, " async");  }
        if fd->is_final()  { self.p.paint(Color::Keyword, " final");  }
        if fd->is_panic()  { self.p.paint(Color::Keyword, " panic");  }
        if fd->is_inline() { self.p.paint(Color::Keyword, " inline"); }
    }

    fn _param_list(self, params: FrozenList::<*ParamDecl>, is_variadic: bool) {
        self.p.paint(Color::Punct, "(");
        for var i: usize = 0; i < params.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            if is_variadic && (i == params.size() - 1) && (!params[i]->is_self) {
                self.p.paint(Color::Punct, "...");
            }
            self._d_param(params[i]);
        }
        self.p.paint(Color::Punct, ")");
    }

    fn _fn_body(self, fd: *FunctionDecl) {
        if      fd->body_kind == FnBodyKind::Default { self.p.paint(Color::Punct, " = "); self.p.paint(Color::Keyword, "default"); }
        else if fd->body_kind == FnBodyKind::Delete  { self.p.paint(Color::Punct, " = "); self.p.paint(Color::Keyword, "delete");  }
        else if fd->body_kind == FnBodyKind::Virtual { self.p.paint(Color::Punct, " = "); self.p.paint(Color::Keyword, "virtual"); }
        else if fd->body_kind == FnBodyKind::Expr    { self.p.paint(Color::Punct, " = "); self.src_expr(fd->body_expr); }
        else if fd->body_kind == FnBodyKind::Block   { self.p.put(" "); self.src_stmt(static_cast::<*Stmt>(fd->body_block)); }
        // FnBodyKind::None: signature only, nothing trailing.
    }

    fn _d_function(self, fd: *FunctionDecl) {
        if      fd->abi == AbiKind::Static   { self.p.paint(Color::Keyword, "static ");   }
        else if fd->abi == AbiKind::Virtual  { self.p.paint(Color::Keyword, "virtual ");  }
        else if fd->abi == AbiKind::Override { self.p.paint(Color::Keyword, "override "); }
        else if fd->abi == AbiKind::FfiC     { self.p.paint(Color::Keyword, "ffi "); self.p.paint(Color::Literal, "\"c\""); self.p.put(" "); }
        else if fd->abi == AbiKind::FfiCpp   { self.p.paint(Color::Keyword, "ffi "); self.p.paint(Color::Literal, "\"c++\""); self.p.put(" "); }

        if fd->transfer == TransferKind::Copy { self.p.paint(Color::Attr, "@copy "); }
        if fd->transfer == TransferKind::Move { self.p.paint(Color::Attr, "@move "); }

        self.p.paint(Color::Keyword, "fn");
        self._generic_params(fd->generic_params);
        self.p.put(" ");

        if fd->qualifier != &null {
            self.src_expr(fd->qualifier);
            self.p.paint(Color::Punct, "::");
        }
        if fd->is_operator {
            self.p.paint(Color::Keyword, "op ");
            self.p.paint(Color::Operator, self.tok(fd->op_token));
        } else {
            self.p.paint(Color::Ident, self.tok(fd->name));
        }

        self._param_list(fd->params, fd->is_variadic);
        self._fn_modifiers(fd);

        if fd->is_noreturn {
            self.p.paint(Color::Punct, " -> ");
            self.p.paint(Color::Operator, "!");
        } else if fd->return_type != &null {
            self.p.paint(Color::Punct, " -> ");
            self.src_type(fd->return_type);
        }

        self._requires(fd->requires_clause);
        self._fn_body(fd);
    }

    // -- VariableDecl / FieldDecl / ParamDecl -------------------------------

    fn _d_variable(self, vd: *VariableDecl) {
        self.p.paint(Color::Keyword, self._storage_kw(vd->storage));
        self.p.put(" ");
        self.p.paint(Color::Ident, self.tok(vd->name));
        if vd->type_ != &null {
            self.p.paint(Color::Punct, ": ");
            self.src_type(vd->type_);
        }
        if vd->init != &null {
            self.p.paint(Color::Punct, " = ");
            self.src_expr(vd->init);
        }
    }

    fn _d_field(self, fd: *FieldDecl) {
        if fd->is_mutable { self.p.paint(Color::Keyword, "mutable "); }
        self.p.paint(Color::Keyword, self._storage_kw(fd->storage));
        self.p.put(" ");
        self.p.paint(Color::Ident, self.tok(fd->name));
        if fd->type_ != &null {
            self.p.paint(Color::Punct, ": ");
            self.src_type(fd->type_);
        }
        if fd->init != &null {
            self.p.paint(Color::Punct, " = ");
            self.src_expr(fd->init);
        }
    }

    fn _d_param(self, pd: *ParamDecl) {
        if pd->is_self {
            self.p.paint(Color::Keyword, "self");
            return;
        }
        self.p.paint(Color::Ident, self.tok(pd->name));
        if pd->type_ != &null {
            self.p.paint(Color::Punct, ": ");
            self.src_type(pd->type_);
        }
        if pd->default_val != &null {
            self.p.paint(Color::Punct, " = ");
            self.src_expr(pd->default_val);
        }
    }

    fn _d_generic_param(self, gp: *GenericParamDecl) {
        if gp->is_const_param {
            self.p.paint(Color::Keyword, "const ");
            self.p.paint(Color::Ident, self.tok(gp->name));
            self.p.paint(Color::Punct, ": ");
            self.src_type(gp->value_type);
            if gp->default_type != &null {
                self.p.paint(Color::Punct, " = ");
                self.src_type(gp->default_type);
            }
            return;
        }

        if gp->is_pack { self.p.paint(Color::Punct, "..."); }
        self.p.paint(Color::TypeName, self.tok(gp->name));

        if gp->kind_bound != GenericParamKindBound::Any {
            self.p.paint(Color::Punct, ": ");
            if      gp->kind_bound == GenericParamKindBound::Class  { self.p.paint(Color::Keyword, "class");  }
            else if gp->kind_bound == GenericParamKindBound::Struct { self.p.paint(Color::Keyword, "struct"); }
            else if gp->kind_bound == GenericParamKindBound::Enum   { self.p.paint(Color::Keyword, "enum");   }
            else if gp->kind_bound == GenericParamKindBound::Union  { self.p.paint(Color::Keyword, "union");  }
        }

        for var i: usize = 0; i < gp->bounds.size(); ++i {
            self.p.paint(Color::Keyword, " impl ");
            self.src_type(gp->bounds[i]);
        }

        if gp->default_type != &null {
            self.p.paint(Color::Punct, " = ");
            self.src_type(gp->default_type);
        }
    }

    // -- aggregate decls (source path) -------------------------------------
    // NOTE: these use the projection caches because the SOURCE one-liner only
    // ever reproduced fields+methods; nested types were never in the source
    // reproduction either. The DEBUG tree path (dump_*) is the surface that
    // had the drop, and that path walks dc_decls. Left as-is on purpose.

    fn _d_struct(self, sd: *StructDecl) {
        var empty_methods: FrozenList::<*FunctionDecl>;
        self.p.paint(Color::Keyword, "struct");
        self._generic_params(sd->generic_params);
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(sd->name));
        self._inherit_list("impl", sd->implements);
        self._requires(sd->requires_clause);
        self._member_body(sd->fields, empty_methods);
    }

    fn _d_class(self, cd: *ClassDecl) {
        if cd->is_final { self.p.paint(Color::Keyword, "final "); }
        self.p.paint(Color::Keyword, "class");
        self._generic_params(cd->generic_params);
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(cd->name));
        self._inherit_list("derives", cd->derives_list);
        self._inherit_list("impl", cd->implements);
        self._requires(cd->requires_clause);
        self._member_body(cd->fields, cd->methods);
    }

    fn _d_interface(self, id: *InterfaceDecl) {
        var empty_fields: FrozenList::<*FieldDecl>;
        self.p.paint(Color::Keyword, "interface");
        self._generic_params(id->generic_params);
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(id->name));
        self._inherit_list("derives", id->derives_list);
        self._requires(id->requires_clause);
        self._member_body(empty_fields, id->methods);
    }

    fn _d_extension(self, ed: *ExtensionDecl) {
        var empty_fields: FrozenList::<*FieldDecl>;
        self.p.paint(Color::Keyword, "extend");
        self._generic_params(ed->generic_params);
        self.p.put(" ");
        self.src_type(ed->target);
        self._inherit_list("impl", ed->implements);
        self._member_body(empty_fields, ed->methods);
    }

    fn _d_enum(self, en: *EnumDecl) {
        self.p.paint(Color::Keyword, "enum");
        self._generic_params(en->generic_params);
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(en->name));
        if en->underlying != &null {
            self.p.paint(Color::Keyword, " derives ");
            self.src_type(en->underlying);
        }
        if en->variants.is_empty() { self.p.paint(Color::Punct, " {}"); return; }
        self.p.paint(Color::Punct, " { ");
        for var i: usize = 0; i < en->variants.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            self._d_enum_variant(en->variants[i]);
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _d_enum_variant(self, v: *EnumVariantDecl) {
        self.p.paint(Color::Ident, self.tok(v->name));
        if v->is_adt() {
            self.p.paint(Color::Punct, " { ");
            for var i: usize = 0; i < v->payload.size(); ++i {
                if i > 0 { self.p.paint(Color::Punct, ", "); }
                var f = v->payload.get(i);
                self.p.paint(Color::Ident, self.tok((*f)->name));
                self.p.paint(Color::Punct, ": ");
                self.src_type((*f)->type_);
            }
            self.p.paint(Color::Punct, " }");
        } else if v->discriminant != &null {
            self.p.paint(Color::Punct, " = ");
            self.src_expr(v->discriminant);
        }
    }

    fn _d_union(self, ud: *UnionDecl) {
        var empty_methods: FrozenList::<*FunctionDecl>;
        self.p.paint(Color::Keyword, "union");
        self._generic_params(ud->generic_params);
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(ud->name));
        self._member_body(ud->fields, empty_methods);
    }

    fn _d_type_alias(self, ta: *TypeAliasDecl) {
        self.p.paint(Color::Keyword, "type");
        self._generic_params(ta->generic_params);
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(ta->name));
        self.p.paint(Color::Punct, " = ");
        self.src_type(ta->aliased);
    }

    fn _d_module(self, md: *ModuleDecl) {
        if md->is_inline { self.p.paint(Color::Keyword, "inline "); }
        self.p.paint(Color::Keyword, "module");
        if !md->is_anonymous {
            self.p.put(" ");
            self.p.paint(Color::Ident, self.tok(md->name));
        }
        var dc = static_cast::<*DeclContext>(md);
        if dc->dc_decls.size() == 0 { self.p.paint(Color::Punct, " {}"); return; }
        self.p.paint(Color::Punct, " { ");
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, "; "); }
            self.src_decl(*(dc->dc_decls.get(i)));
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _d_import(self, im: *ImportDecl) {
        if im->import_kind == ImportKind::FfiC   { self.p.paint(Color::Keyword, "ffi "); self.p.paint(Color::Literal, "\"c\""); self.p.put(" "); }
        if im->import_kind == ImportKind::FfiCpp { self.p.paint(Color::Keyword, "ffi "); self.p.paint(Color::Literal, "\"c++\""); self.p.put(" "); }
        self.p.paint(Color::Keyword, "import ");

        if im->is_ffi() {
            self.p.paint(Color::Literal, self.tok(im->header));
        } else {
            if im->import_kind == ImportKind::SourceOnly { self.p.paint(Color::Keyword, "module "); }
            for var i: usize = 0; i < im->path_segments.size(); ++i {
                if i > 0 { self.p.paint(Color::Punct, "::"); }
                self.p.paint(Color::Ident, self.tok(*(im->path_segments.get(i))));
            }
            if im->is_wildcard {
                self.p.paint(Color::Punct, "::*");
            } else if im->has_items {
                self.p.paint(Color::Punct, "::{");
                for var i: usize = 0; i < im->items.size(); ++i {
                    if i > 0 { self.p.paint(Color::Punct, ", "); }
                    self._import_item(im->items.get(i));
                }
                self.p.paint(Color::Punct, "}");
            }
        }

        if im->has_alias {
            self.p.paint(Color::Keyword, " as ");
            self.p.paint(Color::Ident, self.tok(im->alias));
        }
    }

    fn _import_item(self, it: *ImportItem) {
        if it->is_wildcard { self.p.paint(Color::Punct, "*"); return; }
        for var i: usize = 0; i < it->sub_path.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, "::"); }
            self.p.paint(Color::Ident, self.tok(*(it->sub_path.get(i))));
        }
        if it->has_alias {
            self.p.paint(Color::Keyword, " as ");
            self.p.paint(Color::Ident, self.tok(it->alias));
        }
    }

    fn _d_vis_group(self, vg: *VisibilityGroupDecl) {
        self._vis(vg->group_visibility);
        if vg->members.is_empty() { self.p.paint(Color::Punct, "{}"); return; }
        self.p.paint(Color::Punct, "{ ");
        for var i: usize = 0; i < vg->members.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, "; "); }
            self.src_decl(vg->members[i]);
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _d_eval_block(self, eb: *EvalBlockDecl) {
        self.p.paint(Color::Keyword, "eval");
        if eb->body.is_empty() { self.p.paint(Color::Punct, " {}"); return; }
        self.p.paint(Color::Punct, " { ");
        for var i: usize = 0; i < eb->body.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, "; "); }
            self.src_decl(eb->body[i]);
        }
        self.p.paint(Color::Punct, " }");
    }

    fn _d_test(self, td: *TestDecl) {
        self.p.paint(Color::Keyword, "test");
        if td->label != &null {
            self.p.put(" ");
            self.src_expr(td->label);
        }
        self.p.put(" ");
        if td->body != &null {
            self.src_stmt(static_cast::<*Stmt>(td->body));
        } else {
            self.p.paint(Color::Punct, "{}");
        }
    }

    fn _d_macro(self, mc: *MacroDecl) {
        self.p.paint(Color::Keyword, "macro ");
        self.p.paint(Color::Ident, self.tok(mc->name));
        self.p.paint(Color::Punct, "!(");
        for var i: usize = 0; i < mc->params.size(); ++i {
            if i > 0 { self.p.paint(Color::Punct, ", "); }
            if mc->is_variadic && (i == mc->params.size() - 1) { self.p.paint(Color::Punct, "..."); }
            self.p.paint(Color::Ident, self.tok(*(mc->params.get(i))));
        }
        self.p.paint(Color::Punct, ") { ... }");
    }

    fn _d_proc_macro(self, pm: *ProcedureMacroDecl) {
        self.p.paint(Color::Keyword, "macro ");
        self.p.paint(Color::Attr, f"@{self.tok(pm->name)}");
        self._param_list(pm->params, false);
        self.p.put(" ");
        if pm->body != &null {
            self.src_stmt(static_cast::<*Stmt>(pm->body));
        } else {
            self.p.paint(Color::Punct, "{}");
        }
    }

    // ======================================================================
    //  DEBUG TREE DUMP  (RAV-DRIVEN)
    //
    //  Entry points are the dump_* facades (dump_decl / dump_stmt / dump_expr
    //  / dump_type / dump_pattern). Each sets _pending_last and calls the
    //  matching RAV dispatcher, which this class OVERRIDES. The override emits
    //  the node's row (spine + kind tag + attrs + visibility + inline source)
    //  and recurses into children with its own is_last bookkeeping. It does
    //  NOT call the RAV traverse_ bodies it owns the child walk so it can
    //  thread is_last and walk dc_decls.
    //
    //  Leaf-ish nodes (literals, idents, plain types/patterns) append their
    //  source form inline instead of spawning child rows.
    // ======================================================================

    /// Spine + colored node-kind tag. Caller appends attrs, then recurses.
    fn _head(self, kind: string, is_last: bool) {
        self.p.row(is_last);
        self.p.paint(Color::NodeKind, kind);
    }

    fn _dim(self, s: string) {
        self.p.put(" ");
        self.p.paint(Color::Dim, s);
    }

    fn _inline_type(self, t: *Type) { self.p.put(" "); self.src_type(t); }
    fn _inline_expr(self, e: *Expr) { self.p.put(" "); self.src_expr(e); }

    // -- attribute + visibility row prefix ---------------------------------

    /// Emit written visibility, inline on the current decl row, before its
    /// name. `pub `/`prot `/`priv ` only no output for unspecified.
    fn _dump_vis(self, decl: *Decl) {
        if decl->has_visibility() {
            self.p.put(" ");
            self._vis(static_cast::<u8>(decl->visibility));
        }
    }

    /// Render this decl's annotations as their own child rows, BEFORE the
    /// decl's structural children. Each attribute is one leaf row `@name`.
    /// Comment annotations (doc/line/block) render as `@<comment:kind>` so a
    /// dump never silently swallows an attached doc comment.
    ///
    /// Returns nothing; caller has already opened enter() for this decl.
    /// `attrs_are_last` is true when the decl has NO structural children, so
    /// the final attribute row gets the "`-" corner.
    fn _dump_annotations(self, decl: *Decl, attrs_are_last: bool) {
        var n = decl->annotations.size();
        for var i: usize = 0; i < n; ++i {
            var entry = decl->annotations.get(i);
            var last  = attrs_are_last && (i == n - 1);
            self._head("Attribute", last);
            self.p.put(" ");
            self._dump_one_annotation(entry);
            self.p.newline();
        }
    }

    /// One annotation entry. Attribute => `@name(args)`; comment => `<kind>`.
    ///
    /// Args ARE rendered now. AnnotationEntry.args is FrozenList<*void> only
    /// because Stage 0 cannot forward-declare Expr across files; the grammar
    /// guarantees every element is an Expr* (attr args reuse the call-arg
    /// production verbatim), so the reinterpret_cast at this single read site
    /// is sound. It converts to a typed FrozenList<*Expr> once Stage 1 self-
    /// hosts (see the STAGE0 note in Annotation.k).
    ///
    /// Named args (`@dep(since: 2)`) parse to AssignOperatorExpr(lhs=label,
    /// rhs=value) -- the call-arg grammar folds `name: val` onto the assign
    /// production. We render those as `label: value` to match source spelling
    /// rather than the stored `=`.
    fn _dump_one_annotation(self, entry: *AnnotationEntry) {
        if entry->kind == AnnotationKind::Attribute {
            var nm = self.istr(entry->name);
            if self._istr_unresolved() {
                self.p.paint(Color::Attr, "@<unresolved>");
            } else {
                self.p.paint(Color::Attr, f"@{nm}");
            }
            if !entry->args.is_empty() {
                self.p.paint(Color::Punct, "(");
                for var i: usize = 0; i < entry->args.size(); ++i {
                    if i > 0 { self.p.paint(Color::Punct, ", "); }
                    var arg = reinterpret_cast::<*Expr>(*(entry->args.get(i)));
                    self._attr_arg(arg);
                }
                self.p.paint(Color::Punct, ")");
            }
            return;
        }
        if entry->kind == AnnotationKind::DocComment   { self.p.paint(Color::Dim, "/// doc-comment");   return; }
        if entry->kind == AnnotationKind::LineComment  { self.p.paint(Color::Dim, "// line-comment");   return; }
        if entry->kind == AnnotationKind::BlockComment { self.p.paint(Color::Dim, "/* block-comment */"); return; }
        self.p.paint(Color::Dim, "<annotation>");
    }

    /// Render one attribute arg. Named args parse to AssignOperatorExpr whose
    /// op_token is a synthesized OpColon (see _parse_call_args: `csome: 4`
    /// becomes AssignOperatorExpr(csome, 4, <colon>)). A genuine positional
    /// assignment `foo(x = 4)` is the SAME node kind but with op_token == `=`,
    /// so we discriminate on op_token.kind, NOT on isa<AssignOperatorExpr>.
    /// The colon token is synthesized with the name's range, so tok() on it is
    /// unreliable -- render the `:` literally rather than routing op_token
    /// through src_expr's spelling lookup.
    fn _attr_arg(self, arg: *Expr) {
        if arg == &null { self.p.paint(Color::Error, "<error>"); return; }
        if isa::<AssignOperatorExpr>(arg) {
            var a = cast::<AssignOperatorExpr>(arg);
            if a->op_token.kind == TokenKind::OpColon {
                // named argument: render label : value
                self.src_expr(a->lhs);
                self.p.paint(Color::Punct, ": ");
                self.src_expr(a->rhs);
                return;
            }
            // genuine positional assignment passed as an arg: let src_expr
            // render it with its real `=` spelling.
        }
        self.src_expr(arg);
    }

    /// True if this decl has any annotation to render as a child row.
    fn _has_annotations(self, decl: *Decl) -> bool {
        return decl->annotations.size() > 0;
    }

    // ======================================================================
    //  RAV DISPATCHER OVERRIDES
    //
    //  These five are the entire RAV surface AstDumper overrides. Each reads
    //  _pending_last (set by the caller just before the dispatch call),
    //  renders the node, recurses on children with its own is_last logic, and
    //  returns the node unchanged (the dumper never rewrites the tree).
    // ======================================================================

    /* OVERRIDE */ fn dispatch_type(self, ty: *Type) -> *Type {
        var is_last = self._pending_last;
        self.dump_type_row(ty, is_last);
        return ty;
    }

    /* OVERRIDE */ fn dispatch_expr(self, e: *Expr) -> *Expr {
        var is_last = self._pending_last;
        self.dump_expr_row(e, is_last);
        return e;
    }

    /* OVERRIDE */ fn dispatch_pattern(self, pat: *Pattern) -> *Pattern {
        var is_last = self._pending_last;
        self.dump_pattern_row(pat, is_last);
        return pat;
    }

    /* OVERRIDE */ fn dispatch_stmt(self, s: *Stmt) -> *Stmt {
        var is_last = self._pending_last;
        self.dump_stmt_row(s, is_last);
        return s;
    }

    /* OVERRIDE */ fn dispatch_decl(self, d: *Decl) -> *Decl {
        var is_last = self._pending_last;
        self.dump_decl_row(d, is_last);
        return d;
    }

    // -- child-dispatch helpers (set is_last, route through dyn()) ----------
    // Going through self.dyn()->dispatch_* keeps the CRTP contract: a future
    // subclass of AstDumper would still intercept. is_last is threaded via
    // _pending_last because the dispatch signature cannot carry it.

    fn _child_decl(self, d: *Decl, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_decl(d);
    }
    fn _child_stmt(self, s: *Stmt, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_stmt(s);
    }
    fn _child_expr(self, e: *Expr, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_expr(e);
    }
    fn _child_type(self, t: *Type, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_type(t);
    }
    fn _child_pattern(self, pat: *Pattern, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_pattern(pat);
    }

    // ======================================================================
    //  TYPE dump row
    // ======================================================================

    fn dump_type_row(self, ty: *Type, is_last: bool) {
        if ty == &null    { self._head("<null-type>", is_last); self.p.paint(Color::Error, " <null>"); self.p.newline(); return; }
        if ty->is_error() { self._head("RecoveryType", is_last); self._dim(self._recovery_name(self._type_kind_name_of(ty->recovery_kind))); self.p.newline(); return; }
        self._head(self._type_kind_name(ty), is_last);
        self.p.put(" \x27");
        self.src_type(ty);
        self.p.put("\x27");
        self.p.newline();

        // structured types that carry generic arguments (or a value-expr
        // payload) explode into child rows so the args  including nested
        // value expressions like `Array<i32, foo()>`  are walkable.
        if self._type_is_expandable(ty) {
            self.p.enter(is_last);
            self._dump_type_children(ty);
            self.p.leave();
        }
    }

    // -- generic-aware type expansion --------------------------------------
    // The dumper renders types inline by default; these helpers add child rows
    // only when a type carries a generic argument list (or a TypeExpr value),
    // keeping leaf types (`i32`, `*u8`) on a single inline row.

    fn _chain_generic_arg_count(self, ty: *ChainType) -> usize {
        var n: usize = 0;
        for var i: usize = 0; i < ty->segments.size(); ++i {
            n += ty->segments.get(i)->generic_args.size();
        }
        return n;
    }

    /// True when `ty` (or a nested element/pointee/arg) carries generic
    /// arguments or is a value-expression type, i.e. it has children worth
    /// exploding into the tree.
    fn _type_is_expandable(self, ty: *Type) -> bool {
        if ty == &null      { return false; }
        if ty->is_error()   { return false; }
        if isa::<ChainType>(ty)             { return self._chain_generic_arg_count(cast::<ChainType>(ty)) > 0; }
        if isa::<TypeExpr>(ty)              { return true; }
        if isa::<PointerType>(ty)           { return self._type_is_expandable(cast::<PointerType>(ty)->pointee); }
        if isa::<NullableType>(ty)          { return self._type_is_expandable(cast::<NullableType>(ty)->inner); }
        if isa::<VectorType>(ty)            { return self._type_is_expandable(cast::<VectorType>(ty)->element); }
        if isa::<SetType>(ty)               { return self._type_is_expandable(cast::<SetType>(ty)->element); }
        if isa::<VariadicPackType>(ty)      { return self._type_is_expandable(cast::<VariadicPackType>(ty)->param); }
        if isa::<PackExpansionType>(ty)     { return self._type_is_expandable(cast::<PackExpansionType>(ty)->pattern); }
        if isa::<CXXLValueRefType>(ty)      { return self._type_is_expandable(cast::<CXXLValueRefType>(ty)->referee); }
        if isa::<CXXRValueRefType>(ty)      { return self._type_is_expandable(cast::<CXXRValueRefType>(ty)->referee); }
        if isa::<FixedArrayType>(ty)        { return self._type_is_expandable(cast::<FixedArrayType>(ty)->element); }
        if isa::<TupleType>(ty) {
            var tt = cast::<TupleType>(ty);
            for var i: usize = 0; i < tt->elements.size(); ++i {
                if self._type_is_expandable(tt->elements[i]) { return true; }
            }
            return false;
        }
        if isa::<MapType>(ty) {
            return self._type_is_expandable(cast::<MapType>(ty)->key)
                || self._type_is_expandable(cast::<MapType>(ty)->value);
        }
        if isa::<FunctionPointerType>(ty) {
            var fp = cast::<FunctionPointerType>(ty);
            for var i: usize = 0; i < fp->params.size(); ++i {
                if self._type_is_expandable(fp->params[i]) { return true; }
            }
            return (fp->return_type != &null) && self._type_is_expandable(fp->return_type);
        }
        return false;
    }

    /// Emit the structural child rows of an expandable type. Mirrors the set in
    /// `_type_is_expandable`.
    fn _dump_type_children(self, ty: *Type) {
        if isa::<ChainType>(ty) {
            var ct    = cast::<ChainType>(ty);
            var total = self._chain_generic_arg_count(ct);
            var seen: usize = 0;
            for var i: usize = 0; i < ct->segments.size(); ++i {
                var seg = ct->segments.get(i);
                for var j: usize = 0; j < seg->generic_args.size(); ++j {
                    ++seen;
                    self._dump_generic_arg_row(seg->generic_args.get(j), seen == total);
                }
            }
            return;
        }
        if isa::<TypeExpr>(ty)          { self._child_expr(cast::<TypeExpr>(ty)->expr, true);            return; }
        if isa::<PointerType>(ty)       { self._child_type(cast::<PointerType>(ty)->pointee, true);      return; }
        if isa::<NullableType>(ty)      { self._child_type(cast::<NullableType>(ty)->inner, true);       return; }
        if isa::<VectorType>(ty)        { self._child_type(cast::<VectorType>(ty)->element, true);       return; }
        if isa::<SetType>(ty)           { self._child_type(cast::<SetType>(ty)->element, true);          return; }
        if isa::<VariadicPackType>(ty)  { self._child_type(cast::<VariadicPackType>(ty)->param, true);   return; }
        if isa::<PackExpansionType>(ty) { self._child_type(cast::<PackExpansionType>(ty)->pattern, true); return; }
        if isa::<CXXLValueRefType>(ty)  { self._child_type(cast::<CXXLValueRefType>(ty)->referee, true); return; }
        if isa::<CXXRValueRefType>(ty)  { self._child_type(cast::<CXXRValueRefType>(ty)->referee, true); return; }
        if isa::<FixedArrayType>(ty)    { self._child_type(cast::<FixedArrayType>(ty)->element, true);   return; }
        if isa::<TupleType>(ty) {
            var tt = cast::<TupleType>(ty);
            for var i: usize = 0; i < tt->elements.size(); ++i {
                self._child_type(tt->elements[i], i == tt->elements.size() - 1);
            }
            return;
        }
        if isa::<MapType>(ty) {
            var mt = cast::<MapType>(ty);
            self._child_type(mt->key, false);
            self._child_type(mt->value, true);
            return;
        }
        if isa::<FunctionPointerType>(ty) {
            var fp      = cast::<FunctionPointerType>(ty);
            var np      = fp->params.size();
            var has_ret = (fp->return_type != &null);
            for var i: usize = 0; i < np; ++i {
                self._child_type(fp->params[i], (i == np - 1) && !has_ret);
            }
            if has_ret { self._child_type(fp->return_type, true); }
            return;
        }
    }

    fn _dump_generic_args_children(self, args: FrozenList::<ChainType::GenericArg>) {
        for var i: usize = 0; i < args.size(); ++i {
            self._dump_generic_arg_row(args.get(i), i == args.size() - 1);
        }
    }

    fn _dump_generic_arg_row(self, arg: *ChainType::GenericArg, is_last: bool) {
        self._head("GenericArg", is_last);
        if arg->name != &null {
            self.p.put(" ");
            self.p.paint(Color::Ident, self.tok(arg->name->name));
            self.p.paint(Color::Punct, ":");
        }
        self.p.put(" \x27");
        self.src_type(arg->ty);
        self.p.put("\x27");
        self.p.newline();

        if self._type_is_expandable(arg->ty) {
            self.p.enter(is_last);
            self._dump_type_children(arg->ty);
            self.p.leave();
        }
    }

    // ======================================================================
    //  EXPR dump row
    // ======================================================================

    fn dump_expr_row(self, e: *Expr, is_last: bool) {
        if e == &null    { self._head("<null-expr>", is_last); self.p.paint(Color::Error, " <null>"); self.p.newline(); return; }
        if e->is_error() { self._head("RecoveryExpr", is_last); self._dim(self._recovery_name(self._expr_kind_name_of(e->recovery_kind))); self.p.newline(); return; }

        if isa::<IntegerLiteralExpr>(e) || isa::<FloatingLiteralExpr>(e)
        || isa::<StringLiteralExpr>(e)  || isa::<CharacterLiteralExpr>(e)
        || isa::<BooleanLiteralExpr>(e) || isa::<NullLiteralExpr>(e) {
            self._head(self._expr_kind_name(e), is_last);
            self._inline_expr(e);
            self.p.newline();
            return;
        }

        // NamedIdentExpr is a leaf row unless it carries generic arguments
        // (`foo<sizeof i32>`), which explode into walkable child rows.
        if isa::<NamedIdentExpr>(e) {
            var ni = cast::<NamedIdentExpr>(e);
            self._head(self._expr_kind_name(e), is_last);
            self._inline_expr(e);
            self.p.newline();
            if !ni->generic_args.is_empty() {
                self.p.enter(is_last);
                self._dump_generic_args_children(ni->generic_args);
                self.p.leave();
            }
            return;
        }

        if isa::<ChainExpr>(e)            { self._dx_chain(cast::<ChainExpr>(e), is_last);             return; }
        if isa::<CallExpr>(e)             { self._dx_call(cast::<CallExpr>(e), is_last);               return; }
        if isa::<SubscriptExpr>(e)        { self._dx_subscript(cast::<SubscriptExpr>(e), is_last);     return; }
        if isa::<UnaryOperatorExpr>(e)    { self._dx_unary(cast::<UnaryOperatorExpr>(e), is_last);     return; }
        if isa::<BinaryOperatorExpr>(e)   { self._dx_binop(cast::<BinaryOperatorExpr>(e), is_last);    return; }
        if isa::<AssignOperatorExpr>(e)   { self._dx_assign(cast::<AssignOperatorExpr>(e), is_last);   return; }
        if isa::<ListLiteralExpr>(e)      { self._dx_expr_seq("ListLiteralExpr",  cast::<ListLiteralExpr>(e)->elements,  is_last); return; }
        if isa::<TupleLiteralExpr>(e)     { self._dx_expr_seq("TupleLiteralExpr", cast::<TupleLiteralExpr>(e)->elements, is_last); return; }
        if isa::<SetLiteralExpr>(e)       { self._dx_expr_seq("SetLiteralExpr",   cast::<SetLiteralExpr>(e)->elements,   is_last); return; }
        if isa::<MapLiteralExpr>(e)       { self._dx_map(cast::<MapLiteralExpr>(e), is_last);          return; }
        if isa::<NamedInitializerExpr>(e) { self._dx_named_init(cast::<NamedInitializerExpr>(e), is_last); return; }
        if isa::<AnonInitializerExpr>(e)  { self._dx_anon_init(cast::<AnonInitializerExpr>(e), is_last);   return; }
        if isa::<IfExpr>(e)               { self._dx_if(cast::<IfExpr>(e), is_last);                   return; }
        if isa::<TryCatchExpr>(e)         { self._dx_try(cast::<TryCatchExpr>(e), is_last);            return; }
        if isa::<MatchExpr>(e)            { self._dx_match(cast::<MatchExpr>(e), is_last);             return; }
        if isa::<RangeExpr>(e)            { self._dx_range(cast::<RangeExpr>(e), is_last);             return; }
        if isa::<ClosureExpr>(e)          { self._dx_closure(cast::<ClosureExpr>(e), is_last);         return; }
        if isa::<AwaitExpr>(e)            { self._dx_kw("AwaitExpr",  cast::<AwaitExpr>(e)->operand,  is_last); return; }
        if isa::<SpawnExpr>(e)            { self._dx_kw("SpawnExpr",  cast::<SpawnExpr>(e)->operand,  is_last); return; }
        if isa::<ThreadExpr>(e)           { self._dx_kw("ThreadExpr", cast::<ThreadExpr>(e)->operand, is_last); return; }
        if isa::<EvalExpr>(e)             { self._dx_kw("EvalExpr",   cast::<EvalExpr>(e)->operand,   is_last); return; }
        if isa::<UnsafeExpr>(e)           { self._dx_kw("UnsafeExpr", cast::<UnsafeExpr>(e)->operand, is_last); return; }
        if isa::<DeleteExpr>(e)           { self._dx_kw("DeleteExpr", cast::<DeleteExpr>(e)->operand, is_last); return; }
        if isa::<PackExpansionExpr>(e)    { self._dx_kw("PackExpansionExpr", cast::<PackExpansionExpr>(e)->operand, is_last); return; }
        if isa::<SizeOfExpr>(e)           { self._head("SizeOfExpr", is_last);  self._inline_type(cast::<SizeOfExpr>(e)->type_arg);  self.p.newline(); return; }
        if isa::<AlignOfExpr>(e)          { self._head("AlignOfExpr", is_last); self._inline_type(cast::<AlignOfExpr>(e)->type_arg); self.p.newline(); return; }
        if isa::<TypeOfExpr>(e)           { self._dx_kw("TypeOfExpr", cast::<TypeOfExpr>(e)->operand, is_last); return; }
        if isa::<TypeCastExpr>(e)         { self._dx_cast(cast::<TypeCastExpr>(e), is_last);           return; }
        if isa::<ImplConformanceExpr>(e)  { self._dx_two_types("ImplConformanceExpr", cast::<ImplConformanceExpr>(e)->subject, cast::<ImplConformanceExpr>(e)->inter, is_last); return; }
        if isa::<DerivesRelationExpr>(e)  { self._dx_two_types("DerivesRelationExpr", cast::<DerivesRelationExpr>(e)->subject, cast::<DerivesRelationExpr>(e)->base,  is_last); return; }
        if isa::<ImplicitBoundaryCastExpr>(e) { self._dx_boundary(cast::<ImplicitBoundaryCastExpr>(e), is_last); return; }

        self._head("<unknown-expr>", is_last); self.p.newline();
    }

    fn _dx_chain(self, e: *ChainExpr, is_last: bool) {
        self._head("ChainExpr", is_last);
        self.p.put(" \x27");
        self.src_expr(e);
        self.p.put("\x27");
        self.p.newline();

        self.p.enter(is_last);
        var has_base = (e->base != &null);
        var nsteps   = e->steps.size();

        if has_base {
            self._child_expr(e->base, nsteps == 0);
        }
        for var i: usize = 0; i < nsteps; ++i {
            var s    = e->steps.get(i);
            var last = (i == nsteps - 1);
            self._head("Step", last);
            self.p.put(" ");
            self._access_op(s->access_kind);
            if s->name != &null {
                self.p.paint(Color::Ident, self.tok(s->name->name));
            } else {
                self.p.paint(Color::Error, "<error>");
            }
            self._generic_args(s->generic_args);
            self.p.newline();
        }
        self.p.leave();
    }

    fn _dx_call(self, e: *CallExpr, is_last: bool) {
        self._head("CallExpr", is_last);
        self._dim(f"({e->args.size()} args)");
        self.p.newline();
        self.p.enter(is_last);
        var has_args = !e->args.is_empty();
        self._child_expr(e->callee, !has_args);
        for var i: usize = 0; i < e->args.size(); ++i {
            self._child_expr(e->args[i], (i == e->args.size() - 1));
        }
        self.p.leave();
    }

    fn _dx_subscript(self, e: *SubscriptExpr, is_last: bool) {
        self._head("SubscriptExpr", is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->base, false);
        self._child_expr(e->index, true);
        self.p.leave();
    }

    fn _dx_unary(self, e: *UnaryOperatorExpr, is_last: bool) {
        self._head("UnaryOperatorExpr", is_last);
        self.p.put(" ");
        self.p.paint(Color::Dim, (("prefix ") if (e->is_prefix()) else ("postfix ")));
        self.p.paint(Color::Operator, self.tok(e->op_token));
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->operand, true);
        self.p.leave();
    }

    fn _dx_binop(self, e: *BinaryOperatorExpr, is_last: bool) {
        self._head("BinaryOperatorExpr", is_last);
        self.p.put(" ");
        self.p.paint(Color::Operator, self.tok(e->op_token));
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->lhs, false);
        self._child_expr(e->rhs, true);
        self.p.leave();
    }

    fn _dx_assign(self, e: *AssignOperatorExpr, is_last: bool) {
        self._head("AssignOperatorExpr", is_last);
        self.p.put(" ");
        self.p.paint(Color::Operator, self.tok(e->op_token));
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->lhs, false);
        self._child_expr(e->rhs, true);
        self.p.leave();
    }

    fn _dx_expr_seq(self, kind: string, xs: FrozenList::<*Expr>, is_last: bool) {
        self._head(kind, is_last);
        self._dim(f"({xs.size()})");
        self.p.newline();
        self.p.enter(is_last);
        for var i: usize = 0; i < xs.size(); ++i {
            self._child_expr(xs[i], (i == xs.size() - 1));
        }
        self.p.leave();
    }

    fn _dx_map(self, e: *MapLiteralExpr, is_last: bool) {
        self._head("MapLiteralExpr", is_last);
        self._dim(f"({e->entries.size()} entries)");
        self.p.newline();
        self.p.enter(is_last);
        for var i: usize = 0; i < e->entries.size(); ++i {
            var en   = e->entries.get(i);
            var last = (i == e->entries.size() - 1);
            self._head("Entry", last);
            self.p.newline();
            self.p.enter(last);
            self._child_expr(en->key, false);
            self._child_expr(en->value, true);
            self.p.leave();
        }
        self.p.leave();
    }

    fn _dx_named_init(self, e: *NamedInitializerExpr, is_last: bool) {
        self._head("NamedInitializerExpr", is_last);
        self.p.newline();
        self.p.enter(is_last);
        var has_fields = !e->fields.is_empty();
        self._child_expr(e->type_expr, !has_fields);
        for var i: usize = 0; i < e->fields.size(); ++i {
            var fld  = e->fields.get(i);
            var last = (i == e->fields.size() - 1);
            self._head("Field", last);
            self.p.put(" ");
            self.p.paint(Color::Ident, self.tok(fld->name));
            self.p.newline();
            self.p.enter(last);
            self._child_expr(fld->value, true);
            self.p.leave();
        }
        self.p.leave();
    }

    fn _dx_anon_init(self, e: *AnonInitializerExpr, is_last: bool) {
        self._head("AnonInitializerExpr", is_last);
        self.p.newline();
        self.p.enter(is_last);
        for var i: usize = 0; i < e->fields.size(); ++i {
            var fld  = e->fields.get(i);
            var last = (i == e->fields.size() - 1);
            self._head("Field", last);
            self.p.put(" .");
            self.p.paint(Color::Ident, self.tok(fld->name));
            self.p.newline();
            self.p.enter(last);
            self._child_expr(fld->value, true);
            self.p.leave();
        }
        self.p.leave();
    }

    fn _dx_if(self, e: *IfExpr, is_last: bool) {
        self._head("IfExpr", is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._head("cond", false); self.p.newline();
        self.p.enter(false); self._child_expr(e->condition, true); self.p.leave();
        var no_tail = (e->else_ifs.is_empty() && e->else_expr == &null);
        self._head("then", no_tail); self.p.newline();
        self.p.enter(false); self._child_expr(e->then_expr, true); self.p.leave();
        for var i: usize = 0; i < e->else_ifs.size(); ++i {
            var arm = e->else_ifs.get(i);
            self._head("else-if", false); self.p.newline();
            self.p.enter(false);
            self._child_expr(arm->condition, false);
            self._child_expr(arm->body, true);
            self.p.leave();
        }
        if e->else_expr != &null {
            self._head("else", true); self.p.newline();
            self.p.enter(true); self._child_expr(e->else_expr, true); self.p.leave();
        }
        self.p.leave();
    }

    fn _dx_try(self, e: *TryCatchExpr, is_last: bool) {
        self._head("TryCatchExpr", is_last);
        self._dim(f"({e->catch_arms.size()} arms)");
        self.p.newline();
        self.p.enter(is_last);
        var has_arms = !e->catch_arms.is_empty();
        self._child_expr(e->try_expr, !has_arms);
        for var i: usize = 0; i < e->catch_arms.size(); ++i {
            var arm  = e->catch_arms.get(i);
            var last = (i == e->catch_arms.size() - 1);
            self._head("catch", last);
            if arm->has_binding && (arm->binding != &null) {
                self.p.put(" ");
                if arm->is_const { self.p.paint(Color::Keyword, "const "); }
                self.p.paint(Color::Ident, self.tok(arm->binding->name));
            }
            if arm->filter != &null { self._inline_type(arm->filter); }
            self.p.newline();
            self.p.enter(last);
            self._child_expr(arm->body, true);
            self.p.leave();
        }
        self.p.leave();
    }

    fn _dx_match(self, e: *MatchExpr, is_last: bool) {
        self._head("MatchExpr", is_last);
        self._dim(f"({e->cases.size()} cases)");
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->scrutinee, e->cases.is_empty());
        for var i: usize = 0; i < e->cases.size(); ++i {
            self._dump_match_case(e->cases.get(i), (i == e->cases.size() - 1));
        }
        self.p.leave();
    }

    /// Shared match-case row for expr- and stmt-form match.
    fn _dump_match_case(self, mc: *MatchCase, is_last: bool) {
        if mc->is_default {
            self._head("default", is_last);
        } else {
            self._head("case", is_last);
            self.p.put(" ");
            for var i: usize = 0; i < mc->patterns.size(); ++i {
                if i > 0 { self.p.paint(Color::Punct, ", "); }
                self.src_pattern(mc->patterns[i]);
            }
            if mc->guard != &null {
                self.p.paint(Color::Keyword, " where ");
                self.src_expr(mc->guard);
            }
        }
        self.p.newline();
        self.p.enter(is_last);
        if mc->expression != &null {
            self._child_expr(mc->expression, true);
        } else if mc->body != &null {
            self._child_stmt(static_cast::<*Stmt>(mc->body), true);
        }
        self.p.leave();
    }

    fn _dx_range(self, e: *RangeExpr, is_last: bool) {
        self._head("RangeExpr", is_last);
        self.p.put(" ");
        self.p.paint(Color::Operator, (("..=") if (e->is_inclusive) else ("..")));
        self.p.newline();
        self.p.enter(is_last);
        if e->begin != &null { self._child_expr(e->begin, e->end == &null); }
        if e->end   != &null { self._child_expr(e->end, true); }
        self.p.leave();
    }

    fn _dx_closure(self, e: *ClosureExpr, is_last: bool) {
        self._head("ClosureExpr", is_last);
        if e->return_type != &null { self.p.put(" ->"); self._inline_type(e->return_type); }
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->body, true);
        self.p.leave();
    }

    fn _dx_cast(self, e: *TypeCastExpr, is_last: bool) {
        self._head("TypeCastExpr", is_last);
        if e->is_unsafe { self.p.put(" "); self.p.paint(Color::Keyword, "unsafe"); }
        self.p.put(" -> ");
        self.src_type(e->target);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->operand, true);
        self.p.leave();
    }

    fn _dx_boundary(self, e: *ImplicitBoundaryCastExpr, is_last: bool) {
        self._head("ImplicitBoundaryCastExpr", is_last);
        self.p.put(" ");
        self.src_type(e->source_type);
        self.p.put(" -> ");
        self.src_type(e->target_type);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e->original, true);
        self.p.leave();
    }

    fn _dx_kw(self, kind: string, operand: *Expr, is_last: bool) {
        self._head(kind, is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(operand, true);
        self.p.leave();
    }

    fn _dx_two_types(self, kind: string, a: *Type, b: *Type, is_last: bool) {
        self._head(kind, is_last);
        self.p.put(" ");
        self.src_type(a);
        self.p.put(" / ");
        self.src_type(b);
        self.p.newline();
    }

    // ======================================================================
    //  PATTERN dump row
    // ======================================================================

    fn dump_pattern_row(self, pat: *Pattern, is_last: bool) {
        if pat == &null    { self._head("<null-pat>", is_last); self.p.newline(); return; }
        if pat->is_error() { self._head("RecoveryPattern", is_last); self._dim(self._recovery_name(self._pattern_kind_name_of(pat->recovery_kind))); self.p.newline(); return; }
        self._head(self._pattern_kind_name(pat), is_last);
        self.p.put(" \x27");
        self.src_pattern(pat);
        self.p.put("\x27");
        self.p.newline();
    }

    // ======================================================================
    //  STMT dump row
    // ======================================================================

    fn dump_stmt_row(self, stmt: *Stmt, is_last: bool) {
        if stmt == &null    { self._head("<null-stmt>", is_last); self.p.newline(); return; }
        if stmt->is_error() { self._head("RecoveryStmt", is_last); self._dim(self._recovery_name(self._stmt_kind_name_of(stmt->recovery_kind))); self.p.newline(); return; }

        if isa::<CompoundStmt>(stmt)          { self._ds_compound(cast::<CompoundStmt>(stmt), is_last);       return; }
        if isa::<ExpressionStmt>(stmt)        { self._ds_one_expr("ExpressionStmt", cast::<ExpressionStmt>(stmt)->expr, is_last); return; }
        if isa::<DeclStmt>(stmt)              { self._ds_decl(cast::<DeclStmt>(stmt), is_last);               return; }
        if isa::<ReturnStmt>(stmt)            { self._ds_return(cast::<ReturnStmt>(stmt), is_last);           return; }
        if isa::<BreakStmt>(stmt)             { self._ds_break(cast::<BreakStmt>(stmt), is_last);             return; }
        if isa::<ContinueStmt>(stmt)          { self._ds_continue(cast::<ContinueStmt>(stmt), is_last);       return; }
        if isa::<PanicStmt>(stmt)             { self._ds_one_expr("PanicStmt", cast::<PanicStmt>(stmt)->payload, is_last); return; }
        if isa::<YieldStmt>(stmt)             { self._ds_one_expr("YieldStmt", cast::<YieldStmt>(stmt)->value, is_last);   return; }
        if isa::<RuntimeAssertStmt>(stmt)     { self._ds_assert("RuntimeAssertStmt", cast::<RuntimeAssertStmt>(stmt)->condition, cast::<RuntimeAssertStmt>(stmt)->message, is_last); return; }
        if isa::<StaticAssertStmt>(stmt)      { self._ds_assert("StaticAssertStmt", cast::<StaticAssertStmt>(stmt)->condition, cast::<StaticAssertStmt>(stmt)->message, is_last); return; }
        if isa::<LabelIntrinsicStmt>(stmt)    { self._head("LabelIntrinsicStmt", is_last); self.p.put(" "); self.p.paint(Color::Ident, self.tok(cast::<LabelIntrinsicStmt>(stmt)->name)); self.p.newline(); return; }
        if isa::<JumpIntrinsicStmt>(stmt)     { self._head("JumpIntrinsicStmt", is_last); self.p.put(" "); self.p.paint(Color::Ident, self.tok(cast::<JumpIntrinsicStmt>(stmt)->target)); self.p.newline(); return; }
        if isa::<ConditionalStmt>(stmt)       { self._ds_conditional(cast::<ConditionalStmt>(stmt), is_last); return; }
        if isa::<WhileLoopStmt>(stmt)         { self._ds_while(cast::<WhileLoopStmt>(stmt), is_last);         return; }
        if isa::<LoopStmt>(stmt)              { self._ds_loop(cast::<LoopStmt>(stmt), is_last);               return; }
        if isa::<RangedForStmt>(stmt)         { self._ds_ranged_for(cast::<RangedForStmt>(stmt), is_last);    return; }
        if isa::<IndexedForStmt>(stmt)        { self._ds_indexed_for(cast::<IndexedForStmt>(stmt), is_last);  return; }
        if isa::<MatchStmt>(stmt)             { self._ds_match(cast::<MatchStmt>(stmt), is_last);             return; }
        if isa::<LabeledStmt>(stmt)           { self._ds_labeled(cast::<LabeledStmt>(stmt), is_last);         return; }
        if isa::<TryCatchStmt>(stmt)          { self._ds_try(cast::<TryCatchStmt>(stmt), is_last);            return; }
        if isa::<FinallyStmt>(stmt)           { self._ds_block_stmt("FinallyStmt", cast::<FinallyStmt>(stmt)->body, is_last);     return; }
        if isa::<UnsafeBlockStmt>(stmt)       { self._ds_block_stmt("UnsafeBlockStmt", cast::<UnsafeBlockStmt>(stmt)->body, is_last); return; }
        if isa::<ContextBindingStmt>(stmt)    { self._ds_context(cast::<ContextBindingStmt>(stmt), is_last);  return; }
        if isa::<DestructuringDeclStmt>(stmt) { self._ds_destructure(cast::<DestructuringDeclStmt>(stmt), is_last); return; }
        if isa::<InlineBlockStmt>(stmt)       { self._head("InlineBlockStmt", is_last); self._dim(f"({self._inline_lang(cast::<InlineBlockStmt>(stmt)->lang)})"); self.p.newline(); return; }
        if isa::<EvalBlockStmt>(stmt)         { self._ds_eval_block(cast::<EvalBlockStmt>(stmt), is_last);    return; }

        self._head("<unknown-stmt>", is_last); self.p.newline();
    }

    fn _ds_compound(self, stmt: *CompoundStmt, is_last: bool) {
        self._head("CompoundStmt", is_last);
        self._dim(f"({stmt->body.size()})");
        self.p.newline();
        self.p.enter(is_last);
        for var i: usize = 0; i < stmt->body.size(); ++i {
            self._child_stmt(stmt->body[i], (i == stmt->body.size() - 1));
        }
        self.p.leave();
    }

    fn _ds_decl(self, stmt: *DeclStmt, is_last: bool) {
        self._head("DeclStmt", is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_decl(stmt->decl, true);
        self.p.leave();
    }

    fn _ds_return(self, stmt: *ReturnStmt, is_last: bool) {
        self._head("ReturnStmt", is_last);
        self.p.newline();
        if stmt->value != &null {
            self.p.enter(is_last);
            self._child_expr(stmt->value, true);
            self.p.leave();
        }
    }

    fn _ds_break(self, stmt: *BreakStmt, is_last: bool) {
        self._head("BreakStmt", is_last);
        if stmt->has_label { self.p.put(" "); self.p.paint(Color::Ident, self.tok(stmt->label)); }
        self.p.newline();
    }

    fn _ds_continue(self, stmt: *ContinueStmt, is_last: bool) {
        self._head("ContinueStmt", is_last);
        if stmt->has_label { self.p.put(" "); self.p.paint(Color::Ident, self.tok(stmt->label)); }
        self.p.newline();
    }

    fn _ds_assert(self, kind: string, cond: *Expr, msg: *Expr, is_last: bool) {
        self._head(kind, is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(cond, msg == &null);
        if msg != &null { self._child_expr(msg, true); }
        self.p.leave();
    }

    fn _ds_conditional(self, stmt: *ConditionalStmt, is_last: bool) {
        self._head("ConditionalStmt", is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._head("cond", false); self.p.newline();
        self.p.enter(false); self._child_expr(stmt->cond, true); self.p.leave();
        var has_else = (stmt->else_ != &null);
        self._head("then", !has_else); self.p.newline();
        self.p.enter(!has_else); self._child_stmt(static_cast::<*Stmt>(stmt->then_), true); self.p.leave();
        if has_else {
            self._head("else", true); self.p.newline();
            self.p.enter(true); self._child_stmt(stmt->else_, true); self.p.leave();
        }
        self.p.leave();
    }

    fn _ds_while(self, stmt: *WhileLoopStmt, is_last: bool) {
        self._head("WhileLoopStmt", is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(stmt->cond, false);
        self._child_stmt(static_cast::<*Stmt>(stmt->body), true);
        self.p.leave();
    }

    fn _ds_loop(self, stmt: *LoopStmt, is_last: bool) {
        self._head("LoopStmt", is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_stmt(static_cast::<*Stmt>(stmt->body), true);
        self.p.leave();
    }

    fn _ds_ranged_for(self, stmt: *RangedForStmt, is_last: bool) {
        self._head("RangedForStmt", is_last);
        if stmt->is_eval { self._dim("eval"); }
        self.p.put(" ");
        self._src_binding_list(stmt->bindings);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(stmt->iterable, false);
        self._child_stmt(static_cast::<*Stmt>(stmt->body), true);
        self.p.leave();
    }

    fn _ds_indexed_for(self, stmt: *IndexedForStmt, is_last: bool) {
        self._head("IndexedForStmt", is_last);
        if stmt->is_eval { self._dim("eval"); }
        self.p.newline();
        self.p.enter(is_last);
        self._child_stmt(stmt->init, false);
        self._child_expr(stmt->cond, false);
        self._child_expr(stmt->update, false);
        self._child_stmt(static_cast::<*Stmt>(stmt->body), true);
        self.p.leave();
    }

    fn _ds_match(self, stmt: *MatchStmt, is_last: bool) {
        self._head("MatchStmt", is_last);
        self._dim(f"({stmt->cases.size()} cases)");
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(stmt->scrutinee, stmt->cases.is_empty());
        for var i: usize = 0; i < stmt->cases.size(); ++i {
            self._dump_match_case(stmt->cases.get(i), (i == stmt->cases.size() - 1));
        }
        self.p.leave();
    }

    fn _ds_labeled(self, stmt: *LabeledStmt, is_last: bool) {
        self._head("LabeledStmt", is_last);
        self.p.put(" ");
        self.p.paint(Color::Ident, self.tok(stmt->label));
        self.p.newline();
        self.p.enter(is_last);
        self._child_stmt(stmt->inner, true);
        self.p.leave();
    }

    fn _ds_try(self, stmt: *TryCatchStmt, is_last: bool) {
        self._head("TryCatchStmt", is_last);
        self._dim(f"({stmt->arms.size()} arms)");
        self.p.newline();
        self.p.enter(is_last);
        self._child_stmt(static_cast::<*Stmt>(stmt->try_body), stmt->arms.is_empty());
        for var i: usize = 0; i < stmt->arms.size(); ++i {
            var arm  = stmt->arms.get(i);
            var last = (i == stmt->arms.size() - 1);
            self._head("catch", last);
            if arm->binding != &null {
                self.p.put(" ");
                self.p.paint(Color::Ident, self.tok(arm->binding->name));
            }
            if arm->filter != &null { self._inline_type(arm->filter); }
            self.p.newline();
            self.p.enter(last);
            self._child_stmt(static_cast::<*Stmt>(arm->body), true);
            self.p.leave();
        }
        self.p.leave();
    }

    fn _ds_block_stmt(self, kind: string, body: *CompoundStmt, is_last: bool) {
        self._head(kind, is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_stmt(static_cast::<*Stmt>(body), true);
        self.p.leave();
    }

    fn _ds_context(self, stmt: *ContextBindingStmt, is_last: bool) {
        self._head("ContextBindingStmt", is_last);
        self.p.put(" as ");
        self._src_binding_list(stmt->bindings);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(stmt->value, false);
        self._child_stmt(static_cast::<*Stmt>(stmt->body), true);
        self.p.leave();
    }

    fn _ds_destructure(self, stmt: *DestructuringDeclStmt, is_last: bool) {
        self._head("DestructuringDeclStmt", is_last);
        self.p.put(" ");
        self.p.paint(Color::Dim, (("tuple ") if (stmt->kind_ == DestructureKind::Tuple) else ("struct ")));
        self.p.paint(Color::Keyword, (("const") if (stmt->leading_is_const) else ("var")));
        self.p.put(" ");
        var is_tuple = (stmt->kind_ == DestructureKind::Tuple);
        self.p.paint(Color::Punct, (("(") if (is_tuple) else ("{")));
        self._src_binding_list(stmt->bindings);
        self.p.paint(Color::Punct, ((")") if (is_tuple) else ("}")));
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(stmt->value, true);
        self.p.leave();
    }

    fn _ds_eval_block(self, stmt: *EvalBlockStmt, is_last: bool) {
        self._head("EvalBlockStmt", is_last);
        self._dim(f"({stmt->body.size()} decls)");
        self.p.newline();
        self.p.enter(is_last);
        for var i: usize = 0; i < stmt->body.size(); ++i {
            self._child_decl(stmt->body[i], (i == stmt->body.size() - 1));
        }
        self.p.leave();
    }

    fn _ds_one_expr(self, kind: string, e: *Expr, is_last: bool) {
        self._head(kind, is_last);
        self.p.newline();
        self.p.enter(is_last);
        self._child_expr(e, true);
        self.p.leave();
    }

    // ======================================================================
    //  DECL dump row
    //
    //  Every aggregate now walks dc_decls (DeclContext) the COMPLETE
    //  source-ordered member list  instead of the fields/methods/variants
    //  projection caches that dropped nested types and VisibilityGroupDecl.
    //  Every decl row also renders written visibility + annotation child rows.
    // ======================================================================

    fn dump_decl_row(self, decl: *Decl, is_last: bool) {
        if decl == &null    { self._head("<null-decl>", is_last); self.p.newline(); return; }
        if decl->is_error() { self._head("RecoveryDecl", is_last); self._dim(self._recovery_name(self._decl_kind_name_of(decl->recovery_kind))); self.p.newline(); return; }

        if isa::<FunctionDecl>(decl)        { self._dd_function(cast::<FunctionDecl>(decl), is_last);        return; }
        if isa::<VariableDecl>(decl)        { self._dd_variable(cast::<VariableDecl>(decl), is_last);        return; }
        if isa::<FieldDecl>(decl)           { self._dd_field(cast::<FieldDecl>(decl), is_last);             return; }
        if isa::<ParamDecl>(decl)           { self._dd_param(cast::<ParamDecl>(decl), is_last);             return; }
        if isa::<GenericParamDecl>(decl)    { self._dd_leaf_src("GenericParamDecl", decl, is_last);          return; }
        if isa::<StructDecl>(decl)          { self._dd_struct(cast::<StructDecl>(decl), is_last);           return; }
        if isa::<ClassDecl>(decl)           { self._dd_class(cast::<ClassDecl>(decl), is_last);             return; }
        if isa::<InterfaceDecl>(decl)       { self._dd_interface(cast::<InterfaceDecl>(decl), is_last);     return; }
        if isa::<ExtensionDecl>(decl)       { self._dd_extension(cast::<ExtensionDecl>(decl), is_last);     return; }
        if isa::<EnumDecl>(decl)            { self._dd_enum(cast::<EnumDecl>(decl), is_last);               return; }
        if isa::<EnumVariantDecl>(decl)     { self._dd_enum_variant(cast::<EnumVariantDecl>(decl), is_last); return; }
        if isa::<UnionDecl>(decl)           { self._dd_union(cast::<UnionDecl>(decl), is_last);             return; }
        if isa::<TypeAliasDecl>(decl)       { self._dd_type_alias(cast::<TypeAliasDecl>(decl), is_last);    return; }
        if isa::<ModuleDecl>(decl)          { self._dd_module(cast::<ModuleDecl>(decl), is_last);           return; }
        if isa::<ImportDecl>(decl)          { self._dd_leaf_src("ImportDecl", decl, is_last);                return; }
        if isa::<VisibilityGroupDecl>(decl) { self._dd_vis_group(cast::<VisibilityGroupDecl>(decl), is_last); return; }
        if isa::<EvalBlockDecl>(decl)       { self._dd_eval_block(cast::<EvalBlockDecl>(decl), is_last);    return; }
        if isa::<TestDecl>(decl)            { self._dd_test(cast::<TestDecl>(decl), is_last);               return; }
        if isa::<MacroDecl>(decl)           { self._dd_leaf_src("MacroDecl", decl, is_last);                 return; }
        if isa::<ProcedureMacroDecl>(decl)  { self._dd_proc_macro(cast::<ProcedureMacroDecl>(decl), is_last); return; }

        self._head("<unknown-decl>", is_last); self.p.newline();
    }

    /// Decl whose whole content reads fine on one line: tag + visibility +
    /// source form. Attributes (if any) still get their own child rows.
    fn _dd_leaf_src(self, kind: string, decl: *Decl, is_last: bool) {
        self._head(kind, is_last);
        self._dump_vis(decl);
        self.p.put(" \x27");
        self.src_decl(decl);
        self.p.put("\x27");
        self.p.newline();
        if self._has_annotations(decl) {
            self.p.enter(is_last);
            self._dump_annotations(decl, true);
            self.p.leave();
        }
    }

    /// Open the decl's child scope and emit annotation rows first. Returns
    /// nothing; caller has already called enter(). Use when a decl has BOTH
    /// annotations and structural children: annotations are never last.
    fn _emit_annotations_if_any(self, decl: *Decl, has_struct_children: bool) {
        if self._has_annotations(decl) {
            // attrs are last only when there are no structural children.
            self._dump_annotations(decl, !has_struct_children);
        }
    }

    fn _dd_function(self, fd: *FunctionDecl, is_last: bool) {
        self._head("FunctionDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(fd));
        self.p.put(" ");
        self._generic_params(fd->generic_params);
        self.p.put(" ");
        if fd->is_operator {
            self.p.put("op ");
            self.p.paint(Color::Operator, self.tok(fd->op_token));
            self.p.put(" ");
        } else {
            self.p.paint(Color::Ident, self.tok(fd->name));
        }
        // signature (params + return) inline; body explodes as the child.
        self._param_list(fd->params, fd->is_variadic);
        if fd->is_noreturn { self.p.paint(Color::Punct, " -> "); self.p.paint(Color::Operator, "!"); }
        else if fd->return_type != &null { self.p.paint(Color::Punct, " -> "); self.src_type(fd->return_type); }
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(fd));
        var has_body  = (fd->body_kind == FnBodyKind::Block && (fd->body_block != &null))
                     || (fd->body_kind == FnBodyKind::Expr  && (fd->body_expr  != &null));

        if (!has_attrs) && !has_body { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(fd), !has_body); }
        if fd->body_kind == FnBodyKind::Block && (fd->body_block != &null) {
            self._child_stmt(static_cast::<*Stmt>(fd->body_block), true);
        } else if fd->body_kind == FnBodyKind::Expr && (fd->body_expr != &null) {
            self._child_expr(fd->body_expr, true);
        }
        self.p.leave();
    }

    fn _dd_variable(self, vd: *VariableDecl, is_last: bool) {
        self._head("VariableDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(vd));
        self.p.put(" ");
        self.p.paint(Color::Keyword, self._storage_kw(vd->storage));
        self.p.put(" ");
        self.p.paint(Color::Ident, self.tok(vd->name));
        // a generic-bearing type becomes its own child subtree; a leaf type
        // stays inline on this row.
        var ty_child = (vd->type_ != &null) && self._type_is_expandable(vd->type_);
        if (vd->type_ != &null) && !ty_child { self.p.paint(Color::Punct, ": "); self.src_type(vd->type_); }
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(vd));
        var has_init  = (vd->init != &null);
        if (!has_attrs) && (!ty_child) && !has_init { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(vd), !(ty_child || has_init)); }
        if ty_child  { self._child_type(vd->type_, !has_init); }
        if has_init  { self._child_expr(vd->init, true); }
        self.p.leave();
    }

    fn _dd_field(self, fd: *FieldDecl, is_last: bool) {
        self._head("FieldDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(fd));
        self.p.put(" ");
        if fd->is_mutable { self.p.paint(Color::Keyword, "mutable "); }
        self.p.paint(Color::Keyword, self._storage_kw(fd->storage));
        self.p.put(" ");
        self.p.paint(Color::Ident, self.tok(fd->name));
        var ty_child = (fd->type_ != &null) && self._type_is_expandable(fd->type_);
        if (fd->type_ != &null) && !ty_child { self.p.paint(Color::Punct, ": "); self.src_type(fd->type_); }
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(fd));
        var has_init  = (fd->init != &null);
        if (!has_attrs) && (!ty_child) && !has_init { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(fd), !(ty_child || has_init)); }
        if ty_child  { self._child_type(fd->type_, !has_init); }
        if has_init  { self._child_expr(fd->init, true); }
        self.p.leave();
    }

    fn _dd_param(self, pd: *ParamDecl, is_last: bool) {
        self._head("ParamDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(pd));
        self.p.put(" ");
        self.src_decl(static_cast::<*Decl>(pd));
        self.p.newline();
        if self._has_annotations(static_cast::<*Decl>(pd)) {
            self.p.enter(is_last);
            self._dump_annotations(static_cast::<*Decl>(pd), true);
            self.p.leave();
        }
    }

    // -- aggregate dumps: walk dc_decls, not projection caches --------------

    // ======================================================================
    //  AGGREGATE MEMBER DUMP  (parser-accurate)
    //
    //  Reality of the current parser (DeclParse.k), NOT the aspirational
    //  DeclContext.k comment:
    //
    //    - A type body's flat members (fields, methods) live in the node's
    //      `fields` / `methods` projection lists. Members written inside a
    //      `pub { }` group ALSO live there, with visibility already stamped
    //      on each. dc_decls does NOT contain them.
    //    - dc_decls for a TYPE body holds ONLY: nested type decls (added via
    //      owner->add_decl) and the VisibilityGroupDecl wrapper node. The
    //      wrapper's `members` are pointers back into fields/methods, so
    //      rendering the wrapper as a container double-prints them.
    //    - Enums: members are in `variants`; dc_decls is EMPTY (the enum body
    //      parser never calls add_decl). Struct/union: fields + nested types.
    //    - Modules: everything is in dc_decls (no projection caches, no
    //      groups) -> walk dc_decls directly.
    //
    //  Correct dump = every member once, in source order, with its stamped
    //  visibility. We achieve this by collecting fields + methods + the
    //  nested-type decls from dc_decls (skipping VisibilityGroupDecl, whose
    //  contents are already in fields/methods), sorting by range.start, and
    //  emitting. The per-member `pub`/`prot`/`priv` the parser stamped is
    //  more honest in a tree than a group wrapper, so the group node is
    //  intentionally not rendered as a container.
    // ======================================================================

    /// Collect every real member of a type body into `out`, in source order.
    /// fields + methods (flat lists, include grouped members with visibility
    /// stamped) + nested-type decls from dc_decls (skip VisibilityGroupDecl).
    fn _collect_type_members(
        self,
        dc:      *DeclContext,
        fields:  FrozenList::<*FieldDecl>,
        methods: FrozenList::<*FunctionDecl>,
        out:     *vec::<*Decl>
    ) {
        for var i: usize = 0; i < fields.size(); ++i {
            out->push_back(static_cast::<*Decl>(fields[i]));
        }
        for var i: usize = 0; i < methods.size(); ++i {
            out->push_back(static_cast::<*Decl>(methods[i]));
        }
        // dc_decls: nested types + VisibilityGroupDecl wrappers. Take the
        // nested types; skip the wrappers (their members are already above).
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            if isa::<VisibilityGroupDecl>(d) { continue; }
            out->push_back(d);
        }
        self._sort_by_source(out);
    }

    /// Stable insertion sort on range.start (offset). Member counts in a type
    /// body are small; insertion sort keeps it simple and stable for equal
    /// positions (which shouldn't occur but we don't want a swap if they do).
    fn _sort_by_source(self, xs: *vec::<*Decl>) {
        var n = xs->size();
        for var i: usize = 1; i < n; ++i {
            var key = (*xs)[i];
            var key_pos = key->range.start;
            var j = i;
            while (j > 0) && ((*xs)[j - 1]->range.start > key_pos) {
                (*xs)[j] = (*xs)[j - 1];
                j -= 1;
            }
            (*xs)[j] = key;
        }
    }

    /// Emit annotation rows for the aggregate, then its members in source
    /// order. `members` is the pre-collected, pre-sorted list.
    fn _dump_members(self, decl: *Decl, members: *vec::<*Decl>, is_last: bool) {
        var has_attrs = self._has_annotations(decl);
        var n = members->size();
        if (!has_attrs) && (n == 0) { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(decl, n == 0); }
        for var i: usize = 0; i < n; ++i {
            self._child_decl((*members)[i], (i == n - 1));
        }
        self.p.leave();
    }

    fn _dd_struct(self, sd: *StructDecl, is_last: bool) {
        self._head("StructDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(sd));
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(sd->name));
        self._inherit_list("impl", sd->implements);
        self.p.newline();
        var empty_methods: FrozenList::<*FunctionDecl>;
        var members = vec::<*Decl>();
        self._collect_type_members(static_cast::<*DeclContext>(sd), sd->fields, empty_methods, &members);
        self._dump_members(static_cast::<*Decl>(sd), &members, is_last);
    }

    fn _dd_class(self, cd: *ClassDecl, is_last: bool) {
        self._head("ClassDecl", is_last);
        if cd->is_final { self._dim("final"); }
        self._dump_vis(static_cast::<*Decl>(cd));
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(cd->name));
        self._inherit_list("derives", cd->derives_list);
        self._inherit_list("impl", cd->implements);
        self.p.newline();
        var members = vec::<*Decl>();
        self._collect_type_members(static_cast::<*DeclContext>(cd), cd->fields, cd->methods, &members);
        self._dump_members(static_cast::<*Decl>(cd), &members, is_last);
    }

    fn _dd_interface(self, id: *InterfaceDecl, is_last: bool) {
        self._head("InterfaceDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(id));
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(id->name));
        self._inherit_list("derives", id->derives_list);
        self.p.newline();
        var empty_fields: FrozenList::<*FieldDecl>;
        var members = vec::<*Decl>();
        self._collect_type_members(static_cast::<*DeclContext>(id), empty_fields, id->methods, &members);
        self._dump_members(static_cast::<*Decl>(id), &members, is_last);
    }

    fn _dd_extension(self, ed: *ExtensionDecl, is_last: bool) {
        self._head("ExtensionDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(ed));
        self.p.put(" ");
        self.src_type(ed->target);
        self._inherit_list("impl", ed->implements);
        self.p.newline();
        var empty_fields: FrozenList::<*FieldDecl>;
        var members = vec::<*Decl>();
        self._collect_type_members(static_cast::<*DeclContext>(ed), empty_fields, ed->methods, &members);
        self._dump_members(static_cast::<*Decl>(ed), &members, is_last);
    }

    fn _dd_union(self, ud: *UnionDecl, is_last: bool) {
        self._head("UnionDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(ud));
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(ud->name));
        self.p.newline();
        var empty_methods: FrozenList::<*FunctionDecl>;
        var members = vec::<*Decl>();
        self._collect_type_members(static_cast::<*DeclContext>(ud), ud->fields, empty_methods, &members);
        self._dump_members(static_cast::<*Decl>(ud), &members, is_last);
    }

    /// Enum: members are in `variants` (the parser never adds them to
    /// dc_decls; the enum body has no nested-type parsing at all). Walk
    /// variants directly. No source-order merge needed -- variants is already
    /// in declaration order.
    fn _dd_enum(self, en: *EnumDecl, is_last: bool) {
        self._head("EnumDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(en));
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(en->name));
        if en->underlying != &null { self.p.paint(Color::Keyword, " derives "); self.src_type(en->underlying); }
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(en));
        var n = en->variants.size();
        if (!has_attrs) && (n == 0) { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(en), n == 0); }
        for var i: usize = 0; i < n; ++i {
            self._child_decl(static_cast::<*Decl>(en->variants[i]), (i == n - 1));
        }
        self.p.leave();
    }

    /// Module: every member is in dc_decls (no projection caches, no group
    /// wrappers). Walk dc_decls directly, in source order as the parser
    /// appended it.
    fn _dd_module(self, md: *ModuleDecl, is_last: bool) {
        self._head("ModuleDecl", is_last);
        if md->is_inline { self._dim("inline"); }
        self._dump_vis(static_cast::<*Decl>(md));
        if !md->is_anonymous {
            self.p.put(" ");
            self.p.paint(Color::Ident, self.tok(md->name));
        }
        self.p.newline();

        var dc = static_cast::<*DeclContext>(md);
        var has_attrs = self._has_annotations(static_cast::<*Decl>(md));
        var n = dc->dc_decls.size();
        if !has_attrs && (n == 0) { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(md), n == 0); }
        for var i: usize = 0; i < n; ++i {
            self._child_decl(*(dc->dc_decls.get(i)), (i == n - 1));
        }
        self.p.leave();
    }

    fn _dd_enum_variant(self, v: *EnumVariantDecl, is_last: bool) {
        self._head("EnumVariantDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(v));
        self.p.put(" ");
        self.p.paint(Color::Ident, self.tok(v->name));
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(v));
        var has_disc  = (v->discriminant != &null);
        var npayload  = v->payload.size();
        if (!has_attrs) && (!has_disc) && (npayload == 0) { return; }

        self.p.enter(is_last);
        if has_attrs {
            var attrs_last = (!has_disc) && (npayload == 0);
            self._dump_annotations(static_cast::<*Decl>(v), attrs_last);
        }
        if has_disc {
            var disc_last = (npayload == 0);
            self._head("discriminant", disc_last); self.p.newline();
            self.p.enter(disc_last);
            self._child_expr(v->discriminant, true);
            self.p.leave();
        }
        for var i: usize = 0; i < npayload; ++i {
            self._child_decl(static_cast::<*Decl>(*(v->payload.get(i))), (i == npayload - 1));
        }
        self.p.leave();
    }

    fn _dd_type_alias(self, ta: *TypeAliasDecl, is_last: bool) {
        self._head("TypeAliasDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(ta));
        self.p.put(" ");
        self.p.paint(Color::TypeName, self.tok(ta->name));
        self.p.paint(Color::Punct, " = ");
        self.src_type(ta->aliased);
        self.p.newline();
        if self._has_annotations(static_cast::<*Decl>(ta)) {
            self.p.enter(is_last);
            self._dump_annotations(static_cast::<*Decl>(ta), true);
            self.p.leave();
        }
    }

    fn _dd_vis_group(self, vg: *VisibilityGroupDecl, is_last: bool) {
        self._head("VisibilityGroupDecl", is_last);
        self.p.put(" ");
        self._vis(vg->group_visibility);
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(vg));
        var n = vg->members.size();
        if (!has_attrs) && (n == 0) { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(vg), n == 0); }
        for var i: usize = 0; i < n; ++i {
            self._child_decl(vg->members[i], (i == n - 1));
        }
        self.p.leave();
    }

    fn _dd_eval_block(self, eb: *EvalBlockDecl, is_last: bool) {
        self._head("EvalBlockDecl", is_last);
        self.p.newline();
        var has_attrs = self._has_annotations(static_cast::<*Decl>(eb));
        var n = eb->body.size();
        if (!has_attrs) && (n == 0) { return; }
        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(eb), n == 0); }
        for var i: usize = 0; i < n; ++i {
            self._child_decl(eb->body[i], (i == n - 1));
        }
        self.p.leave();
    }

    fn _dd_test(self, td: *TestDecl, is_last: bool) {
        self._head("TestDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(td));
        if td->label != &null { self.p.put(" "); self.src_expr(td->label); }
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(td));
        var has_body  = (td->body != &null);
        if (!has_attrs) && !has_body { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(td), !has_body); }
        if has_body { self._child_stmt(static_cast::<*Stmt>(td->body), true); }
        self.p.leave();
    }

    fn _dd_proc_macro(self, pm: *ProcedureMacroDecl, is_last: bool) {
        self._head("ProcedureMacroDecl", is_last);
        self._dump_vis(static_cast::<*Decl>(pm));
        self.p.put(" ");
        self.p.paint(Color::Attr, f"@{self.tok(pm->name)}");
        self._param_list(pm->params, false);
        self.p.newline();

        var has_attrs = self._has_annotations(static_cast::<*Decl>(pm));
        var has_body  = (pm->body != &null);
        if (!has_attrs) && !has_body { return; }

        self.p.enter(is_last);
        if has_attrs { self._dump_annotations(static_cast::<*Decl>(pm), !has_body); }
        if has_body { self._child_stmt(static_cast::<*Stmt>(pm->body), true); }
        self.p.leave();
    }

    // ======================================================================
    //  PUBLIC DUMP FACADES (entry points)
    //
    //  Each sets _pending_last and routes through the overridden dispatcher
    //  via self.dyn() so the CRTP contract holds. A top-level node defaults
    //  to is_last = true.
    // ======================================================================

    fn dump_type(self, ty: *Type, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_type(ty);
    }
    fn dump_expr(self, e: *Expr, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_expr(e);
    }
    fn dump_pattern(self, pat: *Pattern, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_pattern(pat);
    }
    fn dump_stmt(self, stmt: *Stmt, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_stmt(stmt);
    }
    fn dump_decl(self, decl: *Decl, is_last: bool) {
        self._pending_last = is_last;
        self.dyn()->dispatch_decl(decl);
    }

    // ======================================================================
    //  NODE-KIND NAMES  (UNCHANGED)
    // ======================================================================

    fn _expr_kind_name(self, e: *Expr) -> string { return self._expr_kind_name_of(e->kind); }
    fn _type_kind_name(self, ty: *Type) -> string { return self._type_kind_name_of(ty->kind); }
    fn _pattern_kind_name(self, pat: *Pattern) -> string { return self._pattern_kind_name_of(pat->kind); }

    fn _recovery_name(self, intended: string) -> string {
        return f"trying: {intended}";
    }

    fn _expr_kind_name_of(self, k: ExprKind) -> string {
        switch k {
            case ExprKind::IntegerLiteralExpr       { return "IntegerLiteralExpr";       }
            case ExprKind::FloatingLiteralExpr      { return "FloatingLiteralExpr";      }
            case ExprKind::StringLiteralExpr        { return "StringLiteralExpr";        }
            case ExprKind::CharacterLiteralExpr     { return "CharacterLiteralExpr";     }
            case ExprKind::BooleanLiteralExpr       { return "BooleanLiteralExpr";       }
            case ExprKind::NullLiteralExpr          { return "NullLiteralExpr";          }
            case ExprKind::ListLiteralExpr          { return "ListLiteralExpr";          }
            case ExprKind::TupleLiteralExpr         { return "TupleLiteralExpr";         }
            case ExprKind::SetLiteralExpr           { return "SetLiteralExpr";           }
            case ExprKind::MapLiteralExpr           { return "MapLiteralExpr";           }
            case ExprKind::NamedInitializerExpr     { return "NamedInitializerExpr";     }
            case ExprKind::AnonInitializerExpr      { return "AnonInitializerExpr";      }
            case ExprKind::ChainExpr                { return "ChainExpr";                }
            case ExprKind::CallExpr                 { return "CallExpr";                 }
            case ExprKind::SubscriptExpr            { return "SubscriptExpr";            }
            case ExprKind::NamedIdentExpr           { return "NamedIdentExpr";           }
            case ExprKind::UnaryOperatorExpr        { return "UnaryOperatorExpr";        }
            case ExprKind::BinaryOperatorExpr       { return "BinaryOperatorExpr";       }
            case ExprKind::AssignOperatorExpr       { return "AssignOperatorExpr";       }
            case ExprKind::ImplConformanceExpr      { return "ImplConformanceExpr";      }
            case ExprKind::DerivesRelationExpr      { return "DerivesRelationExpr";      }
            case ExprKind::IfExpr                   { return "IfExpr";                   }
            case ExprKind::TryCatchExpr             { return "TryCatchExpr";             }
            case ExprKind::MatchExpr                { return "MatchExpr";                }
            case ExprKind::RangeExpr                { return "RangeExpr";                }
            case ExprKind::ClosureExpr              { return "ClosureExpr";              }
            case ExprKind::AwaitExpr                { return "AwaitExpr";                }
            case ExprKind::SpawnExpr                { return "SpawnExpr";                }
            case ExprKind::ThreadExpr               { return "ThreadExpr";               }
            case ExprKind::SizeOfExpr               { return "SizeOfExpr";               }
            case ExprKind::AlignOfExpr              { return "AlignOfExpr";              }
            case ExprKind::TypeOfExpr               { return "TypeOfExpr";               }
            case ExprKind::EvalExpr                 { return "EvalExpr";                 }
            case ExprKind::UnsafeExpr               { return "UnsafeExpr";               }
            case ExprKind::DeleteExpr               { return "DeleteExpr";               }
            case ExprKind::PackExpansionExpr        { return "PackExpansionExpr";        }
            case ExprKind::TypeCastExpr             { return "TypeCastExpr";             }
            case ExprKind::ImplicitBoundaryCastExpr { return "ImplicitBoundaryCastExpr"; }
            default                                 { return "<expr>";                  }
        }
    }

    fn _type_kind_name_of(self, k: TypeKind) -> string {
        switch k {
            case TypeKind::ChainType             { return "ChainType";             }
            case TypeKind::GenericParamType      { return "GenericParamType";      }
            case TypeKind::SubstGenericParamType { return "SubstGenericParamType"; }
            case TypeKind::TypeOfType            { return "TypeOfType";            }
            case TypeKind::VariadicPackType      { return "VariadicPackType";      }
            case TypeKind::PackExpansionType     { return "PackExpansionType";     }
            case TypeKind::PointerType           { return "PointerType";           }
            case TypeKind::NullableType          { return "NullableType";          }
            case TypeKind::TupleType             { return "TupleType";             }
            case TypeKind::FixedArrayType        { return "FixedArrayType";        }
            case TypeKind::VectorType            { return "VectorType";            }
            case TypeKind::MapType               { return "MapType";               }
            case TypeKind::SetType               { return "SetType";               }
            case TypeKind::SelfType              { return "SelfType";              }
            case TypeKind::FunctionPointerType   { return "FunctionPointerType";   }
            case TypeKind::InferredType          { return "InferredType";          }
            case TypeKind::CXXLValueRefType      { return "CXXLValueRefType";      }
            case TypeKind::CXXRValueRefType      { return "CXXRValueRefType";      }
            case TypeKind::OpaqueFFIType         { return "OpaqueFFIType";         }
            case TypeKind::TypeExpr              { return "TypeExpr";              }
            default                              { return "<type>";               }
        }
    }

    fn _pattern_kind_name_of(self, k: PatternKind) -> string {
        switch k {
            case PatternKind::WildcardPattern              { return "WildcardPattern";              }
            case PatternKind::LiteralPattern               { return "LiteralPattern";               }
            case PatternKind::BindingPattern               { return "BindingPattern";               }
            case PatternKind::TupleDestructurePattern      { return "TupleDestructurePattern";      }
            case PatternKind::ConstructorPattern           { return "ConstructorPattern";           }
            case PatternKind::UnresolvedConstructorPattern { return "UnresolvedConstructorPattern"; }
            case PatternKind::AlternationPattern           { return "AlternationPattern";           }
            case PatternKind::RangePattern                 { return "RangePattern";                 }
            case PatternKind::SlicePattern                 { return "SlicePattern";                 }
            default                                        { return "<pattern>";                   }
        }
    }

    fn _stmt_kind_name_of(self, k: StmtKind) -> string {
        switch k {
            case StmtKind::CompoundStmt          { return "CompoundStmt";          }
            case StmtKind::ExpressionStmt        { return "ExpressionStmt";        }
            case StmtKind::DeclStmt              { return "DeclStmt";              }
            case StmtKind::ReturnStmt            { return "ReturnStmt";            }
            case StmtKind::BreakStmt             { return "BreakStmt";             }
            case StmtKind::ContinueStmt          { return "ContinueStmt";          }
            case StmtKind::PanicStmt             { return "PanicStmt";             }
            case StmtKind::YieldStmt             { return "YieldStmt";             }
            case StmtKind::RuntimeAssertStmt     { return "RuntimeAssertStmt";     }
            case StmtKind::StaticAssertStmt      { return "StaticAssertStmt";      }
            case StmtKind::LabelIntrinsicStmt    { return "LabelIntrinsicStmt";    }
            case StmtKind::JumpIntrinsicStmt     { return "JumpIntrinsicStmt";     }
            case StmtKind::ConditionalStmt       { return "ConditionalStmt";       }
            case StmtKind::WhileLoopStmt         { return "WhileLoopStmt";         }
            case StmtKind::LoopStmt              { return "LoopStmt";              }
            case StmtKind::RangedForStmt         { return "RangedForStmt";         }
            case StmtKind::IndexedForStmt        { return "IndexedForStmt";        }
            case StmtKind::MatchStmt             { return "MatchStmt";             }
            case StmtKind::LabeledStmt           { return "LabeledStmt";           }
            case StmtKind::TryCatchStmt          { return "TryCatchStmt";          }
            case StmtKind::FinallyStmt           { return "FinallyStmt";           }
            case StmtKind::UnsafeBlockStmt       { return "UnsafeBlockStmt";       }
            case StmtKind::ContextBindingStmt    { return "ContextBindingStmt";    }
            case StmtKind::DestructuringDeclStmt { return "DestructuringDeclStmt"; }
            case StmtKind::InlineBlockStmt       { return "InlineBlockStmt";       }
            case StmtKind::EvalBlockStmt         { return "EvalBlockStmt";         }
            default                              { return "<stmt>";                }
        }
    }

    fn _decl_kind_name_of(self, k: DeclKind) -> string {
        switch k {
            case DeclKind::FunctionDecl        { return "FunctionDecl";        }
            case DeclKind::VariableDecl        { return "VariableDecl";        }
            case DeclKind::FieldDecl           { return "FieldDecl";           }
            case DeclKind::ParamDecl           { return "ParamDecl";           }
            case DeclKind::GenericParamDecl    { return "GenericParamDecl";    }
            case DeclKind::StructDecl          { return "StructDecl";          }
            case DeclKind::ClassDecl           { return "ClassDecl";           }
            case DeclKind::InterfaceDecl       { return "InterfaceDecl";       }
            case DeclKind::ExtensionDecl       { return "ExtensionDecl";       }
            case DeclKind::EnumDecl            { return "EnumDecl";            }
            case DeclKind::EnumVariantDecl     { return "EnumVariantDecl";     }
            case DeclKind::UnionDecl           { return "UnionDecl";           }
            case DeclKind::TypeAliasDecl       { return "TypeAliasDecl";       }
            case DeclKind::ModuleDecl          { return "ModuleDecl";          }
            case DeclKind::ImportDecl          { return "ImportDecl";          }
            case DeclKind::VisibilityGroupDecl { return "VisibilityGroupDecl"; }
            case DeclKind::EvalBlockDecl       { return "EvalBlockDecl";       }
            case DeclKind::TestDecl            { return "TestDecl";            }
            case DeclKind::MacroDecl           { return "MacroDecl";           }
            case DeclKind::ProcedureMacroDecl  { return "ProcedureMacroDecl";  }
            default                            { return "<decl>";              }
        }
    }
}

// ==========================================================================
//  PUBLIC FACADES  (UNCHANGED API; debug path now RAV-driven)
// ==========================================================================

class TypePrinter {
    static fn print(ty: *Type, ctx: *ASTContext) -> string {
        return TypePrinter::print(ty, ctx, PrintOptions::diag());
    }
    static fn print(ty: *Type, ctx: *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts);
        if opts.is_debug() { d.dump_type(ty, true); } else { d.src_type(ty); }
        return d.p.out;
    }
}

class ExprPrinter {
    static fn print(e: *Expr, ctx: *ASTContext) -> string {
        return ExprPrinter::print(e, ctx, PrintOptions::diag());
    }
    static fn print(e: *Expr, ctx: *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts);
        if opts.is_debug() { d.dump_expr(e, true); } else { d.src_expr(e); }
        return d.p.out;
    }
}

class StmtPrinter {
    static fn print(stmt: *Stmt, ctx: *ASTContext) -> string {
        return StmtPrinter::print(stmt, ctx, PrintOptions::diag());
    }
    static fn print(stmt: *Stmt, ctx: *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts);
        if opts.is_debug() { d.dump_stmt(stmt, true); } else { d.src_stmt(stmt); }
        return d.p.out;
    }
}

class DeclPrinter {
    static fn print(decl: *Decl, ctx: *ASTContext) -> string {
        return DeclPrinter::print(decl, ctx, PrintOptions::diag());
    }
    static fn print(decl: *Decl, ctx: *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts);
        if opts.is_debug() { d.dump_decl(decl, true); } else { d.src_decl(decl); }
        return d.p.out;
    }
}

class PatternPrinter {
    static fn print(pat: *Pattern, ctx: *ASTContext) -> string {
        return PatternPrinter::print(pat, ctx, PrintOptions::diag());
    }
    static fn print(pat: *Pattern, ctx: *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts);
        if opts.is_debug() { d.dump_pattern(pat, true); } else { d.src_pattern(pat); }
        return d.p.out;
    }
}

/// Translation-unit dump for --print-ast. Walks Program's top-level items and
/// routes each through the RAV-overridden dump_* facades, under one shared
/// AstDumper so the tree spine is continuous across items.
class ASTPrinter {
    static fn print(tu: *TranslationUnit) {
        ASTPrinter::print(tu, PrintOptions::dump());
    }

    static fn print(tu: *TranslationUnit, opts: PrintOptions) {
        if tu == &null {
            std::print("<null TranslationUnit>");
            return;
        }
        if tu->ctx == &null {
            std::print("<TranslationUnit with no ASTContext>");
            return;
        }

        var d = AstDumper(tu->ctx, opts);

        var name = tu->ctx->sm->get_filename(tu->fid);
        d.p.paint(Color::NodeKind, "TranslationUnit");
        d.p.put(f" '{name}\x27");
        d.p.paint(Color::Dim, f"(fid={tu->fid})");
        d.p.newline();

        if tu->program == &null {
            d.p.paint(Color::Dim, "<no program>");
            d.p.newline();
            std::print(d.p.out);
            return;
        }

        var prog = tu->program;
        var n    = prog->items.size();
        for var i: usize = 0; i < n; ++i {
            var item = prog->items.get(i);
            if item == &null { continue; }
            var last = (i == n - 1);
            switch item->get_kind() {
                case TopLevelKind::Decl { d.dump_decl(item->as_decl(), last); }
                case TopLevelKind::Stmt { d.dump_stmt(item->as_stmt(), last); }
                case TopLevelKind::Expr { d.dump_expr(item->as_expr(), last); }
                default {
                    d._head("<unknown-top-level>", last);
                    d.p.newline();
                }
            }
        }

        d.p.paint(Color::Dim, f"-- {tu->error_count} error(s), {tu->warn_count} warning(s) --");
        d.p.newline();
        std::print(d.p.out);
        libcxx::fflush(stdout);
    }
}