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
import ASTNode::Declarations::*;
import ASTNode::Statements::*;
import ASTNode::PrimaryExpressions::*;
import ASTNode::Casting::*;
import AST::DeclContext::*;
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

    fn _print_decl_stmt(self, stmt: *DeclStmt);

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

/// --- The Kairo Project --------------- Compiler/AST/DeclPrinter.k ----- ///
///
///   A simple pretty-printer for declaration nodes. Companion to
///   ExprPrinter, StmtPrinter, and TypePrinter; delegates expression,
///   statement, and type children to them.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------- ///

class DeclPrinter {
    var _buf:    string;
    var _style:  PrintStyle;
    var _indent: u32;

    // -- Public entry point ------------------------------------------

    static fn print(decl: *Decl, style: PrintStyle = PrintStyle::Diagnostic) -> string {
        var p     = DeclPrinter{};
        p._style  = style;
        p._buf    = "";
        p._indent = 0;
        p._print(decl);
        return p._buf;
    }

    // -- Indentation / delegation helpers ----------------------------

    priv fn _newline(self) {
        self._buf += "\n";
        for var i: u32 = 0; i < self._indent; ++i {
            self._buf += "  ";
        }
    }

    priv fn _expr(self, e: *Expr) { self._buf += ExprPrinter::print(e, self._style); }
    priv fn _type(self, t: *Type) { self._buf += TypePrinter::print(t, self._style); }
    priv fn _stmt(self, s: *Stmt) { self._buf += StmtPrinter::print(s, self._style); }

    priv fn _name(self, tok: Token) -> string {
        return ExprPrinter::tok_spelling(tok);
    }

    // -- Core dispatch -----------------------------------------------

    priv fn _print(self, decl: *Decl) {
        if decl == &null {
            self._buf += ("<null>") if (self._style == PrintStyle::Debug) else ("<error>");
            return;
        }

        if decl->is_error() {
            self._print_recovery(decl);
            return;
        }

        if isa::<FunctionDecl>(decl)       { self._print_function(cast::<FunctionDecl>(decl));             return; }
        if isa::<VariableDecl>(decl)       { self._print_variable(cast::<VariableDecl>(decl));             return; }
        if isa::<FieldDecl>(decl)          { self._print_field(cast::<FieldDecl>(decl));                   return; }
        if isa::<ParamDecl>(decl)          { self._print_param(cast::<ParamDecl>(decl));                   return; }
        if isa::<GenericParamDecl>(decl)   { self._print_generic_param(cast::<GenericParamDecl>(decl));    return; }
        if isa::<StructDecl>(decl)         { self._print_struct(cast::<StructDecl>(decl));                 return; }
        if isa::<ClassDecl>(decl)          { self._print_class(cast::<ClassDecl>(decl));                   return; }
        if isa::<InterfaceDecl>(decl)      { self._print_interface(cast::<InterfaceDecl>(decl));           return; }
        if isa::<ExtensionDecl>(decl)      { self._print_extension(cast::<ExtensionDecl>(decl));           return; }
        if isa::<EnumDecl>(decl)           { self._print_enum(cast::<EnumDecl>(decl));                     return; }
        if isa::<EnumVariantDecl>(decl)    { self._print_enum_variant(cast::<EnumVariantDecl>(decl));      return; }
        if isa::<UnionDecl>(decl)          { self._print_union(cast::<UnionDecl>(decl));                   return; }
        if isa::<TypeAliasDecl>(decl)      { self._print_type_alias(cast::<TypeAliasDecl>(decl));          return; }
        if isa::<ModuleDecl>(decl)         { self._print_module(cast::<ModuleDecl>(decl));                 return; }
        if isa::<ImportDecl>(decl)         { self._print_import(cast::<ImportDecl>(decl));                 return; }
        if isa::<VisibilityGroupDecl>(decl){ self._print_vis_group(cast::<VisibilityGroupDecl>(decl));     return; }
        if isa::<EvalBlockDecl>(decl)      { self._print_eval_block(cast::<EvalBlockDecl>(decl));          return; }
        if isa::<TestDecl>(decl)           { self._print_test(cast::<TestDecl>(decl));                     return; }
        if isa::<MacroDecl>(decl)          { self._print_macro(cast::<MacroDecl>(decl));                   return; }
        if isa::<ProcedureMacroDecl>(decl) { self._print_proc_macro(cast::<ProcedureMacroDecl>(decl));     return; }

        self._buf += (f"<unknown decl kind={static_cast::<u32>(decl->kind)}>")
            if (self._style == PrintStyle::Debug)
            else "<error>";
    }

