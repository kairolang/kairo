/// --- The Kairo Project --------------------- AST/Printer/ASTPrinter.k --- ///
///
///   AstDumper: the single AST renderer for the whole compiler.
///
///   Source-faithful path (src_*): the diagnostic and canonical styles
///   reproduce one-line source for sema diagnostics.
///
///   The DEBUG TREE path (--print-ast) is built on RecursiveASTVisitor.
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
///   ATTRIBUTES + VISIBILITY: every decl row prefixes written visibility
///   (pub/prot/priv) and renders each annotation entry (@name). Attribute
///   ARGS are not rendered: AnnotationEntry.args stores no labels, so there
///   is nothing faithful to print.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// --------------------------------------------------------------------- ///

ffi "c++" import "Native/KShims.hh" // std_out / std_err
ffi "c++" import "vector"
ffi "c++" import "cstdio"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::PatternKind::PatternKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
}
import AST::Mixin::TypeQual::TypeQual
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::Patterns::{
    AlternationPattern,
    BindingPattern,
    ConstructorPattern,
    LiteralPattern,
    RangePattern,
    SlicePattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
    WildcardPattern,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Statements
import AST::Node::Types
import AST::ParamMode::{
    ParamMode,
    param_mode_prefix,
}
import AST::Printer::PrintCore::{
    Color,
    Painter,
    PrintOptions,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Token::Token::Token
import Token::TokenKind::TokenKind

/// AstDumper derives RecursiveASTVisitor::<AstDumper> so its dispatch_*
/// overrides are reached through the CRTP dyn() routing. The source-faithful
/// (src_*) methods are independent of RAV and unchanged.
/// The node name the dumper prints for an expression kind. File scope so
/// SemaDump can label a row with the same string the AST dump uses, without
/// a second switch that drifts from this one.
pub fn expr_kind_name(k: ExprKind) -> string {
    match k {
        case ExprKind::IntegerLiteralExpr {
            return "IntegerLiteralExpr"
        } case ExprKind::FloatingLiteralExpr {
            return "FloatingLiteralExpr"
        } case ExprKind::StringLiteralExpr {
            return "StringLiteralExpr"
        } case ExprKind::CharacterLiteralExpr {
            return "CharacterLiteralExpr"
        } case ExprKind::BooleanLiteralExpr {
            return "BooleanLiteralExpr"
        } case ExprKind::NullLiteralExpr {
            return "NullLiteralExpr"
        } case ExprKind::ListLiteralExpr {
            return "ListLiteralExpr"
        } case ExprKind::InitListExpr {
            return "InitListExpr"
        } case ExprKind::StmtExpr {
            return "StmtExpr"
        } case ExprKind::VariantInitExpr {
            return "VariantInitExpr"
        } case ExprKind::TupleLiteralExpr {
            return "TupleLiteralExpr"
        } case ExprKind::SetLiteralExpr {
            return "SetLiteralExpr"
        } case ExprKind::MapLiteralExpr {
            return "MapLiteralExpr"
        } case ExprKind::NamedInitializerExpr {
            return "NamedInitializerExpr"
        } case ExprKind::AnonInitializerExpr {
            return "AnonInitializerExpr"
        } case ExprKind::ChainExpr {
            return "ChainExpr"
        } case ExprKind::CallExpr {
            return "CallExpr"
        } case ExprKind::SubscriptExpr {
            return "SubscriptExpr"
        } case ExprKind::NamedIdentExpr {
            return "NamedIdentExpr"
        } case ExprKind::UnaryOperatorExpr {
            return "UnaryOperatorExpr"
        } case ExprKind::BinaryOperatorExpr {
            return "BinaryOperatorExpr"
        } case ExprKind::AssignOperatorExpr {
            return "AssignOperatorExpr"
        } case ExprKind::ImplConformanceExpr {
            return "ImplConformanceExpr"
        } case ExprKind::DerivesRelationExpr {
            return "DerivesRelationExpr"
        } case ExprKind::IfExpr {
            return "IfExpr"
        } case ExprKind::TryCatchExpr {
            return "TryCatchExpr"
        } case ExprKind::MatchExpr {
            return "MatchExpr"
        } case ExprKind::RangeExpr {
            return "RangeExpr"
        } case ExprKind::ClosureExpr {
            return "ClosureExpr"
        } case ExprKind::AwaitExpr {
            return "AwaitExpr"
        } case ExprKind::UnwrapExpr {
            return "UnwrapExpr"
        } case ExprKind::DefinedExpr {
            return "DefinedExpr"
        } case ExprKind::AttributedExpr {
            return "AttributedExpr"
        } case ExprKind::PanicOpExpr {
            return "PanicOpExpr"
        } case ExprKind::TypeTraitExpr {
            return "TypeTraitExpr"
        } case ExprKind::CxxNewExpr {
            return "CxxNewExpr"
        } case ExprKind::SpawnExpr {
            return "SpawnExpr"
        } case ExprKind::ThreadExpr {
            return "ThreadExpr"
        } case ExprKind::ConstraintExpr {
            return "ConstraintExpr"
        } case ExprKind::SizeOfExpr {
            return "SizeOfExpr"
        } case ExprKind::AlignOfExpr {
            return "AlignOfExpr"
        } case ExprKind::TypeOfExpr {
            return "TypeOfExpr"
        } case ExprKind::EvalExpr {
            return "EvalExpr"
        } case ExprKind::UnsafeExpr {
            return "UnsafeExpr"
        } case ExprKind::ParenExpr {
            return "ParenExpr"
        } case ExprKind::NamedArgExpr {
            return "NamedArgExpr"
        } case ExprKind::VerbatimExpr {
            return "VerbatimExpr"
        } case ExprKind::DeleteExpr {
            return "DeleteExpr"
        } case ExprKind::PackExpansionExpr {
            return "PackExpansionExpr"
        } case ExprKind::TypeCastExpr {
            return "TypeCastExpr"
        } case ExprKind::ImplicitBoundaryCastExpr {
            return "ImplicitBoundaryCastExpr"
        } default {
            return "<expr>"
        }
    }
}

pub class AstDumper derives RecursiveASTVisitor<AstDumper> {
    pub var p:   Painter
    pub var ctx: unsafe *ASTContext

    /// Stashed is_last for the next dispatch_* call. The traverse/dispatch
    /// signature has no is_last slot, so the dumper sets this immediately
    /// before invoking a dispatcher and the override reads it once at entry.
    /// Defaults true so a bare top-level dispatch renders as a last child.
    pub var _pending_last: bool = true

    fn AstDumper(self, ctx: unsafe *ASTContext, opts: PrintOptions) {
        self.ctx = ctx
        self.p   = Painter(opts)
    }

    //  SHARED HELPERS

    /// Resolve a token to its real source spelling. THE fix for the
    /// "identifier" corruption  always source text, never a kind word.
    fn tok(self, t: Token) -> string {
        return self.ctx->get_spelling(t)
    }

    /// Resolve an interned string. Falls back when the hoisted scope is not
    /// wired (FFI-origin symbols have no interner entry in this TU).
    fn istr(self, s: u32) -> string {
        if self.ctx->hoisted != &null {
            return self.ctx->hoisted->str(s)
        }

        return "<ffi>"
    }

    /// True when istr() could not resolve a real name (hoisted unwired).
    /// Used by the attribute renderer to avoid printing the bare sentinel as
    /// if it were a real attribute name.
    fn _istr_unresolved(self) -> bool {
        return self.ctx->hoisted == &null
    }

    fn _expr_list(self, const open: string, const close: string, xs: FrozenList<unsafe *Expr>) {
        self.p.paint(Color::Punct, open)
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_expr(xs[i])
        }

        self.p.paint(Color::Punct, close)
    }

    fn _pat_list(self, xs: FrozenList<unsafe *Pattern>) {
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_pattern(xs[i])
        }
    }

    /// Generic argument list `<...>`. Shared by NamedIdentExpr, ChainExpr
    /// steps, and ChainType segments  all carry ChainType::GenericArg.
    fn _generic_args(self, args: FrozenList<Types::ChainType::GenericArg>) {
        if args.is_empty() {
            return
        }

        self.p.paint(Color::Punct, "<")
        for var i: usize = 0; i < args.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            var unsafe *a = args.get(i)
            if a->name != &null {
                self.p.paint(Color::Ident, self.tok(a->name->name))
                self.p.paint(Color::Punct, ": ")
            }

            self.src_type(a->ty)
        }

        self.p.paint(Color::Punct, ">")
    }

    fn _access_op(self, k: ChainExpr::AccessKind) {
        type AK = ChainExpr::AccessKind
        if k == AK::Dot {
            self.p.paint(Color::Operator, ".")
        } else if k == AK::Arrow {
            self.p.paint(Color::Operator, "->")
        } else if k == AK::ColonColon {
            self.p.paint(Color::Operator, "::")
        } else if k == AK::QuestionDot {
            self.p.paint(Color::Operator, "?.")
        } else if k == AK::QuestionArrow {
            self.p.paint(Color::Operator, "?->")
        }
    }

    /// `pub `/`prot `/`priv ` prefix from the numeric visibility code
    /// (0 None / 1 priv / 2 prot / 3 pub). Source path.
    fn _vis(self, v: u8) {
        if v == 3 {
            self.p.paint(Color::Keyword, "pub ")
        } else if v == 2 {
            self.p.paint(Color::Keyword, "prot ")
        } else if v == 1 {
            self.p.paint(Color::Keyword, "priv ")
        }
    }

    //  TYPES  source-faithful  (UNCHANGED)

    fn _quals(self, ty: unsafe *Type) {
        self._data_quals(ty)
        type TQ = TypeQual<Type>
        var f = ty->flags
        if f.has(TQ::Flags::IsAsync) {
            self.p.paint(Color::Keyword, "async ")
        }

        if f.has(TQ::Flags::IsYield) {
            self.p.paint(Color::Keyword, "yield ")
        }

        if f.has(TQ::Flags::IsPanic) {
            self.p.paint(Color::Keyword, "panic ")
        }
    }

    fn _data_quals(self, ty: unsafe *Type) {
        type TQ = TypeQual<Type>
        var f = ty->flags
        if f.has(TQ::Flags::IsConst) {
            self.p.paint(Color::Keyword, "const ")
        }

        if f.has(TQ::Flags::IsVolatile) {
            self.p.paint(Color::Keyword, "volatile ")
        }

        if f.has(TQ::Flags::IsAtomic) {
            self.p.paint(Color::Keyword, "atomic ")
        }

        if f.has(TQ::Flags::IsUnsafe) {
            self.p.paint(Color::Keyword, "unsafe ")
        }

        if f.has(TQ::Flags::IsEval) {
            self.p.paint(Color::Keyword, "eval ")
        }
    }

    /// ` panic` and, when declared, its set `(E1, E2)` -- the one spelling
    /// for a function header, a closure and a `fn` type.
    fn _panic_spec(self, set: FrozenList<unsafe *Type>) {
        self.p.paint(Color::Keyword, " panic")
        if set.is_empty() {
            return
        }

        self.p.paint(Color::Punct, "(")
        for var i: usize = 0; i < set.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_type(set[i])
        }

        self.p.paint(Color::Punct, ")")
    }

    fn src_type(self, ty: unsafe *Type) {
        if ty == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if ty->is_error() {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if isa<Types::ChainType>(ty) {
            self._t_chain(cast<Types::ChainType>(ty))
            return
        }

        if isa<Types::GenericParamType>(ty) {
            self._t_generic_param(cast<Types::GenericParamType>(ty))
            return
        }

        if isa<Types::SubstGenericParamType>(ty) {
            self.src_type(cast<Types::SubstGenericParamType>(ty)->replacement)
            return
        }

        if isa<Types::TypeOfType>(ty) {
            self._quals(ty)
            self.p.paint(Color::Keyword, "typeof")
            self.p.paint(Color::Punct, "(...)")
            return
        }

        if isa<Types::VariadicPackType>(ty) {
            self.p.paint(Color::Punct, "...")
            self.src_type(cast<Types::VariadicPackType>(ty)->param)
            return
        }

        if isa<Types::PackExpansionType>(ty) {
            self.src_type(cast<Types::PackExpansionType>(ty)->pattern)
            self.p.paint(Color::Punct, "...")
            return
        }

        if isa<Types::PointerType>(ty) {
            // `*(T?)`: unparenthesized it would read back as `(*T)?`.
            var unsafe *pte = cast<Types::PointerType>(ty)->pointee
            self._quals(ty)
            self.p.paint(Color::Punct, "*")
            if isa<Types::NullableType>(pte) {
                self.p.paint(Color::Punct, "(")
                self.src_type(pte)
                self.p.paint(Color::Punct, ")")
                return
            }

            self.src_type(pte)
            return
        }

        if isa<Types::NullableType>(ty) {
            // `(T?)?`: `T??` would read back as the `??` operator.
            var unsafe *inner = cast<Types::NullableType>(ty)->inner
            self._quals(ty)
            if isa<Types::NullableType>(inner) {
                self.p.paint(Color::Punct, "(")
                self.src_type(inner)
                self.p.paint(Color::Punct, ")")
            } else {
                self.src_type(inner)
            }

            self.p.paint(Color::Punct, "?")
            return
        }

        if isa<Types::TupleType>(ty) {
            self._t_tuple(cast<Types::TupleType>(ty))
            return
        }

        if isa<Types::FixedArrayType>(ty) {
            self._t_fixed_array(cast<Types::FixedArrayType>(ty))
            return
        }

        if isa<Types::VectorType>(ty) {
            self._quals(ty)
            self.p.paint(Color::Punct, "[")
            self.src_type(cast<Types::VectorType>(ty)->element)
            self.p.paint(Color::Punct, "]")
            return
        }

        if isa<Types::MapType>(ty) {
            self._t_map(cast<Types::MapType>(ty))
            return
        }

        if isa<Types::SetType>(ty) {
            self._quals(ty)
            self.p.paint(Color::Punct, "{")
            self.src_type(cast<Types::SetType>(ty)->element)
            self.p.paint(Color::Punct, "}")
            return
        }

        if isa<Types::SelfType>(ty) {
            self._quals(ty)
            self.p.paint(Color::TypeName, "Self")
            return
        }

        if isa<Types::FunctionPointerType>(ty) {
            self._t_fn_ptr(cast<Types::FunctionPointerType>(ty))
            return
        }

        if isa<Types::InferredType>(ty) {
            self.p.paint(Color::Punct, "_")
            return
        }

        // Written `ffi::ref<T>` / `ffi::mref<T>`: spelled back as
        // written; the referee carries its own `const`.
        if isa<Types::CXXLValueRefType>(ty) && cast<Types::CXXLValueRefType>(ty)->ffi_spelled {
            self.p.paint(Color::TypeName, "ffi::ref")
            self.p.paint(Color::Punct, "<")
            self.src_type(cast<Types::CXXLValueRefType>(ty)->referee)
            self.p.paint(Color::Punct, ">")
            return
        }

        if isa<Types::CXXRValueRefType>(ty) && cast<Types::CXXRValueRefType>(ty)->ffi_spelled {
            self.p.paint(Color::TypeName, "ffi::mref")
            self.p.paint(Color::Punct, "<")
            self.src_type(cast<Types::CXXRValueRefType>(ty)->referee)
            self.p.paint(Color::Punct, ">")
            return
        }

        if isa<Types::CXXLValueRefType>(ty) {
            self._quals(ty)
            self.src_type(cast<Types::CXXLValueRefType>(ty)->referee)
            self.p.paint(Color::Punct, "&")
            return
        }

        if isa<Types::CXXRValueRefType>(ty) {
            self._quals(ty)
            self.src_type(cast<Types::CXXRValueRefType>(ty)->referee)
            self.p.paint(Color::Punct, "&&")
            return
        }

        if isa<Types::OpaqueFFIType>(ty) {
            self.p.paint(Color::TypeName, cast<Types::OpaqueFFIType>(ty)->text())
            return
        }

        if isa<Types::TypeExpr>(ty) {
            self._quals(ty)
            self.src_expr(cast<Types::TypeExpr>(ty)->expr)
            return
        }

        self.p.paint(Color::Error, "<error>")
    }

    fn _t_chain(self, ty: unsafe *Types::ChainType) {
        self._quals(ty)
        if ty->segments.is_empty() {
            self.p.paint(Color::Error, "<error>")
            return
        }

        for var i: usize = 0; i < ty->segments.size(); ++i {
            var unsafe *seg = ty->segments.get(i)
            if seg->sep == Types::ChainType::SegmentSeparator::ColonColon {
                self.p.paint(Color::Punct, "::")
            }

            if seg->name == &null {
                self.p.paint(Color::Error, "<error>")
                continue
            }

            self.p.paint(Color::TypeName, self.tok(seg->name->name))
            self._generic_args(seg->generic_args)
        }
    }

    fn _t_generic_param(self, ty: unsafe *Types::GenericParamType) {
        self._quals(ty)
        if ty->is_pack {
            self.p.paint(Color::Punct, "...")
        }

        if ty->param_name == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        self.p.paint(Color::TypeName, self.tok(ty->param_name->name))
    }

    fn _t_tuple(self, ty: unsafe *Types::TupleType) {
        self._quals(ty)
        self.p.paint(Color::Punct, "(")
        for var i: usize = 0; i < ty->elements.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_type(ty->elements[i])
        }

        self.p.paint(Color::Punct, ")")
    }

    fn _t_fixed_array(self, ty: unsafe *Types::FixedArrayType) {
        self._quals(ty)
        self.p.paint(Color::Punct, "[")
        self.src_type(ty->element)
        self.p.paint(Color::Punct, "; ")
        if !ty->is_incomplete && ty->size_expr != &null {
            self.src_expr(ty->size_expr)
        }

        self.p.paint(Color::Punct, "]")
    }

    fn _t_map(self, ty: unsafe *Types::MapType) {
        self._quals(ty)
        self.p.paint(Color::Punct, "{")
        self.src_type(ty->key)
        self.p.paint(Color::Punct, ": ")
        self.src_type(ty->value)
        self.p.paint(Color::Punct, "}")
    }

    fn _t_fn_ptr(self, ty: unsafe *Types::FunctionPointerType) {
        // Effects follow the parameter list, where they are written
        // (`fn(i32) async panic(E) -> T`); printed in front, `fn() panic`
        // read back as a panic-qualified... nothing.
        self._data_quals(ty)
        self.p.paint(Color::Keyword, "fn")
        self.p.paint(Color::Punct, "(")
        if ty->is_unprototyped {
            self.p.paint(Color::Punct, "...")
        } else {
            for var i: usize = 0; i < ty->params.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, ", ")
                }

                if i < ty->modes.size() && ty->modes[i] != ParamMode::Value {
                    self.p.paint(Color::Attr, param_mode_prefix(ty->modes[i]))
                }

                self.src_type(ty->params[i])
            }
        }

        self.p.paint(Color::Punct, ")")
        if ty->is_async() {
            self.p.paint(Color::Keyword, " async")
        }

        if ty->is_yield() {
            self.p.paint(Color::Keyword, " yield")
        }

        if ty->is_panic() {
            self._panic_spec(ty->panic_set)
        }

        if ty->return_type != &null {
            self.p.paint(Color::Punct, " -> ")
            self.src_type(ty->return_type)
        }
    }

    //  EXPRESSIONS  source-faithful  (UNCHANGED)

    fn src_expr(self, e: unsafe *Expr) {
        if e == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if e->is_error() {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if isa<IntegerLiteralExpr>(e) {
            self.p.paint(Color::Literal, cast<IntegerLiteralExpr>(e)->get_spelling())
            return
        }

        if isa<FloatingLiteralExpr>(e) {
            self.p.paint(Color::Literal, cast<FloatingLiteralExpr>(e)->get_spelling())
            return
        }

        if isa<StringLiteralExpr>(e) {
            self.p.paint(Color::Literal, cast<StringLiteralExpr>(e)->get_spelling())
            return
        }

        if isa<CharacterLiteralExpr>(e) {
            self.p.paint(Color::Literal, cast<CharacterLiteralExpr>(e)->get_spelling())
            return
        }

        if isa<BooleanLiteralExpr>(e) {
            self.p.paint(Color::Literal, (if (cast<BooleanLiteralExpr>(e)->value) => ("true") else => "false"))
            return
        }

        if isa<NullLiteralExpr>(e) {
            self.p.paint(Color::Literal, (if (cast<NullLiteralExpr>(e)->is_ref) => ("&null") else => "null"))
            return
        }

        if isa<NamedIdentExpr>(e) {
            self._e_ident(cast<NamedIdentExpr>(e))
            return
        }

        if isa<ChainExpr>(e) {
            self._chain(cast<ChainExpr>(e))
            return
        }

        if isa<Expressions::CallExpr>(e) {
            self._e_call(cast<Expressions::CallExpr>(e))
            return
        }

        if isa<Expressions::SubscriptExpr>(e) {
            self._e_subscript(cast<Expressions::SubscriptExpr>(e))
            return
        }

        if isa<Expressions::UnaryOperatorExpr>(e) {
            self._e_unary(cast<Expressions::UnaryOperatorExpr>(e))
            return
        }

        if isa<Expressions::BinaryOperatorExpr>(e) {
            self._e_binary(cast<Expressions::BinaryOperatorExpr>(e))
            return
        }

        if isa<Expressions::AssignOperatorExpr>(e) {
            self._e_assign(cast<Expressions::AssignOperatorExpr>(e))
            return
        }

        if isa<Expressions::ListLiteralExpr>(e) {
            self._expr_list("[", "]", cast<Expressions::ListLiteralExpr>(e)->elements)
            return
        }

        if isa<Expressions::InitListExpr>(e) {
            self._expr_list("{", "}", cast<Expressions::InitListExpr>(e)->elements)
            return
        }

        if isa<Expressions::StmtExpr>(e) {
            // A `try` arm that leaves (`=> return v`) prints as written: the
            // one jump, no block around it.
            var unsafe *se = cast<Expressions::StmtExpr>(e)
            if se->is_jump && se->body != &null && se->body->body.size() == 1 {
                self.src_stmt(se->body->body[0])
                return
            }

            // `({ ... })`: the parens are what make the block a value, so they
            // round-trip like ParenExpr's.
            self.p.paint(Color::Punct, "(")
            self.src_stmt((cast<Expressions::StmtExpr>(e)->body))
            self.p.paint(Color::Punct, ")")
            return
        }

        if isa<Expressions::TupleLiteralExpr>(e) {
            self._expr_list("(", ")", cast<Expressions::TupleLiteralExpr>(e)->elements)
            return
        }

        if isa<Expressions::SetLiteralExpr>(e) {
            self._expr_list("{", "}", cast<Expressions::SetLiteralExpr>(e)->elements)
            return
        }

        if isa<Expressions::MapLiteralExpr>(e) {
            self._e_map(cast<Expressions::MapLiteralExpr>(e))
            return
        }

        if isa<Expressions::NamedInitializerExpr>(e) {
            self._e_named_init(cast<Expressions::NamedInitializerExpr>(e))
            return
        }

        if isa<Expressions::VariantInitExpr>(e) {
            self._e_variant_init(cast<Expressions::VariantInitExpr>(e))
            return
        }

        if isa<Expressions::AnonInitializerExpr>(e) {
            self._e_anon_init(cast<Expressions::AnonInitializerExpr>(e))
            return
        }

        if isa<Expressions::IfExpr>(e) {
            self._e_if(cast<Expressions::IfExpr>(e))
            return
        }

        if isa<Expressions::TryCatchExpr>(e) {
            self._e_try(cast<Expressions::TryCatchExpr>(e))
            return
        }

        if isa<Expressions::MatchExpr>(e) {
            self._e_match(cast<Expressions::MatchExpr>(e))
            return
        }

        if isa<Expressions::RangeExpr>(e) {
            self._e_range(cast<Expressions::RangeExpr>(e))
            return
        }

        if isa<Expressions::ClosureExpr>(e) {
            self._e_closure(cast<Expressions::ClosureExpr>(e))
            return
        }

        if isa<Expressions::AwaitExpr>(e) {
            self._kw_operand("await ", cast<Expressions::AwaitExpr>(e)->operand)
            return
        }

        if isa<Expressions::PanicOpExpr>(e) {
            var unsafe *po = cast<Expressions::PanicOpExpr>(e)
            self.p.paint(Color::Keyword, "__panic_" + Expressions::panic_op_name(po->which))
            self.p.put("(")
            if po->slot != &null {
                self.src_expr(po->slot)
            }

            if po->slot != &null && po->operand != &null {
                self.p.put(", ")
            }

            if po->operand != &null {
                self.src_expr(po->operand)
            }

            self.p.put(")")
            return
        }

        if isa<Expressions::AttributedExpr>(e) {
            var unsafe *ae = cast<Expressions::AttributedExpr>(e)
            self.p.paint(Color::Keyword, "@" + self.tok(ae->name))
            if ae->has_args {
                self._expr_list("(", ")", ae->args)
            }

            self.p.put(" ")
            self.src_expr(ae->operand)
            return
        }

        if isa<Expressions::DefinedExpr>(e) {
            self.p.paint(Color::Keyword, "defined!")
            self.p.paint(Color::Punct, "(")
            self.p.put(self.ctx->get_spelling(cast<Expressions::DefinedExpr>(e)->name))
            self.p.paint(Color::Punct, ")")
            return
        }

        if isa<Expressions::UnwrapExpr>(e) {
            self.p.paint(Color::Keyword, "unwrap!")
            self.p.paint(Color::Punct, "(")
            self.src_expr(cast<Expressions::UnwrapExpr>(e)->operand)
            self.p.paint(Color::Punct, ")")
            return
        }

        if isa<Expressions::SpawnExpr>(e) {
            self._kw_operand("spawn ", cast<Expressions::SpawnExpr>(e)->operand)
            return
        }

        if isa<Expressions::ThreadExpr>(e) {
            self._kw_operand("thread ", cast<Expressions::ThreadExpr>(e)->operand)
            return
        }

        if isa<Expressions::EvalExpr>(e) {
            self._kw_operand("eval ", cast<Expressions::EvalExpr>(e)->operand)
            return
        }

        if isa<Expressions::UnsafeExpr>(e) {
            self._kw_operand("unsafe ", cast<Expressions::UnsafeExpr>(e)->operand)
            return
        }

        if isa<Expressions::ParenExpr>(e) {
            // Round-trip the parens. Dropping them here would print
            // `(a + b) * c` as `a + b * c`   the exact bug ParenExpr exists
            // to prevent.
            self.p.paint(Color::Punct, "(")
            self.src_expr(cast<Expressions::ParenExpr>(e)->inner)
            self.p.paint(Color::Punct, ")")
            return
        }

        if isa<Expressions::NamedArgExpr>(e) {
            var unsafe *na = cast<Expressions::NamedArgExpr>(e)
            self.p.paint(Color::Ident, self.tok(na->name))
            self.p.paint(Color::Punct, ": ")
            self.src_expr(na->value)
            return
        }

        if isa<Expressions::VerbatimExpr>(e) {
            // The span IS the rendering   that is what verbatim means.
            var unsafe *ve = cast<Expressions::VerbatimExpr>(e)
            if self.ctx != &null && self.ctx->sm != &null {
                self.p.paint(Color::Ident, self.ctx->sm->get_text(ve->span))
            } else {
                self.p.paint(Color::Dim, "<verbatim>")
            }

            return
        }

        if isa<Expressions::ConstraintExpr>(e) {
            self._e_constraint(cast<Expressions::ConstraintExpr>(e))
            return
        }

        if isa<Expressions::SizeOfExpr>(e) {
            self._builtin_type("sizeof", cast<Expressions::SizeOfExpr>(e)->type_arg)
            return
        }

        if isa<Expressions::AlignOfExpr>(e) {
            self._builtin_type("alignof", cast<Expressions::AlignOfExpr>(e)->type_arg)
            return
        }

        if isa<Expressions::TypeTraitExpr>(e) {
            self._builtin_type(
                Expressions::type_trait_spelling(cast<Expressions::TypeTraitExpr>(e)->fact) + "!",
                cast<Expressions::TypeTraitExpr>(e)->type_arg,
            )

            return
        }

        if isa<Expressions::TypeOfExpr>(e) {
            self._e_typeof(cast<Expressions::TypeOfExpr>(e))
            return
        }

        if isa<Expressions::DeleteExpr>(e) {
            self._e_delete(cast<Expressions::DeleteExpr>(e))
            return
        }

        if isa<Expressions::CxxNewExpr>(e) {
            self._e_cxx_new(cast<Expressions::CxxNewExpr>(e))
            return
        }

        if isa<Expressions::PackExpansionExpr>(e) {
            self.src_expr(cast<Expressions::PackExpansionExpr>(e)->operand)
            self.p.paint(Color::Punct, "...")
            return
        }

        if isa<Expressions::TypeCastExpr>(e) {
            self._e_cast(cast<Expressions::TypeCastExpr>(e))
            return
        }

        if isa<Expressions::ImplConformanceExpr>(e) {
            self._e_impl(cast<Expressions::ImplConformanceExpr>(e))
            return
        }

        if isa<Expressions::DerivesRelationExpr>(e) {
            self._e_derives(cast<Expressions::DerivesRelationExpr>(e))
            return
        }

        if isa<Expressions::ImplicitBoundaryCastExpr>(e) {
            self.src_expr(cast<Expressions::ImplicitBoundaryCastExpr>(e)->original)
            return
        }

        self.p.paint(Color::Error, "<error>")
    }

    fn _e_ident(self, e: unsafe *NamedIdentExpr) {
        self.p.paint(Color::Ident, self.tok(e->name))
        self._generic_args(e->generic_args)
    }

    fn _chain(self, e: unsafe *ChainExpr) {
        if e->base != &null {
            self.src_expr(e->base)
        }

        for var i: usize = 0; i < e->steps.size(); ++i {
            var unsafe *s = e->steps.get(i)
            self._access_op(s->access_kind)
            if s->is_operator() {
                self.p.paint(Color::Keyword, "op")
                for var j: usize = 0; j < s->op_tokens.size(); ++j {
                    self.p.paint(Color::Operator, self.tok(s->op_tokens[j]))
                }
            } else if s->is_tuple_index() {
                // the separator is already out; the ordinal completes it (`.0`).
                self.p.paint(Color::Literal, f"{s->index}")
            } else if s->name != &null {
                self.p.paint(Color::Ident, self.tok(s->name->name))
            } else {
                self.p.paint(Color::Error, "<error>")
            }

            self._generic_args(s->generic_args)
        }
    }

    fn _e_call(self, e: unsafe *Expressions::CallExpr) {
        self.src_expr(e->callee)
        self._expr_list("(", ")", e->args)
    }

    fn _e_subscript(self, e: unsafe *Expressions::SubscriptExpr) {
        self.src_expr(e->base)
        self.p.paint(Color::Punct, "[")
        self.src_expr(e->index)
        self.p.paint(Color::Punct, "]")
    }

    fn _e_unary(self, e: unsafe *Expressions::UnaryOperatorExpr) {
        var opr = self.tok(e->op_token)
        if e->is_prefix() {
            self.p.paint(Color::Operator, opr)
            self.src_expr(e->operand)
        } else {
            self.src_expr(e->operand)
            self.p.paint(Color::Operator, opr)
        }
    }

    fn _e_binary(self, e: unsafe *Expressions::BinaryOperatorExpr) {
        self.src_expr(e->lhs)
        self.p.put(" ")
        self.p.paint(Color::Operator, self.tok(e->op_token))
        self.p.put(" ")
        self.src_expr(e->rhs)
    }

    fn _e_constraint(self, e: unsafe *Expressions::ConstraintExpr) {
        self.src_expr(e->lhs)
        self.p.put(" ")
        self.p.paint(Color::Keyword, self.tok(e->op_token))
        self.p.put(" ")
        self.src_type(e->rhs)
    }

    fn _e_assign(self, e: unsafe *Expressions::AssignOperatorExpr) {
        self.src_expr(e->lhs)
        self.p.put(" ")
        self.p.paint(Color::Operator, self.tok(e->op_token))
        self.p.put(" ")
        self.src_expr(e->rhs)
    }

    fn _e_map(self, e: unsafe *Expressions::MapLiteralExpr) {
        self.p.paint(Color::Punct, "{")
        for var i: usize = 0; i < e->entries.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            var unsafe *en = e->entries.get(i)
            self.src_expr(en->key)
            self.p.paint(Color::Punct, ": ")
            self.src_expr(en->value)
        }

        self.p.paint(Color::Punct, "}")
    }

    fn _e_named_init(self, e: unsafe *Expressions::NamedInitializerExpr) {
        if e->is_dotted {
            self.p.paint(Color::Punct, ".")
            self.p.paint(Color::Ident, self.tok(e->dotted_name))
            if !e->has_braces {
                return
            }
        } else {
            self.src_expr(e->type_expr)
        }

        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < e->fields.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            var unsafe *fld = e->fields.get(i)
            self.p.paint(Color::Ident, self.tok(fld->name))
            self.p.paint(Color::Punct, ": ")
            self.src_expr(fld->value)
        }

        self.p.paint(Color::Punct, " }")
    }

    /// `Enum::Variant { f: e, .. }`, the payload in declaration order.
    fn _e_variant_init(self, e: unsafe *Expressions::VariantInitExpr) {
        var unsafe *en = cast<Declarations::EnumDecl>(e->en)
        var unsafe *v  = en->variants[e->variant as usize]
        self.p.paint(Color::Ident, self.tok(en->name))
        self.p.paint(Color::Punct, "::")
        self.p.paint(Color::Ident, self.tok(v->name))
        if v->payload.is_empty() {
            return
        }

        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < e->fields.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self.p.paint(Color::Ident, self.tok(v->payload[i]->name))
            self.p.paint(Color::Punct, ": ")
            self.src_expr(e->fields[i])
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _e_anon_init(self, e: unsafe *Expressions::AnonInitializerExpr) {
        self.p.paint(Color::Punct, "{ ")
        for var i: usize = 0; i < e->fields.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            var unsafe *fld = e->fields.get(i)
            self.p.paint(Color::Punct, ".")
            self.p.paint(Color::Ident, self.tok(fld->name))
            self.p.paint(Color::Punct, ": ")
            self.src_expr(fld->value)
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _e_if(self, e: unsafe *Expressions::IfExpr) {
        self.p.paint(Color::Keyword, "if ")
        self.src_expr(e->condition)
        self.p.paint(Color::Punct, " { ")
        self.src_expr(e->then_expr)
        self.p.paint(Color::Punct, " }")
        for var i: usize = 0; i < e->else_ifs.size(); ++i {
            var unsafe *arm = e->else_ifs.get(i)
            self.p.paint(Color::Keyword, " else if ")
            self.src_expr(arm->condition)
            self.p.paint(Color::Punct, " { ")
            self.src_expr(arm->body)
            self.p.paint(Color::Punct, " }")
        }

        self.p.paint(Color::Keyword, " else ")
        self.p.paint(Color::Punct, "{ ")
        self.src_expr(e->else_expr)
        self.p.paint(Color::Punct, " }")
    }

    fn _e_try(self, e: unsafe *Expressions::TryCatchExpr) {
        self.p.paint(Color::Keyword, "try ")
        self.p.paint(Color::Punct, "{ ")
        self.src_expr(e->try_expr)
        self.p.paint(Color::Punct, " }")
        for var i: usize = 0; i < e->catch_arms.size(); ++i {
            var unsafe *arm = e->catch_arms.get(i)
            self.p.paint(Color::Keyword, " catch")
            if arm->has_binding {
                self.p.put(" ")
                if arm->is_const {
                    self.p.paint(Color::Keyword, "const ")
                }

                if arm->binding != &null {
                    self.p.paint(Color::Ident, self.tok(arm->binding->name))
                }

                if arm->filter != &null {
                    self.p.paint(Color::Punct, ": ")
                    self.src_type(arm->filter)
                }
            }

            self.p.paint(Color::Punct, " { ")
            self.src_expr(arm->body)
            self.p.paint(Color::Punct, " }")
        }
    }

    fn _e_match(self, e: unsafe *Expressions::MatchExpr) {
        self.p.paint(Color::Keyword, "match ")
        self.src_expr(e->scrutinee)
        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < e->cases.size(); ++i {
            if i > 0 {
                self.p.put(" ")
            }

            self._src_match_case(e->cases.get(i))
        }

        self.p.paint(Color::Punct, " }")
    }

    /// Source form of one match case. Expr-form keeps the value in
    /// `expression`; stmt-form keeps it in `body`. We render whichever is set.
    fn _src_match_case(self, mc: unsafe *Statements::MatchCase) {
        if mc->is_default {
            self.p.paint(Color::Keyword, "default ")
        } else {
            self.p.paint(Color::Keyword, "case ")
            for var i: usize = 0; i < mc->patterns.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, ", ")
                }

                self.src_pattern(mc->patterns[i])
            }

            if mc->guard != &null {
                self.p.paint(Color::Keyword, " where ")
                self.src_expr(mc->guard)
            }

            self.p.put(" ")
        }

        if mc->expression != &null {
            self.p.paint(Color::Punct, "{ ")
            self.src_expr(mc->expression)
            self.p.paint(Color::Punct, " }")
        } else if mc->body != &null {
            self.src_stmt(mc->body)
        } else {
            self.p.paint(Color::Punct, "{}")
        }
    }

    fn _e_range(self, e: unsafe *Expressions::RangeExpr) {
        if e->begin != &null {
            self.src_expr(e->begin)
        }

        self.p.paint(Color::Operator, (if (e->is_inclusive) => ("..=") else => ".."))
        if e->end != &null {
            self.src_expr(e->end)
        }
    }

    /// \brief Source-faithful formatting facade for ClosureExpr nodes.
    fn _e_closure(self, e: unsafe *Expressions::ClosureExpr) {
        self.p.paint(Color::Keyword, "fn")

        if !e->generic_params.is_empty() {
            self.p.paint(Color::Punct, "<")
            for var i: usize = 0; i < e->generic_params.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, ", ")
                }

                self._d_generic_param(e->generic_params[i])
            }

            self.p.paint(Color::Punct, ">")
        }

        self.p.paint(Color::Punct, "(")
        for var i: usize = 0; i < e->params.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self._d_param(e->params[i])
        }

        self.p.paint(Color::Punct, ")")

        if !e->captures.is_empty() {
            self.p.paint(Color::Punct, "|")
            for var i: usize = 0; i < e->captures.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, ", ")
                }

                var unsafe *cap = e->captures.get(i)
                if cap->is_const {
                    self.p.paint(Color::Keyword, "const ")
                }

                if cap->by_ptr {
                    self.p.paint(Color::Punct, "*")
                }

                if cap->name != &null {
                    self.p.paint(Color::Ident, self.tok(cap->name->name))
                }
            }

            self.p.paint(Color::Punct, "|")
        }

        if ((e->modifiers as u16) & (Declarations::FnModifier::IsPanic as u16)) != 0 {
            self._panic_spec(e->panic_set)
        }

        if ((e->modifiers as u16) & (Declarations::FnModifier::IsVolatile as u16)) != 0 {
            self.p.paint(Color::Keyword, " volatile")
        }

        if ((e->modifiers as u16) & (Declarations::FnModifier::IsAsync as u16)) != 0 {
            self.p.paint(Color::Keyword, " async")
        }

        if e->return_type != &null {
            self.p.paint(Color::Punct, " -> ")
            self.src_type(e->return_type)
        }

        if e->body_kind == Declarations::FnBodyKind::Expr {
            self.p.paint(Color::Punct, " = ")
            self.src_expr(e->body_expr)
        } else if e->body_kind == Declarations::FnBodyKind::Block {
            self.p.put(" ")
            self.src_stmt(e->body_block)
        }
    }

    fn _kw_operand(self, const kw: string, operand: unsafe *Expr) {
        self.p.paint(Color::Keyword, kw)
        self.src_expr(operand)
    }

    fn _builtin_type(self, const kw: string, t: unsafe *Type) {
        self.p.paint(Color::Keyword, kw)
        self.p.paint(Color::Punct, "(")
        self.src_type(t)
        self.p.paint(Color::Punct, ")")
    }

    fn _e_typeof(self, e: unsafe *Expressions::TypeOfExpr) {
        self.p.paint(Color::Keyword, "typeof")
        self.p.paint(Color::Punct, "(")
        self.src_expr(e->operand)
        self.p.paint(Color::Punct, ")")
    }

    fn _e_delete(self, e: unsafe *Expressions::DeleteExpr) {
        self.p.paint(Color::Keyword, (if (e->is_cxx) => ("@cxx::delete ") else => "delete "))
        if e->is_array {
            self.p.paint(Color::Punct, "[] ")
        }

        self.src_expr(e->operand)
    }

    fn _e_cxx_new(self, e: unsafe *Expressions::CxxNewExpr) {
        self.p.paint(Color::Keyword, "@cxx::new ")
        if e->is_array() {
            self.p.paint(Color::Punct, "[")
            self.src_type(e->elem_type())
            self.p.paint(Color::Punct, "; ")
            self.src_expr(e->count)
            self.p.paint(Color::Punct, "]")
            return
        }

        self.src_expr(e->init)
    }

    fn _e_cast(self, e: unsafe *Expressions::TypeCastExpr) {
        self.src_expr(e->operand)
        self.p.paint(Color::Keyword, " as ")
        if e->is_unsafe {
            self.p.paint(Color::Keyword, "unsafe ")
        }

        self.src_type(e->target)
    }

    fn _e_impl(self, e: unsafe *Expressions::ImplConformanceExpr) {
        self.src_type(e->subject)
        self.p.paint(Color::Keyword, " impl ")
        self.src_type(e->inter)
    }

    fn _e_derives(self, e: unsafe *Expressions::DerivesRelationExpr) {
        self.src_type(e->subject)
        self.p.paint(Color::Keyword, " derives ")
        self.src_type(e->base)
    }

    //  PATTERNS  source-faithful  (UNCHANGED)

    fn src_pattern(self, pat: unsafe *Pattern) {
        if pat == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if pat->is_error() {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if isa<WildcardPattern>(pat) {
            self.p.paint(Color::Punct, "_")
            return
        }

        if isa<LiteralPattern>(pat) {
            self.src_expr(cast<LiteralPattern>(pat)->value)
            return
        }

        if isa<BindingPattern>(pat) {
            self._p_binding(cast<BindingPattern>(pat))
            return
        }

        if isa<TupleDestructurePattern>(pat) {
            self._p_tuple(cast<TupleDestructurePattern>(pat))
            return
        }

        if isa<ConstructorPattern>(pat) {
            self._p_ctor(cast<ConstructorPattern>(pat))
            return
        }

        if isa<UnresolvedConstructorPattern>(pat) {
            self._p_uctor(cast<UnresolvedConstructorPattern>(pat))
            return
        }

        if isa<AlternationPattern>(pat) {
            self._p_alt(cast<AlternationPattern>(pat))
            return
        }

        if isa<RangePattern>(pat) {
            self._p_range(cast<RangePattern>(pat))
            return
        }

        if isa<SlicePattern>(pat) {
            self._p_slice(cast<SlicePattern>(pat))
            return
        }

        self.p.paint(Color::Error, "<error>")
    }

    fn _p_binding(self, pat: unsafe *BindingPattern) {
        self.p.paint(Color::Keyword, (if (pat->is_const) => ("const ") else => "var "))
        self.p.paint(Color::Ident, self.tok(pat->name))
        if pat->type_ != &null {
            self.p.paint(Color::Punct, ": ")
            self.src_type(pat->type_)
        }
    }

    fn _p_tuple(self, pat: unsafe *TupleDestructurePattern) {
        self.p.paint(Color::Punct, "(")
        self._pat_list(pat->elements)
        self.p.paint(Color::Punct, ")")
    }

    fn _p_ctor(self, pat: unsafe *ConstructorPattern) {
        if pat->is_dotted {
            self.p.paint(Color::Punct, ".")
            self.p.paint(Color::Ident, self.tok(pat->dotted_name))
        } else if pat->head != &null {
            self.src_expr(pat->head)
        }

        if pat->has_parens {
            self.p.paint(Color::Punct, "(")
            self._pat_list(pat->subpatterns)
            self.p.paint(Color::Punct, ")")
        }
    }

    fn _p_uctor(self, pat: unsafe *UnresolvedConstructorPattern) {
        if pat->head != &null {
            self.src_expr(pat->head)
        }

        if pat->has_parens {
            self.p.paint(Color::Punct, "(")
            self._pat_list(pat->subpatterns)
            self.p.paint(Color::Punct, ")")
        }
    }

    fn _p_alt(self, pat: unsafe *AlternationPattern) {
        for var i: usize = 0; i < pat->alternatives.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Operator, " | ")
            }

            self.src_pattern(pat->alternatives[i])
        }
    }

    fn _p_range(self, pat: unsafe *RangePattern) {
        if pat->lo != &null {
            self.src_expr(pat->lo)
        }

        self.p.paint(Color::Operator, (if (pat->is_inclusive) => ("..=") else => ".."))
        if pat->hi != &null {
            self.src_expr(pat->hi)
        }
    }

    fn _p_slice(self, pat: unsafe *SlicePattern) {
        self.p.paint(Color::Punct, "[")
        var first = true
        for var i: usize = 0; i < pat->prefix.size(); ++i {
            if !first {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_pattern(pat->prefix[i])
            first = false
        }

        if pat->has_rest {
            if !first {
                self.p.paint(Color::Punct, ", ")
            }

            self.p.paint(Color::Punct, "..")
            if pat->rest_binding != &null {
                self.src_pattern(pat->rest_binding)
            }

            first = false
        }

        for var i: usize = 0; i < pat->suffix.size(); ++i {
            if !first {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_pattern(pat->suffix[i])
            first = false
        }

        self.p.paint(Color::Punct, "]")
    }

    //  BINDINGS  shared by destructure / for / context (source path)  (UNCHANGED)

    fn _src_binding(self, b: unsafe *Statements::Binding) {
        if b->is_explicit {
            self.p.paint(Color::Keyword, (if (b->is_const) => ("const ") else => "var "))
        }

        var sh = b->shorthand
        if sh.has(Statements::BindingShorthand::Unsafe) {
            self.p.paint(Color::Keyword, "unsafe ")
        }

        if sh.has(Statements::BindingShorthand::Pointer) {
            self.p.paint(Color::Punct, "*")
        }

        if b->is_discard {
            self.p.paint(Color::Punct, "_")
        } else if b->name != &null {
            self.p.paint(Color::Ident, self.tok(b->name->name))
        } else {
            self.p.paint(Color::Error, "<error>")
        }

        if sh.has(Statements::BindingShorthand::Nullable) {
            self.p.paint(Color::Punct, "?")
        }
    }

    fn _src_binding_list(self, bs: FrozenList<Statements::Binding>) {
        for var i: usize = 0; i < bs.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self._src_binding(bs.get(i))
        }
    }

    //  STATEMENTS  source-faithful  (UNCHANGED)

    fn src_stmt(self, stmt: unsafe *Stmt) {
        if stmt == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if stmt->is_error() {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if isa<Statements::CompoundStmt>(stmt) {
            self._s_compound(cast<Statements::CompoundStmt>(stmt))
            return
        }

        if isa<Statements::ExpressionStmt>(stmt) {
            self.src_expr(cast<Statements::ExpressionStmt>(stmt)->expr)
            return
        }

        if isa<Statements::DeclStmt>(stmt) {
            self.src_decl(cast<Statements::DeclStmt>(stmt)->decl)
            return
        }

        if isa<Statements::ReturnStmt>(stmt) {
            self._s_return(cast<Statements::ReturnStmt>(stmt))
            return
        }

        if isa<Statements::BreakStmt>(stmt) {
            self._s_break(cast<Statements::BreakStmt>(stmt))
            return
        }

        if isa<Statements::ContinueStmt>(stmt) {
            self._s_continue(cast<Statements::ContinueStmt>(stmt))
            return
        }

        if isa<Statements::PanicStmt>(stmt) {
            self.p.paint(Color::Keyword, "panic ")
            self.src_expr(cast<Statements::PanicStmt>(stmt)->payload)
            return
        }

        if isa<Statements::YieldStmt>(stmt) {
            self.p.paint(Color::Keyword, "yield ")
            self.src_expr(cast<Statements::YieldStmt>(stmt)->value)
            return
        }

        if isa<Statements::RuntimeAssertStmt>(stmt) {
            self._s_assert(cast<Statements::RuntimeAssertStmt>(stmt))
            return
        }

        if isa<Statements::StaticAssertStmt>(stmt) {
            self._s_static_assert(cast<Statements::StaticAssertStmt>(stmt))
            return
        }

        if isa<Statements::LabelIntrinsicStmt>(stmt) {
            self._s_label_intrinsic(cast<Statements::LabelIntrinsicStmt>(stmt))
            return
        }

        if isa<Statements::JumpIntrinsicStmt>(stmt) {
            self._s_jump_intrinsic(cast<Statements::JumpIntrinsicStmt>(stmt))
            return
        }

        if isa<Statements::ConditionalStmt>(stmt) {
            self._s_conditional(cast<Statements::ConditionalStmt>(stmt))
            return
        }

        if isa<Statements::WhileLoopStmt>(stmt) {
            self._s_while(cast<Statements::WhileLoopStmt>(stmt))
            return
        }

        if isa<Statements::LoopStmt>(stmt) {
            self.p.paint(Color::Keyword, "loop ")
            self.src_stmt((cast<Statements::LoopStmt>(stmt)->body))
            return
        }

        if isa<Statements::RangedForStmt>(stmt) {
            self._s_ranged_for(cast<Statements::RangedForStmt>(stmt))
            return
        }

        if isa<Statements::IndexedForStmt>(stmt) {
            self._s_indexed_for(cast<Statements::IndexedForStmt>(stmt))
            return
        }

        if isa<Statements::MatchStmt>(stmt) {
            self._s_match(cast<Statements::MatchStmt>(stmt))
            return
        }

        if isa<Statements::LabeledStmt>(stmt) {
            self._s_labeled(cast<Statements::LabeledStmt>(stmt))
            return
        }

        if isa<Statements::TryCatchStmt>(stmt) {
            self._s_try(cast<Statements::TryCatchStmt>(stmt))
            return
        }

        if isa<Statements::FinallyStmt>(stmt) {
            self.p.paint(Color::Keyword, "finally ")
            self.src_stmt((cast<Statements::FinallyStmt>(stmt)->body))
            return
        }

        if isa<Statements::UnsafeBlockStmt>(stmt) {
            self.p.paint(Color::Keyword, "unsafe ")
            self.src_stmt((cast<Statements::UnsafeBlockStmt>(stmt)->body))
            return
        }

        if isa<Statements::ContextBindingStmt>(stmt) {
            self._s_context(cast<Statements::ContextBindingStmt>(stmt))
            return
        }

        if isa<Statements::DestructuringDeclStmt>(stmt) {
            self._s_destructure(cast<Statements::DestructuringDeclStmt>(stmt))
            return
        }

        if isa<Statements::InlineBlockStmt>(stmt) {
            self._s_inline(cast<Statements::InlineBlockStmt>(stmt))
            return
        }

        if isa<Statements::EvalBlockStmt>(stmt) {
            self.p.paint(Color::Keyword, "eval")
            self.p.paint(Color::Punct, " { ... }")
            return
        }

        if isa<Statements::SwitchDispatchStmt>(stmt) {
            self._s_switch_dispatch(cast<Statements::SwitchDispatchStmt>(stmt))
            return
        }

        self.p.paint(Color::Error, "<error>")
    }

    fn _s_compound(self, stmt: unsafe *Statements::CompoundStmt) {
        if stmt->body.is_empty() {
            self.p.paint(Color::Punct, "{}")
            return
        }

        self.p.paint(Color::Punct, "{ ")
        for var i: usize = 0; i < stmt->body.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, "; ")
            }

            self.src_stmt(stmt->body[i])
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _s_return(self, stmt: unsafe *Statements::ReturnStmt) {
        self.p.paint(Color::Keyword, "return")
        if stmt->value != &null {
            self.p.put(" ")
            self.src_expr(stmt->value)
        }
    }

    fn _s_break(self, stmt: unsafe *Statements::BreakStmt) {
        self.p.paint(Color::Keyword, "break")
        if stmt->has_label {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(stmt->label))
        }
    }

    fn _s_continue(self, stmt: unsafe *Statements::ContinueStmt) {
        self.p.paint(Color::Keyword, "continue")
        if stmt->has_label {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(stmt->label))
        }
    }

    fn _s_assert(self, stmt: unsafe *Statements::RuntimeAssertStmt) {
        self.p.paint(Color::Keyword, "assert ")
        self.src_expr(stmt->condition)
        if stmt->message != &null {
            self.p.paint(Color::Punct, ", ")
            self.src_expr(stmt->message)
        }
    }

    fn _s_static_assert(self, stmt: unsafe *Statements::StaticAssertStmt) {
        self.p.paint(Color::Keyword, "assert static ")
        self.src_expr(stmt->condition)
        if stmt->message != &null {
            self.p.paint(Color::Punct, ", ")
            self.src_expr(stmt->message)
        }
    }

    /// `name:;` -- after lowering these are the lowerings' labels, and the
    /// dump reads as the C++ EmitIR writes for them.
    fn _s_label_intrinsic(self, stmt: unsafe *Statements::LabelIntrinsicStmt) {
        self.p.paint(Color::Ident, self.tok(stmt->name))
        self.p.paint(Color::Punct, ":;")
    }

    /// `goto name;`, for the same reason.
    fn _s_jump_intrinsic(self, stmt: unsafe *Statements::JumpIntrinsicStmt) {
        self.p.paint(Color::Keyword, "goto ")
        self.p.paint(Color::Ident, self.tok(stmt->target))
        self.p.paint(Color::Punct, ";")
    }

    /// `switch (v) { case lo: goto L; case lo ... hi: goto L; default: goto D; }`,
    /// or `default: <stmt>`: the shape EmitIR writes.
    fn _s_switch_dispatch(self, stmt: unsafe *Statements::SwitchDispatchStmt) {
        self.p.paint(Color::Keyword, "switch ")
        self.p.paint(Color::Punct, "(")
        self.src_expr(stmt->value)
        self.p.paint(Color::Punct, ") { ")
        for var i: usize = 0; i < stmt->cases.size(); ++i {
            var unsafe *c = stmt->cases.get(i)
            self.p.paint(Color::Keyword, "case ")
            self.src_expr(c->lo)
            if c->hi != &null {
                self.p.paint(Color::Punct, " ... ")
                self.src_expr(c->hi)
            }

            self.p.paint(Color::Punct, ": ")
            self.p.paint(Color::Keyword, "goto ")
            self.p.paint(Color::Ident, self.tok(c->target))
            self.p.paint(Color::Punct, "; ")
        }

        self.p.paint(Color::Keyword, "default")
        self.p.paint(Color::Punct, ": ")
        if stmt->default_stmt != &null {
            self.src_stmt(stmt->default_stmt)
        } else {
            self.p.paint(Color::Keyword, "goto ")
            self.p.paint(Color::Ident, self.tok(stmt->default_target))
            self.p.paint(Color::Punct, ";")
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _s_conditional(self, stmt: unsafe *Statements::ConditionalStmt) {
        self.p.paint(Color::Keyword, "if ")
        self.src_expr(stmt->cond)
        self.p.put(" ")
        self.src_stmt(stmt->then_)
        if stmt->else_ != &null {
            self.p.paint(Color::Keyword, " else ")
            self.src_stmt(stmt->else_)
        }
    }

    fn _s_while(self, stmt: unsafe *Statements::WhileLoopStmt) {
        self.p.paint(Color::Keyword, "while ")
        self.src_expr(stmt->cond)
        self.p.put(" ")
        self.src_stmt(stmt->body)
    }

    fn _s_ranged_for(self, stmt: unsafe *Statements::RangedForStmt) {
        self.p.paint(Color::Keyword, "for ")
        if stmt->is_eval {
            self.p.paint(Color::Keyword, "eval ")
        }

        self._src_binding_list(stmt->bindings)
        self.p.paint(Color::Keyword, " in ")
        self.src_expr(stmt->iterable)
        self.p.put(" ")
        self.src_stmt(stmt->body)
    }

    fn _s_indexed_for(self, stmt: unsafe *Statements::IndexedForStmt) {
        self.p.paint(Color::Keyword, "for ")
        if stmt->is_eval {
            self.p.paint(Color::Keyword, "eval ")
        }

        if stmt->init != &null { // `for ; c; s`: empty init
            self.src_stmt(stmt->init)
        }

        self.p.paint(Color::Punct, "; ")
        self.src_expr(stmt->cond)
        self.p.paint(Color::Punct, "; ")
        self.src_expr(stmt->update)
        self.p.put(" ")
        self.src_stmt(stmt->body)
    }

    fn _s_match(self, stmt: unsafe *Statements::MatchStmt) {
        self.p.paint(Color::Keyword, "match ")
        self.src_expr(stmt->scrutinee)
        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < stmt->cases.size(); ++i {
            if i > 0 {
                self.p.put(" ")
            }

            self._src_match_case(stmt->cases.get(i))
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _s_labeled(self, stmt: unsafe *Statements::LabeledStmt) {
        self.p.paint(Color::Ident, self.tok(stmt->label))
        self.p.paint(Color::Punct, ": ")
        self.src_stmt(stmt->inner)
    }

    fn _s_try(self, stmt: unsafe *Statements::TryCatchStmt) {
        self.p.paint(Color::Keyword, "try ")
        self.src_stmt(stmt->try_body)
        for var i: usize = 0; i < stmt->arms.size(); ++i {
            var unsafe *arm = stmt->arms.get(i)
            self.p.paint(Color::Keyword, " catch")
            if arm->binding != &null {
                self.p.put(" ")
                self.p.paint(Color::Ident, self.tok(arm->binding->name))
                if arm->filter != &null {
                    self.p.paint(Color::Punct, ": ")
                    self.src_type(arm->filter)
                }
            }

            self.p.put(" ")
            self.src_stmt(arm->body)
        }
    }

    fn _s_context(self, stmt: unsafe *Statements::ContextBindingStmt) {
        self.src_expr(stmt->value)
        self.p.paint(Color::Keyword, " as ")
        if stmt->bindings.size() == 1 {
            self._src_binding_list(stmt->bindings)
        } else {
            self.p.paint(Color::Punct, "(")
            self._src_binding_list(stmt->bindings)
            self.p.paint(Color::Punct, ")")
        }

        self.p.put(" ")
        self.src_stmt(stmt->body)
    }

    fn _s_destructure(self, stmt: unsafe *Statements::DestructuringDeclStmt) {
        var is_tuple = stmt->kind_ == Statements::DestructureKind::Tuple
        self.p.paint(Color::Keyword, (if (stmt->leading_is_const) => ("const ") else => "var "))
        self.p.paint(Color::Punct, (if (is_tuple) => ("(") else => "{"))
        self._src_binding_list(stmt->bindings)
        self.p.paint(Color::Punct, (if (is_tuple) => (")") else => "}"))
        self.p.paint(Color::Punct, " = ")
        self.src_expr(stmt->value)
    }

    fn _s_inline(self, stmt: unsafe *Statements::InlineBlockStmt) {
        self.p.paint(Color::Keyword, "inline ")
        self.p.paint(Color::Literal, f"\"{self._inline_lang(stmt->lang)}\"")
        self.p.paint(Color::Punct, " { ... }")
    }

    fn _inline_lang(self, lang: Statements::FFILang) -> string {
        if lang == Statements::FFILang::Asm {
            return "asm"
        }

        if lang == Statements::FFILang::C {
            return "c"
        }

        if lang == Statements::FFILang::Cpp {
            return "c++"
        }

        if lang == Statements::FFILang::Cuda {
            return "cuda"
        }

        if lang == Statements::FFILang::Hip {
            return "hip"
        }

        if lang == Statements::FFILang::OpenCL {
            return "opencl"
        }

        if lang == Statements::FFILang::Hlsl {
            return "hlsl"
        }

        if lang == Statements::FFILang::Metal {
            return "metal"
        }

        if lang == Statements::FFILang::SpirV {
            return "spirv"
        }

        if lang == Statements::FFILang::Wgsl {
            return "wgsl"
        }

        if lang == Statements::FFILang::Glsl {
            return "glsl"
        }

        if lang == Statements::FFILang::Kairo {
            return "kairo"
        }

        return "c++"
    }

    //  DECLARATIONS  source-faithful  (UNCHANGED)

    fn src_decl(self, decl: unsafe *Decl) {
        if decl == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if decl->is_error() {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if isa<Declarations::FunctionDecl>(decl) {
            self._d_function(cast<Declarations::FunctionDecl>(decl))
            return
        }

        if isa<Declarations::VariableDecl>(decl) {
            self._d_variable(cast<Declarations::VariableDecl>(decl))
            return
        }

        if isa<Declarations::FieldDecl>(decl) {
            self._d_field(cast<Declarations::FieldDecl>(decl))
            return
        }

        if isa<Declarations::ParamDecl>(decl) {
            self._d_param(cast<Declarations::ParamDecl>(decl))
            return
        }

        if isa<Declarations::GenericParamDecl>(decl) {
            self._d_generic_param(cast<Declarations::GenericParamDecl>(decl))
            return
        }

        if isa<Declarations::StructDecl>(decl) {
            self._d_struct(cast<Declarations::StructDecl>(decl))
            return
        }

        if isa<Declarations::ClassDecl>(decl) {
            self._d_class(cast<Declarations::ClassDecl>(decl))
            return
        }

        if isa<Declarations::InterfaceDecl>(decl) {
            self._d_interface(cast<Declarations::InterfaceDecl>(decl))
            return
        }

        if isa<Declarations::ExtensionDecl>(decl) {
            self._d_extension(cast<Declarations::ExtensionDecl>(decl))
            return
        }

        if isa<Declarations::EnumDecl>(decl) {
            self._d_enum(cast<Declarations::EnumDecl>(decl))
            return
        }

        if isa<Declarations::EnumVariantDecl>(decl) {
            self._d_enum_variant(cast<Declarations::EnumVariantDecl>(decl))
            return
        }

        if isa<Declarations::UnionDecl>(decl) {
            self._d_union(cast<Declarations::UnionDecl>(decl))
            return
        }

        if isa<Declarations::TypeAliasDecl>(decl) {
            self._d_type_alias(cast<Declarations::TypeAliasDecl>(decl))
            return
        }

        if isa<Declarations::ModuleDecl>(decl) {
            self._d_module(cast<Declarations::ModuleDecl>(decl))
            return
        }

        if isa<Declarations::ImportDecl>(decl) {
            self._d_import(cast<Declarations::ImportDecl>(decl))
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(decl) {
            self._d_vis_group(cast<Declarations::VisibilityGroupDecl>(decl))
            return
        }

        if isa<Declarations::EvalBlockDecl>(decl) {
            self._d_eval_block(cast<Declarations::EvalBlockDecl>(decl))
            return
        }

        if isa<Declarations::TestDecl>(decl) {
            self._d_test(cast<Declarations::TestDecl>(decl))
            return
        }

        if isa<Declarations::MacroDecl>(decl) {
            self._d_macro(cast<Declarations::MacroDecl>(decl))
            return
        }

        if isa<Declarations::ProcedureMacroDecl>(decl) {
            self._d_proc_macro(cast<Declarations::ProcedureMacroDecl>(decl))
            return
        }

        if isa<Declarations::FFIBlockDecl>(decl) {
            self._d_ffi_block(cast<Declarations::FFIBlockDecl>(decl))
            return
        }

        self.p.paint(Color::Error, "<error>")
    }

    /// # shared decl pieces

    fn _generic_params(self, gps: FrozenList<unsafe *Declarations::GenericParamDecl>) {
        if gps.is_empty() {
            return
        }

        self.p.paint(Color::Punct, "<")
        for var i: usize = 0; i < gps.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self._d_generic_param(gps[i])
        }

        self.p.paint(Color::Punct, ">")
    }

    fn _requires(self, req: unsafe *Expr) {
        if req == &null {
            return
        }

        self.p.paint(Color::Keyword, " requires ")
        self.src_expr(req)
    }

    fn _where(self, wh: unsafe *Expr) {
        if wh == &null {
            return
        }

        self.p.paint(Color::Keyword, " where ")
        self.src_expr(wh)
    }

    /// Renders the `<>` specialization introducer that precedes the name when a
    /// decl is a specialization (#68). Primary/Explicit/Partial all print the
    /// bare `<>` marker in source form; the distinction is on the arg pattern.
    /// Instantiated nodes are compiler-synthesized (never written by the user,
    /// see InstantiationRegistry) and have no source form, so they print
    /// nothing here, same as None.
    fn _spec_intro(self, kind: Declarations::SpecKind) {
        if kind == Declarations::SpecKind::None || kind == Declarations::SpecKind::Instantiated {
            return
        }

        self.p.paint(Color::Punct, "<>")
        self.p.put(" ")
    }

    /// Renders the post-name `<...>` specialization argument pattern (#68).
    /// Instantiated nodes carry no source-form args (see _spec_intro), so
    /// they print nothing here either.
    fn _spec_args(self, kind: Declarations::SpecKind, args: FrozenList<unsafe *Type>) {
        if kind == Declarations::SpecKind::None || kind == Declarations::SpecKind::Instantiated {
            return
        }

        self.p.paint(Color::Punct, "<")
        for var i: usize = 0; i < args.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self.src_type(args[i])
        }

        self.p.paint(Color::Punct, ">")
    }

    /// Debug-tree annotation for a decl's specialization classification (#68).
    /// Emitted on the DEBUG path so `--print-ast=tree` shows Primary/Explicit/
    /// Partial/Instantiated per decl, making the classification verifiable.
    fn _spec_kind_label(self, kind: Declarations::SpecKind) -> string {
        match kind {
            case Declarations::SpecKind::None {
                return ""
            } case Declarations::SpecKind::Primary {
                return "primary"
            } case Declarations::SpecKind::Explicit {
                return "explicit"
            } case Declarations::SpecKind::Partial {
                return "partial"
            } case Declarations::SpecKind::Instantiated {
                return "instantiated"
            }
        }
    }

    /// Debug-tree inline tag for a specialization: ` [spec=explicit <i32>]`.
    /// Renders nothing for non-specializations (#68). `args` is empty for an
    /// Instantiated node (the registry never fills spec_args -- the concrete
    /// args live on the InstanceEntry, not the decl) and for ExtensionDecl
    /// (whose pattern lives in `target`, not a post-name list); in both cases
    /// the tag prints just `[spec=<kind>]`, skipping the always-empty `<>`
    /// an args-bearing kind would otherwise show.
    fn _dd_spec(self, kind: Declarations::SpecKind, args: FrozenList<unsafe *Type>) {
        if kind == Declarations::SpecKind::None {
            return
        }

        self.p.paint(Color::Punct, " [spec=")
        self.p.paint(Color::Keyword, self._spec_kind_label(kind))
        if !args.is_empty() {
            self.p.put(" ")
            self._spec_args(kind, args)
        }

        self.p.paint(Color::Punct, "]")
    }

    /// An interface's `derives`: the expression as written when it uses `-`
    /// or `&`; a plain union prints as the list it is (`A, B` == `A + B`).
    fn _derives_clause(self, id: unsafe *Declarations::InterfaceDecl) {
        if id->derives_expr == &null || !id->derives_composed {
            self._inherit_list("derives", id->derives_list)
            return
        }

        self.p.put(" ")
        self.p.paint(Color::Keyword, "derives")
        self.p.put(" ")
        self._derives_src(id->derives_expr, 0, false)
    }

    /// The derives expression with the parentheses its tree needs (the parser
    /// keeps none): a child is wrapped when it mixes `&` with `+`/`-` (the
    /// form the parser warns about unparenthesized), or sits on the right of
    /// its own operator class (both are left-associative).
    fn _derives_src(self, e: unsafe *Expr, parent: u8, rhs: bool) {
        var unsafe *b = dyn_cast<Expressions::BinaryOperatorExpr>(e)
        if b == &null {
            self.src_expr(e)
            return
        }

        var mine: u8 = if (b->op_token.kind == TokenKind::OpAmp) => (1) else => 2
        var wrap     = parent > 0 && (mine != parent || rhs)
        if wrap {
            self.p.paint(Color::Punct, "(")
        }

        self._derives_src(b->lhs, mine, false)
        self.p.put(" ")
        self.p.paint(Color::Punct, (if (mine == 1) => ("&") else => (if (b->op_token.kind == TokenKind::OpPlus) => ("+") else => "-")))
        self.p.put(" ")
        self._derives_src(b->rhs, mine, true)
        if wrap {
            self.p.paint(Color::Punct, ")")
        }
    }

    fn _inherit_list(self, const kw: string, edges: FrozenList<Declarations::InheritEdge>) {
        if edges.is_empty() {
            return
        }

        self.p.put(" ")
        self.p.paint(Color::Keyword, kw)
        self.p.put(" ")
        for var i: usize = 0; i < edges.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            var unsafe *e = edges.get(i)
            if e->is_virtual {
                self.p.paint(Color::Keyword, "virtual ")
            }

            self._vis(e->visibility)
            self.src_type(e->base)
        }
    }

    /// Brace member body: fields then methods, "; "-separated on one line.
    /// NOTE: source path only. The DEBUG tree path walks dc_decls instead.
    fn _member_body(self,
                    fields:  FrozenList<unsafe *Declarations::FieldDecl>,
                    methods: FrozenList<unsafe *Declarations::FunctionDecl>) {
        if fields.is_empty() && methods.is_empty() {
            self.p.paint(Color::Punct, " {}")
            return
        }

        self.p.paint(Color::Punct, " { ")
        var first = true
        for var i: usize = 0; i < fields.size(); ++i {
            if !first {
                self.p.paint(Color::Punct, "; ")
            }

            self._d_field(fields[i])
            first = false
        }

        for var i: usize = 0; i < methods.size(); ++i {
            if !first {
                self.p.paint(Color::Punct, "; ")
            }

            self._d_function(methods[i])
            first = false
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _storage_kw(self, s: Declarations::StorageClass) -> string {
        if s == Declarations::StorageClass::Const {
            return "const"
        }

        if s == Declarations::StorageClass::Static {
            return "static"
        }

        if s == Declarations::StorageClass::Eval {
            return "eval"
        }

        return "var"
    }

    /// The binding keywords as one canonical spelling: `thread` for Static
    /// storage with is_thread, then `const` when the binding is const
    /// (`static const` / `thread const`, whichever order was written).
    fn _binding_kw(self,
                   s:             Declarations::StorageClass,
                   is_thread:     bool,
                   const_binding: bool) -> string {
        var kw = self._storage_kw(s)
        if s == Declarations::StorageClass::Static && is_thread {
            kw = "thread"
        }

        if const_binding {
            kw += " const"
        }

        return kw
    }

    /// # FunctionDecl

    fn _fn_modifiers(self, fd: unsafe *Declarations::FunctionDecl) {
        // a Kairo const method prints as `const self` in the parameter list;
        // only a const fn with no const receiver (an imported C++ method
        // whose receiver is implicit) still needs the flag shown here.
        if fd->is_const() && !self._has_const_self(fd) {
            self.p.paint(Color::Keyword, " const")
        }

        if ((fd->modifiers as u16) & (Declarations::FnModifier::IsVolatile as u16)) != 0 {
            self.p.paint(Color::Keyword, " volatile")
        }

        if fd->is_unsafe() {
            self.p.paint(Color::Keyword, " unsafe")
        }

        if fd->is_eval() {
            self.p.paint(Color::Keyword, " eval")
        }

        if fd->is_async() {
            self.p.paint(Color::Keyword, " async")
        }

        if fd->is_final() {
            self.p.paint(Color::Keyword, " final")
        }

        if fd->is_panic() {
            self._panic_spec(fd->panic_set)
        }

        if fd->is_inline() {
            self.p.paint(Color::Keyword, " inline")
        }
    }

    fn _has_const_self(self, fd: unsafe *Declarations::FunctionDecl) -> bool {
        for var i: usize = 0; i < fd->params.size(); ++i {
            var unsafe *p = fd->params[i]
            if p != &null && p->is_self && p->is_const {
                return true
            }
        }

        return false
    }

    fn _param_list(self, params: FrozenList<unsafe *Declarations::ParamDecl>) {
        self.p.paint(Color::Punct, "(")
        for var i: usize = 0; i < params.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self._d_param(params[i])
        }

        self.p.paint(Color::Punct, ")")
    }

    fn _fn_body(self, fd: unsafe *Declarations::FunctionDecl) {
        if fd->body_kind == Declarations::FnBodyKind::Default {
            self.p.paint(Color::Punct, " = ")
            self.p.paint(Color::Keyword, "default")
        } else if fd->body_kind == Declarations::FnBodyKind::Delete {
            self.p.paint(Color::Punct, " = ")
            self.p.paint(Color::Keyword, "delete")
        } else if fd->body_kind == Declarations::FnBodyKind::Expr {
            self.p.paint(Color::Punct, " = ")
            self.src_expr(fd->body_expr)
        } else if fd->body_kind == Declarations::FnBodyKind::Block {
            self.p.put(" ")
            self.src_stmt(fd->body_block)
        }

        // FnBodyKind::None: signature only, nothing trailing. Virtual (pure)
        // too: it is a `virtual fn` with no body, and the modifier prints.
    }

    fn _d_function(self, fd: unsafe *Declarations::FunctionDecl) {
        if fd->abi == Declarations::AbiKind::Static {
            self.p.paint(Color::Keyword, "static ")
        } else if fd->abi == Declarations::AbiKind::Virtual {
            self.p.paint(Color::Keyword, "virtual ")
        } else if fd->abi == Declarations::AbiKind::Override {
            self.p.paint(Color::Keyword, "override ")
        }

        if fd->transfer == Declarations::TransferKind::Copy {
            self.p.paint(Color::Attr, "@copy ")
        }

        if fd->transfer == Declarations::TransferKind::Move {
            self.p.paint(Color::Attr, "@move ")
        }

        self.p.paint(Color::Keyword, "fn")
        self._generic_params(fd->generic_params)
        self.p.put(" ")
        self._spec_intro(fd->spec_kind) // `<>` marker (#68)

        if fd->qualifier != &null {
            self.src_expr(fd->qualifier)
            self.p.paint(Color::Punct, "::")
        }

        if fd->is_operator {
            self.p.paint(Color::Keyword, "op ")
            if !fd->op_token.is_empty() {
                for var i: usize = 0; i < fd->op_token.size(); ++i {
                    self.p.paint(Color::Operator, self.tok(fd->op_token[i]))
                }
            }
        } else {
            self.p.paint(Color::Ident, self.tok(fd->name))
        }

        self._spec_args(fd->spec_kind, fd->spec_args) // post-name `<...>` (#68)

        self._param_list(fd->params)
        self._fn_modifiers(fd)

        if fd->is_noreturn {
            self.p.paint(Color::Punct, " -> ")
            self.p.paint(Color::Operator, "!")
        } else if fd->return_type != &null {
            self.p.paint(Color::Punct, " -> ")
            self.src_type(fd->return_type)
        }

        self._requires(fd->requires_clause)
        self._where(fd->where_clause)
        self._fn_body(fd)
    }

    /// # VariableDecl / FieldDecl / ParamDecl

    fn _d_variable(self, vd: unsafe *Declarations::VariableDecl) {
        self.p.paint(
            Color::Keyword,
            self._binding_kw(vd->storage, vd->is_thread, vd->const_binding),
        )

        self.p.put(" ")
        if vd->pointer_unsafe {
            self.p.paint(Color::Keyword, "unsafe ")
        }

        for var i: u32 = 0; i < vd->pointer_depth; ++i {
            self.p.paint(Color::Punct, "*")
        }

        self.p.paint(Color::Ident, self.tok(vd->name))
        if vd->nullable_shorthand {
            self.p.paint(Color::Punct, "?")
        }

        if vd->type_ != &null {
            self.p.paint(Color::Punct, ": ")
            self.src_type(vd->type_)
        }

        if vd->init != &null {
            self.p.paint(Color::Punct, " = ")
            self.src_expr(vd->init)
        }
    }

    fn _d_field(self, fd: unsafe *Declarations::FieldDecl) {
        if fd->is_mutable {
            self.p.paint(Color::Keyword, "mutable ")
        }

        self.p.paint(
            Color::Keyword,
            self._binding_kw(fd->storage, fd->is_thread, fd->const_binding),
        )

        self.p.put(" ")
        self.p.paint(Color::Ident, self.tok(fd->name))
        if fd->type_ != &null {
            self.p.paint(Color::Punct, ": ")
            self.src_type(fd->type_)
        }

        if fd->init != &null {
            self.p.paint(Color::Punct, " = ")
            self.src_expr(fd->init)
        }
    }

    fn _d_param(self, pd: unsafe *Declarations::ParamDecl) {
        if pd->is_self {
            if pd->is_const {
                self.p.paint(Color::Keyword, "const ")
            }

            self.p.paint(Color::Keyword, "self")
            return
        }

        // `[const] [@mode] name: T`. `const` is the binding's (ParamDecl::
        // is_const), so it exists only on a named param; an unnamed param's
        // const is on its type and prints there. Value prints no mode.
        if pd->is_const && !pd->unname {
            self.p.paint(Color::Keyword, "const ")
        }

        if pd->mode != ParamMode::Value {
            self.p.paint(Color::Attr, param_mode_prefix(pd->mode))
        }

        // The `...` goes on the parameter that CARRIES it, which need not be
        // the last one (keying off `is_variadic` + last index marked the wrong
        // parameter for every keyword-only tail), and it prints HERE rather
        // than in the signature so the ParamDecl row shows it too. After
        // `const`, as written: `const ...s: string`.
        if pd->is_pack {
            self.p.paint(Color::Punct, "...")
        }

        // type-only forward-decl parameter: no name token to print.
        if pd->unname {
            if pd->type_ != &null {
                self.src_type(pd->type_)
            }

            if pd->default_val != &null {
                self.p.paint(Color::Punct, " = ")
                self.src_expr(pd->default_val)
            }

            return
        }

        self.p.paint(Color::Ident, self.tok(pd->name))
        if pd->type_ != &null {
            self.p.paint(Color::Punct, ": ")
            self.src_type(pd->type_)
        }

        if pd->default_val != &null {
            self.p.paint(Color::Punct, " = ")
            self.src_expr(pd->default_val)
        }
    }

    fn _d_generic_param(self, gp: unsafe *Declarations::GenericParamDecl) {
        if gp->is_const_param {
            self.p.paint(Color::Keyword, "eval ")
            self.p.paint(Color::Ident, self.tok(gp->name))
            self.p.paint(Color::Punct, ": ")
            self.src_type(gp->value_type)
            if gp->default_type != &null {
                self.p.paint(Color::Punct, " = ")
                self.src_type(gp->default_type)
            }

            return
        }

        if gp->is_pack {
            self.p.paint(Color::Punct, "...")
        }

        self.p.paint(Color::TypeName, self.tok(gp->name))

        if gp->kind_bound != Declarations::GenericParamKindBound::Any {
            self.p.paint(Color::Punct, ": ")
            if gp->kind_bound == Declarations::GenericParamKindBound::Class {
                self.p.paint(Color::Keyword, "class")
            } else if gp->kind_bound == Declarations::GenericParamKindBound::Struct {
                self.p.paint(Color::Keyword, "struct")
            } else if gp->kind_bound == Declarations::GenericParamKindBound::Enum {
                self.p.paint(Color::Keyword, "enum")
            } else if gp->kind_bound == Declarations::GenericParamKindBound::Union {
                self.p.paint(Color::Keyword, "union")
            } else if gp->kind_bound == Declarations::GenericParamKindBound::Duck {
                self.p.paint(Color::Keyword, "type")
            }
        }

        for var i: usize = 0; i < gp->derives_bounds.size(); ++i {
            self.p.paint(Color::Keyword, " derives ")
            var unsafe *e = gp->derives_bounds.get(i)
            if e->is_virtual {
                self.p.paint(Color::Keyword, "virtual ")
            }

            self._vis(e->visibility)
            self.src_type(e->base)
        }

        for var i: usize = 0; i < gp->impl_bounds.size(); ++i {
            self.p.paint(Color::Keyword, " impl ")
            var unsafe *e = gp->impl_bounds.get(i)
            if e->is_virtual {
                self.p.paint(Color::Keyword, "virtual ")
            }

            self._vis(e->visibility)
            self.src_type(e->base)
        }

        if gp->default_type != &null {
            self.p.paint(Color::Punct, " = ")
            self.src_type(gp->default_type)
        }
    }

    /// # aggregate decls (source path)
    /// NOTE: these use the projection caches because the SOURCE one-liner only
    /// ever reproduced fields+methods; nested types were never in the source
    /// reproduction either. The DEBUG tree path (dump_*) is the surface that
    /// had the drop, and that path walks dc_decls. Left as-is on purpose.

    fn _d_struct(self, sd: unsafe *Declarations::StructDecl) {
        var empty_methods: FrozenList<unsafe *Declarations::FunctionDecl>
        self.p.paint(Color::Keyword, "struct")
        self._generic_params(sd->generic_params)
        self.p.put(" ")
        self._spec_intro(sd->spec_kind) // `<>` marker (#68)
        self.p.paint(Color::TypeName, self.tok(sd->name))
        self._spec_args(sd->spec_kind, sd->spec_args) // post-name `<...>` (#68)
        self._inherit_list("impl", sd->implements)
        self._requires(sd->requires_clause)
        self._member_body(sd->fields, empty_methods)
    }

    fn _d_class(self, cd: unsafe *Declarations::ClassDecl) {
        if cd->is_final {
            self.p.paint(Color::Keyword, "final ")
        }

        self.p.paint(Color::Keyword, "class")
        self._generic_params(cd->generic_params)
        self.p.put(" ")
        self._spec_intro(cd->spec_kind) // `<>` marker (#68)
        self.p.paint(Color::TypeName, self.tok(cd->name))
        self._spec_args(cd->spec_kind, cd->spec_args) // post-name `<...>` (#68)
        self._inherit_list("derives", cd->derives_list)
        self._inherit_list("impl", cd->implements)
        self._requires(cd->requires_clause)
        self._member_body(cd->fields, cd->methods)
    }

    fn _d_interface(self, id: unsafe *Declarations::InterfaceDecl) {
        var empty_fields: FrozenList<unsafe *Declarations::FieldDecl>
        self.p.paint(Color::Keyword, "interface")
        self._generic_params(id->generic_params)
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(id->name))
        self._derives_clause(id)
        self._requires(id->requires_clause)
        self._member_body(empty_fields, id->methods)
    }

    fn _d_extension(self, ed: unsafe *Declarations::ExtensionDecl) {
        var empty_fields: FrozenList<unsafe *Declarations::FieldDecl>
        self.p.paint(Color::Keyword, "extend")
        self._generic_params(ed->generic_params)
        self.p.put(" ")
        self._spec_intro(ed->spec_kind) // `<>` marker (#68); pattern lives in `target`.
        self.src_type(ed->target)
        self._inherit_list("impl", ed->implements)
        self._member_body(empty_fields, ed->methods)
    }

    fn _d_enum(self, en: unsafe *Declarations::EnumDecl) {
        self.p.paint(Color::Keyword, "enum")
        self._generic_params(en->generic_params)
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(en->name))
        if en->underlying != &null {
            self.p.paint(Color::Keyword, " derives ")
            self.src_type(en->underlying)
        }

        if en->variants.is_empty() {
            self.p.paint(Color::Punct, " {}")
            return
        }

        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < en->variants.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            self._d_enum_variant(en->variants[i])
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _d_enum_variant(self, v: unsafe *Declarations::EnumVariantDecl) {
        self.p.paint(Color::Ident, self.tok(v->name))
        if v->is_adt() {
            self.p.paint(Color::Punct, " { ")
            for var i: usize = 0; i < v->payload.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, ", ")
                }

                var unsafe **f = v->payload.get(i)
                self.p.paint(Color::Ident, self.tok((*f)->name))
                self.p.paint(Color::Punct, ": ")
                self.src_type((*f)->type_)
            }

            self.p.paint(Color::Punct, " }")
        } else if v->discriminant != &null {
            self.p.paint(Color::Punct, " = ")
            self.src_expr(v->discriminant)
        }

        if v->is_pack_expansion {
            self.p.paint(Color::Punct, "...")
        }
    }

    fn _d_union(self, ud: unsafe *Declarations::UnionDecl) {
        var empty_methods: FrozenList<unsafe *Declarations::FunctionDecl>
        self.p.paint(Color::Keyword, "union")
        self._generic_params(ud->generic_params)
        self.p.put(" ")
        self._spec_intro(ud->spec_kind) // `<>` marker (#68)
        self.p.paint(Color::TypeName, self.tok(ud->name))
        self._spec_args(ud->spec_kind, ud->spec_args) // post-name `<...>` (#68)
        self._member_body(ud->fields, empty_methods)
    }

    fn _d_type_alias(self, ta: unsafe *Declarations::TypeAliasDecl) {
        self.p.paint(Color::Keyword, "type")
        self._generic_params(ta->generic_params)
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(ta->name))
        self._alias_rest(ta)
    }

    /// ` = T`, or for an associated type its bounds and optional default:
    /// `type N impl X, Y = D` (the bounds are its requires clause's conjuncts).
    fn _alias_rest(self, ta: unsafe *Declarations::TypeAliasDecl) {
        if ta->is_associated && ta->requires_clause != &null {
            self.p.put(" ")
            self.p.paint(Color::Keyword, "impl")
            self.p.put(" ")
            self._assoc_bounds(ta->requires_clause, true)
        }

        if ta->aliased == &null && ta->is_associated {
            return
        }

        self.p.paint(Color::Punct, " = ")
        self.src_type(ta->aliased)
    }

    /// The interfaces of an `N impl X && N impl Y` conjunction, comma-separated.
    fn _assoc_bounds(self, e: unsafe *Expr, first: bool) -> bool {
        var unsafe *b = dyn_cast<Expressions::BinaryOperatorExpr>(e)
        if b != &null {
            var f = self._assoc_bounds(b->lhs, first)
            return self._assoc_bounds(b->rhs, f)
        }

        var unsafe *c = dyn_cast<Expressions::ConstraintExpr>(e)
        if c == &null {
            return first
        }

        if !first {
            self.p.paint(Color::Punct, ", ")
        }

        self.src_type(c->rhs)
        return false
    }

    fn _d_module(self, md: unsafe *Declarations::ModuleDecl) {
        if md->is_inline {
            self.p.paint(Color::Keyword, "inline ")
        }

        self.p.paint(Color::Keyword, "module")
        if !md->is_anonymous {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(md->name))
        }

        var unsafe *dc = unsafe (md as unsafe *DeclContext)
        if dc->dc_decls.size() == 0 {
            self.p.paint(Color::Punct, " {}")
            return
        }

        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, "; ")
            }

            self.src_decl(*dc->dc_decls.get(i))
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _d_import(self, im: unsafe *Declarations::ImportDecl) {
        // The injected `import builtin::*` is not in the source. Printing it
        // would make the rendered tree disagree with the file it came from,
        // and a round-tripped print would then carry an import the user never
        // wrote. It has no path_segments to spell either.
        if im->is_prelude {
            return
        }

        if im->has_ffi_linkage() {
            self.p.paint(Color::Keyword, "ffi ")
            self.p.paint(Color::Literal, self.tok(im->ffi_lang_token()))
            self.p.put(" ")
        }

        self.p.paint(Color::Keyword, "import ")

        if im->has_ffi_linkage() {
            self.p.paint(Color::Literal, self.tok(im->header))
        } else {
            if im->import_kind == Declarations::ImportKind::SelfRelative {
                self.p.paint(Color::Keyword, "self")
                self.p.paint(Color::Punct, "::")
            } else if im->import_kind == Declarations::ImportKind::ModuleRelative {
                self.p.paint(Color::Keyword, "module")
                self.p.paint(Color::Punct, "::")
            }

            for var i: usize = 0; i < im->path_segments.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, "::")
                }

                self.p.paint(Color::Ident, self.tok(*im->path_segments.get(i)))
            }

            if im->is_wildcard {
                self.p.paint(Color::Punct, "::*")
            } else if im->has_items {
                self.p.paint(Color::Punct, "::{")
                for var i: usize = 0; i < im->items.size(); ++i {
                    if i > 0 {
                        self.p.paint(Color::Punct, ", ")
                    }

                    self._import_item(im->items.get(i))
                }

                self.p.paint(Color::Punct, "}")
            }
        }

        if im->has_alias {
            self.p.paint(Color::Keyword, " as ")
            self.p.paint(Color::Ident, self.tok(im->alias))
        }
    }

    fn _import_item(self, it: unsafe *Declarations::ImportItem) {
        if it->is_wildcard {
            self.p.paint(Color::Punct, "*")
            return
        }

        for var i: usize = 0; i < it->sub_path.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, "::")
            }

            self.p.paint(Color::Ident, self.tok(*it->sub_path.get(i)))
        }

        if it->has_alias {
            self.p.paint(Color::Keyword, " as ")
            self.p.paint(Color::Ident, self.tok(it->alias))
        }
    }

    fn _d_vis_group(self, vg: unsafe *Declarations::VisibilityGroupDecl) {
        self._vis(vg->group_visibility)
        if vg->members.is_empty() {
            self.p.paint(Color::Punct, "{}")
            return
        }

        self.p.paint(Color::Punct, "{ ")
        for var i: usize = 0; i < vg->members.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, "; ")
            }

            self.src_decl(vg->members[i])
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _d_ffi_block(self, fb: unsafe *Declarations::FFIBlockDecl) {
        self.p.paint(Color::Keyword, "ffi ")
        self.p.paint(Color::Literal, self.tok(fb->lang_token))
        if fb->body.is_empty() {
            self.p.paint(Color::Punct, " {}")
            return
        }

        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < fb->body.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, "; ")
            }

            self.src_decl(fb->body[i])
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _d_eval_block(self, eb: unsafe *Declarations::EvalBlockDecl) {
        // member-position `eval if` / `eval for`. A for loop prints its own
        // `eval`; ConditionalStmt does not carry it yet (StmtParse FIXME).
        if eb->stmt != &null {
            if isa<Statements::ConditionalStmt>(eb->stmt) {
                self.p.paint(Color::Keyword, "eval ")
            }

            self.src_stmt(eb->stmt)
            return
        }

        self.p.paint(Color::Keyword, "eval")
        if eb->body.is_empty() {
            self.p.paint(Color::Punct, " {}")
            return
        }

        self.p.paint(Color::Punct, " { ")
        for var i: usize = 0; i < eb->body.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, "; ")
            }

            self.src_decl(eb->body[i])
        }

        self.p.paint(Color::Punct, " }")
    }

    fn _d_test(self, td: unsafe *Declarations::TestDecl) {
        self.p.paint(Color::Keyword, "test")
        if td->label != &null {
            self.p.put(" ")
            self.src_expr(td->label)
        }

        self.p.put(" ")
        if td->body != &null {
            self.src_stmt(td->body)
        } else {
            self.p.paint(Color::Punct, "{}")
        }
    }

    fn _d_macro(self, mc: unsafe *Declarations::MacroDecl) {
        self.p.paint(Color::Keyword, "macro ")
        self.p.paint(Color::Ident, self.tok(mc->name))
        self.p.paint(Color::Punct, "!(")
        for var i: usize = 0; i < mc->params_spec.size(); ++i {
            if i > 0 {
                self.p.paint(Color::Punct, ", ")
            }

            if mc->is_variadic && i == mc->params_spec.size() - 1 {
                self.p.paint(Color::Punct, "...")
            }

            self.p.paint(Color::Ident, self.tok(mc->params_spec.get(i)->name))
        }

        self.p.paint(Color::Punct, ") { ... }")
    }

    fn _d_proc_macro(self, pm: unsafe *Declarations::ProcedureMacroDecl) {
        self.p.paint(Color::Keyword, "macro ")
        self.p.paint(Color::Attr, f"@{self.tok(pm->name)}")
        self._param_list(pm->params)
        self.p.put(" ")
        if pm->body != &null {
            self.src_stmt(unsafe (pm->body as unsafe *Stmt))
        } else {
            self.p.paint(Color::Punct, "{}")
        }
    }

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

    /// Spine + colored node-kind tag. Caller appends attrs, then recurses.
    fn _head(self, const kind: string, is_last: bool) {
        self.p.row(is_last)
        self.p.paint(Color::NodeKind, kind)
    }

    fn _dim(self, const s: string) {
        self.p.put(" ")
        self.p.paint(Color::Dim, s)
    }

    fn _inline_type(self, t: unsafe *Type) {
        self.p.put(" ")
        self.src_type(t)
    }

    fn _inline_expr(self, e: unsafe *Expr) {
        self.p.put(" ")
        self.src_expr(e)
    }

    /// # attribute + visibility row prefix

    /// Emit written visibility, inline on the current decl row, before its
    /// name. `pub `/`prot `/`priv ` only no output for unspecified.
    fn _dump_vis(self, decl: unsafe *Decl) {
        if decl->has_visibility() {
            self.p.put(" ")
            self._vis(decl->visibility as u8)
        }
    }

    /// Helper to print ffi linkage modifier next to visibility on debug rows.
    fn _dump_ffi_linkage(self, d: unsafe *Decl) {
        var has_ffi  = false
        var lang_tok = Token()

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *fd = cast<Declarations::FunctionDecl>(d)
            has_ffi  = fd->has_ffi_linkage()
            lang_tok = fd->ffi_lang_token()
        } else if isa<Declarations::ClassDecl>(d) {
            var unsafe *cd = cast<Declarations::ClassDecl>(d)
            has_ffi  = cd->has_ffi_linkage()
            lang_tok = cd->ffi_lang_token()
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *sd = cast<Declarations::StructDecl>(d)
            has_ffi  = sd->has_ffi_linkage()
            lang_tok = sd->ffi_lang_token()
        } else if isa<Declarations::UnionDecl>(d) {
            var unsafe *ud = cast<Declarations::UnionDecl>(d)
            has_ffi  = ud->has_ffi_linkage()
            lang_tok = ud->ffi_lang_token()
        } else if isa<Declarations::TypeAliasDecl>(d) {
            var unsafe *ta = cast<Declarations::TypeAliasDecl>(d)
            has_ffi  = ta->has_ffi_linkage()
            lang_tok = ta->ffi_lang_token()
        } else if isa<Declarations::VariableDecl>(d) {
            var unsafe *vd = cast<Declarations::VariableDecl>(d)
            has_ffi  = vd->has_ffi_linkage()
            lang_tok = vd->ffi_lang_token()
        } else if isa<Declarations::ImportDecl>(d) {
            var unsafe *id = cast<Declarations::ImportDecl>(d)
            has_ffi  = id->has_ffi_linkage()
            lang_tok = id->ffi_lang_token()
        }

        if has_ffi {
            self.p.put(" ")
            self.p.paint(Color::Keyword, "ffi ")
            self.p.paint(Color::Literal, self.tok(lang_tok))
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
    fn _dump_annotations(self, decl: unsafe *Decl, attrs_are_last: bool) {
        var n = decl->annotations.size()
        for var i: usize = 0; i < n; ++i {
            var unsafe *entry = decl->annotations.get(i)
            var        last   = attrs_are_last && i == n - 1
            self._head("Attribute", last)
            self.p.put(" ")
            self._dump_one_annotation(entry)
            self.p.newline()
        }
    }

    /// One annotation entry. Attribute => `@name(args)`; comment => `<kind>`.
    ///
    /// Attribute args reuse the call-arg production verbatim.
    ///
    /// Named args (`@dep(since: 2)`) parse to AssignOperatorExpr(lhs=label,
    /// rhs=value) -- the call-arg grammar folds `name: val` onto the assign
    /// production. We render those as `label: value` to match source spelling
    /// rather than the stored `=`.
    fn _dump_one_annotation(self, entry: unsafe *AnnotationEntry) {
        if entry->kind == AnnotationKind::Attribute {
            var nm = self.istr(entry->name)
            if self._istr_unresolved() {
                self.p.paint(Color::Attr, "@<unresolved>")
            } else {
                self.p.paint(Color::Attr, f"@{nm}")
            }

            if !entry->args.is_empty() {
                self.p.paint(Color::Punct, "(")
                for var i: usize = 0; i < entry->args.size(); ++i {
                    if i > 0 {
                        self.p.paint(Color::Punct, ", ")
                    }

                    var unsafe *arg = *entry->args.get(i)
                    self._attr_arg(arg)
                }

                self.p.paint(Color::Punct, ")")
            }

            return
        }

        if entry->kind == AnnotationKind::DocComment {
            self.p.paint(Color::Dim, "/// doc-comment")
            return
        }

        if entry->kind == AnnotationKind::LineComment {
            self.p.paint(Color::Dim, "// line-comment")
            return
        }

        if entry->kind == AnnotationKind::BlockComment {
            self.p.paint(Color::Dim, "/* block-comment */")
            return
        }

        self.p.paint(Color::Dim, "<annotation>")
    }

    /// Render one attribute arg. Named args parse to AssignOperatorExpr whose
    /// op_token is a synthesized OpColon (see _parse_call_args: `csome: 4`
    /// becomes AssignOperatorExpr(csome, 4, <colon>)). A genuine positional
    /// assignment `foo(x = 4)` is the SAME node kind but with op_token == `=`,
    /// so we discriminate on op_token.kind, NOT on isa<AssignOperatorExpr>.
    /// The colon token is synthesized with the name's range, so tok() on it is
    /// unreliable -- render the `:` literally rather than routing op_token
    /// through src_expr's spelling lookup.
    fn _attr_arg(self, arg: unsafe *Expr) {
        if arg == &null {
            self.p.paint(Color::Error, "<error>")
            return
        }

        if isa<Expressions::AssignOperatorExpr>(arg) {
            var unsafe *a = cast<Expressions::AssignOperatorExpr>(arg)
            if a->op_token.kind == TokenKind::OpColon {
                // named argument: render label : value
                self.src_expr(a->lhs)
                self.p.paint(Color::Punct, ": ")
                self.src_expr(a->rhs)
                return
            }

            // genuine positional assignment passed as an arg: let src_expr
            // render it with its real `=` spelling.
        }

        self.src_expr(arg)
    }

    /// True if this decl has any annotation to render as a child row.
    fn _has_annotations(self, decl: unsafe *Decl) -> bool {
        return decl->annotations.size() > 0
    }

    //  RAV DISPATCHER OVERRIDES
    //
    //  These five are the entire RAV surface AstDumper overrides. Each reads
    //  _pending_last (set by the caller just before the dispatch call),
    //  renders the node, recurses on children with its own is_last logic, and
    //  returns the node unchanged (the dumper never rewrites the tree).

    /* OVERRIDE */
    fn dispatch_type(self, ty: unsafe *Type) -> unsafe *Type {
        var is_last = self._pending_last
        self.dump_type_row(ty, is_last)
        return ty
    }

    /* OVERRIDE */
    fn dispatch_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        var is_last = self._pending_last
        self.dump_expr_row(e, is_last)
        return e
    }

    /* OVERRIDE */
    fn dispatch_pattern(self, pat: unsafe *Pattern) -> unsafe *Pattern {
        var is_last = self._pending_last
        self.dump_pattern_row(pat, is_last)
        return pat
    }

    /* OVERRIDE */
    fn dispatch_stmt(self, s: unsafe *Stmt) -> unsafe *Stmt {
        var is_last = self._pending_last
        self.dump_stmt_row(s, is_last)
        return s
    }

    /* OVERRIDE */
    fn dispatch_decl(self, d: unsafe *Decl) -> unsafe *Decl {
        var is_last = self._pending_last
        self.dump_decl_row(d, is_last)
        return d
    }

    /// # child-dispatch helpers (set is_last, route through dyn())
    /// Going through self.dyn()->dispatch_* keeps the CRTP contract: a future
    /// subclass of AstDumper would still intercept. is_last is threaded via
    /// _pending_last because the dispatch signature cannot carry it.

    fn _child_decl(self, d: unsafe *Decl, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_decl(d)
    }

    fn _child_stmt(self, s: unsafe *Stmt, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_stmt(s)
    }

    fn _child_expr(self, e: unsafe *Expr, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_expr(e)
    }

    fn _child_type(self, t: unsafe *Type, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_type(t)
    }

    fn _child_pattern(self, pat: unsafe *Pattern, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_pattern(pat)
    }

    //  TYPE dump row

    fn dump_type_row(self, ty: unsafe *Type, is_last: bool) {
        if ty == &null {
            self._head("<null-type>", is_last)
            self.p.paint(Color::Error, " <null>")
            self.p.newline()
            return
        }

        if ty->is_error() {
            self._head("RecoveryType", is_last)
            self._dim(self._recovery_name(self._type_kind_name_of(ty->recovery_kind)))
            self.p.newline()
            return
        }

        self._head(self._type_kind_name(ty), is_last)
        self.p.put(" '")
        self.src_type(ty)
        self.p.put("'")
        self.p.newline()

        // structured types that carry generic arguments (or a value-expr
        // payload) explode into child rows so the args  including nested
        // value expressions like `Array<i32, foo()>`  are walkable.
        if self._type_is_expandable(ty) {
            self.p.enter(is_last)
            self._dump_type_children(ty)
            self.p.leave()
        }
    }

    /// # generic-aware type expansion
    /// The dumper renders types inline by default; these helpers add child rows
    /// only when a type carries a generic argument list (or a TypeExpr value),
    /// keeping leaf types (`i32`, `*u8`) on a single inline row.

    fn _chain_generic_arg_count(self, ty: unsafe *Types::ChainType) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < ty->segments.size(); ++i {
            n += ty->segments.get(i)->generic_args.size()
        }

        return n
    }

    /// True when `ty` (or a nested element/pointee/arg) carries generic
    /// arguments or is a value-expression type, i.e. it has children worth
    /// exploding into the tree.
    fn _type_is_expandable(self, ty: unsafe *Type) -> bool {
        if ty == &null {
            return false
        }

        if ty->is_error() {
            return false
        }

        if isa<Types::ChainType>(ty) {
            return self._chain_generic_arg_count(cast<Types::ChainType>(ty)) > 0
        }

        if isa<Types::TypeExpr>(ty) {
            return true
        }

        if isa<Types::PointerType>(ty) {
            return self._type_is_expandable(cast<Types::PointerType>(ty)->pointee)
        }

        if isa<Types::NullableType>(ty) {
            return self._type_is_expandable(cast<Types::NullableType>(ty)->inner)
        }

        if isa<Types::VectorType>(ty) {
            return self._type_is_expandable(cast<Types::VectorType>(ty)->element)
        }

        if isa<Types::SetType>(ty) {
            return self._type_is_expandable(cast<Types::SetType>(ty)->element)
        }

        if isa<Types::VariadicPackType>(ty) {
            return self._type_is_expandable(cast<Types::VariadicPackType>(ty)->param)
        }

        if isa<Types::PackExpansionType>(ty) {
            return self._type_is_expandable(cast<Types::PackExpansionType>(ty)->pattern)
        }

        if isa<Types::CXXLValueRefType>(ty) {
            return self._type_is_expandable(cast<Types::CXXLValueRefType>(ty)->referee)
        }

        if isa<Types::CXXRValueRefType>(ty) {
            return self._type_is_expandable(cast<Types::CXXRValueRefType>(ty)->referee)
        }

        if isa<Types::FixedArrayType>(ty) {
            return self._type_is_expandable(cast<Types::FixedArrayType>(ty)->element)
        }

        if isa<Types::TupleType>(ty) {
            var unsafe *tt = cast<Types::TupleType>(ty)
            for var i: usize = 0; i < tt->elements.size(); ++i {
                if self._type_is_expandable(tt->elements[i]) {
                    return true
                }
            }

            return false
        }

        if isa<Types::MapType>(ty) {
            return self._type_is_expandable(cast<Types::MapType>(ty)->key)
                || self._type_is_expandable(cast<Types::MapType>(ty)->value)
        }

        if isa<Types::FunctionPointerType>(ty) {
            var unsafe *fp = cast<Types::FunctionPointerType>(ty)
            for var i: usize = 0; i < fp->params.size(); ++i {
                if self._type_is_expandable(fp->params[i]) {
                    return true
                }
            }

            return fp->return_type != &null && self._type_is_expandable(fp->return_type)
        }

        return false
    }

    /// Emit the structural child rows of an expandable type. Mirrors the set in
    /// `_type_is_expandable`.
    fn _dump_type_children(self, ty: unsafe *Type) {
        if isa<Types::ChainType>(ty) {
            var unsafe *ct         = cast<Types::ChainType>(ty)
            var        total       = self._chain_generic_arg_count(ct)
            var        seen: usize = 0
            for var i: usize = 0; i < ct->segments.size(); ++i {
                var unsafe *seg = ct->segments.get(i)
                for var j: usize = 0; j < seg->generic_args.size(); ++j {
                    ++seen
                    self._dump_generic_arg_row(seg->generic_args.get(j), seen == total)
                }
            }

            return
        }

        if isa<Types::TypeExpr>(ty) {
            self._child_expr(cast<Types::TypeExpr>(ty)->expr, true)
            return
        }

        if isa<Types::PointerType>(ty) {
            self._child_type(cast<Types::PointerType>(ty)->pointee, true)
            return
        }

        if isa<Types::NullableType>(ty) {
            self._child_type(cast<Types::NullableType>(ty)->inner, true)
            return
        }

        if isa<Types::VectorType>(ty) {
            self._child_type(cast<Types::VectorType>(ty)->element, true)
            return
        }

        if isa<Types::SetType>(ty) {
            self._child_type(cast<Types::SetType>(ty)->element, true)
            return
        }

        if isa<Types::VariadicPackType>(ty) {
            self._child_type(cast<Types::VariadicPackType>(ty)->param, true)
            return
        }

        if isa<Types::PackExpansionType>(ty) {
            self._child_type(cast<Types::PackExpansionType>(ty)->pattern, true)
            return
        }

        if isa<Types::CXXLValueRefType>(ty) {
            self._child_type(cast<Types::CXXLValueRefType>(ty)->referee, true)
            return
        }

        if isa<Types::CXXRValueRefType>(ty) {
            self._child_type(cast<Types::CXXRValueRefType>(ty)->referee, true)
            return
        }

        if isa<Types::FixedArrayType>(ty) {
            self._child_type(cast<Types::FixedArrayType>(ty)->element, true)
            return
        }

        if isa<Types::TupleType>(ty) {
            var unsafe *tt = cast<Types::TupleType>(ty)
            for var i: usize = 0; i < tt->elements.size(); ++i {
                self._child_type(tt->elements[i], i == tt->elements.size() - 1)
            }

            return
        }

        if isa<Types::MapType>(ty) {
            var unsafe *mt = cast<Types::MapType>(ty)
            self._child_type(mt->key, false)
            self._child_type(mt->value, true)
            return
        }

        if isa<Types::FunctionPointerType>(ty) {
            var unsafe *fp     = cast<Types::FunctionPointerType>(ty)
            var        np      = fp->params.size()
            var        has_ret = fp->return_type != &null
            for var i: usize = 0; i < np; ++i {
                self._child_type(fp->params[i], i == np - 1 && !has_ret)
            }

            if has_ret {
                self._child_type(fp->return_type, true)
            }

            return
        }
    }

    fn _dump_generic_args_children(self, args: FrozenList<Types::ChainType::GenericArg>) {
        for var i: usize = 0; i < args.size(); ++i {
            self._dump_generic_arg_row(args.get(i), i == args.size() - 1)
        }
    }

    fn _dump_generic_arg_row(self, arg: unsafe *Types::ChainType::GenericArg, is_last: bool) {
        self._head("GenericArg", is_last)
        if arg->name != &null {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(arg->name->name))
            self.p.paint(Color::Punct, ":")
        }

        self.p.put(" '")
        self.src_type(arg->ty)
        self.p.put("'")
        self.p.newline()

        if self._type_is_expandable(arg->ty) {
            self.p.enter(is_last)
            self._dump_type_children(arg->ty)
            self.p.leave()
        }
    }

    //  EXPR dump row

    fn dump_expr_row(self, e: unsafe *Expr, is_last: bool) {
        if e == &null {
            self._head("<null-expr>", is_last)
            self.p.paint(Color::Error, " <null>")
            self.p.newline()
            return
        }

        if e->is_error() {
            self._head("RecoveryExpr", is_last)
            self._dim(self._recovery_name(self._expr_kind_name_of(e->recovery_kind)))
            self.p.newline()
            return
        }

        // CharacterLiteralExpr belongs here with the other scalar leaves:
        // _inline_expr already knows how to render one, and without this arm it
        // falls all the way through to `<unknown-expr>`.
        if isa<IntegerLiteralExpr>(e)
            || isa<FloatingLiteralExpr>(e)
            || isa<BooleanLiteralExpr>(e)
            || isa<NullLiteralExpr>(e)
            || isa<CharacterLiteralExpr>(e)
            || isa<Expressions::DefinedExpr>(e) {
            self._head(self._expr_kind_name(e), is_last)
            self._inline_expr(e)
            self.p.newline()
            return
        }

        // NamedIdentExpr is a leaf row unless it carries generic arguments
        // (`foo<sizeof i32>`), which explode into walkable child rows.
        if isa<NamedIdentExpr>(e) {
            var unsafe *ni = cast<NamedIdentExpr>(e)
            self._head(self._expr_kind_name(e), is_last)
            self._inline_expr(e)
            self.p.newline()
            if !ni->generic_args.is_empty() {
                self.p.enter(is_last)
                self._dump_generic_args_children(ni->generic_args)
                self.p.leave()
            }

            return
        }

        if isa<ChainExpr>(e) {
            self._dx_chain(cast<ChainExpr>(e), is_last)
            return
        }

        if isa<Expressions::CallExpr>(e) {
            self._dx_call(cast<Expressions::CallExpr>(e), is_last)
            return
        }

        if isa<Expressions::SubscriptExpr>(e) {
            self._dx_subscript(cast<Expressions::SubscriptExpr>(e), is_last)
            return
        }

        if isa<Expressions::UnaryOperatorExpr>(e) {
            self._dx_unary(cast<Expressions::UnaryOperatorExpr>(e), is_last)
            return
        }

        if isa<Expressions::BinaryOperatorExpr>(e) {
            self._dx_binop(cast<Expressions::BinaryOperatorExpr>(e), is_last)
            return
        }

        if isa<Expressions::AssignOperatorExpr>(e) {
            self._dx_assign(cast<Expressions::AssignOperatorExpr>(e), is_last)
            return
        }

        if isa<StringLiteralExpr>(e) {
            self._dx_string_literal(cast<StringLiteralExpr>(e), is_last)
            return
        }

        if isa<Expressions::ListLiteralExpr>(e) {
            self._dx_list_literal(cast<Expressions::ListLiteralExpr>(e), is_last)
            return
        }

        if isa<Expressions::InitListExpr>(e) {
            self._dx_expr_seq("InitListExpr", cast<Expressions::InitListExpr>(e)->elements, is_last)
            return
        }

        if isa<Expressions::StmtExpr>(e) {
            self._dx_stmt_expr(cast<Expressions::StmtExpr>(e), is_last)
            return
        }

        if isa<Expressions::TupleLiteralExpr>(e) {
            self._dx_expr_seq(
                "TupleLiteralExpr",
                cast<Expressions::TupleLiteralExpr>(e)->elements,
                is_last,
            )

            return
        }

        if isa<Expressions::SetLiteralExpr>(e) {
            self._dx_expr_seq(
                "SetLiteralExpr",
                cast<Expressions::SetLiteralExpr>(e)->elements,
                is_last,
            )

            return
        }

        if isa<Expressions::MapLiteralExpr>(e) {
            self._dx_map(cast<Expressions::MapLiteralExpr>(e), is_last)
            return
        }

        if isa<Expressions::NamedInitializerExpr>(e) {
            self._dx_named_init(cast<Expressions::NamedInitializerExpr>(e), is_last)
            return
        }

        if isa<Expressions::VariantInitExpr>(e) {
            self._dx_variant_init(cast<Expressions::VariantInitExpr>(e), is_last)
            return
        }

        if isa<Expressions::AnonInitializerExpr>(e) {
            self._dx_anon_init(cast<Expressions::AnonInitializerExpr>(e), is_last)
            return
        }

        if isa<Expressions::IfExpr>(e) {
            self._dx_if(cast<Expressions::IfExpr>(e), is_last)
            return
        }

        if isa<Expressions::TryCatchExpr>(e) {
            self._dx_try(cast<Expressions::TryCatchExpr>(e), is_last)
            return
        }

        if isa<Expressions::MatchExpr>(e) {
            self._dx_match(cast<Expressions::MatchExpr>(e), is_last)
            return
        }

        if isa<Expressions::RangeExpr>(e) {
            self._dx_range(cast<Expressions::RangeExpr>(e), is_last)
            return
        }

        if isa<Expressions::ClosureExpr>(e) {
            self._dx_closure(cast<Expressions::ClosureExpr>(e), is_last)
            return
        }

        if isa<Expressions::AwaitExpr>(e) {
            self._dx_kw("AwaitExpr", cast<Expressions::AwaitExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::UnwrapExpr>(e) {
            self._dx_kw("UnwrapExpr", cast<Expressions::UnwrapExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::AttributedExpr>(e) {
            self._dx_attributed(cast<Expressions::AttributedExpr>(e), is_last)
            return
        }

        if isa<Expressions::PanicOpExpr>(e) {
            self._dx_panic_op(cast<Expressions::PanicOpExpr>(e), is_last)
            return
        }

        if isa<Expressions::SpawnExpr>(e) {
            self._dx_kw("SpawnExpr", cast<Expressions::SpawnExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::ThreadExpr>(e) {
            self._dx_kw("ThreadExpr", cast<Expressions::ThreadExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::EvalExpr>(e) {
            self._dx_kw("EvalExpr", cast<Expressions::EvalExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::UnsafeExpr>(e) {
            self._dx_kw("UnsafeExpr", cast<Expressions::UnsafeExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::ParenExpr>(e) {
            self._dx_kw("ParenExpr", cast<Expressions::ParenExpr>(e)->inner, is_last)
            return
        }

        if isa<Expressions::NamedArgExpr>(e) {
            var unsafe *na = cast<Expressions::NamedArgExpr>(e)
            self._head("NamedArgExpr", is_last)
            self.p.paint(Color::Ident, f" {self.tok(na->name)}:")
            self.p.newline()
            self.p.enter(is_last)
            self._child_expr(na->value, true)
            self.p.leave()
            return
        }

        if isa<Expressions::VerbatimExpr>(e) {
            var unsafe *ve = cast<Expressions::VerbatimExpr>(e)
            self._head("VerbatimExpr", is_last)
            if self.ctx != &null && self.ctx->sm != &null {
                self.p.paint(Color::Literal, f" '{self.ctx->sm->get_text(ve->span)}'")
            }

            self.p.newline()
            return
        }

        if isa<Expressions::DeleteExpr>(e) {
            var unsafe *de = cast<Expressions::DeleteExpr>(e)
            self._dx_kw(
                (if (de->is_cxx) => ("DeleteExpr @cxx") else => "DeleteExpr"),
                de->operand,
                is_last,
            )

            return
        }

        if isa<Expressions::CxxNewExpr>(e) {
            var unsafe *ne = cast<Expressions::CxxNewExpr>(e)
            self._head((if (ne->is_array()) => ("CxxNewExpr []") else => "CxxNewExpr"), is_last)
            self.p.newline()
            self.p.enter(is_last)
            if ne->is_array() {
                self._child_expr(ne->elem_size, false)
                self._child_expr(ne->count, true)
            } else {
                self._child_expr(ne->init, true)
            }

            self.p.leave()
            return
        }

        if isa<Expressions::PackExpansionExpr>(e) {
            self._dx_kw(
                "PackExpansionExpr",
                cast<Expressions::PackExpansionExpr>(e)->operand,
                is_last,
            )

            return
        }

        if isa<Expressions::ConstraintExpr>(e) {
            self._dx_constraint(cast<Expressions::ConstraintExpr>(e), is_last)
            return
        }

        if isa<Expressions::SizeOfExpr>(e) {
            self._head("SizeOfExpr", is_last)
            self._inline_type(cast<Expressions::SizeOfExpr>(e)->type_arg)
            self.p.newline()
            return
        }

        if isa<Expressions::AlignOfExpr>(e) {
            self._head("AlignOfExpr", is_last)
            self._inline_type(cast<Expressions::AlignOfExpr>(e)->type_arg)
            self.p.newline()
            return
        }

        if isa<Expressions::TypeTraitExpr>(e) {
            self._head("TypeTraitExpr", is_last)
            self.p.put(
                " " + Expressions::type_trait_spelling(
                    cast<Expressions::TypeTraitExpr>(e)->fact,
                ) + "!",
            )

            self._inline_type(cast<Expressions::TypeTraitExpr>(e)->type_arg)
            self.p.newline()
            return
        }

        if isa<Expressions::TypeOfExpr>(e) {
            self._dx_kw("TypeOfExpr", cast<Expressions::TypeOfExpr>(e)->operand, is_last)
            return
        }

        if isa<Expressions::TypeCastExpr>(e) {
            self._dx_cast(cast<Expressions::TypeCastExpr>(e), is_last)
            return
        }

        if isa<Expressions::ImplConformanceExpr>(e) {
            self._dx_two_types(
                "ImplConformanceExpr",
                cast<Expressions::ImplConformanceExpr>(e)->subject,
                cast<Expressions::ImplConformanceExpr>(e)->inter,
                is_last,
            )

            return
        }

        if isa<Expressions::DerivesRelationExpr>(e) {
            self._dx_two_types(
                "DerivesRelationExpr",
                cast<Expressions::DerivesRelationExpr>(e)->subject,
                cast<Expressions::DerivesRelationExpr>(e)->base,
                is_last,
            )

            return
        }

        if isa<Expressions::ImplicitBoundaryCastExpr>(e) {
            self._dx_boundary(cast<Expressions::ImplicitBoundaryCastExpr>(e), is_last)
            return
        }

        self._head("<unknown-expr>", is_last)
        self.p.newline()
    }

    fn _dx_chain(self, e: unsafe *ChainExpr, is_last: bool) {
        self._head("ChainExpr", is_last)
        self.p.put(" '")
        self.src_expr(e)
        self.p.put("'")
        self.p.newline()

        self.p.enter(is_last)
        var has_base = e->base != &null
        var nsteps   = e->steps.size()

        if has_base {
            self._child_expr(e->base, nsteps == 0)
        }

        for var i: usize = 0; i < nsteps; ++i {
            var unsafe *s   = e->steps.get(i)
            var        last = i == nsteps - 1
            self._head("Step", last)
            self.p.put(" ")
            self._access_op(s->access_kind)
            if s->is_operator() {
                self.p.paint(Color::Keyword, "op")
                for var j: usize = 0; j < s->op_tokens.size(); ++j {
                    self.p.paint(Color::Operator, self.tok(s->op_tokens[j]))
                }
            } else if s->is_tuple_index() {
                self.p.paint(Color::Literal, f"{s->index}")
                self._dim(" tuple-index")
            } else if s->name != &null {
                self.p.paint(Color::Ident, self.tok(s->name->name))
            } else {
                self.p.paint(Color::Error, "<error>")
            }

            self._generic_args(s->generic_args)
            self.p.newline()
        }

        self.p.leave()
    }

    fn _dx_call(self, e: unsafe *Expressions::CallExpr, is_last: bool) {
        self._head("CallExpr", is_last)
        self._dim(f"({e->args.size()} args)")
        self._instance(e->instance)
        self.p.newline()
        self.p.enter(is_last)
        var has_args = !e->args.is_empty()
        self._child_expr(e->callee, !has_args)
        for var i: usize = 0; i < e->args.size(); ++i {
            self._child_expr(e->args[i], i == e->args.size() - 1)
        }

        self.p.leave()
    }

    /// ` instance(N args)` for a slot X filled with a generic callee's
    /// registry entry (`*InstanceEntry` as `*void`); nothing when unset. The
    /// args are CANONICALS, which only Sema can spell (TypeUtil::str; src_type
    /// renders them `<error>`), so the tree marks the slot and --print-sema /
    /// --print-lowered print the args themselves.
    fn _instance(self, ie: unsafe *InstanceEntry) {
        if ie == &null {
            return
        }

        self._dim(f"instance({ie->args.size()} args)")
    }

    fn _dx_subscript(self, e: unsafe *Expressions::SubscriptExpr, is_last: bool) {
        self._head("SubscriptExpr", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->base, false)
        self._child_expr(e->index, true)
        self.p.leave()
    }

    fn _dx_unary(self, e: unsafe *Expressions::UnaryOperatorExpr, is_last: bool) {
        self._head("UnaryOperatorExpr", is_last)
        self.p.put(" ")
        self.p.paint(Color::Dim, (if (e->is_prefix()) => ("prefix ") else => "postfix "))
        self.p.paint(Color::Operator, self.tok(e->op_token))
        self._instance(e->op_instance)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->operand, true)
        self.p.leave()
    }

    /// A left-leaning chain (`1 + 1 + 1 + ...`) is printed with the left
    /// spine walked in a loop: its depth is the term count, and a few
    /// thousand terms overflowed the stack when each level was a call.
    /// The rows come out in the order the recursion printed them: every
    /// node's head on the way down, then each right operand and `leave` on
    /// the way back.
    fn _dx_binop(self, e: unsafe *Expressions::BinaryOperatorExpr, is_last: bool) {
        var spine = cxx::std::vector<unsafe *Expressions::BinaryOperatorExpr>()
        var unsafe *cur = e
        var last  = is_last
        while true {
            self._head("BinaryOperatorExpr", last)
            self.p.put(" ")
            self.p.paint(Color::Operator, self.tok(cur->op_token))
            if cur->op_rewrite == Expressions::OpRewrite::Not {
                self._dim("rewrite !(==)")
            }

            if cur->op_rewrite == Expressions::OpRewrite::Cmp {
                self._dim("rewrite <=> vs 0")
            }

            if cur->tag_eq {
                self._dim("tag_eq")
            }

            self._instance(cur->op_instance)
            self.p.newline()
            self.p.enter(last)
            spine.push_back(cur)
            if cur->lhs != &null && (!cur->lhs->is_error()) && isa<Expressions::BinaryOperatorExpr>(cur->lhs) {
                cur  = cast<Expressions::BinaryOperatorExpr>(cur->lhs)
                last = false
                continue
            }

            self._child_expr(cur->lhs, false)
            break
        }

        var i = spine.size()
        while i > 0 {
            i -= 1
            self._child_expr(spine[i]->rhs, true)
            self.p.leave()
        }
    }

    fn _dx_constraint(self, e: unsafe *Expressions::ConstraintExpr, is_last: bool) {
        self._head("ConstraintExpr", is_last)
        self.p.put(" ")
        self.p.paint(Color::Keyword, self.tok(e->op_token))
        self._inline_type(e->rhs)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->lhs, true)
        self.p.leave()
    }

    fn _dx_assign(self, e: unsafe *Expressions::AssignOperatorExpr, is_last: bool) {
        self._head("AssignOperatorExpr", is_last)
        self.p.put(" ")
        self.p.paint(Color::Operator, self.tok(e->op_token))
        self._instance(e->op_instance)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->lhs, false)
        self._child_expr(e->rhs, true)
        self.p.leave()
    }

    fn _dx_string_literal(self, e: unsafe *StringLiteralExpr, is_last: bool) {
        self._head("StringLiteralExpr", is_last)
        self._inline_expr(e)
        // The suffix is a separate token, not part of the literal's own
        // spelling; without it `"hi"_len` dumped as a plain string though Sema
        // makes it a literal-operator call. It belongs to the whole joined
        // chain, on whichever segment it is written (`"12" "3"_km` is
        // `"123"_km`), so it prints once, from the first segment that has it.
        var unsafe *seg = e->imm
        while seg != &null {
            if seg->suffix.range.is_valid() {
                var sfx = e->ctx->get_spelling(seg->suffix.range)
                self._dim(f"suffix {sfx}")
                break
            }

            seg = e->next_segment(seg)
        }

        self.p.newline()

        // If there are no interpolated holes, we are done
        if e->parts.is_empty() {
            return
        }

        // Otherwise, walk the holes (the 'parts' expressions)
        self.p.enter(is_last)
        for var i: usize = 0; i < e->parts.size(); ++i {
            var is_final_part = i == e->parts.size() - 1
            self._child_expr(e->parts[i], is_final_part)
        }

        self.p.leave()
    }

    fn _dx_expr_seq(self, const kind: string, xs: FrozenList<unsafe *Expr>, is_last: bool) {
        self._head(kind, is_last)
        self._dim(f"({xs.size()})")
        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < xs.size(); ++i {
            self._child_expr(xs[i], i == xs.size() - 1)
        }

        self.p.leave()
    }

    /// A list literal, with the storage X chose for a slice-typed one: an
    /// Extended backing array is a declaration this dump would not otherwise
    /// show, because ListLiteralLowering mints it later.
    fn _dx_list_literal(self, e: unsafe *Expressions::ListLiteralExpr, is_last: bool) {
        self._head("ListLiteralExpr", is_last)
        self._dim(f"({e->elements.size()})")
        if e->storage == Expressions::ListStorage::Extended {
            self._dim(" [extended]")
        }

        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < e->elements.size(); ++i {
            self._child_expr(e->elements[i], i == e->elements.size() - 1)
        }

        self.p.leave()
    }

    fn _dx_map(self, e: unsafe *Expressions::MapLiteralExpr, is_last: bool) {
        self._head("MapLiteralExpr", is_last)
        self._dim(f"({e->entries.size()} entries)")
        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < e->entries.size(); ++i {
            var unsafe *en  = e->entries.get(i)
            var        last = i == e->entries.size() - 1
            self._head("Entry", last)
            self.p.newline()
            self.p.enter(last)
            self._child_expr(en->key, false)
            self._child_expr(en->value, true)
            self.p.leave()
        }

        self.p.leave()
    }

    fn _dx_named_init(self, e: unsafe *Expressions::NamedInitializerExpr, is_last: bool) {
        self._head("NamedInitializerExpr", is_last)
        // The dotted form has no head expression: its name is on the row.
        if e->is_dotted {
            self.p.put(" .")
            self.p.paint(Color::Ident, self.tok(e->dotted_name))
        }

        self.p.newline()
        self.p.enter(is_last)
        var has_fields = !e->fields.is_empty()
        if !e->is_dotted {
            self._child_expr(e->type_expr, !has_fields)
        }

        for var i: usize = 0; i < e->fields.size(); ++i {
            var unsafe *fld = e->fields.get(i)
            var        last = i == e->fields.size() - 1
            self._head("Field", last)
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(fld->name))
            self.p.newline()
            self.p.enter(last)
            self._child_expr(fld->value, true)
            self.p.leave()
        }

        self.p.leave()
    }

    /// `VariantInitExpr Enum::Variant fields=N`, then the fields in
    /// declaration order.
    fn _dx_variant_init(self, e: unsafe *Expressions::VariantInitExpr, is_last: bool) {
        var unsafe *en = cast<Declarations::EnumDecl>(e->en)
        var unsafe *v  = en->variants[e->variant as usize]
        self._head("VariantInitExpr", is_last)
        self.p.put(" ")
        self.p.paint(Color::Ident, self.tok(en->name) + "::" + self.tok(v->name))
        self.p.put(f" fields={e->fields.size()}")
        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < e->fields.size(); ++i {
            self._child_expr(e->fields[i], i + 1 == e->fields.size())
        }

        self.p.leave()
    }

    fn _dx_anon_init(self, e: unsafe *Expressions::AnonInitializerExpr, is_last: bool) {
        self._head("AnonInitializerExpr", is_last)
        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < e->fields.size(); ++i {
            var unsafe *fld = e->fields.get(i)
            var        last = i == e->fields.size() - 1
            self._head("Field", last)
            self.p.put(" .")
            self.p.paint(Color::Ident, self.tok(fld->name))
            self.p.newline()
            self.p.enter(last)
            self._child_expr(fld->value, true)
            self.p.leave()
        }

        self.p.leave()
    }

    fn _dx_if(self, e: unsafe *Expressions::IfExpr, is_last: bool) {
        self._head("IfExpr", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._head("cond", false)
        self.p.newline()
        self.p.enter(false)
        self._child_expr(e->condition, true)
        self.p.leave()
        var no_tail = e->else_ifs.is_empty() && e->else_expr == &null
        self._head("then", no_tail)
        self.p.newline()
        self.p.enter(false)
        self._child_expr(e->then_expr, true)
        self.p.leave()
        for var i: usize = 0; i < e->else_ifs.size(); ++i {
            var unsafe *arm = e->else_ifs.get(i)
            self._head("else-if", false)
            self.p.newline()
            self.p.enter(false)
            self._child_expr(arm->condition, false)
            self._child_expr(arm->body, true)
            self.p.leave()
        }

        if e->else_expr != &null {
            self._head("else", true)
            self.p.newline()
            self.p.enter(true)
            self._child_expr(e->else_expr, true)
            self.p.leave()
        }

        self.p.leave()
    }

    fn _dx_try(self, e: unsafe *Expressions::TryCatchExpr, is_last: bool) {
        self._head("TryCatchExpr", is_last)
        self._dim(f"({e->catch_arms.size()} arms)")
        self.p.newline()
        self.p.enter(is_last)
        var has_arms = !e->catch_arms.is_empty()
        self._child_expr(e->try_expr, !has_arms)
        for var i: usize = 0; i < e->catch_arms.size(); ++i {
            var unsafe *arm = e->catch_arms.get(i)
            var        last = i == e->catch_arms.size() - 1
            self._head("catch", last)
            if arm->has_binding && arm->binding != &null {
                self.p.put(" ")
                if arm->is_const {
                    self.p.paint(Color::Keyword, "const ")
                }

                self.p.paint(Color::Ident, self.tok(arm->binding->name))
            }

            if arm->filter != &null {
                self._inline_type(arm->filter)
            }

            self.p.newline()
            self.p.enter(last)
            self._child_expr(arm->body, true)
            self.p.leave()
        }

        self.p.leave()
    }

    fn _dx_match(self, e: unsafe *Expressions::MatchExpr, is_last: bool) {
        self._head("MatchExpr", is_last)
        self._dim(f"({e->cases.size()} cases)")
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->scrutinee, e->cases.is_empty())
        for var i: usize = 0; i < e->cases.size(); ++i {
            self._dump_match_case(e->cases.get(i), i == e->cases.size() - 1)
        }

        self.p.leave()
    }

    /// Shared match-case row for expr- and stmt-form match.
    fn _dump_match_case(self, mc: unsafe *Statements::MatchCase, is_last: bool) {
        if mc->is_default {
            self._head("default", is_last)
        } else {
            self._head("case", is_last)
            self.p.put(" ")
            for var i: usize = 0; i < mc->patterns.size(); ++i {
                if i > 0 {
                    self.p.paint(Color::Punct, ", ")
                }

                self.src_pattern(mc->patterns[i])
            }

            if mc->guard != &null {
                self.p.paint(Color::Keyword, " where ")
                self.src_expr(mc->guard)
            }
        }

        self.p.newline()
        self.p.enter(is_last)
        if mc->expression != &null {
            self._child_expr(mc->expression, true)
        } else if mc->body != &null {
            self._child_stmt(mc->body, true)
        }

        self.p.leave()
    }

    fn _dx_range(self, e: unsafe *Expressions::RangeExpr, is_last: bool) {
        self._head("RangeExpr", is_last)
        self.p.put(" ")
        self.p.paint(Color::Operator, (if (e->is_inclusive) => ("..=") else => ".."))
        self.p.newline()
        self.p.enter(is_last)
        if e->begin != &null {
            self._child_expr(e->begin, e->end == &null)
        }

        if e->end != &null {
            self._child_expr(e->end, true)
        }

        self.p.leave()
    }

    /// \brief Renders the structure hierarchy of ClosureExpr nodes for tree dumps.
    fn _dx_closure(self, e: unsafe *Expressions::ClosureExpr, is_last: bool) {
        self._head("ClosureExpr", is_last)
        if ((e->modifiers as u16) & (Declarations::FnModifier::IsPanic as u16)) != 0 {
            self._panic_spec(e->panic_set)
        }

        if e->return_type != &null {
            self.p.put(" -> ")
            self._inline_type(e->return_type)
        }

        self.p.newline()

        self.p.enter(is_last)

        var has_generics = !e->generic_params.is_empty()
        var has_params   = !e->params.is_empty()
        var has_captures = !e->captures.is_empty()
        var has_body = e->body_kind == Declarations::FnBodyKind::Block && e->body_block != &null
            || e->body_kind == Declarations::FnBodyKind::Expr && e->body_expr != &null
        var explicit_no_capture = e->explicit_no_capture

        if has_generics {
            for var i: usize = 0; i < e->generic_params.size(); ++i {
                var last_gen = i == e->generic_params.size() - 1
                    && !has_params
                    && !has_captures
                    && !has_body
                self._child_decl(unsafe (e->generic_params[i] as unsafe *Decl), last_gen)
            }
        }

        if has_params {
            for var i: usize = 0; i < e->params.size(); ++i {
                var last_param = i == e->params.size() - 1 && !has_captures && !has_body
                self._child_decl(unsafe (e->params[i] as unsafe *Decl), last_param)
            }
        }

        if explicit_no_capture {
            self._head("CaptureList (explicit no capture)", is_last)
            self.p.newline()
        }

        if has_captures {
            for var i: usize = 0; i < e->captures.size(); ++i {
                var unsafe *cap     = e->captures.get(i)
                var        last_cap = i == e->captures.size() - 1 && !has_body
                self._head("Capture", last_cap)
                self.p.put(" ")
                if cap->is_const {
                    self.p.paint(Color::Keyword, "const ")
                }

                if cap->by_ptr {
                    self.p.paint(Color::Punct, "*")
                }

                if cap->name != &null {
                    self.p.paint(Color::Ident, self.tok(cap->name->name))
                }

                self.p.newline()
            }
        }

        if e->body_kind == Declarations::FnBodyKind::Block && e->body_block != &null {
            self._child_stmt(e->body_block, true)
        } else if e->body_kind == Declarations::FnBodyKind::Expr && e->body_expr != &null {
            self._child_expr(e->body_expr, true)
        }

        self.p.leave()
    }

    fn _dx_cast(self, e: unsafe *Expressions::TypeCastExpr, is_last: bool) {
        self._head("TypeCastExpr", is_last)
        if e->is_unsafe {
            self.p.put(" ")
            self.p.paint(Color::Keyword, "unsafe")
        }

        self.p.put(" -> ")
        self.src_type(e->target)
        // The decl itself belongs to --print-sema; here it is only worth
        // saying that the cast is a construction, not a conversion.
        if e->resolved_ctor != &null {
            self._dim(" [ctor]")
        }

        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->operand, true)
        self.p.leave()
    }

    fn _dx_boundary(self, e: unsafe *Expressions::ImplicitBoundaryCastExpr, is_last: bool) {
        self._head("ImplicitBoundaryCastExpr", is_last)
        self.p.put(" ")
        self.src_type(e->source_type)
        self.p.put(" -> ")
        self.src_type(e->target_type)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e->original, true)
        self.p.leave()
    }

    fn _dx_kw(self, const kind: string, operand: unsafe *Expr, is_last: bool) {
        self._head(kind, is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(operand, true)
        self.p.leave()
    }

    /// `AttributedExpr @name (N args)`: the arguments, then the operand.
    fn _dx_attributed(self, e: unsafe *Expressions::AttributedExpr, is_last: bool) {
        self._head("AttributedExpr", is_last)
        self.p.put(" ")
        self.p.paint(Color::Keyword, "@" + self.tok(e->name))
        if e->has_args {
            self._dim(f"({e->args.size()} args)")
        }

        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < e->args.size(); ++i {
            self._child_expr(e->args[i], false)
        }

        self._child_expr(e->operand, true)
        self.p.leave()
    }

    /// `PanicOpExpr <op>`, then the slot and the operand it has.
    fn _dx_panic_op(self, e: unsafe *Expressions::PanicOpExpr, is_last: bool) {
        self._head("PanicOpExpr", is_last)
        self.p.put(" " + Expressions::panic_op_name(e->which))
        self.p.newline()
        self.p.enter(is_last)
        if e->slot != &null {
            self._child_expr(e->slot, e->operand == &null)
        }

        if e->operand != &null {
            self._child_expr(e->operand, true)
        }

        self.p.leave()
    }

    /// One child, and it is a block: the value is its last statement.
    fn _dx_stmt_expr(self, n: unsafe *Expressions::StmtExpr, is_last: bool) {
        self._head(if (n->is_jump) => ("StmtExpr (jump)") else => "StmtExpr", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_stmt(n->body, true)
        self.p.leave()
    }

    fn _dx_two_types(self, const kind: string, a: unsafe *Type, b: unsafe *Type, is_last: bool) {
        self._head(kind, is_last)
        self.p.put(" ")
        self.src_type(a)
        self.p.put(" / ")
        self.src_type(b)
        self.p.newline()
    }

    //  PATTERN dump row

    fn dump_pattern_row(self, pat: unsafe *Pattern, is_last: bool) {
        if pat == &null {
            self._head("<null-pat>", is_last)
            self.p.newline()
            return
        }

        if pat->is_error() {
            self._head("RecoveryPattern", is_last)
            self._dim(self._recovery_name(self._pattern_kind_name_of(pat->recovery_kind)))
            self.p.newline()
            return
        }

        self._head(self._pattern_kind_name(pat), is_last)
        self.p.put(" '")
        self.src_pattern(pat)
        self.p.put("'")
        self.p.newline()
    }

    //  STMT dump row

    fn dump_stmt_row(self, stmt: unsafe *Stmt, is_last: bool) {
        if stmt == &null {
            self._head("<null-stmt>", is_last)
            self.p.newline()
            return
        }

        if stmt->is_error() {
            self._head("RecoveryStmt", is_last)
            self._dim(self._recovery_name(self._stmt_kind_name_of(stmt->recovery_kind)))
            self.p.newline()
            return
        }

        if isa<Statements::CompoundStmt>(stmt) {
            self._ds_compound(cast<Statements::CompoundStmt>(stmt), is_last)
            return
        }

        if isa<Statements::ExpressionStmt>(stmt) {
            self._ds_one_expr(
                "ExpressionStmt",
                cast<Statements::ExpressionStmt>(stmt)->expr,
                is_last,
            )

            return
        }

        if isa<Statements::DeclStmt>(stmt) {
            self._ds_decl(cast<Statements::DeclStmt>(stmt), is_last)
            return
        }

        if isa<Statements::ReturnStmt>(stmt) {
            self._ds_return(cast<Statements::ReturnStmt>(stmt), is_last)
            return
        }

        if isa<Statements::BreakStmt>(stmt) {
            self._ds_break(cast<Statements::BreakStmt>(stmt), is_last)
            return
        }

        if isa<Statements::ContinueStmt>(stmt) {
            self._ds_continue(cast<Statements::ContinueStmt>(stmt), is_last)
            return
        }

        if isa<Statements::PanicStmt>(stmt) {
            self._ds_one_expr("PanicStmt", cast<Statements::PanicStmt>(stmt)->payload, is_last)
            return
        }

        if isa<Statements::YieldStmt>(stmt) {
            self._ds_one_expr("YieldStmt", cast<Statements::YieldStmt>(stmt)->value, is_last)
            return
        }

        if isa<Statements::RuntimeAssertStmt>(stmt) {
            self._ds_assert(
                "RuntimeAssertStmt",
                cast<Statements::RuntimeAssertStmt>(stmt)->condition,
                cast<Statements::RuntimeAssertStmt>(stmt)->message,
                is_last,
            )

            return
        }

        if isa<Statements::StaticAssertStmt>(stmt) {
            self._ds_assert(
                "StaticAssertStmt",
                cast<Statements::StaticAssertStmt>(stmt)->condition,
                cast<Statements::StaticAssertStmt>(stmt)->message,
                is_last,
            )

            return
        }

        if isa<Statements::LabelIntrinsicStmt>(stmt) {
            self._head("LabelIntrinsicStmt", is_last)
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(cast<Statements::LabelIntrinsicStmt>(stmt)->name))
            self.p.newline()
            return
        }

        if isa<Statements::JumpIntrinsicStmt>(stmt) {
            self._head("JumpIntrinsicStmt", is_last)
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(cast<Statements::JumpIntrinsicStmt>(stmt)->target))
            self.p.newline()
            return
        }

        if isa<Statements::ConditionalStmt>(stmt) {
            self._ds_conditional(cast<Statements::ConditionalStmt>(stmt), is_last)
            return
        }

        if isa<Statements::WhileLoopStmt>(stmt) {
            self._ds_while(cast<Statements::WhileLoopStmt>(stmt), is_last)
            return
        }

        if isa<Statements::LoopStmt>(stmt) {
            self._ds_loop(cast<Statements::LoopStmt>(stmt), is_last)
            return
        }

        if isa<Statements::RangedForStmt>(stmt) {
            self._ds_ranged_for(cast<Statements::RangedForStmt>(stmt), is_last)
            return
        }

        if isa<Statements::IndexedForStmt>(stmt) {
            self._ds_indexed_for(cast<Statements::IndexedForStmt>(stmt), is_last)
            return
        }

        if isa<Statements::MatchStmt>(stmt) {
            self._ds_match(cast<Statements::MatchStmt>(stmt), is_last)
            return
        }

        if isa<Statements::LabeledStmt>(stmt) {
            self._ds_labeled(cast<Statements::LabeledStmt>(stmt), is_last)
            return
        }

        if isa<Statements::TryCatchStmt>(stmt) {
            self._ds_try(cast<Statements::TryCatchStmt>(stmt), is_last)
            return
        }

        if isa<Statements::FinallyStmt>(stmt) {
            self._ds_block_stmt("FinallyStmt", cast<Statements::FinallyStmt>(stmt)->body, is_last)
            return
        }

        if isa<Statements::UnsafeBlockStmt>(stmt) {
            self._ds_block_stmt(
                "UnsafeBlockStmt",
                cast<Statements::UnsafeBlockStmt>(stmt)->body,
                is_last,
            )

            return
        }

        if isa<Statements::ContextBindingStmt>(stmt) {
            self._ds_context(cast<Statements::ContextBindingStmt>(stmt), is_last)
            return
        }

        if isa<Statements::DestructuringDeclStmt>(stmt) {
            self._ds_destructure(cast<Statements::DestructuringDeclStmt>(stmt), is_last)
            return
        }

        if isa<Statements::InlineBlockStmt>(stmt) {
            self._head("InlineBlockStmt", is_last)
            self._dim(f"({self._inline_lang(cast<Statements::InlineBlockStmt>(stmt)->lang)})")
            self.p.newline()
            return
        }

        if isa<Statements::EvalBlockStmt>(stmt) {
            self._ds_eval_block(cast<Statements::EvalBlockStmt>(stmt), is_last)
            return
        }

        if isa<Statements::SwitchDispatchStmt>(stmt) {
            self._ds_switch_dispatch(cast<Statements::SwitchDispatchStmt>(stmt), is_last)
            return
        }

        self._head("<unknown-stmt>", is_last)
        self.p.newline()
    }

    fn _ds_compound(self, stmt: unsafe *Statements::CompoundStmt, is_last: bool) {
        self._head("CompoundStmt", is_last)
        self._dim(f"({stmt->body.size()})")
        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < stmt->body.size(); ++i {
            self._child_stmt(stmt->body[i], i == stmt->body.size() - 1)
        }

        self.p.leave()
    }

    fn _ds_decl(self, stmt: unsafe *Statements::DeclStmt, is_last: bool) {
        self._head("DeclStmt", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_decl(stmt->decl, true)
        self.p.leave()
    }

    fn _ds_return(self, stmt: unsafe *Statements::ReturnStmt, is_last: bool) {
        self._head("ReturnStmt", is_last)
        self.p.newline()
        if stmt->value != &null {
            self.p.enter(is_last)
            self._child_expr(stmt->value, true)
            self.p.leave()
        }
    }

    fn _ds_break(self, stmt: unsafe *Statements::BreakStmt, is_last: bool) {
        self._head("BreakStmt", is_last)
        if stmt->has_label {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(stmt->label))
        }

        self.p.newline()
    }

    fn _ds_continue(self, stmt: unsafe *Statements::ContinueStmt, is_last: bool) {
        self._head("ContinueStmt", is_last)
        if stmt->has_label {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(stmt->label))
        }

        self.p.newline()
    }

    fn _ds_assert(self, const kind: string, cond: unsafe *Expr, msg: unsafe *Expr, is_last: bool) {
        self._head(kind, is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(cond, msg == &null)
        if msg != &null {
            self._child_expr(msg, true)
        }

        self.p.leave()
    }

    /// `cases=<n> default=<label | policy>`; children are the value, each
    /// case's lo then hi, then the policy statement when there is one.
    fn _ds_switch_dispatch(self, stmt: unsafe *Statements::SwitchDispatchStmt, is_last: bool) {
        self._head("SwitchDispatchStmt", is_last)
        var dflt = "policy"
        if stmt->default_stmt == &null {
            dflt = self.tok(stmt->default_target)
        }

        self._dim(f"cases={stmt->cases.size()} default={dflt}")
        self.p.newline()
        self.p.enter(is_last)
        var has_dflt = stmt->default_stmt != &null
        var n_cases  = stmt->cases.size()
        self._child_expr(stmt->value, n_cases == 0 && !has_dflt)
        for var i: usize = 0; i < n_cases; ++i {
            var unsafe *c   = stmt->cases.get(i)
            var        tail = i == n_cases - 1 && !has_dflt
            self._child_expr(c->lo, tail && c->hi == &null)
            if c->hi != &null {
                self._child_expr(c->hi, tail)
            }
        }

        if has_dflt {
            self._child_stmt(stmt->default_stmt, true)
        }

        self.p.leave()
    }

    fn _ds_conditional(self, stmt: unsafe *Statements::ConditionalStmt, is_last: bool) {
        self._head("ConditionalStmt", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._head("cond", false)
        self.p.newline()
        self.p.enter(false)
        self._child_expr(stmt->cond, true)
        self.p.leave()
        var has_else = stmt->else_ != &null
        self._head("then", !has_else)
        self.p.newline()
        self.p.enter(!has_else)
        self._child_stmt(stmt->then_, true)
        self.p.leave()
        if has_else {
            self._head("else", true)
            self.p.newline()
            self.p.enter(true)
            self._child_stmt(stmt->else_, true)
            self.p.leave()
        }

        self.p.leave()
    }

    fn _ds_while(self, stmt: unsafe *Statements::WhileLoopStmt, is_last: bool) {
        self._head("WhileLoopStmt", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(stmt->cond, false)
        self._child_stmt(unsafe (stmt->body as unsafe *Stmt), true)
        self.p.leave()
    }

    fn _ds_loop(self, stmt: unsafe *Statements::LoopStmt, is_last: bool) {
        self._head("LoopStmt", is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_stmt(unsafe (stmt->body as unsafe *Stmt), true)
        self.p.leave()
    }

    fn _ds_ranged_for(self, stmt: unsafe *Statements::RangedForStmt, is_last: bool) {
        self._head("RangedForStmt", is_last)
        if stmt->is_eval {
            self._dim("eval")
        }

        self.p.put(" ")
        self._src_binding_list(stmt->bindings)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(stmt->iterable, false)
        self._child_stmt(stmt->body, true)
        self.p.leave()
    }

    fn _ds_indexed_for(self, stmt: unsafe *Statements::IndexedForStmt, is_last: bool) {
        self._head("IndexedForStmt", is_last)
        if stmt->is_eval {
            self._dim("eval")
        }

        self.p.newline()
        self.p.enter(is_last)
        if stmt->init != &null { // `for ; c; s`
            self._child_stmt(stmt->init, false)
        }

        self._child_expr(stmt->cond, false)
        self._child_expr(stmt->update, false)
        self._child_stmt(stmt->body, true)
        self.p.leave()
    }

    fn _ds_match(self, stmt: unsafe *Statements::MatchStmt, is_last: bool) {
        self._head("MatchStmt", is_last)
        self._dim(f"({stmt->cases.size()} cases)")
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(stmt->scrutinee, stmt->cases.is_empty())
        for var i: usize = 0; i < stmt->cases.size(); ++i {
            self._dump_match_case(stmt->cases.get(i), i == stmt->cases.size() - 1)
        }

        self.p.leave()
    }

    fn _ds_labeled(self, stmt: unsafe *Statements::LabeledStmt, is_last: bool) {
        self._head("LabeledStmt", is_last)
        self.p.put(" ")
        self.p.paint(Color::Ident, self.tok(stmt->label))
        self.p.newline()
        self.p.enter(is_last)
        self._child_stmt(stmt->inner, true)
        self.p.leave()
    }

    fn _ds_try(self, stmt: unsafe *Statements::TryCatchStmt, is_last: bool) {
        self._head("TryCatchStmt", is_last)
        self._dim(f"({stmt->arms.size()} arms)")
        self.p.newline()
        self.p.enter(is_last)
        self._child_stmt(stmt->try_body, stmt->arms.is_empty())
        for var i: usize = 0; i < stmt->arms.size(); ++i {
            var unsafe *arm = stmt->arms.get(i)
            var        last = i == stmt->arms.size() - 1
            self._head("catch", last)
            if arm->binding != &null {
                self.p.put(" ")
                self.p.paint(Color::Ident, self.tok(arm->binding->name))
            }

            if arm->filter != &null {
                self._inline_type(arm->filter)
            }

            self.p.newline()
            self.p.enter(last)
            self._child_stmt(arm->body, true)
            self.p.leave()
        }

        self.p.leave()
    }

    fn _ds_block_stmt(self,
                      const kind: string,
                      body:       unsafe *Statements::CompoundStmt,
                      is_last:    bool) {
        self._head(kind, is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_stmt(body, true)
        self.p.leave()
    }

    fn _ds_context(self, stmt: unsafe *Statements::ContextBindingStmt, is_last: bool) {
        self._head("ContextBindingStmt", is_last)
        self.p.put(" as ")
        self._src_binding_list(stmt->bindings)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(stmt->value, false)
        self._child_stmt(unsafe (stmt->body as unsafe *Stmt), true)
        self.p.leave()
    }

    fn _ds_destructure(self, stmt: unsafe *Statements::DestructuringDeclStmt, is_last: bool) {
        self._head("DestructuringDeclStmt", is_last)
        self.p.put(" ")
        self.p.paint(Color::Dim, (if (stmt->kind_ == Statements::DestructureKind::Tuple) => ("tuple ") else => "struct "))
        self.p.paint(Color::Keyword, (if (stmt->leading_is_const) => ("const") else => "var"))
        self.p.put(" ")
        var is_tuple = stmt->kind_ == Statements::DestructureKind::Tuple
        self.p.paint(Color::Punct, (if (is_tuple) => ("(") else => "{"))
        self._src_binding_list(stmt->bindings)
        self.p.paint(Color::Punct, (if (is_tuple) => (")") else => "}"))
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(stmt->value, true)
        self.p.leave()
    }

    fn _ds_eval_block(self, stmt: unsafe *Statements::EvalBlockStmt, is_last: bool) {
        self._head("EvalBlockStmt", is_last)
        self._dim(f"({stmt->body.size()} decls)")
        self.p.newline()
        self.p.enter(is_last)
        for var i: usize = 0; i < stmt->body.size(); ++i {
            self._child_decl(stmt->body[i], i == stmt->body.size() - 1)
        }

        self.p.leave()
    }

    fn _ds_one_expr(self, const kind: string, e: unsafe *Expr, is_last: bool) {
        self._head(kind, is_last)
        self.p.newline()
        self.p.enter(is_last)
        self._child_expr(e, true)
        self.p.leave()
    }

    //  DECL dump row
    //
    //  Every aggregate walks dc_decls (DeclContext) the COMPLETE
    //  source-ordered member list  instead of the fields/methods/variants
    //  projection caches that drop nested types and VisibilityGroupDecl.
    //  Every decl row also renders written visibility + annotation child rows.

    fn dump_decl_row(self, decl: unsafe *Decl, is_last: bool) {
        if decl == &null {
            self._head("<null-decl>", is_last)
            self.p.newline()
            return
        }

        if decl->is_error() {
            self._head("RecoveryDecl", is_last)
            self._dim(self._recovery_name(self._decl_kind_name_of(decl->recovery_kind)))
            self.p.newline()
            return
        }

        if isa<Declarations::FunctionDecl>(decl) {
            self._dd_function(cast<Declarations::FunctionDecl>(decl), is_last)
            return
        }

        if isa<Declarations::VariableDecl>(decl) {
            self._dd_variable(cast<Declarations::VariableDecl>(decl), is_last)
            return
        }

        if isa<Declarations::FieldDecl>(decl) {
            self._dd_field(cast<Declarations::FieldDecl>(decl), is_last)
            return
        }

        if isa<Declarations::ParamDecl>(decl) {
            self._dd_param(cast<Declarations::ParamDecl>(decl), is_last)
            return
        }

        if isa<Declarations::GenericParamDecl>(decl) {
            self._dd_leaf_src("GenericParamDecl", decl, is_last)
            return
        }

        if isa<Declarations::StructDecl>(decl) {
            self._dd_struct(cast<Declarations::StructDecl>(decl), is_last)
            return
        }

        if isa<Declarations::ClassDecl>(decl) {
            self._dd_class(cast<Declarations::ClassDecl>(decl), is_last)
            return
        }

        if isa<Declarations::InterfaceDecl>(decl) {
            self._dd_interface(cast<Declarations::InterfaceDecl>(decl), is_last)
            return
        }

        if isa<Declarations::ExtensionDecl>(decl) {
            self._dd_extension(cast<Declarations::ExtensionDecl>(decl), is_last)
            return
        }

        if isa<Declarations::EnumDecl>(decl) {
            self._dd_enum(cast<Declarations::EnumDecl>(decl), is_last)
            return
        }

        if isa<Declarations::EnumVariantDecl>(decl) {
            self._dd_enum_variant(cast<Declarations::EnumVariantDecl>(decl), is_last)
            return
        }

        if isa<Declarations::UnionDecl>(decl) {
            self._dd_union(cast<Declarations::UnionDecl>(decl), is_last)
            return
        }

        if isa<Declarations::TypeAliasDecl>(decl) {
            self._dd_type_alias(cast<Declarations::TypeAliasDecl>(decl), is_last)
            return
        }

        if isa<Declarations::ModuleDecl>(decl) {
            self._dd_module(cast<Declarations::ModuleDecl>(decl), is_last)
            return
        }

        if isa<Declarations::ImportDecl>(decl) {
            self._dd_leaf_src("ImportDecl", decl, is_last)
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(decl) {
            self._dd_vis_group(cast<Declarations::VisibilityGroupDecl>(decl), is_last)
            return
        }

        if isa<Declarations::EvalBlockDecl>(decl) {
            self._dd_eval_block(cast<Declarations::EvalBlockDecl>(decl), is_last)
            return
        }

        if isa<Declarations::TestDecl>(decl) {
            self._dd_test(cast<Declarations::TestDecl>(decl), is_last)
            return
        }

        if isa<Declarations::MacroDecl>(decl) {
            self._dd_leaf_src("MacroDecl", decl, is_last)
            return
        }

        if isa<Declarations::ProcedureMacroDecl>(decl) {
            self._dd_proc_macro(cast<Declarations::ProcedureMacroDecl>(decl), is_last)
            return
        }

        if isa<Declarations::FFIBlockDecl>(decl) {
            self._dd_ffi_block(cast<Declarations::FFIBlockDecl>(decl), is_last)
            return
        }

        self._head("<unknown-decl>", is_last)
        self.p.newline()
    }

    /// Decl whose whole content reads fine on one line: tag + visibility +
    /// source form. Attributes (if any) still get their own child rows.
    fn _dd_leaf_src(self, const kind: string, decl: unsafe *Decl, is_last: bool) {
        self._head(kind, is_last)
        self._dump_vis(decl)
        self._dump_ffi_linkage(decl)
        self.p.put(" '")
        self.src_decl(decl)
        self.p.put("'")
        self.p.newline()
        if self._has_annotations(decl) {
            self.p.enter(is_last)
            self._dump_annotations(decl, true)
            self.p.leave()
        }
    }

    /// Open the decl's child scope and emit annotation rows first. Returns
    /// nothing; caller has already called enter(). Use when a decl has BOTH
    /// annotations and structural children: annotations are never last.
    fn _emit_annotations_if_any(self, decl: unsafe *Decl, has_struct_children: bool) {
        if self._has_annotations(decl) {
            // attrs are last only when there are no structural children.
            self._dump_annotations(decl, !has_struct_children)
        }
    }

    fn _dd_function(self, fd: unsafe *Declarations::FunctionDecl, is_last: bool) {
        self._head("FunctionDecl", is_last)
        self._dump_vis(unsafe (fd as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (fd as unsafe *Decl))
        self.p.put(" ")
        self._generic_params(fd->generic_params)
        self.p.put(" ")
        if fd->is_operator {
            self.p.put("op ")
            if fd->op_token.is_empty() {
                self.p.put(" ")
                return
            }

            for var i: usize = 0; i < fd->op_token.size(); ++i {
                self.p.paint(Color::Operator, self.tok(fd->op_token[i]))
            }

            self.p.put(" ")
        } else {
            self.p.paint(Color::Ident, self.tok(fd->name))
        }

        self._dd_spec(fd->spec_kind, fd->spec_args) // specialization tag + pattern (#68)
        // signature (params + return) inline; full declarations explode as children.
        self._param_list(fd->params)
        if fd->is_panic() {
            self._panic_spec(fd->panic_set)
        }

        if fd->is_noreturn {
            self.p.paint(Color::Punct, " -> ")
            self.p.paint(Color::Operator, "!")
        } else if fd->return_type != &null {
            self.p.paint(Color::Punct, " -> ")
            self.src_type(fd->return_type)
        }

        // a bodyless `virtual fn` (or an imported `= 0`) has no body to show
        if fd->body_kind == Declarations::FnBodyKind::Virtual {
            self.p.paint(Color::Keyword, " pure")
        }

        // The guard is a child row like the requires clause, and nothing on
        // that row says which of the two it is; the head does.
        if fd->where_clause != &null {
            self.p.paint(Color::Keyword, " where")
        }

        self.p.newline()

        var has_attrs    = self._has_annotations(unsafe (fd as unsafe *Decl))
        var has_generics = !fd->generic_params.is_empty()
        var has_params   = !fd->params.is_empty()
        var has_requires = fd->requires_clause != &null
        var has_where    = fd->where_clause != &null
        var has_body = fd->body_kind == Declarations::FnBodyKind::Block && fd->body_block != &null
            || fd->body_kind == Declarations::FnBodyKind::Expr && fd->body_expr != &null

        if !has_attrs && !has_generics && !has_params && !has_requires && !has_where && !has_body {
            return
        }

        self.p.enter(is_last)

        if has_attrs {
            self._dump_annotations(
                unsafe (fd as unsafe *Decl),
                !(has_generics || has_params || has_requires || has_where || has_body),
            )
        }

        if has_generics {
            for var i: usize = 0; i < fd->generic_params.size(); ++i {
                var last_gen = i == fd->generic_params.size() - 1
                    && !has_params
                    && !has_requires
                    && !has_where
                    && !has_body
                self._child_decl(fd->generic_params[i], last_gen)
            }
        }

        if has_params {
            for var i: usize = 0; i < fd->params.size(); ++i {
                var last_param = i == fd->params.size() - 1
                    && !has_requires
                    && !has_where
                    && !has_body
                self._child_decl(fd->params[i], last_param)
            }
        }

        if has_requires {
            self._child_expr(fd->requires_clause, !has_where && !has_body)
        }

        if has_where {
            self._child_expr(fd->where_clause, !has_body)
        }

        if fd->body_kind == Declarations::FnBodyKind::Block && fd->body_block != &null {
            self._child_stmt(fd->body_block, true)
        } else if fd->body_kind == Declarations::FnBodyKind::Expr && fd->body_expr != &null {
            self._child_expr(fd->body_expr, true)
        }

        self.p.leave()
    }

    fn _dd_variable(self, vd: unsafe *Declarations::VariableDecl, is_last: bool) {
        self._head("VariableDecl", is_last)
        self._dump_vis(unsafe (vd as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (vd as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(
            Color::Keyword,
            self._binding_kw(vd->storage, vd->is_thread, vd->const_binding),
        )

        self.p.put(" ")
        if vd->pointer_unsafe {
            self.p.paint(Color::Keyword, "unsafe ")
        }

        for var i: u32 = 0; i < vd->pointer_depth; ++i {
            self.p.paint(Color::Punct, "*")
        }

        self.p.paint(Color::Ident, self.tok(vd->name))
        if vd->nullable_shorthand {
            self.p.paint(Color::Punct, "?")
        }

        // a generic-bearing type becomes its own child subtree; a leaf type
        // stays inline on this row.
        var ty_child = vd->type_ != &null && self._type_is_expandable(vd->type_)
        if vd->type_ != &null && !ty_child {
            self.p.paint(Color::Punct, ": ")
            self.src_type(vd->type_)
        }

        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (vd as unsafe *Decl))
        var has_init  = vd->init != &null
        if !has_attrs && !ty_child && !has_init {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (vd as unsafe *Decl), !(ty_child || has_init))
        }

        if ty_child {
            self._child_type(vd->type_, !has_init)
        }

        if has_init {
            self._child_expr(vd->init, true)
        }

        self.p.leave()
    }

    fn _dd_field(self, fd: unsafe *Declarations::FieldDecl, is_last: bool) {
        self._head("FieldDecl", is_last)
        self._dump_vis(unsafe (fd as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (fd as unsafe *Decl))
        self.p.put(" ")
        if fd->is_mutable {
            self.p.paint(Color::Keyword, "mutable ")
        }

        self.p.paint(
            Color::Keyword,
            self._binding_kw(fd->storage, fd->is_thread, fd->const_binding),
        )

        self.p.put(" ")
        self.p.paint(Color::Ident, self.tok(fd->name))
        var ty_child = fd->type_ != &null && self._type_is_expandable(fd->type_)
        if fd->type_ != &null && !ty_child {
            self.p.paint(Color::Punct, ": ")
            self.src_type(fd->type_)
        }

        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (fd as unsafe *Decl))
        var has_init  = fd->init != &null
        if !has_attrs && !ty_child && !has_init {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (fd as unsafe *Decl), !(ty_child || has_init))
        }

        if ty_child {
            self._child_type(fd->type_, !has_init)
        }

        if has_init {
            self._child_expr(fd->init, true)
        }

        self.p.leave()
    }

    fn _dd_param(self, pd: unsafe *Declarations::ParamDecl, is_last: bool) {
        self._head("ParamDecl", is_last)
        self._dump_vis(unsafe (pd as unsafe *Decl))
        self.p.put(" ")
        self.src_decl(unsafe (pd as unsafe *Decl))
        self.p.newline()
        if self._has_annotations(unsafe (pd as unsafe *Decl)) {
            self.p.enter(is_last)
            self._dump_annotations(unsafe (pd as unsafe *Decl), true)
            self.p.leave()
        }
    }

    /// # aggregate dumps: walk dc_decls, not projection caches

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

    /// Collect every real member of a type body into `out`, in source order.
    /// fields + methods (flat lists, include grouped members with visibility
    /// stamped) + nested-type decls from dc_decls (skip VisibilityGroupDecl).
    fn _collect_type_members(self,
                             dc:      unsafe *DeclContext,
                             fields:  FrozenList<unsafe *Declarations::FieldDecl>,
                             methods: FrozenList<unsafe *Declarations::FunctionDecl>,
                             out:     unsafe *cxx::std::vector<unsafe *Decl>) {
        for var i: usize = 0; i < fields.size(); ++i {
            out->push_back(unsafe (fields[i] as unsafe *Decl))
        }

        for var i: usize = 0; i < methods.size(); ++i {
            out->push_back(unsafe (methods[i] as unsafe *Decl))
        }

        // dc_decls: nested types + VisibilityGroupDecl wrappers. Take the
        // nested types; skip the wrappers (their members are already above).
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            if isa<Declarations::VisibilityGroupDecl>(d) {
                continue
            }

            out->push_back(d)
        }

        self._sort_by_source(&*out)
    }

    /// Stable insertion sort on range.start (offset). Member counts in a type
    /// body are small; insertion sort keeps it simple and stable for equal
    /// positions (which shouldn't occur but we don't want a swap if they do).
    fn _sort_by_source(self, @inout xs: cxx::std::vector<unsafe *Decl>) {
        var n = xs.size()
        for var i: usize = 1; i < n; ++i {
            var unsafe *key    = (xs)[i]
            var        key_pos = key->range.start
            var        j       = i
            while j > 0 && (xs)[j - 1]->range.start > key_pos {
                (xs)[j] = (xs)[j - 1]
                j -= 1
            }

            (xs)[j] = key
        }
    }

    /// Emit annotation rows for the aggregate, then its members in source
    /// order. `members` is the pre-collected, pre-sorted list.
    fn _dump_members(self,
                     decl:          unsafe *Decl,
                     const members: cxx::std::vector<unsafe *Decl>,
                     is_last:       bool) {
        var has_attrs = self._has_annotations(decl)
        var n         = members.size()
        if !has_attrs && n == 0 {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(decl, n == 0)
        }

        for var i: usize = 0; i < n; ++i {
            self._child_decl((members)[i], i == n - 1)
        }

        self.p.leave()
    }

    fn _dd_struct(self, sd: unsafe *Declarations::StructDecl, is_last: bool) {
        self._head("StructDecl", is_last)
        self._dump_vis(unsafe (sd as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (sd as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(sd->name))
        self._dd_spec(sd->spec_kind, sd->spec_args) // specialization tag (#68)
        self._inherit_list("impl", sd->implements)
        self.p.newline()
        var empty_methods: FrozenList<unsafe *Declarations::FunctionDecl>
        var members = cxx::std::vector<unsafe *Decl>()
        self._collect_type_members(
            unsafe (sd as unsafe *DeclContext),
            sd->fields,
            empty_methods,
            unsafe &members,
        )

        self._dump_members(sd, members, is_last)
    }

    fn _dd_class(self, cd: unsafe *Declarations::ClassDecl, is_last: bool) {
        self._head("ClassDecl", is_last)
        if cd->is_final {
            self._dim("final")
        }

        self._dump_vis(unsafe (cd as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (cd as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(cd->name))
        self._dd_spec(cd->spec_kind, cd->spec_args) // specialization tag (#68)
        self._inherit_list("derives", cd->derives_list)
        self._inherit_list("impl", cd->implements)
        self.p.newline()
        var members = cxx::std::vector<unsafe *Decl>()
        self._collect_type_members(cd, cd->fields, cd->methods, unsafe &members)
        self._dump_members(cd, members, is_last)
    }

    fn _dd_interface(self, id: unsafe *Declarations::InterfaceDecl, is_last: bool) {
        self._head("InterfaceDecl", is_last)
        self._dump_vis(unsafe (id as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (id as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(id->name))
        self._derives_clause(id)
        self.p.newline()
        var empty_fields: FrozenList<unsafe *Declarations::FieldDecl>
        var members = cxx::std::vector<unsafe *Decl>()
        self._collect_type_members(
            unsafe (id as unsafe *DeclContext),
            empty_fields,
            id->methods,
            unsafe &members,
        )

        self._dump_members(id, members, is_last)
    }

    fn _dd_extension(self, ed: unsafe *Declarations::ExtensionDecl, is_last: bool) {
        self._head("ExtensionDecl", is_last)
        self._dump_vis(unsafe (ed as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (ed as unsafe *Decl))
        self.p.put(" ")
        self.src_type(ed->target)
        self._dd_spec(ed->spec_kind, ed->spec_args) // specialization tag (#68); pattern lives in `target`.
        self._inherit_list("impl", ed->implements)
        self.p.newline()
        var empty_fields: FrozenList<unsafe *Declarations::FieldDecl>
        var members = cxx::std::vector<unsafe *Decl>()
        self._collect_type_members(
            unsafe (ed as unsafe *DeclContext),
            empty_fields,
            ed->methods,
            unsafe &members,
        )

        self._dump_members(ed, members, is_last)
    }

    fn _dd_union(self, ud: unsafe *Declarations::UnionDecl, is_last: bool) {
        self._head("UnionDecl", is_last)
        self._dump_vis(unsafe (ud as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (ud as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(ud->name))
        self._dd_spec(ud->spec_kind, ud->spec_args) // specialization tag (#68)
        self.p.newline()
        var empty_methods: FrozenList<unsafe *Declarations::FunctionDecl>
        var members = cxx::std::vector<unsafe *Decl>()
        self._collect_type_members(
            unsafe (ud as unsafe *DeclContext),
            ud->fields,
            empty_methods,
            unsafe &members,
        )

        self._dump_members(ud, members, is_last)
    }

    /// Enum: members are in `variants` (the parser never adds them to
    /// dc_decls; the enum body has no nested-type parsing at all). Walk
    /// variants directly. No source-order merge needed -- variants is already
    /// in declaration order.
    fn _dd_enum(self, en: unsafe *Declarations::EnumDecl, is_last: bool) {
        self._head("EnumDecl", is_last)
        self._dump_vis(unsafe (en as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (en as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(en->name))
        if en->underlying != &null {
            self.p.paint(Color::Keyword, " derives ")
            self.src_type(en->underlying)
        }

        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (en as unsafe *Decl))
        var n         = en->variants.size()
        if !has_attrs && n == 0 {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (en as unsafe *Decl), n == 0)
        }

        for var i: usize = 0; i < n; ++i {
            self._child_decl(en->variants[i], i == n - 1)
        }

        self.p.leave()
    }

    /// Module: every member is in dc_decls (no projection caches, no group
    /// wrappers). Walk dc_decls directly, in source order as the parser
    /// appended it.
    fn _dd_module(self, md: unsafe *Declarations::ModuleDecl, is_last: bool) {
        self._head("ModuleDecl", is_last)
        if md->is_inline {
            self._dim("inline")
        }

        self._dump_vis(unsafe (md as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (md as unsafe *Decl))
        if !md->is_anonymous {
            self.p.put(" ")
            self.p.paint(Color::Ident, self.tok(md->name))
        }

        self.p.newline()

        var unsafe *dc       = unsafe (md as unsafe *DeclContext)
        var        has_attrs = self._has_annotations(unsafe (md as unsafe *Decl))
        var        n         = dc->dc_decls.size()
        if !has_attrs && n == 0 {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (md as unsafe *Decl), n == 0)
        }

        for var i: usize = 0; i < n; ++i {
            self._child_decl(*dc->dc_decls.get(i), i == n - 1)
        }

        self.p.leave()
    }

    fn _dd_enum_variant(self, v: unsafe *Declarations::EnumVariantDecl, is_last: bool) {
        self._head("EnumVariantDecl", is_last)
        self._dump_vis(unsafe (v as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (v as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::Ident, self.tok(v->name))
        if v->is_pack_expansion {
            self.p.paint(Color::Punct, " pack-expansion")
        }

        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (v as unsafe *Decl))
        var has_disc  = v->discriminant != &null
        var npayload  = v->payload.size()
        if !has_attrs && !has_disc && npayload == 0 {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            var attrs_last = !has_disc && npayload == 0
            self._dump_annotations(unsafe (v as unsafe *Decl), attrs_last)
        }

        if has_disc {
            var disc_last = npayload == 0
            self._head("discriminant", disc_last)
            self.p.newline()
            self.p.enter(disc_last)
            self._child_expr(v->discriminant, true)
            self.p.leave()
        }

        for var i: usize = 0; i < npayload; ++i {
            self._child_decl(unsafe ((*v->payload.get(i)) as unsafe *Decl), i == npayload - 1)
        }

        self.p.leave()
    }

    fn _dd_type_alias(self, ta: unsafe *Declarations::TypeAliasDecl, is_last: bool) {
        self._head("TypeAliasDecl", is_last)
        self._dump_vis(unsafe (ta as unsafe *Decl))
        self._dump_ffi_linkage(unsafe (ta as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::TypeName, self.tok(ta->name))
        self._alias_rest(ta)
        self.p.newline()
        if self._has_annotations(unsafe (ta as unsafe *Decl)) {
            self.p.enter(is_last)
            self._dump_annotations(unsafe (ta as unsafe *Decl), true)
            self.p.leave()
        }
    }

    fn _dd_vis_group(self, vg: unsafe *Declarations::VisibilityGroupDecl, is_last: bool) {
        self._head("VisibilityGroupDecl", is_last)
        self.p.put(" ")
        self._vis(vg->group_visibility)
        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (vg as unsafe *Decl))
        var n         = vg->members.size()
        if !has_attrs && n == 0 {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (vg as unsafe *Decl), n == 0)
        }

        for var i: usize = 0; i < n; ++i {
            self._child_decl(vg->members[i], i == n - 1)
        }

        self.p.leave()
    }

    fn _dd_ffi_block(self, fb: unsafe *Declarations::FFIBlockDecl, is_last: bool) {
        self._head("FFIBlockDecl", is_last)
        self.p.put(" ")
        self.p.paint(Color::Literal, self.tok(fb->lang_token))
        self.p.newline()

        var n         = fb->body.size()
        var has_attrs = self._has_annotations(unsafe (fb as unsafe *Decl))
        if !has_attrs && n == 0 {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (fb as unsafe *Decl), n == 0)
        }

        for var i: usize = 0; i < n; ++i {
            self._child_decl(fb->body[i], i == n - 1)
        }

        self.p.leave()
    }

    fn _dd_eval_block(self, eb: unsafe *Declarations::EvalBlockDecl, is_last: bool) {
        self._head("EvalBlockDecl", is_last)
        self.p.newline()
        var has_attrs = self._has_annotations(unsafe (eb as unsafe *Decl))
        var n         = eb->body.size()
        var has_stmt  = eb->stmt != &null
        if !has_attrs && n == 0 && !has_stmt {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (eb as unsafe *Decl), n == 0 && !has_stmt)
        }

        for var i: usize = 0; i < n; ++i {
            self._child_decl(eb->body[i], i == n - 1 && !has_stmt)
        }

        if has_stmt {
            self._child_stmt(eb->stmt, true)
        }

        self.p.leave()
    }

    fn _dd_test(self, td: unsafe *Declarations::TestDecl, is_last: bool) {
        self._head("TestDecl", is_last)
        self._dump_vis(unsafe (td as unsafe *Decl))
        if td->label != &null {
            self.p.put(" ")
            self.src_expr(td->label)
        }

        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (td as unsafe *Decl))
        var has_body  = td->body != &null
        if !has_attrs && !has_body {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (td as unsafe *Decl), !has_body)
        }

        if has_body {
            self._child_stmt(unsafe (td->body as unsafe *Stmt), true)
        }

        self.p.leave()
    }

    fn _dd_proc_macro(self, pm: unsafe *Declarations::ProcedureMacroDecl, is_last: bool) {
        self._head("ProcedureMacroDecl", is_last)
        self._dump_vis(unsafe (pm as unsafe *Decl))
        self.p.put(" ")
        self.p.paint(Color::Attr, f"@{self.tok(pm->name)}")
        self._param_list(pm->params)
        self.p.newline()

        var has_attrs = self._has_annotations(unsafe (pm as unsafe *Decl))
        var has_body  = pm->body != &null
        if !has_attrs && !has_body {
            return
        }

        self.p.enter(is_last)
        if has_attrs {
            self._dump_annotations(unsafe (pm as unsafe *Decl), !has_body)
        }

        if has_body {
            self._child_stmt(unsafe (pm->body as unsafe *Stmt), true)
        }

        self.p.leave()
    }

    //  PUBLIC DUMP FACADES (entry points)
    //
    //  Each sets _pending_last and routes through the overridden dispatcher
    //  via self.dyn() so the CRTP contract holds. A top-level node defaults
    //  to is_last = true.

    fn dump_type(self, ty: unsafe *Type, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_type(ty)
    }

    fn dump_expr(self, e: unsafe *Expr, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_expr(e)
    }

    fn dump_pattern(self, pat: unsafe *Pattern, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_pattern(pat)
    }

    fn dump_stmt(self, stmt: unsafe *Stmt, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_stmt(stmt)
    }

    fn dump_decl(self, decl: unsafe *Decl, is_last: bool) {
        self._pending_last = is_last
        self.dyn()->dispatch_decl(decl)
    }

    //  NODE-KIND NAMES  (UNCHANGED)

    fn _expr_kind_name(self, e: unsafe *Expr) -> string {
        return self._expr_kind_name_of(e->kind)
    }

    fn _type_kind_name(self, ty: unsafe *Type) -> string {
        return self._type_kind_name_of(ty->kind)
    }

    fn _pattern_kind_name(self, pat: unsafe *Pattern) -> string {
        return self._pattern_kind_name_of(pat->kind)
    }

    fn _recovery_name(self, const intended: string) -> string {
        return f"trying: {intended}"
    }

    fn _expr_kind_name_of(self, k: ExprKind) -> string {
        return expr_kind_name(k)
    }

    fn _type_kind_name_of(self, k: TypeKind) -> string {
        match k {
            case TypeKind::ChainType {
                return "ChainType"
            } case TypeKind::GenericParamType {
                return "GenericParamType"
            } case TypeKind::SubstGenericParamType {
                return "SubstGenericParamType"
            } case TypeKind::TypeOfType {
                return "TypeOfType"
            } case TypeKind::VariadicPackType {
                return "VariadicPackType"
            } case TypeKind::PackExpansionType {
                return "PackExpansionType"
            } case TypeKind::PointerType {
                return "PointerType"
            } case TypeKind::NullableType {
                return "NullableType"
            } case TypeKind::TupleType {
                return "TupleType"
            } case TypeKind::FixedArrayType {
                return "FixedArrayType"
            } case TypeKind::VectorType {
                return "VectorType"
            } case TypeKind::MapType {
                return "MapType"
            } case TypeKind::SetType {
                return "SetType"
            } case TypeKind::SelfType {
                return "SelfType"
            } case TypeKind::FunctionPointerType {
                return "FunctionPointerType"
            } case TypeKind::InferredType {
                return "InferredType"
            } case TypeKind::CXXLValueRefType {
                return "CXXLValueRefType"
            } case TypeKind::CXXRValueRefType {
                return "CXXRValueRefType"
            } case TypeKind::OpaqueFFIType {
                return "OpaqueFFIType"
            } case TypeKind::QualifiedType {
                return "QualifiedType"
            } case TypeKind::TypeExpr {
                return "TypeExpr"
            } case TypeKind::AssocType {
                return "AssocType"
            } default {
                return "<type>"
            }
        }
    }

    fn _pattern_kind_name_of(self, k: PatternKind) -> string {
        match k {
            case PatternKind::WildcardPattern {
                return "WildcardPattern"
            } case PatternKind::LiteralPattern {
                return "LiteralPattern"
            } case PatternKind::BindingPattern {
                return "BindingPattern"
            } case PatternKind::TupleDestructurePattern {
                return "TupleDestructurePattern"
            } case PatternKind::ConstructorPattern {
                return "ConstructorPattern"
            } case PatternKind::UnresolvedConstructorPattern {
                return "UnresolvedConstructorPattern"
            } case PatternKind::AlternationPattern {
                return "AlternationPattern"
            } case PatternKind::RangePattern {
                return "RangePattern"
            } case PatternKind::SlicePattern {
                return "SlicePattern"
            } default {
                return "<pattern>"
            }
        }
    }

    fn _stmt_kind_name_of(self, k: StmtKind) -> string {
        match k {
            case StmtKind::CompoundStmt {
                return "CompoundStmt"
            } case StmtKind::ExpressionStmt {
                return "ExpressionStmt"
            } case StmtKind::DeclStmt {
                return "DeclStmt"
            } case StmtKind::ReturnStmt {
                return "ReturnStmt"
            } case StmtKind::BreakStmt {
                return "BreakStmt"
            } case StmtKind::ContinueStmt {
                return "ContinueStmt"
            } case StmtKind::PanicStmt {
                return "PanicStmt"
            } case StmtKind::YieldStmt {
                return "YieldStmt"
            } case StmtKind::RuntimeAssertStmt {
                return "RuntimeAssertStmt"
            } case StmtKind::StaticAssertStmt {
                return "StaticAssertStmt"
            } case StmtKind::LabelIntrinsicStmt {
                return "LabelIntrinsicStmt"
            } case StmtKind::JumpIntrinsicStmt {
                return "JumpIntrinsicStmt"
            } case StmtKind::ConditionalStmt {
                return "ConditionalStmt"
            } case StmtKind::WhileLoopStmt {
                return "WhileLoopStmt"
            } case StmtKind::LoopStmt {
                return "LoopStmt"
            } case StmtKind::RangedForStmt {
                return "RangedForStmt"
            } case StmtKind::IndexedForStmt {
                return "IndexedForStmt"
            } case StmtKind::MatchStmt {
                return "MatchStmt"
            } case StmtKind::LabeledStmt {
                return "LabeledStmt"
            } case StmtKind::TryCatchStmt {
                return "TryCatchStmt"
            } case StmtKind::FinallyStmt {
                return "FinallyStmt"
            } case StmtKind::UnsafeBlockStmt {
                return "UnsafeBlockStmt"
            } case StmtKind::ContextBindingStmt {
                return "ContextBindingStmt"
            } case StmtKind::DestructuringDeclStmt {
                return "DestructuringDeclStmt"
            } case StmtKind::InlineBlockStmt {
                return "InlineBlockStmt"
            } case StmtKind::EvalBlockStmt {
                return "EvalBlockStmt"
            } case StmtKind::SwitchDispatchStmt {
                return "SwitchDispatchStmt"
            } default {
                return "<stmt>"
            }
        }
    }

    fn _decl_kind_name_of(self, k: DeclKind) -> string {
        match k {
            case DeclKind::FunctionDecl {
                return "FunctionDecl"
            } case DeclKind::VariableDecl {
                return "VariableDecl"
            } case DeclKind::FieldDecl {
                return "FieldDecl"
            } case DeclKind::ParamDecl {
                return "ParamDecl"
            } case DeclKind::GenericParamDecl {
                return "GenericParamDecl"
            } case DeclKind::StructDecl {
                return "StructDecl"
            } case DeclKind::ClassDecl {
                return "ClassDecl"
            } case DeclKind::InterfaceDecl {
                return "InterfaceDecl"
            } case DeclKind::ExtensionDecl {
                return "ExtensionDecl"
            } case DeclKind::EnumDecl {
                return "EnumDecl"
            } case DeclKind::EnumVariantDecl {
                return "EnumVariantDecl"
            } case DeclKind::UnionDecl {
                return "UnionDecl"
            } case DeclKind::TypeAliasDecl {
                return "TypeAliasDecl"
            } case DeclKind::ModuleDecl {
                return "ModuleDecl"
            } case DeclKind::ImportDecl {
                return "ImportDecl"
            } case DeclKind::VisibilityGroupDecl {
                return "VisibilityGroupDecl"
            } case DeclKind::EvalBlockDecl {
                return "EvalBlockDecl"
            } case DeclKind::TestDecl {
                return "TestDecl"
            } case DeclKind::MacroDecl {
                return "MacroDecl"
            } case DeclKind::ProcedureMacroDecl {
                return "ProcedureMacroDecl"
            } case DeclKind::FFIBlockDecl {
                return "FFIBlockDecl"
            } default {
                return "<decl>"
            }
        }
    }
}
