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
///                                specialization is being defined; see below;
///                                an opaque imported from a canonical,
///                                non-tag clang type in THIS context is that
///                                type: ForeignRegistry::opaque_qt).
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/Decl.h"
ffi "c++" import "clang/AST/DeclCXX.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/AST/TemplateBase.h"
ffi "c++" import "clang/AST/TemplateName.h"
ffi "c++" import "clang/AST/Type.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Sema/Sema.h"
ffi "c++" import "llvm/ADT/APInt.h"
ffi "c++" import "llvm/ADT/APSInt.h"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::DeclFacts::{
    decl_clang,       decl_generic_params, decl_instantiated_from, decl_is_imported,
    decl_is_instance, decl_origin_set,     decl_pattern,           decl_type_owner,
}
import AST::EnumNiche::{
    adt_declared_tag_kind,
    enum_niche_kind,
}
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,  BuiltinType, QUAL_CONST, QUAL_VOLATILE, QualifiedType, RecordType, builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AbiKind, ClassDecl, EnumDecl, FieldDecl, FnBodyKind, GenericParamDecl, StructDecl, UnionDecl,
}
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, GenericParamType,
    NullableType,     OpaqueFFIType,    PointerType,    TypeExpr,
}
import Codegen::CodegenContext::CodegenContext
import Codegen::Emit::CXXSpell::CXXSpell
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Foreign::TypeImport::TypeImport
import Sema::Resolve::NameLookup::NameLookup

pub class TypeExport {
    pub var cctx: unsafe *clang::ASTContext
    pub var sema: unsafe *clang::Sema ///< for nested specializations.
    pub var set:  unsafe *void ///< the HeaderSet cctx belongs to (FFILinkage::origin_set's type).

    // Stand-ins for Kairo records (see the file header). All three or none:
    // with any of them null a Kairo record is refused, as it always was.
    pub var reg:       unsafe *ForeignRegistry         = &null ///< stand-in USR -> the Kairo decl.
    pub var psym:      unsafe *PreprocessorSymbolTable = &null ///< CXXSpell's module segments.
    pub var instances: unsafe *InstantiationRegistry   = &null ///< CXXSpell's CodegenContext wants it.
    /// The TU a Kairo instance this export names first is homed in
    /// (InstanceEntry::home_fid: EmitPlan writes its explicit instantiation
    /// there). The demanding TU, which the fill knows; -1 falls back to the
    /// primary's own TU, right only when the primary is the user's.
    pub var home_fid: i64 = -1
    /// Some type this exporter spelled was a Kairo record's stand-in. A
    /// stand-in has the record's layout and none of its behaviour, so a
    /// question clang answers about it -- a concept probing `b.len()`, a
    /// trait probing a member -- can come out false for the real type.
    pub var used_standin: bool = false
    /// A plain imported record that only ANOTHER set's AST can spell may be
    /// spelled as a layout-only blob (_opaque_like) instead of failing. Only
    /// a caller that asks a question about the TEMPLATE, not the argument,
    /// sets it: deduce_call's SFINAE verdict on `make_shared<clang::X>()`
    /// from <memory>'s set, which never saw X. A fill must keep failing so it
    /// retries in the demanding TU's set (a blob there would name the wrong
    /// instance). \p used_opaque reports it was taken; it implies used_standin.
    pub var allow_opaque_args: bool = false
    pub var used_opaque:       bool = false

    /// The substitution in force while a stand-in specialization is being
    /// defined: the primary whose parameters are being read, and what they
    /// read as. Null outside _standin_instance, where a parameter has no
    /// clang type at all. Saved and restored around a nested one.
    priv var _sub_owner: unsafe *Decl                                  = &null
    priv var _sub_args:  unsafe *llvm::SmallVector<clang::QualType, 8> = &null
    /// Parallel to _sub_args: the canonical value argument at each value
    /// parameter's index, null at a type parameter's. A fixed array whose
    /// extent is such a parameter (FixedArrayType::extent_param) reads it here.
    priv var _sub_vals: unsafe *cxx::std::vector<unsafe *Type> = &null

    fn TypeExport(self,
                  cctx: unsafe *clang::ASTContext,
                  sema: unsafe *clang::Sema,
                  set:  unsafe *void) {
        self.cctx = cctx
        self.sema = sema
        self.set  = set
    }

    /// The clang type for canonical \p t, or a null QualType.
    fn to_clang(self, t: unsafe *Type) -> clang::QualType {
        if t == &null {
            return clang::QualType()
        }

        // A parameter is a type only under a substitution, and only the
        // primary's own: any other template's parameter, or a pack, is
        // still nothing here.
        if isa<GenericParamType>(t) {
            var unsafe *g = cast<GenericParamType>(t)
            if self._sub_owner == &null || g->is_pack {
                return clang::QualType()
            }

            if NameLookup::representative(g->owner) != self._sub_owner {
                return clang::QualType()
            }

            if (g->param_index as usize) >= self._sub_args->size() {
                return clang::QualType()
            }

            return (*self._sub_args)[g->param_index as usize]
        }

        // Under a substitution a dependent composite still walks: its
        // parameters resolve through the arm above, or fail there.
        if self._sub_owner == &null && (t->is_dependent() || t->is_instantiation_dependent()) {
            return clang::QualType()
        }

        if isa<QualifiedType>(t) {
            var unsafe *q = cast<QualifiedType>(t)
            var        r  = self.to_clang(q->inner)
            if r.isNull() {
                return r
            }

            if (q->quals & QUAL_CONST) != 0 {
                r = r.withConst()
            }

            if (q->quals & QUAL_VOLATILE) != 0 {
                r = r.withVolatile()
            }

            return r
        }

        if isa<BuiltinType>(t) {
            return self._builtin(cast<BuiltinType>(t))
        }

        if isa<PointerType>(t) {
            var p = self.to_clang(cast<PointerType>(t)->pointee)
            if p.isNull() {
                return p
            }

            return self.cctx->getPointerType(p)
        }

        if isa<CXXLValueRefType>(t) {
            var unsafe *lr = cast<CXXLValueRefType>(t)
            var        r   = self.to_clang(lr->referee)
            if r.isNull() {
                return r
            }

            return self.cctx->getLValueReferenceType(r)
        }

        if isa<CXXRValueRefType>(t) {
            var r = self.to_clang(cast<CXXRValueRefType>(t)->referee)
            if r.isNull() {
                return r
            }

            return self.cctx->getRValueReferenceType(r)
        }

        if isa<FixedArrayType>(t) {
            var unsafe *at = cast<FixedArrayType>(t)
            var        el  = self.to_clang(at->element)
            if el.isNull() {
                return el
            }

            // The store keeps a canonical array's extent in size_bits (it has
            // no size_expr); 0 is how TypeImport spells `T[]`.
            var extent = (at->size_bits as u64)
            if at->extent_param != &null {
                var unsafe *ep = dyn_cast<GenericParamType>(at->extent_param)
                if ep == &null || self._sub_owner == &null || self._sub_vals == &null {
                    return clang::QualType()
                }

                if NameLookup::representative(ep->owner) != self._sub_owner {
                    return clang::QualType()
                }

                var ix = (ep->param_index as usize)
                if ix >= self._sub_vals->size() {
                    return clang::QualType()
                }

                var unsafe *ev = dyn_cast<TypeExpr>((*self._sub_vals)[ix])
                if ev == &null || !ev->is_exact() || ev->vneg {
                    return clang::QualType()
                }

                extent = ev->vmag
            }

            if at->is_incomplete || extent == 0 {
                return self.cctx->getIncompleteArrayType(el, clang::ArraySizeModifier::Normal, 0)
            }

            return self.cctx->getConstantArrayType(
                el,
                llvm::APInt(64, extent),
                &null,
                clang::ArraySizeModifier::Normal,
                0,
            )
        }

        // Kairo `fn(...)` IS the pointer (TypeImport::_map folds `R(*)(A)`
        // into it), so the way back out wraps the function type in one.
        if isa<FunctionPointerType>(t) {
            var unsafe *ft = cast<FunctionPointerType>(t)
            var        ret = self.cctx->VoidTy
            var        rq  = clang::QualType::getFromOpaquePtr((ret).getAsOpaquePtr())
            if ft->return_type != &null {
                rq = self.to_clang(ft->return_type)
                if rq.isNull() {
                    return rq
                }
            }

            if ft->is_unprototyped {
                return self.cctx->getPointerType(self.cctx->getFunctionNoProtoType(rq))
            }

            var ps: llvm::SmallVector<clang::QualType, 8>
            for var i: usize = 0; i < ft->params.size(); ++i {
                var q = self.to_clang(*ft->params.get(i))
                if q.isNull() {
                    return q
                }

                ps.push_back(q)
            }

            var fn_ = self.cctx->getFunctionType(
                rq,
                llvm::ArrayRef<clang::QualType>(ps),
                clang::FunctionProtoType::ExtProtoInfo(),
            )

            return self.cctx->getPointerType(fn_)
        }

        if isa<RecordType>(t) {
            return self._record(cast<RecordType>(t))
        }

        if isa<NullableType>(t) {
            return self._nullable(cast<NullableType>(t))
        }

        // OpaqueFFIType has no shape: only the clang type TypeImport made it
        // from, in this context, spells it back (`vector<__m128i>`);
        // another set's opaque stays null, so a fill retries in the
        // demanding TU's set. A tuple never gets here: TypeResolve
        // canonicalizes it to its TupleN record, which the record arm takes.
        if isa<OpaqueFFIType>(t) && self.reg != &null {
            var unsafe *oq = self.reg->opaque_qt(
                unsafe (t as unsafe *void),
                unsafe (self.cctx as unsafe *void),
            )

            if oq != &null {
                return clang::QualType::getFromOpaquePtr(oq)
            }
        }

        return clang::QualType()
    }

