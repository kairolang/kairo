///--- The Kairo Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Kairo Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).                                                   ///
///                                                                          ///
///   SPDX-License-Identifier: CC-BY-4.0                                     ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                       ///
///                                                                          ///
///------------------------------------------------------------ KAIRO -------///

#ifndef KAIRO_CLANG_BRIDGE_IMPL_HH
#define KAIRO_CLANG_BRIDGE_IMPL_HH

///
/// \file  Clang/ClangBridgeImpl.hh
/// \brief C++ implementation details for Clang interop.
///
/// contains the CRTP visitor, PPCallbacks, ASTConsumer, and FrontendAction
/// subclasses that can't be expressed in Kairo.  imported by ClangBridge.kro
/// via `ffi "c++" import`.
///
/// target: LLVM/Clang 22.x
///   - DiagnosticOptions is a plain value type (no IntrusiveRefCntPtr).
///   - DiagnosticsEngine takes DiagnosticOptions& in constructor.
///   - PPCallbacks::MacroDefined(const Token&, const MacroDirective*).
///

#include <clang/AST/ASTConsumer.h>
#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <clang/AST/DeclCXX.h>
#include <clang/AST/DeclTemplate.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/AST/StmtCXX.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/Basic/FileManager.h>
#include <clang/Basic/LangOptions.h>
#include <clang/Basic/SourceLocation.h>
#include <clang/Basic/SourceManager.h>
#include <clang/Basic/TargetInfo.h>
#include <clang/Basic/TargetOptions.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/Frontend/FrontendAction.h>
#include <clang/Frontend/FrontendActions.h>
#include <clang/Frontend/FrontendOptions.h>
#include <clang/Lex/HeaderSearch.h>
#include <clang/Lex/HeaderSearchOptions.h>
#include <clang/Lex/MacroArgs.h>
#include <clang/Lex/MacroInfo.h>
#include <clang/Lex/PPCallbacks.h>
#include <clang/Lex/Preprocessor.h>
#include <clang/Lex/PreprocessorOptions.h>
#include <llvm/ADT/IntrusiveRefCntPtr.h>
#include <llvm/ADT/StringRef.h>
#include <llvm/Support/VirtualFileSystem.h>
#include <llvm/TargetParser/Host.h>

#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace clang_detail {
enum class SymKind : uint8_t {
    None = 0,
    Function,
    Method,
    Constructor,
    Destructor,
    OperatorOverload,
    ConversionOperator,
    FriendFunction,
    CoroutineFunction,
    ExplicitObjectMethod,
    DeductionGuide,
    OverloadSet,
    FunctionTemplate,
    ClassTemplate,
    AliasTemplate,
    PackExpansion,
    Class,
    Union,
    Enum,
    EnumClass,
    TypeAlias,
    StructuredBinding,
    Concept,
    Variable,
    StaticMember,
    EnumConstant,
    MacroFunction,
    MacroConstant,
    Namespace,
};

struct RawSymbol {
    std::string name;
    std::string qualified_name;
    SymKind     kind = SymKind::None;
    std::string rendered_loc;  ///< "file:line:col"

    uint32_t min_arity        = 0;
    uint32_t max_arity        = 0;
    uint32_t type_param_count = 0;

    bool is_template  = false;
    bool is_callable  = false;
    bool is_type      = false;
    bool is_value     = false;
    bool is_namespace = false;

    bool is_variadic       = false;
    bool is_noexcept       = false;
    bool has_conversion_op = false;
    bool is_coroutine      = false;
    bool is_consteval      = false;
};

struct FileCord {
    std::string filename;
    uint32_t    offset = 0;  ///< 0-based byte offset into the file

    [[nodiscard]] bool is_valid() const { return !filename.empty(); }
};

auto to_file_cord(clang::SourceLocation loc, clang::SourceManager &csm)
    -> FileCord {
    if (loc.isInvalid()) {
        return {};
    }

    auto ploc = csm.getPresumedLoc(loc);
    if (!ploc.isValid()) {
        return {};
    }

    return {.filename = ploc.getFilename(), .offset = csm.getFileOffset(loc)};
}

