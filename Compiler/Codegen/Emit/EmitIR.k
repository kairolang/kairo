/// --- The Kairo Project ---------------------- Codegen/Emit/EmitIR.k ----- ///
///
///   \brief The M2 emitter. Declarations, statements, expressions, and types
///          in one class, because they are not four independent walks   they
///          are one recursive descent over the tree that happens to change
///          node category at every level. A function's body is statements; a
///          statement is expressions and a type; an expression's call target
///          re-enters the same dispatch a declaration started at. Splitting
///          that into four classes only worked while none of them needed to
///          call sideways, and M3 already doesn't hold: default arguments put
///          an EmitExprs call inside decl emission, `sizeof`-in-type-position
///          puts an expression inside a type, and neither used to be
///          reachable from where it was needed without threading a borrowed
///          instance through a constructor. One class, four `emit` overloads
///          resolved by parameter type (Decl* / Stmt* / Expr* / Type*),
///          arbitrary cross-calls, no plumbing.
///
///   \par THE reorder
///     Kairo:  fn main() -> i32 { ... }
///     C++:    int main() { ... }
///
///     The return type moves from trailing position to leading and `fn`
///     vanishes. This is codegen's job and not sema's, because it is not a
///     translation of anything   nothing is renamed, nothing is chosen,
///     nothing can fail. It is the C++ surface syntax for a FunctionDecl. It
///     is also why codegen cannot be a linear walk of the token stream, which
///     is the entire reason this layer exists.
///
///     Location consequence: the leading return type borrows the Kairo RETURN
///     TYPE's span (`i32` at offset 13), not `fn`'s. A diagnostic about the
///     return type then blames `i32`, which is what the user wrote. Emitting
///     it at `fn`'s offset would blame two bytes that mean something else.
///
///   \par What this emitter refuses
///     Operators, generics, and an absent return type are all ICEs, and none
///     of them are "M3 emitter work". They are things Lower/ must resolve
///     before codegen sees the tree:
///
///       - `fn op +`     -> a FunctionDecl whose name Token is the interned
///                          `operator+`, borrowing the op token's span.
///       - `fn op in`    -> TWO FunctionDecls named `begin` and `end`. One
///                          Kairo decl becoming two C++ decls is a tree
///                          transformation; codegen emits decls, it does not
///                          invent them.
///       - `fn Foo(self)` in `class Foo` -> ctor form. Recognizing it needs
///                          the enclosing type, which is name lookup.
///       - no return type -> Lower/ materializes the void type node. Codegen
///                          inferring `void` from a null pointer is inference,
///                          and inference is sema.
///
///     Every one of those is a decision with a wrong answer available. This
///     file has no way to produce a diagnostic when it guesses wrong, so it
///     does not guess.
///
///   \par Literals are emitted verbatim
///     An integer literal is emitted as the bytes the user wrote. No
///     separator stripping, no suffix rewriting, no canonicalization.
///
///     That work is real and it has to happen somewhere   `1_000_000u32` is
///     not valid C++   but it needs the literal's semantic value and its
///     resolved type to decide the target spelling, and it can OVERFLOW,
///     which means it can diagnose. Sema's Lower/ stage does it and stamps
///     the canonical text on the node.
///
///     When that lands, the emitter reads the stamped spelling and routes it
///     through TokenSink::create_int. It still will not compute
///     one. The arena/ExpansionLoc plumbing behind that call is location
///     machinery and stays here; the DECISION never does.
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
///   \par There is no builtin table here, on purpose
///     `i32` is emitted as `i32`. If the C++ output needs `::kairo::i32`,
///     Sema's Lower/ stage rewrites the ChainType into three segments   a
///     leading `::`, `kairo`, `i32`   interning the new identifiers and
///     stamping each with the ORIGINAL `i32` token's range. Codegen then
///     emits exactly what it is handed and the carets still land on the four
///     bytes the user typed.
///
///     Codegen cannot own that mapping. Deciding `i32` is a builtin means
///     deciding it was not shadowed, not aliased, not a user type in scope
///     that happens to share the spelling. That is name lookup. Name lookup
///     is sema, it needs scopes and diagnostics, and it can FAIL   and there
///     is no such thing as a codegen error.
///
///     A name table in this file was the seed of every Stage 0 layer
///     violation. It is not coming back.
///
///   Import law: CodegenContext only. Reach the sink through cg->sink. An
///   `ffi "c++" import "clang/..."` appearing here is a layer-fusion bug;
///   clang::tok is visible transitively through calls into the sink.
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
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Types::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::StmtKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define sink this->_cg->sink
");