    /// `ct<args...>` as a canonical clang type, or null. Declares the
    /// specialization (CheckTemplateIdType) but does NOT complete it: a
    /// nested argument only has to be nameable. PRE: sema_lock() held.
    fn template_id(self,
                   ct:          unsafe *clang::ClassTemplateDecl,
                   @inout args: llvm::SmallVector<clang::TemplateArgument, 8>) -> clang::QualType {
        if ct == &null || self.sema == &null {
            return clang::QualType()
        }

        var loc = ct->getLocation() // any valid loc; the pattern's is honest.
        var ali = clang::TemplateArgumentListInfo(loc, loc)
        for var i: usize = 0; i < args.size(); ++i {
            if !self.add_arg_loc(&ali, args[i], loc) {
                return clang::QualType()
            }
        }

        var *diags = &self.sema->getDiagnostics()
        var before = diags->getNumErrors()
        // 22.x signature (VERIFIED against /usr/include/clang/Sema/Sema.h,
        // 22.1.8): the elaborated-type refactor put the keyword FIRST and
        // added (Scope*, ForNestedNameSpecifier) at the end.
        var tn = clang::TemplateName(unsafe (ct as unsafe *clang::TemplateDecl))
        var ty = self.sema->CheckTemplateIdType(
            clang::ElaboratedTypeKeyword::None,
            tn,
            loc,
            &ali,
            &null,
            false,
        )

        if ty.isNull() || diags->getNumErrors() > before {
            return clang::QualType()
        }

        return ty.getCanonicalType()
    }

    /// Append \p a to \p ali as a written argument would be. False when a
    /// value argument has no expression. PRE: sema_lock() held.
    fn add_arg_loc(self,
                   @inout ali: clang::TemplateArgumentListInfo,
                   a:          clang::TemplateArgument,
                   loc:        clang::SourceLocation) -> bool {
        if a.getKind() == clang::TemplateArgument::Type {
            var qt = a.getAsType()
            ali.addArgument(
                clang::TemplateArgumentLoc(a, self.cctx->getTrivialTypeSourceInfo(qt, loc)),
            )

            return true
        }

        // A value goes in as the expression clang itself would rebuild
        // from it, so the template-id is checked exactly as a written
        // `ct<..., 4>` is, and a diagnostic about it has a source
        // expression to print instead of a null one.
        var er = self.sema->BuildExpressionFromNonTypeTemplateArgument(a, loc)
        if er.isInvalid() || er.get() == &null {
            return false
        }

        var unsafe *e = er.get()
        ali.addArgument(clang::TemplateArgumentLoc(clang::TemplateArgument(e, false), e))
        return true
    }

    /// Argument \p i of a template-id of \p ct, for canonical \p t, or a
    /// null TemplateArgument. A type goes through to_clang. A value argument
    /// (`4` of `array<i32, 4>`) is an exact integer with no C++ type of its
    /// own -- the registry keys on the number alone (TypeImport::_args) --
    /// so it takes the type of the parameter it binds: `size_t` for array's
    /// extent, `bool` for SmallVectorTemplateBase's flag, an enum for an
    /// enum parameter. \p prior is the arguments before it, for a parameter
    /// typed by an earlier one (`integral_constant<T, T v>`).
    fn to_clang_arg(self,
                    ct:           unsafe *clang::ClassTemplateDecl,
                    i:            usize,
                    t:            unsafe *Type,
                    @inout prior: llvm::SmallVector<clang::TemplateArgument, 8>) -> clang::TemplateArgument {
        if ct == &null {
            return clang::TemplateArgument()
        }

        return self.to_clang_arg_of(ct->getTemplateParameters(), i, t, &prior)
    }

    /// to_clang_arg against any template's parameter list: a function
    /// template's explicit arguments (`make_unique<i32>`) are spelled the
    /// same way a class template-id's are.
    fn to_clang_arg_of(self,
                       tpl:          unsafe *clang::TemplateParameterList,
                       i:            usize,
                       t:            unsafe *Type,
                       @inout prior: llvm::SmallVector<clang::TemplateArgument, 8>) -> clang::TemplateArgument {
        if t == &null {
            return clang::TemplateArgument()
        }

        if !isa<TypeExpr>(t) {
            var q = self.to_clang(t)
            if q.isNull() {
                return clang::TemplateArgument()
            }

            // A written `fn(A) -> R` as a template argument names the C++
            // FUNCTION type `R(A)` (`function_ref<bool(X)>`), not `R(*)(A)`:
            // a partial specialization over `Ret(Params...)` never matches the
            // pointer, so the instance stayed unfilled and its constructors
            // were invisible (SC038E). A raw `unsafe fn` is the pointer.
            var unsafe *ct_ = canon_unqual(t)
            if ct_ != &null && isa<FunctionPointerType>(ct_) {
                var unsafe *fpt = cast<FunctionPointerType>(ct_)
                if !fpt->is_raw && !fpt->is_unprototyped && q->isPointerType() {
                    return clang::TemplateArgument(q->getPointeeType())
                }
            }

            return clang::TemplateArgument(q)
        }

        var unsafe *te = cast<TypeExpr>(t)
        // A computed value (`N + 1` over a parameter) is dependent: there is
        // no concrete clang argument for it, as for a dependent type.
        if !te->is_exact() {
            return clang::TemplateArgument()
        }

        var pt = self._value_param_type(tpl, i, &prior)
        if pt.isNull() {
            return clang::TemplateArgument()
        }

        var bits = (self.cctx->getIntWidth(pt))
        var uns  = !pt->isSignedIntegerOrEnumerationType()
        // Out of the parameter's range is refused, not truncated: APInt
        // asserts on a magnitude wider than its width, and a wrapped value
        // would name a different specialization than the one written.
        if bits == 0 || bits > 64 {
            return clang::TemplateArgument()
        }

        if te->vneg && uns {
            return clang::TemplateArgument()
        }

        var limit_bits = if (!uns) => (bits - 1) else => bits
        if limit_bits < 64 {
            var lim = (1 as u64) << (limit_bits as u64)
            // A signed minimum (`-128` of i8) is the one magnitude equal to
            // the limit that still fits.
            if te->vneg {
                if te->vmag > lim {
                    return clang::TemplateArgument()
                }
            } else if te->vmag >= lim {
                return clang::TemplateArgument()
            }
        }

        var v = llvm::APSInt(llvm::APInt(bits, te->vmag, false, true), uns)
        if te->vneg {
            v.negate()
        }

        return clang::TemplateArgument(*self.cctx, v, pt)
    }

    /// The (canonical, integral or enum) type of \p tpl's \p i-th parameter
    /// when it is a non-type one, or null. Past the end, the trailing pack's.
    priv fn _value_param_type(self,
                              tpl:          unsafe *clang::TemplateParameterList,
                              i:            usize,
                              @inout prior: llvm::SmallVector<clang::TemplateArgument, 8>) -> clang::QualType {
        if tpl == &null {
            return clang::QualType()
        }

        var n = (tpl->size() as usize)
        if n == 0 {
            return clang::QualType()
        }

        var k = i
        if k >= n {
            k = n - 1
            if !tpl->getParam(k as u32)->isParameterPack() {
                return clang::QualType()
            }
        }

        var unsafe *nt = llvm::dyn_cast<clang::NonTypeTemplateParmDecl>(tpl->getParam(k as u32))
        if nt == &null {
            return clang::QualType()
        }

        var pt = nt->getType().getCanonicalType()
        if pt->isDependentType() {
            // `template <class T, T v>`: the type is an earlier argument.
            var unsafe *tp = llvm::dyn_cast<clang::TemplateTypeParmType>(pt.getTypePtr())
            if tp == &null || tp->getDepth() != 0 {
                return clang::QualType()
            }

            var j = (tp->getIndex() as usize)
            if j >= prior.size() || prior[j].getKind() != clang::TemplateArgument::Type {
                return clang::QualType()
            }

            pt = prior[j].getAsType().getCanonicalType()
        }

        if !pt->isIntegralOrEnumerationType() {
            return clang::QualType()
        }

        return pt
    }

    /// The ClassTemplateDecl behind a Kairo primary, or null. DeclImport
    /// stamps the decl it WALKED, which for a primary is the ClassTemplateDecl
    /// -- unless the first sighting was the templated record itself.
    static fn class_template_of(cd: unsafe *clang::Decl) -> unsafe *clang::ClassTemplateDecl {
        if cd == &null {
            return &null
        }

        var unsafe *ct = llvm::dyn_cast<clang::ClassTemplateDecl>(cd)
        if ct != &null {
            return ct
        }

        // A partial specialization M2-style repointing never happens for a
        // clang instance, but a pattern's stamp can still be one.
        var unsafe *ps = llvm::dyn_cast<clang::ClassTemplatePartialSpecializationDecl>(cd)
        if ps != &null {
            return ps->getSpecializedTemplate()
        }

        var unsafe *rd = llvm::dyn_cast<clang::CXXRecordDecl>(cd)
        if rd != &null {
            return rd->getDescribedClassTemplate()
        }

        return &null
    }

