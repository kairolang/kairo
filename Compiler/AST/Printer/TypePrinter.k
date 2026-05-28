/// --- The Kairo Project --------------- Compiler/AST/TypePrinter.k ----- ///
///
///   A simple pretty-printer for type nodes.
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
import ASTNode::Types::*;
import ASTNode::Casting::*;
import TokenKind::*;

/// How the printer formats type output.
///
/// Debug     structural, shows all detail, meant for compiler devs
/// Diagnostic user-facing, matches Kairo source syntax as closely as possible
/// Canonical  fully qualified, no sugar, no inference placeholders
enum PrintStyle derives u8 {
    Debug,      // *named(i32), tuple(i32, bool), recovery(PointerType)
    Diagnostic, // *i32, (i32, bool), <error>
    Canonical,  // same as Diagnostic for now, extended by sema later
}

class TypePrinter {
    var _buf:   string;
    var _style: PrintStyle;

    //  Public entry point

    static fn print(ty: *Type, style: PrintStyle = PrintStyle::Diagnostic) -> string {
        var p    = TypePrinter{};
        p._style = style;
        p._buf   = "";
        p._print(ty);
        return p._buf;
    }

    //  Token spelling helper
    //  Full SourceManager integration is deferred for now return the raw
    //  spelling from the token itself. Macro-expanded tokens return their
    //  original kind spelling; the caller can layer SM on top later.

    static fn tok_spelling(tok: Token) -> string {
        // TODO: thread SourceManager tok only carries kind + range + imm
        // SM lookup: sm->get_text(tok.range)
        // For now fall back to the kind string so diagnostics aren't empty
        return token_kind_to_readable_string(tok.kind);
    }

    //  Qualifier prefix
    //  Emits leading qualifier keywords before a type token.
    //  Order matches Kairo grammar: const volatile atomic unsafe eval async yield