class EmitIR {
    priv var _cg: obs::<CodegenContext>;

    fn EmitIR(self, cg: *CodegenContext) {
        self._cg = cg;
    }

    // ----------------------------------------------------------------- //
    // Declarations
    // ----------------------------------------------------------------- //

    fn emit(self, d: *Decl) {
        ICE_IF(d == &null, "EmitIR: null decl reached codegen");
        ICE_IF(d->kind == DeclKind::RecoveryDecl,
            "EmitIR: poisoned node reached codegen   sema gate failure");

        switch d->kind {
            case DeclKind::FunctionDecl { self._fn(cast::<FunctionDecl>(d)); }
            default {
                ICE_FAIL("EmitIR: decl kind not supported at M2");
            }
        }
    }

    priv fn _param_decl(self, p: *ParamDecl) {
        // C++ forms:
        //   - `T name`  (no default)
        //   - `T name = default`  (with default)
        //   - `T` (no name, fwd decl only)
        //
        // class ParamDecl derives Decl {
        //     pub var name:        Token;            ///< parameter name.
        //     pub var type_:       *Type;            ///< declared type (never inferred for params).
        //     pub var default_val: *Expr = &null;    ///< default value expr; null if none.
        //     pub var is_self:     bool = false;     ///< true for the `self` parameter.
        //     pub var is_const:    bool = false;     ///< true for the `const` parameter.
        //     pub var index:       u32 = 0;          ///< position in the parameter list.
        //     pub var unname:      bool = false;     ///< true for the `unnamed` parameter.
        
        if p->is_self {
            ICE_FAIL("EmitIR::_param_decl: self param reached codegen");
            return;  // `self` is not emitted, it is a semantic placeholder only.
        }

        if p->is_const {
            sink->kw_const(p->name);
        }

        if p->type_ != &null {
            self.emit(p->type_);
        } else {
            ICE_FAIL("EmitIR::_param_decl: parameter with no type reached codegen; Lower/ must materialize the explicit type node");
            return;
        }

        if !p->unname {
            sink->create(p->name);
        }

        if p->default_val != &null {
            sink->synth_at_end(p->name.range, clang::tok::equal);
            self.emit(p->default_val);
        }
    }

    priv fn _param_list(self, pl: FrozenList::<*ParamDecl>) {
        for var i: usize = 0; i < pl.size(); ++i {
            var p = pl.get(i);
            if p == &null {
                ICE_FAIL("EmitIR::_param_list: null param reached codegen");
                continue;
            }
            
            self._param_decl(*p);
            if i + 1 < pl.size() {
                sink->synth_at_end((*p)->name.range, clang::tok::comma);
            }
        }
    }

    priv fn _fn_fwd(self, n: *FunctionDecl) {
        ICE_IF(n->is_operator,
            "EmitIR: operator decl reached codegen; Lower/ must rewrite it "
            "into a plain FunctionDecl carrying its C++ name");
        ICE_IF(!n->generic_params.is_empty(),
            "EmitIR: generic function reached codegen; Lower/ must "
            "monomorphize or emit the template form");
        ICE_IF(n->return_type == &null,
            "EmitIR: function with no return type reached codegen; Lower/ "
            "must materialize the explicit type node   codegen does not infer");

        self.emit(n->return_type);
        sink->create(n->name);
        sink->synth_at_end(n->name.range, clang::tok::l_paren);
        self._param_list(n->params);
        sink->synth_at_end(n->name.range, clang::tok::r_paren);
        sink->synth_at_end(n->name.range, clang::tok::semi);
    }

    /// `fn NAME(params) -> RET { body }`  ->  `RET NAME(params) { body }`
    priv fn _fn(self, n: *FunctionDecl) {
        ICE_IF(n->is_operator,
            "EmitIR: operator decl reached codegen; Lower/ must rewrite it "
            "into a plain FunctionDecl carrying its C++ name");
        ICE_IF(!n->generic_params.is_empty(),
            "EmitIR: generic function reached codegen; Lower/ must "
            "monomorphize or emit the template form");
        ICE_IF(n->return_type == &null,
            "EmitIR: function with no return type reached codegen; Lower/ "
            "must materialize the explicit type node   codegen does not infer");

        if n->body_kind == FnBodyKind::None {
            self._fn_fwd(n);
            return;
        }

        /* T  */ self.emit(n->return_type);
        /* i  */ sink->create(n->name);
        /* (  */ sink->synth_at_end(n->name.range, clang::tok::l_paren);
        /* T, */ self._param_list(n->params);
        /* )  */ sink->synth_at_end(n->name.range, clang::tok::r_paren);
        /* {} */ self.emit_block(n->body_block);
    }