    // records

    priv fn _record(self, rt: unsafe *RecordType) -> clang::QualType {
        var unsafe *d = rt->decl
        if d == &null {
            return clang::QualType()
        }

        // Anything with a live clang decl in THIS set: a plain imported
        // record or enum, an explicit specialization, or an instance a fill
        // already stamped with its ClassTemplateSpecializationDecl.
        var unsafe *cd = decl_clang(d)
        if cd != &null && decl_origin_set(d) == self.set {
            var unsafe *tag = llvm::dyn_cast<clang::TagDecl>(unsafe (cd as unsafe *clang::Decl))
            if tag != &null {
                return clang::QualType::getFromOpaquePtr(
                    (self.cctx->getCanonicalTagType(tag)).getAsOpaquePtr(),
                )
            }
        }

        // An imported plain record or enum whose decl is ANOTHER set's: the
        // first set to import `clang::QualType` is not the set of the TU
        // naming `SmallVector<QualType, 8>`, and an argument with no spelling
        // here left the whole instance unfilled (`v.size()` was R025E).
        // The same entity is re-found in this set's AST by its qualified
        // path; an instance or a Kairo-authored record is handled below.
        if cd != &null && decl_is_imported(d) && !decl_is_instance(d) {
            var unsafe *rf = self._refind(unsafe (cd as unsafe *clang::Decl))
            var unsafe *rtag = llvm::dyn_cast_or_null<clang::TagDecl>(
                unsafe (rf as unsafe *clang::Decl),
            )

            if rtag != &null {
                return clang::QualType::getFromOpaquePtr(
                    (self.cctx->getCanonicalTagType(rtag)).getAsOpaquePtr(),
                )
            }

            if self.allow_opaque_args {
                var ob = self._opaque_like(rt)
                // Forward-declared in its own set, or a layout the sized blob
                // refuses: the template's SFINAE never reads the argument's
                // layout, so a byte stands for it.
                if ob.isNull() {
                    ob = self._opaque_blank()
                }

                if !ob.isNull() {
                    self.used_standin = true
                    self.used_opaque  = true
                    return ob
                }
            }
        }

        // A Kairo-authored record: a stand-in under its emitted name. With
        // arguments it is the primary named from inside its own pattern
        // (`next: *G<T>` while G<int> is being defined): the specialization.
        if !decl_is_imported(d) && !decl_is_instance(d) {
            var sq = clang::QualType()
            if rt->args.size() == 0 {
                sq = self._standin(d, rt)
            } else {
                var own = TypeExport::_vec_of(rt->args)
                sq = self._standin_instance(d, own)
            }

            // A stand-in refused here (its C++ base is not spellable in this
            // set): a caller asking only about the template takes a blob, so
            // a removal over it stays soft.
            if sq.isNull() && self.allow_opaque_args {
                sq = self._opaque_blank()
                if !sq.isNull() {
                    self.used_standin = true
                    self.used_opaque  = true
                }
            }

            return sq
        }

        var unsafe *prim = decl_instantiated_from(d)
        if prim == &null || !decl_is_instance(d) {
            return clang::QualType()
        }

        // An instance of a KAIRO generic: an explicit specialization of the
        // primary's stand-in template.
        if !decl_is_imported(NameLookup::representative(prim)) {
            var iargs = TypeExport::_vec_of(rt->args)
            return self._standin_instance(prim, iargs)
        }

        // An unfilled instance of an imported template: spell the template-id
        // from its args. Recursing here is what makes `cont<cont<i32>>` work.
        var unsafe *pcd = unsafe (decl_clang(prim) as unsafe *clang::Decl)
        if decl_origin_set(prim) != self.set {
            var unsafe *rf = self._refind(pcd)
            pcd = unsafe (rf as unsafe *clang::Decl)
        }

        if pcd == &null {
            return clang::QualType()
        }

        var unsafe *ct = TypeExport::class_template_of(pcd)
        if ct == &null {
            return clang::QualType()
        }

        var qs: llvm::SmallVector<clang::TemplateArgument, 8>
        for var i: usize = 0; i < rt->args.size(); ++i {
            var a = self.to_clang_arg(ct, i, *rt->args.get(i), &qs)
            if a.isNull() {
                return clang::QualType()
            }

            qs.push_back(a)
        }

        return self.template_id(ct, &qs)
    }

    /// A complete one-byte struct standing for a type whose layout is
    /// unknown or unspellable here. Only for a caller whose question is about
    /// the template, never the argument (allow_opaque_args).
    priv fn _opaque_blank(self) -> clang::QualType {
        var elem = self.cctx->getIntTypeForBitwidth(8, 0)
        if elem.isNull() {
            return clang::QualType()
        }

        var        leaf = "__kairo_opaque_blank"
        var unsafe *tu  = unsafe (self.cctx->getTranslationUnitDecl() as unsafe *clang::DeclContext)
        var unsafe *lii = self._ident(leaf)
        var        res  = tu->lookup(clang::DeclarationName(lii))
        if !res.empty() {
            var unsafe *prev = llvm::dyn_cast<clang::CXXRecordDecl>(res.front())
            if prev == &null {
                return clang::QualType()
            }

            return clang::QualType::getFromOpaquePtr(
                (self.cctx->getCanonicalTagType(prev)).getAsOpaquePtr(),
            )
        }

        var loc = clang::SourceLocation()
        var unsafe *rd = clang::CXXRecordDecl::Create(
            *self.cctx,
            clang::TagTypeKind::Struct,
            tu,
            loc,
            loc,
            lii,
            &null,
        )

        rd->setImplicit(true)
        tu->addDecl(rd)
        rd->startDefinition()
        var arr = self.cctx->getConstantArrayType(
            elem,
            llvm::APInt(64, 1),
            &null,
            clang::ArraySizeModifier::Normal,
            0,
        )

        self._add_field(rd, arr, 0)
        rd->completeDefinition()
        return clang::QualType::getFromOpaquePtr(
            (self.cctx->getCanonicalTagType(rd)).getAsOpaquePtr(),
        )
    }

    /// An opaque struct with \p t's size and alignment, for an imported
    /// record type that only another set's AST can spell; null otherwise.
    priv fn _opaque_like(self, t: unsafe *Type) -> clang::QualType {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<RecordType>(c) {
            return clang::QualType()
        }

        var unsafe *d = cast<RecordType>(c)->decl
        if d == &null {
            return clang::QualType()
        }

        var unsafe *tag = llvm::dyn_cast_or_null<clang::TagDecl>(
            unsafe (decl_clang(d) as unsafe *clang::Decl),
        )

        if tag == &null || !tag->isCompleteDefinition() {
            return clang::QualType()
        }

        var unsafe *octx = unsafe &tag->getASTContext()
        if octx == self.cctx {
            return clang::QualType()
        }

        var oty = clang::QualType::getFromOpaquePtr(
            (octx->getCanonicalTagType(tag)).getAsOpaquePtr(),
        )

        var size  = (octx->getTypeSizeInChars(oty).getQuantity() as u64)
        var align = (octx->getTypeAlignInChars(oty).getQuantity() as u64)
        if align == 0 || align > 16 || size % align != 0 {
            return clang::QualType()
        }

        var elem = self.cctx->getIntTypeForBitwidth((align * 8) as u32, 0)
        if elem.isNull() {
            return clang::QualType()
        }

        var        leaf = f"__kairo_opaque_s{size}_a{align}"
        var unsafe *tu  = unsafe (self.cctx->getTranslationUnitDecl() as unsafe *clang::DeclContext)
        var unsafe *lii = self._ident(leaf)
        var        res  = tu->lookup(clang::DeclarationName(lii))
        if !res.empty() {
            var unsafe *prev = llvm::dyn_cast<clang::CXXRecordDecl>(res.front())
            if prev == &null {
                return clang::QualType()
            }

            return clang::QualType::getFromOpaquePtr(
                (self.cctx->getCanonicalTagType(prev)).getAsOpaquePtr(),
            )
        }

        var loc = clang::SourceLocation()
        var unsafe *rd = clang::CXXRecordDecl::Create(
            *self.cctx,
            clang::TagTypeKind::Struct,
            tu,
            loc,
            loc,
            lii,
            &null,
        )

        rd->setImplicit(true)
        tu->addDecl(rd)
        rd->startDefinition()
        if size > 0 {
            var arr = self.cctx->getConstantArrayType(
                elem,
                llvm::APInt(64, size / align),
                &null,
                clang::ArraySizeModifier::Normal,
                0,
            )

            self._add_field(rd, arr, 0)
        }

        rd->completeDefinition()
        return clang::QualType::getFromOpaquePtr(
            (self.cctx->getCanonicalTagType(rd)).getAsOpaquePtr(),
        )
    }

