/// --- The Kairo Project -------------------- Sema/Foreign/TypeExport.k --- ///
///
///   \brief Kairo CANONICAL type -> clang::QualType, against ONE HeaderSet's
///          ASTContext. The inverse of TypeImport::_map.
///
///   \detail
///     Exists for ForeignInstantiate: to ask clang for `cont<i32>` it has to
///     spell `i32` as a clang type in the AST that owns `cont`. Null QualType
///     for anything it cannot express, and the caller reads null as "cannot
///     instantiate in phase A" -- never as an error of the user's.
///
///     What cannot be expressed, and why:
///       generic params, opaque, anything dependent   no concrete clang type
///                                (a parameter IS expressible while a stand-in
///                                specialization is being defined; see below).
///       a Kairo record nested in another type, with a base, with a pack or
///       value parameter, an ADT with a pack-expanded variant
///                                no stand-in shape for it yet.
///       a decl from ANOTHER set  its clang_decl points into a different
///                                ASTContext. v1 instantiates only through
///                                the set the primary came from, so a decl
///                                of any other set is refused, not re-found.
///
///   \par Kairo records
///     phase A's AST has never heard of a Kairo-authored record, so
///     `std::vector<S>` declares a STAND-IN for `S` there first (_standin):
///     a complete C++ struct with S's non-static fields in order, declared
///     under exactly the qualified name EmitIR gives S (`::stem::S`). The
///     name is what makes it safe. Every spelling a fill records -- the
///     instance's own `::std::vector<::stem::S>`, a member typedef's path --
///     is printed from this AST, and phase B compiles it against the real
///     `S`; any other name would be a spelling that names nothing there.
///     The stand-in's USR is registered to S itself, so TypeImport reads
///     `S&` out of `reference` as the Kairo record, not as a foreign one.
///
///     A GENERIC Kairo record needs the same spelling to be a template-id:
///     `std::vector<G<i32>>` records `::stem::G<int>`. So the primary gets a
///     stand-in TEMPLATE (_standin_template) -- declared with its parameters,
///     never defined -- and each instance an EXPLICIT SPECIALIZATION of it
///     (_standin_instance), defined with the pattern's fields under that
///     instance's arguments. The specialization's USR is registered to the
///     instance, the template's to the primary, so TypeImport reads
///     `G<int>&` back as the registry instance the user already has.
///
///     A stand-in carries layout, not behaviour: no methods, and implicit
///     special members only (a Kairo destructor or deleted copy is not
///     mirrored). That is enough for phase A, which declares members and
///     never instantiates their bodies; phase B sees the real type.
///
///     Enums too. A plain enum's stand-in is a scoped enum of its word
///     (_standin_enum). An ADT's is a struct (_shape): its tag word, then
///     every variant's payload fields in sequence, which keeps the real
///     record's traits (it copies exactly when every payload does) where a
///     union would delete its copy. `T?` is the Nullable lang item's
///     instance over T (_nullable), so `vector<*Node?>` is
///     `::std::vector<::builtin::Nullable<::stem::Node *>>`, and TypeImport
///     reads that specialization back as `T?`.
///
///   \par Threading
///     A nested instance (`cont<cont<i32>>`) is spelled by specializing the
///     inner one, which is a clang::Sema call: callers hold the set's
///     sema_lock() across to_clang, not just across the outer instantiation.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/AST/ASTContext.h";
ffi "c++" import "clang/AST/Decl.h";
ffi "c++" import "clang/AST/DeclCXX.h";
ffi "c++" import "clang/AST/DeclTemplate.h";
ffi "c++" import "clang/AST/TemplateBase.h";
ffi "c++" import "clang/AST/TemplateName.h";
ffi "c++" import "clang/AST/Type.h";
ffi "c++" import "clang/Sema/Sema.h";
ffi "c++" import "llvm/ADT/APInt.h";
ffi "c++" import "llvm/ADT/APSInt.h";
ffi "c++" import "llvm/ADT/SmallVector.h";

import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Context::InstantiationRegistry::*;
import AST::LangItems::*;
import AST::EnumNiche::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Codegen::CodegenContext::*;
import Codegen::Emit::CXXSpell::*;
import Sema::Resolve::NameLookup::*;
import Sema::Foreign::ForeignRegistry::*;
import Sema::Foreign::TypeImport::*;

class TypeExport {
    pub var cctx: obs::<clang::ASTContext>;
    pub var sema: obs::<clang::Sema>;        ///< for nested specializations.
    pub var set:  obs::<void>;               ///< the HeaderSet cctx belongs to (FFILinkage::origin_set's type).

    // Stand-ins for Kairo records (see the file header). All three or none:
    // with any of them null a Kairo record is refused, as it always was.
    pub var reg:       obs::<ForeignRegistry>         = &null;   ///< stand-in USR -> the Kairo decl.
    pub var psym:      obs::<PreprocessorSymbolTable> = &null;   ///< CXXSpell's module segments.
    pub var instances: obs::<InstantiationRegistry>   = &null;   ///< CXXSpell's CodegenContext wants it.
    /// The TU a Kairo instance this export names first is homed in
    /// (InstanceEntry::home_fid: EmitPlan writes its explicit instantiation
    /// there). The demanding TU, which the fill knows; -1 falls back to the
    /// primary's own TU, right only when the primary is the user's.
    pub var home_fid:  i64 = -1;
    /// Some type this exporter spelled was a Kairo record's stand-in. A
    /// stand-in has the record's layout and none of its behaviour, so a
    /// question clang answers about it -- a concept probing `b.len()`, a
    /// trait probing a member -- can come out false for the real type.
    pub var used_standin: bool = false;

