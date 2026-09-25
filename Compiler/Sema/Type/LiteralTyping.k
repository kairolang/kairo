/// --- The Kairo Project ------------------- Sema/Type/LiteralTyping.k --- ///
///
///   \brief Literal typing (lattice §5): expected-type-first, defaults of
///          i32 / f64, fit checked AT the literal. Not a conversion and never
///          consults the lattice.
///
///   \detail
///     An unsuffixed integer literal has no type of its own. With an expected
///     type it takes it and the value is range-checked; without one it is i32,
///     widening only when the value does not fit i32. A suffixed literal is
///     typed at the literal and then participates in conversion normally.
///
///     Unary minus on a literal is folded here (`-128` fits i8) through the
///     `negative` argument; OperatorTyping passes it.
///
///     Aggregate literals push the expected element type down and join what
///     comes back up. A list literal takes its target from the expected type:
///     `[T; N]`, Slice or Vector; with none it is `[T; N]`. The constructors a
///     Slice or Vector target is built through are bound here, so the lowering
///     never looks one up.
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
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Diagnostic::Registry::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::SymbolTable::*;
import AST::Node::Declarations::*;
import AST::LangItems::*;

class <T> LiteralTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === classification =====================================================

    /// Fill \p a's literal shape if \p e is an untyped literal (through parens
    /// and a leading unary minus). Returns true when it is.
    fn literal_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e   = dyn()->tu.strip_parens(e_in);
        var neg = false;
        if (e != &null) && isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if u->is_prefix() && (u->op_token.kind == TokenKind::OpMinus) {
                neg = true;
                e = dyn()->tu.strip_parens(u->operand);
            }
        }
        if e == &null { return false; }
        if isa::<IntegerLiteralExpr>(e) {
            var n = cast::<IntegerLiteralExpr>(e);
            if (n->imm == &null) || n->has_suffix() { return false; }
            a->lit     = LitKind::Int;
            a->lit_lo  = n->get_value_lo();
            a->lit_hi  = n->get_value_hi();
            a->lit_big = n->is_big();
            a->lit_neg = neg;
            return true;
        }
        if isa::<FloatingLiteralExpr>(e) {
            var n = cast::<FloatingLiteralExpr>(e);
            if (n->imm != &null) && n->has_suffix() { return false; }
            a->lit = LitKind::Float;
            return true;
        }
        if (!neg) && isa::<NullLiteralExpr>(e) {
            a->lit = (LitKind::NullPtr) if (cast::<NullLiteralExpr>(e)->is_ref) else (LitKind::Null);
            return true;
        }
        return false;
    }

    fn is_untyped_literal(self, e: *Expr) -> bool {
        var a = ArgInfo{};
        return self.literal_shape(e, &a);
    }

    /// A list literal in ARGUMENT position is ranked by shape and typed after
    /// selection, as an untyped scalar literal is (§5): it takes the
    /// parameter's type. Kept out of literal_shape because is_untyped_literal
    /// feeds operand unification, which a list has no part in.
    ///
    /// A literal a parent already typed is not deferred; its type is fixed.
    fn list_literal_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e = dyn()->tu.strip_parens(e_in);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return false; }
        var n = cast::<ListLiteralExpr>(e);
        if (n->type_ != &null) || n->is_poisoned() { return false; }
        a->lit = LitKind::List;

        // The children are collected first and appended in one run: typing an
        // element can itself append (a nested list literal), and the range
        // this ArgInfo names has to be contiguous.
        var kids = vec::<ListShape>();
        for var i: usize = 0; i < n->elements.size(); ++i {
            var el = dyn()->arg_info(n->elements[i]);
            if el.dependent { a->dependent = true; }
            var sh = ListShape{};
            sh.lit     = el.lit;
            sh.lit_lo  = el.lit_lo;
            sh.lit_hi  = el.lit_hi;
            sh.lit_big = el.lit_big;
            sh.lit_neg = el.lit_neg;
            sh.ty      = el.ty;
            sh.kids_lo = el.elems_lo;
            sh.kids_n  = el.elems_n;
            kids.push_back(sh);
        }
        a->elems_lo = dyn()->ovl.list_shapes.size();
        a->elems_n  = kids.size();
        for var i: usize = 0; i < kids.size(); ++i { dyn()->ovl.list_shapes.push_back(kids[i]); }
        return true;
    }

    // === integers ===========================================================

    fn type_int_literal(self, n: *IntegerLiteralExpr, expected: *Type, negative: bool) -> *Type {
        if n->imm == &null { dyn()->fail(n, "integer literal has no immediate data"); return &null; }
        var pb = dyn()->tu.builtin(BuiltinKind::USize)->size_bits;

        // suffixed: typed at the literal.
        if n->has_suffix() {
            var k = self._int_kind(n->get_bits(), n->is_unsigned());
            if k == BuiltinKind::COUNT {
                dyn()->fail(n, f"unknown integer literal suffix '{n->get_suffix_text()}\x27");
                return &null;
            }
            if !literal_fits_int(n->get_value_lo(), n->get_value_hi(), n->is_big(), negative, k, pb) {
                dyn()->fail(n, f"literal does not fit in '{builtin_info(k)->spelling}\x27");
                return &null;
            }
            return dyn()->tu.builtin(k);
        }

        // expected-type-first.
        var target = dyn()->tu.strip_nullable(expected);
        var tk = dyn()->tu.kind_of(target);
        if tk != BuiltinKind::COUNT {
            if builtin_info(tk)->is_integer() {
                if !literal_fits_int(n->get_value_lo(), n->get_value_hi(), n->is_big(), negative, tk, pb) {
                    dyn()->fail(n, f"literal '{n->get_spelling()}' does not fit in '{builtin_info(tk)->spelling}\x27");
                    return &null;
                }
                return target;
            }
            if builtin_info(tk)->is_float() { return target; }
        }

        // default: i32, widening only when it does not fit.
        var order = vec::<BuiltinKind>();
        order.push_back(BuiltinKind::I32);
        order.push_back(BuiltinKind::I64);
        order.push_back(BuiltinKind::I128);
        for var i: usize = 0; i < order.size(); ++i {
            if literal_fits_int(n->get_value_lo(), n->get_value_hi(), n->is_big(), negative, order[i], pb) {
                return dyn()->tu.builtin(order[i]);
            }
        }
        dyn()->fail(n, "integer literal is too large for any integer type without a suffix");
        return &null;
    }

    priv fn _int_kind(self, bits: u16, unsigned: bool) -> BuiltinKind {
        switch bits {
            case 8   { return (BuiltinKind::U8)   if (unsigned) else (BuiltinKind::I8);   }
            case 16  { return (BuiltinKind::U16)  if (unsigned) else (BuiltinKind::I16);  }
            case 32  { return (BuiltinKind::U32)  if (unsigned) else (BuiltinKind::I32);  }
            case 64  { return (BuiltinKind::U64)  if (unsigned) else (BuiltinKind::I64);  }
            case 128 { return (BuiltinKind::U128) if (unsigned) else (BuiltinKind::I128); }
            case 256 { return (BuiltinKind::U256) if (unsigned) else (BuiltinKind::I256); }
            case 512 { return (BuiltinKind::U512) if (unsigned) else (BuiltinKind::I512); }
            default  { return BuiltinKind::COUNT; }
        }
    }

    // === floats =============================================================

    fn type_float_literal(self, n: *FloatingLiteralExpr, expected: *Type) -> *Type {
        if n->imm == &null { dyn()->fail(n, "float literal has no immediate data"); return &null; }
        if n->has_suffix() {
            var k = self._float_kind(n->get_bits());
            if k == BuiltinKind::COUNT {
                dyn()->fail(n, f"unknown float literal suffix '{n->get_suffix_text()}\x27");
                return &null;
            }
            return dyn()->tu.builtin(k);
        }
        var target = dyn()->tu.strip_nullable(expected);
        if dyn()->tu.is_float(target) { return target; }
        return dyn()->tu.builtin(BuiltinKind::F64);
    }

    priv fn _float_kind(self, bits: u32) -> BuiltinKind {
        switch bits {
            case 16  { return BuiltinKind::F16;  }
            case 32  { return BuiltinKind::F32;  }
            case 64  { return BuiltinKind::F64;  }
            case 80  { return BuiltinKind::F80;  }
            case 128 { return BuiltinKind::F128; }
            case 256 { return BuiltinKind::F256; }
            case 512 { return BuiltinKind::F512; }
            default  { return BuiltinKind::COUNT; }
        }
    }

    // === the rest ===========================================================

    fn type_string_literal(self, n: *StringLiteralExpr, expected: *Type) -> *Type {
        for var i: usize = 0; i < n->parts.size(); ++i {
            dyn()->type_of(n->parts[i], &null);
        }
        var s = dyn()->tu.string_type();
        if s == &null {
            dyn()->missing_lang_item(n, "string");
            return &null;
        }
        return s;
    }

    fn type_char_literal(self, n: *CharacterLiteralExpr, expected: *Type) -> *Type {
        return dyn()->tu.builtin(BuiltinKind::Char);
    }

    fn type_bool_literal(self, n: *BooleanLiteralExpr, expected: *Type) -> *Type {
        return dyn()->tu.builtin(BuiltinKind::Bool);
    }

    /// `null` needs a nullable expected type; `&null` a pointer (or nullable
    /// pointer). Neither has a type of its own to fall back on.
    fn type_null_literal(self, n: *NullLiteralExpr, expected: *Type) -> *Type {
        if n->is_ref {
            if dyn()->tu.pointee(dyn()->tu.strip_nullable(expected)) != &null { return expected; }
            dyn()->fail(n, "cannot infer the pointer type of '&null' here; annotate the target");
            return &null;
        }
        if dyn()->tu.nullable_inner(expected) != &null { return expected; }
        dyn()->fail(n, "cannot infer the type of 'null' here; annotate the target with a nullable type");
        return &null;
    }

    fn type_list_literal(self, n: *ListLiteralExpr, expected: *Type) -> *Type {
        var ex = canon_unqual(dyn()->tu.strip_nullable(expected));
        var elem_expected = dyn()->tu.container_elem(ex);
        var elem: *Type = elem_expected;
        for var i: usize = 0; i < n->elements.size(); ++i {
            var t = dyn()->type_of(n->elements[i], elem_expected);
            if t == &null { continue; }
            if elem_expected != &null { dyn()->check_convertible(n->elements[i], elem_expected); continue; }
            var j = dyn()->conv.join(elem, t);
            if j == &null {
                dyn()->fail(n->elements[i], f"list element of type '{dyn()->tu.str(t)}' does not match the earlier element type '{dyn()->tu.str(elem)}\x27");
                return &null;
            }
            elem = j;
        }
        var count = n->elements.size();
        if elem == &null {
            if count == 0 { dyn()->fail(n, "cannot infer the element type of an empty list; annotate the target"); }
            return &null;
        }

        // `[T; N]`: the literal IS the array, element for element.
        if (ex != &null) && isa::<FixedArrayType>(ex) && (!cast::<FixedArrayType>(ex)->is_incomplete) {
            var at = cast::<FixedArrayType>(ex);
            if count == 0 { dyn()->fail(n, "an array literal needs at least one element"); return &null; }
            if static_cast::<usize>(at->size_bits) != count {
                dyn()->fail(n, f"array literal has {count} element(s), but '{dyn()->tu.str(ex)}' needs {at->size_bits}");
                return &null;
            }
            return ex;
        }

        // `[T;]`: a view over a backing array ListLiteralLowering provides.
        if (ex != &null) && dyn()->tu.is_slice(ex) {
            if !self._bind_slice_ctor(n) { return &null; }
            return ex;
        }

        // `[T]`: an owner, built from that same view. Empty is the default ctor.
        if (ex != &null) && dyn()->tu.is_vector_like(ex) {
            if count == 0 {
                n->owner_ctor = self._lang_ctor(WellKnownType::Vector, 0, false);
            } else {
                if !self._bind_slice_ctor(n) { return &null; }
                n->owner_ctor = self._lang_ctor(WellKnownType::Vector, 1, true);
            }
            if n->owner_ctor == &null { dyn()->missing_lang_item(n, "Vector"); return &null; }
            return ex;
        }

        // No container target: the literal's own type.
        if count == 0 {
            dyn()->fail(n, "cannot infer the type of an empty list here; annotate the target as '[T;]' or '[T]\x27");
            return &null;
        }
        return dyn()->sc->types->array(elem, static_cast::<u64>(count));
    }

    priv fn _bind_slice_ctor(self, n: *ListLiteralExpr) -> bool {
        n->slice_ctor = self._lang_ctor(WellKnownType::Slice, 2, false);
        if n->slice_ctor == &null { dyn()->missing_lang_item(n, "Slice"); return false; }
        return true;
    }

    /// A lang record's constructor BY SHAPE: \p nparams non-self parameters,
    /// and for \p from_slice the single one is a Slice. Found through the lang
    /// item, never by name.
    priv fn _lang_ctor(self, k: WellKnownType, nparams: usize, from_slice: bool) -> *Decl {
        var d = dyn()->sc->well_known->get(k);
        if d == &null { return &null; }
        var body = dyn()->tu.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        if dc == &null { return &null; }
        var cell = dyn()->sc->lookup.in_context(dc, DeclName::ctor());
        if !cell.found() { return &null; }
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cell.cell->get(i));
            if f == &null { continue; }
            var n: usize = 0;
            var only: *ParamDecl = &null;
            for var p: usize = 0; p < f->params.size(); ++p {
                var pd = f->params[p];
                if (pd == &null) || pd->is_self { continue; }
                n += 1;
                only = pd;
            }
            if n != nparams { continue; }
            if from_slice {
                if (only == &null) || (only->type_ == &null) || (!dyn()->tu.is_slice(only->type_->canonical)) { continue; }
            }
            return cell.cell->get(i);
        }
        return &null;
    }

    // === list storage =======================================================

    fn is_slice_literal(self, e_in: *Expr) -> bool {
        var e = dyn()->tu.strip_parens(e_in);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return false; }
        return (e->type_ != &null) && dyn()->tu.is_slice(e->type_);
    }

    /// A slice literal that directly initializes a `var` gets a backing array
    /// in that var's scope, and so does every slice literal nested in it.
    fn mark_list_storage(self, init: *Expr) {
        if !self.is_slice_literal(init) { return; }
        var n = cast::<ListLiteralExpr>(dyn()->tu.strip_parens(init));
        n->storage = ListStorage::Extended;
        for var i: usize = 0; i < n->elements.size(); ++i { self.mark_list_storage(n->elements[i]); }
    }

    /// The positions with no scope to extend a backing array into. A callee
    /// that RETAINS a slice argument is not decidable here; that is AMT's
    /// escape clause.
    fn reject_slice_literal(self, e: *Expr, what: string) -> bool {
        if !self.is_slice_literal(e) { return false; }
        dyn()->fail(dyn()->tu.strip_parens(e),
            f"a list literal {what} is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first");
        return true;
    }

    /// An array is initialized from a list literal and from nothing else:
    /// copying one is not an initialization C++ has. A variable's
    /// initializer and an aggregate initializer's field value both land
    /// here; true when \p value was rejected.
    fn reject_array_copy(self, value: *Expr, t: *Type) -> bool {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<FixedArrayType>(c)) { return false; }
        var v = dyn()->tu.strip_parens(value);
        if (v == &null) || v->is_poisoned() || isa::<ListLiteralExpr>(v) { return false; }
        dyn()->fail(v, "an array is not copyable; initialize it from a list literal, or view the source through a slice or a pointer");
        return true;
    }

    fn type_set_literal(self, n: *SetLiteralExpr, expected: *Type) -> *Type {
        var elem_expected = dyn()->tu.container_elem(dyn()->tu.strip_nullable(expected));
        var elem: *Type = elem_expected;
        for var i: usize = 0; i < n->elements.size(); ++i {
            var t = dyn()->type_of(n->elements[i], elem_expected);
            if t == &null { continue; }
            if elem_expected != &null { dyn()->check_convertible(n->elements[i], elem_expected); continue; }
            var j = dyn()->conv.join(elem, t);
            if j == &null { dyn()->fail(n->elements[i], "set elements do not share a type"); return &null; }
            elem = j;
        }
        if elem == &null {
            if n->elements.size() == 0 { dyn()->fail(n, "cannot infer the element type of an empty set; annotate the target"); }
            return &null;
        }
        return dyn()->tu.set_of(elem);
    }

    fn type_map_literal(self, n: *MapLiteralExpr, expected: *Type) -> *Type {
        var ek: *Type = &null; var ev: *Type = &null;
        dyn()->tu.map_key_value(dyn()->tu.strip_nullable(expected), &ek, &ev);
        var k: *Type = ek; var v: *Type = ev;
        for var i: usize = 0; i < n->entries.size(); ++i {
            var en = n->entries.get(i);
            var kt = dyn()->type_of(en->key, ek);
            var vt = dyn()->type_of(en->value, ev);
            if ek != &null { dyn()->check_convertible(en->key, ek); }
            else if kt != &null {
                var j = dyn()->conv.join(k, kt);
                if j == &null { dyn()->fail(en->key, "map keys do not share a type"); return &null; }
                k = j;
            }
            if ev != &null { dyn()->check_convertible(en->value, ev); }
            else if vt != &null {
                var j = dyn()->conv.join(v, vt);
                if j == &null { dyn()->fail(en->value, "map values do not share a type"); return &null; }
                v = j;
            }
        }
        if (k == &null) || (v == &null) {
            if n->entries.size() == 0 { dyn()->fail(n, "cannot infer the key and value types of an empty map; annotate the target"); }
            return &null;
        }
        return dyn()->tu.map_of(k, v);
    }

    fn type_tuple_literal(self, n: *TupleLiteralExpr, expected: *Type) -> *Type {
        var ex = canon_unqual(dyn()->tu.strip_nullable(expected));
        var et: *TupleType = &null;
        if (ex != &null) && isa::<TupleType>(ex) && (cast::<TupleType>(ex)->elements.size() == n->elements.size()) {
            et = cast::<TupleType>(ex);
        }
        var elems = vec::<*Type>();
        var ok = true;
        for var i: usize = 0; i < n->elements.size(); ++i {
            var e_exp: *Type = (et->elements[i]) if (et != &null) else (&null);
            var t = dyn()->type_of(n->elements[i], e_exp);
            if t == &null { ok = false; continue; }
            if e_exp != &null { dyn()->check_convertible(n->elements[i], e_exp); }
            elems.push_back(t);
        }
        if !ok { return &null; }
        return dyn()->sc->types->tuple(&elems);
    }
}