    /// \p ct, a class template of ANOTHER set's AST, re-found in this one;
    /// null when this set never declared it. ForeignInstantiate's fallback
    /// set for an instance the primary's set cannot spell.
    fn refind_template(self,
                       ct: unsafe *clang::ClassTemplateDecl) -> unsafe *clang::ClassTemplateDecl {
        if ct == &null {
            return &null
        }

        var unsafe *d    = unsafe (ct as unsafe *clang::Decl)
        var unsafe *octx = unsafe &d->getASTContext()
        if octx == self.cctx {
            return ct
        }

        var unsafe *rf = self._refind(d)
        return TypeExport::class_template_of(unsafe (rf as unsafe *clang::Decl))
    }

    /// \p ftd, a function template of ANOTHER set's AST, re-found in this
    /// one; null when this set never declared it. An overload set shares the
    /// qualified path (`std::move(T&&)` beside the algorithm `std::move(It,
    /// It, Out)`), so the one whose declaration sits at the same header
    /// position is the match: both sets parsed the one header file.
    /// deduce_call's fallback set for a call the primary's set cannot spell.
    fn refind_function_template(self,
                                ftd: unsafe *clang::FunctionTemplateDecl) -> unsafe *clang::FunctionTemplateDecl {
        if ftd == &null {
            return &null
        }

        var unsafe *d    = unsafe (ftd as unsafe *clang::Decl)
        var unsafe *octx = unsafe &d->getASTContext()
        if octx == self.cctx {
            return ftd
        }

        var unsafe *nd = unsafe (ftd as unsafe *clang::NamedDecl)
        if nd->getIdentifier() == &null {
            return &null
        }

        var unsafe *first = self._refind(d)
        if first == &null {
            return &null
        }

        var *osm = &octx->getSourceManager()
        var opl  = osm->getPresumedLoc(d->getLocation(), true)
        if opl.isInvalid() {
            return &null
        }

        var        ofile = string(unsafe ((opl.getFilename() as unsafe *const u8) as *const u8))
        var        *nsm  = &self.cctx->getSourceManager()
        var unsafe *dc   = first->getDeclContext()
        // The name through THIS set's identifier table: a DeclarationName
        // of the other AST never matches here.
        var nsr: llvm::StringRef = nd->getName()
        var res = dc->lookup(
            clang::DeclarationName(
                self._ident(
                    string(unsafe ((nsr.data() as unsafe *const u8) as *const u8), nsr.size()),
                ),
            ),
        )

        for r in res {
            var unsafe *cand = llvm::dyn_cast<clang::FunctionTemplateDecl>(r)
            if cand == &null {
                continue
            }

            var npl = nsm->getPresumedLoc(r->getLocation(), true)
            if npl.isInvalid() {
                continue
            }

            if npl.getLine() != opl.getLine() || npl.getColumn() != opl.getColumn() {
                continue
            }

            if string(unsafe ((npl.getFilename() as unsafe *const u8) as *const u8)) == ofile {
                return cand
            }
        }

        return &null
    }

    /// \p d, a clang decl of ANOTHER set's AST, re-found in this set's AST by
    /// its qualified path -- namespaces (inline ones included, as written in
    /// its parents), then its name, of the same decl kind -- or null.
    priv fn _refind(self, d: unsafe *clang::Decl) -> unsafe *clang::NamedDecl {
        var unsafe *nd = llvm::dyn_cast_or_null<clang::NamedDecl>(d)
        if nd == &null {
            return &null
        }

        if nd->getIdentifier() == &null {
            return &null
        }

        var        names = cxx::std::vector<string>()
        var unsafe *dc   = nd->getDeclContext()
        while dc != &null && !dc->isTranslationUnit() {
            var unsafe *ns = llvm::dyn_cast<clang::NamespaceDecl>(dc)
            if ns == &null {
                if dc->isTransparentContext() {
                    dc = dc->getParent()
                    continue
                }

                // A member of a plain class (`RedeclarableTemplateDecl::
                // SpecIterator`): re-found through the class's own table. A
                // class that is itself an instance has no path another AST
                // shares, and a dependent one is not a place at all.
                var unsafe *orec = llvm::dyn_cast<clang::CXXRecordDecl>(dc)
                if orec == &null || llvm::isa<clang::ClassTemplateSpecializationDecl>(orec) {
                    return &null
                }

                if orec->getIdentifier() == &null || orec->isDependentContext() {
                    return &null
                }

                var rsr: llvm::StringRef = orec->getName()
                names.push_back(
                    string(unsafe ((rsr.data() as unsafe *const u8) as *const u8), rsr.size()),
                )

                dc = dc->getParent()
                continue
            }

            if ns->isAnonymousNamespace() {
                return &null
            }

            var sr: llvm::StringRef = ns->getName()
            names.push_back(
                string(unsafe ((sr.data() as unsafe *const u8) as *const u8), sr.size()),
            )

            dc = dc->getParent()
        }

        var unsafe *cur = unsafe (self.cctx->getTranslationUnitDecl() as unsafe *clang::DeclContext)
        for var i: usize = names.size(); i > 0; --i {
            var res = cur->lookup(clang::DeclarationName(self._ident(names[i - 1])))
            var next: unsafe *clang::DeclContext = &null
            for r in res {
                var unsafe *rns = llvm::dyn_cast<clang::NamespaceDecl>(r)
                if rns != &null {
                    next = unsafe (rns as unsafe *clang::DeclContext)
                    break
                }

                // A class on the path: its definition's table is the one that
                // holds the members (a forward declaration holds none).
                var unsafe *rrec = llvm::dyn_cast<clang::CXXRecordDecl>(r)
                if rrec != &null {
                    var unsafe *rdef = rrec->getDefinition()
                    if rdef != &null {
                        next = unsafe (rdef as unsafe *clang::DeclContext)
                        break
                    }
                }
            }

            if next == &null {
                return &null
            }

            cur = next
        }

        var nsr: llvm::StringRef = nd->getName()
        var res = cur->lookup(
            clang::DeclarationName(
                self._ident(
                    string(unsafe ((nsr.data() as unsafe *const u8) as *const u8), nsr.size()),
                ),
            ),
        )

        for r in res {
            if r->getKind() == d->getKind() {
                return r
            }
        }

        return &null
    }

    /// # stand-ins

    /// True when the three stand-in collaborators are wired.
    priv fn _can_standin(self) -> bool {
        return self.reg != &null && self.psym != &null && self.instances != &null
    }

    static fn _vec_of(l: FrozenList<unsafe *Type>) -> cxx::std::vector<unsafe *Type> {
        var v = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < l.size(); ++i {
            v.push_back(*l.get(i))
        }

        return v
    }

    /// `T?`: the Nullable lang item's instance over T, which is what
    /// NullableTypeLowering makes it and what EmitIR spells
    /// (`::builtin::Nullable<T>`), so its stand-in is that generic ADT's
    /// specialization like any other. Through the lang item, never the
    /// lowered slot: a fill runs during typing, long before that pass.
    priv fn _nullable(self, n: unsafe *NullableType) -> clang::QualType {
        if self.reg == &null || n->inner == &null {
            return clang::QualType()
        }

        var unsafe *nd = self.reg->nullable_lang()
        if nd == &null {
            return clang::QualType()
        }

        var args = cxx::std::vector<unsafe *Type>()
        args.push_back(n->inner)
        return self._standin_instance(nd, args)
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
    priv fn _shape(self,
                   d:          unsafe *Decl,
                   tk:         unsafe *clang::TagTypeKind,
                   tag:        unsafe *clang::QualType,
                   @inout out: cxx::std::vector<unsafe *Type>,
                   bases:      unsafe *cxx::std::vector<unsafe *Type> = &null) -> bool {
        *tk = clang::TagTypeKind::Struct
        var fields: unsafe *FrozenList<unsafe *FieldDecl> = &null
        if isa<StructDecl>(d) {
            fields = unsafe &cast<StructDecl>(d)->fields
        }

        if isa<UnionDecl>(d) {
            *tk    = clang::TagTypeKind::Union
            fields = unsafe &cast<UnionDecl>(d)->fields
        }

        if isa<ClassDecl>(d) {
            // Bases are mirrored as C++ bases by a caller that asks for them
            // (\p bases, _standin_of); one that does not still refuses. A
            // virtual base's subobject placement is not modelled.
            var *dl = &cast<ClassDecl>(d)->derives_list
            if dl->size() > 0 {
                if bases == &null {
                    return false
                }

                for var i: usize = 0; i < dl->size(); ++i {
                    var unsafe *e = dl->get(i)
                    if e == &null
                        || e->base == &null
                        || e->base->canonical == &null
                        || e->is_virtual {
                        return false
                    }

                    bases->push_back(e->base->canonical)
                }
            }

            fields = unsafe &cast<ClassDecl>(d)->fields
        }

        if isa<EnumDecl>(d) {
            var unsafe *en = cast<EnumDecl>(d)
            if !en->is_adt {
                return false
            }

            *tag = self._int_type(adt_declared_tag_kind(en))
            for var i: usize = 0; i < en->variants.size(); ++i {
                var unsafe *v = en->variants[i]
                if v == &null || v->is_pack_expansion {
                    return false
                }

                for var j: usize = 0; j < v->payload.size(); ++j {
                    out.push_back(TypeExport::_canon_of(v->payload[j]))
                }
            }

            return true
        }

        if fields == &null {
            return false
        }

        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *fd = (*fields)[i]
            if fd == &null || fd->is_static() {
                continue
            }

            out.push_back(TypeExport::_canon_of(fd))
        }

        return true
    }