    /// The substitution in force while a stand-in specialization is being
    /// defined: the primary whose parameters are being read, and what they
    /// read as. Null outside _standin_instance, where a parameter has no
    /// clang type at all. Saved and restored around a nested one.
    priv var _sub_owner: *Decl = &null;
    priv var _sub_args:  *llvm::SmallVector::<clang::QualType, 8> = &null;

    fn TypeExport(self, cctx: *clang::ASTContext, sema: *clang::Sema, set: *void) {
        self.cctx = cctx;
        self.sema = sema;
        self.set  = set;
    }

    /// The clang type for canonical \p t, or a null QualType.
    fn to_clang(self, t: *Type) -> clang::QualType {
        if t == &null { return clang::QualType(); }

        // A parameter is a type only under a substitution, and only the
        // primary's own: any other template's parameter, or a pack, is
        // still nothing here.
        if isa::<GenericParamType>(t) {
            var g = cast::<GenericParamType>(t);
            if (self._sub_owner == &null) || g->is_pack { return clang::QualType(); }
            if NameLookup::representative(g->owner) != self._sub_owner { return clang::QualType(); }
            if static_cast::<usize>(g->param_index) >= self._sub_args->size() { return clang::QualType(); }
            return (*(self._sub_args))[static_cast::<usize>(g->param_index)];
        }
        // Under a substitution a dependent composite still walks: its
        // parameters resolve through the arm above, or fail there.
        if (self._sub_owner == &null) && (t->is_dependent() || t->is_instantiation_dependent()) { return clang::QualType(); }

        if isa::<QualifiedType>(t) {
            var q = cast::<QualifiedType>(t);
            var r = self.to_clang(q->inner);
            if r.isNull() { return r; }
            if (q->quals & QUAL_CONST())    != 0 { r = r.withConst();    }
            if (q->quals & QUAL_VOLATILE()) != 0 { r = r.withVolatile(); }
            return r;
        }

        if isa::<BuiltinType>(t) { return self._builtin(cast::<BuiltinType>(t)); }

        if isa::<PointerType>(t) {
            var p = self.to_clang(cast::<PointerType>(t)->pointee);
            if p.isNull() { return p; }
            return self.cctx->getPointerType(p);
        }
        if isa::<CXXLValueRefType>(t) {
            var lr = cast::<CXXLValueRefType>(t);
            var r  = self.to_clang(lr->referee);
            if r.isNull() { return r; }
            return self.cctx->getLValueReferenceType(r);
        }
        if isa::<CXXRValueRefType>(t) {
            var r = self.to_clang(cast::<CXXRValueRefType>(t)->referee);
            if r.isNull() { return r; }
            return self.cctx->getRValueReferenceType(r);
        }

        if isa::<FixedArrayType>(t) {
            var at = cast::<FixedArrayType>(t);
            var el = self.to_clang(at->element);
            if el.isNull() { return el; }
            // The store keeps a canonical array's extent in size_bits (it has
            // no size_expr); 0 is how TypeImport spells `T[]`.
            var extent = static_cast::<u64>(at->size_bits);
            if at->is_incomplete || (extent == 0) {
                return self.cctx->getIncompleteArrayType(el, clang::ArraySizeModifier::Normal, 0);
            }
            return self.cctx->getConstantArrayType(el, llvm::APInt(64, extent), &null,
                                                   clang::ArraySizeModifier::Normal, 0);
        }

        // Kairo `fn(...)` IS the pointer (TypeImport::_map folds `R(*)(A)`
        // into it), so the way back out wraps the function type in one.
        if isa::<FunctionPointerType>(t) {
            var ft  = cast::<FunctionPointerType>(t);
            var ret = self.cctx->VoidTy;
            var rq  = clang::QualType(ret);
            if ft->return_type != &null {
                rq = self.to_clang(ft->return_type);
                if rq.isNull() { return rq; }
            }
            if ft->is_unprototyped {
                return self.cctx->getPointerType(self.cctx->getFunctionNoProtoType(rq));
            }
            var ps: llvm::SmallVector::<clang::QualType, 8>;
            for var i: usize = 0; i < ft->params.size(); ++i {
                var q = self.to_clang(*(ft->params.get(i)));
                if q.isNull() { return q; }
                ps.push_back(q);
            }
            var fn_ = self.cctx->getFunctionType(rq, ps, clang::FunctionProtoType::ExtProtoInfo());
            return self.cctx->getPointerType(fn_);
        }

        if isa::<RecordType>(t) { return self._record(cast::<RecordType>(t)); }
        if isa::<NullableType>(t) { return self._nullable(cast::<NullableType>(t)); }

        // OpaqueFFIType has no shape. A tuple never gets here: TypeResolve
        // canonicalizes it to its TupleN record, which the record arm takes.
        return clang::QualType();
    }

