#pragma once
//===----------------------------------------------------------------------===//
///
/// \file ClangSemaAgree.hh
/// \brief The Sema agreement pass: a walk of the clang AST of one Kairo TU
///        that checks clang's Sema reached the decisions Kairo's Sema made
///        (Compiler/Spec/SemaAgreement.md).
///
///   CodeGen hands clang a reduced C++ in which overloads are already
///   resolved, so every call Kairo bound to a declaration has one right
///   answer on clang's side. The fill records, per such call, the token
///   that closes it and where the declaration Kairo chose is written
///   (SemaAgreeTable). The walk joins each clang call expression to its
///   record by that token's location and compares clang's callee with the
///   recorded declaration.
///
///   The join is the location of one token (`)`), which the sink gives to
///   no other token; the comparison is by where a declaration is written
///   (file and byte offset), since the two compilers share no declaration
///   object. A clang callee agrees when it, its template pattern, its
///   primary template, or any redeclaration of those is located at the name
///   token of Kairo's declaration. It disagrees only when one of them is
///   located on bytes that spell its own name, somewhere else: the sink
///   gives a name's byte to the token that spells it, and puts every other
///   token on a free byte nearby, so only such a location says where a
///   declaration is written.
///
///   The walk runs as an ASTConsumer ahead of clang's CodeGen consumer, on
///   each top-level declaration as Sema finishes it, because clang's
///   CodeGen consumes a declaration in the same callback: a call that is
///   repaired must be repaired before then.
///
///   Repair: where clang's callee differs and the declaration Kairo chose
///   exists in clang's AST with the identical function type and the same
///   kind (both free or static, or both non-virtual instance methods of
///   one class), the callee reference is pointed at it. The argument
///   conversions clang computed stay valid because the parameter types are
///   the same. Everything else is reported and left as clang resolved it.
///
/// Part of the Kairo Project, under the Apache License v2.0 with the
/// Kairo Runtime Library Exception.
///
/// See: https://www.kairolang.org/LICENSE
/// SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
/// Copyright (c) 2026 Dhruvan Kartik
///
//===----------------------------------------------------------------------===//

#include "clang/AST/ASTConsumer.h"
#include "clang/AST/ASTContext.h"
#include "clang/AST/Decl.h"
#include "clang/AST/DeclCXX.h"
#include "clang/AST/DeclGroup.h"
#include "clang/AST/DeclTemplate.h"
#include "clang/AST/Expr.h"
#include "clang/AST/ExprCXX.h"
#include "clang/AST/PrettyPrinter.h"
#include "clang/AST/RecursiveASTVisitor.h"
#include "clang/Basic/CharInfo.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Frontend/MultiplexConsumer.h"
#include "clang/Sema/Sema.h"
#include "clang/Sema/SemaConsumer.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace kairo {

/// One call Kairo bound to a declaration. Locations are raw clang
/// SourceLocations of the TU's own SourceManager.
struct SemaAgreeCall {
    uint32_t at = 0;       ///< the token that closes the call
    uint32_t name = 0;     ///< the name token of the declaration Kairo chose; 0 when it has no clang location
    uint32_t decl = 0;     ///< first byte of that declaration; 0 likewise
    uint32_t decl_len = 0; ///< its length in bytes
    uint8_t state = 0;     ///< bit 0: clang's AST held the call; bit 1: reported; bit 2: has entries in SemaAgreeTable::alts
};

/// One disagreement.
struct SemaAgreeFinding {
    uint32_t call = 0;     ///< index into SemaAgreeTable::calls
    uint32_t clang_at = 0; ///< raw location of clang's callee
    uint32_t clang_len = 0; ///< length of its name there
    bool repaired = false;
    bool adl = false; ///< clang found its callee by argument-dependent lookup
    /// Why the call was left as clang resolved it: 0 repaired, 1 repair is
    /// off, 2 Kairo's declaration has no counterpart in clang's AST, 3 the
    /// two function types differ, 4 the two are of different kinds, 5 the
    /// node has no callee reference that can be re-pointed.
    uint8_t why = 0;
    ::std::string clang_name;
};