    static fn _canon_of(fd: unsafe *FieldDecl) -> unsafe *Type {
        if fd == &null || fd->type_ == &null {
            return &null
        }

        return fd->type_->canonical
    }

    /// The clang integer for builtin integer kind \p k, as _builtin spells it.
    priv fn _int_type(self, k: BuiltinKind) -> clang::QualType {
        var bits = builtin_info(k)->bits
        if bits == 0 {
            bits = (self.cctx->getTypeSize(self.cctx->getSizeType()) as usize)
        }

        var sgn: u32 = if (builtin_info(k)->is_signed()) => (1) else => 0
        return self._int_of(bits as u32, sgn)
    }

    /// The clang integer of \p bits and sign. 64 bits is the TARGET's int64_t /
    /// uint64_t, the type CanonicalTypes spells i64 / u64 as (Int64Type): by
    /// width alone it was `long` on every LP64 target, but Darwin's int64_t is
    /// `long long`, so cxx::std::vector<u64>'s element was `unsigned long`
    /// beside a u64 spelled `unsigned long long` and every reference between
    /// them failed (the arm64 macOS compiler build). Unchanged elsewhere.
    priv fn _int_of(self, bits: u32, sgn: u32) -> clang::QualType {
        if bits == 64 {
            // getFromTargetType is private to ASTContext: pick the field by hand.
            var ll = self.cctx->getTargetInfo().getInt64Type() == clang::TargetInfo::SignedLongLong
            if ll {
                return clang::QualType::getFromOpaquePtr(
                    (if (sgn != 0) => (self.cctx->LongLongTy)
                     else => self.cctx->UnsignedLongLongTy).getAsOpaquePtr(),
                )
            }

            return clang::QualType::getFromOpaquePtr(
                (if (sgn != 0) => (self.cctx->LongTy)
                 else => self.cctx->UnsignedLongTy).getAsOpaquePtr(),
            )
        }

        return self.cctx->getIntTypeForBitwidth(bits, sgn)
    }

    /// The speller for the name EmitIR gives a Kairo decl. CXXSpell only
    /// reads decl facts, the TU's imm table and the PP symbols, so a
    /// sink-less context is enough. False if \p d has no TU to spell from
    /// or is nested in a type (the owner would need a stand-in of its own).
    priv fn _spell_for(self,
                       d:           unsafe *Decl,
                       @inout segs: cxx::std::vector<string>,
                       @inout leaf: string,
                       fid:         unsafe *u32) -> bool {
        var unsafe *tu = CXXSpell::tu_of(d)
        if tu == &null || tu->ctx == &null {
            return false
        }

        var cg = CodegenContext(tu->ctx, &null, self.psym, self.instances)
        var sp = CXXSpell(unsafe &cg)
        if sp.owner_types(d).size() > 0 {
            return false
        }

        (segs) = sp.ns_segments(d)
        (leaf) = sp.leaf(d)
        *fid   = tu->fid
        return true
    }

    /// The namespace \p segs names in this AST, declared as needed; null
    /// when a header's non-namespace already owns a segment's name.
    priv fn _namespace_for(self,
                           const segs: cxx::std::vector<string>) -> unsafe *clang::DeclContext {
        var        loc = clang::SourceLocation()
        var unsafe *dc = unsafe (self.cctx->getTranslationUnitDecl() as unsafe *clang::DeclContext)
        for var i: usize = 0; i < segs.size(); ++i {
            var unsafe *ii                              = self._ident((segs)[i])
            var        res                              = dc->lookup(clang::DeclarationName(ii))
            var        ns: unsafe *clang::NamespaceDecl = &null
            if !res.empty() {
                ns = llvm::dyn_cast<clang::NamespaceDecl>(res.front())
                if ns == &null {
                    return &null
                }
            } else {
                ns = clang::NamespaceDecl::Create(
                    &*self.cctx,
                    dc,
                    false,
                    loc,
                    loc,
                    ii,
                    &null,
                    false,
                )

                dc->addDecl(ns)
            }

            dc = unsafe (ns as unsafe *clang::DeclContext)
        }

        return dc
    }

    /// Define \p rd with \p tag (when not null) and then \p fields, each
    /// type through to_clang (and so through the substitution in force).
    /// False, with \p rd marked invalid, when a field has no clang type:
    /// all or nothing, or a stand-in found by name later would have the
    /// wrong shape.
    priv fn _define(self,
                    rd:            unsafe *clang::CXXRecordDecl,
                    tag:           clang::QualType,
                    @inout fields: cxx::std::vector<unsafe *Type>,
                    bases:         unsafe *cxx::std::vector<clang::QualType> = &null,
                    vptr:          bool = false) -> bool {
        if !rd->isBeingDefined() {
            rd->startDefinition()
        }

        if bases != &null && bases->size() > 0 {
            if self.sema == &null {
                self._abandon(rd)
                return false
            }

            var specs: llvm::SmallVector<unsafe *clang::CXXBaseSpecifier, 4>
            for var i: usize = 0; i < bases->size(); ++i {
                var unsafe *tsi = self.cctx->getTrivialTypeSourceInfo(
                    (*bases)[i],
                    clang::SourceLocation(),
                )

                var unsafe *bs = self.sema->CheckBaseSpecifier(
                    rd,
                    clang::SourceRange(),
                    false,
                    clang::AS_public,
                    tsi,
                    clang::SourceLocation(),
                )

                if bs == &null {
                    self._abandon(rd)
                    return false
                }

                specs.push_back(bs)
            }

            rd->setBases(specs.data(), specs.size() as u32)
        }

        var n: usize = 0
        if vptr {
            self._add_field(
                rd,
                clang::QualType::getFromOpaquePtr((self.cctx->VoidPtrTy).getAsOpaquePtr()),
                n,
            )

            n += 1
        }

        if !tag.isNull() {
            self._add_field(rd, tag, n)
            n += 1
        }

        for var i: usize = 0; i < fields.size(); ++i {
            var ft: clang::QualType
            if (fields)[i] != &null {
                ft = self.to_clang((fields)[i])
            }

            // A pointer field only needs a pointer's layout, and a stand-in
            // carries layout, nothing more: nothing names its fields. So a
            // pointee this set cannot spell (a Kairo record holding an
            // imported instance from ANOTHER set, which is refused above)
            // is `void *` here rather than the end of the stand-in. Without
            // it, `children: unordered_map<string, unsafe *Node>` failed to
            // fill whenever Node had an `unsafe *Ext` field and Ext held a
            // `cxx::std::set<string>` from a different header set; the map's
            // `op []` then came from the unfilled pattern, its result stayed
            // dependent, and `self.children[name]` was an ICE.
            if ft.isNull() && (fields)[i] != &null && isa<PointerType>(canon_unqual((fields)[i])) {
                ft = clang::QualType::getFromOpaquePtr((self.cctx->VoidPtrTy).getAsOpaquePtr())
            }

            // A field of a C++ type this set cannot see (a `set<string>` from
            // <set> while filling in <map>'s set): a blob of the same size and
            // alignment, measured in the set that owns the type. Layout is
            // all a stand-in carries.
            if ft.isNull() && (fields)[i] != &null {
                ft = self._opaque_like((fields)[i])
            }

            if ft.isNull() {
                self._abandon(rd)
                return false
            }

            // A by-value field of class type must be COMPLETE: a field
            // of an imported instance is only declared by template_id, and a
            // stand-in completed around an incomplete subobject is a record
            // clang never checked. Declaring its implicit copy assignment
            // (`is_copy_assignable<ConstraintSet>` from `pair<u64,
            // ConstraintSet>`) then walked into the subobject's missing
            // definition and segfaulted in LookupSpecialMember. Completing
            // it here instantiates `vector<unsafe *X>` as any use would. One
            // that will not complete (an instance whose pattern this set only
            // declares) is a blob in its place, measured where it is complete
            // (_opaque_like), else a byte: a stand-in carries layout for
            // phase A only, and an incomplete subobject is the crash, while
            // refusing the whole stand-in left every container of the record
            // unfilled.
            var bt = self.cctx->getBaseElementType(ft)
            if !bt.isNull() && bt->isRecordType() {
                if self.sema == &null || !self.sema->isCompleteType(clang::SourceLocation(), bt) {
                    var ol = self._opaque_like((fields)[i])
                    ft = if (!ol.isNull()) => (ol)
                         else => clang::QualType::getFromOpaquePtr(
                             (self.cctx->CharTy).getAsOpaquePtr(),
                         )
                }
            }

            self._add_field(rd, ft, n)
            n += 1
        }

        rd->completeDefinition()
        return true
    }