    /// `ct<args...>` as a canonical clang type, or null. Declares the
    /// specialization (CheckTemplateIdType) but does NOT complete it: a
    /// nested argument only has to be nameable. PRE: sema_lock() held.
    fn template_id(self, ct: *clang::ClassTemplateDecl, args: ref!(llvm::SmallVector::<clang::TemplateArgument, 8>)) -> clang::QualType {
        if (ct == &null) || (self.sema == &null) { return clang::QualType(); }
        var loc = ct->getLocation();                     // any valid loc; the pattern's is honest.
        var ali = clang::TemplateArgumentListInfo(loc, loc);
        for var i: usize = 0; i < args.size(); ++i {
            if !self.add_arg_loc(ali, args[i], loc) { return clang::QualType(); }
        }
        var diags  = &(self.sema->getDiagnostics());
        var before = diags->getNumErrors();
        // 22.x signature (VERIFIED against /usr/include/clang/Sema/Sema.h,
        // 22.1.8): the elaborated-type refactor put the keyword FIRST and
        // added (Scope*, ForNestedNameSpecifier) at the end.
        var tn = clang::TemplateName(static_cast::<*clang::TemplateDecl>(ct));
        var ty = self.sema->CheckTemplateIdType(clang::ElaboratedTypeKeyword::None, tn, loc, ali, &null, false);
        if ty.isNull() || (diags->getNumErrors() > before) { return clang::QualType(); }
        return ty.getCanonicalType();
    }

    /// Append \p a to \p ali as a written argument would be. False when a
    /// value argument has no expression. PRE: sema_lock() held.
    fn add_arg_loc(self, ali: ref!(clang::TemplateArgumentListInfo), a: clang::TemplateArgument,
                   loc: clang::SourceLocation) -> bool {
        if a.getKind() == clang::TemplateArgument::Type {
            var qt = a.getAsType();
            ali.addArgument(clang::TemplateArgumentLoc(a, self.cctx->getTrivialTypeSourceInfo(qt, loc)));
            return true;
        }
        // A value goes in as the expression clang itself would rebuild
        // from it, so the template-id is checked exactly as a written
        // `ct<..., 4>` is, and a diagnostic about it has a source
        // expression to print instead of a null one.
        var er = self.sema->BuildExpressionFromNonTypeTemplateArgument(a, loc);
        if er.isInvalid() || (er.get() == &null) { return false; }
        var e = er.get();
        ali.addArgument(clang::TemplateArgumentLoc(clang::TemplateArgument(e, false), e));
        return true;
    }

    /// Argument \p i of a template-id of \p ct, for canonical \p t, or a
    /// null TemplateArgument. A type goes through to_clang. A value argument
    /// (`4` of `array<i32, 4>`) is an exact integer with no C++ type of its
    /// own -- the registry keys on the number alone (TypeImport::_args) --
    /// so it takes the type of the parameter it binds: `size_t` for array's
    /// extent, `bool` for SmallVectorTemplateBase's flag, an enum for an
    /// enum parameter. \p prior is the arguments before it, for a parameter
    /// typed by an earlier one (`integral_constant<T, T v>`).
    fn to_clang_arg(self, ct: *clang::ClassTemplateDecl, i: usize, t: *Type,
                    prior: ref!(llvm::SmallVector::<clang::TemplateArgument, 8>)) -> clang::TemplateArgument {
        if ct == &null { return clang::TemplateArgument(); }
        return self.to_clang_arg_of(ct->getTemplateParameters(), i, t, prior);
    }

    /// to_clang_arg against any template's parameter list: a function
    /// template's explicit arguments (`make_unique<i32>`) are spelled the
    /// same way a class template-id's are.
    fn to_clang_arg_of(self, tpl: *clang::TemplateParameterList, i: usize, t: *Type,
                       prior: ref!(llvm::SmallVector::<clang::TemplateArgument, 8>)) -> clang::TemplateArgument {
        if t == &null { return clang::TemplateArgument(); }
        if !isa::<TypeExpr>(t) {
            var q = self.to_clang(t);
            if q.isNull() { return clang::TemplateArgument(); }
            return clang::TemplateArgument(q);
        }
        var te = cast::<TypeExpr>(t);
        // A computed value (`N + 1` over a parameter) is dependent: there is
        // no concrete clang argument for it, as for a dependent type.
        if !te->is_exact() { return clang::TemplateArgument(); }
        var pt = self._value_param_type(tpl, i, prior);
        if pt.isNull() { return clang::TemplateArgument(); }

        var bits = static_cast::<u32>(self.cctx->getIntWidth(pt));
        var uns  = !pt->isSignedIntegerOrEnumerationType();
        // Out of the parameter's range is refused, not truncated: APInt
        // asserts on a magnitude wider than its width, and a wrapped value
        // would name a different specialization than the one written.
        if (bits == 0) || (bits > 64) { return clang::TemplateArgument(); }
        if te->vneg && uns { return clang::TemplateArgument(); }
        var limit_bits = (bits - 1) if (!uns) else (bits);
        if limit_bits < 64 {
            var lim = (u64(1) << static_cast::<u64>(limit_bits));
            // A signed minimum (`-128` of i8) is the one magnitude equal to
            // the limit that still fits.
            if te->vneg { if te->vmag > lim { return clang::TemplateArgument(); } }
            else if te->vmag >= lim { return clang::TemplateArgument(); }
        }
        var v = llvm::APSInt(llvm::APInt(bits, te->vmag, false, true), uns);
        if te->vneg { v.negate(); }
        return clang::TemplateArgument(*(self.cctx), v, pt);
    }

