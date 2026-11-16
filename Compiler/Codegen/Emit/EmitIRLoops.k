/// --- The Kairo Project ------------------- Codegen/Emit/EmitIRLoops.k --- ///
///
///   EmitIR, part: loops. C-style `for`, `while`, the switch dispatch
///   Lowering builds, and the loops unrolled at compile time: `eval for`
///   (Compiler/Spec/Eval.md#eval-for), `for` over a type pack, and a ranged
///   `for` over a dependent C++ range.
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

import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions::BinaryOperatorExpr
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements::{
    BindingShorthand, DeclStmt, IndexedForStmt, IterKind, RangedForStmt, SwitchDispatchStmt,
    WhileLoopStmt,
}
import AST::Node::Types::FixedArrayType
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitIRDecls
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::EmitIRLocals
import Codegen::Emit::EmitIRNames
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell
import Location::SourceRange::SourceRange

extend EmitIR {
    /// `eval for i in X { body }` (Compiler/Spec/Eval.md#eval-for): the body expanded once per
    /// value with an index pack, so in each copy `i` is a constant:
    ///
    ///   { [&]<usize... K>(::__kairo_iseq<usize, K...>) {
    ///       (... && [&]<usize I>() -> bool { constexpr T i = VAL(I); body; return true; }
    ///                .template operator()<K>());
    ///     }(__make_integer_seq<::__kairo_iseq, usize, COUNT>{}); }
    ///
    /// The `&&` fold is the unrolled loop: `continue` is `return true` from a
    /// copy, `break` `return false`, which stops the fold. A `return` sets
    /// the function's flag (and value slot) and stops it, and the code after
    /// the outermost expansion returns; an inner one stops its enclosing
    /// copy. VAL / COUNT: a range is `LO + I` and `HI - LO` (`+ 1` when
    /// inclusive); an array its elements; an eval generator's values are
    /// computed once, into `static constexpr` locals, ahead of the expansion.
    prot fn _eval_for(self, n: unsafe *RangedForStmt) {
        var        sz    = "decltype(sizeof(0))"
        var        at    = n->range
        var unsafe *elem = n->iter_elem
        if elem == &null {
            self._ice(
                at,
                "EmitIR: an eval for with no element type; X gate failure",
            )
        }

        if n->bindings.size() != 1 {
            self._ice(
                at,
                "EmitIR: an eval for with other than one binding; EvalUsageChecking rejects it",
            )
        }

        var        bd                 = n->bindings[0]
        var unsafe *vd                = dyn_cast<VariableDecl>(bd.decl)
        var        et                 = self._spell._type(elem)
        var        outer              = self._ef_depth == 0
        var        rt:   unsafe *Type = &null
        if self._cur_fn != &null && !self._cur_fn->is_noreturn {
            rt = self._cur_fn->return_type
        }

        if self._cur_fn != &null && self._cur_fn->panic_result != &null { // what its `return`s now carry.
            rt = self._cur_fn->panic_result
        }

        var has_val = rt != &null && rt->canonical != &null && !self.tu_is_void(rt->canonical)

        self._cg->sink->spell(at, "{")
        if outer {
            self._cg->sink->spell(
                at,
                "bool " + LowerTargets::eval_for_ret_flag() + " = false;",
            )

            if has_val {
                self._cg->sink->spell(at, self._ef_slot_decl(rt))
            }
        }

        var gk:      usize = 0
        var is_range       = n->ev_lo != &null && n->ev_hi != &null
        var is_gen         = !is_range && n->iter_kind == IterKind::User
        if is_gen {
            gk = self._ef_gens
            self._ef_gens += 1
            var gn = LowerTargets::eval_for_gen_n(gk)
            self._cg->sink->spell(
                at,
                "static constexpr " + sz + " " + gn + " = (",
            )

            self.emit(n->iterable)
            self._cg->sink->spell(
                at,
                ")." + LowerTargets::eval_buf_count() + ";",
            )

            self._cg->sink->spell(
                at,
                "static constexpr auto " + LowerTargets::eval_for_gen(
                    gk,
                ) + " = []() consteval { ::" + LowerTargets::eval_arr() + "<" + et + ", " + gn + "> a{}; auto b = (",
            )

            self.emit(n->iterable)
            self._cg->sink->spell(
                at,
                "); for (" + sz + " k = 0; k < " + gn + "; ++k) a." + LowerTargets::eval_arr_values() + "[k] = b." + LowerTargets::eval_buf_data() + "[k]; return a; }();",
            )
        }

        var K = LowerTargets::eval_for_pack(self._ef_depth)
        var I = LowerTargets::eval_for_index(self._ef_depth)
        self._cg->sink->spell(
            at,
            "[&]<" + sz + "... " + K + ">(::" + LowerTargets::eval_iseq() + "<" + sz + ", " + K + "...>) { (... && [&]<" + sz + " " + I + ">() -> bool {",
        )

        // The binding: a constant in each copy.
        var nm = if (vd != &null) => (self._local_name(
                     unsafe (vd as unsafe *Decl),
                 ))
                 else => LowerTargets::eval_for_unused()
        self._cg->sink->spell(
            at,
            "[[maybe_unused]] constexpr " + et + " " + nm + " = ",
        )

        if is_range {
            self._cg->sink->spell(at, "static_cast<" + et + ">((")
            self.emit(n->ev_lo)
            self._cg->sink->spell(
                at,
                ") + static_cast<" + et + ">(" + I + "));",
            )
        } else if is_gen {
            self._cg->sink->spell(
                at,
                LowerTargets::eval_for_gen(
                    gk,
                ) + "." + LowerTargets::eval_arr_values() + "[" + I + "];",
            )
        } else {
            self._cg->sink->spell(at, "(")
            self.emit(n->iterable)
            self._cg->sink->spell(at, ")[" + I + "];")
        }

        var sd = self._ef_depth
        var sl = self._ef_loops
        self._ef_depth += 1
        self._ef_loops = 0
        for var i: usize = 0; i < n->body->body.size(); ++i {
            self.emit(n->body->body[i])
        }

        self._ef_depth = sd
        self._ef_loops = sl

        self._cg->sink->spell(
            at,
            "return true; }.template operator()<" + K + ">()); }(" + LowerTargets::make_index_seq() + "<::" + LowerTargets::eval_iseq() + ", " + sz + ", ",
        )

        if is_range {
            self._cg->sink->spell(at, "static_cast<" + sz + ">((")
            self.emit(n->ev_hi)
            self._cg->sink->spell(at, ") - (")
            self.emit(n->ev_lo)
            self._cg->sink->spell(
                at,
                ")" + (if (n->ev_incl) => (" + 1") else => "") + ")",
            )
        } else if is_gen {
            self._cg->sink->spell(at, LowerTargets::eval_for_gen_n(gk))
        } else {
            var unsafe *arr = dyn_cast<FixedArrayType>(
                canon_unqual(n->iterable->type_),
            )

            if arr == &null {
                self._ice(
                    at,
                    "EmitIR: an eval for over something that is not a range, an array or an eval generator; EvalUsageChecking rejects it",
                )
            }

            var ext = if (arr->extent_param != &null) => (self._spell._type(
                          arr->extent_param,
                      ))
                      else => f"{arr->size_bits}"
            self._cg->sink->spell(at, ext)
        }

        self._cg->sink->spell(at, ">{});")

        var flag = LowerTargets::eval_for_ret_flag()
        if outer {
            if has_val {
                self._cg->sink->spell(
                    at,
                    "if (" + flag + ") { return " + LowerTargets::eval_for_ret_val() + "." + LowerTargets::ctor_slot_take() + "(); }",
                )
            } else {
                self._cg->sink->spell(
                    at,
                    "if (" + flag + ") { " + self._bare_return() + " }",
                )
            }
        } else {
            self._cg->sink->spell(at, "if (" + flag + ") { return false; }")
        }

        self._cg->sink->spell(at, "}")
    }

    /// `for x in xs` over a type pack (`...xs: T`): the body once per
    /// element, each copy a lambda the `&&` fold calls with that element,
    ///
    ///   { (void)(... && [&](auto& x) -> bool { body; return true; }(xs)); }
    ///
    /// (the `(void)` because an empty pack folds to a bare `true`, which as
    /// a statement is clang's "expression result unused", C1119W at the
    /// user's `for`) under `_eval_for`'s protocol, which this shares: `continue` is
    /// `return true` from a copy, `break` `return false`, a `return` sets
    /// the function's flag (and value slot) and stops the fold, and the
    /// code after the outermost expansion returns.
    /// A loop over an imported C++ range that depends on the generic's own
    /// parameter (StmtTyping::_cxx_range): C++'s range-for, which picks
    /// begin()/end() per instance as every other member call on the range
    /// is. A plain binder is a copy (`auto x`), `*x` the element's address,
    /// several plain names a structured binding; the shapes StmtTyping lets
    /// through.
    prot fn _cxx_dependent_for(self, n: unsafe *RangedForStmt) {
        var at   = n->range
        var s    = self._cg->sink
        var nb   = n->bindings.size()
        var el   = LowerTargets::range_elem()
        var head = "auto&& " + el
        var ptr  = ""
        if nb == 1 {
            var unsafe *b = n->bindings.get(0)
            if (!b->is_discard) && b->decl != &null {
                var nm = self._local_name(unsafe (b->decl as unsafe *Decl))
                if b->shorthand.has(BindingShorthand::Pointer) {
                    ptr = "auto* " + nm + " = " + LowerTargets::clang_addressof() + "(" + el + ");"
                } else {
                    head = "auto " + nm
                }
            } else {
                head = "[[maybe_unused]] auto&& " + el
            }
        } else {
            head = "auto ["
            for var i: usize = 0; i < nb; ++i {
                var unsafe *b = n->bindings.get(i)
                if i > 0 {
                    head = head + ", "
                }

                if b->is_discard || b->decl == &null {
                    head = head + LowerTargets::unused_binding(i)
                } else {
                    head = head + self._local_name(
                        unsafe (b->decl as unsafe *Decl),
                    )
                }
            }

            head = head + "]"
        }

        s->spell(at, "for (" + head + " : ")
        self.emit(n->iterable)
        s->spell(at, ") {" + ptr)
        var sl = self._ef_loops
        self._ef_loops += 1 // its break/continue are this loop's, not an `eval for`'s fold.
        for var i: usize = 0; i < n->body->body.size(); ++i {
            self.emit(n->body->body[i])
        }

        self._ef_loops = sl
        s->spell(at, "}")
    }

    prot fn _pack_for(self, n: unsafe *RangedForStmt) {
        var at = n->range
        if n->bindings.size() != 1 {
            self._ice(
                at,
                "EmitIR: a for over a pack with other than one binding; X gate failure",
            )
        }

        var unsafe *pk = dyn_cast<NamedIdentExpr>(n->iterable)
        if pk == &null {
            self._ice(
                at,
                "EmitIR: a for over a pack whose iterable is not the pack's name; StmtTyping classifies only that",
            )
        }

        var unsafe *vd = dyn_cast<VariableDecl>(n->bindings[0].decl)
        var outer              = self._ef_depth == 0
        var rt:   unsafe *Type = &null
        if self._cur_fn != &null && !self._cur_fn->is_noreturn {
            rt = self._cur_fn->return_type
        }

        if self._cur_fn != &null && self._cur_fn->panic_result != &null { // what its `return`s now carry.
            rt = self._cur_fn->panic_result
        }

        var has_val = rt != &null && rt->canonical != &null && !self.tu_is_void(rt->canonical)

        self._cg->sink->spell(at, "{")
        if outer {
            self._cg->sink->spell(
                at,
                "bool " + LowerTargets::eval_for_ret_flag() + " = false;",
            )

            if has_val {
                self._cg->sink->spell(at, self._ef_slot_decl(rt))
            }
        }

        var nm = if (vd != &null) => (self._local_name(
                     unsafe (vd as unsafe *Decl),
                 ))
                 else => LowerTargets::eval_for_unused()
        self._cg->sink->spell(
            at,
            "(void)(... && [&]([[maybe_unused]] auto& " + nm + ") -> bool {",
        )

        // The element's type, for a witness call through its bound
        // (_witness_member): the pack's canonical, matched against Self.
        var        pt: unsafe *Type = &null
        var unsafe *pd              = dyn_cast<ParamDecl>(pk->resolved_decl)
        if pd != &null && pd->type_ != &null && pd->type_->canonical != &null {
            pt = canon_unqual(pd->type_->canonical)
        }

        self._pe_gp.push_back(pt)
        self._pe_name.push_back(nm)
        var sd = self._ef_depth
        var sl = self._ef_loops
        self._ef_depth += 1
        self._ef_loops = 0
        for var i: usize = 0; i < n->body->body.size(); ++i {
            self.emit(n->body->body[i])
        }

        self._ef_depth = sd
        self._ef_loops = sl
        self._pe_gp.pop_back()
        self._pe_name.pop_back()
        self._cg->sink->spell(at, "return true; }(")
        self.emit(n->iterable)
        self._cg->sink->spell(at, "));")

        var flag = LowerTargets::eval_for_ret_flag()
        if outer {
            if has_val {
                self._cg->sink->spell(
                    at,
                    "if (" + flag + ") { return " + LowerTargets::eval_for_ret_val() + "." + LowerTargets::ctor_slot_take() + "(); }",
                )
            } else {
                self._cg->sink->spell(
                    at,
                    "if (" + flag + ") { " + self._bare_return() + " }",
                )
            }
        } else {
            self._cg->sink->spell(at, "if (" + flag + ") { return false; }")
        }

        self._cg->sink->spell(at, "}")
    }

    /// The function's return slot for a `return` out of an expansion copy:
    /// a `__kairo_slot<R>` (the constructor slots' helper), empty storage a
    /// returning copy builds the value in and the code after the expansion
    /// moves it out of. A plain `R slot{}` asked R for a default
    /// constructor whether or not any copy returns, which a panicking
    /// function's Panic result and many records lack (clang: "no matching
    /// constructor"). EmitPlan::needs_ef_slot has the preamble define it.
    priv fn _ef_slot_decl(self, rt: unsafe *Type) -> string {
        return "::" + LowerTargets::ctor_slot() + "<" + self._spell._type(
            rt,
        ) + "> " + LowerTargets::eval_for_ret_val() + ";"
    }

    prot fn _while(self, n: unsafe *WhileLoopStmt) {
        var own = isa<BinaryOperatorExpr>(n->cond) // `(a == b)` brings its own parens; a second pair is C786W.
        self._cg->sink->spell(
            SourceRange::from_bounds(n->range.start, 5 as u32),
            if (own) => ("while") else => "while (",
        )

        self.emit(n->cond)
        if !own {
            self._cg->sink->spell(n->cond->range, ")")
        }

        self.emit_block(n->body)
    }

    /// `switch (v) { case lo: goto L; case lo ... hi: goto L; default: goto D; }`:
    /// MatchLowering's dispatch. The cases hold only gotos, so a user
    /// `break` never meets this switch. `...` is clang's case range.
    prot fn _switch_dispatch(self, n: unsafe *SwitchDispatchStmt) {
        self._cg->sink->spell(n->range, "switch (")
        self.emit(n->value)
        self._cg->sink->spell(n->range, ") {")
        for var i: usize = 0; i < n->cases.size(); ++i {
            var unsafe *c = n->cases.get(i)
            self._cg->sink->spell(n->range, "case")
            self.emit(c->lo)
            if c->hi != &null {
                self._cg->sink->spell(n->range, " ... ")
                self.emit(c->hi)
            }

            self._cg->sink->spell(n->range, ": goto")
            self._name(c->target)
            self._cg->sink->spell(n->range, ";")
        }

        self._cg->sink->spell(n->range, "default:")
        if n->default_stmt != &null {
            self.emit(n->default_stmt)
        } else {
            self._cg->sink->spell(n->range, "goto")
            self._name(n->default_target)
            self._cg->sink->spell(n->range, ";")
        }

        self._cg->sink->spell(n->range, "}")
    }

    prot fn _for(self, n: unsafe *IndexedForStmt) {
        if n->is_eval {
            self._ice(
                n->range,
                "EmitIR: a C-style eval for; EvalUsageChecking rejects it",
            )
        }

        self._cg->sink->spell(
            SourceRange::from_bounds(n->range.start, 3 as u32),
            "for (",
        )

        if n->init != &null {
            var unsafe *ds = dyn_cast<DeclStmt>(n->init)
            if ds == &null {
                self._ice(n->range, "EmitIR: for-init is not a DeclStmt")
            }

            if !isa<VariableDecl>(ds->decl) {
                self._ice(n->range, "EmitIR: for-init is not a variable")
            }

            self._in_for_init = true
            self._var_decl(cast<VariableDecl>(ds->decl))
            self._in_for_init = false
        }

        self._cg->sink->spell(n->range, ";")
        if n->cond != &null {
            self.emit(n->cond)
        }

        self._cg->sink->spell(n->range, ";")
        if n->update != &null {
            var unsafe *saved_stmt = self._stmt_node
            self._stmt_node = n->update
            self.emit(n->update)
            self._stmt_node = saved_stmt
        }

        self._cg->sink->spell(n->range, ")")
        self.emit_block(n->body)
    }
}