    /// A stand-in given up on after its definition started: completed (as
    /// it stands) and invalid, never left mid-definition. Something may
    /// already name it -- a CRTP base's specialization (`Mixin<B>` while B
    /// is being defined), a field's container (`vector<B *>` inside B) --
    /// and clang declaring an implicit member of THAT reaches it as a
    /// subobject: LookupSpecialMember on a record still being defined
    /// segfaulted the whole-tree type-check.
    priv fn _abandon(self, rd: unsafe *clang::CXXRecordDecl) {
        if rd->isBeingDefined() {
            rd->completeDefinition()
        }

        rd->setInvalidDecl()
    }

    priv fn _add_field(self, rd: unsafe *clang::CXXRecordDecl, ft: clang::QualType, i: usize) {
        var        loc  = clang::SourceLocation()
        var unsafe *fii = self._ident(LowerTargets::export_field(i))
        var unsafe *cf = clang::FieldDecl::Create(
            *self.cctx,
            rd,
            loc,
            loc,
            fii,
            ft,
            self.cctx->getTrivialTypeSourceInfo(ft, loc),
            &null,
            false,
            clang::ICIS_NoInit,
        )

        cf->setAccess(clang::AS_public)
        rd->addDecl(cf)
    }

    /// The stand-in for plain Kairo enum \p en: a scoped enum with a fixed
    /// underlying type, the one InterfaceEmitter writes (`enum class E :
    /// u32`; EnumNiche's enum_niche_kind is that rule). No enumerators:
    /// phase A only needs a complete enum of the right width, and no header
    /// names a Kairo enum's values. Found by name after the first use, like
    /// _standin. PRE: sema_lock() held.
    priv fn _standin_enum(self, en: unsafe *EnumDecl) -> clang::QualType {
        var unsafe *d = unsafe (en as unsafe *Decl)
        // A member enum (`DiagLabel::Style`) lives in its owner's
        // stand-in, as a member record does (_home_of). Refused before: the
        // owner's stand-in failed on that field, and with it every container
        // of the owner (`vector<DiagLabel>`) and of anything holding one
        // (`vector<unsafe *Diagnostic>`) fell back to the pattern, whose
        // `size_type` is dependent: SC063E on `v[i]`, SC066E on `i < v.size()`.
        var        leaf = ""
        var unsafe *dc  = self._home_of(d, unsafe &leaf)
        if dc == &null {
            return clang::QualType()
        }

        var unsafe *lii = self._ident(leaf)
        var        res  = dc->lookup(clang::DeclarationName(lii))
        if !res.empty() {
            var unsafe *prev = llvm::dyn_cast<clang::EnumDecl>(res.front())
            if prev == &null {
                return clang::QualType()
            }

            if !self._ours((TypeImport::usr_of(prev)).str(), d) { // a header's own `stem::E`.
                return clang::QualType()
            }

            return clang::QualType::getFromOpaquePtr(
                (self.cctx->getCanonicalTagType(prev)).getAsOpaquePtr(),
            )
        }

        var loc = clang::SourceLocation()
        var ut  = self._int_type(enum_niche_kind(en))
        var unsafe *ed = clang::EnumDecl::Create(
            &*self.cctx,
            dc,
            loc,
            loc,
            lii,
            &null,
            true,
            true,
            true,
        )

        ed->setImplicit(true)
        if decl_type_owner(d) != &null {
            ed->setAccess(clang::AS_public)
        }

        ed->setIntegerType(ut)
        dc->addDecl(ed)
        ed->startDefinition()
        var promo = ut
        if self.cctx->isPromotableIntegerType(ut) {
            promo = self.cctx->getPromotedIntegerType(ut)
        }

        ed->completeDefinition(ut, promo, 0, 0)

        var usr = TypeImport::usr_of(ed)
        if usr.empty() {
            dc->removeDecl(ed)
            return clang::QualType()
        }

        self.reg->put((usr).str(), d)
        return clang::QualType::getFromOpaquePtr(
            (self.cctx->getCanonicalTagType(ed)).getAsOpaquePtr(),
        )
    }

    /// The stand-in for plain Kairo record \p d in this set's AST, declared
    /// on first use and found by name after that. Null QualType when \p d
    /// is a shape it cannot mirror, or when its name is already taken there.
    /// PRE: sema_lock() held (it mutates the AST).
    priv fn _standin(self, d_in: unsafe *Decl, rt: unsafe *RecordType) -> clang::QualType {
        if !self._can_standin() {
            return clang::QualType()
        }

        self.used_standin = true // records, enums, ADTs alike: layout, no behaviour.
        if rt->args.size() > 0 {
            return clang::QualType()
        }

        return self._standin_of(NameLookup::representative(d_in))
    }

    /// _standin for non-generic record \p d, nested in a record or not.
    /// Where \p d's stand-in is declared, and its \p leaf name there: its
    /// namespace, or for a member type (a record or plain enum declared in a
    /// record) inside the owner's stand-in, spelled `::stem::Owner::Inner`
    /// as EmitIR spells it. Refused before, which left every container of a
    /// pointer to a nested record unfilled (`vector<unsafe *Segment>` in
    /// VirtualFileManager): no members, and `begin` / `end` from the pattern
    /// tied (SC064E). The owner may be mid-definition (its own field named
    /// the member), which is all a nested decl needs. Null when neither.
    priv fn _home_of(self, d: unsafe *Decl, leaf: unsafe *string) -> unsafe *clang::DeclContext {
        var unsafe *owner = decl_type_owner(d)
        if owner != &null {
            var oq = self._standin_of(NameLookup::representative(owner))
            if oq.isNull() {
                return &null
            }

            var unsafe *ord = oq->getAsCXXRecordDecl()
            if ord == &null {
                return &null
            }

            var unsafe *tu = CXXSpell::tu_of(d)
            if tu == &null || tu->ctx == &null {
                return &null
            }

            var cg = CodegenContext(tu->ctx, &null, self.psym, self.instances)
            *leaf = CXXSpell(unsafe &cg).leaf(d)
            return unsafe (ord as unsafe *clang::DeclContext)
        }

        var segs     = cxx::std::vector<string>()
        var fid: u32 = 0
        if !self._spell_for(d, &segs, &*leaf, unsafe &fid) {
            return &null
        }

        return self._namespace_for(segs)
    }

    /// The clang declaration of \p usr is \p d's stand-in: registered to
    /// it, or one a live check orphaned when it re-read \p d's file, which
    /// \p d now adopts (ForeignRegistry::adopt).
    priv fn _ours(self, usr: llvm::StringRef, d: unsafe *Decl) -> bool {
        var unsafe *have = self.reg->find(usr)
        if have == d {
            return true
        }

        return have == &null && self.reg->adopt(usr, d)
    }

    priv fn _standin_of(self, d: unsafe *Decl) -> clang::QualType {
        if decl_generic_params(d).size() > 0 {
            return clang::QualType()
        }

        var unsafe *en = dyn_cast<EnumDecl>(d)
        if en != &null && !en->is_adt {
            return self._standin_enum(en)
        }

        var tk     = clang::TagTypeKind::Struct
        var tag    = clang::QualType()
        var fields = cxx::std::vector<unsafe *Type>()
        var kbases = cxx::std::vector<unsafe *Type>()
        if !self._shape(d, unsafe &tk, unsafe &tag, &fields, unsafe &kbases) {
            return clang::QualType()
        }

        var        leaf   = ""
        var unsafe *owner = decl_type_owner(d)
        var unsafe *dc    = self._home_of(d, unsafe &leaf)
        if dc == &null {
            return clang::QualType()
        }

        var        loc  = clang::SourceLocation()
        var unsafe *lii = self._ident(leaf)
        var        res  = dc->lookup(clang::DeclarationName(lii))
        if !res.empty() {
            var unsafe *prev = llvm::dyn_cast<clang::CXXRecordDecl>(res.front())
            if prev == &null {
                return clang::QualType()
            }

            // Mid-definition: a field of d reached d again (`next: *S`). A
            // pointer to it only needs the name; a by-value cycle is
            // TypeCycleCheck's error, not ours.
            var ours = prev->isBeingDefined()
                || self._ours((TypeImport::usr_of(prev)).str(), d)
            if !ours { // a header's own `stem::S`.
                return clang::QualType()
            }

            return clang::QualType::getFromOpaquePtr(
                (self.cctx->getCanonicalTagType(prev)).getAsOpaquePtr(),
            )
        }

        var unsafe *rd = clang::CXXRecordDecl::Create(*self.cctx, tk, dc, loc, loc, lii, &null)
        rd->setImplicit(true)
        if owner != &null {
            rd->setAccess(clang::AS_public)
        }

        dc->addDecl(rd)
        return self._standin_body(d, rd, dc, tag, fields, kbases)
    }

