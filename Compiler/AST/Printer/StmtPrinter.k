/// --- The Kairo Project --------------- Compiler/AST/StmtPrinter.k ----- ///
///
///   A simple pretty-printer for statement nodes. Companion to ExprPrinter
///   and TypePrinter; delegates expression and type children to them.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------- ///

import ASTNode::Base::*;
import ASTNode::Statements::*;
import ASTNode::PrimaryExpressions::*;
import ASTNode::Casting::*;
import AST::Printer::ExprPrinter::*;
import AST::Printer::TypePrinter::*;
import TokenKind::*;

class StmtPrinter {
    var _buf:    string;
    var _style:  PrintStyle;
    var _indent: u32;

    // -- Public entry point ------------------------------------------

    static fn print(stmt: *Stmt, style: PrintStyle = PrintStyle::Diagnostic) -> string {
        var p     = StmtPrinter{};
        p._style  = style;
        p._buf    = "";
        p._indent = 0;
        p._print(stmt);
        return p._buf;
    }

    // -- Indentation helpers -----------------------------------------

    priv fn _newline(self) {
        self._buf += "\n";
        for var i: u32 = 0; i < self._indent; ++i {
            self._buf += "  ";
        }
    }

    // -- Delegation helpers ------------------------------------------

    priv fn _expr(self, e: *Expr) {
        self._buf += ExprPrinter::print(e, self._style);
    }

    priv fn _type(self, t: *Type) {
        self._buf += TypePrinter::print(t, self._style);
    }

    // -- Binding helper (shared: destructure, for, context) ----------

    priv fn _print_binding(self, b: Binding) {
        if b.is_explicit {
            self._buf += ("const ") if (b.is_const) else ("var ");
        }
        var sh = static_cast::<u8>(b.shorthand);
        if (sh & static_cast::<u8>(BindingShorthand::Unsafe))   != 0 { self._buf += "unsafe "; }
        if (sh & static_cast::<u8>(BindingShorthand::Pointer))  != 0 { self._buf += "*"; }
        if b.is_discard {
            self._buf += "_";
        } else if b.name != &null {
            self._buf += ExprPrinter::tok_spelling(b.name->name);
        } else {
            self._buf += "<error>";
        }
        if (sh & static_cast::<u8>(BindingShorthand::Nullable)) != 0 { self._buf += "?"; }
    }