/// What the fill recorded for one TU, and what the walk found. Owned by the
/// TU's run; written by the fill before clang parses, read by the walk
/// during the parse and by the driver side after it.
class SemaAgreeTable {
public:
    bool repair = true;
    /// Count clang calls located in the stream that have no record.
    bool count_unrecorded = false;
    ::std::vector<SemaAgreeCall> calls;
    ::std::vector<SemaAgreeFinding> findings;
    uint64_t seen = 0;       ///< records clang's AST held, counted once each
    uint64_t agreed = 0;     ///< comparisons that agreed (a template body's call counts per instance)
    uint64_t agreed_inside = 0; ///< of those, by a location inside the declaration, not on its name
    uint64_t unchecked = 0;  ///< joined, but one side has no comparable location
    uint64_t dependent = 0;  ///< joined, but clang resolves the call per instance
    uint64_t by_instance = 0; ///< in an instance, a member of the specialization C++ selected
    uint64_t unrecorded = 0; ///< clang calls in the stream with no record (count_unrecorded)
    /// The clang FileIDs of the Kairo files are one contiguous block: its
    /// first hash value and its size.
    uint32_t block_base = 0;
    uint32_t block_n = 0;

    void add(uint32_t at, uint32_t name, uint32_t decl, uint32_t decl_len) {
        SemaAgreeCall c;
        c.at = at;
        c.name = name;
        c.decl = decl;
        c.decl_len = decl_len;
        _by_loc.try_emplace(static_cast<uint64_t>(at), static_cast<uint32_t>(calls.size()));
        calls.push_back(c);
    }

    /// Another declaration of the function call \p call was bound to: the
    /// name token of a redeclaration. In call order.
    void add_alt(uint32_t call, uint32_t name) {
        if (call < calls.size() && name != 0) {
            calls[call].state |= 4;
            alts.emplace_back(call, name);
        }
    }

    /// (call, name token) for each redeclaration of a call's declaration,
    /// sorted by call.
    ::std::vector<::std::pair<uint32_t, uint32_t>> alts;

    /// The record of the call closed by the token at \p raw, or null.
    SemaAgreeCall *find(uint32_t raw) {
        auto it = _by_loc.find(static_cast<uint64_t>(raw));
        return it == _by_loc.end() ? nullptr : &calls[it->second];
    }

    uint32_t index_of(const SemaAgreeCall *c) const { return static_cast<uint32_t>(c - calls.data()); }

    size_t finding_count() const { return findings.size(); }
    size_t call_count() const { return calls.size(); }
    uint32_t finding_call(size_t i) const { return findings[i].call; }
    uint32_t finding_clang_at(size_t i) const { return findings[i].clang_at; }
    uint32_t finding_clang_len(size_t i) const { return findings[i].clang_len; }
    bool finding_repaired(size_t i) const { return findings[i].repaired; }
    bool finding_adl(size_t i) const { return findings[i].adl; }
    uint8_t finding_why(size_t i) const { return findings[i].why; }
    ::std::string finding_clang_name(size_t i) const { return findings[i].clang_name; }

private:
    /// Keys widened to 64 bits: a raw location may equal a 32-bit DenseMap
    /// sentinel, a zero-extended one never does.
    llvm::DenseMap<uint64_t, uint32_t> _by_loc;
};

namespace sema_agree_detail {

    /// A place in a file: the file's identity and a byte offset.
    struct FilePos {
        const clang::FileEntry *file = nullptr;
        unsigned off = 0;
    };

    /// Finds the function declared at one file position. Bodies are not
    /// entered: a declaration is what is looked for.
    class DeclFinder : public clang::RecursiveASTVisitor<DeclFinder> {
    public:
        DeclFinder(clang::SourceManager &sm, FilePos want) : _sm(sm), _want(want) {}

        clang::FunctionDecl *found = nullptr;