    /// Define stand-in \p rd of \p d (declared in \p dc, empty so far):
    /// its bases, then its fields, then register it. Null on failure, with
    /// \p rd abandoned (_abandon) and taken out of \p dc.
    priv fn _standin_body(self,
                          d:               unsafe *Decl,
                          rd:              unsafe *clang::CXXRecordDecl,
                          dc:              unsafe *clang::DeclContext,
                          tag:             clang::QualType,
                          const fields_in: cxx::std::vector<unsafe *Type>,
                          const kbases_in: cxx::std::vector<unsafe *Type>) -> clang::QualType {
        var fields = fields_in
        var kbases = kbases_in
        // Bases: `class DiagEngine derives DiagEngineVBase`, `Decl
        // derives VisibilityAnnotation<Decl>, Annotation<Decl>`. Refused
        // before, which left every container of such a class -- or of a
        // nested type of one (`vector<DiagEngine::PoisonEntry>`) -- unfilled,
        // with the pattern's dependent `size_type`. Each base's stand-in
        // first, as a C++ base, so the layout is the Itanium one of the
        // emitted class. A vtable pointer is a stand-in's leading `void *`
        // (nothing calls through it); a class whose first virtual comes
        // with non-dynamic bases would put it before them, which this does
        // not model, so it is refused.
        // Being defined before the bases are spelled: a CRTP base (`Decl
        // derives Annotation<Decl>`) names this record as its argument, and
        // the lookup above takes a record mid-definition as ours.
        rd->startDefinition()
        var bq     = cxx::std::vector<clang::QualType>()
        var dyn_at = usize::MAX
        for var i: usize = 0; i < kbases.size(); ++i {
            var q = self.to_clang(kbases[i])
            // A base still being defined: this stand-in was reached through
            // a pointer field of that base (or of one of its fields), so the
            // base cannot be complete yet. Refused here rather than handed to
            // CheckBaseSpecifier, which refuses it too but reports "base class
            // has incomplete type" as a user error (CL001E) with no location.
            // The pointer field that asked falls back to `void *` (_define),
            // which has the same layout. Reached when a pointer-field chain
            // leads back to a class deriving a base still being defined
            // (Decl::semantic_dc typed `*DeclContext` does this).
            if q.isNull()
                || q->getAsCXXRecordDecl() == &null
                || q->getAsCXXRecordDecl()->isBeingDefined() {
                self._abandon(rd)
                dc->removeDecl(rd)
                return clang::QualType()
            }

            if dyn_at == usize::MAX && self._dynamic(kbases[i], 0) {
                dyn_at = bq.size()
            }

            bq.push_back(q)
        }

        // Itanium places the first dynamic base at offset 0 (the primary
        // base) whatever its position in the list; a stand-in's dynamism is
        // a field clang does not see, so the order says it instead.
        if dyn_at != usize::MAX && dyn_at != 0 {
            var ord = cxx::std::vector<clang::QualType>()
            ord.push_back(bq[dyn_at])
            for var i: usize = 0; i < bq.size(); ++i {
                if i != dyn_at {
                    ord.push_back(bq[i])
                }
            }

            bq = ord
        }

        var vptr = dyn_at == usize::MAX && self._own_virtual(d)
        if vptr && bq.size() > 0 {
            self._abandon(rd)
            dc->removeDecl(rd)
            return clang::QualType()
        }

        if !self._define(rd, tag, &fields, unsafe &bq, vptr) {
            dc->removeDecl(rd)
            return clang::QualType()
        }

        var usr = TypeImport::usr_of(rd)
        if usr.empty() {
            dc->removeDecl(rd)
            return clang::QualType()
        }

        self.reg->put((usr).str(), d)
        return clang::QualType::getFromOpaquePtr(
            (self.cctx->getCanonicalTagType(rd)).getAsOpaquePtr(),
        )
    }

    /// \p d declares a virtual (or override, or pure) method itself.
    priv fn _own_virtual(self, d: unsafe *Decl) -> bool {
        var unsafe *cd = dyn_cast<ClassDecl>(NameLookup::representative(decl_pattern(d)))
        if cd == &null {
            return false
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null {
                continue
            }

            if m->abi == AbiKind::Virtual || m->abi == AbiKind::Override {
                return true
            }

            if m->body_kind == FnBodyKind::Virtual {
                return true
            }
        }

        return false
    }

    /// Record type \p t has a vtable: an imported class clang calls dynamic,
    /// or a Kairo class with a virtual method of its own or in a base.
    priv fn _dynamic(self, t: unsafe *Type, depth: u32) -> bool {
        if depth > 64 {
            return false
        }

        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<RecordType>(c) {
            return false
        }

        var unsafe *d = cast<RecordType>(c)->decl
        if d == &null {
            return false
        }

        if decl_is_imported(d) || decl_is_imported(NameLookup::representative(decl_pattern(d))) {
            var q = self.to_clang(c)
            if q.isNull() {
                return false
            }

            var unsafe *rd = q->getAsCXXRecordDecl()
            return rd != &null && rd->hasDefinition() && rd->isDynamicClass()
        }

        if self._own_virtual(d) {
            return true
        }

        var unsafe *cd = dyn_cast<ClassDecl>(NameLookup::representative(decl_pattern(d)))
        if cd == &null {
            return false
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            if self._dynamic(e->base->canonical, depth + 1) {
                return true
            }
        }

        return false
    }

    /// A Kairo value parameter's canonical type (`value_type` is the syntax
    /// node as written, which to_clang cannot walk); null before T resolves it.
    priv static fn _value_canon(gp: unsafe *GenericParamDecl) -> unsafe *Type {
        if gp->value_type == &null {
            return &null
        }

        return gp->value_type->canonical
    }

    /// The stand-in TEMPLATE for Kairo generic primary \p prim: declared
    /// with its type parameters, never defined. Every instance is an
    /// explicit specialization of it. Found by name after the first use.
    /// Null for a shape with no stand-in, or a taken name.
    /// PRE: sema_lock() held.
    priv fn _standin_template(self, prim: unsafe *Decl) -> unsafe *clang::ClassTemplateDecl {
        var gps = decl_generic_params(prim)
        if gps.size() == 0 {
            return &null
        }

        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            // A pack has no fixed arity to specialize on. A value parameter is
            // a non-type template parameter of its Kairo type (below).
            if gp == &null || gp->is_pack {
                return &null
            }

            if gp->is_const_param {
                // Its C++ type must be integral: the instance argument is spelled
                // as a clang integral (to_clang_arg_of), which has no other shape.
                var vq = self.to_clang(TypeExport::_value_canon(gp))
                if vq.isNull() || !vq->isIntegralOrEnumerationType() {
                    return &null
                }
            }
        }

        var tk    = clang::TagTypeKind::Struct
        var tag0  = clang::QualType()
        var probe = cxx::std::vector<unsafe *Type>()
        if !self._shape(prim, unsafe &tk, unsafe &tag0, &probe) {
            return &null
        }

        var segs     = cxx::std::vector<string>()
        var leaf     = ""
        var fid: u32 = 0
        if !self._spell_for(prim, &segs, &leaf, unsafe &fid) {
            return &null
        }

        var unsafe *dc = self._namespace_for(segs)
        if dc == &null {
            return &null
        }

        var unsafe *lii = self._ident(leaf)
        var        res  = dc->lookup(clang::DeclarationName(lii))
        if !res.empty() {
            var unsafe *prev = llvm::dyn_cast<clang::ClassTemplateDecl>(res.front())
            if prev == &null { // a header's own `stem::G`, not a template.
                return &null
            }

            if !self._ours((TypeImport::usr_of(prev)).str(), prim) {
                return &null
            }

            return prev
        }

        var loc = clang::SourceLocation()
        var unsafe *tu = self.cctx->getTranslationUnitDecl()
        var params: llvm::SmallVector<unsafe *clang::NamedDecl, 8>
        var unsafe *tu_ctx = CXXSpell::tu_of(prim)->ctx
        var        cg      = CodegenContext(tu_ctx, &null, self.psym, self.instances)
        var        sp      = CXXSpell(unsafe &cg)
        for var i: usize = 0; i < gps.size(); ++i {
            var name = sp.imm_name(gps[i]->name.imm, fid)
            if gps[i]->is_const_param {
                var vt = self.to_clang(TypeExport::_value_canon(gps[i]))
                var unsafe *nt = clang::NonTypeTemplateParmDecl::Create(
                    *self.cctx,
                    unsafe (tu as unsafe *clang::DeclContext),
                    loc,
                    loc,
                    0,
                    i as u32,
                    self._ident(name),
                    vt,
                    false,
                    self.cctx->getTrivialTypeSourceInfo(vt, loc),
                )

                params.push_back(unsafe (nt as unsafe *clang::NamedDecl))
                continue
            }

            var unsafe *tp = clang::TemplateTypeParmDecl::Create(
                *self.cctx,
                unsafe (tu as unsafe *clang::DeclContext),
                loc,
                loc,
                0,
                i as u32,
                self._ident(name),
                true,
                false,
            )

            params.push_back(unsafe (tp as unsafe *clang::NamedDecl))
        }

        var unsafe *tpl = clang::TemplateParameterList::Create(
            *self.cctx,
            loc,
            loc,
            llvm::ArrayRef<unsafe *clang::NamedDecl>(params),
            loc,
            &null,
        )

        var unsafe *pat = clang::CXXRecordDecl::Create(*self.cctx, tk, dc, loc, loc, lii, &null)
        var unsafe *ct = clang::ClassTemplateDecl::Create(
            &*self.cctx,
            dc,
            loc,
            clang::DeclarationName(lii),
            tpl,
            unsafe (pat as unsafe *clang::NamedDecl),
        )

        pat->setDescribedClassTemplate(ct)
        pat->setImplicit(true)
        ct->setImplicit(true)
        dc->addDecl(ct)

