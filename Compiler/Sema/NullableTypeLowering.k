/// --- The Kairo Project ------------------ Sema/NullableTypeLowering.k --- ///
///
///   \brief Lower T? -> std::Nullable<T> at type positions.
///
///   \detail
///     Type-level desugar. Distinct from the value-level nullable lowerings
///     below (??, ?, narrowed access).
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::Printer::PrintCore::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import Support::InternedStr::*;
import AST::Context::TranslationUnit::*;
import AST::Mixin::TypeQual::*;
import AST::Mixin::Annotation::*;
import AST::Visitor::RecursiveASTVisitor::*;
import AST::Visitor::ASTWriter::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import AST::Kind::StmtKind::*;
import AST::Kind::PatternKind::*;
import Token::TokenKind::*;

class NullableTypeLowering derives ASTWriter::<NullableTypeLowering> {
    fn transform_nullable_type(self, n: *NullableType) -> *Type {
        var inner = self.dyn()->transform_type(n->inner);

        // Build: std::Nullable::<inner>
        //
        // ChainType has segments: [std, Nullable<inner>]
        //   segment 0: name = "std",      generic_args = []
        //   segment 1: name = "Nullable", generic_args = [inner]

        var seg_buf = self.ctx->alloc_array::<ChainType::ChainSegment>(2);
        var std_t   = self.ctx->make_token(n->range, TokenKind::LitIdentifier, "std");

        // segment 0: "std"
        (seg_buf[0].name) = NamedIdentExpr::create(
            self.ctx, n->range, std_t
        );

        (seg_buf[0].generic_args) = create_empty_frozen_list::<ChainType::GenericArg>();
        var nullable_t = self.ctx->make_token(n->range, TokenKind::LitIdentifier, "Nullable");

        // segment 1: "Nullable" with generic arg
        (seg_buf[1].sep) = ChainType::SegmentSeparator::ColonColon;
        (seg_buf[1].name) = NamedIdentExpr::create(
            self.ctx, n->range, nullable_t
        );

        var arg = self.ctx->alloc::<ChainType::GenericArg>();
        arg->ty = inner;
        arg->name = &null;  // positional, not named

        var arg_frozen = FrozenList::<ChainType::GenericArg>{};
        arg_frozen.from_raw(arg, 1);

        seg_buf[1].generic_args = arg_frozen;

        // Build the ChainType
        var chain = ChainType::create(self.ctx, n->range);
        chain->segments.from_raw(seg_buf, 2);
        // chain->is_rooted = true;  // ::std::Nullable, global root

        return chain;
    }
}