    priv fn _print_quals(self, ty: *Type) {
        type TQ = TypeQual::<Type>;
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsConst))    { self._buf += "const ";    }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsVolatile)) { self._buf += "volatile "; }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsAtomic))   { self._buf += "atomic ";   }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsUnsafe))   { self._buf += "unsafe ";   }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsEval))     { self._buf += "eval ";     }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsAsync))    { self._buf += "async ";    }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsYield))    { self._buf += "yield ";    }
        if (static_cast::<u8>(ty->flags)) & (static_cast::<u8>(TQ::Flags::IsPanic))    { self._buf += "panic ";    }
    }

    //  Core dispatch

    priv fn _print(self, ty: *Type) {
        if ty == &null {
            self._buf += ("<null>") if (self._style == PrintStyle::Debug) else ("<error>");
            return;
        }

        if ty->is_error() {
            self._print_recovery(ty);
            return;
        }

        if isa::<ChainType>(ty)              { self._print_chain(cast::<ChainType>(ty));                         return; }
        if isa::<GenericParamType>(ty)       { self._print_generic_param(cast::<GenericParamType>(ty));          return; }
        if isa::<SubstGenericParamType>(ty)  { self._print_subst_generic(cast::<SubstGenericParamType>(ty));     return; }
        if isa::<TypeOfType>(ty)             { self._print_typeof(cast::<TypeOfType>(ty));                       return; }
        if isa::<VariadicPackType>(ty)       { self._print_variadic_pack(cast::<VariadicPackType>(ty));          return; }
        if isa::<PackExpansionType>(ty)      { self._print_pack_expansion(cast::<PackExpansionType>(ty));        return; }
        if isa::<PointerType>(ty)            { self._print_pointer(cast::<PointerType>(ty));                     return; }
        if isa::<NullableType>(ty)           { self._print_nullable(cast::<NullableType>(ty));                   return; }
        if isa::<TupleType>(ty)              { self._print_tuple(cast::<TupleType>(ty));                         return; }
        if isa::<FixedArrayType>(ty)         { self._print_fixed_array(cast::<FixedArrayType>(ty));              return; }
        if isa::<VectorType>(ty)             { self._print_vector(cast::<VectorType>(ty));                       return; }
        if isa::<MapType>(ty)                { self._print_map(cast::<MapType>(ty));                             return; }
        if isa::<SetType>(ty)                { self._print_set(cast::<SetType>(ty));                             return; }
        if isa::<SelfType>(ty)               { self._print_self(cast::<SelfType>(ty));                           return; }
        if isa::<FunctionPointerType>(ty)    { self._print_fn_ptr(cast::<FunctionPointerType>(ty));              return; }
        if isa::<InferredType>(ty)           { self._print_inferred(cast::<InferredType>(ty));                   return; }
        if isa::<CXXLValueRefType>(ty)       { self._print_cxx_lref(cast::<CXXLValueRefType>(ty));               return; }
        if isa::<CXXRValueRefType>(ty)       { self._print_cxx_rref(cast::<CXXRValueRefType>(ty));               return; }
        if isa::<OpaqueFFIType>(ty)          { self._print_opaque_ffi(cast::<OpaqueFFIType>(ty));                return; }
        if isa::<TypeExpr>(ty)               { self._print_type_expr(cast::<TypeExpr>(ty));                      return; }

        // unknown kind shouldn't happen in a well-formed AST
        self._buf += (f"<unknown kind={static_cast::<u32>(ty->kind)}>")
            if (self._style == PrintStyle::Debug)
            else "<error>";
    }

    //  Recovery

    priv fn _print_recovery(self, ty: *Type) {
        if self._style == PrintStyle::Debug {
            self._buf += f"<recovery:{static_cast::<u32>(ty->recovery_kind)}>";
        } else {
            self._buf += "<error>";
        }
    }

    //  GenericParamType   T | ...T

    priv fn _print_generic_param(self, ty: *GenericParamType) {
        self._print_quals(ty);
        if ty->is_pack { self._buf += "..."; }
        if ty->param_name == &null {
            self._buf += ("<unnamed-param>") if (self._style == PrintStyle::Debug) else "<error>";
        } else {
            if self._style == PrintStyle::Debug {
                self._buf += f"param({TypePrinter::tok_spelling(ty->param_name->name)})";
            } else {
                self._buf += TypePrinter::tok_spelling(ty->param_name->name);
            }
        }
    }

    //  SubstGenericParamType   (T -> i32 substitution wrapper)

    priv fn _print_subst_generic(self, ty: *SubstGenericParamType) {
        if self._style == PrintStyle::Debug {
            self._buf += "subst(";
            self._print(ty->original);
            self._buf += " -> ";
            self._print(ty->replacement);
            self._buf += ")";
        } else {
            // user sees the concrete replacement type, not the wrapper
            self._print(ty->replacement);
        }
    }

    //  ChainType   i32 | Foo::Bar | Vec<i32> | std::Map<K, V>::Iterator

    priv fn _print_chain(self, ty: *ChainType) {
        self._print_quals(ty);

        if ty->segments.is_empty() {
            self._buf += ("<empty-chain>") if (self._style == PrintStyle::Debug) else "<error>";
            return;
        }

        for var i: usize = 0; i < ty->segments.size(); ++i {
            var seg = ty->segments.get(i);

            if seg->sep == ChainType::SegmentSeparator::ColonColon {
                self._buf += "::";
            }

            if seg->name == &null {
                self._buf += "<error>";
                continue;
            }

            if self._style == PrintStyle::Debug && ty->is_simple() {
                self._buf += f"named({TypePrinter::tok_spelling(seg->name->name)})";
            } else {
                self._buf += TypePrinter::tok_spelling(seg->name->name);
            }

            if !seg->generic_args.is_empty() {
                self._buf += "<";
                for var j: usize = 0; j < seg->generic_args.size(); ++j {
                    if j > 0 { self._buf += ", "; }
                    var arg = seg->generic_args.get(j);
                    if arg->name != &null {
                        self._buf += TypePrinter::tok_spelling(arg->name->name);
                        self._buf += ": ";
                    }
                    self._print(arg->ty);
                }
                self._buf += ">";
            }
        }
    }

    //  TypeOfType   typeof(expr)

    priv fn _print_typeof(self, ty: *TypeOfType) {
        self._print_quals(ty);
        if self._style == PrintStyle::Debug && ty->resolved != &null {
            self._buf += "typeof(/* resolved: ";
            self._print(ty->resolved);
            self._buf += " */)";
        } else {
            self._buf += "typeof(...)";
        }
    }

    //  VariadicPackType   ...T (declaration site)

    priv fn _print_variadic_pack(self, ty: *VariadicPackType) {
        self._buf += "...";
        self._print(ty->param);
    }

    //  PackExpansionType   pattern... (use site)

    priv fn _print_pack_expansion(self, ty: *PackExpansionType) {
        self._print(ty->pattern);
        self._buf += "...";
    }

    //  PointerType   *T | *const T | **T

    priv fn _print_pointer(self, ty: *PointerType) {
        self._print_quals(ty);   // moved BEFORE the *
        self._buf += "*";
        self._print(ty->pointee);
    }

    //  NullableType   T?

    priv fn _print_nullable(self, ty: *NullableType) {
        self._print_quals(ty);
        self._print(ty->inner);
        self._buf += "?";
    }

    //  TupleType   (i32, bool, f64)

    priv fn _print_tuple(self, ty: *TupleType) {
        self._print_quals(ty);
        self._buf += "(";
        for var i: usize = 0; i < ty->elements.size(); ++i {
            if i > 0 { self._buf += ", "; }
            self._print(ty->elements[i]);
        }
        self._buf += ")";
    }

    //  FixedArrayType   [i32; 10] | [i32;] (incomplete)

    priv fn _print_fixed_array(self, ty: *FixedArrayType) {
        self._print_quals(ty);
        self._buf += "[";
        self._print(ty->element);
        self._buf += "; ";
        if ty->is_incomplete || ty->size_expr == &null {
            self._buf += "?" if (self._style == PrintStyle::Debug) else "";
        } else {
            // TODO: thread ExprPrinter here once expr printing is built
            //       for now emit a placeholder so diagnostics aren't empty
            self._buf += "<N>";
        }
        self._buf += "]";
    }

    //  VectorType   [i32]

    priv fn _print_vector(self, ty: *VectorType) {
        self._print_quals(ty);
        self._buf += "[";
        self._print(ty->element);
        self._buf += "]";
    }

    //  MapType   {K: V}

    priv fn _print_map(self, ty: *MapType) {
        self._print_quals(ty);
        self._buf += "{";
        self._print(ty->key);
        self._buf += ": ";
        self._print(ty->value);
        self._buf += "}";
    }

    //  SetType   {T}

    priv fn _print_set(self, ty: *SetType) {
        self._print_quals(ty);
        self._buf += "{";
        self._print(ty->element);
        self._buf += "}";
    }

    //  SelfType   Self

    priv fn _print_self(self, ty: *SelfType) {
        self._print_quals(ty);
        self._buf += "Self";
    }

    //  FunctionPointerType   fn(i32, str) -> bool

    priv fn _print_fn_ptr(self, ty: *FunctionPointerType) {
        self._print_quals(ty);
        self._buf += "fn(";

        if ty->is_unprototyped {
            self._buf += "...";
        } else {
            for var i: usize = 0; i < ty->params.size(); ++i {
                if i > 0 { self._buf += ", "; }
                self._print(ty->params[i]);
            }
        }

        self._buf += ")";

        if ty->return_type != &null {
            if self._style == PrintStyle::Debug || !isa::<ChainType>(ty->return_type) {
                self._buf += " -> ";
                self._print(ty->return_type);
            } else {
                var ct = cast::<ChainType>(ty->return_type);
                if (ct->is_simple()) && (ct->trailing_name() != &null)
                && (TypePrinter::tok_spelling(ct->trailing_name()->name) != "void") {
                    self._buf += " -> ";
                    self._print(ty->return_type);
                }
                else if !ct->is_simple() {
                    // multi-segment or generic   always print
                    self._buf += " -> ";
                    self._print(ty->return_type);
                }
            }
        }
    }

    //  InferredType _

    priv fn _print_inferred(self, ty: *InferredType) {
        if self._style == PrintStyle::Debug {
            self._buf += f"_${ty->infer_id}";
        } else {
            self._buf += "_";
        }
    }

    //  CXXLValueRefType   T& (C++ import only)

    priv fn _print_cxx_lref(self, ty: *CXXLValueRefType) {
        self._print_quals(ty);
        self._print(ty->referee);
        self._buf += "&";
    }

    //  CXXRValueRefType   T&& (C++ import only)

    priv fn _print_cxx_rref(self, ty: *CXXRValueRefType) {
        self._print_quals(ty);
        self._print(ty->referee);
        self._buf += "&&";
    }

    //  OpaqueFFIType   ffi "c++" opaque

    priv fn _print_opaque_ffi(self, ty: *OpaqueFFIType) {
        if self._style == PrintStyle::Debug {
            self._buf += f"ffi({ty->name})";
        } else {
            self._buf += "opaque_ffi" if (self._style == PrintStyle::Diagnostic) else "<error>";
        }
    }

    //  TypeExpr   typeof-like but wraps an already-parsed Expr

    priv fn _print_type_expr(self, ty: *TypeExpr) {
        self._print_quals(ty);
        // TODO: thread ExprPrinter here
        if self._style == PrintStyle::Debug {
            self._buf += "type_expr(<expr>)";
        } else {
            self._buf += "<expr>";
        }
    }
}