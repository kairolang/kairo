/// --- The Kairo Project ------------------- AST/CodeCompleteConsumer.k --- ///
///
///   Abstract callback invoked by the parser at cursor-relevant positions
///   during completion or signature-help requests. Null for batch compile.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------------- ///

import Location::SourceRange::*;
import AST::Node::Base::*;
import AST::Context::DeclContext::*;
import AST::Context::ASTContext::*;

enum CompletionContextKind derives u8 {
    TopLevel,         // start of a top-level decl
    StmtStart,        // start of a statement
    ExprStart,        // start of an expression
    MemberAccess,     // after `.` on a value
    QualifiedName,    // after `::` on a scope
    TypeRef,          // type position
    CallArg,          // inside call args
    GenericArg,       // inside <...> after a generic type/fn
    PatternBinding,   // in a pattern position
    AttributeName,    // after `@`
}

class CodeCompleteConsumer {
    pub var cursor_loc: SourceLocation;

    /// Generic hook fired when parser reaches completion position.
    /// Concrete consumers override with their own logic.
    virtual fn on_completion(self, kind: CompletionContextKind, dc: *DeclContext) {
        // default: no-op. override in subclass.
    }

    /// Member-access variant: parser has parsed `base` and seen `.` at cursor.
    virtual fn on_member_access(self, base: *Expr, is_arrow: bool) { }

    /// Qualified-name variant: parser has parsed `scope` and seen `::` at cursor.
    virtual fn on_qualified_name(self, scope: *ScopeNode) { }

    /// Signature-help variant: parser is inside a call, knows callee and arg index.
    virtual fn on_signature_help(self, callee: *Expr, arg_index: u32) { }
}