auto to_clang_loc(const FileCord &cord, clang::SourceManager &csm)
    -> clang::SourceLocation {
    if (!cord.is_valid()) {
        return {};
    }

    auto fentry = csm.getFileManager().getFileRef(cord.filename);
    if (!fentry) {
        return {};
    }

    auto fid = csm.getOrCreateFileID(*fentry, clang::SrcMgr::C_User);
    return csm.getLocForStartOfFile(fid).getLocWithOffset(cord.offset);
}

class RawSymbolTable {
  public:
    void insert(RawSymbol sym) {
        auto qit = by_qualified_.find(sym.qualified_name);
        if (qit != by_qualified_.end()) {
            auto &existing = syms_[qit->second];
            if (existing.is_callable && sym.is_callable) {
                // don't merge a template decl with its templated function
                // the visitor fires for both; keep whichever is the template
                if (existing.is_template && !sym.is_template) {
                    return;
                }
                if (!existing.is_template && sym.is_template) {
                    // upgrade to template, don't create overload set
                    existing.kind             = sym.kind;
                    existing.is_template      = true;
                    existing.type_param_count = sym.type_param_count;
                    return;
                }
                // genuine overload: same name, both callables, same
                // template-ness
                existing.min_arity =
                    std::min(existing.min_arity, sym.min_arity);
                existing.max_arity =
                    std::max(existing.max_arity, sym.max_arity);
                existing.type_param_count =
                    std::max(existing.type_param_count, sym.type_param_count);
                existing.is_variadic = existing.is_variadic || sym.is_variadic;
                existing.is_noexcept = existing.is_noexcept && sym.is_noexcept;
                existing.is_template = existing.is_template || sym.is_template;
                existing.is_coroutine =
                    existing.is_coroutine || sym.is_coroutine;
                existing.is_consteval =
                    existing.is_consteval && sym.is_consteval;
                existing.kind = SymKind::OverloadSet;
                overload_type_params_[qit->second].push_back(
                    sym.type_param_count);
                return;
            }
            return;
        }
        size_t idx                        = syms_.size();
        by_qualified_[sym.qualified_name] = idx;
        by_name_[sym.name].push_back(idx);
        if (sym.is_callable && sym.kind != SymKind::OverloadSet) {
            overload_type_params_[idx].push_back(sym.type_param_count);
        }
        syms_.push_back(std::move(sym));
    }

    [[nodiscard]] const std::vector<RawSymbol> &symbols() const {
        return syms_;
    }
    [[nodiscard]] size_t size() const { return syms_.size(); }
    [[nodiscard]] bool   empty() const { return syms_.empty(); }

    [[nodiscard]] const std::unordered_map<std::string, std::vector<size_t>> &
    name_index() const {
        return by_name_;
    }
    [[nodiscard]] const std::unordered_map<std::string, size_t> &
    qualified_index() const {
        return by_qualified_;
    }
    [[nodiscard]] const std::unordered_map<size_t, std::vector<uint32_t>> &
    overload_params() const {
        return overload_type_params_;
    }

  private:
    std::vector<RawSymbol>                               syms_;
    std::unordered_map<std::string, std::vector<size_t>> by_name_;
    std::unordered_map<std::string, size_t>              by_qualified_;
    std::unordered_map<size_t, std::vector<uint32_t>>    overload_type_params_;
};

class DiagSink : public clang::DiagnosticConsumer {
  public:
    explicit DiagSink(std::vector<std::string> *sink = nullptr)
        : sink_(sink) {}

    void HandleDiagnostic(clang::DiagnosticsEngine::Level level,
                          const clang::Diagnostic        &info) override {
        if (sink_ == nullptr) {
            return;
        }
        llvm::SmallString<256> buf;
        info.FormatDiagnostic(buf);
        sink_->emplace_back(buf.str());
    }

  private:
    std::vector<std::string> *sink_;
};

class MacroCollector : public clang::PPCallbacks {
  public:
    MacroCollector(RawSymbolTable &table, clang::SourceManager &sm, bool sys)
        : table_(table)
        , sm_(sm)
        , include_system_(sys) {}