        bool shouldVisitTemplateInstantiations() const { return false; }
        bool shouldVisitImplicitCode() const { return false; }
        bool TraverseStmt(clang::Stmt *) { return true; }
        bool TraverseTypeLoc(clang::TypeLoc, bool = true) { return true; }

        bool VisitFunctionDecl(clang::FunctionDecl *fd) {
            auto dec = _sm.getDecomposedExpansionLoc(fd->getLocation());
            if (dec.second != _want.off) {
                return true;
            }

            if (_sm.getFileEntryForID(dec.first) != _want.file) {
                return true;
            }

            found = fd;
            return false;
        }

    private:
        clang::SourceManager &_sm;
        FilePos _want;
    };

} // namespace sema_agree_detail

/// The walk. One per TU run, placed ahead of clang's CodeGen consumer.
class SemaAgreeConsumer final : public clang::SemaConsumer,
                                public clang::RecursiveASTVisitor<SemaAgreeConsumer> {
    using RAV = clang::RecursiveASTVisitor<SemaAgreeConsumer>;
    using FilePos = sema_agree_detail::FilePos;

public:
    explicit SemaAgreeConsumer(SemaAgreeTable *t) : _t(t) {}

    void Initialize(clang::ASTContext &ctx) override {
        _ctx = &ctx;
        _sm = &ctx.getSourceManager();
    }

    void InitializeSema(clang::Sema &s) override { _sema = &s; }
    void ForgetSema() override { _sema = nullptr; }

    bool HandleTopLevelDecl(clang::DeclGroupRef dg) override {
        if (_t->calls.empty() && !_t->count_unrecorded) {
            return true;
        }

        for (clang::Decl *d : dg) {
            _walk(d);
        }

        return true;
    }

    /// An inline member's body is complete, and consumed by CodeGen, before
    /// its class reaches HandleTopLevelDecl.
    void HandleInlineFunctionDefinition(clang::FunctionDecl *fd) override {
        if (_t->calls.empty() && !_t->count_unrecorded) {
            return;
        }

        if (_walk(fd)) {
            _walked.insert(fd);
        }
    }

    // RecursiveASTVisitor.

    bool shouldVisitTemplateInstantiations() const { return false; }
    bool shouldVisitImplicitCode() const { return false; }
    /// No call the fill records is written inside a type.
    bool TraverseTypeLoc(clang::TypeLoc, bool = true) { return true; }

    bool TraverseDecl(clang::Decl *d) {
        if (d != nullptr && !_walked.empty() && _walked.count(d) != 0) {
            return true;
        }

        const auto *fd = llvm::dyn_cast_or_null<clang::FunctionDecl>(d);
        bool inst = fd != nullptr && fd->isTemplateInstantiation();
        _instance += inst ? 1 : 0;
        bool r = RAV::TraverseDecl(d);
        _instance -= inst ? 1 : 0;
        return r;
    }

    bool VisitCallExpr(clang::CallExpr *e) {
        SemaAgreeCall *c = _t->find(e->getRParenLoc().getRawEncoding());
        if (c == nullptr) {
            _unrecorded(e->getRParenLoc());
            return true;
        }

        _mark_seen(c);
        auto *fd = llvm::dyn_cast_or_null<clang::FunctionDecl>(e->getCalleeDecl());
        if (fd == nullptr) {
            // A dependent callee is resolved in each instance, where this
            // same record is joined again; a call through a value has no
            // declaration to compare.
            if (e->isTypeDependent() || e->getCallee()->isTypeDependent()) {
                _t->dependent += 1;
            } else {
                _t->unchecked += 1;
            }

            return true;
        }

        _check(c, fd, e, e->usesADL());
        return true;
    }

    bool VisitCXXConstructExpr(clang::CXXConstructExpr *e) {
        clang::SourceLocation end = e->getParenOrBraceRange().getEnd();
        if (end.isInvalid()) {
            return true;
        }

        SemaAgreeCall *c = _t->find(end.getRawEncoding());
        if (c == nullptr) {
            return true;
        }

        _mark_seen(c);
        _check(c, e->getConstructor(), e, false);
        return true;
    }

    /// `T(x)`: a one-argument construction is a functional cast around the
    /// constructor call, or around the conversion function clang picked.
    bool VisitCXXFunctionalCastExpr(clang::CXXFunctionalCastExpr *e) {
        SemaAgreeCall *c = _t->find(e->getRParenLoc().getRawEncoding());
        if (c == nullptr) {
            return true;
        }

        _mark_seen(c);
        clang::Expr *sub = e->getSubExpr();
        if (sub != nullptr) {
            sub = sub->IgnoreImplicit();
        }

        if (auto *ce = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(sub)) {
            // One with a paren range of its own is visited as a construct.
            if (ce->getParenOrBraceRange().getEnd() != e->getRParenLoc()) {
                _check(c, ce->getConstructor(), ce, false);
            }

            return true;
        }

        if (auto *mc = llvm::dyn_cast_or_null<clang::CXXMemberCallExpr>(sub)) {
            if (auto *conv = llvm::dyn_cast_or_null<clang::CXXConversionDecl>(mc->getCalleeDecl())) {
                _check(c, conv, e, false);
                return true;
            }
        }

        // A cast of a scalar, or of a type clang has not completed.
        if (e->isTypeDependent()) {
            _t->dependent += 1;
        } else {
            _t->unchecked += 1;
        }

        return true;
    }

    bool VisitCXXUnresolvedConstructExpr(clang::CXXUnresolvedConstructExpr *e) {
        SemaAgreeCall *c = _t->find(e->getRParenLoc().getRawEncoding());
        if (c != nullptr) {
            _mark_seen(c);
            _t->dependent += 1;
        }

        return true;
    }

private:
    SemaAgreeTable *_t;
    clang::ASTContext *_ctx = nullptr;
    clang::SourceManager *_sm = nullptr;
    clang::Sema *_sema = nullptr;
    /// Inline bodies already walked, so their class does not walk them again.
    llvm::DenseSet<const clang::Decl *> _walked;
    llvm::DenseMap<clang::FileID, const clang::FileEntry *> _files;
    unsigned _searches = 0;
    /// How many template instances enclose the declaration being walked.
    unsigned _instance = 0;

    /// Whether \p fid is one of the Kairo files the stream's tokens are
    /// located in.
    bool _in_block(clang::FileID fid) const {
        unsigned h = fid.getHashValue();
        return h >= _t->block_base && h - _t->block_base < _t->block_n;
    }

    /// Walks \p d when the stream wrote it: a declaration from a header
    /// clang read itself holds no recorded call.
    bool _walk(clang::Decl *d) {
        if (d == nullptr || _sm == nullptr) {
            return false;
        }

        clang::SourceLocation loc = d->getLocation();
        if (loc.isInvalid() || !_in_block(_sm->getDecomposedExpansionLoc(loc).first)) {
            return false;
        }

        TraverseDecl(d);
        return true;
    }

    void _mark_seen(SemaAgreeCall *c) {
        if ((c->state & 1) == 0) {
            c->state |= 1;
            _t->seen += 1;
        }
    }

    void _unrecorded(clang::SourceLocation at) {
        if (!_t->count_unrecorded || at.isInvalid()) {
            return;
        }

        if (_in_block(_sm->getDecomposedExpansionLoc(at).first)) {
            _t->unrecorded += 1;
        }
    }

    const clang::FileEntry *_file(clang::FileID fid) {
        auto it = _files.find(fid);
        if (it != _files.end()) {
            return it->second;
        }

        const clang::FileEntry *fe = _sm->getFileEntryForID(fid);
        _files.try_emplace(fid, fe);
        return fe;
    }

    FilePos _pos(clang::SourceLocation loc) {
        FilePos p;
        if (loc.isInvalid()) {
            return p;
        }

        auto dec = _sm->getDecomposedExpansionLoc(loc);
        p.file = _file(dec.first);
        p.off = dec.second;
        return p;
    }

    /// What the redeclarations of clang's callee say about where it is
    /// written.
    struct Where {
        bool hit = false;    ///< one is located at the name Kairo chose
        bool inside = false; ///< one is located inside the declaration Kairo chose
        bool spelled = false; ///< one is located on bytes that spell its own name
        FilePos name;        ///< that name's position
        clang::SourceLocation name_loc;
        unsigned name_len = 0;
    };

    /// Whether the bytes at \p r's location spell \p r's name. A sink gives
    /// a declaration's name byte to the first token that spells the name, so
    /// such a location is where Kairo wrote the declaration; any other
    /// token of the stream sits on whatever byte was free.
    bool _spelled(const clang::FunctionDecl *r) {
        clang::SourceLocation loc = r->getLocation();
        if (loc.isInvalid() || !loc.isFileID()) {
            return false;
        }

        const clang::IdentifierInfo *ii = r->getIdentifier();
        if (const auto *ctor = llvm::dyn_cast<clang::CXXConstructorDecl>(r)) {
            ii = ctor->getParent()->getIdentifier();
        }

        if (ii == nullptr) {
            return false;
        }

        bool invalid = false;
        const char *p = _sm->getCharacterData(loc, &invalid);
        if (invalid || p == nullptr) {
            return false;
        }

        llvm::StringRef n = ii->getName();
        if (::std::strncmp(p, n.data(), n.size()) != 0) {
            return false;
        }

        return !clang::isAsciiIdentifierContinue(static_cast<unsigned char>(p[n.size()]));
    }

    unsigned _name_len(const clang::FunctionDecl *r) {
        const clang::IdentifierInfo *ii = r->getIdentifier();
        if (const auto *ctor = llvm::dyn_cast<clang::CXXConstructorDecl>(r)) {
            ii = ctor->getParent()->getIdentifier();
        }

        return ii != nullptr ? static_cast<unsigned>(ii->getName().size()) : 1;
    }

    void _scan(const clang::FunctionDecl *fd, FilePos want, FilePos k, unsigned len, Where &w) {
        if (fd == nullptr || w.hit) {
            return;
        }

        for (const clang::FunctionDecl *r : fd->redecls()) {
            FilePos p = _pos(r->getLocation());
            if (p.file == nullptr) {
                continue;
            }

            if (want.file != nullptr && p.file == want.file && p.off == want.off) {
                w.hit = true;
                return;
            }

            if (k.file != nullptr && p.file == k.file && p.off >= k.off && p.off - k.off < len) {
                w.inside = true;
            }

            if (!w.spelled && _spelled(r)) {
                w.spelled = true;
                w.name = p;
                w.name_loc = r->getLocation();
                w.name_len = _name_len(r);
            }
        }
    }

    /// \p fd and every declaration it stands for: an instance is written
    /// where its pattern is, and a specialization agrees with its primary
    /// template, since which specialization serves an instance is C++'s
    /// choice (Compiler/Spec/Generics.md).
    void _scan_all(const clang::FunctionDecl *fd, FilePos want, FilePos k, unsigned len, Where &w) {
        _scan(fd, want, k, len, w);
        _scan(fd->getTemplateInstantiationPattern(), want, k, len, w);
        if (const clang::FunctionTemplateDecl *pt = fd->getPrimaryTemplate()) {
            _scan(pt->getTemplatedDecl(), want, k, len, w);
            if (const clang::FunctionTemplateDecl *mt = pt->getInstantiatedFromMemberTemplate()) {
                _scan(mt->getTemplatedDecl(), want, k, len, w);
            }
        }

        _scan(fd->getInstantiatedFromMemberFunction(), want, k, len, w);
        if (const auto *ctor = llvm::dyn_cast<clang::CXXConstructorDecl>(fd)) {
            if (const clang::CXXConstructorDecl *base = ctor->getInheritedConstructor().getConstructor()) {
                _scan_all(base, want, k, len, w);
            }
        }
    }

    void _check(SemaAgreeCall *c, clang::FunctionDecl *fd, clang::Expr *node, bool adl) {
        if (fd == nullptr || (c->name == 0 && c->decl == 0)) {
            _t->unchecked += 1;
            return;
        }

        FilePos want = _pos(clang::SourceLocation::getFromRawEncoding(c->name));
        FilePos k = _pos(clang::SourceLocation::getFromRawEncoding(c->decl));
        if (want.file == nullptr && k.file == nullptr) {
            _t->unchecked += 1;
            return;
        }

        Where w;
        _scan_all(fd, want, k, c->decl_len, w);
        if (w.hit) {
            _t->agreed += 1;
            return;
        }

        // A disagreement needs proof that clang's callee is written somewhere
        // else: a location on bytes that spell its name. Without one (an
        // operator, an implicit member, a name C++ spells differently) a
        // location inside Kairo's declaration is taken as agreement, and
        // anything else is not comparable.
        if (!w.spelled || want.file == nullptr) {
            if (w.inside) {
                _t->agreed += 1;
                _t->agreed_inside += 1;
            } else {
                _t->unchecked += 1;
            }

            return;
        }

        // Kairo bound the call to one declaration of a function declared
        // more than once; the stream may have written another.
        if ((c->state & 4) != 0) {
            uint32_t ci = _t->index_of(c);
            auto it = ::std::lower_bound(_t->alts.begin(), _t->alts.end(), ::std::make_pair(ci, 0u));
            for (; it != _t->alts.end() && it->first == ci; ++it) {
                Where a;
                _scan_all(fd, _pos(clang::SourceLocation::getFromRawEncoding(it->second)), k, c->decl_len, a);
                if (a.hit) {
                    _t->agreed += 1;
                    return;
                }
            }
        }

        // In an instance, a member of a partial or explicit specialization
        // of a class template is the one C++ selected for that instance
        // (Compiler/Spec/Generics.md); Kairo bound the call, in the generic
        // body, to the primary template's member.
        if (_instance > 0 && _specialized_member(fd)) {
            _t->by_instance += 1;
            return;
        }

        if ((c->state & 2) != 0) {
            return;
        }

        c->state |= 2;
        SemaAgreeFinding f;
        f.call = _t->index_of(c);
        f.clang_at = w.name_loc.getRawEncoding();
        f.clang_len = w.name_len;
        f.adl = adl;
        f.clang_name = _name(fd);
        f.why = _repair(want, fd, node);
        f.repaired = f.why == 0;
        _t->findings.push_back(::std::move(f));
    }

    /// Whether \p fd is a member of a class template's explicit
    /// specialization, or of an instance of one of its partial ones.
    static bool _specialized_member(const clang::FunctionDecl *fd) {
        const auto *m = llvm::dyn_cast<clang::CXXMethodDecl>(fd);
        if (m == nullptr) {
            return false;
        }

        const auto *spec = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(m->getParent());
        if (spec == nullptr) {
            return false;
        }

        if (spec->isExplicitSpecialization()) {
            return true;
        }

        return llvm::isa<clang::ClassTemplatePartialSpecializationDecl *>(spec->getSpecializedTemplateOrPartial());
    }

    ::std::string _name(const clang::FunctionDecl *fd) {
        ::std::string s;
        llvm::raw_string_ostream os(s);
        clang::PrintingPolicy pol(_ctx->getLangOpts());
        pol.SuppressUnwrittenScope = true;
        fd->getNameForDiagnostic(os, pol, true);
        os << '(';
        bool first = true;
        for (const clang::ParmVarDecl *p : fd->parameters()) {
            if (!first) {
                os << ", ";
            }

            first = false;
            p->getType().print(os, pol);
        }

        os << ')';
        return s;
    }

    /// Points \p node at the declaration Kairo chose, when that is sound.
    /// Returns 0, or why not (SemaAgreeFinding::why).
    uint8_t _repair(FilePos want, clang::FunctionDecl *x, clang::Expr *node) {
        if (!_t->repair) {
            return 1;
        }

        // The search reads every declaration of the TU, so a TU with many
        // disagreements stops searching: each is reported either way.
        if (_searches >= 8) {
            return 2;
        }

        _searches += 1;
        sema_agree_detail::DeclFinder finder(*_sm, want);
        finder.TraverseDecl(_ctx->getTranslationUnitDecl());
        clang::FunctionDecl *y = finder.found;
        if (y == nullptr || y->isInvalidDecl() || y->isDeleted()) {
            return 2;
        }

        if (y->isTemplated() || x->isTemplated() || y->isDependentContext()) {
            return 2;
        }

        if (x->isConsteval() != y->isConsteval()) {
            return 4;
        }

        auto *xm = llvm::dyn_cast<clang::CXXMethodDecl>(x);
        auto *ym = llvm::dyn_cast<clang::CXXMethodDecl>(y);
        bool xi = xm != nullptr && xm->isInstance();
        bool yi = ym != nullptr && ym->isInstance();
        if (xi != yi) {
            return 4;
        }

        if (xi) {
            if (xm->getParent()->getCanonicalDecl() != ym->getParent()->getCanonicalDecl()) {
                return 4;
            }

            if (xm->isVirtual() || ym->isVirtual()) {
                return 4;
            }

            if (llvm::isa<clang::CXXConstructorDecl>(xm)
                || llvm::isa<clang::CXXConstructorDecl>(ym)
                || llvm::isa<clang::CXXDestructorDecl>(xm)
                || llvm::isa<clang::CXXDestructorDecl>(ym)
                || llvm::isa<clang::CXXConversionDecl>(xm)
                || llvm::isa<clang::CXXConversionDecl>(ym)) {
                return 4;
            }
        }

        if (!_ctx->hasSameType(x->getType(), y->getType())) {
            return 3;
        }

        auto *call = llvm::dyn_cast<clang::CallExpr>(node);
        if (call == nullptr) {
            return 5;
        }

        clang::Expr *callee = call->getCallee()->IgnoreParenImpCasts();
        if (auto *dre = llvm::dyn_cast<clang::DeclRefExpr>(callee)) {
            // Explicit template arguments name a template; the declaration
            // Kairo chose is not one.
            if (dre->getDecl() != x || dre->hasExplicitTemplateArgs()) {
                return 5;
            }

            dre->setDecl(y);
        } else if (auto *me = llvm::dyn_cast<clang::MemberExpr>(callee)) {
            if (me->getMemberDecl() != x || me->hasExplicitTemplateArgs()) {
                return 5;
            }

            me->setMemberDecl(y);
        } else {
            return 5;
        }

        // Its body is emitted only if something refers to it.
        if (_sema != nullptr) {
            _sema->MarkFunctionReferenced(call->getExprLoc(), y);
        } else {
            y->setIsUsed();
        }

        return 0;
    }
};

