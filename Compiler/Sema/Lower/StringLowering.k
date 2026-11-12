/// --- The Kairo Project ------------------ Sema/Lower/StringLowering.k --- ///
///
///   \brief Every `string` literal becomes the borrowed constructor call it is.
///
///   \detail
///       "hi"                 ->  string("hi" as unsafe *const u8, 2, 2)
///       "Hello, Kairo! 📣"   ->  string("Hello, Kairo! \360\237\223\243" as unsafe *const u8, 17, 15)
///       "a" "b"              ->  string("ab" as unsafe *const u8, 2, 2)
///
///     The bytes are decoded HERE, once: every escape the lexer accepts, into
///     UTF-8; adjacent parts concatenated; the chain cleared. `len` counts
///     bytes, `cp_len` codepoints; `cap` is 0, the borrow flag, because the
///     bytes are a C++ literal in static storage. The constructor is the one
///     X bound (`string_ctor`); nothing is looked up.
///
///     A literal C++ reads at compile time (StringLiteralExpr::const_eval,
///     Compiler/Spec/Eval.md#strings-at-compile-time) passes its bytes uncast: EmitIR spells them as
///     `__kairo_estr<...>`, a `const unsigned char` array.
///
///     A literal CallTyping marked as a C string argument
///     (StringLiteralExpr::c_string) becomes the bytes alone:
///       strlen("ab")         ->  strlen("ab")
///
///     Only a literal typed `string` is rewritten. The byte literals this
///     pass and FStringLowering mint are pointer-typed and pass through to
///     EmitIR, which spells them from their bytes.
///
///   \par Postcondition
///     No StringLiteralExpr typed `string` reaches codegen, and no f-string
///     reaches THIS pass: FStringLowering ran first, and one arriving here is
///     a schedule bug, never data.
///
///   Phase: LOWER, last. A literal is pure until it is a constructor call;
///   after SequenceLowering, so no `"hi"` argument is hoisted into a local.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Kind::ExprKind::to_string
import AST::LangItems::{
    WellKnownType,
    to_string,
}
import AST::Node::Base::Expr
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    QUAL_CONST,
    canon_unqual,
}
import AST::Node::Casting::cast
import AST::Node::Declarations::FunctionDecl
import AST::Node::Expressions::CastMode
import AST::Node::PrimaryExpressions::StringLiteralExpr
import AST::Visitor::ASTWriter::ASTWriter
import Lexer::Immediate::Immediate
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