    void MacroDefined(const clang::Token          &name_tok,
                      const clang::MacroDirective *md) override {
        if (md == nullptr) {
            return;
        }
        const auto *mi = md->getMacroInfo();
        if ((mi == nullptr) || mi->isBuiltinMacro()) {
            return;
        }
        if (!include_system_ && sm_.isInSystemHeader(mi->getDefinitionLoc())) {
            return;
        }

        RawSymbol sym;
        sym.name           = name_tok.getIdentifierInfo()->getName().str();
        sym.qualified_name = sym.name;

        if (mi->isFunctionLike()) {
            sym.kind        = SymKind::MacroFunction;
            sym.is_callable = true;
            sym.min_arity   = mi->getNumParams();
            sym.max_arity   = mi->isVariadic()
                                  ? std::numeric_limits<uint32_t>::max()
                                  : mi->getNumParams();
            sym.is_variadic = mi->isVariadic();
        } else {
            sym.kind     = SymKind::MacroConstant;
            sym.is_value = true;
        }

        auto ploc = sm_.getPresumedLoc(mi->getDefinitionLoc());
        if (ploc.isValid()) {
            sym.rendered_loc = std::string(ploc.getFilename()) + ":" +
                               std::to_string(ploc.getLine()) + ":" +
                               std::to_string(ploc.getColumn());
        }

        table_.insert(std::move(sym));
    }

  private:
    RawSymbolTable       &table_;
    clang::SourceManager &sm_;
    bool                  include_system_;
};

class DeclCollector : public clang::RecursiveASTVisitor<DeclCollector> {
  public:
    DeclCollector(RawSymbolTable &table, clang::ASTContext &ctx, bool sys)
        : table_(table)
        , ctx_(ctx)
        , sm_(ctx.getSourceManager())
        , include_system_(sys) {}

    static bool shouldVisitImplicitCode() { return false; }
    static bool shouldVisitTemplateInstantiations() { return false; }