    priv fn _print_binding_list(self, bindings: FrozenList::<Binding>) {
        for var i: usize = 0; i < bindings.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print_binding(*(bindings.get(i)));
        }
    }

    // -- Core dispatch -----------------------------------------------

    priv fn _print(self, stmt: *Stmt) {
        if stmt == &null {
            self._buf += ("<null>") if (self._style == PrintStyle::Debug) else ("<error>");
            return;
        }

        if stmt->is_error() {
            self._print_recovery(stmt);
            return;
        }

        if isa::<CompoundStmt>(stmt)            { self._print_compound(cast::<CompoundStmt>(stmt));                       return; }
        if isa::<ExpressionStmt>(stmt)          { self._print_expr_stmt(cast::<ExpressionStmt>(stmt));                   return; }
        if isa::<DeclStmt>(stmt)                { self._print_decl_stmt(cast::<DeclStmt>(stmt));                         return; }
        if isa::<ReturnStmt>(stmt)              { self._print_return(cast::<ReturnStmt>(stmt));                          return; }
        if isa::<BreakStmt>(stmt)               { self._print_break(cast::<BreakStmt>(stmt));                            return; }
        if isa::<ContinueStmt>(stmt)            { self._print_continue(cast::<ContinueStmt>(stmt));                      return; }
        if isa::<PanicStmt>(stmt)               { self._print_panic(cast::<PanicStmt>(stmt));                            return; }
        if isa::<YieldStmt>(stmt)               { self._print_yield(cast::<YieldStmt>(stmt));                            return; }
        if isa::<RuntimeAssertStmt>(stmt)       { self._print_runtime_assert(cast::<RuntimeAssertStmt>(stmt));           return; }
        if isa::<StaticAssertStmt>(stmt)        { self._print_static_assert(cast::<StaticAssertStmt>(stmt));             return; }
        if isa::<LabelIntrinsicStmt>(stmt)      { self._print_label_intrinsic(cast::<LabelIntrinsicStmt>(stmt));         return; }
        if isa::<JumpIntrinsicStmt>(stmt)       { self._print_jump_intrinsic(cast::<JumpIntrinsicStmt>(stmt));           return; }
        if isa::<ConditionalStmt>(stmt)         { self._print_conditional(cast::<ConditionalStmt>(stmt));                return; }
        if isa::<WhileLoopStmt>(stmt)           { self._print_while(cast::<WhileLoopStmt>(stmt));                        return; }
        if isa::<LoopStmt>(stmt)                { self._print_loop(cast::<LoopStmt>(stmt));                              return; }
        if isa::<RangedForStmt>(stmt)           { self._print_ranged_for(cast::<RangedForStmt>(stmt));                   return; }
        if isa::<IndexedForStmt>(stmt)          { self._print_indexed_for(cast::<IndexedForStmt>(stmt));                 return; }
        if isa::<MatchStmt>(stmt)               { self._print_match(cast::<MatchStmt>(stmt));                            return; }
        if isa::<LabeledStmt>(stmt)             { self._print_labeled(cast::<LabeledStmt>(stmt));                        return; }
        if isa::<TryCatchStmt>(stmt)            { self._print_try_catch(cast::<TryCatchStmt>(stmt));                     return; }
        if isa::<FinallyStmt>(stmt)             { self._print_finally(cast::<FinallyStmt>(stmt));                        return; }
        if isa::<UnsafeBlockStmt>(stmt)         { self._print_unsafe_block(cast::<UnsafeBlockStmt>(stmt));               return; }
        if isa::<ContextBindingStmt>(stmt)      { self._print_context_binding(cast::<ContextBindingStmt>(stmt));         return; }
        if isa::<DestructuringDeclStmt>(stmt)   { self._print_destructure(cast::<DestructuringDeclStmt>(stmt));          return; }
        if isa::<InlineBlockStmt>(stmt)         { self._print_inline_block(cast::<InlineBlockStmt>(stmt));               return; }
        if isa::<EvalBlockStmt>(stmt)           { self._print_eval_block(cast::<EvalBlockStmt>(stmt));                   return; }

        self._buf += (f"<unknown stmt kind={static_cast::<u32>(stmt->kind)}>")
            if (self._style == PrintStyle::Debug)
            else "<error>";
    }

    // -- Recovery ----------------------------------------------------

    priv fn _print_recovery(self, stmt: *Stmt) {
        if self._style == PrintStyle::Debug {
            self._buf += f"<recovery:{static_cast::<u32>(stmt->recovery_kind)}>";
        } else {
            self._buf += "<error>";
        }
    }

    // -- Compound block ----------------------------------------------

    priv fn _print_compound(self, stmt: *CompoundStmt) {
        if stmt->body.is_empty() {
            self._buf += "{}";
            return;
        }

        self._buf += "{";
        self._indent += 1;
        for var i: usize = 0; i < stmt->body.size(); ++i {
            self._newline();
            self._print(*(stmt->body.get(i)));
        }
        self._indent -= 1;
        self._newline();
        self._buf += "}";
    }

    // -- Expression statement ----------------------------------------

    priv fn _print_expr_stmt(self, stmt: *ExpressionStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "expr_stmt(";
            self._expr(stmt->expr);
            self._buf += ")";
        } else {
            self._expr(stmt->expr);
        }
    }

    // -- Declaration statement ---------------------------------------

    priv fn _print_decl_stmt(self, stmt: *DeclStmt) {
        // DeclPrinter does not exist yet; show a placeholder so the
        // surrounding structure is visible during smoke testing.
        if self._style == PrintStyle::Debug {
            self._buf += "decl_stmt(<decl>)";
        } else {
            self._buf += "<decl>";
        }
    }

    // -- Return / break / continue -----------------------------------

    priv fn _print_return(self, stmt: *ReturnStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "return(";
            if stmt->value != &null { self._expr(stmt->value); }
            self._buf += ")";
        } else {
            self._buf += "return";
            if stmt->value != &null {
                self._buf += " ";
                self._expr(stmt->value);
            }
        }
    }

    priv fn _print_break(self, stmt: *BreakStmt) {
        if self._style == PrintStyle::Debug {
            if stmt->has_label {
                self._buf += f"break({ExprPrinter::tok_spelling(stmt->label)})";
            } else {
                self._buf += "break()";
            }
        } else {
            self._buf += "break";
            if stmt->has_label {
                self._buf += " ";
                self._buf += ExprPrinter::tok_spelling(stmt->label);
            }
        }
    }

    priv fn _print_continue(self, stmt: *ContinueStmt) {
        if self._style == PrintStyle::Debug {
            if stmt->has_label {
                self._buf += f"continue({ExprPrinter::tok_spelling(stmt->label)})";
            } else {
                self._buf += "continue()";
            }
        } else {
            self._buf += "continue";
            if stmt->has_label {
                self._buf += " ";
                self._buf += ExprPrinter::tok_spelling(stmt->label);
            }
        }
    }

    // -- Panic / yield -----------------------------------------------

    priv fn _print_panic(self, stmt: *PanicStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "panic(";
            self._expr(stmt->payload);
            self._buf += ")";
        } else {
            self._buf += "panic ";
            self._expr(stmt->payload);
        }
    }

    priv fn _print_yield(self, stmt: *YieldStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "yield(";
            self._expr(stmt->value);
            self._buf += ")";
        } else {
            self._buf += "yield ";
            self._expr(stmt->value);
        }
    }

    // -- Assertions --------------------------------------------------

    priv fn _print_runtime_assert(self, stmt: *RuntimeAssertStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "assert(";
            self._expr(stmt->condition);
            if stmt->message != &null {
                self._buf += ", ";
                self._expr(stmt->message);
            }
            self._buf += ")";
        } else {
            self._buf += "assert ";
            self._expr(stmt->condition);
            if stmt->message != &null {
                self._buf += ", ";
                self._expr(stmt->message);
            }
        }
    }

    priv fn _print_static_assert(self, stmt: *StaticAssertStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "static_assert(";
            self._expr(stmt->condition);
            if stmt->message != &null {
                self._buf += ", ";
                self._expr(stmt->message);
            }
            self._buf += ")";
        } else {
            self._buf += "assert static ";
            self._expr(stmt->condition);
            if stmt->message != &null {
                self._buf += ", ";
                self._expr(stmt->message);
            }
        }
    }

    // -- label! / jump! ----------------------------------------------

    priv fn _print_label_intrinsic(self, stmt: *LabelIntrinsicStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += f"label_intrinsic({ExprPrinter::tok_spelling(stmt->name)})";
        } else {
            self._buf += f"label!({ExprPrinter::tok_spelling(stmt->name)})";
        }
    }

    priv fn _print_jump_intrinsic(self, stmt: *JumpIntrinsicStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += f"jump_intrinsic({ExprPrinter::tok_spelling(stmt->target)})";
        } else {
            self._buf += f"jump!({ExprPrinter::tok_spelling(stmt->target)})";
        }
    }

    // -- Conditional -------------------------------------------------

    priv fn _print_conditional(self, stmt: *ConditionalStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "if(";
            self._expr(stmt->cond);
            self._buf += ", then=";
            self._print(stmt->then_);
            if stmt->else_ != &null {
                self._buf += ", else=";
                self._print(stmt->else_);
            }
            self._buf += ")";
        } else {
            self._buf += "if ";
            self._expr(stmt->cond);
            self._buf += " ";
            self._print(stmt->then_);
            if stmt->else_ != &null {
                self._buf += " else ";
                self._print(stmt->else_);
            }
        }
    }

    // -- While / loop ------------------------------------------------

    priv fn _print_while(self, stmt: *WhileLoopStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "while(";
            self._expr(stmt->cond);
            self._buf += ", ";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._buf += "while ";
            self._expr(stmt->cond);
            self._buf += " ";
            self._print(stmt->body);
        }
    }

    priv fn _print_loop(self, stmt: *LoopStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "loop(";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._buf += "loop ";
            self._print(stmt->body);
        }
    }

    // -- For loops ---------------------------------------------------

    priv fn _print_ranged_for(self, stmt: *RangedForStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "ranged_for(";
            if stmt->is_eval { self._buf += "eval, "; }
            self._buf += "bindings=[";
            self._print_binding_list(stmt->bindings);
            self._buf += "], in=";
            self._expr(stmt->iterable);
            self._buf += ", ";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._buf += "for ";
            if stmt->is_eval { self._buf += "eval "; }
            self._print_binding_list(stmt->bindings);
            self._buf += " in ";
            self._expr(stmt->iterable);
            self._buf += " ";
            self._print(stmt->body);
        }
    }

    priv fn _print_indexed_for(self, stmt: *IndexedForStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "indexed_for(";
            if stmt->is_eval { self._buf += "eval, "; }
            self._buf += "init=";
            self._print(stmt->init);
            self._buf += ", cond=";
            self._expr(stmt->cond);
            self._buf += ", update=";
            self._expr(stmt->update);
            self._buf += ", ";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._buf += "for ";
            if stmt->is_eval { self._buf += "eval "; }
            self._print(stmt->init);
            self._buf += "; ";
            self._expr(stmt->cond);
            self._buf += "; ";
            self._expr(stmt->update);
            self._buf += " ";
            self._print(stmt->body);
        }
    }

    // -- Match -------------------------------------------------------

    priv fn _print_match(self, stmt: *MatchStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "match(";
            self._expr(stmt->scrutinee);
            self._buf += f", cases={stmt->cases.size()}";
            self._indent += 1;
            for var i: usize = 0; i < stmt->cases.size(); ++i {
                self._newline();
                self._print_match_case(*(stmt->cases.get(i)));
            }
            self._indent -= 1;
            self._buf += ")";
        } else {
            self._buf += "match ";
            self._expr(stmt->scrutinee);
            self._buf += " {";
            self._indent += 1;
            for var i: usize = 0; i < stmt->cases.size(); ++i {
                self._newline();
                self._print_match_case(*(stmt->cases.get(i)));
            }
            self._indent -= 1;
            self._newline();
            self._buf += "}";
        }
    }

    priv fn _print_match_case(self, mc: MatchCase) {
        if mc.is_default {
            self._buf += "default ";
        } else {
            self._buf += "case ";
            // patterns delegate to PatternPrinter once it exists; for now
            // show count so structure is visible.
            if self._style == PrintStyle::Debug {
                self._buf += f"<{mc.patterns.size()} pattern(s)>";
            } else {
                self._buf += "<pattern>";
            }
            if mc.guard != &null {
                self._buf += " where ";
                self._expr(mc.guard);
            }
            self._buf += " ";
        }
        self._print(mc.body);
    }

    // -- Labeled -----------------------------------------------------

    priv fn _print_labeled(self, stmt: *LabeledStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += f"labeled({ExprPrinter::tok_spelling(stmt->label)}, ";
            self._print(stmt->inner);
            self._buf += ")";
        } else {
            self._buf += ExprPrinter::tok_spelling(stmt->label);
            self._buf += ": ";
            self._print(stmt->inner);
        }
    }

    // -- Try / catch / finally ---------------------------------------

    priv fn _print_try_catch(self, stmt: *TryCatchStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "try(";
            self._print(stmt->try_body);
            self._buf += f", arms={stmt->arms.size()}";
            for var i: usize = 0; i < stmt->arms.size(); ++i {
                self._buf += ", ";
                self._print_catch_arm(*(stmt->arms.get(i)));
            }
            self._buf += ")";
        } else {
            self._buf += "try ";
            self._print(stmt->try_body);
            for var i: usize = 0; i < stmt->arms.size(); ++i {
                self._buf += " ";
                self._print_catch_arm(*(stmt->arms.get(i)));
            }
        }
    }

    priv fn _print_catch_arm(self, arm: CatchArm) {
        self._buf += "catch";
        if arm.binding != &null {
            self._buf += " ";
            self._buf += ExprPrinter::tok_spelling(arm.binding->name);
            if arm.filter != &null {
                self._buf += ": ";
                self._type(arm.filter);
            }
        }
        self._buf += " ";
        self._print(arm.body);
    }

    priv fn _print_finally(self, stmt: *FinallyStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "finally(";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._buf += "finally ";
            self._print(stmt->body);
        }
    }

    // -- Unsafe block ------------------------------------------------

    priv fn _print_unsafe_block(self, stmt: *UnsafeBlockStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "unsafe_block(";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._buf += "unsafe ";
            self._print(stmt->body);
        }
    }

    // -- Context binding ---------------------------------------------

    priv fn _print_context_binding(self, stmt: *ContextBindingStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += "context_binding(";
            self._expr(stmt->value);
            self._buf += ", as=[";
            self._print_binding_list(stmt->bindings);
            self._buf += "], ";
            self._print(stmt->body);
            self._buf += ")";
        } else {
            self._expr(stmt->value);
            self._buf += " as ";
            // single bare binding prints without parens; multiple get parens.
            if stmt->bindings.size() == 1 {
                self._print_binding_list(stmt->bindings);
            } else {
                self._buf += "(";
                self._print_binding_list(stmt->bindings);
                self._buf += ")";
            }
            self._buf += " ";
            self._print(stmt->body);
        }
    }

    // -- Destructuring decl ------------------------------------------

    priv fn _print_destructure(self, stmt: *DestructuringDeclStmt) {
        var open  = ("(") if (stmt->kind_ == DestructureKind::Tuple) else ("{");
        var close = (")") if (stmt->kind_ == DestructureKind::Tuple) else ("}");

        if self._style == PrintStyle::Debug {
            var dk = ("tuple") if (stmt->kind_ == DestructureKind::Tuple) else ("struct");
            self._buf += f"destructure({dk}, ";
            self._buf += ("const ") if (stmt->leading_is_const) else ("var ");
            self._buf += open;
            self._print_binding_list(stmt->bindings);
            self._buf += close;
            self._buf += " = ";
            self._expr(stmt->value);
            self._buf += ")";
        } else {
            self._buf += ("const ") if (stmt->leading_is_const) else ("var ");
            self._buf += open;
            self._print_binding_list(stmt->bindings);
            self._buf += close;
            self._buf += " = ";
            self._expr(stmt->value);
        }
    }

    // -- Inline foreign block ----------------------------------------

    priv fn _print_inline_block(self, stmt: *InlineBlockStmt) {
        var lang = "c++";
        if stmt->lang == InlineLang::Asm { lang = "asm"; }
        if stmt->lang == InlineLang::C   { lang = "c";   }

        if self._style == PrintStyle::Debug {
            self._buf += f"inline_block({lang}, <opaque body>)";
        } else {
            self._buf += f"inline \"{lang}\" \{ ... \}";
        }
    }

    // -- Eval block --------------------------------------------------

    priv fn _print_eval_block(self, stmt: *EvalBlockStmt) {
        if self._style == PrintStyle::Debug {
            self._buf += f"eval_block(decls={stmt->body.size()})";
        } else {
            self._buf += "eval { ... }";
        }
    }
}