    /// The (canonical, integral or enum) type of \p tpl's \p i-th parameter
    /// when it is a non-type one, or null. Past the end, the trailing pack's.
    priv fn _value_param_type(self, tpl: *clang::TemplateParameterList, i: usize,
                              prior: ref!(llvm::SmallVector::<clang::TemplateArgument, 8>)) -> clang::QualType {
        if tpl == &null { return clang::QualType(); }
        var n = static_cast::<usize>(tpl->size());
        if n == 0 { return clang::QualType(); }
        var k = i;
        if k >= n {
            k = n - 1;
            if !tpl->getParam(static_cast::<u32>(k))->isParameterPack() { return clang::QualType(); }
        }
        var nt = llvm::dyn_cast::<clang::NonTypeTemplateParmDecl>(tpl->getParam(static_cast::<u32>(k)));
        if nt == &null { return clang::QualType(); }
        var pt = nt->getType().getCanonicalType();
        if pt->isDependentType() {
            // `template <class T, T v>`: the type is an earlier argument.
            var tp = llvm::dyn_cast::<clang::TemplateTypeParmType>(pt.getTypePtr());
            if (tp == &null) || (tp->getDepth() != 0) { return clang::QualType(); }
            var j = static_cast::<usize>(tp->getIndex());
            if (j >= prior.size()) || (prior[j].getKind() != clang::TemplateArgument::Type) { return clang::QualType(); }
            pt = prior[j].getAsType().getCanonicalType();
        }
        if !pt->isIntegralOrEnumerationType() { return clang::QualType(); }
        return pt;
    }

    /// The ClassTemplateDecl behind a Kairo primary, or null. DeclImport
    /// stamps the decl it WALKED, which for a primary is the ClassTemplateDecl
    /// -- unless the first sighting was the templated record itself.
    static fn class_template_of(cd: *clang::Decl) -> *clang::ClassTemplateDecl {
        if cd == &null { return &null; }
        var ct = llvm::dyn_cast::<clang::ClassTemplateDecl>(cd);
        if ct != &null { return ct; }
        // A partial specialization M2-style repointing never happens for a
        // clang instance, but a pattern's stamp can still be one.
        var ps = llvm::dyn_cast::<clang::ClassTemplatePartialSpecializationDecl>(cd);
        if ps != &null { return ps->getSpecializedTemplate(); }
        var rd = llvm::dyn_cast::<clang::CXXRecordDecl>(cd);
        if rd != &null { return rd->getDescribedClassTemplate(); }
        return &null;
    }

    // records

    priv fn _record(self, rt: *RecordType) -> clang::QualType {
        var d = rt->decl;
        if d == &null { return clang::QualType(); }

        // Anything with a live clang decl in THIS set: a plain imported
        // record or enum, an explicit specialization, or an instance a fill
        // already stamped with its ClassTemplateSpecializationDecl.
        var cd = decl_clang(d);
        if (cd != &null) && (decl_origin_set(d) == self.set) {
            var tag = llvm::dyn_cast::<clang::TagDecl>(reinterpret_cast::<*clang::Decl>(cd));
            if tag != &null { return clang::QualType(self.cctx->getCanonicalTagType(tag)); }
        }

        // A Kairo-authored record: a stand-in under its emitted name. With
        // arguments it is the primary named from inside its own pattern
        // (`next: *G<T>` while G<int> is being defined): the specialization.
        if (!decl_is_imported(d)) && (!decl_is_instance(d)) {
            if rt->args.size() == 0 { return self._standin(d, rt); }
            var own = TypeExport::_vec_of(rt->args);
            return self._standin_instance(d, &own);
        }

        var prim = decl_instantiated_from(d);
        if (prim == &null) || (!decl_is_instance(d)) { return clang::QualType(); }

        // An instance of a KAIRO generic: an explicit specialization of the
        // primary's stand-in template.
        if !decl_is_imported(NameLookup::representative(prim)) {
            var iargs = TypeExport::_vec_of(rt->args);
            return self._standin_instance(prim, &iargs);
        }

        // An unfilled instance of an imported template: spell the template-id
        // from its args. Recursing here is what makes `cont<cont<i32>>` work.
        if decl_origin_set(prim) != self.set { return clang::QualType(); }
        var ct = TypeExport::class_template_of(reinterpret_cast::<*clang::Decl>(decl_clang(prim)));
        if ct == &null { return clang::QualType(); }
        var qs: llvm::SmallVector::<clang::TemplateArgument, 8>;
        for var i: usize = 0; i < rt->args.size(); ++i {
            var a = self.to_clang_arg(ct, i, *(rt->args.get(i)), qs);
            if a.isNull() { return clang::QualType(); }
            qs.push_back(a);
        }
        return self.template_id(ct, qs);
    }

    // --- stand-ins ----------------------------------------------------------------

    /// True when the three stand-in collaborators are wired.
    priv fn _can_standin(self) -> bool {
        return (self.reg != &null) && (self.psym != &null) && (self.instances != &null);
    }

    static fn _vec_of(l: FrozenList::<*Type>) -> vec::<*Type> {
        var v = vec::<*Type>();
        for var i: usize = 0; i < l.size(); ++i { v.push_back(*(l.get(i))); }
        return v;
    }

