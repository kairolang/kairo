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
import Sema::Resolve::MemberLookup::*;
import AST::OperatorFacts::*;
import Support::UTF8View::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

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

    /// Every literal is a `string`. A plain one gets its constructor bound; a
    /// format one gets, per hole, everything FStringLowering needs to mint
    /// without a lookup: the kind, the conversion, the packed spec.
    fn type_string_literal(self, n: *StringLiteralExpr, expected: *Type) -> *Type {
        var s = dyn()->tu.string_type();
        if s == &null { dyn()->missing_lang_item(n, "string"); return &null; }

        n->string_ctor = self._lang_ctor(WellKnownType::String, 3, false);
        if n->string_ctor == &null { dyn()->missing_lang_item(n, "string"); return &null; }
        if !n->is_format() { return s; }

        if n->imm == &null { dyn()->fail(n, "format string literal has no immediate data"); return &null; }
        if !self._type_format_literal(n, s) { dyn()->poison_only(n); return &null; }
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

    priv fn _type_format_literal(self, n: *StringLiteralExpr, s: *Type) -> bool {
        var holes = n->get_holes();
        ICE_IF(holes->size() != n->parts.size(), "LiteralTyping: lexer hole facts not parallel to the parser's parts");

        var fb = dyn()->sc->well_known->get(WellKnownType::FmtBuf);
        if fb == &null { dyn()->missing_lang_item(n, "FmtBuf"); return false; }
        n->fmt_ctor   = self._lang_ctor(WellKnownType::FmtBuf, 1, false);
        n->fmt_text   = self._lang_method(WellKnownType::FmtBuf, "text");
        n->fmt_finish = self._lang_method(WellKnownType::FmtBuf, "finish");
        n->fmt_len    = self._lang_field(WellKnownType::String, "len");
        if (n->fmt_ctor == &null) || (n->fmt_text == &null) || (n->fmt_finish == &null) || (n->fmt_len == &null) {
            dyn()->missing_lang_item(n, "FmtBuf");
            return false;
        }

        var ok  = true;
        var out = vec::<FormatHole>();
        for var i: usize = 0; i < n->parts.size(); ++i {
            var e = n->parts[i];
            var t = dyn()->type_of(e, &null);
            if e->is_poisoned() { ok = false; continue; }
            if t == &null {
                // Untyped and not poisoned: dependent. Lower/ runs once, before M2.
                dyn()->fail(e, "an interpolation in a generic body needs a concrete type; format it in the caller");
                ok = false;
                continue;
            }

            var h = FormatHole{};
            h.kind = FormatKind::None; h.spec = 0; h.put = &null; h.conv = &null;
            h.cast_to = &null; h.by_addr = false; h.doc = (*holes)[i].doc;

            var repr: *Decl = &null;
            var conv: *Decl = &null;
            if !self._classify_hole(e, t, &h, &repr, &conv) { ok = false; continue; }
            if !self._parse_spec(n, (*holes)[i].spec, h.kind, t, &(h.spec)) { ok = false; continue; }

            // A record: user repr, then user `op as`, then the address form.
            // `?` skips `op as`: it asks for the repr form or nothing.
            if h.kind == FormatKind::None {
                var debug = ((h.spec >> 57) & FMT_DEBUG()) != 0;
                if repr != &null                  { h.conv = repr; h.kind = FormatKind::String; }
                else if (conv != &null) && !debug { h.conv = conv; h.kind = FormatKind::String; }
                else { h.kind = FormatKind::Ptr; h.by_addr = true; h.cast_to = dyn()->tu.builtin(BuiltinKind::USize); }
            }

            h.put = self._lang_method(WellKnownType::FmtBuf, fmt_put_name(h.kind));
            if h.put == &null { dyn()->missing_lang_item(n, "FmtBuf"); ok = false; continue; }
            out.push_back(h);
        }
        if !ok { return false; }
        n->fmt_holes.from_buf(out.data(), out.size(), dyn()->sc->ctx);
        return true;
    }

    /// The put row for a hole's value type. A record leaves `kind` as None
    /// with its candidates in \p repr / \p conv; the caller ranks them.
    priv fn _classify_hole(self, e: *Expr, t: *Type, h: *FormatHole, repr: *(*Decl), conv: *(*Decl)) -> bool {
        var v = dyn()->tu.as_value(t);
        if v == &null { return false; }
        if v->is_dependent() {
            dyn()->fail(e, "an interpolation in a generic body needs a concrete type; format it in the caller");
            return false;
        }
        if dyn()->tu.nullable_inner(v) != &null {
            dyn()->fail(e, f"a value of type '{dyn()->tu.str(v)}' has no formatter yet; test it and format the inner value");
            return false;
        }
        if dyn()->tu.pointee(v) != &null {
            h->kind    = FormatKind::Ptr;
            h->cast_to = dyn()->tu.builtin(BuiltinKind::USize);
            return true;
        }
        var bk = dyn()->tu.kind_of(v);
        if bk != BuiltinKind::COUNT {
            var fk = format_kind_of(bk);
            if fk == FormatKind::COUNT {
                dyn()->fail(e, f"a value of type '{dyn()->tu.str(v)}' cannot be formatted");
                return false;
            }
            h->kind = fk;
            return true;
        }
        if dyn()->tu.is_string(v) { h->kind = FormatKind::String; return true; }

        var d = dyn()->tu.record_decl(v);
        if d == &null {
            dyn()->fail(e, f"a value of type '{dyn()->tu.str(v)}' has no formatter");
            return false;
        }
        var en = dyn_cast::<EnumDecl>(NameLookup::representative(d));
        if (en != &null) && (!en->is_adt) {
            // A plain enum prints its discriminant until the synthesized repr exists.
            var under: *Type = &null;
            if (en->underlying != &null) && (en->underlying->canonical != &null) { under = canon_unqual(en->underlying->canonical); }
            if under == &null { under = dyn()->tu.builtin(BuiltinKind::U32); }
            h->kind    = format_kind_of(dyn()->tu.kind_of(under));
            h->cast_to = under;
            return h->kind != FormatKind::COUNT;
        }
        self._string_conv(v, repr, conv);
        return true;   // kind stays None; the caller ranks.
    }

    /// `fn repr(self) -> string` and `fn op as(self) -> string` on \p v, own
    /// members and extensions alike, in that order of preference. Through
    /// ExprTyper's MemberLookup, whose extension index is built once at
    /// construction.
    priv fn _string_conv(self, v: *Type, repr: *(*Decl), conv: *(*Decl)) {
        var s = dyn()->tu.string_type();

        var imm   = dyn()->sc->imm_table()->intern_ident_copy("repr");
        var cands = vec::<*Decl>();
        dyn()->ml.lookup(v, DeclName::ident(imm), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cands[i]);
            if (f == &null) || (!f->is_method()) || f->is_operator { continue; }
            if (OperatorFacts::arity(f) != 0) || !self._returns(f, s) { continue; }
            (*repr) = cands[i];
            break;
        }

        cands.clear();
        dyn()->ml.lookup(v, DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cands[i]);
            if (f == &null) || (!f->is_method()) || (!f->is_operator) { continue; }
            if (OperatorFacts::arity(f) != 0) || !self._returns(f, s) { continue; }
            (*conv) = cands[i];
            break;
        }
    }

    priv fn _returns(self, f: *FunctionDecl, t: *Type) -> bool {
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return false; }
        return canon_unqual(f->return_type->canonical) == canon_unqual(t);
    }

    /// A lang record's method by NAME, spelled into that record's own TU.
    priv fn _lang_method(self, k: WellKnownType, name: string) -> *Decl {
        var d = dyn()->sc->well_known->get(k);
        if d == &null { return &null; }
        var body = dyn()->tu.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        if dc == &null { return &null; }
        var imm  = dyn()->sc->imm_table()->intern_ident_copy(name);
        var cell = dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), name);
        if !cell.found() { return &null; }
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cell.cell->get(i));
            if (f != &null) && f->is_method() { return cell.cell->get(i); }
        }
        return &null;
    }

    priv fn _lang_field(self, k: WellKnownType, name: string) -> *Decl {
        var d = dyn()->sc->well_known->get(k);
        if d == &null { return &null; }
        var body = dyn()->tu.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        if dc == &null { return &null; }
        var imm  = dyn()->sc->imm_table()->intern_ident_copy(name);
        var cell = dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), name);
        if !cell.found() { return &null; }
        var fd = dyn_cast::<FieldDecl>(cell.first());
        return static_cast::<*Decl>(fd);
    }

    // === format specs =======================================================
    //
    //   spec := [[fill] align] ['+'] ['#'] ['0'] [width] ['.' precision] [type] | '?'
    //   align := '<' | '>' | '^'      type := 'x' | 'X' | 'o' | 'b' | 'e' | 'E'
    //
    // Parsed here, packed into one word (LangItems::fmt_pack_spec), validated
    // against the hole's kind. Reported at the spec's own bytes.

    priv fn _is_align(self, b: u8) -> bool { return (b == '<') || (b == '>') || (b == '^'); }

    priv fn _align_code(self, b: u8) -> u64 {
        if b == '<' { return static_cast::<u64>(FormatAlign::Left); }
        if b == '>' { return static_cast::<u64>(FormatAlign::Right); }
        return static_cast::<u64>(FormatAlign::Center);
    }

    priv fn _spec_error(self, n: *StringLiteralExpr, at: SourceRange, spelled: string, t: *Type, why: string) -> bool {
        dyn()->sc->diag->report(DiagID::SC001E, at.start,
            f"invalid format spec '{spelled}' for a value of type '{dyn()->tu.str(t)}': {why}"
        ).first(at).emit();
        return false;
    }

    priv fn _parse_spec(self, n: *StringLiteralExpr, at: SourceRange, kind: FormatKind, t: *Type, out: *u64) -> bool {
        (*out) = 0;
        if !at.is_valid() { return true; }

        var view    = dyn()->sc->ctx->sm->get_view(at);
        var p       = view.data();
        var len     = view.size();
        var spelled = dyn()->sc->ctx->sm->get_text(at);

        var is_int   = (kind >= FormatKind::I8)     && (kind <= FormatKind::USize);
        var is_float = (kind >= FormatKind::F8E4M3) && (kind <= FormatKind::F512);
        var is_text  = (kind == FormatKind::String) || (kind == FormatKind::Char) || (kind == FormatKind::Bool);
        var is_rec   = kind == FormatKind::None;

        if (len == 1) && (p[0] == '?') {
            (*out) = fmt_pack_spec(0, 0, 0, 0, 0, static_cast::<u64>(FMT_DEBUG()));
            return true;
        }
        if kind == FormatKind::Ptr { return self._spec_error(n, at, spelled, t, "a pointer takes no format spec"); }

        var width: u64 = 0; var prec1: u64 = 0; var fill: u64 = 0;
        var align: u64 = 0; var base:  u64 = 0; var flags: u64 = 0;
        var type_ch: u8 = 0;
        var i: usize = 0;

        var first = UTF8View::decode_utf8(p, len);
        if (first.len > 0) && (first.len < len) && self._is_align(p[first.len]) {
            fill  = static_cast::<u64>(first.chr);
            align = self._align_code(p[first.len]);
            i     = first.len + 1;
        } else if (len > 0) && self._is_align(p[0]) {
            align = self._align_code(p[0]);
            i     = 1;
        }

        if (i < len) && (p[i] == '+') { flags |= static_cast::<u64>(FMT_SIGN_PLUS()); i += 1; }
        else if (i < len) && (p[i] == '-') { return self._spec_error(n, at, spelled, t, "'-' is the default sign; remove it"); }
        if (i < len) && (p[i] == '#') { flags |= static_cast::<u64>(FMT_ALT()); i += 1; }
        if (i < len) && (p[i] == '0') { flags |= static_cast::<u64>(FMT_ZERO()); i += 1; }
        while (i < len) && (p[i] >= '0') && (p[i] <= '9') {
            width = width * 10 + static_cast::<u64>(p[i] - '0');
            if width > 0xFFFF { return self._spec_error(n, at, spelled, t, "width is limited to 65535"); }
            i += 1;
        }
        if (i < len) && (p[i] == '.') {
            i += 1;
            var digits: usize = 0;
            var prec: u64 = 0;
            while (i < len) && (p[i] >= '0') && (p[i] <= '9') {
                prec = prec * 10 + static_cast::<u64>(p[i] - '0');
                if prec > 0xFFFE { return self._spec_error(n, at, spelled, t, "precision is limited to 65534"); }
                i += 1; digits += 1;
            }
            if digits == 0 { return self._spec_error(n, at, spelled, t, "'.' must be followed by a precision"); }
            prec1 = prec + 1;
        }
        if i < len {
            type_ch = p[i];
            switch type_ch {
                case 'x' { base = 1; }
                case 'X' { base = 1; flags |= static_cast::<u64>(FMT_UPPER()); }
                case 'o' { base = 2; }
                case 'b' { base = 3; }
                case 'e' { base = 1; }
                case 'E' { base = 1; flags |= static_cast::<u64>(FMT_UPPER()); }
                default  { return self._spec_error(n, at, spelled, t, f"'{spelled.raw_string().substr(i)}' is not a format type"); }
            }
            i += 1;
        }
        if i < len { return self._spec_error(n, at, spelled, t, "unexpected characters after the format type"); }

        // Per kind.
        if is_int {
            if prec1 != 0 { return self._spec_error(n, at, spelled, t, "precision applies to floats and strings"); }
            if (type_ch == 'e') || (type_ch == 'E') { return self._spec_error(n, at, spelled, t, "'e' applies to floats"); }
        } else if is_float {
            if (type_ch == 'x') || (type_ch == 'X') || (type_ch == 'o') || (type_ch == 'b') {
                return self._spec_error(n, at, spelled, t, "an integer base applies to integers");
            }
            if (flags & static_cast::<u64>(FMT_ALT())) != 0 { return self._spec_error(n, at, spelled, t, "'#' applies to integers"); }
        } else if kind == FormatKind::Byte {
            if (prec1 != 0) || (type_ch != 0) || ((flags & (static_cast::<u64>(FMT_SIGN_PLUS()) | static_cast::<u64>(FMT_ZERO()))) != 0) {
                return self._spec_error(n, at, spelled, t, "a byte takes width, alignment and '#' only");
            }
        } else if is_text || is_rec {
            if (type_ch != 0) || ((flags & (static_cast::<u64>(FMT_SIGN_PLUS()) | static_cast::<u64>(FMT_ALT()) | static_cast::<u64>(FMT_ZERO()))) != 0) {
                return self._spec_error(n, at, spelled, t, "text takes width, alignment and precision only");
            }
            if (prec1 != 0) && (kind != FormatKind::String) && (!is_rec) {
                return self._spec_error(n, at, spelled, t, "precision applies to floats and strings");
            }
        }

        (*out) = fmt_pack_spec(width, prec1, fill, align, base, flags);
        return true;
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