        // TypeImport::_record reads an instance back through the TEMPLATE's
        // USR (spec->getSpecializedTemplate()); both spellings map to prim.
        var usr = TypeImport::usr_of(ct)
        if usr.empty() {
            dc->removeDecl(ct)
            return &null
        }

        self.reg->put(usr.str(), prim)
        var pusr = TypeImport::usr_of(pat)
        if !pusr.empty() {
            self.reg->put((pusr).str(), prim)
        }

        return ct
    }

    /// `G<int>` for an instance of Kairo generic \p prim_in at \p args: an
    /// explicit specialization of the stand-in template, defined with the
    /// pattern's fields where each parameter is read as this instance's
    /// argument. clang's specialization table answers the second use, and
    /// a self-reference mid-definition, so this is declared once per
    /// argument list. With concrete arguments the specialization's USR is
    /// registered to the registry instance, so `G<int>&` reads back as it.
    /// PRE: sema_lock() held.
    priv fn _standin_instance(self,
                              prim_in:    unsafe *Decl,
                              const args: cxx::std::vector<unsafe *Type>) -> clang::QualType {
        if !self._can_standin() {
            return clang::QualType()
        }

        self.used_standin = true // a Kairo generic's instance, `T?` (Nullable) included.
        var unsafe *prim = NameLookup::representative(prim_in)
        var unsafe *ct   = self._standin_template(prim)
        if ct == &null {
            return clang::QualType()
        }

        if decl_generic_params(prim).size() != args.size() {
            return clang::QualType()
        }

        var qs:      llvm::SmallVector<clang::QualType, 8>
        var targs:   llvm::SmallVector<clang::TemplateArgument, 8>
        var concrete                                               = true
        var vals = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < args.size(); ++i {
            var unsafe *a = (args)[i]
            if a == &null {
                return clang::QualType()
            }

            if a->is_dependent() || a->is_instantiation_dependent() {
                concrete = false
            }

            if decl_generic_params(prim)[i]->is_const_param {
                // A value argument: a clang integral of the parameter's type.
                // qs keeps a placeholder so the parameter indices still line up.
                var va = self.to_clang_arg_of(ct->getTemplateParameters(), i, a, &targs)
                if va.isNull() {
                    return clang::QualType()
                }

                qs.push_back(clang::QualType())
                targs.push_back(va)
                vals.push_back(a)
                continue
            }

            var q = self.to_clang(a)
            if q.isNull() {
                return q
            }

            qs.push_back(q)
            targs.push_back(clang::TemplateArgument(q))
            vals.push_back(&null)
        }

        var pos: unsafe *void = &null
        var unsafe *prev = ct->findSpecialization(
            llvm::ArrayRef<clang::TemplateArgument>(targs),
            &pos,
        )

        if prev != &null {
            if prev->isInvalidDecl() { // a field of it had no clang type; refused, sticky.
                return clang::QualType()
            }

            return clang::QualType::getFromOpaquePtr(
                (self.cctx->getCanonicalTagType(prev)).getAsOpaquePtr(),
            )
        }

        var tk     = clang::TagTypeKind::Struct
        var tag    = clang::QualType()
        var fields = cxx::std::vector<unsafe *Type>()
        if !self._shape(prim, unsafe &tk, unsafe &tag, &fields) {
            return clang::QualType()
        }

        var        loc = clang::SourceLocation()
        var unsafe *dc = ct->getDeclContext()
        // 22.x: the `StrictPackMatch` bool before PrevDecl. If the build says
        // the call has one argument too many, drop the `false`.
        var unsafe *spec = clang::ClassTemplateSpecializationDecl::Create(
            &*self.cctx,
            tk,
            dc,
            loc,
            loc,
            ct,
            llvm::ArrayRef<clang::TemplateArgument>(targs),
            false,
            &null,
        )

        spec->setSpecializationKind(clang::TSK_ExplicitSpecialization)
        spec->setImplicit(true)
        ct->AddSpecialization(spec, pos)
        dc->addDecl(spec)

        // The pattern's fields, its parameters read as this instance's
        // arguments. Saved around: a field's own instance argument
        // (`G<H<T>>`) nests one of these.
        var unsafe *saved_owner = self._sub_owner
        var unsafe *saved_args  = self._sub_args
        self._sub_owner = prim
        self._sub_args  = unsafe &qs
        var unsafe *saved_vals = self._sub_vals
        self._sub_vals = unsafe &vals
        var ok = self._define(spec, tag, &fields)
        self._sub_owner = saved_owner
        self._sub_args  = saved_args
        self._sub_vals  = saved_vals
        // On failure the spec stays in clang's table, invalid: findSpecialization
        // refuses it above, and it is never printed.
        if !ok {
            return clang::QualType()
        }

        if concrete {
            var kargs = cxx::std::vector<unsafe *Type>()
            for var i: usize = 0; i < args.size(); ++i {
                kargs.push_back((args)[i])
            }

            var hf = if (self.home_fid >= 0) => (self.home_fid as u32)
                     else => CXXSpell::fid_of(prim)
            var unsafe *e = self.instances->instance_for(
                prim,
                unsafe &kargs,
                hf,
                NameLookup::ctx_of(prim),
            )

            var usr = TypeImport::usr_of(spec)
            if e != &null && !usr.empty() {
                self.reg->put(usr.str(), e->decl)
            }
        }

        return clang::QualType::getFromOpaquePtr(
            (self.cctx->getCanonicalTagType(spec)).getAsOpaquePtr(),
        )
    }

    priv fn _ident(self, const s: string) -> unsafe *clang::IdentifierInfo {
        return unsafe &self.cctx->Idents.get(kairo::sref(s))
    }

    // builtins

    /// Mirrors TypeImport::_builtin, so a round trip is the identity on every
    /// canonical import can produce. Integers go by (width, sign) through the
    /// target, exactly as they came in.
    priv fn _builtin(self, bt: unsafe *BuiltinType) -> clang::QualType {
        var k = bt->builtin
        if builtin_info(k)->is_integer() {
            var bits = builtin_info(k)->bits
            if bits == 0 { // usize/isize: the store's target width.
                bits = bt->size_bits
            }

            var sgn: u32 = if (builtin_info(k)->is_signed()) => (1) else => 0
            // Past 128 there is no fundamental type to find; i256/u512 are
            // _BitInt, exactly as BuiltinTable spells them.
            if bits > 128 {
                return self.cctx->getBitIntType(sgn == 0, bits as u32)
            }

            return self._int_of(bits as u32, sgn)
        }

        match k {
            case BuiltinKind::Void {
                return clang::QualType::getFromOpaquePtr((self.cctx->VoidTy).getAsOpaquePtr())
            } case BuiltinKind::Bool {
                return clang::QualType::getFromOpaquePtr((self.cctx->BoolTy).getAsOpaquePtr())
            } case BuiltinKind::Char {
                return clang::QualType::getFromOpaquePtr((self.cctx->Char32Ty).getAsOpaquePtr())
            } case BuiltinKind::CChar {
                return clang::QualType::getFromOpaquePtr((self.cctx->CharTy).getAsOpaquePtr())
            } case BuiltinKind::CWChar {
                return clang::QualType::getFromOpaquePtr((self.cctx->WCharTy).getAsOpaquePtr())
            } case BuiltinKind::CChar16 {
                return clang::QualType::getFromOpaquePtr((self.cctx->Char16Ty).getAsOpaquePtr())
            } case BuiltinKind::CChar8 {
                return clang::QualType::getFromOpaquePtr((self.cctx->Char8Ty).getAsOpaquePtr())
            } case BuiltinKind::F16 {
                return clang::QualType::getFromOpaquePtr((self.cctx->Float16Ty).getAsOpaquePtr())
            } case BuiltinKind::BF16 {
                return clang::QualType::getFromOpaquePtr((self.cctx->BFloat16Ty).getAsOpaquePtr())
            } case BuiltinKind::F32 {
                return clang::QualType::getFromOpaquePtr((self.cctx->FloatTy).getAsOpaquePtr())
            } case BuiltinKind::F64 {
                return clang::QualType::getFromOpaquePtr((self.cctx->DoubleTy).getAsOpaquePtr())
            }

            // The format's address, compared as a pointer (as TypeImport
            // does): fltSemantics compared by value would be wrong.
            case BuiltinKind::F80 {
                var ld = clang::QualType::getFromOpaquePtr(
                    (self.cctx->LongDoubleTy).getAsOpaquePtr(),
                )

                var *fmt = &self.cctx->getFloatTypeSemantics(ld)
                if fmt == &llvm::APFloat::x87DoubleExtended() {
                    return ld
                }

                return clang::QualType()
            } case BuiltinKind::F128 {
                // _builtin maps a binary128 `long double` AND `__float128` to
                // f128; `long double` is the one headers actually spell.
                var ld = clang::QualType::getFromOpaquePtr(
                    (self.cctx->LongDoubleTy).getAsOpaquePtr(),
                )

                var *fmt = &self.cctx->getFloatTypeSemantics(ld)
                if fmt == &llvm::APFloat::IEEEquad() {
                    return ld
                }

                return clang::QualType::getFromOpaquePtr((self.cctx->Float128Ty).getAsOpaquePtr())
            } default { // never, byte, f8*, f256+: no import produces them.
                return clang::QualType()
            }
        }
    }
}