    // ----------------------------------------------------------------- //
    // Statements
    // ----------------------------------------------------------------- //

    fn emit(self, s: *Stmt) {
        ICE_IF(s == &null, "EmitIR: null stmt reached codegen");

        switch s->kind {
            case StmtKind::CompoundStmt {
                self.emit_block(cast::<CompoundStmt>(s));
            }
            case StmtKind::ReturnStmt {
                self._return(cast::<ReturnStmt>(s));
            }
            case StmtKind::ExpressionStmt {
                var n = cast::<ExpressionStmt>(s);
                self.emit(n->expr);
                sink->synth_at_end(n->range, clang::tok::semi);
            }
            case StmtKind::DeclStmt {
                self._decl(cast::<DeclStmt>(s));
            }
            default {
                ICE_FAIL("EmitIR: statement kind not supported at M2");
            }
        }
    }

    /// `{ ... }`.
    fn emit_block(self, n: *CompoundStmt) {
        ICE_IF(n == &null, "EmitIR: null block reached codegen");

        sink->synth_at_start(n->range, clang::tok::l_brace);

        for var i: usize = 0; i < n->body.size(); ++i {
            self.emit(*(n->body.get(i)));
        }

        sink->synth_at_end(n->range, clang::tok::r_brace);
    }

    /// Statement-position declarations. Local variables are dispatched HERE,
    /// not from the top-level `emit(*Decl)` switch, and that is a deliberate
    /// split rather than a leftover from the old file boundary:
    ///
    ///   - A local is `T name = init;` in statement position. A
    ///     namespace-scope variable carries storage class, linkage, and
    ///     initialization-order concerns that have nothing to do with this
    ///     code and belong in the decl-emission section above when they land.
    ///
    /// They share a spelling today. They are not the same emission.
    priv fn _decl(self, n: *DeclStmt) {
        ICE_IF(n->decl == &null, "EmitIR: DeclStmt with no decl");

        switch n->decl->kind {
            case DeclKind::VariableDecl {
                self._var_decl(cast::<VariableDecl>(n->decl));
            }
            default {
                ICE_FAIL("EmitIR: only variable declarations are emittable in "
                    "statement position at M2");
            }
        }

        sink->synth_at_end(n->range, clang::tok::semi);
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
        ICE_IF(n->kind == DeclKind::RecoveryDecl,
            "EmitIR: poisoned VariableDecl reached codegen   sema gate failure");

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
            self.emit(n->type_);
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
            self.emit(n->init);
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
    /// this emitter grows.
    priv fn _return(self, n: *ReturnStmt) {
        // Six bytes at the start of the statement: Kairo's `return` keyword.
        // Correct only because Kairo spells it `return` too. See the TODO
        // above   with the token retained this is kw_return(n->kw_token) and
        // the span becomes a fact instead of an assumption.
        sink->synth(
            SourceRange::from_bounds(n->range.start, u32(6)),
            clang::tok::kw_return);

        if n->value != &null {
            self.emit(n->value);
        }

        sink->synth_at_end(n->range, clang::tok::semi);
    }

    // ----------------------------------------------------------------- //
    // Expressions
    // ----------------------------------------------------------------- //

    fn emit(self, e: *Expr) {
        ICE_IF(e == &null, "EmitIR: null expr reached codegen");

        switch e->kind {
            case ExprKind::IntegerLiteralExpr {
                // Borrowed literal: the span IS the spelling, so synth
                // satisfies the literal rule for free. A literal whose C++
                // text differs from its source bytes is Lower/'s to
                // canonicalize, and arrives here via create_int.
                sink->synth(
                    cast::<IntegerLiteralExpr>(e)->token,
                    clang::tok::numeric_constant);
            }
            case ExprKind::NamedIdentExpr {
                sink->create(cast::<NamedIdentExpr>(e)->name);
            }
            case ExprKind::BinaryOperatorExpr {
                self._binary(cast::<BinaryOperatorExpr>(e));
            }
            case ExprKind::CallExpr {
                self._call(cast::<CallExpr>(e));
            }
            case ExprKind::StringLiteralExpr {
                self._string(cast::<StringLiteralExpr>(e));
            }
            default {
                ICE_FAIL("EmitIR: expression kind not supported at M2");
            }
        }
    }

    priv fn _string(self, n: *StringLiteralExpr) {
        ICE_IF(n->kind == ExprKind::RecoveryExpr,
            "EmitIR: poisoned StringLiteralExpr reached codegen   sema gate failure");

        var final_str = std::string_to_nstring(n->get_spelling());

        if n->has_next() {
            ICE_FAIL("EmitIR: multi-part string literal reached codegen; Lower/ must concatenate it into a single literal");
        }

        sink->create_str(n->token, final_str);
    }

    /// `lhs op rhs`. The operator token is emitted through punct_kind, which
    /// is a 1:1 lexical map   an unmapped kind means Lower/ left a Kairo-only
    /// operator in the tree and CodegenContext ICEs there, not here.
    priv fn _binary(self, n: *BinaryOperatorExpr) {
        self.emit(n->lhs);
        sink->create(n->op_token);
        self.emit(n->rhs);
    }

    /// `callee(a, b)`. CallExpr does not retain its paren or comma tokens, so
    /// all three families are synthesized: `(` against the first byte of the
    /// call, each `,` against the last byte of the argument it follows, `)`
    /// against the last byte of the call. Every synthesized caret then sits
    /// inside the construct a C++ user would expect it to blame.
    priv fn _call(self, n: *CallExpr) {
        self.emit(n->callee);
        sink->synth_at_end(n->callee->range, clang::tok::l_paren);

        for var i: usize = 0; i < n->args.size(); ++i {
            if i > 0 {
                sink->synth_at_end((*(n->args.get(i - 1)))->range, clang::tok::comma);
            }
            self.emit(*(n->args.get(i)));
        }

        sink->synth_at_end(n->range, clang::tok::r_paren);
    }

    // ----------------------------------------------------------------- //
    // Types
    // ----------------------------------------------------------------- //

    /// Emit \p t in type position.
    ///
    /// ChainType is the only kind codegen handles and, by design, close to
    /// the only kind that should ever reach it: pointers, arrays, nullable,
    /// and function types are Kairo spellings of C++ constructs, so Lower/
    /// reduces them to their codegen-shaped form. A kind landing in the
    /// default arm is a missing lowering, not a missing emitter case.
    fn emit(self, t: *Type) {
        ICE_IF(t == &null, "EmitIR: null type reached codegen");

        switch t->kind {
            case TypeKind::ChainType { self._chain(cast::<ChainType>(t)); }
            case TypeKind::PointerType { self._pointer(cast::<PointerType>(t)); }
            default {
                ICE_FAIL(f"EmitIR: {to_string(t->kind)} type reached codegen; Lower/ must "
                    "reduce it to its codegen-shaped form");
            }
        }
    }

    /// `a::b::C`   emit each segment's identifier, prefixed by `::` when the
    /// segment carries that separator. A leading `::` (global scope) is
    /// segment 0 with sep == ColonColon and falls out of the same loop.
    ///
    /// The `::` borrows the FIRST byte of the segment's range, which covers
    /// the separator, so the caret lands on the separator itself.
    priv fn _chain(self, n: *ChainType) {
        ICE_IF(n->segments.is_empty(),
            "EmitIR: chain type with no segments reached codegen");

        for var i: usize = 0; i < n->segments.size(); ++i {
            var seg = n->segments.get(i);

            ICE_IF(seg->name == &null,
                "EmitIR: chain segment with no identifier reached codegen");
            ICE_IF(!seg->generic_args.is_empty(),
                "EmitIR: generic arguments in type position are M3");

            if seg->sep == ChainType::SegmentSeparator::ColonColon {
                sink->synth_at_start(
                    seg->range, clang::tok::coloncolon);
            }

            // create() ICEs on a keyword token, which is the sema gate: a
            // primitive type name (`void`, `i32`) is a Kairo KEYWORD and has
            // no automatic C++ meaning. Lower/ rewrites those into identifier
            // chains   `i32` is an alias to `int32_t` in the runtime   and
            // codegen emits whatever names it is handed.
            sink->create(seg->name->name);
        }
    }

    priv fn _pointer(self, n: *PointerType) {
        self.emit(n->pointee);
        sink->synth_at_end(n->range, clang::tok::star);
    }
}

__inline_cpp("
#undef sink
");