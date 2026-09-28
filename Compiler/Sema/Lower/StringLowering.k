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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Lexer::Immediate::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_StringLowering ASTWriter<StringLowering>
");

class StringLowering derives ASTWriter::<StringLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn StringLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_StringLowering::run(self.sc->tu);
    }

    fn transform_string_literal_expr(self, n: *StringLiteralExpr) -> *Expr {
        var out = ASTWriter_StringLowering::transform_string_literal_expr(n);
        ICE_IF(n->is_format(), "StringLowering: f-string survived FStringLowering; check Sema::_stage_lowerings order");
        if n->is_poisoned() || (n->imm == &null) { return out; }
        if (n->type_ == &null) || (!self.tu.is_string(n->type_)) { return out; }   // a minted byte literal.
        ICE_IF(n->string_ctor == &null, "StringLowering: literal with no constructor bound; LiteralTyping must bind it");

        var bytes = vec::<u8>();
        self._collect(n, &bytes);
        var cp = LowerSynth::cp_count(&bytes);

        var u8t  = self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST());
        var pu8  = self.sc->types->pointer(u8t);
        var lit  = self.synth.bytes_literal(n->range, &bytes, pu8);
        var data = self.synth.cast_to(n->range, lit, pu8, CastMode::Unsafe);   // `"..."` is const char*; the parameter is const unsigned char*.

        var args = self.list_builder::<*Expr>();
        args.push(data);
        args.push(self.synth.int_literal(n->range, static_cast::<u64>(bytes.size()), BuiltinKind::USize));
        args.push(self.synth.int_literal(n->range, static_cast::<u64>(cp), BuiltinKind::USize));
        return self.synth.ctor_call(n->range, n->string_ctor, to_string(WellKnownType::String), &args, n->type_);
    }

    /// The literal's decoded bytes: its own body, then every chained part.
    /// A segment with owned text (stringify!, file!) is already decoded.
    priv fn _collect(self, n: *StringLiteralExpr, out: *vec::<u8>) {
        var tbl = self.sc->imm_table();
        var seg = n->imm;
        var raw = n->is_raw();
        while seg != &null {
            if seg->has_owned_text() {
                for var i: usize = 0; i < static_cast::<usize>(seg->owned_len); ++i { out->push_back(seg->owned_ptr[i]); }
            } else {
                ICE_IF(!self.synth.decode_text(seg->body, raw, out),
                    "StringLowering: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step");
            }
            if seg->next == u32(-1) { break; }
            seg = tbl->get::<Immediate::StringData>(seg->next);
            raw = (static_cast::<u8>(seg->prefix_kind) & static_cast::<u8>(Immediate::TextPrefixKind::Raw)) != 0;
        }
        n->imm->next = u32(-1);   // one literal now; the chain is spent.
    }
}

__inline_cpp("
#undef ASTWriter_StringLowering
");