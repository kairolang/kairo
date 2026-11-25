/// --- The Kairo Project ------------------------- Codegen/Emit/Stmts.k --- ///
///
///   EmitIR, part: statements. The statement dispatcher, blocks, `return`,
///   `yield`, `if`, static and runtime assertions, and C++ `try`.
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

import AST::DeclFacts::place_has_const_root
import AST::Kind::DeclKind::to_string
import AST::Kind::ExprKind::to_string
import AST::Kind::StmtKind::{
    StmtKind,
    to_string,
}
import AST::Kind::TypeKind::to_string
import AST::LangItems::{
    ABORT_EXIT_CODE,
    LangAttrs,
    LangMembers,
    LowerTargets,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    ParenExpr,
    TypeCastExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Statements::{
    BranchHint,
    BreakStmt,
    CompoundStmt,
    ConditionalStmt,
    ContinueStmt,
    DeclStmt,
    ExpressionStmt,
    IndexedForStmt,
    IterKind,
    JumpIntrinsicStmt,
    LabelIntrinsicStmt,
    LoopStmt,
    RangedForStmt,
    ReturnStmt,
    RuntimeAssertStmt,
    StaticAssertStmt,
    SwitchDispatchStmt,
    TryCatchStmt,
    UnsafeBlockStmt,
    WhileLoopStmt,
    YieldStmt,
}
import AST::Node::Types::PointerType
import Codegen::Emit::Calls
import Codegen::Emit::Convert
import Codegen::Emit::Ctors
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::Exprs
import Codegen::Emit::Locals
import Codegen::Emit::Loops
import Codegen::Emit::Names
import Codegen::Emit::Push
import Codegen::Spell::Spell::Speller
import Location::SourceRange::SourceRange

/// The longest assertion text a failed `assert` with a run-time message
/// writes, in bytes: rt/crash.h's KAIRO_RT_CRASH_MAX, past which the runtime
/// drops the rest anyway.
const ASSERT_TEXT_MAX: usize = 4096

/// `m`, an `assert` message after StringLowering, is a plain string
/// literal: the constructor call StringLowering made of it, spanning the
/// literal alone, whose bytes argument is that literal. A call that merely
/// takes a literal argument (`f("x")`) spans more than the literal.
fn _literal_message(m: unsafe *Expr) -> bool {
    var unsafe *call = dyn_cast<CallExpr>(m)
    if call == &null || call->args.size() == 0 {
        return false
    }

    var unsafe *a = *call->args.get(0)
    var unsafe *c = dyn_cast<TypeCastExpr>(a)
    if c != &null {
        a = c->operand
    }

    var unsafe *lit = dyn_cast<StringLiteralExpr>(a)
    return lit != &null && lit->range == call->range
}

extend EmitIR {
    /// # Statements

    fn emit(self, s: unsafe *Stmt) {
        if s == &null {
            kairo::std::ice_fail("EmitIR: null stmt reached codegen")
        }

        if s->kind == StmtKind::RecoveryStmt {
            self._ice(
                s->range,
                "EmitIR: poisoned stmt reached codegen; sema gate failure",
            )
        }

        match s->kind {
            case StmtKind::CompoundStmt {
                self.emit_block(cast<CompoundStmt>(s))
            } case StmtKind::ReturnStmt {
                self._return(cast<ReturnStmt>(s))
            } case StmtKind::ExpressionStmt {
                var unsafe *n          = cast<ExpressionStmt>(s)
                var unsafe *saved_stmt = self._stmt_node
                self._stmt_node = n->expr
                self.emit(n->expr)
                self._stmt_node = saved_stmt
                self._cg->sink->synth_at_end(n->range, clang::tok::semi)
            } case StmtKind::DeclStmt {
                self._decl(cast<DeclStmt>(s))
            } case StmtKind::ConditionalStmt {
                self._if(cast<ConditionalStmt>(s))
            } case StmtKind::WhileLoopStmt {
                self._ef_loops += 1
                self._while(cast<WhileLoopStmt>(s))
                self._ef_loops -= 1
            } case StmtKind::LoopStmt {
                var unsafe *n = cast<LoopStmt>(s)
                self._cg->sink->spell(n->range, "for (;;)")
                self._ef_loops += 1
                self.emit_block(n->body)
                self._ef_loops -= 1
            } case StmtKind::IndexedForStmt {
                self._ef_loops += 1
                self._for(cast<IndexedForStmt>(s))
                self._ef_loops -= 1
            } case StmtKind::BreakStmt {
                var unsafe *n = cast<BreakStmt>(s)
                if n->has_label {
                    self._ice(
                        s->range,
                        "EmitIR: labeled break; LabelLowering must have rewritten it",
                    )
                }

                // An `eval for`'s own break ends the `&&` fold (Compiler/Spec/Eval.md#eval-for).
                if self._ef_depth > 0 && self._ef_loops == 0 {
                    self._cg->sink->spell(n->range, "return false;")
                } else {
                    self._cg->sink->spell(n->range, "break;")
                }
            } case StmtKind::ContinueStmt {
                var unsafe *n = cast<ContinueStmt>(s)
                if n->has_label {
                    self._ice(
                        s->range,
                        "EmitIR: labeled continue; LabelLowering must have rewritten it",
                    )
                }

                if self._ef_depth > 0 && self._ef_loops == 0 {
                    self._cg->sink->spell(n->range, "return true;")
                } else {
                    self._cg->sink->spell(n->range, "continue;")
                }
            } case StmtKind::UnsafeBlockStmt {
                self.emit_block(cast<UnsafeBlockStmt>(s)->body)
            } case StmtKind::RangedForStmt {
                var unsafe *rf = cast<RangedForStmt>(s)
                if rf->iter_kind == IterKind::Pack {
                    self._pack_for(rf)
                } else if rf->cxx_dependent {
                    self._cxx_dependent_for(rf)
                } else {
                    if !rf->is_eval {
                        self._ice(
                            s->range,
                            "EmitIR: ranged for; IterLowering owns it",
                        )
                    }

                    self._eval_for(rf)
                }
            } case StmtKind::MatchStmt {
                self._ice(s->range, "EmitIR: match MatchLowering left in place")
            } case StmtKind::TryCatchStmt {
                var unsafe *t = cast<TryCatchStmt>(s)
                if !t->cxx {
                    self._ice(
                        s->range,
                        "EmitIR: try/catch; PanicLowering owns it",
                    )
                }

                self._cxx_try(t)
            } case StmtKind::FinallyStmt {
                self._ice(s->range, "EmitIR: finally; FinallyLowering owns it")
            } case StmtKind::PanicStmt {
                self._ice(s->range, "EmitIR: panic; PanicLowering owns it")
            } case StmtKind::YieldStmt {
                self._yield(cast<YieldStmt>(s))
            } case StmtKind::RuntimeAssertStmt {
                self._assert(cast<RuntimeAssertStmt>(s))
            } case StmtKind::StaticAssertStmt {
                self._static_assert(cast<StaticAssertStmt>(s))
            } case StmtKind::ContextBindingStmt {
                self._ice(
                    s->range,
                    "EmitIR: context binding; ContextLowering owns it",
                )
            } case StmtKind::DestructuringDeclStmt {
                self._ice(
                    s->range,
                    "EmitIR: destructuring; TupleLowering owns a tuple's, FeatureGateCheck rejects a struct's",
                )
            } case StmtKind::LabeledStmt {
                self._ice(
                    s->range,
                    "EmitIR: labeled loop; the label lowering owns it",
                )
            } case StmtKind::LabelIntrinsicStmt {
                var unsafe *n = cast<LabelIntrinsicStmt>(s)
                self._name(n->name)
                self._cg->sink->spell(n->range, ":;")
            } case StmtKind::JumpIntrinsicStmt {
                var unsafe *n = cast<JumpIntrinsicStmt>(s)
                // Out of an `eval for` copy (a lambda no goto leaves): stop
                // the fold; the jump after the expansion takes it on.
                if n->ef_leave {
                    if self._ef_depth == 0 {
                        self._ice(
                            n->range,
                            "EmitIR: a jump out of an eval for copy outside one; PanicLowering marks only those",
                        )
                    }

                    self._cg->sink->spell(n->range, "return false;")
                } else {
                    self._cg->sink->spell(n->range, "goto")
                    self._name(n->target)
                    self._cg->sink->synth_at_end(n->range, clang::tok::semi)
                }
            } case StmtKind::SwitchDispatchStmt {
                self._switch_dispatch(cast<SwitchDispatchStmt>(s))
            } case StmtKind::InlineBlockStmt {
                self._ice(
                    s->range,
                    "EmitIR: inline foreign block; not emitted yet",
                )
            } case StmtKind::EvalBlockStmt {
                self._ice(
                    s->range,
                    "EmitIR: an eval block in a function body; FeatureGateCheck rejects it",
                )
            } default {
                self._ice(
                    s->range,
                    f"EmitIR: statement kind {to_string(s->kind)} is not in the core",
                )
            }
        }
    }

    /// PanicLowering's C++ `try` (Compiler/Spec/Panic.md#c-exception-arms, §4.5a H): `try { body }
    /// catch (T& e) { arm } ...`, each arm's binding a reference to the
    /// exception (PanicLowering typed it), or the type alone when the arm
    /// binds nothing.
    priv fn _cxx_try(self, n: unsafe *TryCatchStmt) {
        self._cg->sink->spell(n->range, "try")
        self.emit_block(n->try_body)
        for var i: usize = 0; i < n->arms.size(); ++i {
            var unsafe *a = n->arms.get(i)
            self._cg->sink->spell(a->range, "catch (")
            // Not _var_decl: a handler's parameter has no initializer, and a
            // local without one is value-initialized there.
            var unsafe *vd = dyn_cast<VariableDecl>(a->decl)
            if vd != &null {
                self._cg->sink->spell(
                    vd->name.range,
                    self._spell._type(vd->type_),
                )

                self._local_ref(unsafe (vd as unsafe *Decl), vd->name)
            } else {
                self._cg->sink->spell(
                    a->range,
                    self._spell._type(a->filter->canonical) + "&",
                )
            }

            self._cg->sink->spell(a->range, ")")
            self.emit_block(a->body)
        }
    }

    fn emit_block(self, n: unsafe *CompoundStmt) {
        if n == &null {
            kairo::std::ice_fail("EmitIR: null block reached codegen")
        }

        self._cg->sink->synth_at_start(n->range, clang::tok::l_brace)
        self._stmts(n, 0)
        self._cg->sink->synth_at_end(n->range, clang::tok::r_brace)
    }

    /// The `return` keyword borrows the statement's first six bytes; correct
    /// only because Kairo spells it `return` too. TODO(ast): retain the token.
    /// A `return` the parser synthesized for an expression body (`fn f() = 7`)
    /// has the expression's range, which can be shorter than six bytes: the
    /// borrow is clipped to it, or a lone literal near the end of its file
    /// reads past the buffer (TokenSink::_bytes ICEs).
    priv fn _return_kw_at(self, n: unsafe *ReturnStmt) -> SourceRange {
        var len = n->range.size()
        if len > (6 as u32) {
            len = (6)
        }

        return SourceRange::from_bounds(n->range.start, len)
    }

    /// The function being emitted is the program's `main` with no result,
    /// which the head spells `int main()`.
    priv fn _in_void_main(self) -> bool {
        if self._cur_fn == &null || self._closure != &null {
            return false
        }

        if !self._spell.is_main(unsafe (self._cur_fn as unsafe *Decl)) {
            return false
        }

        var unsafe *rt = self._cur_fn->return_type
        if rt == &null || rt->canonical == &null {
            return true
        }

        var unsafe *c = canon_unqual(rt->canonical)
        return c != &null
            && isa<BuiltinType>(c)
            && cast<BuiltinType>(c)->builtin == BuiltinKind::Void
    }

    /// A valueless return from the function being emitted, as C++ text.
    prot fn _bare_return(self) -> string {
        if self._in_void_main() {
            return "return 0;"
        }

        return "return;"
    }

    priv fn _return(self, n: unsafe *ReturnStmt) {
        // In a closure: the lambda's own return, to the closure's type.
        if self._closure != &null {
            self._cg->sink->synth(self._return_kw_at(n), clang::tok::kw_return)
            var unsafe *crt = self._closure->return_type
            if self._closure->panic_result != &null {
                crt = self._closure->panic_result
            }

            if n->value != &null {
                self._ret_move = self._returned_name(n->value)
                self._value(n->value, crt)
                self._ret_move = &null
            }

            self._cg->sink->synth_at_end(n->range, clang::tok::semi)
            return
        }

        // Out of a push-form loop body (Emit/Push.k): the function's flag
        // and value, then stop the generator.
        if self._pf_depth > 0 {
            self._push_return(n)
            return
        }

        // A generator's push form: `return` ends the sequence.
        if self._twin {
            if n->value != &null {
                self._ice(
                    n->range,
                    "EmitIR: generator 'return' with a value; X gate failure",
                )
            }

            self._cg->sink->spell(n->range, "return true;")
            return
        }

        // Out of an `eval for` copy: the function's return slot, then stop
        // the fold; the code after the expansion returns (Compiler/Spec/Eval.md#eval-for).
        if self._ef_depth > 0 {
            self._cg->sink->spell(
                n->range,
                "{ " + LowerTargets::eval_for_ret_flag() + " = true;",
            )

            if n->value != &null {
                // Built in place, once: a copy's `return` stops every fold
                // out to the function, so no slot is filled twice.
                self._cg->sink->spell(
                    n->range,
                    LowerTargets::eval_for_ret_val() + "." + LowerTargets::ctor_slot_init() + "(",
                )

                var vrt: unsafe *Type = &null
                if self._cur_fn != &null {
                    vrt = self._cur_fn->return_type
                }

                if self._cur_fn != &null && self._cur_fn->panic_result != &null {
                    vrt = self._cur_fn->panic_result
                }

                self._slot_value(n->value, vrt, n->range)
                self._cg->sink->spell(n->range, ");")
            }

            self._cg->sink->spell(n->range, "return false; }")
            return
        }

        // An eval generator's `return` hands back what it yielded.
        if self._cur_fn != &null && self._cur_fn->is_generator && self._cur_fn->is_eval() {
            self._cg->sink->spell(
                n->range,
                "return " + LowerTargets::eval_yield_buf() + ";",
            )

            return
        }

        // A generator's `return` is bare (X rejects a value) and ends the
        // sequence: `co_return;`. A plain `return` in a coroutine is ill-formed.
        if self._cur_fn != &null && self._cur_fn->is_generator {
            if n->value != &null {
                self._ice(
                    n->range,
                    "EmitIR: generator 'return' with a value; X gate failure",
                )
            }

            self._cg->sink->spell(n->range, "co_return")
            self._cg->sink->synth_at_end(n->range, clang::tok::semi)
            return
        }

        // `fn main()` with no result is `int main()` (the head above), where
        // a bare `return;` is ill-formed: C++'s implicit 0 is only for
        // falling off the end.
        if n->value == &null && self._in_void_main() {
            self._cg->sink->spell(n->range, "return 0")
            self._cg->sink->synth_at_end(n->range, clang::tok::semi)
            return
        }

        self._cg->sink->synth(self._return_kw_at(n), clang::tok::kw_return)
        if n->value != &null {
            var rt: unsafe *Type = &null
            if self._cur_fn != &null {
                rt = self._cur_fn->return_type
            }

            // A panicking function returns its Panic result (PanicLowering
            // built every returned value as one).
            if self._cur_fn != &null && self._cur_fn->panic_result != &null {
                rt = self._cur_fn->panic_result
            }

            // A place operator's decl still says `*T` (importers' X reads it),
            // but the C++ function returns `T&`: `return x;` binds the
            // reference, and a conversion to `T*` here would be wrong.
            if self._cur_fn != &null
                && (Speller::is_place_operator(self._cur_fn) || self._cur_fn->cxx_ref_return)
                && rt != &null
                && rt->canonical != &null {
                rt = cast<PointerType>(canon_unqual(rt->canonical))->pointee
            }

            self._ret_move = self._returned_name(n->value)
            self._value(n->value, rt)
            self._ret_move = &null
        }

        self._cg->sink->synth_at_end(n->range, clang::tok::semi)
    }

    /// `v` under its parens when it is a plain name, else null: the value
    /// C++ moves out of a `return` on its own (_ret_move).
    priv fn _returned_name(self, v: unsafe *Expr) -> unsafe *Expr {
        var unsafe *x = v
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x != &null && isa<NamedIdentExpr>(x) {
            return x
        }

        return &null
    }

    /// `co_yield (e);`. The operand is emitted bare when its canonical is the
    /// element's: `co_yield` on an lvalue binds the promise's `T&` overload,
    /// which is the zero-copy path, and an exactness cast would turn it into
    /// a prvalue. A differing type is cast to the element and binds the
    /// prvalue overload.
    priv fn _yield(self, n: unsafe *YieldStmt) {
        if self._cur_fn == &null || !self._cur_fn->is_generator {
            self._ice(
                n->range,
                "EmitIR: yield outside a generator; X gate failure",
            )
        }

        if n->value == &null {
            self._ice(n->range, "EmitIR: yield with no value reached codegen")
        }

        // An eval generator pushes into its buffer (Compiler/Spec/Eval.md#eval-for).
        if self._cur_fn->is_eval() {
            self._cg->sink->spell(
                n->range,
                LowerTargets::eval_yield_buf() + "." + LowerTargets::eval_buf_push() + "(",
            )

            self._value(n->value, self._yield_elem(self._cur_fn))
            self._cg->sink->spell(n->range, ");")
            return
        }

        // YieldPromise::yield_value takes a `T&` (`@inout`: the reader sees
        // the generator's own value) or a `T&&` (`@move`: a prvalue, which
        // lives to the end of the full `co_yield` expression and so across
        // the suspension). A CONST lvalue binds neither, so it is copied to
        // a frame local first: the local lives until the block closes, after
        // the generator resumes, and is what the reader sees. Const
        // by its type, or by its root: `self.n` in a `const self`
        // generator, `p.n` of a `const p`, whose types say nothing. A
        // move-only one is MoveCheck's SC182E before this.
        var unsafe *elem = self._yield_elem(self._cur_fn)
        var unsafe *vt   = n->value->type_
        var clv = n->value->value_category == Expr::ValueCategory::LValue
            && vt != &null
            && (canon_has_const(vt)
                || place_has_const_root(n->value)
                || self._const_place_call(n->value))
            && (!self._needs_cast(n->value, elem, &null))

        // In the generator's push form (Emit/Push.k) the value goes to the
        // loop body through the form's sink, whose two overloads bind as
        // yield_value's do; a false answer is the consumer leaving its loop.
        if self._twin {
            var sink = LowerTargets::gen_sink()
            if clv {
                var tv = LowerTargets::yield_value_tmp()
                self._cg->sink->spell(n->range, "{ auto " + tv + " = (")
                self._value(n->value, elem)
                self._cg->sink->spell(
                    n->range,
                    "); if (!" + sink + "(" + tv + ")) " + self._push_stop() + " }",
                )

                return
            }

            self._cg->sink->spell(n->range, "if (!" + sink + "(")
            self._value(n->value, elem)
            self._cg->sink->spell(n->range, ")) " + self._push_stop())
            return
        }

        if clv {
            var yv = LowerTargets::yield_value_tmp()
            self._cg->sink->spell(n->range, "{ auto " + yv + " = (")
            self._value(n->value, elem)
            self._cg->sink->spell(n->range, "); co_yield(" + yv + "); }")
            return
        }

        self._cg->sink->spell(n->range, "co_yield")
        self._cg->sink->spell(n->range, "(")
        self._value(n->value, elem)
        self._cg->sink->spell(n->range, ")")
        self._cg->sink->synth_at_end(n->range, clang::tok::semi)
    }

    /// `e` is a lowered `x[i]` through a place `op []` C++ sees as a
    /// `const T&` (Speller::return_spelling), which neither `yield_value`
    /// binds: the form returns `*const T`, or it is a `self` form on a
    /// receiver const by its root (`self.items[0]` in a `const self`
    /// generator), where C++ picks the `const` overload instead.
    priv fn _const_place_call(self, e: unsafe *Expr) -> bool {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        var unsafe *c = dyn_cast<CallExpr>(x)
        if c == &null || c->callee == &null {
            return false
        }

        var unsafe *f = dyn_cast<FunctionDecl>(self._callee_decl(c->callee))
        if !Speller::is_place_operator(f) {
            return false
        }

        var unsafe *pt = cast<PointerType>(
            canon_unqual(f->return_type->canonical),
        )

        if canon_has_const(pt->pointee) {
            return true
        }

        // A `const self` form is what C++ calls on a const receiver too, so
        // its result decides (a slice's `*T` is a mutable element).
        if f->is_const() {
            return false
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c->callee)
        return ch != &null && ch->base != &null && place_has_const_root(ch->base)
    }

    /// `T` of a generator's Yield<T> return canonical, or null (nothing to
    /// cast to; the operand goes bare).
    prot fn _yield_elem(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        if f->return_type == &null || f->return_type->canonical == &null {
            return &null
        }

        var unsafe *rt = canon_unqual(f->return_type->canonical)
        if rt == &null || !isa<RecordType>(rt) {
            return &null
        }

        var unsafe *r = cast<RecordType>(rt)
        return if (r->args.size() > 0) => (r->args[0]) else => &null
    }

    /// `assert static c, "msg"` is C++'s `static_assert(c, "msg")`. In a
    /// generic body `c` depends on the parameters (a C++ trait over `T`), so
    /// no Kairo pass can decide it; clang does, per instance, and a false one
    /// is that instance's error. The message must be a literal in C++, so it
    /// is spelled from the source text, not emitted as a `string` value.
    priv fn _static_assert(self, n: unsafe *StaticAssertStmt) {
        self._cg->sink->spell(n->range, "static_assert(")
        self.emit(n->condition)
        // StringLowering has already replaced the message with a `string`
        // construction, so its source text is what is read.
        if n->message != &null && n->message->range.is_valid() {
            var t = self._cg->ctx->sm->get_text(n->message->range)
            if t.size() >= 3 && t.data()[0] == 0x22 {
                self._cg->sink->spell(n->range, ", " + t)
            } else if t.size() >= 4 && t.data()[0] == 0x72 && t.data()[1] == 0x22 {
                var inner = t.subslice(2, t.size() - 3)
                self._cg->sink->spell(n->range, ", " + Speller::c_string(inner))
            }
        }

        self._cg->sink->spell(n->range, ");")
    }

    /// `assert c, msg?` (Compiler/Spec/Panic.md#crashes-are-not-panics): a crash-family check, so
    /// `if (!(c)) crash_exit(...)` with the runtime's own noreturn entry, which
    /// formats nothing: the text arrives whole. With no message, or a literal
    /// one, the text is a C literal of the location and the statement as
    /// written, which already carries the literal. Any other message is a
    /// `string` known only at run time, so the failing branch evaluates it,
    /// once, and joins it to the location and the condition as written in a
    /// stack buffer of the runtime's limit. That branch is a cold, noinline
    /// lambda: the buffer is in its frame, not the caller's, and the message
    /// is never evaluated while the condition holds.
    priv fn _assert(self, n: unsafe *RuntimeAssertStmt) {
        var unsafe *sm = self._cg->ctx->sm
        var        lc  = sm->get_line_col(n->range.start)
        var at = f"kairo: assertion failed at {sm->get_filename(n->range.start)}:{lc.line}:{lc.column}: "
        var exit = LowerTargets::rt_crash_exit()
        if n->message == &null || _literal_message(n->message) {
            var lit = Speller::c_string(at + sm->get_text(n->range))
            self._cg->sink->spell(n->range, "if (!(")
            self.emit(n->condition)
            self._cg->sink->spell(
                n->range,
                ")) ::" + exit + "(reinterpret_cast<const unsigned char*>(" + lit + "), sizeof(" + lit + ") - 1, " + f"{ABORT_EXIT_CODE}" + ");",
            )

            return
        }

        var lit = Speller::c_string(
            at + "assert " + sm->get_text(n->condition->range),
        )

        var z   = LowerTargets::cxx_size_t()
        var cap = f"{ASSERT_TEXT_MAX}"
        var tw = self._cg->tu != &null
            && self._cg->tu->global_scope != &null
            && self._cg->tu->global_scope->well_known()->two_word()
        self._cg->sink->spell(n->range, "if (!(")
        self.emit(n->condition)
        self._cg->sink->spell(
            n->range,
            ")) [&]() __attribute__((cold, noinline)) noexcept { const auto& __kairo_am = (",
        )

        self.emit(n->message)
        var sd   = LangMembers::string_data(tw)
        var sl   = LangMembers::string_size(tw)
        var body = "); "
        body += "const unsigned char* __kairo_ad = reinterpret_cast<const unsigned char*>(__kairo_am." + sd + "()); "
        body += z.copy() + " __kairo_ak = __kairo_am." + sl + "(); "
        body += "unsigned char __kairo_ab[" + cap + "]; "
        body += z.copy() + " __kairo_an = sizeof(" + lit + ") - 1; "
        body += "if (__kairo_an > " + cap + ") { __kairo_an = " + cap + "; } "
        body += "__builtin_memcpy(__kairo_ab, " + lit + ", __kairo_an); "
        body += "if (__kairo_ak > 0 && __kairo_an + 2 < " + cap + ") { "
        body += "__kairo_ab[__kairo_an++] = 58; __kairo_ab[__kairo_an++] = 32; "
        body += "if (__kairo_ak > " + cap + " - __kairo_an) { __kairo_ak = " + cap + " - __kairo_an; } "
        body += "__builtin_memcpy(__kairo_ab + __kairo_an, __kairo_ad, __kairo_ak); __kairo_an += __kairo_ak; } "
        body += "::" + exit + "(__kairo_ab, __kairo_an, " + f"{ABORT_EXIT_CODE}" + "); }();"
        self._cg->sink->spell(n->range, body)
    }

    /// The weight written on one branch of `n`, as a BranchHint: the `if`'s
    /// own `@likely` / `@unlikely` (LangAttrs) for the then-branch, the
    /// `else`'s for `of_else`. An `eval if` has no branch to weigh.
    priv fn _branch_hint(self, n: unsafe *ConditionalStmt, of_else: bool) -> u8 {
        if of_else {
            return n->else_hint
        }

        if n->is_eval || !n->has_attribute() {
            return BranchHint::None as u8
        }

        var unsafe *tbl = self._cg->ctx->tcm->get_imm_table_for_fid(
            self._owning_fid(),
        )

        if tbl == &null {
            return BranchHint::None as u8
        }

        var kl = tbl->find_ident(LangAttrs::likely())
        var ku = tbl->find_ident(LangAttrs::unlikely())
        if kl != u32::MAX && n->has_attribute_named(kl) {
            return BranchHint::Likely as u8
        }

        if ku != u32::MAX && n->has_attribute_named(ku) {
            return BranchHint::Unlikely as u8
        }

        return BranchHint::None as u8
    }

    /// `n` is written `@unpredictable if`.
    priv fn _unpredictable(self, n: unsafe *ConditionalStmt) -> bool {
        if n->is_eval || !n->has_attribute() {
            return false
        }

        var unsafe *tbl = self._cg->ctx->tcm->get_imm_table_for_fid(
            self._owning_fid(),
        )

        if tbl == &null {
            return false
        }

        var k = tbl->find_ident(LangAttrs::unpredictable())
        return k != u32::MAX && n->has_attribute_named(k)
    }

    /// C++'s attribute for BranchHint `h`, or "".
    priv fn _hint_attr(self, h: u8) -> string {
        if h == (BranchHint::Likely as u8) {
            return "[[likely]]"
        }

        if h == (BranchHint::Unlikely as u8) {
            return "[[unlikely]]"
        }

        return ""
    }

    priv fn _if(self, n: unsafe *ConditionalStmt) {
        var own = isa<BinaryOperatorExpr>(n->cond) // `(a == b)` brings its own parens; a second pair is C786W.
        // An `eval if` EvalIfFolding could not fold (a function body only):
        // C++ chooses, and discards the other branch in a template.
        var kw = if (n->is_eval) => ("if constexpr") else => "if"
        self._cg->sink->spell(
            SourceRange::from_bounds(n->range.start, 2 as u32),
            if (own) => (kw) else => kw + " (",
        )

        // `@unpredictable if c`: the condition is clang's
        // `__builtin_unpredictable(c)`, which marks the branch on it.
        // Bare, as the whole condition: clang keeps the hint only on a branch
        // whose condition is the builtin's own call (no cast, no `!= 0`).
        var unpred = self._unpredictable(n)
        if unpred {
            if own {
                self._cg->sink->spell(n->cond->range, "(")
            }

            self._cg->sink->spell(
                n->cond->range,
                LowerTargets::clang_unpredictable() + "(",
            )
        }

        var unsafe *saved_cond = self._if_cond
        var unsafe *cx         = n->cond
        while cx != &null && isa<ParenExpr>(cx) {
            cx = cast<ParenExpr>(cx)->inner
        }

        self._if_cond = if (unpred) => (&null) else => cx
        self.emit(n->cond)
        self._if_cond = saved_cond
        if unpred {
            self._cg->sink->spell(n->cond->range, ")")
            if own {
                self._cg->sink->spell(n->cond->range, ")")
            }
        }

        if !own {
            self._cg->sink->spell(n->cond->range, ")")
        }

        // `@likely if` / `@unlikely if`: C++'s attribute on the then-branch,
        // which clang turns into the branch's weights.
        var hint = self._hint_attr(self._branch_hint(n, false))
        if hint.size() > 0 {
            self._cg->sink->spell(n->cond->range, hint)
        }

        self.emit_block(n->then_)
        if n->else_ != &null {
            // `} @unlikely else`: C++20 puts the attribute on the else
            // substatement, so it weighs the else branch itself.
            var eh = "else"
            var ea = self._hint_attr(self._branch_hint(n, true))
            if ea.size() > 0 {
                eh += " " + ea
            }

            self._cg->sink->spell(n->else_->range, eh)
            self.emit(n->else_) // a ConditionalStmt (else-if) or a CompoundStmt.
        }
    }
}