    // -- Recovery ----------------------------------------------------

    priv fn _print_recovery(self, decl: *Decl) {
        if self._style == PrintStyle::Debug {
            self._buf += f"<recovery:{static_cast::<u32>(decl->recovery_kind)}>";
        } else {
            self._buf += "<error>";
        }
    }

    // -- Shared: visibility, generics, heritage ----------------------

    /// 0 None / 1 priv / 2 prot / 3 pub  (matches VisibilityKind ordering).
    priv fn _print_visibility(self, vis: u8) {
        if      vis == 3 { self._buf += "pub ";  }
        else if vis == 2 { self._buf += "prot "; }
        else if vis == 1 { self._buf += "priv "; }
    }

    priv fn _print_generic_params(self, gps: FrozenList::<*GenericParamDecl>) {
        if gps.is_empty() { return; }
        self._buf += "<";
        for var i: usize = 0; i < gps.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print_generic_param(*(gps.get(i)));
        }
        self._buf += ">";
    }

    priv fn _print_requires(self, req: *Expr) {
        if req == &null { return; }
        self._buf += " requires ";
        self._expr(req);
    }

    /// Renders one `derives`/`impl` edge list with the given keyword. Skips
    /// entirely when empty so callers can chain unconditionally.
    priv fn _print_inherit_list(self, kw: string, edges: FrozenList::<InheritEdge>) {
        if edges.is_empty() { return; }
        self._buf += " ";
        self._buf += kw;
        self._buf += " ";
        for var i: usize = 0; i < edges.size(); ++i {
            if i > 0 { self._buf += ", "; }
            var e = edges.get(i);
            if e->is_virtual { self._buf += "virtual "; }
            self._print_visibility(e->visibility);
            self._type(e->base);
        }
    }

    // -- GenericParamDecl --------------------------------------------
    //  T | ...T | T: class | T impl Foo derives Bar | const N: i32 | T = i32

    priv fn _print_generic_param(self, gp: *GenericParamDecl) {
        if gp->is_const_param {
            self._buf += "const ";
            self._buf += self._name(gp->name);
            self._buf += ": ";
            self._type(gp->value_type);
            if gp->default_type != &null {
                self._buf += " = ";
                self._type(gp->default_type);
            }
            return;
        }

        if gp->is_pack { self._buf += "..."; }
        self._buf += self._name(gp->name);

        if gp->kind_bound != GenericParamKindBound::Any {
            self._buf += ": ";
            if      gp->kind_bound == GenericParamKindBound::Class  { self._buf += "class";  }
            else if gp->kind_bound == GenericParamKindBound::Struct { self._buf += "struct"; }
            else if gp->kind_bound == GenericParamKindBound::Enum   { self._buf += "enum";   }
            else if gp->kind_bound == GenericParamKindBound::Union  { self._buf += "union";  }
        }

        for var i: usize = 0; i < gp->bounds.size(); ++i {
            self._buf += " impl ";
            self._type(*(gp->bounds.get(i)));
        }

        if gp->default_type != &null {
            self._buf += " = ";
            self._type(gp->default_type);
        }
    }

    // -- ParamDecl ---------------------------------------------------

    priv fn _print_param(self, p: *ParamDecl) {
        if p->is_self {
            self._buf += "self";
            return;
        }
        self._buf += self._name(p->name);
        if p->type_ != &null {
            self._buf += ": ";
            self._type(p->type_);
        }
        if p->default_val != &null {
            self._buf += " = ";
            self._expr(p->default_val);
        }
    }

    priv fn _print_param_list(self, params: FrozenList::<*ParamDecl>, is_variadic: bool) {
        self._buf += "(";
        for var i: usize = 0; i < params.size(); ++i {
            if i > 0 { self._buf += ", "; }
            // a trailing variadic pack param is rendered with a leading `...`
            if is_variadic && (i == params.size() - 1) && (!params[i]->is_self) {
                self._buf += "...";
            }
            self._print_param(params[i]);
        }
        self._buf += ")";
    }

    // -- FunctionDecl ------------------------------------------------

    priv fn _print_fn_modifiers(self, fd: *FunctionDecl) {
        if fd->is_const()    { self._buf += " const";    }
        if (static_cast::<u16>(fd->modifiers) & static_cast::<u16>(FnModifier::IsVolatile)) != 0 {
            self._buf += " volatile";
        }
        if fd->is_unsafe()   { self._buf += " unsafe";   }
        if fd->is_eval()     { self._buf += " eval";     }
        if fd->is_async()    { self._buf += " async";    }
        if fd->is_final()    { self._buf += " final";    }
        if fd->is_panic()    { self._buf += " panic";    }
        if fd->is_inline()   { self._buf += " inline";   }
    }

    priv fn _print_fn_body(self, fd: *FunctionDecl) {
        if      fd->body_kind == FnBodyKind::Default { self._buf += " = default"; }
        else if fd->body_kind == FnBodyKind::Delete  { self._buf += " = delete";  }
        else if fd->body_kind == FnBodyKind::Virtual { self._buf += " = virtual"; }
        else if fd->body_kind == FnBodyKind::Expr {
            self._buf += " = ";
            self._expr(fd->body_expr);
        }
        else if fd->body_kind == FnBodyKind::Block {
            self._buf += " ";
            self._stmt(static_cast::<*Stmt>(fd->body_block));
        }
        // FnBodyKind::None: forward decl / signature, nothing trailing.
    }

    priv fn _print_function(self, fd: *FunctionDecl) {
        if self._style == PrintStyle::Debug {
            self._buf += "fn_decl(";
        }

        // abi / dispatch modifiers that precede `fn`
        if      fd->abi == AbiKind::Static   { self._buf += "static ";   }
        else if fd->abi == AbiKind::Virtual  { self._buf += "virtual ";  }
        else if fd->abi == AbiKind::Override { self._buf += "override "; }
        else if fd->abi == AbiKind::FfiC     { self._buf += "ffi \"c\" ";   }
        else if fd->abi == AbiKind::FfiCpp   { self._buf += "ffi \"c++\" "; }

        if fd->transfer == TransferKind::Copy { self._buf += "@copy "; }
        if fd->transfer == TransferKind::Move { self._buf += "@move "; }

        self._buf += "fn";
        self._print_generic_params(fd->generic_params);
        self._buf += " ";

        // out-of-line qualifier (Class::), then name / operator
        if fd->qualifier != &null {
            self._expr(fd->qualifier);
            self._buf += "::";
        }
        if fd->is_operator {
            self._buf += "op ";
            self._buf += self._name(fd->op_token);
        } else {
            self._buf += self._name(fd->name);
        }

        self._print_param_list(fd->params, fd->is_variadic);
        self._print_fn_modifiers(fd);

        if fd->is_noreturn {
            self._buf += " -> !";
        } else if fd->return_type != &null {
            self._buf += " -> ";
            self._type(fd->return_type);
        }

        self._print_requires(fd->requires_clause);
        self._print_fn_body(fd);

        if self._style == PrintStyle::Debug {
            self._buf += ")";
        }
    }

    // -- VariableDecl ------------------------------------------------

    priv fn _storage_kw(self, s: StorageClass) -> string {
        if s == StorageClass::Const  { return "const";  }
        if s == StorageClass::Static { return "static"; }
        if s == StorageClass::Eval   { return "eval";   }
        return "var";
    }

    priv fn _print_variable(self, vd: *VariableDecl) {
        self._buf += self._storage_kw(vd->storage);
        self._buf += " ";
        self._buf += self._name(vd->name);
        if vd->type_ != &null {
            self._buf += ": ";
            self._type(vd->type_);
        }
        if vd->init != &null {
            self._buf += " = ";
            self._expr(vd->init);
        }
    }

    // -- FieldDecl ---------------------------------------------------

    priv fn _print_field(self, fd: *FieldDecl) {
        if fd->is_mutable { self._buf += "mutable "; }
        self._buf += self._storage_kw(fd->storage);
        self._buf += " ";
        self._buf += self._name(fd->name);
        if fd->type_ != &null {
            self._buf += ": ";
            self._type(fd->type_);
        }
        if fd->init != &null {
            self._buf += " = ";
            self._expr(fd->init);
        }
    }

    // -- Shared braced member body -----------------------------------
    //  Renders `{ ... }` over a fields list then a methods list, each on its
    //  own indented line. Either may be empty. Empty body prints `{}`.

    priv fn _print_member_body(
        self,
        fields:  FrozenList::<*FieldDecl>,
        methods: FrozenList::<*FunctionDecl>
    ) {
        if fields.is_empty() && methods.is_empty() {
            self._buf += " {}";
            return;
        }
        self._buf += " {";
        self._indent += 1;
        for var i: usize = 0; i < fields.size(); ++i {
            self._newline();
            self._print_field(*(fields.get(i)));
        }
        for var i: usize = 0; i < methods.size(); ++i {
            self._newline();
            self._print_function(*(methods.get(i)));
        }
        self._indent -= 1;
        self._newline();
        self._buf += "}";
    }

    // -- StructDecl --------------------------------------------------

    priv fn _print_struct(self, sd: *StructDecl) {
        var empty_methods: FrozenList::<*FunctionDecl>; // structs have no in-body methods
        self._buf += "struct";
        self._print_generic_params(sd->generic_params);
        self._buf += " ";
        self._buf += self._name(sd->name);
        self._print_inherit_list("impl", sd->implements);
        self._print_requires(sd->requires_clause);
        self._print_member_body(sd->fields, empty_methods);
    }

    // -- ClassDecl ---------------------------------------------------

    priv fn _print_class(self, cd: *ClassDecl) {
        if cd->is_final { self._buf += "final "; }
        self._buf += "class";
        self._print_generic_params(cd->generic_params);
        self._buf += " ";
        self._buf += self._name(cd->name);
        self._print_inherit_list("derives", cd->derives_list);
        self._print_inherit_list("impl", cd->implements);
        self._print_requires(cd->requires_clause);
        self._print_member_body(cd->fields, cd->methods);
    }

    // -- InterfaceDecl -----------------------------------------------

    priv fn _print_interface(self, id: *InterfaceDecl) {
        var empty_fields: FrozenList::<*FieldDecl>; // interfaces hold only signatures
        self._buf += "interface";
        self._print_generic_params(id->generic_params);
        self._buf += " ";
        self._buf += self._name(id->name);
        self._print_inherit_list("derives", id->derives_list);
        self._print_requires(id->requires_clause);
        self._print_member_body(empty_fields, id->methods);
    }

    // -- ExtensionDecl -----------------------------------------------

    priv fn _print_extension(self, ed: *ExtensionDecl) {
        var empty_fields: FrozenList::<*FieldDecl>;
        self._buf += "extend";
        self._print_generic_params(ed->generic_params);
        self._buf += " ";
        self._type(ed->target);
        self._print_inherit_list("impl", ed->implements);
        self._print_member_body(empty_fields, ed->methods);
    }

    // -- EnumDecl / EnumVariantDecl ----------------------------------

    priv fn _print_enum(self, en: *EnumDecl) {
        self._buf += "enum";
        self._print_generic_params(en->generic_params);
        self._buf += " ";
        self._buf += self._name(en->name);
        if en->underlying != &null {
            self._buf += " derives ";
            self._type(en->underlying);
        }

        if en->variants.is_empty() {
            self._buf += " {}";
            return;
        }
        self._buf += " {";
        self._indent += 1;
        for var i: usize = 0; i < en->variants.size(); ++i {
            self._newline();
            self._print_enum_variant(*(en->variants.get(i)));
            self._buf += ",";
        }
        self._indent -= 1;
        self._newline();
        self._buf += "}";
    }

    priv fn _print_enum_variant(self, v: *EnumVariantDecl) {
        self._buf += self._name(v->name);

        if v->is_adt() {
            self._buf += " { ";
            for var i: usize = 0; i < v->payload.size(); ++i {
                if i > 0 { self._buf += ", "; }
                var f = v->payload.get(i);
                self._buf += self._name((*f)->name);
                self._buf += ": ";
                self._type((*f)->type_);
            }
            self._buf += " }";
        } else if v->discriminant != &null {
            self._buf += " = ";
            self._expr(v->discriminant);
        }
    }

    // -- UnionDecl ---------------------------------------------------

    priv fn _print_union(self, ud: *UnionDecl) {
        var empty_methods: FrozenList::<*FunctionDecl>;
        self._buf += "union";
        self._print_generic_params(ud->generic_params);
        self._buf += " ";
        self._buf += self._name(ud->name);
        self._print_member_body(ud->fields, empty_methods);
    }

    // -- TypeAliasDecl -----------------------------------------------

    priv fn _print_type_alias(self, ta: *TypeAliasDecl) {
        self._buf += "type";
        self._print_generic_params(ta->generic_params);
        self._buf += " ";
        self._buf += self._name(ta->name);
        self._buf += " = ";
        self._type(ta->aliased);
    }

    // -- ModuleDecl --------------------------------------------------
    //  Module children live in the DeclContext, not a typed list.

    priv fn _print_module(self, md: *ModuleDecl) {
        if md->is_inline { self._buf += "inline "; }
        self._buf += "module";
        if !md->is_anonymous {
            self._buf += " ";
            self._buf += self._name(md->name);
        }

        var dc = static_cast::<*DeclContext>(md);
        if dc->dc_decls.size() == 0 {
            self._buf += " {}";
            return;
        }
        self._buf += " {";
        self._indent += 1;
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._newline();
            self._print(*(dc->dc_decls.get(i)));
        }
        self._indent -= 1;
        self._newline();
        self._buf += "}";
    }

    // -- ImportDecl --------------------------------------------------

    priv fn _print_import(self, im: *ImportDecl) {
        if im->import_kind == ImportKind::FfiC   { self._buf += "ffi \"c\" ";   }
        if im->import_kind == ImportKind::FfiCpp { self._buf += "ffi \"c++\" "; }

        self._buf += "import ";

        if im->is_ffi() {
            self._buf += self._name(im->header);
        } else {
            if im->import_kind == ImportKind::SourceOnly { self._buf += "module "; }
            for var i: usize = 0; i < im->path_segments.size(); ++i {
                if i > 0 { self._buf += "::"; }
                self._buf += self._name(*(im->path_segments.get(i)));
            }

            if im->is_wildcard {
                self._buf += "::*";
            } else if im->has_items {
                self._buf += "::{";
                for var i: usize = 0; i < im->items.size(); ++i {
                    if i > 0 { self._buf += ", "; }
                    var it = im->items.get(i);
                    self._print_import_item(it);
                }
                self._buf += "}";
            }
        }

        if im->has_alias {
            self._buf += " as ";
            self._buf += self._name(im->alias);
        }
    }

    priv fn _print_import_item(self, it: *ImportItem) {
        if it->is_wildcard {
            self._buf += "*";
            return;
        }
        for var i: usize = 0; i < it->sub_path.size(); ++i {
            if i > 0 { self._buf += "::"; }
            self._buf += self._name(*(it->sub_path.get(i)));
        }
        if it->has_alias {
            self._buf += " as ";
            self._buf += self._name(it->alias);
        }
    }

    // -- VisibilityGroupDecl -----------------------------------------

    priv fn _print_vis_group(self, vg: *VisibilityGroupDecl) {
        self._print_visibility(vg->group_visibility);
        if vg->members.is_empty() {
            self._buf += "{}";
            return;
        }
        self._buf += "{";
        self._indent += 1;
        for var i: usize = 0; i < vg->members.size(); ++i {
            self._newline();
            self._print(*(vg->members.get(i)));
        }
        self._indent -= 1;
        self._newline();
        self._buf += "}";
    }

    // -- EvalBlockDecl -----------------------------------------------

    priv fn _print_eval_block(self, eb: *EvalBlockDecl) {
        if self._style == PrintStyle::Debug {
            self._buf += f"eval_block_decl(decls={eb->body.size()})";
            return;
        }
        self._buf += "eval";
        if eb->body.is_empty() {
            self._buf += " {}";
            return;
        }
        self._buf += " {";
        self._indent += 1;
        for var i: usize = 0; i < eb->body.size(); ++i {
            self._newline();
            self._print(*(eb->body.get(i)));
        }
        self._indent -= 1;
        self._newline();
        self._buf += "}";
    }

    // -- TestDecl ----------------------------------------------------

    priv fn _print_test(self, td: *TestDecl) {
        self._buf += "test";
        if td->label != &null {
            self._buf += " ";
            self._expr(td->label);
        }
        self._buf += " ";
        if td->body != &null {
            self._stmt(static_cast::<*Stmt>(td->body));
        } else {
            self._buf += "{}";
        }
    }

    // -- MacroDecl ---------------------------------------------------

    priv fn _print_macro(self, mc: *MacroDecl) {
        self._buf += "macro ";
        self._buf += self._name(mc->name);
        self._buf += "!(";
        for var i: usize = 0; i < mc->params.size(); ++i {
            if i > 0 { self._buf += ", "; }
            if mc->is_variadic && (i == mc->params.size() - 1) { self._buf += "..."; }
            self._buf += self._name(*(mc->params.get(i)));
        }
        self._buf += ") { ... }";
    }

    // -- ProcedureMacroDecl ------------------------------------------

    priv fn _print_proc_macro(self, pm: *ProcedureMacroDecl) {
        self._buf += "macro @";
        self._buf += self._name(pm->name);
        self._print_param_list(pm->params, false);
        self._buf += " ";
        if pm->body != &null {
            self._stmt(static_cast::<*Stmt>(pm->body));
        } else {
            self._buf += "{}";
        }
    }
}

fn StmtPrinter::_print_decl_stmt(stmt: *DeclStmt) {
    if self._style == PrintStyle::Debug {
        self._buf += "decl_stmt(";
        self._buf += DeclPrinter::print(stmt->decl, self._style);
        self._buf += ")";
    } else {
        self._buf += DeclPrinter::print(stmt->decl, self._style);
    }
}