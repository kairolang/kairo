/// --- The Kairo Project ----------------------- Sema/Verify/TerminatorCheck.k --- ///
///
///   \brief Warn on statements lexically after a terminator in the same
///          block.
///
///   \detail
///     Terminators: return, break, continue, panic, jump!. Anything after
///     one of these in the SAME CompoundStmt cannot execute with one
///     exception: a `label!` intrinsic is a jump target, so it (and
///     everything after it) is reachable via `jump!`. A label therefore
///     ends the dead region and suppresses the warning.
///
///     What this is NOT: reachability analysis. `if c { return } else
///     { return } x();`
///
///   Phase: VERIFY (pre-N)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Diagnostic::Registry::*;

class TerminatorCheck derives RecursiveASTVisitor::<TerminatorCheck> {
    pub var sc: *SemaContext;

    fn TerminatorCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        
        if tu == &null { return; }
        if tu->program == &null { return; }
        
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { 0; }
            }
        }
    }

    priv fn _is_terminator(self, s: *Stmt) -> bool {
        switch s->kind {
            case StmtKind::ReturnStmt        { return true;  }
            case StmtKind::BreakStmt         { return true;  }
            case StmtKind::ContinueStmt      { return true;  }
            case StmtKind::PanicStmt         { return true;  }
            case StmtKind::JumpIntrinsicStmt { return true;  }
            default                          { return false; }
        }
    }

    fn visit_compound_stmt(self, n: *CompoundStmt) -> bool {
        var dead: bool = false;
        for var i: usize = 0; i < n->body.size(); ++i {
            var s = *(n->body.get(i));
            if s == &null { continue; }

            if dead {
                if s->kind == StmtKind::LabelIntrinsicStmt {
                    dead = false;
                    continue;
                }

                self.sc->diag->report(DiagID::SC001W, s->range.start,
                    "unreachable code; the statement above always transfers "
                    "control out of this block"
                ).first(s->range).emit();
                
                while (i + 1) < n->body.size() {
                    var nx = *(n->body.get(i + 1));
                    if (nx != &null) && (nx->kind == StmtKind::LabelIntrinsicStmt) {
                        break;
                    }
                    ++i;
                }

                continue;
            }

            if self._is_terminator(s) {
                dead = true;
            }
        }
        
        return true;
    }
}
