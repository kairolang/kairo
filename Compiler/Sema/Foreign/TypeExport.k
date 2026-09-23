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
///       generic params, opaque, anything dependent   no concrete clang type.
///       a GENERIC Kairo record   (or an instance of one, or one nested in
///                                another type, or one with a base) no
///                                stand-in yet; see below.
///       a decl from ANOTHER set  its clang_decl points into a different
///                                ASTContext. v1 instantiates only through
///                                the set the primary came from, so a decl
///                                of any other set is refused, not re-found.
///       nullables, Kairo vectors/maps/slices   no C++ counterpart.
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
///     The stand-in carries layout, not behaviour: no methods, and implicit
///     special members only (a Kairo destructor or deleted copy is not
///     mirrored). That is enough for phase A, which declares members and
///     never instantiates their bodies; phase B sees the real type.
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
ffi "c++" import "llvm/ADT/SmallVector.h";

import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Context::InstantiationRegistry::*;
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

    fn TypeExport(self, cctx: *clang::ASTContext, sema: *clang::Sema, set: *void) {
        self.cctx = cctx;
        self.sema = sema;
        self.set  = set;
    }

    /// The clang type for canonical \p t, or a null QualType.
    fn to_clang(self, t: *Type) -> clang::QualType {
        if t == &null { return clang::QualType(); }
        if t->is_dependent() || t->is_instantiation_dependent() { return clang::QualType(); }

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

        // GenericParamType and OpaqueFFIType were caught as dependent / have
        // no shape; nullable, vector, map, slice, tuple have no C++ twin.
        return clang::QualType();
    }

    /// `ct<args...>` as a canonical clang type, or null. Declares the
    /// specialization (CheckTemplateIdType) but does NOT complete it: a
    /// nested argument only has to be nameable. PRE: sema_lock() held.
    fn template_id(self, ct: *clang::ClassTemplateDecl, args: ref!(llvm::SmallVector::<clang::QualType, 8>)) -> clang::QualType {
        if (ct == &null) || (self.sema == &null) { return clang::QualType(); }
        var loc = ct->getLocation();                     // any valid loc; the pattern's is honest.
        var ali = clang::TemplateArgumentListInfo(loc, loc);
        for var i: usize = 0; i < args.size(); ++i {
            var qt = args[i];
            ali.addArgument(clang::TemplateArgumentLoc(clang::TemplateArgument(qt),
                                                       self.cctx->getTrivialTypeSourceInfo(qt, loc)));
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

        // A Kairo-authored record: a stand-in under its emitted name.
        if (!decl_is_imported(d)) && (!decl_is_instance(d)) { return self._standin(d, rt); }

        // An unfilled instance of an imported template: spell the template-id
        // from its args. Recursing here is what makes `cont<cont<i32>>` work.
        var prim = decl_instantiated_from(d);
        if (prim == &null) || (!decl_is_instance(d)) { return clang::QualType(); }
        if decl_origin_set(prim) != self.set { return clang::QualType(); }
        var ct = TypeExport::class_template_of(reinterpret_cast::<*clang::Decl>(decl_clang(prim)));
        if ct == &null { return clang::QualType(); }
        var qs: llvm::SmallVector::<clang::QualType, 8>;
        for var i: usize = 0; i < rt->args.size(); ++i {
            var q = self.to_clang(*(rt->args.get(i)));
            if q.isNull() { return q; }
            qs.push_back(q);
        }
        return self.template_id(ct, qs);
    }

    /// The stand-in for Kairo record \p d in this set's AST, declared on
    /// first use and found by name after that. Null QualType when \p d is
    /// a shape it cannot mirror, or when its name is already taken there.
    /// PRE: sema_lock() held (it mutates the AST).
    priv fn _standin(self, d_in: *Decl, rt: *RecordType) -> clang::QualType {
        if (self.reg == &null) || (self.psym == &null) || (self.instances == &null) { return clang::QualType(); }
        var d = NameLookup::representative(d_in);
        if rt->args.size() > 0 { return clang::QualType(); }
        if decl_generic_params(d).size() > 0 { return clang::QualType(); }
        var tk = clang::TagTypeKind::Struct;
        var fields: *FrozenList::<*FieldDecl> = &null;
        if isa::<StructDecl>(d) { fields = &(cast::<StructDecl>(d)->fields); }
        else if isa::<UnionDecl>(d) { fields = &(cast::<UnionDecl>(d)->fields); tk = clang::TagTypeKind::Union; }
        else if isa::<ClassDecl>(d) {
            // A base would have to be mirrored first, and its layout with it.
            if cast::<ClassDecl>(d)->derives_list.size() > 0 { return clang::QualType(); }
            fields = &(cast::<ClassDecl>(d)->fields);
        }
        if fields == &null { return clang::QualType(); }   // enums, interfaces: no stand-in.

        // The name EmitIR gives d. CXXSpell only reads decl facts, the TU's
        // imm table and the PP symbols, so a sink-less context is enough.
        var tu = CXXSpell::tu_of(d);
        if (tu == &null) || (tu->ctx == &null) { return clang::QualType(); }
        var cg = CodegenContext(tu->ctx, &null, self.psym, self.instances);
        var sp = CXXSpell(&cg);
        // Nested in a type: the owner would need a stand-in of its own.
        if sp.owner_types(d).size() > 0 { return clang::QualType(); }
        var segs = sp.ns_segments(d);
        var leaf = sp.leaf(d);

        var loc = clang::SourceLocation();
        var dc  = static_cast::<*clang::DeclContext>(self.cctx->getTranslationUnitDecl());
        for var i: usize = 0; i < segs.size(); ++i {
            var ii  = self._ident(segs[i]);
            var res = dc->lookup(clang::DeclarationName(ii));
            var ns: *clang::NamespaceDecl = &null;
            if !res.empty() {
                ns = llvm::dyn_cast::<clang::NamespaceDecl>(res.front());
                if ns == &null { return clang::QualType(); }   // a header's non-namespace owns the name.
            } else {
                ns = clang::NamespaceDecl::Create(*(self.cctx), dc, false, loc, loc, ii, &null, false);
                dc->addDecl(ns);
            }
            dc = static_cast::<*clang::DeclContext>(ns);
        }

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
        rd->startDefinition();
        for var i: usize = 0; i < fields->size(); ++i {
            var fd = (*fields)[i];
            if (fd == &null) || fd->is_static() { continue; }
            var ft: clang::QualType;
            if (fd->type_ != &null) && (fd->type_->canonical != &null) { ft = self.to_clang(fd->type_->canonical); }
            if ft.isNull() {
                // All or nothing: a stand-in missing a field would be found
                // by name later with the wrong shape.
                dc->removeDecl(rd);
                return clang::QualType();
            }
            var fii = self._ident(f"__kairo_f{i}");
            var cf  = clang::FieldDecl::Create(*(self.cctx), rd, loc, loc, fii, ft,
                                               self.cctx->getTrivialTypeSourceInfo(ft, loc),
                                               &null, false, clang::ICIS_NoInit);
            cf->setAccess(clang::AS_public);
            rd->addDecl(cf);
        }
        rd->completeDefinition();

        var usr = TypeImport::usr_of(rd);
        if usr.empty() { dc->removeDecl(rd); return clang::QualType(); }
        self.reg->put(usr, d);
        return clang::QualType(self.cctx->getCanonicalTagType(rd));
    }

    priv fn _ident(self, s: string) -> *clang::IdentifierInfo {
        var ns = std::string_to_nstring(s);
        return &(self.cctx->Idents.get(llvm::StringRef(ns.raw(), ns.size())));
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
            return self.cctx->getIntTypeForBitwidth(static_cast::<u32>(bits), sgn);   // null past 128.
        }
        switch k {
            case BuiltinKind::Void { return clang::QualType(self.cctx->VoidTy); }
            case BuiltinKind::Bool { return clang::QualType(self.cctx->BoolTy); }
            case BuiltinKind::Char { return clang::QualType(self.cctx->Char32Ty); }
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