    /// `T?`: the Nullable lang item's instance over T, which is what
    /// NullableTypeLowering makes it and what EmitIR spells
    /// (`::builtin::Nullable<T>`), so its stand-in is that generic ADT's
    /// specialization like any other. Through the lang item, never the
    /// lowered slot: a fill runs during typing, long before that pass.
    priv fn _nullable(self, n: *NullableType) -> clang::QualType {
        if (self.reg == &null) || (n->inner == &null) { return clang::QualType(); }
        var nd = self.reg->nullable_lang();
        if nd == &null { return clang::QualType(); }
        var args = vec::<*Type>();
        args.push_back(n->inner);
        return self._standin_instance(nd, &args);
    }

    /// What a stand-in for \p d holds, or false for a shape with none (an
    /// interface, a class with a base, a plain enum -- which is an enum,
    /// _standin_enum -- or an ADT with a pack-expanded variant, which has
    /// no fixed field list). \p out gets the field types in order (a null
    /// entry fails _define), \p tag a leading tag field's type or stays null.
    ///
    /// An ADT mirrors its declaration, not EnumLayoutLowering's record: a
    /// fill runs during typing and that pass has not built the record yet
    /// (and a generic ADT's real shape is per instance, picked by C++). So
    /// the stand-in is its tag word followed by every variant's payload
    /// fields in sequence. Overlapping them in a union would match the size
    /// but not the traits -- a union with a non-trivial member deletes its
    /// own copy, while the real record copies exactly when every payload
    /// does -- and phase A's member declarations ask traits
    /// (`is_copy_constructible`, a defaulted `pair` copy), never sizeof.
    priv fn _shape(self, d: *Decl, tk: *clang::TagTypeKind, tag: *clang::QualType, out: *vec::<*Type>) -> bool {
        (*tk) = clang::TagTypeKind::Struct;
        var fields: *FrozenList::<*FieldDecl> = &null;
        if isa::<StructDecl>(d) { fields = &(cast::<StructDecl>(d)->fields); }
        if isa::<UnionDecl>(d)  { (*tk) = clang::TagTypeKind::Union; fields = &(cast::<UnionDecl>(d)->fields); }
        if isa::<ClassDecl>(d) {
            // A base would have to be mirrored first, and its layout with it.
            if cast::<ClassDecl>(d)->derives_list.size() > 0 { return false; }
            fields = &(cast::<ClassDecl>(d)->fields);
        }
        if isa::<EnumDecl>(d) {
            var en = cast::<EnumDecl>(d);
            if !en->is_adt { return false; }
            (*tag) = self._int_type(adt_declared_tag_kind(en));
            for var i: usize = 0; i < en->variants.size(); ++i {
                var v = en->variants[i];
                if (v == &null) || v->is_pack_expansion { return false; }
                for var j: usize = 0; j < v->payload.size(); ++j {
                    out->push_back(TypeExport::_canon_of(v->payload[j]));
                }
            }
            return true;
        }
        if fields == &null { return false; }
        for var i: usize = 0; i < fields->size(); ++i {
            var fd = (*fields)[i];
            if (fd == &null) || fd->is_static() { continue; }
            out->push_back(TypeExport::_canon_of(fd));
        }
        return true;
    }

    static fn _canon_of(fd: *FieldDecl) -> *Type {
        if (fd == &null) || (fd->type_ == &null) { return &null; }
        return fd->type_->canonical;
    }

    /// The clang integer for builtin integer kind \p k, as _builtin spells it.
    priv fn _int_type(self, k: BuiltinKind) -> clang::QualType {
        var bits = builtin_info(k)->bits;
        if bits == 0 { bits = static_cast::<usize>(self.cctx->getTypeSize(self.cctx->getSizeType())); }
        var sgn: u32 = (1) if (builtin_info(k)->is_signed()) else (0);
        return self.cctx->getIntTypeForBitwidth(static_cast::<u32>(bits), sgn);
    }

    /// The speller for the name EmitIR gives a Kairo decl. CXXSpell only
    /// reads decl facts, the TU's imm table and the PP symbols, so a
    /// sink-less context is enough. False if \p d has no TU to spell from
    /// or is nested in a type (the owner would need a stand-in of its own).
    priv fn _spell_for(self, d: *Decl, segs: *vec::<string>, leaf: *string, fid: *u32) -> bool {
        var tu = CXXSpell::tu_of(d);
        if (tu == &null) || (tu->ctx == &null) { return false; }
        var cg = CodegenContext(tu->ctx, &null, self.psym, self.instances);
        var sp = CXXSpell(&cg);
        if sp.owner_types(d).size() > 0 { return false; }
        (*segs) = sp.ns_segments(d);
        (*leaf) = sp.leaf(d);
        (*fid)  = tu->fid;
        return true;
    }

    /// The namespace \p segs names in this AST, declared as needed; null
    /// when a header's non-namespace already owns a segment's name.
    priv fn _namespace_for(self, segs: *vec::<string>) -> *clang::DeclContext {
        var loc = clang::SourceLocation();
        var dc  = static_cast::<*clang::DeclContext>(self.cctx->getTranslationUnitDecl());
        for var i: usize = 0; i < segs->size(); ++i {
            var ii  = self._ident((*segs)[i]);
            var res = dc->lookup(clang::DeclarationName(ii));
            var ns: *clang::NamespaceDecl = &null;
            if !res.empty() {
                ns = llvm::dyn_cast::<clang::NamespaceDecl>(res.front());
                if ns == &null { return &null; }
            } else {
                ns = clang::NamespaceDecl::Create(*(self.cctx), dc, false, loc, loc, ii, &null, false);
                dc->addDecl(ns);
            }
            dc = static_cast::<*clang::DeclContext>(ns);
        }
        return dc;
    }