    bool VisitFunctionDecl(clang::FunctionDecl *d) {
        if (skip(d) || d->isFunctionTemplateSpecialization()) {
            return true;
        }

        if (d->isImplicit() || d->isDefaulted() || d->isDeleted() ||
            llvm::isa<clang::CXXDestructorDecl>(d)) {
            return true;
        }

        RawSymbol sym = make_base(d);
        fill_callable(sym, d);
        classify_function(sym, d);
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitFunctionTemplateDecl(clang::FunctionTemplateDecl *d) {
        if (skip(d)) {
            return true;
        }
        
        auto     *fd  = d->getTemplatedDecl();
        if (fd->isImplicit()) {
            return true;
        }

        RawSymbol sym = make_base(d);
        fill_callable(sym, fd);
        classify_function(sym, fd);
        sym.kind             = SymKind::FunctionTemplate;
        sym.is_template      = true;
        sym.type_param_count = d->getTemplateParameters()->size();
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitCXXRecordDecl(clang::CXXRecordDecl *d) {
        if (skip(d) || d->isInjectedClassName()) {
            return true;
        }
        if (auto *spec =
                llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(d)) {
            if (!spec->isExplicitSpecialization()) {
                return true;
            }
        }

        RawSymbol sym    = make_base(d);
        sym.is_type      = true;
        sym.is_namespace = true;
        sym.kind         = d->isUnion() ? SymKind::Union : SymKind::Class;

        for (auto *method : d->methods()) {
            if (llvm::isa<clang::CXXConversionDecl>(method)) {
                sym.has_conversion_op = true;
                break;
            }
        }

        table_.insert(std::move(sym));
        return true;
    }

    bool VisitClassTemplateDecl(clang::ClassTemplateDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym        = make_base(d);
        sym.kind             = SymKind::ClassTemplate;
        sym.is_type          = true;
        sym.is_template      = true;
        sym.is_namespace     = true;
        sym.type_param_count = d->getTemplateParameters()->size();
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitTypeAliasTemplateDecl(clang::TypeAliasTemplateDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym        = make_base(d);
        sym.kind             = SymKind::AliasTemplate;
        sym.is_type          = true;
        sym.is_template      = true;
        sym.type_param_count = d->getTemplateParameters()->size();
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitTypedefNameDecl(clang::TypedefNameDecl *d) {
        if (skip(d)) {
            return true;
        }
        if (llvm::isa<clang::TypeAliasDecl>(d)) {
            auto *tad = llvm::cast<clang::TypeAliasDecl>(d);
            if (tad->getDescribedAliasTemplate() != nullptr) {
                return true;
            }
        }
        RawSymbol sym = make_base(d);
        sym.kind      = SymKind::TypeAlias;
        sym.is_type   = true;
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitEnumDecl(clang::EnumDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym = make_base(d);
        sym.is_type   = true;
        if (d->isScoped()) {
            sym.kind         = SymKind::EnumClass;
            sym.is_namespace = true;
        } else {
            sym.kind = SymKind::Enum;
        }
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitEnumConstantDecl(clang::EnumConstantDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym = make_base(d);
        sym.kind      = SymKind::EnumConstant;
        sym.is_value  = true;
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitVarDecl(clang::VarDecl *d) {
        if (skip(d)) {
            return true;
        }
        if (d->isLocalVarDecl() || llvm::isa<clang::ParmVarDecl>(d)) {
            return true;
        }
        RawSymbol sym = make_base(d);
        sym.is_value  = true;
        sym.kind =
            d->isStaticDataMember() ? SymKind::StaticMember : SymKind::Variable;
        if (d->isConstexpr()) {
            sym.is_consteval = true;
        }
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitNamespaceDecl(clang::NamespaceDecl *d) {
        if (skip(d)) {
            return true;
        }

        if (d->isInline()) {
            return true;
        }

        RawSymbol sym    = make_base(d);
        sym.kind         = SymKind::Namespace;
        sym.is_namespace = true;
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitConceptDecl(clang::ConceptDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym        = make_base(d);
        sym.kind             = SymKind::Concept;
        sym.is_template      = true;
        sym.type_param_count = d->getTemplateParameters()->size();
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitDecompositionDecl(clang::DecompositionDecl *d) {
        if (skip(d)) {
            return true;
        }
        for (auto *binding : d->bindings()) {
            RawSymbol sym;
            sym.name           = binding->getName().str();
            sym.qualified_name = binding->getQualifiedNameAsString();
            sym.kind           = SymKind::StructuredBinding;
            sym.is_value       = true;
            fill_loc(sym, binding);
            table_.insert(std::move(sym));
        }
        return true;
    }

    bool VisitCXXDeductionGuideDecl(clang::CXXDeductionGuideDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym   = make_base(d);
        sym.kind        = SymKind::DeductionGuide;
        sym.is_callable = true;
        sym.is_template = true;
        fill_callable(sym, d);
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitUsingDecl(clang::UsingDecl *d) {
        if (skip(d)) {
            return true;
        }

        for (auto *shadow : d->shadows()) {
            auto *target = shadow->getTargetDecl();
            if (target == nullptr) {
                continue;
            }

            // synthesize a symbol using the shadow's unqualified name
            // but the target's properties
            RawSymbol sym;
            sym.name           = d->getNameAsString();
            sym.qualified_name = d->getQualifiedNameAsString();
            fill_loc(sym, d);

            if (auto *fd = llvm::dyn_cast<clang::FunctionDecl>(target)) {
                fill_callable(sym, fd);
                classify_function(sym, fd);
            } else if (auto *ftd = llvm::dyn_cast<clang::FunctionTemplateDecl>(
                           target)) {
                fill_callable(sym, ftd->getTemplatedDecl());
                classify_function(sym, ftd->getTemplatedDecl());
                sym.kind             = SymKind::FunctionTemplate;
                sym.is_template      = true;
                sym.type_param_count = ftd->getTemplateParameters()->size();
            } else if (auto *rd =
                           llvm::dyn_cast<clang::CXXRecordDecl>(target)) {
                sym.kind    = rd->isUnion() ? SymKind::Union : SymKind::Class;
                sym.is_type = true;
                sym.is_namespace = true;
            } else if (auto *ctd =
                           llvm::dyn_cast<clang::ClassTemplateDecl>(target)) {
                sym.kind             = SymKind::ClassTemplate;
                sym.is_type          = true;
                sym.is_template      = true;
                sym.is_namespace     = true;
                sym.type_param_count = ctd->getTemplateParameters()->size();
            } else if (auto *tnd =
                           llvm::dyn_cast<clang::TypedefNameDecl>(target)) {
                sym.kind    = SymKind::TypeAlias;
                sym.is_type = true;
            } else if (auto *vd = llvm::dyn_cast<clang::VarDecl>(target)) {
                sym.kind     = vd->isStaticDataMember() ? SymKind::StaticMember
                                                        : SymKind::Variable;
                sym.is_value = true;
            } else if (auto *ecd =
                           llvm::dyn_cast<clang::EnumConstantDecl>(target)) {
                sym.kind     = SymKind::EnumConstant;
                sym.is_value = true;
            } else if (auto *ed = llvm::dyn_cast<clang::EnumDecl>(target)) {
                sym.kind = ed->isScoped() ? SymKind::EnumClass : SymKind::Enum;
                sym.is_type      = true;
                sym.is_namespace = ed->isScoped();
            } else {
                continue;  // skip anything we don't recognize
            }

            table_.insert(std::move(sym));
        }
        return true;
    }

    bool VisitUnresolvedUsingValueDecl(clang::UnresolvedUsingValueDecl *d) {
        if (skip(d)) {
            return true;
        }
        // can't resolve at parse time, add as unknown callable/value
        RawSymbol sym = make_base(d);
        sym.is_value  = true;
        sym.kind      = SymKind::Variable;  // best guess
        table_.insert(std::move(sym));
        return true;
    }

    bool
    VisitUnresolvedUsingTypenameDecl(clang::UnresolvedUsingTypenameDecl *d) {
        if (skip(d)) {
            return true;
        }
        RawSymbol sym = make_base(d);
        sym.is_type   = true;
        sym.kind      = SymKind::TypeAlias;  // best guess
        table_.insert(std::move(sym));
        return true;
    }

    bool VisitUsingDirectiveDecl(clang::UsingDirectiveDecl *d) {
        if (skip(d)) {
            return true;
        }
        // the nominated namespace's symbols are already in the table
        // from VisitNamespaceDecl traversalnothing to add here.
        // but record the namespace itself so the parser knows
        // unqualified lookup should search it.
        // for now: no-op, parser handles this at sema level
        return true;
    }

  private:
    bool skip(const clang::Decl *d) const {
        if ((d == nullptr) || d->isInvalidDecl()) {
            return true;
        }
        if (!include_system_ && sm_.isInSystemHeader(d->getLocation())) {
            return true;
        }
        return false;
    }

    RawSymbol make_base(const clang::NamedDecl *d) {
        RawSymbol sym;
        sym.name           = d->getNameAsString();
        sym.qualified_name = d->getQualifiedNameAsString();
        fill_loc(sym, d);
        return sym;
    }

    void fill_loc(RawSymbol &sym, const clang::NamedDecl *d) {
        auto loc = d->getLocation();
        if (loc.isInvalid()) {
            return;
        }
        auto ploc = sm_.getPresumedLoc(loc);
        if (!ploc.isValid()) {
            return;
        }
        sym.rendered_loc = std::string(ploc.getFilename()) + ":" +
                           std::to_string(ploc.getLine()) + ":" +
                           std::to_string(ploc.getColumn());
    }

    static void fill_callable(RawSymbol &sym, const clang::FunctionDecl *fd) {
        sym.is_callable = true;

        unsigned min = 0;
        unsigned max = 0;
        for (unsigned i = 0; i < fd->getNumParams(); ++i) {
            if (!fd->getParamDecl(i)->hasDefaultArg()) {
                ++min;
            }
            ++max;
        }
        sym.min_arity = min;

        if (fd->isVariadic()) {
            sym.max_arity   = std::numeric_limits<uint32_t>::max();
            sym.is_variadic = true;
        } else {
            sym.max_arity = max;
        }

        if (const auto *fpt =
                fd->getType()->getAs<clang::FunctionProtoType>()) {
            if (fpt->isNothrow()) {
                sym.is_noexcept = true;
            }
        }

        if (fd->isConsteval()) {
            sym.is_consteval = true;
        }

        // coroutine check: only on user-written functions with an actual
        // parsed body. skip ctors, dtors, and anything implicitly defined
        // to avoid getBody() on not-yet-synthesized implicit specials.
        if (!llvm::isa<clang::CXXConstructorDecl>(fd) &&
            !llvm::isa<clang::CXXDestructorDecl>(fd) && !fd->isImplicit() &&
            !fd->isDefaulted() && !fd->isDeleted() &&
            fd->doesThisDeclarationHaveABody()) {
            auto *body = fd->getBody();
            if (body && llvm::isa<clang::CoroutineBodyStmt>(body)) {
                sym.is_coroutine = true;
            }
        }
    }

    static void classify_function(RawSymbol                 &sym,
                                  const clang::FunctionDecl *fd) {
        sym.kind     = SymKind::Function;
        sym.is_value = true;

        if (const auto *md = llvm::dyn_cast<clang::CXXMethodDecl>(fd)) {
            if (llvm::isa<clang::CXXConstructorDecl>(md)) {
                sym.kind = SymKind::Constructor;
            } else if (llvm::isa<clang::CXXDestructorDecl>(md)) {
                sym.kind = SymKind::Destructor;
            } else if (llvm::isa<clang::CXXConversionDecl>(md)) {
                sym.kind = SymKind::ConversionOperator;
            } else if (md->isOverloadedOperator()) {
                sym.kind = SymKind::OperatorOverload;
            } else if (md->hasCXXExplicitFunctionObjectParameter()) {
                sym.kind = SymKind::ExplicitObjectMethod;
            } else {
                sym.kind = SymKind::Method;
            }
        } else if (fd->isOverloadedOperator()) {
            sym.kind = SymKind::OperatorOverload;
        }

        if (fd->getFriendObjectKind() != clang::Decl::FOK_None) {
            sym.kind = SymKind::FriendFunction;
        }
    }

    RawSymbolTable       &table_;
    clang::ASTContext    &ctx_;
    clang::SourceManager &sm_;
    bool                  include_system_;
};

class ExtractorConsumer : public clang::ASTConsumer {
  public:
    ExtractorConsumer(RawSymbolTable &t, bool sys)
        : table_(t)
        , sys_(sys) {}
    void HandleTranslationUnit(clang::ASTContext &ctx) override {
        DeclCollector collector(table_, ctx, sys_);
        collector.TraverseDecl(ctx.getTranslationUnitDecl());
    }

  private:
    RawSymbolTable &table_;
    bool            sys_;
};

class ExtractorAction : public clang::ASTFrontendAction {
  public:
    ExtractorAction(RawSymbolTable &t, bool sys)
        : table_(t)
        , sys_(sys) {}

    std::unique_ptr<clang::ASTConsumer>
    CreateASTConsumer(clang::CompilerInstance &ci,
                      llvm::StringRef /*InFile*/) override {
        ci.getPreprocessor().addPPCallbacks(std::make_unique<MacroCollector>(
            table_, ci.getSourceManager(), sys_));
        return std::make_unique<ExtractorConsumer>(table_, sys_);
    }

  private:
    RawSymbolTable &table_;
    bool            sys_;
};

struct BridgeConfig {
    std::string                                     target_triple;
    std::string                                     cxx_std = "c++26";
    std::string                                     sysroot;
    std::string                                     resource_dir;
    std::vector<std::string>                        system_include_dirs;
    std::vector<std::string>                        user_include_dirs;
    std::vector<std::string>                        cxx_system_include_dirs;
    std::vector<std::string>                        defines;
    bool                                            suppress_diagnostics = true;
    llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> vfs;
};

class BridgeState {
  public:
    static BridgeState *create(const BridgeConfig &cfg) {
        auto *b    = new BridgeState();
        b->config_ = cfg;

        b->vfs_ = cfg.vfs ? cfg.vfs : llvm::vfs::getRealFileSystem();

        b->diag_opts_.ShowColors = false;

        b->diags_ = llvm::makeIntrusiveRefCnt<clang::DiagnosticsEngine>(
            llvm::makeIntrusiveRefCnt<clang::DiagnosticIDs>(), b->diag_opts_);

        if (cfg.suppress_diagnostics) {
            b->diags_->setClient(new DiagSink(nullptr), true);
        }

        clang::FileSystemOptions fs_opts;
        b->file_mgr_ =
            llvm::makeIntrusiveRefCnt<clang::FileManager>(fs_opts, b->vfs_);

        b->target_opts_         = std::make_shared<clang::TargetOptions>();
        b->target_opts_->Triple = cfg.target_triple.empty()
                                      ? llvm::sys::getDefaultTargetTriple()
                                      : cfg.target_triple;

        auto &lo     = b->lang_opts_;
        lo.CPlusPlus = lo.CPlusPlus11 = lo.CPlusPlus14 = true;
        lo.CPlusPlus17 = lo.CPlusPlus20 = lo.CPlusPlus23 = true;
        lo.CPlusPlus26                                   = true;
        lo.Exceptions = lo.CXXExceptions = true;
        lo.RTTI = lo.Bool = lo.WChar = true;

        b->hdr_opts_ = std::make_shared<clang::HeaderSearchOptions>();
        if (!cfg.resource_dir.empty())
            b->hdr_opts_->ResourceDir = cfg.resource_dir;
        if (!cfg.sysroot.empty())
            b->hdr_opts_->Sysroot = cfg.sysroot;

        for (auto &d : cfg.system_include_dirs) {
            b->hdr_opts_->AddPath(d, clang::frontend::System, false, false);
        }
        for (auto &d : cfg.user_include_dirs) {
            b->hdr_opts_->AddPath(d, clang::frontend::Angled, false, false);
        }
        for (auto &d : cfg.cxx_system_include_dirs) {
            b->hdr_opts_->AddPath(d, clang::frontend::CXXSystem, false, false);
        }

        b->pp_opts_ = std::make_shared<clang::PreprocessorOptions>();
        return b;
    }

    void reset_diagnostics() {
        diags_->Reset();
        diags_->getClient()->clear();
    }

    clang::DiagnosticsEngine         &diags() { return *diags_; }
    clang::FileManager               &file_mgr() { return *file_mgr_; }
    const clang::LangOptions         &lang_opts() { return lang_opts_; }
    const clang::TargetOptions       &target_opts() { return *target_opts_; }
    const clang::HeaderSearchOptions &hdr_opts() { return *hdr_opts_; }
    const clang::PreprocessorOptions &pp_opts() { return *pp_opts_; }
    const BridgeConfig               &config() { return config_; }

  private:
    BridgeConfig config_;

    // LLVM 22: DiagnosticOptions is a value, not IntrusiveRefCntPtr
    clang::DiagnosticOptions                           diag_opts_;
    llvm::IntrusiveRefCntPtr<clang::DiagnosticsEngine> diags_;
    llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>    vfs_;
    llvm::IntrusiveRefCntPtr<clang::FileManager>       file_mgr_;

    std::shared_ptr<clang::TargetOptions>       target_opts_;
    clang::LangOptions                          lang_opts_;
    std::shared_ptr<clang::HeaderSearchOptions> hdr_opts_;
    std::shared_ptr<clang::PreprocessorOptions> pp_opts_;
};

struct ExtractOpts {
    std::vector<std::string>  extra_include_dirs;
    std::vector<std::string>  extra_defines;
    bool                      include_system_symbols = false;
    std::vector<std::string> *diagnostic_sink        = nullptr;
};

inline RawSymbolTable extract_symbols(BridgeState       &bridge,
                                      const char        *filename,
                                      const ExtractOpts &opts) {
    RawSymbolTable table;
    bridge.reset_diagnostics();

    auto ci = std::make_unique<clang::CompilerInstance>();
    ci->setDiagnostics(&bridge.diags());
    ci->setFileManager(&bridge.file_mgr());

    if (opts.diagnostic_sink != nullptr) {
        ci->getDiagnostics().setClient(new DiagSink(opts.diagnostic_sink),
                                       true);
    }

    // Mutate the CI's own invocation in placeno setInvocation in LLVM 22
    ci->getLangOpts()          = bridge.lang_opts();
    ci->getTargetOpts().Triple = bridge.target_opts().Triple;
    ci->getHeaderSearchOpts()  = bridge.hdr_opts();
    ci->getPreprocessorOpts()  = bridge.pp_opts();

    for (const auto &d : opts.extra_include_dirs) {
        ci->getHeaderSearchOpts().AddPath(
            d, clang::frontend::Angled, false, false);
    }

    for (const auto &def : bridge.config().defines) {
        ci->getPreprocessorOpts().addMacroDef(def);
    }
    for (const auto &def : opts.extra_defines) {
        ci->getPreprocessorOpts().addMacroDef(def);
    }

    auto &front         = ci->getFrontendOpts();
    front.ProgramAction = clang::frontend::ParseSyntaxOnly;
    front.Inputs.clear();
    front.Inputs.push_back(
        clang::FrontendInputFile(filename, clang::Language::CXX));

    ci->setTarget(clang::TargetInfo::CreateTargetInfo(ci->getDiagnostics(),
                                                      ci->getTargetOpts()));

    if (!ci->hasTarget()) {
        return table;
    }

    ci->createSourceManager();

    auto action =
        std::make_unique<ExtractorAction>(table, opts.include_system_symbols);

    ci->ExecuteAction(*action);
    return table;
}

}  // namespace clang_detail

#endif  // KAIRO_CLANG_BRIDGE_IMPL_HH