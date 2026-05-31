/// --- The Kairo Project --------------- Compiler/AST/ExprPrinter.k ----- ///
///
///   A simple pretty-printer for expression nodes.
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
import ASTNode::PrimaryExpressions::*;
import ASTNode::Expressions::*;
import ASTNode::Types::*;
import ASTNode::Casting::*;
import AST::Printer::TypePrinter::*;
import TokenKind::*;

class ExprPrinter {
    var _buf:   string;
    var _style: PrintStyle;

    // ── Public entry point ──────────────────────────────────────────

    static fn print(expr: *Expr, style: PrintStyle = PrintStyle::Diagnostic) -> string {
        var p    = ExprPrinter{};
        p._style = style;
        p._buf   = "";
        p._print(expr);
        return p._buf;
    }

    // ── Token spelling helper ───────────────────────────────────────

    static fn tok_spelling(tok: Token) -> string {
        return token_kind_to_readable_string(tok.kind);
    }

    // ── Core dispatch ───────────────────────────────────────────────

    priv fn _print(self, expr: *Expr) {
        if expr == &null {
            self._buf += ("<null>") if (self._style == PrintStyle::Debug) else ("<error>");
            return;
        }

        if expr->is_error() {
            self._print_recovery(expr);
            return;
        }

        if isa::<IntegerLiteralExpr>(expr)    { self._print_int_lit(cast::<IntegerLiteralExpr>(expr));       return; }
        if isa::<FloatingLiteralExpr>(expr)   { self._print_float_lit(cast::<FloatingLiteralExpr>(expr));    return; }
        if isa::<StringLiteralExpr>(expr)     { self._print_string_lit(cast::<StringLiteralExpr>(expr));     return; }
        if isa::<CharacterLiteralExpr>(expr)  { self._print_char_lit(cast::<CharacterLiteralExpr>(expr));    return; }
        if isa::<BooleanLiteralExpr>(expr)    { self._print_bool_lit(cast::<BooleanLiteralExpr>(expr));      return; }
        if isa::<NullLiteralExpr>(expr)       { self._print_null_lit(cast::<NullLiteralExpr>(expr));         return; }
        if isa::<NamedIdentExpr>(expr)        { self._print_named_ident(cast::<NamedIdentExpr>(expr));       return; }
        if isa::<ChainExpr>(expr)             { self._print_chain(cast::<ChainExpr>(expr));                  return; }
        if isa::<CallExpr>(expr)              { self._print_call(cast::<CallExpr>(expr));                    return; }
        if isa::<SubscriptExpr>(expr)         { self._print_subscript(cast::<SubscriptExpr>(expr));          return; }
        if isa::<UnaryOperatorExpr>(expr)     { self._print_unary(cast::<UnaryOperatorExpr>(expr));          return; }
        if isa::<BinaryOperatorExpr>(expr)    { self._print_binary(cast::<BinaryOperatorExpr>(expr));        return; }
        if isa::<AssignOperatorExpr>(expr)    { self._print_assign(cast::<AssignOperatorExpr>(expr));         return; }
        if isa::<ListLiteralExpr>(expr)       { self._print_list_lit(cast::<ListLiteralExpr>(expr));         return; }
        if isa::<TupleLiteralExpr>(expr)      { self._print_tuple_lit(cast::<TupleLiteralExpr>(expr));       return; }
        if isa::<SetLiteralExpr>(expr)        { self._print_set_lit(cast::<SetLiteralExpr>(expr));           return; }
        if isa::<MapLiteralExpr>(expr)        { self._print_map_lit(cast::<MapLiteralExpr>(expr));           return; }
        if isa::<NamedInitializerExpr>(expr)  { self._print_named_init(cast::<NamedInitializerExpr>(expr));  return; }
        if isa::<AnonInitializerExpr>(expr)   { self._print_anon_init(cast::<AnonInitializerExpr>(expr));    return; }
        if isa::<IfExpr>(expr)                { self._print_if(cast::<IfExpr>(expr));                        return; }
        if isa::<TryCatchExpr>(expr)          { self._print_try_catch(cast::<TryCatchExpr>(expr));           return; }
        if isa::<RangeExpr>(expr)             { self._print_range(cast::<RangeExpr>(expr));                  return; }
        if isa::<ClosureExpr>(expr)           { self._print_closure(cast::<ClosureExpr>(expr));              return; }
        if isa::<AwaitExpr>(expr)             { self._print_await(cast::<AwaitExpr>(expr));                  return; }
        if isa::<SpawnExpr>(expr)             { self._print_spawn(cast::<SpawnExpr>(expr));                  return; }
        if isa::<ThreadExpr>(expr)            { self._print_thread(cast::<ThreadExpr>(expr));                return; }
        if isa::<SizeOfExpr>(expr)            { self._print_sizeof(cast::<SizeOfExpr>(expr));                return; }
        if isa::<AlignOfExpr>(expr)           { self._print_alignof(cast::<AlignOfExpr>(expr));              return; }
        if isa::<TypeOfExpr>(expr)            { self._print_typeof(cast::<TypeOfExpr>(expr));                return; }
        if isa::<EvalExpr>(expr)              { self._print_eval(cast::<EvalExpr>(expr));                    return; }
        if isa::<UnsafeExpr>(expr)            { self._print_unsafe(cast::<UnsafeExpr>(expr));                return; }
        if isa::<DeleteExpr>(expr)            { self._print_delete(cast::<DeleteExpr>(expr));                return; }
        if isa::<PackExpansionExpr>(expr)     { self._print_pack_expansion(cast::<PackExpansionExpr>(expr)); return; }
        if isa::<TypeCastExpr>(expr)          { self._print_type_cast(cast::<TypeCastExpr>(expr));           return; }
        if isa::<ImplConformanceExpr>(expr)   { self._print_impl_conf(cast::<ImplConformanceExpr>(expr));    return; }
        if isa::<DerivesRelationExpr>(expr)   { self._print_derives_rel(cast::<DerivesRelationExpr>(expr));  return; }
        if isa::<ImplicitBoundaryCastExpr>(expr) { self._print_boundary_cast(cast::<ImplicitBoundaryCastExpr>(expr)); return; }

        self._buf += (f"<unknown expr kind={static_cast::<u32>(expr->kind)}>")
            if (self._style == PrintStyle::Debug)
            else "<error>";
    }

