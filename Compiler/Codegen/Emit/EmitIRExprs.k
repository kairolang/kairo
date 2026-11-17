/// --- The Kairo Project ------------------- Codegen/Emit/EmitIRExprs.k --- ///
///
///   EmitIR, part: the expression dispatcher, and the forms too small for a
///   file of their own: constraints, pack expansions, subscripts, `if`
///   expressions, `new`, closures and their capture lists, PanicLowering's
///   panic operations, and type operands.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "vector"

import AST::DeclFacts::decl_pattern
import AST::Kind::DeclKind::to_string
import AST::Kind::ExprKind::{
    ExprKind,
    to_string,
}
import AST::Kind::StmtKind::to_string
import AST::Kind::TypeKind::{
    TypeKind,
    to_string,
}
import AST::LangItems::{
    LowerTargets,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    InterfaceDecl,
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    AlignOfExpr,              AnonInitializerExpr, AssignOperatorExpr,   BinaryOperatorExpr,
    CallExpr,                 CaptureMode,         ClosureExpr,          ConstraintExpr,
    CxxNewExpr,               DeleteExpr,          EvalExpr,             IfExpr,
    ImplicitBoundaryCastExpr, InitListExpr,        NamedInitializerExpr, PackExpansionExpr,
    PanicOp,                  PanicOpExpr,         ParenExpr,            SizeOfExpr,
    StmtExpr,                 SubscriptExpr,       TypeCastExpr,         TypeTraitExpr,
    UnaryOperatorExpr,        UnsafeExpr,          VariantInitExpr,      type_trait_cxx,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Types::{
    FunctionPointerType,
    GenericParamType,
    PointerType,
}
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitIRCalls
import Codegen::Emit::EmitIRConvert
import Codegen::Emit::EmitIRDecls
import Codegen::Emit::EmitIRForms
import Codegen::Emit::EmitIRLiterals
import Codegen::Emit::EmitIRLocals
import Codegen::Emit::EmitIRNames
import Codegen::Emit::EmitIROperators
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell::Speller

extend EmitIR {
    /// A character literal is its own bytes with C++'s `U` prefix: a
    /// `char` is a Unicode scalar value and lowers to `char32_t`, and a
    /// plain `'...'` is a one-byte `char` literal, which clang rejects for
    /// any character past U+007F (`'\u00e9'`, `'漢'`). C++ reads every
    /// other escape as Kairo does, `\xHH` included (one code unit of a
    /// `U` literal is the code point). `'\{'` and `'\}'` are the two it does
    /// not know (the lexer accepts them with S022W), so those are spelled
    /// as the brace itself. A literal a macro expansion carries has the
    /// invocation's range and is borrowed as it is.
    priv fn _char_lit(self, n: unsafe *CharacterLiteralExpr) {
        var text  = self._cg->ctx->sm->get_text(n->token.range)
        var cxx_v = "U"
        if text.size() == 4 && text[1] == 0x5c && (text[2] == 0x7b || text[2] == 0x7d) {
            cxx_v += "'"
            cxx_v.push_back(text[2])
            cxx_v += "'"
        } else {
            cxx_v += text
        }

        self._cg->sink->create_char(n->token.range, &cxx_v)
    }

    /// # Expressions

    fn emit(self, e: unsafe *Expr) {
        if e == &null {
            kairo::std::ice_fail("EmitIR: null expr reached codegen")
        }

        if e->kind == ExprKind::RecoveryExpr {
            self._ice(
                e->range,
                "EmitIR: poisoned expr reached codegen; sema gate failure",
            )
        }

        if e->is_poisoned() {
            self._ice(
                e->range,
                "EmitIR: poisoned expr reached codegen; sema gate failure",
            )
        }

        match e->kind {
            case ExprKind::IntegerLiteralExpr {
                self._int_lit(cast<IntegerLiteralExpr>(e))
            } case ExprKind::FloatingLiteralExpr {
                self._float_lit(cast<FloatingLiteralExpr>(e))
            } case ExprKind::CharacterLiteralExpr {
                self._char_lit(cast<CharacterLiteralExpr>(e))
            } case ExprKind::BooleanLiteralExpr {
                self._cg->sink->spell(e->range, (if (cast<BooleanLiteralExpr>(e)->value) => ("true") else => "false"))
            } case ExprKind::NullLiteralExpr {
                self._cg->sink->spell(e->range, "nullptr")
            } case ExprKind::StringLiteralExpr {
                self._string(cast<StringLiteralExpr>(e))
            } case ExprKind::NamedIdentExpr {
                self._name(cast<NamedIdentExpr>(e))
            } case ExprKind::ChainExpr {
                self._chain(cast<ChainExpr>(e))
            } case ExprKind::CallExpr {
                self._call(cast<CallExpr>(e))
            } case ExprKind::ParenExpr {
                self._cg->sink->spell(e->range, "(")
                self.emit(cast<ParenExpr>(e)->inner)
                self._cg->sink->spell(e->range, ")")
            } case ExprKind::UnaryOperatorExpr {
                var unsafe *un = cast<UnaryOperatorExpr>(e)
                var        uw  = self._duck_unary(un)
                if uw {
                    self._nopanic_open(e->range)
                }

                self._unary(un)
                if uw {
                    self._nopanic_close(e->range)
                }
            } case ExprKind::BinaryOperatorExpr {
                var unsafe *bn = cast<BinaryOperatorExpr>(e)
                var bw = self._duck_operand(bn->lhs) || self._duck_operand(bn->rhs)
                if bw {
                    self._nopanic_open(e->range)
                }

                self._binary(bn)
                if bw {
                    self._nopanic_close(e->range)
                }
            } case ExprKind::AssignOperatorExpr {
                var unsafe *an = cast<AssignOperatorExpr>(e)
                var        aw  = self._duck_compound(an)
                if aw {
                    self._nopanic_open(e->range)
                }

                self._assign(an)
                if aw {
                    self._nopanic_close(e->range)
                }
            } case ExprKind::TypeCastExpr {
                if cast<TypeCastExpr>(e)->disarms != &null {
                    self._disarm_site(cast<TypeCastExpr>(e))
                } else {
                    self._cast(cast<TypeCastExpr>(e))
                }
            } case ExprKind::ImplicitBoundaryCastExpr {
                var unsafe *n = cast<ImplicitBoundaryCastExpr>(e)
                if !self._array_view(n->original, n->target_type, &null) {
                    self._cast_to(n->target_type, n->original, "static_cast")
                }
            } case ExprKind::NamedInitializerExpr {
                self._init(e, cast<NamedInitializerExpr>(e)->fields)
            } case ExprKind::AnonInitializerExpr {
                self._init(e, cast<AnonInitializerExpr>(e)->fields)
            } case ExprKind::IfExpr {
                self._if_expr(cast<IfExpr>(e))
            } case ExprKind::SizeOfExpr {
                self._cg->sink->spell(
                    e->range,
                    "sizeof(" + self._spell._type(cast<SizeOfExpr>(e)->type_arg) + ")",
                )
            } case ExprKind::AlignOfExpr {
                self._cg->sink->spell(
                    e->range,
                    "alignof(" + self._spell._type(
                        cast<AlignOfExpr>(e)->type_arg,
                    ) + ")",
                )
            } case ExprKind::TypeTraitExpr {
                var unsafe *tt = cast<TypeTraitExpr>(e)
                self._cg->sink->spell(
                    e->range,
                    type_trait_cxx(tt->fact) + "(" + self._spell._type(
                        tt->type_arg,
                    ) + ")",
                )
            } case ExprKind::DeleteExpr {
                // `@cxx::delete p` / `@cxx::delete [] p`: C++'s own delete. A
                // bare Kairo `delete p` is S091E and never reaches here.
                var unsafe *n = cast<DeleteExpr>(e)
                self._cg->sink->spell(e->range, (if (n->is_array) => ("delete[] ") else => "delete "))
                self.emit(n->operand)
            } case ExprKind::CxxNewExpr {
                self._cxx_new(cast<CxxNewExpr>(e))
            } case ExprKind::UnsafeExpr {
                self.emit(cast<UnsafeExpr>(e)->operand)
            } case ExprKind::SubscriptExpr {
                self._subscript(cast<SubscriptExpr>(e))
            } case ExprKind::NamedArgExpr {
                self._ice(
                    e->range,
                    "EmitIR: named argument; CallLowering owns it",
                )
            } case ExprKind::MatchExpr {
                self._ice(e->range, "EmitIR: match MatchLowering left in place")
            } case ExprKind::TryCatchExpr {
                self._ice(
                    e->range,
                    "EmitIR: try expression; PanicLowering owns it",
                )
            } case ExprKind::RangeExpr {
                self._ice(
                    e->range,
                    "EmitIR: range; RangeLowering owns it (IterLowering for a loop's iterable)",
                )
            } case ExprKind::ClosureExpr {
                self._closure_expr(cast<ClosureExpr>(e))
            } case ExprKind::AwaitExpr {
                self._ice(e->range, "EmitIR: await; the async lowering owns it")
            } case ExprKind::UnwrapExpr {
                self._ice(e->range, "EmitIR: unwrap!; CoalesceLowering owns it")
            } case ExprKind::DefinedExpr {
                self._ice(e->range, "EmitIR: defined!; EvalIfFolding owns it")
            } case ExprKind::AttributedExpr {
                self._ice(
                    e->range,
                    "EmitIR: expression attribute; FeatureGateCheck gates every one",
                )
            } case ExprKind::PanicOpExpr {
                self._panic_op(cast<PanicOpExpr>(e))
            } case ExprKind::SpawnExpr {
                self._ice(e->range, "EmitIR: spawn; the async lowering owns it")
            } case ExprKind::ThreadExpr {
                self._ice(
                    e->range,
                    "EmitIR: thread; the async lowering owns it",
                )
            }

            // `eval e`: computed by C++ at compile time, in place (Compiler/Spec/Eval.md
            // §0); EvalUsageChecking made sure `e` can be.
            case ExprKind::EvalExpr {
                self._cg->sink->spell(e->range, "[&]() consteval { return (")
                self.emit(cast<EvalExpr>(e)->operand)
                self._cg->sink->spell(e->range, "); }()")
            }

            // `xs...` (or `...xs`): C++'s own pack expansion, in an argument
            // list.
            case ExprKind::PackExpansionExpr {
                self._pack_expansion(cast<PackExpansionExpr>(e))
            } case ExprKind::ListLiteralExpr {
                self._ice(
                    e->range,
                    "EmitIR: list literal; ListLiteralLowering owns it",
                )
            } case ExprKind::InitListExpr {
                self._init_list(cast<InitListExpr>(e), false)
            } case ExprKind::VariantInitExpr {
                self._variant_init(cast<VariantInitExpr>(e))
            } case ExprKind::StmtExpr {
                // `({ ... })`: clang's statement expression. The block is
                // emitted as any block; the parens make it a value.
                if self._ns_init {
                    self._ns_stmt_expr(cast<StmtExpr>(e))
                } else {
                    self._cg->sink->spell(e->range, "(")
                    self.emit_block(cast<StmtExpr>(e)->body)
                    self._cg->sink->spell(e->range, ")")
                }
            } case ExprKind::SetLiteralExpr {
                self._ice(
                    e->range,
                    "EmitIR: set literal; the container migration owns it",
                )
            } case ExprKind::MapLiteralExpr {
                self._ice(
                    e->range,
                    "EmitIR: map literal; the container migration owns it",
                )
            } case ExprKind::TupleLiteralExpr {
                self._ice(
                    e->range,
                    "EmitIR: tuple literal; TupleLowering owns it",
                )
            } case ExprKind::TypeOfExpr {
                self._ice(e->range, "EmitIR: typeof; TypeQueryLowering owns it")
            } case ExprKind::ConstraintExpr {
                self._constraint(cast<ConstraintExpr>(e))
            } case ExprKind::VerbatimExpr {
                self._ice(e->range, "EmitIR: verbatim span; tooling-only node")
            } default {
                self._ice(
                    e->range,
                    f"EmitIR: expression kind {to_string(e->kind)} is not in the core",
                )
            }
        }
    }

    /// `A impl I` as a value: the condition of a function-body `eval if`
    /// EvalIfFolding left to C++ (Compiler/Spec/NameResolution.md#expansion), decided once per
    /// instantiation by I's concept -- `(::ns::I_c<A>)`, the conjunct
    /// Speller::requires_clause writes for a bound, so the test and a bound
    /// can never disagree. The taken branch may call I's members on A
    /// (ChainBinding's narrowed bounds); in a template the other branch is a
    /// discarded statement, never instantiated for an A that lacks them.
    /// EvalUsageChecking admits only `impl` over a generic parameter here.
    priv fn _constraint(self, c: unsafe *ConstraintExpr) {
        var unsafe *e = unsafe (c as unsafe *Expr)
        if c->is_derives() {
            self._ice(
                e->range,
                "EmitIR: a 'derives' test as a value; EvalUsageChecking admits only 'impl'",
            )
        }

        if c->rhs == &null || c->rhs->canonical == &null {
            self._ice(
                e->range,
                "EmitIR: an 'impl' test whose interface did not resolve",
            )
        }

        var unsafe *rhs = canon_unqual(c->rhs->canonical)
        if !isa<RecordType>(rhs) {
            self._ice(
                e->range,
                "EmitIR: an 'impl' test against a type that is not an interface",
            )
        }

        var unsafe *idecl = Speller::rep(
            decl_pattern(Speller::rep(cast<RecordType>(rhs)->decl)),
        )

        if !isa<InterfaceDecl>(idecl) {
            self._ice(
                e->range,
                "EmitIR: an 'impl' test against a type that is not an interface",
            )
        }

        var unsafe *gp = Speller::_bound_param(c)
        if gp == &null || gp->owner == &null {
            self._ice(
                e->range,
                "EmitIR: an 'impl' test of something other than a generic parameter",
            )
        }

        var subj = self._spell.tparam_name(gp, Speller::rep(gp->owner))
        self._cg->sink->spell(
            e->range,
            "(" + self._spell.concept_name(idecl) + self._spell.witness_args(
                subj,
                rhs,
            ) + ")",
        )
    }

    /// `xs...` of a forwarding pack (`T&&... xs`, Speller::forwarding_pack)
    /// is `static_cast<T&&>(xs)...`: a named `T&&` is an lvalue, and
    /// as one it would copy into the next layer's `E&&` (or not bind at
    /// all, for a MOVE element). With T an rvalue element the cast is a
    /// move; a reference element collapses to its own kind. A `const` or
    /// `@inout` pack goes on as it is, and so does an expansion the pack is
    /// read again after (`reread`, MoveCheck): forwarding it would
    /// hand that later read moved-from elements.
    priv fn _pack_expansion(self, n: unsafe *PackExpansionExpr) {
        var unsafe *opnd = n->operand
        while opnd != &null && isa<ParenExpr>(opnd) {
            opnd = cast<ParenExpr>(opnd)->inner
        }

        var p: unsafe *ParamDecl = &null
        if opnd != &null && isa<NamedIdentExpr>(opnd) {
            p = dyn_cast<ParamDecl>(cast<NamedIdentExpr>(opnd)->resolved_decl)
        }

        if Speller::forwarding_pack(p) && !n->reread {
            var unsafe *g = cast<GenericParamType>(
                canon_unqual(p->type_->canonical),
            )

            self._cg->sink->spell(
                n->range,
                "static_cast<" + self._spell.pack_param_name(g) + "&&>(",
            )

            self.emit(n->operand)
            self._cg->sink->spell(n->range, ")...")
            return
        }

        self.emit(n->operand)
        self._cg->sink->spell(n->range, "...")
    }

    /// A closure is a C++ lambda (Compiler/Spec/Codegen.md#emitir, Closures), wrapped in the
    /// `fn` value its type is:
    ///   captures nothing  `::__kairo_fn<R(A)>(+[](A a) -> R { ... })`
    ///   captures          `::__kairo_fn<R(A)>::own(new auto([c...](A a) mutable -> R { ... }))`
    /// The capture list is ClosureCaptures' decision (_capture_list). A
    /// capturing lambda is `mutable`: a by-copy capture is the closure's
    /// own variable, which its body may assign and which keeps its value
    /// from one call to the next. `new auto(prvalue)` builds the lambda in
    /// its heap slot directly, so no temporary lambda copies a capture.
    priv fn _closure_expr(self, n: unsafe *ClosureExpr) {
        if !n->caps_resolved {
            self._ice(
                n->range,
                "EmitIR: a closure with no capture decision; ClosureCaptures must run",
            )
        }

        if n->body_block == &null {
            self._ice(
                n->range,
                "EmitIR: an expression-bodied closure; ExprBodyDesugar wraps it in a block",
            )
        }

        if n->generic_params.size() > 0 {
            self._ice(
                n->range,
                "EmitIR: a generic closure; FeatureGateCheck rejects it",
            )
        }

        var fp: unsafe *FunctionPointerType = &null
        if n->type_ != &null {
            var unsafe *t = canon_unqual(n->type_)
            if t != &null && isa<FunctionPointerType>(t) {
                fp = cast<FunctionPointerType>(t)
            }
        }

        if fp == &null {
            self._ice_untyped(
                n,
                "EmitIR: a closure with no fn type; ExprTyper gate failure",
            )
        }

        var caps = self._capture_list(n)
        var head = "[" + caps + "]("
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if i > 0 {
                head += ", "
            }

            head += self._spell.closure_param(
                p,
                self._spell.tok_name(p->name, self._owning_fid()),
            )
        }

        head += ")"
        if caps.size() > 0 {
            head += " mutable"
        }

        // A closure is a Kairo frame like any function: noexcept unless
        // -funwind. A closure cannot carry `@unwind` yet (an attribute
        // before `fn` in expression position is an expression attribute).
        if !self._cg->opts.unwind {
            head += " noexcept"
        }

        var ret = "void"
        if !n->is_noreturn && n->return_type != &null {
            ret = self._spell._type(n->return_type)
        }

        if n->panic_result != &null {
            ret = self._spell._type(n->panic_result)
        }

        head += " -> " + ret

        var wrap = "::" + LowerTargets::fn_value() + "<" + self._spell.fn_signature(
            fp,
        ) + ">"
        // A raw closure (it captures nothing: ControlTyping::type_closure)
        // is the function pointer `+[]` gives, with no `fn` value around it.
        if fp->is_raw {
            if caps.size() > 0 {
                self._ice(
                    n->range,
                    "EmitIR: a raw closure with captures; ControlTyping and ClosureCaptures disagree",
                )
            }

            wrap = ""
        }

        if caps.size() == 0 {
            self._cg->sink->spell(n->range, wrap + "(+" + head)
        } else {
            self._cg->sink->spell(
                n->range,
                wrap + "::" + LowerTargets::fn_value_own() + "(new auto(" + head,
            )
        }

        var unsafe *saved = self._closure
        var        sd     = self._ef_depth
        var        sl     = self._ef_loops
        var        sn     = self._ns_init
        self._closure  = n
        self._ef_depth = 0     // a closure's statements are its own, not a copy's.
        self._ef_loops = 0
        self._ns_init  = false // a closure in a global's initializer has a function body.
        self.emit_block(n->body_block)
        self._closure  = saved
        self._ef_depth = sd
        self._ef_loops = sl
        self._ns_init  = sn

        if caps.size() == 0 {
            self._cg->sink->spell(n->range, ")")
        } else {
            self._cg->sink->spell(n->range, "))")
        }
    }

    /// The lambda's capture list, from ClosureCaptures' modes:
    ///   Copy      `x`                                (the closure's own copy)
    ///   Move      `x = static_cast<T&&>(x)`          (a MOVE value, moved in)
    ///   Ptr       `x = &x`                           (`x` IS the `*T` the body reads)
    ///   ConstPtr  `x = static_cast<const T*>(&x)`    (`x` when it is a pointer already)
    ///   Self      `this`, or `self` in an extension member (a pointer already)
    /// Init-captures keep the Kairo name, so the body is emitted unchanged:
    /// a `|*x|` closure's `*x = 1` is C++'s `*x = 1` on the captured pointer.
    priv fn _capture_list(self, n: unsafe *ClosureExpr) -> string {
        var s = ""
        for var i: usize = 0; i < n->held.size(); ++i {
            var unsafe *d  = n->held[i].decl
            var        m   = n->held[i].mode
            var        via = n->held[i].via_ptr
            if s.size() > 0 {
                s += ", "
            }

            if m == CaptureMode::Receiver {
                s += if (self._cur_ext != &null) => (LowerTargets::ext_receiver_name())
                     else => "this"
                continue
            }

            var nm = self._local_name(d)
            // A script's top-level `var` is a global: C++ captures no
            // global, so the copy is an init-capture from its qualified name,
            // unless an enclosing closure holds it already under `nm`.
            var origin = nm.copy()
            if (!self._is_local(d)) && (!self._captures_global(self._closure, d)) {
                origin = self._spell.qual_name(d)
            }

            // A union-stored local is its storage's member out here.
            var place = nm.copy()
            var ur    = self._ul_use(d)
            if ur != usize::MAX {
                origin = self._ul_obj[ur].copy()
                place  = origin.copy()
            }

            match m {
                case CaptureMode::Copy {
                    s += if (origin == nm) => (nm) else => nm + " = " + origin
                } case CaptureMode::Move {
                    s += nm + " = static_cast<" + self._spell._type(
                        self._capture_type(d),
                    ) + "&&>(" + origin + ")"
                } case CaptureMode::Ptr {
                    s += nm + " = &" + place
                } case CaptureMode::ConstPtr {
                    var src = if (via) => (place) else => "&" + place
                    s += nm + " = static_cast<const " + self._spell._type(
                        self._capture_type(d),
                    ) + "*>(" + src + ")"
                } default {
                    self._ice(
                        n->range,
                        "EmitIR: a capture mode with no spelling",
                    )
                }
            }
        }

        return s
    }

    /// Closure `c` captures the global `d` (a script's top-level `var`):
    /// inside it, `d` is the closure's own copy, named bare.
    prot fn _captures_global(self, c: unsafe *ClosureExpr, d: unsafe *Decl) -> bool {
        if c == &null || self._is_local(d) {
            return false
        }

        for var i: usize = 0; i < c->held.size(); ++i {
            if c->held[i].decl == d {
                return true
            }
        }

        return false
    }

    /// The captured binding's own type, top-level cv dropped (a capture's
    /// spelling adds what it needs).
    priv fn _capture_type(self, d: unsafe *Decl) -> unsafe *Type {
        var        t: unsafe *Type = &null
        var unsafe *p              = dyn_cast<ParamDecl>(d)
        if p != &null {
            t = if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_
        } else {
            t = cast<VariableDecl>(d)->type_
        }

        if t == &null || t->canonical == &null {
            self._ice(
                d->range,
                "EmitIR: a captured binding with no type; X gate failure",
            )
        }

        return canon_unqual(t->canonical)
    }

    /// `@cxx::new T(args)` -> `(new T(<T(args)>))`: C++17 builds the object
    /// in the new storage straight from the prvalue (no copy, no move), so
    /// whatever the construction lowered to is the initializer as written.
    /// `@cxx::new [T; n]` -> `(new T[n])`. Parenthesized so a postfix after
    /// it applies to the pointer.
    priv fn _cxx_new(self, n: unsafe *CxxNewExpr) {
        var s = self._cg->sink
        if n->is_array() {
            s->spell(
                n->range,
                "(new " + self._spell._type(n->elem_type()) + "[",
            )

            self.emit(n->count)
            s->spell(n->range, "])")
            return
        }

        var unsafe *c = canon_unqual(
            if (n->type_->canonical != &null) => (n->type_->canonical) else => n->type_,
        )

        if c == &null || c->kind != TypeKind::PointerType {
            self._ice(n->range, "EmitIR: '@cxx::new' not typed as a pointer")
        }

        s->spell(
            n->range,
            "(new " + self._spell._type(cast<PointerType>(c)->pointee) + "(",
        )

        self.emit(n->init)
        s->spell(n->range, "))")
    }

    priv fn _subscript(self, n: unsafe *SubscriptExpr) {
        // `self.v[i]` on a `vector<T>`: the operator was left to each
        // instance, so clang resolves `operator[]` as written.
        if self._record_operand(n->base) && !self._dependent_foreign_type(n->base->type_) {
            self._ice(
                n->range,
                "EmitIR: `[]` on a record; OperatorLowering owns it",
            )
        }

        self.emit(n->base)
        self._cg->sink->spell(n->range, "[")
        self.emit(n->index)
        self._cg->sink->spell(n->range, "]")
    }

    priv fn _if_expr(self, n: unsafe *IfExpr) {
        // (c ? a : (c2 ? b : e)) -- every arm converts to the join type X
        // recorded on the node.
        self._cg->sink->spell(n->range, "(")
        self.emit(n->condition)
        self._cg->sink->spell(n->range, "?")
        self._if_arm(n->then_expr, n->type_)
        self._cg->sink->spell(n->range, ":")
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var unsafe *arm = n->else_ifs.get(i)
            self._cg->sink->spell(arm->range, "(")
            self.emit(arm->condition)
            self._cg->sink->spell(arm->range, "?")
            self._if_arm(arm->body, n->type_)
            self._cg->sink->spell(arm->range, ":")
        }

        self._if_arm(n->else_expr, n->type_)
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            self._cg->sink->spell(n->range, ")")
        }

        self._cg->sink->spell(n->range, ")")
    }

    /// One arm of an if-expression, converted to the join type `t`. An arm
    /// of type `!` (`else => die()`) is a void call to C++, which `?:` takes
    /// only as a `throw` (`static_cast<int>(die())` is rejected, CL001E). It is
    /// the body of a lambda returning `t` that never returns, called on the
    /// spot: a prvalue of the join type for every T, a move-only or
    /// non-transferable one included, with nothing copied. `[&]` reaches
    /// the arm's locals; at namespace scope nothing needs capturing, and no
    /// capture-default is allowed there.
    priv fn _if_arm(self, e: unsafe *Expr, t: unsafe *Type) {
        var arm_never = e != &null && e->type_ != &null && self._is_never_type(e->type_)
        if !arm_never || t == &null || self.tu_is_void(t) {
            self._value(e, t)
            return
        }

        var cap = if (self._ns_init) => ("[]") else => "[&]"
        self._cg->sink->spell(
            e->range,
            cap + "() -> " + self._spell._type(t) + " { ",
        )

        var saved = self._ns_init
        self._ns_init = false
        self.emit(e)
        self._ns_init = saved
        self._cg->sink->spell(
            e->range,
            "; " + LowerTargets::clang_unreachable() + "(); }()",
        )
    }

    priv fn _is_never_type(self, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        return cast<BuiltinType>(c)->builtin == BuiltinKind::Never
    }

    /// PanicLowering's C++ with no Kairo spelling (PanicOpExpr):
    ///   Fwd / FwdAll  `::__kairo_fwd<R, A>(operand)`, R the node's type;
    ///   SlotPut       `new (&slot.__kairo_b) ::__kairo_rbox<T>{operand}`,
    ///                 the slot built from the prvalue in place;
    ///   SlotTake      `slot.__kairo_take()`: the value moved out, the
    ///                 slot destroyed.
    /// The slot is a raw_slot local, read by its name.
    priv fn _panic_op(self, n: unsafe *PanicOpExpr) {
        if n->which == PanicOp::Fwd || n->which == PanicOp::FwdAll {
            if n->type_ == &null || n->operand == &null {
                self._ice(
                    n->range,
                    "EmitIR: a panic fwd with no result type or operand; PanicLowering mints both",
                )
            }

            var all = if (n->which == PanicOp::FwdAll) => ("true") else => "false"
            self._cg->sink->spell(
                n->range,
                "::" + LowerTargets::panic_fwd() + "<" + self._spell._type(
                    n->type_,
                ) + ", " + all + ">(",
            )

            self.emit(n->operand)
            self._cg->sink->spell(n->range, ")")
            return
        }

        match n->which {
            case PanicOp::SlotPut {
                if n->slot == &null || n->operand == &null || n->slot->type_ == &null {
                    self._ice(
                        n->range,
                        "EmitIR: a slot put with no slot or value; PanicLowering mints both",
                    )
                }

                self._cg->sink->spell(n->range, "new (&")
                self.emit(n->slot)
                self._cg->sink->spell(
                    n->range,
                    "." + LowerTargets::raw_box_member() + ") ::" + LowerTargets::raw_box() + "<" + self._spell._type(
                        n->slot->type_,
                    ) + ">{",
                )

                self._value(n->operand, n->slot->type_)
                self._cg->sink->spell(n->range, "}")
            } case PanicOp::SlotTake {
                if n->slot == &null {
                    self._ice(
                        n->range,
                        "EmitIR: a slot take with no slot; PanicLowering mints it",
                    )
                }

                self.emit(n->slot)
                self._cg->sink->spell(
                    n->range,
                    "." + LowerTargets::raw_take() + "()",
                )
            }

            // A dependent set's test and read (Compiler/Spec/Panic.md#generic-bodies): the C++ view's
            // `is<E>` / `error<E>`, which find E's id and its place in the
            // set C++ ordered at the instance.
            case PanicOp::Holds {
                if n->operand == &null || n->elem == &null {
                    self._ice(
                        n->range,
                        "EmitIR: a panic holds-test with no value or type; EnumLayoutQuery mints both",
                    )
                }

                self._cg->sink->spell(
                    n->range,
                    "::" + LowerTargets::panic_api_ns() + "::" + LowerTargets::panic_api_is() + "<" + self._spell._type(
                        n->elem,
                    ) + ">(",
                )

                self.emit(n->operand)
                self._cg->sink->spell(n->range, ")")
            } case PanicOp::ErrorRef {
                if n->operand == &null || n->elem == &null {
                    self._ice(
                        n->range,
                        "EmitIR: a panic error read with no value or type; EnumLayoutQuery mints both",
                    )
                }

                self._cg->sink->spell(
                    n->range,
                    "::" + LowerTargets::panic_api_ns() + "::" + LowerTargets::panic_api_error() + "<" + self._spell._type(
                        n->elem,
                    ) + ">(",
                )

                self.emit(n->operand)
                self._cg->sink->spell(n->range, ")")
            } default {
                0
            }
        }
    }

    /// # Types

    fn emit(self, t: unsafe *Type) {
        if t == &null {
            kairo::std::ice_fail("EmitIR: null type reached codegen")
        }

        // A member type of a duck parameter (`T::Guard`) has no canonical until
        // an instance names T; it is spelled as written (Speller::dependent_member).
        if t->canonical == &null && self._spell.dependent_member(t).size() == 0 {
            self._ice(
                t->range,
                "EmitIR: unresolved type reached codegen; sema gate failure",
            )
        }

        self._cg->sink->spell(t->range, self._spell._type(t))
    }
}