    /// Define \p rd with \p tag (when not null) and then \p fields, each
    /// type through to_clang (and so through the substitution in force).
    /// False, with \p rd marked invalid, when a field has no clang type:
    /// all or nothing, or a stand-in found by name later would have the
    /// wrong shape.
    priv fn _define(self, rd: *clang::CXXRecordDecl, tag: clang::QualType, fields: *vec::<*Type>) -> bool {
        rd->startDefinition();
        var n: usize = 0;
        if !tag.isNull() { self._add_field(rd, tag, n); n += 1; }
        for var i: usize = 0; i < fields->size(); ++i {
            var ft: clang::QualType;
            if (*fields)[i] != &null { ft = self.to_clang((*fields)[i]); }
            if ft.isNull() { rd->setInvalidDecl(); return false; }
            self._add_field(rd, ft, n);
            n += 1;
        }
        rd->completeDefinition();
        return true;
    }

    priv fn _add_field(self, rd: *clang::CXXRecordDecl, ft: clang::QualType, i: usize) {
        var loc = clang::SourceLocation();
        var fii = self._ident(LowerTargets::export_field(i));
        var cf  = clang::FieldDecl::Create(*(self.cctx), rd, loc, loc, fii, ft,
                                           self.cctx->getTrivialTypeSourceInfo(ft, loc),
                                           &null, false, clang::ICIS_NoInit);
        cf->setAccess(clang::AS_public);
        rd->addDecl(cf);
    }

    /// The stand-in for plain Kairo enum \p en: a scoped enum with a fixed
    /// underlying type, the one InterfaceEmitter writes (`enum class E :
    /// u32`; EnumNiche's enum_niche_kind is that rule). No enumerators:
    /// phase A only needs a complete enum of the right width, and no header
    /// names a Kairo enum's values. Found by name after the first use, like
    /// _standin. PRE: sema_lock() held.
    priv fn _standin_enum(self, en: *EnumDecl) -> clang::QualType {
        var d = static_cast::<*Decl>(en);
        var segs = vec::<string>();
        var leaf = "";
        var fid: u32 = 0;
        if !self._spell_for(d, &segs, &leaf, &fid) { return clang::QualType(); }
        var dc = self._namespace_for(&segs);
        if dc == &null { return clang::QualType(); }

        var lii = self._ident(leaf);
        var res = dc->lookup(clang::DeclarationName(lii));
        if !res.empty() {
            var prev = llvm::dyn_cast::<clang::EnumDecl>(res.front());
            if prev == &null { return clang::QualType(); }
            if self.reg->find(TypeImport::usr_of(prev)) != d { return clang::QualType(); }   // a header's own `stem::E`.
            return clang::QualType(self.cctx->getCanonicalTagType(prev));
        }

        var loc = clang::SourceLocation();
        var ut  = self._int_type(enum_niche_kind(en));
        var ed  = clang::EnumDecl::Create(*(self.cctx), dc, loc, loc, lii, &null, true, true, true);
        ed->setImplicit(true);
        ed->setIntegerType(ut);
        dc->addDecl(ed);
        ed->startDefinition();
        var promo = ut;
        if self.cctx->isPromotableIntegerType(ut) { promo = self.cctx->getPromotedIntegerType(ut); }
        ed->completeDefinition(ut, promo, 0, 0);

        var usr = TypeImport::usr_of(ed);
        if usr.empty() { dc->removeDecl(ed); return clang::QualType(); }
        self.reg->put(usr, d);
        return clang::QualType(self.cctx->getCanonicalTagType(ed));
    }

    /// The stand-in for plain Kairo record \p d in this set's AST, declared
    /// on first use and found by name after that. Null QualType when \p d
    /// is a shape it cannot mirror, or when its name is already taken there.
    /// PRE: sema_lock() held (it mutates the AST).
    priv fn _standin(self, d_in: *Decl, rt: *RecordType) -> clang::QualType {
        if !self._can_standin() { return clang::QualType(); }
        self.used_standin = true;      // records, enums, ADTs alike: layout, no behaviour.
        var d = NameLookup::representative(d_in);
        if rt->args.size() > 0 { return clang::QualType(); }
        if decl_generic_params(d).size() > 0 { return clang::QualType(); }
        var en = dyn_cast::<EnumDecl>(d);
        if (en != &null) && (!en->is_adt) { return self._standin_enum(en); }
        var tk = clang::TagTypeKind::Struct;
        var tag = clang::QualType();
        var fields = vec::<*Type>();
        if !self._shape(d, &tk, &tag, &fields) { return clang::QualType(); }

        var segs = vec::<string>();
        var leaf = "";
        var fid: u32 = 0;
        if !self._spell_for(d, &segs, &leaf, &fid) { return clang::QualType(); }
        var dc = self._namespace_for(&segs);
        if dc == &null { return clang::QualType(); }

        var loc = clang::SourceLocation();
        var lii = self._ident(leaf);
        var res = dc->lookup(clang::DeclarationName(lii));
        if !res.empty() {
            var prev = llvm::dyn_cast::<clang::CXXRecordDecl>(res.front());
            if prev == &null { return clang::QualType(); }
            // Mid-definition: a field of d reached d again (`next: *S`). A
            // pointer to it only needs the name; a by-value cycle is
            // TypeCycleCheck's error, not ours.
            var ours = prev->isBeingDefined()
                    || (self.reg->find(TypeImport::usr_of(prev)) == d);
            if !ours { return clang::QualType(); }             // a header's own `stem::S`.
            return clang::QualType(self.cctx->getCanonicalTagType(prev));
        }

        var rd = clang::CXXRecordDecl::Create(*(self.cctx), tk, dc, loc, loc, lii, &null);
        rd->setImplicit(true);
        dc->addDecl(rd);
        if !self._define(rd, tag, &fields) { dc->removeDecl(rd); return clang::QualType(); }

        var usr = TypeImport::usr_of(rd);
        if usr.empty() { dc->removeDecl(rd); return clang::QualType(); }
        self.reg->put(usr, d);
        return clang::QualType(self.cctx->getCanonicalTagType(rd));
    }

