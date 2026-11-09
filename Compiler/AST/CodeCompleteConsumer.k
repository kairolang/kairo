/// --- The Kairo Project ------------------- AST/CodeCompleteConsumer.k --- ///
///
///   Abstract callback invoked by the parser at cursor-relevant positions
///   during completion or signature-help requests. Null for batch compile.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------------- ///

import AST::Context::DeclContext::DeclContext
import AST::Context::DisambigTable::DisambigNode
import AST::Node::Base::Expr
import Location::SourceLocation::SourceLocation

pub enum CompletionContextKind derives u8 {
    TopLevel,       // start of a top-level decl
    StmtStart,      // start of a statement
    ExprStart,      // start of an expression
    MemberAccess,   // after `.` on a value
    QualifiedName,  // after `::` on a scope
    TypeRef,        // type position
    CallArg,        // inside call args
    GenericArg,     // inside <...> after a generic type/fn
    PatternBinding, // in a pattern position
    AttributeName,  // after `@`
}

pub class CodeCompleteConsumer {
    pub var cursor_loc: SourceLocation

    /// Generic hook fired when parser reaches completion position.
    /// Concrete consumers override with their own logic.
    pub virtual fn on_completion(self, kind: CompletionContextKind, dc: unsafe *DeclContext) {
        // default: no-op. override in subclass.
    }

    /// Member-access variant: parser has parsed `base` and seen `.` at cursor.
    pub virtual fn on_member_access(self, base: *Expr, is_arrow: bool) { }

    /// Qualified-name variant: parser has parsed `scope` and seen `::` at cursor.
    pub virtual fn on_qualified_name(self, scope: *DisambigNode) { }

    /// Signature-help variant: parser is inside a call, knows callee and arg index.
    pub virtual fn on_signature_help(self, callee: *Expr, arg_index: u32) { }
}
