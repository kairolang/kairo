/// --- The Kairo Project ------------------- Codegen/Emit/EmitStmts.k ----- ///
///
///   \brief Statement emission. M2 scope: compound blocks, return, expression
///          statements, and local variable declarations.
///
///   \par Synthesized punctuation
///     Kairo elides the statement terminator and CompoundStmt does not retain
///     its braces. Both are structural: the node kind alone says a `;` or a
///     `{` is required, there is nothing to look up and nothing to decide.
///
///     Anchoring is the part that matters. `{` borrows the FIRST byte of the
///     block, `}` and `;` the LAST. Using one anchor for both put the `{`
///     caret on the closing brace   a location bug that no test would have
///     caught until a real diagnostic pointed at the wrong end of a function.
///
///   Import law: CodegenContext only. Reach the sink through cg->sink.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::Emit::EmitExprs::*;
import Codegen::Emit::EmitTypes::*;
import AST::Node::Base::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Kind::DeclKind::*;
import Location::SourceRange::*;

class EmitStmts {
    priv var _cg:    obs::<CodegenContext>;
    priv var _exprs: EmitExprs;
    priv var _types: EmitTypes;

    default fn EmitStmts(self);

    fn EmitStmts(self, cg: *CodegenContext) {
        self._cg    = cg;
        self._exprs = EmitExprs(cg);
        self._types = EmitTypes(cg);
    }

    fn emit(self, s: *Stmt) {
        std::ICE(s != &null, "EmitStmts: null stmt reached codegen");

        switch s->kind {
            case StmtKind::CompoundStmt {
                self.emit_block(cast::<CompoundStmt>(s));
            }
            case StmtKind::ReturnStmt {
                self._return(cast::<ReturnStmt>(s));
            }
            case StmtKind::ExpressionStmt {
                var n = cast::<ExpressionStmt>(s);
                self._exprs.emit(n->expr);
                self._cg->sink->synth_at_end(n->range, clang::tok::semi);
            }
            case StmtKind::DeclStmt {
                self._decl(cast::<DeclStmt>(s));
            }
            default {
                std::ICE(false, "EmitStmts: statement kind not supported at M2");
            }
        }
    }

    /// `{ ... }`.
    fn emit_block(self, n: *CompoundStmt) {
        std::ICE(n != &null, "EmitStmts: null block reached codegen");

        self._cg->sink->synth_at_start(n->range, clang::tok::l_brace);

        for var i: usize = 0; i < n->body.size(); ++i {
            self.emit(*(n->body.get(i)));
        }

        self._cg->sink->synth_at_end(n->range, clang::tok::r_brace);
    }

    /// Statement-position declarations. Local variables live HERE, not in
    /// EmitDecls, and that is a deliberate split rather than a convenience:
    ///
    ///   - EmitDecls already imports EmitStmts to emit function bodies.
    ///     Routing DeclStmt back into EmitDecls would close a mutual import
    ///     between the two busiest emitters   the exact cycle-hub shape the
    ///     layer rules exist to prevent.
    ///   - The jobs genuinely differ. A local is `T name = init;` in statement
    ///     position. A namespace-scope variable carries storage class,
    ///     linkage, and initialization-order concerns that have nothing to do
    ///     with this code and belong in EmitDecls when they land.
    ///
    /// They share a spelling today. They are not the same emission.
    priv fn _decl(self, n: *DeclStmt) {
        std::ICE(n->decl != &null, "EmitStmts: DeclStmt with no decl");

        switch n->decl->kind {
            case DeclKind::VariableDecl {
                self._var_decl(cast::<VariableDecl>(n->decl));
            }
            default {
                std::ICE(false,
                    "EmitStmts: only variable declarations are emittable in "
                    "statement position at M2");
            }
        }

        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
    }

    /// `[const|static] TYPE name [= init]`   no trailing `;`, _decl adds it.
    ///
    /// \par The `auto` caveat, which is a real bug and not a TODO
    ///   A null `type_` means "deduced from the initializer", and `auto` is
    ///   the C++ spelling of exactly that. Structurally this is sound.
    ///
    ///   Semantically it is NOT equivalent yet. For `var x = 10` the Kairo
    ///   lexer types the literal `i8` (see --print-tokens); C++ `auto` deduces
    ///   `int`. Same source, different type, silently. Nothing in codegen can
    ///   fix that   picking the type is what sema does.
    ///
    ///   TODO(sema): once type resolution runs, `type_` is never null on a
    ///   checked tree and this path becomes unreachable for real code. Until
    ///   then M2 emits a program whose locals are wider than Kairo says they
    ///   are. Acceptable only because M2's goal is proving the token stream
    ///   and the caret pipeline, not running the output.
    priv fn _var_decl(self, n: *VariableDecl) {
        std::ICE(n->kind != DeclKind::RecoveryDecl,
            "EmitStmts: poisoned VariableDecl reached codegen   sema gate failure");

        var sink = self._cg->sink;

        // Storage class. `eval` is C++ constexpr; Kairo's `const` is a
        // binding-level immutability, which top-level const models closely
        // enough for a local. All three are node-FIELD determined, which is
        // what makes them codegen's to emit.
        switch n->storage {
            case StorageClass::Const  { sink->kw_const(n->name);     }
            case StorageClass::Static { sink->kw_static(n->name);    }
            case StorageClass::Eval   { sink->kw_constexpr(n->name); }
            default { /* Var: no C++ qualifier */ }
        }

        if n->type_ != &null {
            self._types.emit(n->type_);
        } else {
            sink->kw_auto(n->name);
        }

        sink->create(n->name);

        // Kairo writes the `=` but VariableDecl does not retain the token, so
        // it is synthesized against the end of the name   a diagnostic about
        // the initialization then blames the variable, which is where a C++
        // user would look.
        if n->init != &null {
            sink->synth_at_end(n->name.range, clang::tok::equal);
            self._exprs.emit(n->init);
        }
    }

    /// `return [expr];`
    ///
    /// The `return` keyword borrows the first six bytes of the statement's
    /// range. That is correct only because the Kairo keyword is also spelled
    /// `return` and is also six bytes   a coincidence the code should not be
    /// relying on.
    ///
    /// TODO(ast): ReturnStmt must retain its keyword Token. Then this is
    /// kw_return(n->kw_token) and the span is a fact rather than an
    /// assumption. Same fix applies to every keyword-led statement node as
    /// EmitStmts grows.
    priv fn _return(self, n: *ReturnStmt) {
        // Six bytes at the start of the statement: Kairo's `return` keyword.
        // Correct only because Kairo spells it `return` too. See the TODO
        // above   with the token retained this is kw_return(n->kw_token) and
        // the span becomes a fact instead of an assumption.
        self._cg->sink->synth(
            SourceRange::from_bounds(n->range.start, u32(6)),
            clang::tok::kw_return);

        if n->value != &null {
            self._exprs.emit(n->value);
        }

        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
    }
}