    /// The stand-in TEMPLATE for Kairo generic primary \p prim: declared
    /// with its type parameters, never defined. Every instance is an
    /// explicit specialization of it. Found by name after the first use.
    /// Null for a shape with no stand-in, or a taken name.
    /// PRE: sema_lock() held.
    priv fn _standin_template(self, prim: *Decl) -> *clang::ClassTemplateDecl {
        var gps = decl_generic_params(prim);
        if gps.size() == 0 { return &null; }
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            // A pack has no fixed arity to specialize on; a value parameter
            // has no canonical shape in the registry yet (TypeImport::_args).
            if (gp == &null) || gp->is_pack || gp->is_const_param { return &null; }
        }
        var tk = clang::TagTypeKind::Struct;
        var tag0 = clang::QualType();
        var probe = vec::<*Type>();
        if !self._shape(prim, &tk, &tag0, &probe) { return &null; }

        var segs = vec::<string>();
        var leaf = "";
        var fid: u32 = 0;
        if !self._spell_for(prim, &segs, &leaf, &fid) { return &null; }
        var dc = self._namespace_for(&segs);
        if dc == &null { return &null; }

        var lii = self._ident(leaf);
        var res = dc->lookup(clang::DeclarationName(lii));
        if !res.empty() {
            var prev = llvm::dyn_cast::<clang::ClassTemplateDecl>(res.front());
            if prev == &null { return &null; }                  // a header's own `stem::G`, not a template.
            if self.reg->find(TypeImport::usr_of(prev)) != prim { return &null; }
            return prev;
        }

        var loc = clang::SourceLocation();
        var tu  = self.cctx->getTranslationUnitDecl();
        var params: llvm::SmallVector::<*clang::NamedDecl, 8>;
        var tu_ctx = CXXSpell::tu_of(prim)->ctx;
        var cg = CodegenContext(tu_ctx, &null, self.psym, self.instances);
        var sp = CXXSpell(&cg);
        for var i: usize = 0; i < gps.size(); ++i {
            var name = sp.imm_name(gps[i]->name.imm, fid);
            var tp = clang::TemplateTypeParmDecl::Create(*(self.cctx), static_cast::<*clang::DeclContext>(tu),
                                                         loc, loc, 0, static_cast::<u32>(i),
                                                         self._ident(name), true, false);
            params.push_back(static_cast::<*clang::NamedDecl>(tp));
        }
        var tpl = clang::TemplateParameterList::Create(*(self.cctx), loc, loc, params, loc, &null);

        var pat = clang::CXXRecordDecl::Create(*(self.cctx), tk, dc, loc, loc, lii, &null);
        var ct  = clang::ClassTemplateDecl::Create(*(self.cctx), dc, loc, clang::DeclarationName(lii), tpl,
                                                   static_cast::<*clang::NamedDecl>(pat));
        pat->setDescribedClassTemplate(ct);
        pat->setImplicit(true);
        ct->setImplicit(true);
        dc->addDecl(ct);