    // ── Recovery ────────────────────────────────────────────────────

    priv fn _print_recovery(self, expr: *Expr) {
        if self._style == PrintStyle::Debug {
            self._buf += f"<recovery:{static_cast::<u32>(expr->recovery_kind)}>";
        } else {
            self._buf += "<error>";
        }
    }

    // ── Scalar literals ─────────────────────────────────────────────

    priv fn _print_int_lit(self, expr: *IntegerLiteralExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += f"int({ExprPrinter::tok_spelling(expr->token)})";
        } else {
            self._buf += ExprPrinter::tok_spelling(expr->token);
        }
    }

    priv fn _print_float_lit(self, expr: *FloatingLiteralExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += f"float({ExprPrinter::tok_spelling(expr->token)})";
        } else {
            self._buf += ExprPrinter::tok_spelling(expr->token);
        }
    }

    priv fn _print_string_lit(self, expr: *StringLiteralExpr) {
        if self._style == PrintStyle::Debug {
            var kind_str = "plain";
            if expr->string_kind == StringLiteralExpr::StringKind::Raw    { kind_str = "raw";    }
            if expr->string_kind == StringLiteralExpr::StringKind::Format { kind_str = "format"; }
            self._buf += f"str({kind_str}, {ExprPrinter::tok_spelling(expr->token)})";
        } else {
            self._buf += ExprPrinter::tok_spelling(expr->token);
        }
    }

    priv fn _print_char_lit(self, expr: *CharacterLiteralExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += f"char({ExprPrinter::tok_spelling(expr->token)})";
        } else {
            self._buf += ExprPrinter::tok_spelling(expr->token);
        }
    }

    priv fn _print_bool_lit(self, expr: *BooleanLiteralExpr) {
        self._buf += ("true") if (expr->value) else ("false");
    }

    priv fn _print_null_lit(self, expr: *NullLiteralExpr) {
        if expr->is_ref {
            self._buf += "&null";
        } else {
            self._buf += "null";
        }
    }

    // ── Named identifier ────────────────────────────────────────────

    priv fn _print_named_ident(self, expr: *NamedIdentExpr) {
        var name = ExprPrinter::tok_spelling(expr->name);

        if self._style == PrintStyle::Debug {
            self._buf += f"ident({name})";
        } else {
            self._buf += name;
        }

        if !expr->generic_args.is_empty() {
            self._buf += "<";
            for var i: usize = 0; i < expr->generic_args.size(); ++i {
                if i > 0 { self._buf += ", "; }
                var arg = expr->generic_args.get(i);
                if arg->name != &null {
                    self._buf += ExprPrinter::tok_spelling(arg->name->name);
                    self._buf += ": ";
                }
                self._buf += TypePrinter::print(arg->ty, self._style);
            }
            self._buf += ">";
        }
    }

    // ── Chain expression ────────────────────────────────────────────

    priv fn _print_chain(self, expr: *ChainExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "chain(";
        }

        // base
        if expr->base != &null {
            self._print(expr->base);
        } else {
            // global root: no base
            if self._style != PrintStyle::Debug {
                // the leading :: is implicit from first step
                0;
            }
        }

        // steps
        for var i: usize = 0; i < expr->steps.size(); ++i {
            var step = expr->steps.get(i);
            self._print_access_kind(step->access_kind);

            if step->name != &null {
                self._buf += ExprPrinter::tok_spelling(step->name->name);
            } else {
                self._buf += "<error>";
            }

            if !step->generic_args.is_empty() {
                self._buf += "<";
                for var j: usize = 0; j < step->generic_args.size(); ++j {
                    if j > 0 { self._buf += ", "; }
                    var arg = step->generic_args.get(j);
                    if arg->name != &null {
                        self._buf += ExprPrinter::tok_spelling(arg->name->name);
                        self._buf += ": ";
                    }
                    self._buf += TypePrinter::print(arg->ty, self._style);
                }
                self._buf += ">";
            }
        }

        if self._style == PrintStyle::Debug {
            self._buf += ")";
        }
    }

    priv fn _print_access_kind(self, kind: ChainExpr::AccessKind) {
        if      kind == ChainExpr::AccessKind::Dot               { self._buf += ".";   }
        else if kind == ChainExpr::AccessKind::Arrow             { self._buf += "->";  }
        else if kind == ChainExpr::AccessKind::ColonColon        { self._buf += "::";  }
        else if kind == ChainExpr::AccessKind::QuestionDot       { self._buf += "?.";  }
        else if kind == ChainExpr::AccessKind::QuestionArrow     { self._buf += "?->"; }
        else if kind == ChainExpr::AccessKind::DotStar           { self._buf += ".*";  }
        else if kind == ChainExpr::AccessKind::ArrowStar         { self._buf += "->*"; }
        else if kind == ChainExpr::AccessKind::QuestionDotStar   { self._buf += "?.*"; }
        else if kind == ChainExpr::AccessKind::QuestionArrowStar { self._buf += "?->*";}
    }

    // ── Call expression ─────────────────────────────────────────────

    priv fn _print_call(self, expr: *CallExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "call(";
            self._print(expr->callee);
            self._buf += ", args=[";
        } else {
            self._print(expr->callee);
            self._buf += "(";
        }

        for var i: usize = 0; i < expr->args.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print(expr->args[i]);
        }

        if self._style == PrintStyle::Debug {
            self._buf += "])";
        } else {
            self._buf += ")";
        }
    }

    // ── Subscript expression ────────────────────────────────────────

    priv fn _print_subscript(self, expr: *SubscriptExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "subscript(";
            self._print(expr->base);
            self._buf += ", ";
            self._print(expr->index);
            self._buf += ")";
        } else {
            self._print(expr->base);
            self._buf += "[";
            self._print(expr->index);
            self._buf += "]";
        }
    }

    // ── Unary operator ──────────────────────────────────────────────

    priv fn _print_unary(self, expr: *UnaryOperatorExpr) {
        var op_ = ExprPrinter::tok_spelling(expr->op_token);

        if self._style == PrintStyle::Debug {
            var fix_str = ("prefix") if (expr->is_prefix()) else ("postfix");
            self._buf += f"unary({fix_str}, {op_}, ";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            if expr->is_prefix() {
                self._buf += op_;
                self._print(expr->operand);
            } else {
                self._print(expr->operand);
                self._buf += op_;
            }
        }
    }

    // ── Binary operator ─────────────────────────────────────────────

    priv fn _print_binary(self, expr: *BinaryOperatorExpr) {
        var op_ = ExprPrinter::tok_spelling(expr->op_token);

        if self._style == PrintStyle::Debug {
            self._buf += f"binop({op_}, ";
            self._print(expr->lhs);
            self._buf += ", ";
            self._print(expr->rhs);
            self._buf += ")";
        } else {
            self._print(expr->lhs);
            self._buf += f" {op_} ";
            self._print(expr->rhs);
        }
    }

    // ── Assignment operator ─────────────────────────────────────────

    priv fn _print_assign(self, expr: *AssignOperatorExpr) {
        var op_ = ExprPrinter::tok_spelling(expr->op_token);

        if self._style == PrintStyle::Debug {
            self._buf += f"assign({op_}, ";
            self._print(expr->lhs);
            self._buf += ", ";
            self._print(expr->rhs);
            self._buf += ")";
        } else {
            self._print(expr->lhs);
            self._buf += f" {op_} ";
            self._print(expr->rhs);
        }
    }

    // ── Collection literals ─────────────────────────────────────────

    priv fn _print_list_lit(self, expr: *ListLiteralExpr) {
        self._buf += "[";
        for var i: usize = 0; i < expr->elements.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print(expr->elements[i]);
        }
        self._buf += "]";
    }

    priv fn _print_tuple_lit(self, expr: *TupleLiteralExpr) {
        self._buf += "(";
        for var i: usize = 0; i < expr->elements.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print(expr->elements[i]);
        }
        self._buf += ")";
    }

    priv fn _print_set_lit(self, expr: *SetLiteralExpr) {
        self._buf += "{";
        for var i: usize = 0; i < expr->elements.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print(expr->elements[i]);
        }
        self._buf += "}";
    }

    priv fn _print_map_lit(self, expr: *MapLiteralExpr) {
        self._buf += "{";
        for var i: usize = 0; i < expr->entries.size(); ++i {
            if i > 0 { self._buf += ", "; }
            var entry = expr->entries.get(i);
            self._print(entry->key);
            self._buf += ": ";
            self._print(entry->value);
        }
        self._buf += "}";
    }

    // ── Initializer expressions ─────────────────────────────────────

    priv fn _print_named_init(self, expr: *NamedInitializerExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "named_init(";
            self._print(expr->type_expr);
            self._buf += ", {";
        } else {
            self._print(expr->type_expr);
            self._buf += " { ";
        }

        for var i: usize = 0; i < expr->fields.size(); ++i {
            if i > 0 { self._buf += ", "; }
            var field = expr->fields.get(i);
            self._buf += ExprPrinter::tok_spelling(field->name);
            self._buf += ": ";
            self._print(field->value);
        }

        if self._style == PrintStyle::Debug {
            self._buf += "})";
        } else {
            self._buf += " }";
        }
    }

    priv fn _print_anon_init(self, expr: *AnonInitializerExpr) {
        self._buf += "{ ";
        for var i: usize = 0; i < expr->fields.size(); ++i {
            if i > 0 { self._buf += ", "; }
            var field = expr->fields.get(i);
            self._buf += ".";
            self._buf += ExprPrinter::tok_spelling(field->name);
            self._buf += ": ";
            self._print(field->value);
        }
        self._buf += " }";
    }

    // ── Control flow expressions ────────────────────────────────────

    priv fn _print_if(self, expr: *IfExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "if_expr(";
            self._print(expr->condition);
            self._buf += ", then=";
            self._print(expr->then_expr);
            for var i: usize = 0; i < expr->else_ifs.size(); ++i {
                var arm = expr->else_ifs.get(i);
                self._buf += ", elif=";
                self._print(arm->condition);
                self._buf += "=>";
                self._print(arm->body);
            }
            self._buf += ", else=";
            self._print(expr->else_expr);
            self._buf += ")";
        } else {
            self._buf += "if ";
            self._print(expr->condition);
            self._buf += " { ";
            self._print(expr->then_expr);
            self._buf += " }";
            for var i: usize = 0; i < expr->else_ifs.size(); ++i {
                var arm = expr->else_ifs.get(i);
                self._buf += " else if ";
                self._print(arm->condition);
                self._buf += " { ";
                self._print(arm->body);
                self._buf += " }";
            }
            self._buf += " else { ";
            self._print(expr->else_expr);
            self._buf += " }";
        }
    }

    priv fn _print_try_catch(self, expr: *TryCatchExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "try_catch(";
            self._print(expr->try_expr);
            self._buf += f", arms={expr->catch_arms.size()})";
        } else {
            self._buf += "try { ";
            self._print(expr->try_expr);
            self._buf += " }";
            for var i: usize = 0; i < expr->catch_arms.size(); ++i {
                var arm = expr->catch_arms.get(i);
                self._buf += " catch ";
                if arm->has_binding {
                    if arm->is_const {
                        self._buf += "const ";
                    }
                    self._print(arm->binding);
                    if arm->filter != &null {
                        self._buf += ": ";
                        TypePrinter::print(arm->filter, self._style);
                    }
                    self._buf += " ";
                }
                self._buf += "{ ";
                self._print(arm->body);
                self._buf += " }";
            }
        }
    }

    priv fn _print_range(self, expr: *RangeExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "range(";
            self._print(expr->begin);
            self._buf += (", ..=, ") if (expr->is_inclusive) else (", .., ");
            self._print(expr->end);
            self._buf += ")";
        } else {
            if expr->begin != &null { self._print(expr->begin); }
            self._buf += ("..=") if (expr->is_inclusive) else ("..");
            if expr->end != &null { self._print(expr->end); }
        }
    }

    // ── Closure ─────────────────────────────────────────────────────

    priv fn _print_closure(self, expr: *ClosureExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "closure(";
            if expr->return_type != &null {
                self._buf += "ret=";
                self._buf += TypePrinter::print(expr->return_type, self._style);
                self._buf += ", ";
            }
            self._buf += "body=";
            self._print(expr->body);
            self._buf += ")";
        } else {
            self._buf += "fn(...) { ";
            self._print(expr->body);
            self._buf += " }";
        }
    }

    // ── Async / concurrency ─────────────────────────────────────────

    priv fn _print_await(self, expr: *AwaitExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "await(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "await ";
            self._print(expr->operand);
        }
    }

    priv fn _print_spawn(self, expr: *SpawnExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "spawn(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "spawn ";
            self._print(expr->operand);
        }
    }

    priv fn _print_thread(self, expr: *ThreadExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "thread(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "thread ";
            self._print(expr->operand);
        }
    }

    // ── Intrinsic / builtin ─────────────────────────────────────────

    priv fn _print_sizeof(self, expr: *SizeOfExpr) {
        self._buf += "sizeof(";
        self._buf += TypePrinter::print(expr->type_arg, self._style);
        self._buf += ")";
    }

    priv fn _print_alignof(self, expr: *AlignOfExpr) {
        self._buf += "alignof(";
        self._buf += TypePrinter::print(expr->type_arg, self._style);
        self._buf += ")";
    }

    priv fn _print_typeof(self, expr: *TypeOfExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "typeof(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "typeof(";
            self._print(expr->operand);
            self._buf += ")";
        }
    }

    priv fn _print_eval(self, expr: *EvalExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "eval(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "eval ";
            self._print(expr->operand);
        }
    }

    priv fn _print_unsafe(self, expr: *UnsafeExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "unsafe(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "unsafe ";
            self._print(expr->operand);
        }
    }

    // ── Memory / lifetime ───────────────────────────────────────────

    priv fn _print_delete(self, expr: *DeleteExpr) {
        if self._style == PrintStyle::Debug {
            var arr_str = ("[]") if (expr->is_array) else ("");
            self._buf += f"delete{arr_str}(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._buf += "delete ";
            if expr->is_array { self._buf += "[] "; }
            self._print(expr->operand);
        }
    }

    // ── Pack expansion ──────────────────────────────────────────────

    priv fn _print_pack_expansion(self, expr: *PackExpansionExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "pack_expand(";
            self._print(expr->operand);
            self._buf += ")";
        } else {
            self._print(expr->operand);
            self._buf += "...";
        }
    }

    // ── Type cast ───────────────────────────────────────────────────

    priv fn _print_type_cast(self, expr: *TypeCastExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "cast(";
            self._print(expr->operand);
            self._buf += (", unsafe ") if (expr->is_unsafe) else (", ");
            self._buf += TypePrinter::print(expr->target, self._style);
            self._buf += ")";
        } else {
            self._print(expr->operand);
            self._buf += " as ";
            if expr->is_unsafe { self._buf += "unsafe "; }
            self._buf += TypePrinter::print(expr->target, self._style);
        }
    }

    // ── Type relation expressions ───────────────────────────────────

    priv fn _print_impl_conf(self, expr: *ImplConformanceExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "impl_check(";
            self._buf += TypePrinter::print(expr->subject, self._style);
            self._buf += ", ";
            self._buf += TypePrinter::print(expr->inter, self._style);
            self._buf += ")";
        } else {
            self._buf += TypePrinter::print(expr->subject, self._style);
            self._buf += " impl ";
            self._buf += TypePrinter::print(expr->inter, self._style);
        }
    }

    priv fn _print_derives_rel(self, expr: *DerivesRelationExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "derives_check(";
            self._buf += TypePrinter::print(expr->subject, self._style);
            self._buf += ", ";
            self._buf += TypePrinter::print(expr->base, self._style);
            self._buf += ")";
        } else {
            self._buf += TypePrinter::print(expr->subject, self._style);
            self._buf += " derives ";
            self._buf += TypePrinter::print(expr->base, self._style);
        }
    }

    // ── Sema-inserted ───────────────────────────────────────────────

    priv fn _print_boundary_cast(self, expr: *ImplicitBoundaryCastExpr) {
        if self._style == PrintStyle::Debug {
            self._buf += "boundary_cast(";
            self._print(expr->original);
            self._buf += ", ";
            self._buf += TypePrinter::print(expr->source_type, self._style);
            self._buf += " -> ";
            self._buf += TypePrinter::print(expr->target_type, self._style);
            self._buf += ")";
        } else {
            self._print(expr->original);
        }
    }
}