/// Whether a disagreement is reported (I012W) when -fsema-agreement is not
/// given. The one switch for it: the pass itself runs, and counts, either
/// way.
///
/// A release-built compiler stays silent. Sema's pick among the overloads
/// of an imported C++ set differs from clang's on ordinary interop code
/// (Compiler/Spec/SemaAgreement.md, "Known disagreements"), and the
/// message tells its reader to report a compiler bug. This returns true in
/// every build once Sema's picks for those sets match clang's.
inline bool sema_agree_reports_unasked() {
#ifdef DEBUG
    return true;
#else
    return false;
#endif
}

/// \p inner behind the agreement walk for \p t, or \p inner alone when
/// there is no table (the pass is off).
inline ::std::unique_ptr<clang::ASTConsumer> sema_agree_wrap(::std::unique_ptr<clang::ASTConsumer> inner,
                                                           SemaAgreeTable *t) {
    if (t == nullptr || inner == nullptr) {
        return inner;
    }

    ::std::vector<::std::unique_ptr<clang::ASTConsumer>> both;
    both.push_back(::std::make_unique<SemaAgreeConsumer>(t));
    both.push_back(::std::move(inner));
    return ::std::make_unique<clang::MultiplexConsumer>(::std::move(both));
}

} // namespace kairo