        // TypeImport::_record reads an instance back through the TEMPLATE's
        // USR (spec->getSpecializedTemplate()); both spellings map to prim.
        var usr = TypeImport::usr_of(ct);
        if usr.empty() { dc->removeDecl(ct); return &null; }
        self.reg->put(usr, prim);
        var pusr = TypeImport::usr_of(pat);
        if !pusr.empty() { self.reg->put(pusr, prim); }
        return ct;
    }

    /// `G<int>` for an instance of Kairo generic \p prim_in at \p args: an
    /// explicit specialization of the stand-in template, defined with the
    /// pattern's fields where each parameter is read as this instance's
    /// argument. clang's specialization table answers the second use, and
    /// a self-reference mid-definition, so this is declared once per
    /// argument list. With concrete arguments the specialization's USR is
    /// registered to the registry instance, so `G<int>&` reads back as it.
    /// PRE: sema_lock() held.
    priv fn _standin_instance(self, prim_in: *Decl, args: *vec::<*Type>) -> clang::QualType {
        if !self._can_standin() { return clang::QualType(); }
        self.used_standin = true;      // a Kairo generic's instance, `T?` (Nullable) included.
        var prim = NameLookup::representative(prim_in);
        var ct = self._standin_template(prim);
        if ct == &null { return clang::QualType(); }
        if decl_generic_params(prim).size() != args->size() { return clang::QualType(); }

        var qs: llvm::SmallVector::<clang::QualType, 8>;
        var targs: llvm::SmallVector::<clang::TemplateArgument, 8>;
        var concrete = true;
        for var i: usize = 0; i < args->size(); ++i {
            var a = (*args)[i];
            if a == &null { return clang::QualType(); }
            if a->is_dependent() || a->is_instantiation_dependent() { concrete = false; }
            var q = self.to_clang(a);
            if q.isNull() { return q; }
            qs.push_back(q);
            targs.push_back(clang::TemplateArgument(q));
        }

        var pos: *void = &null;
        var prev = ct->findSpecialization(targs, pos);
        if prev != &null {
            if prev->isInvalidDecl() { return clang::QualType(); }   // a field of it had no clang type; refused, sticky.
            return clang::QualType(self.cctx->getCanonicalTagType(prev));
        }

        var tk = clang::TagTypeKind::Struct;
        var tag = clang::QualType();
        var fields = vec::<*Type>();
        if !self._shape(prim, &tk, &tag, &fields) { return clang::QualType(); }
        var loc = clang::SourceLocation();
        var dc  = ct->getDeclContext();
        // 22.x: the `StrictPackMatch` bool before PrevDecl. If the build says
        // the call has one argument too many, drop the `false`.
        var spec = clang::ClassTemplateSpecializationDecl::Create(*(self.cctx), tk, dc, loc, loc, ct, targs, false, &null);
        spec->setSpecializationKind(clang::TSK_ExplicitSpecialization);
        spec->setImplicit(true);
        ct->AddSpecialization(spec, pos);
        dc->addDecl(spec);

        // The pattern's fields, its parameters read as this instance's
        // arguments. Saved around: a field's own instance argument
        // (`G<H<T>>`) nests one of these.
        var saved_owner = self._sub_owner;
        var saved_args  = self._sub_args;
        self._sub_owner = prim;
        self._sub_args  = &qs;
        var ok = self._define(spec, tag, &fields);
        self._sub_owner = saved_owner;
        self._sub_args  = saved_args;
        // On failure the spec stays in clang's table, invalid: findSpecialization
        // refuses it above, and it is never printed.
        if !ok { return clang::QualType(); }

        if concrete {
            var kargs = vec::<*Type>();
            for var i: usize = 0; i < args->size(); ++i { kargs.push_back((*args)[i]); }
            var hf = (u32(self.home_fid)) if (self.home_fid >= 0) else (CXXSpell::fid_of(prim));
            var e = self.instances->instance_for(prim, &kargs, hf, NameLookup::ctx_of(prim));
            var usr = TypeImport::usr_of(spec);
            if (e != &null) && (!usr.empty()) { self.reg->put(usr, e->decl); }
        }
        return clang::QualType(self.cctx->getCanonicalTagType(spec));
    }

    priv fn _ident(self, s: string) -> *clang::IdentifierInfo {
        return &(self.cctx->Idents.get(sref(s)));
    }

    // builtins

    /// Mirrors TypeImport::_builtin, so a round trip is the identity on every
    /// canonical import can produce. Integers go by (width, sign) through the
    /// target, exactly as they came in.
    priv fn _builtin(self, bt: *BuiltinType) -> clang::QualType {
        var k = bt->builtin;
        if builtin_info(k)->is_integer() {
            var bits = builtin_info(k)->bits;
            if bits == 0 { bits = bt->size_bits; }       // usize/isize: the store's target width.
            var sgn: u32 = (1) if (builtin_info(k)->is_signed()) else (0);
            // Past 128 there is no fundamental type to find; i256/u512 are
            // _BitInt, exactly as BuiltinTable spells them.
            if bits > 128 { return self.cctx->getBitIntType(sgn == 0, static_cast::<u32>(bits)); }
            return self.cctx->getIntTypeForBitwidth(static_cast::<u32>(bits), sgn);
        }
        switch k {
            case BuiltinKind::Void { return clang::QualType(self.cctx->VoidTy); }
            case BuiltinKind::Bool { return clang::QualType(self.cctx->BoolTy); }
            case BuiltinKind::Char { return clang::QualType(self.cctx->Char32Ty); }
            case BuiltinKind::CChar { return clang::QualType(self.cctx->CharTy); }
            case BuiltinKind::F16  { return clang::QualType(self.cctx->Float16Ty); }
            case BuiltinKind::BF16 { return clang::QualType(self.cctx->BFloat16Ty); }
            case BuiltinKind::F32  { return clang::QualType(self.cctx->FloatTy); }
            case BuiltinKind::F64  { return clang::QualType(self.cctx->DoubleTy); }
            // The format through a `var` first, as TypeImport does: Stage 0
            // drops a leading `&(...)` inside a comparison and compares the
            // fltSemantics by value.
            case BuiltinKind::F80 {
                var ld  = clang::QualType(self.cctx->LongDoubleTy);
                var fmt = &(self.cctx->getFloatTypeSemantics(ld));
                if fmt == &(llvm::APFloat::x87DoubleExtended()) { return ld; }
                return clang::QualType();
            }
            case BuiltinKind::F128 {
                // _builtin maps a binary128 `long double` AND `__float128` to
                // f128; `long double` is the one headers actually spell.
                var ld  = clang::QualType(self.cctx->LongDoubleTy);
                var fmt = &(self.cctx->getFloatTypeSemantics(ld));
                if fmt == &(llvm::APFloat::IEEEquad()) { return ld; }
                return clang::QualType(self.cctx->Float128Ty);
            }
            default { return clang::QualType(); }       // never, byte, f8*, f256+: no import produces them.
        }
    }

}