pub class StringLowering derives ASTWriter<StringLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn StringLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::String)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<StringLowering>::run(self, self.sc->tu)
    }

    fn transform_string_literal_expr(self, n: unsafe *StringLiteralExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<StringLowering>::transform_string_literal_expr(
            self,
            n,
        )

        if n->is_format() {
            kairo::std::ice_fail(
                "StringLowering: f-string survived FStringLowering; check Sema::_stage_lowerings order",
            )
        }

        if n->is_poisoned() || n->imm == &null {
            return out
        }

        if n->udl_op != &null && n->type_ != &null {
            // Typed as the operator's result, not `string`: the early return
            // below would leave a literal in codegen.
            var bytes = cxx::std::vector<u8>()
            self._collect(n, unsafe &bytes)
            return self._udl_call(n, unsafe &bytes)
        }

        if n->type_ == &null || !self.tu.is_string(n->type_) { // a minted byte literal.
            return out
        }

        if n->string_ctor == &null {
            kairo::std::ice_fail(
                "StringLowering: literal with no constructor bound; LiteralTyping must bind it",
            )
        }

        var bytes = cxx::std::vector<u8>()
        self._collect(n, unsafe &bytes)
        var cp = LowerSynth::cp_count(bytes)

        var unsafe *u8t = self.sc->types->qualified(
            self.sc->builtin(BuiltinKind::U8),
            QUAL_CONST,
        )

        var unsafe *pu8 = self.sc->types->pointer(u8t)

        // A literal at a C string parameter: the static bytes ARE
        // the argument, and no string is made. `"..."` is C++'s `const
        // char *`, which a `c_char` target is; a `*const u8` one is the
        // same cast the constructor's `data` takes.
        if n->c_string != &null {
            var unsafe *ct = n->c_string
            if self.tu.is_builtin(
                canon_unqual(self.tu.pointee(ct)),
                BuiltinKind::CChar,
            ) {
                return self.synth.bytes_literal(n->range, unsafe &bytes, ct)
            }

            return self.synth.cast_to(
                n->range,
                self.synth.bytes_literal(n->range, unsafe &bytes, pu8),
                ct,
                CastMode::Unsafe,
            )
        }

        var unsafe *lit = self.synth.bytes_literal(n->range, unsafe &bytes, pu8)
        var unsafe *data = lit
        if n->const_eval {
            // C++ reads it at compile time (Compiler/Spec/Eval.md#strings-at-compile-time): the bytes become
            // `__kairo_estr<...>`, already `const unsigned char`, and the
            // literal constructor is constexpr. No cast, which a constant
            // expression could not contain.
            cast<StringLiteralExpr>(lit)->const_eval = true
            self.sc->tu->has_eval_string             = true
        } else {
            data = self.synth.cast_to(n->range, lit, pu8, CastMode::Unsafe) // `"..."` is const char*; the parameter is const unsigned char*.
        }

        var args = self.list_builder<unsafe *Expr>()
        args.push(data)
        args.push(
            self.synth.int_literal(
                n->range,
                bytes.size() as u64,
                BuiltinKind::USize,
            ),
        )

        args.push(
            self.synth.int_literal(n->range, cp as u64, BuiltinKind::USize),
        )

        return self.synth.ctor_call(
            n->range,
            n->string_ctor,
            to_string(WellKnownType::String),
            &args,
            n->type_,
        )
    }

    /// `operator""_x(<bytes>, <len>)`: C++'s own explicit spelling of what
    /// `"..."_x` means, so the emitter needs nothing new. The first parameter
    /// is the C string (`const char *`), cast as a C string argument is.
    priv fn _udl_call(self,
                      n:     unsafe *StringLiteralExpr,
                      bytes: unsafe *cxx::std::vector<u8>) -> unsafe *Expr {
        var unsafe *f = cast<FunctionDecl>(n->udl_op)
        var unsafe *u8t = self.sc->types->qualified(
            self.sc->builtin(BuiltinKind::U8),
            QUAL_CONST,
        )

        var unsafe *pu8 = self.sc->types->pointer(u8t)
        var unsafe *pt  = f->params[0]->type_->canonical
        var unsafe *arg = self.synth.cast_to(
            n->range,
            self.synth.bytes_literal(n->range, bytes, pu8),
            pt,
            CastMode::Unsafe,
        )

        if self.tu.is_builtin(
            canon_unqual(self.tu.pointee(pt)),
            BuiltinKind::CChar,
        ) {
            arg = self.synth.bytes_literal(n->range, bytes, pt)
        }

        var args = self.list_builder<unsafe *Expr>()
        args.push(arg)
        args.push(
            self.synth.int_literal(
                n->range,
                bytes->size() as u64,
                BuiltinKind::USize,
            ),
        )

        return self.synth.free_call(n->range, n->udl_op, unsafe &args, n->type_)
    }

    /// The literal's decoded bytes: its own body, then every chained part.
    /// A segment with owned text (stringify!, file!) is already decoded.
    priv fn _collect(self, n: unsafe *StringLiteralExpr, out: unsafe *cxx::std::vector<u8>) {
        // The chain lives in the table that holds n->imm: the file that
        // wrote the literal, which for an imported macro's body is not this
        // one (the parser found it through get_payload_table). Following
        // `next` in ours read some other literal, or past the end (null).
        var unsafe *tbl = self.sc->imm_table()
        if n->ctx != &null {
            tbl = n->ctx->get_payload_table(n->token)
        }

        var unsafe *seg = n->imm
        var        raw  = n->is_raw()
        while seg != &null {
            if seg->has_owned_text() {
                for var i: usize = 0; i < (seg->owned_len as usize); ++i {
                    out->push_back(seg->owned_ptr[i])
                }
            } else {
                if !self.synth.decode_text(seg->body, raw, out) {
                    kairo::std::ice_fail(
                        "StringLowering: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step",
                    )
                }
            }

            if seg->next == u32::MAX {
                break
            }

            seg = tbl->get<Immediate::StringData>(seg->next)
            raw = seg->prefix_kind.has(Immediate::TextPrefixKind::Raw)
        }

        n->imm->next = u32::MAX // one literal now; the chain is spent.
    }
}
