///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: Apache-2.0                                                        ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __CXIR_H__
#define __CXIR_H__

#include <filesystem>
#include <memory>
#include <optional>
#include <regex>
#include <string>
#include <utility>
#include <vector>

#include "generator/include/CX-IR/tokens.def"
#include "generator/include/config/Gen_config.def"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/AST.hh"
#include "parser/ast/include/nodes/AST_declarations.hh"

namespace kairo::lsp {
static void dbg(const std::string &msg);
}

const std::regex
    double_semi_regexp(R"(;\r?\n\s*?;)");  // Matches any whitespace around the semicolons
inline std::string get_neo_clang_format_config() {
    return R"(
Language:        Cpp
BasedOnStyle:  Google
AccessModifierOffset: -2
NamespaceIndentation: Inner
AlignAfterOpenBracket: Align
AlignConsecutiveAssignments: true
AlignConsecutiveDeclarations: true
AlignEscapedNewlines: Left
AlignOperands:   true
AlignTrailingComments: true
AllowAllParametersOfDeclarationOnNextLine: true
AllowShortBlocksOnASingleLine: true
AllowShortCaseLabelsOnASingleLine: false
AllowShortIfStatementsOnASingleLine: false
AllowShortLoopsOnASingleLine: false
AlwaysBreakAfterDefinitionReturnType: None
AlwaysBreakAfterReturnType: None
AlwaysBreakBeforeMultilineStrings: false
AlwaysBreakTemplateDeclarations: true
BinPackArguments: false
BinPackParameters: false
BraceWrapping:
    AfterClass:      false
    AfterControlStatement: false
    AfterEnum:       false
    AfterFunction:   false
    AfterNamespace:  false
    AfterObjCDeclaration: false
    AfterStruct:     false
    AfterUnion:      false
    AfterExternBlock: false
    BeforeCatch:     false
    BeforeElse:      false
    IndentBraces:    false
    SplitEmptyFunction: true
    SplitEmptyRecord: true
    SplitEmptyNamespace: true
AllowShortFunctionsOnASingleLine: All
BreakBeforeBinaryOperators: None
BreakBeforeBraces: Custom
BreakBeforeInheritanceComma: true
BreakInheritanceList: BeforeColon
BreakBeforeTernaryOperators: true
BreakConstructorInitializersBeforeComma: true
ColumnLimit:     100
CommentPragmas:  '^ IWYU pragma:'
CompactNamespaces: false
ConstructorInitializerAllOnOneLineOrOnePerLine: false
ConstructorInitializerIndentWidth: 4
ContinuationIndentWidth: 4
Cpp11BracedListStyle: true
DerivePointerAlignment: false
DisableFormat:   false
ExperimentalAutoDetectBinPacking: false
FixNamespaceComments: true
ForEachMacros:
  - foreach
  - Q_FOREACH
  - BOOST_FOREACH
IncludeCategories:
  - Regex:           '^<.*\.h>'
    Priority:        1
  - Regex:           '^<.*'
    Priority:        2
  - Regex:           '.*'
    Priority:        3
IndentCaseLabels: true
IndentWidth:     4
IndentWrappedFunctionNames: false
KeepEmptyLinesAtTheStartOfBlocks: true
MacroBlockBegin: ''
MacroBlockEnd:   ''
MaxEmptyLinesToKeep: 1
PenaltyBreakAssignment: 2
PenaltyBreakBeforeFirstCallParameter: 19
PenaltyBreakComment: 300
PenaltyBreakFirstLessLess: 120
PenaltyBreakString: 1000
PenaltyExcessCharacter: 1000000
PenaltyReturnTypeOnItsOwnLine: 60
PointerAlignment: Right
ReflowComments:  true
SortIncludes:    true
SpaceAfterCStyleCast: false
SpaceAfterTemplateKeyword: true
SpaceBeforeAssignmentOperators: true
SpaceBeforeParens: ControlStatements
SpaceInEmptyParentheses: false
SpacesBeforeTrailingComments: 2
SpacesInAngles:  false
SpacesInContainerLiterals: true
SpacesInCStyleCastParentheses: false
SpacesInParentheses: false
SpacesInSquareBrackets: false
Standard:        Latest
TabWidth:        4
UseTab:          Never
)";
}

GENERATE_CXIR_TOKENS_ENUM_AND_MAPPING;

__CXIR_CODEGEN_BEGIN {
    void reset_cxir_statics();
    class CX_Token {
      private:
        u64         line{};
        u64         column{};
        u64         length{};
        cxir_tokens type{};
        std::string file_name;
        std::string value;

      public:
        CX_Token() = default;
        CX_Token(const token::Token &tok, cxir_tokens set_type)
            : line(tok.line_number())
            , column(tok.column_number())
            , length(tok.length())
            , type(set_type)
            , file_name(std::filesystem::path(tok.file_name()).generic_string())
            , value(std::string(tok.value())) {}

        explicit CX_Token(cxir_tokens type)
            : length(1)
            , type(type)
            , file_name("_H1HJA9ZLO_17.kairo-compiler.cxir")
            , value(cxir_tokens_map.at(type).has_value()
                        ? std::string(cxir_tokens_map.at(type).value())
                        : " /* Unknown Token */ ") {}

        CX_Token(cxir_tokens type, std::string value)
            : length(value.length())
            , type(type)
            , file_name("_H1HJA9ZLO_17.kairo-compiler.cxir")
            , value(std::move(value)) {}

        CX_Token(cxir_tokens type, const token::Token &loc)
            : line(loc.line_number())
            , column(loc.column_number())
            , length(loc.length())
            , type(type)
            , file_name(std::filesystem::path(loc.file_name()).generic_string())
            , value(cxir_tokens_map.at(type).has_value()
                        ? std::string(cxir_tokens_map.at(type).value())
                        : " /* Unknown Token */ ") {}

        CX_Token(cxir_tokens type, std::string value, const token::Token &loc)
            : line(loc.line_number())
            , column(loc.column_number())
            , length(loc.length())
            , type(type)
            , file_name(std::filesystem::path(loc.file_name()).generic_string())
            , value(std::move(value)) {}

        CX_Token(const CX_Token &)            = default;
        CX_Token(CX_Token &&)                 = delete;
        CX_Token &operator=(const CX_Token &) = default;
        CX_Token &operator=(CX_Token &&)      = delete;
        ~CX_Token()                           = default;

        [[nodiscard]] u64         get_line() const { return line; }
        [[nodiscard]] u64         get_column() const { return column; }
        [[nodiscard]] u64         get_length() const { return length; }
        [[nodiscard]] cxir_tokens get_type() const { return type; }
        [[nodiscard]] std::string get_file_name() const { return file_name; }
        [[nodiscard]] std::string get_value() const { return value; }
        [[nodiscard]] std::string to_CXIR() const {
            if (value[0] == '#') {
                return "\n" + value + " ";
            }

            return value + " ";
        }

        [[nodiscard]] std::string to_clean_CXIR() const {
            if (value[0] == '#') {
                return value + " ";
            }
            return value + "\n";
        }
    };

    struct SourceLocation {
        using Location = std::pair<size_t, size_t>;

        Location kairo;
        Location cxir;

        string to_dict() const {
            // source map of kairo pos to cxir pos
            return "(" + std::to_string(kairo.first) + "," + std::to_string(kairo.second) + "):(" +
                   std::to_string(cxir.first) + "," + std::to_string(cxir.second) + "),";
        }
    };

    struct SourceMap {
        inline static size_t cxx_line_num{1};
        inline static size_t cxx_column_num{1};

        std::vector<SourceLocation>                     locs;
        std::map<std::string, std::vector<std::string>> full_dict;
        std::string                                     file_name;

        // flat sorted cache for reverse lookup
        struct FlatEntry {
            std::string file;
            size_t      kairo_line;
            size_t      kairo_col;
            size_t      cxir_line;
            size_t      cxir_col;
        };

        mutable std::vector<FlatEntry> _flat;
        mutable bool                   _flat_built = false;

        SourceMap() = default;

        // --- forward map building (unchanged from your original) ---

        void finalize() {
            if (file_name.empty() || locs.empty())
                return;

            auto &vec = full_dict[file_name];  // insert empty vec if not present, or get existing
            for (const auto &loc : locs) {
                vec.emplace_back(loc.to_dict());
            }

            locs.clear();
            _flat_built = false;
        }

        static void inc_line_num(size_t inc = 1) {
            cxx_line_num += inc;
            cxx_column_num = 1;
        }

        [[nodiscard]] static size_t get_line_num() { return cxx_line_num; }
        [[nodiscard]] static size_t get_column_num() { return cxx_column_num; }
        [[nodiscard]] static void   inc_column_num(size_t inc = 1) { cxx_column_num += inc; }

        [[nodiscard]] static void reset_line_num() {
            cxx_line_num   = 1;
            cxx_column_num = 1;
        }

        void reset() {
            locs.clear();
            full_dict.clear();
            file_name.clear();
            _flat.clear();
            _flat_built = false;
            reset_line_num();
            reset_cxir_statics();
        }

        [[nodiscard]] static std::string get_file_name(const CX_Token &token) {
            return token.get_file_name();
        }

        void set_file_name(const std::string &new_file_name) {
            if (this->file_name == new_file_name)
                return;
            if (!this->file_name.empty())
                finalize();
            this->file_name = new_file_name;
        }

        void add_loc(const SourceLocation &loc) {
            locs.emplace_back(loc);
            _flat_built = false;
        }

        // --- flat cache ---

        void build_flat() const {
            _flat.clear();

            for (auto &[file, loc_strs] : full_dict) {
                for (auto &loc_str : loc_strs) {
                    size_t kl = 0, kc = 0, cl = 0, cc = 0;
                    sscanf(loc_str.c_str(), "(%zu,%zu):(%zu,%zu)", &kl, &kc, &cl, &cc);
                    if (kl == 0 || cl == 0)
                        continue;  // skip invalid
                    _flat.push_back({file, kl, kc, cl, cc});
                }
            }

            // sort by (cxir_line, cxir_col) for forward lookup
            std::sort(_flat.begin(), _flat.end(), [](const FlatEntry &a, const FlatEntry &b) {
                if (a.cxir_line != b.cxir_line)
                    return a.cxir_line < b.cxir_line;
                return a.cxir_col < b.cxir_col;
            });

            _flat_built = true;
        }

        // --- reverse lookup: cxir (line, col) → kairo loc ---

        // returns nearest kairo loc at or before the given cxir position
        std::optional<FlatEntry> lookup_cxir(size_t cxir_line, size_t cxir_col) const {
            if (!_flat_built)
                build_flat();
            if (_flat.empty())
                return std::nullopt;

            const FlatEntry *best = nullptr;
            for (auto &e : _flat) {
                if (e.cxir_line > cxir_line)
                    break;
                if (e.cxir_line == cxir_line && e.cxir_col > cxir_col)
                    break;
                best = &e;
            }

            return best ? std::optional(*best) : std::nullopt;
        }

        // col-adjusted version: applies the off-by-one fix for emitter trailing spaces
        std::optional<FlatEntry> lookup_cxir_adjusted(size_t cxir_line, size_t cxir_col) const {
            auto result = lookup_cxir(cxir_line, cxir_col);
            if (!result)
                return std::nullopt;

            // fix trailing space offset: emitter adds space after every token
            // so cxir col is 1-indexed with spaces, kairo col is 1-indexed without
            if (result->kairo_col > 1 && result->cxir_col > 1) {
                result->kairo_col -= 1;
            }

            return result;
        }

        // std::optional<FlatEntry> lookup_cxir_adjusted(size_t cxir_line, size_t cxir_col) const {
        //     auto result = lookup_cxir(cxir_line, cxir_col);
        //     if (!result) return std::nullopt;
        //     if (result->kairo_col > 1 && result->cxir_col > 1)
        //         result->kairo_col -= 1;
        //     return result;
        // }

        // --- forward lookup: kairo (file, line) → cxir line ---

        std::optional<size_t> lookup_kairo_line(const std::string &file, size_t kairo_line) const {
            if (!_flat_built)
                build_flat();
            // _flat is sorted by cxir, need linear scan for kairo lookup
            for (auto &e : _flat) {
                if (e.file == file && e.kairo_line == kairo_line)
                    return e.cxir_line;
            }
            return std::nullopt;
        }

        // exact kairo (file, line, col) → cxir (line, col)
        std::optional<std::pair<size_t, size_t>>
        lookup_kairo(const std::string &file, size_t kairo_line, size_t kairo_col) const {
            if (!_flat_built)
                build_flat();
            const FlatEntry *best = nullptr;
            for (auto &e : _flat) {
                if (e.file != file)
                    continue;
                if (e.kairo_line > kairo_line)
                    continue;
                if (e.kairo_line == kairo_line && e.kairo_col > kairo_col)
                    continue;
                if (!best || e.kairo_line > best->kairo_line ||
                    (e.kairo_line == best->kairo_line && e.kairo_col > best->kairo_col))
                    best = &e;
            }

            if (!best)
                return std::nullopt;
            return {{best->cxir_line, best->cxir_col}};
        }

        // --- debug output ---

        [[nodiscard]] string to_dict() const {
            std::string dict = "{";
            for (const auto &[key, value] : full_dict) {
                dict += "\"" + key + "\": {";
                for (const auto &loc : value) {
                    dict += loc;
                }
                dict += "},";
            }
            dict += "}";
            return dict;
        }
    };

    class CXIRBuilder {
        string file_name;
        string cxir;

      public:
        inline static size_t cxir_line{1};
        inline static size_t cxir_col{1};
        SourceMap           *source_map{nullptr};

        size_t kairo_line{1};
        size_t kairo_col{1};

        // we need a few functions to help us also build the source map
        void add_to_source_map(const CX_Token *token = nullptr);

      public:
        explicit CXIRBuilder(const size_t len, SourceMap *source_map = nullptr);

        CXIRBuilder &add_line();

        CXIRBuilder &add_line(const string &str);

        CXIRBuilder &add_line(const CX_Token &token);

        CXIRBuilder &add_line(const std::unique_ptr<CX_Token> &token);

        // ONLY add change the kairo mapping
        CXIRBuilder &add(const string &str);

        CXIRBuilder &add(const CX_Token &token);

        CXIRBuilder &add(const std::unique_ptr<CX_Token> &token);

        CXIRBuilder &add_line_marker(const size_t  line_num,
                                     const string &file_macro = "",
                                     const string &file_name  = "");

        CXIRBuilder &add_macro(const string &str);

        CXIRBuilder &operator+=(const string &str);
        CXIRBuilder &operator+=(const CX_Token &token);
        CXIRBuilder &operator+=(const std::unique_ptr<CX_Token> &token);

        CXIRBuilder &operator<<(const string &str);
        CXIRBuilder &operator<<(const CX_Token &token);
        CXIRBuilder &operator<<(const std::unique_ptr<CX_Token> &token);

        [[nodiscard]] string build() const;
        [[nodiscard]] string get_file_name() const;
    };

    class CXIR : public __AST_VISITOR::Visitor {
      private:
        std::vector<std::unique_ptr<CX_Token>>              tokens;
        std::vector<std::shared_ptr<generator::CXIR::CXIR>> imports;
        std::filesystem::path                               core_dir;
        bool                                                forward_only = false;

      public:
        inline static SourceMap source_map;

        explicit CXIR(bool                                                forward_only = false,
                      std::vector<std::shared_ptr<generator::CXIR::CXIR>> imports      = {})
            : imports(std::move(imports))
            , forward_only(forward_only) {}

        CXIR(const CXIR &)            = delete;
        CXIR(CXIR &&)                 = default;
        CXIR &operator=(const CXIR &) = delete;
        CXIR &operator=(CXIR &&)      = delete;
        ~CXIR() override              = default;

        void set_core_dir(const std::filesystem::path &dir) { core_dir = dir; }

        [[nodiscard]] std::optional<std::string> get_file_name() const {
            if (tokens.empty()) {
                return std::nullopt;
            }

            for (const auto &token : tokens) {
                if (token->get_line() != 0) {
                    return token->get_file_name();
                }
            }

            return std::nullopt;
        }

        void append(std::unique_ptr<CX_Token> token) { tokens.push_back(std::move(token)); }
        void append(cxir_tokens type) { tokens.push_back(std::make_unique<CX_Token>(type)); }

        std::string generate_CXIR() const;

        template <const bool add_core = true>
        std::string to_CXIR(std::unordered_set<std::string> *seen = nullptr) const {
            std::string cxir;

            if constexpr (add_core) {
                string core       = get_core();
                size_t core_lines = std::count(core.begin(), core.end(), '\n') + 1;
                string imports    = get_imports<false>(seen, core_lines + 1);
                cxir += core + "\n" + imports + "\n";
            } else {
                string imports = get_imports<false>(seen, 0);
                cxir += imports + "\n";
            }

            size_t line_offset     = std::count(cxir.begin(), cxir.end(), '\n');
            CXIRBuilder::cxir_line = line_offset + 1;

            cxir += generate_CXIR();

            if (cxir.empty()) {
                print("CXIR is empty after processing tokens.");
                return cxir;
            }

            return cxir;
        }

        [[nodiscard]] std::string
        to_readable_CXIR(std::unordered_set<std::string> *seen = nullptr) const {
            std::string cxir = get_imports<true>(seen) + "\n";
            std::string file_name;

            // Build the CXIR string from tokens
            for (const auto &token : tokens) {
                if (token->get_line() != 0 && token->get_file_name() != file_name) {
                    file_name = token->get_file_name();
                    string fn = "// File: \'" + file_name + "\' //\n";
                    cxir += "\n\n"
                            "//" +
                            string(fn.length() - 1, '=') + "//\n" + fn + "//" +
                            string(fn.length() - 1, '=') + "//\n\n";
                }

                cxir += token->to_clean_CXIR();
            }

            // If cxir is empty, log and return early
            if (cxir.empty()) {
                print("CXIR is empty after processing tokens.");
                return cxir;
            }

            // Format the CXIR code
            return format_cxir(cxir);
        }

        [[nodiscard]] static std::string format_cxir(const std::string &cxir) { return cxir; }

        static std::string get_core();

        template <const bool readable>
        std::string get_imports(std::unordered_set<std::string> *seen             = nullptr,
                                size_t                           base_line_offset = 0) const {
            std::string                     cxir;
            std::unordered_set<std::string> local_seen;
            if (seen == nullptr)
                seen = &local_seen;

            for (const auto &import : this->imports) {
                auto fname = import->get_file_name();
                if (fname.has_value() && !seen->insert(fname.value()).second)
                    continue;

                size_t before = base_line_offset + std::count(cxir.begin(), cxir.end(), '\n');

                std::unordered_set<std::string> import_files_before;
                for (auto &[f, _] : source_map.full_dict)
                    import_files_before.insert(f);

                if constexpr (readable) {
                    cxir += import->to_readable_CXIR(seen);
                } else {
                    cxir += import->template to_CXIR<false>(seen);
                }

                for (auto &[file, entries] : source_map.full_dict) {
                    if (import_files_before.count(file))
                        continue;
                    if (file == get_file_name().value_or(""))
                        continue;

                    size_t sub_base = SIZE_MAX;
                    for (auto &entry : entries) {
                        size_t kl, kc, cl, cc;
                        sscanf(entry.c_str(), "(%zu,%zu):(%zu,%zu)", &kl, &kc, &cl, &cc);
                        sub_base = std::min(sub_base, cl);
                    }
                    if (sub_base == SIZE_MAX)
                        continue;

                    for (auto &entry : entries) {
                        size_t kl, kc, cl, cc;
                        sscanf(entry.c_str(), "(%zu,%zu):(%zu,%zu)", &kl, &kc, &cl, &cc);
                        cl    = (cl - sub_base) + before;
                        entry = "(" + std::to_string(kl) + "," + std::to_string(kc) + "):(" +
                                std::to_string(cl) + "," + std::to_string(cc) + "),";
                    }
                }
            }

            return cxir;
        }

        void visit(parser::ast::node::LiteralExpr &node) override;
        void visit(parser::ast::node::BinaryExpr &node) override;
        void visit(parser::ast::node::UnaryExpr &node) override;
        void visit(parser::ast::node::IdentExpr &node) override;
        void visit(parser::ast::node::NamedArgumentExpr &node) override;
        void visit(parser::ast::node::ArgumentExpr &node) override;
        void visit(parser::ast::node::ArgumentListExpr &node) override;
        void visit(parser::ast::node::GenericInvokeExpr &node) override;
        void visit(parser::ast::node::ScopePathExpr &node) override { visit(node, true); }
        void visit(parser::ast::node::ScopePathExpr &node, bool access);
        void visit(parser::ast::node::DotPathExpr &node) override;
        void visit(parser::ast::node::ArrayAccessExpr &node) override;
        void visit(parser::ast::node::PathExpr &node) override;
        void visit(parser::ast::node::FunctionCallExpr &node) override;
        void visit(parser::ast::node::ArrayLiteralExpr &node) override;
        void visit(parser::ast::node::TupleLiteralExpr &node) override;
        void visit(parser::ast::node::SetLiteralExpr &node) override;
        void visit(parser::ast::node::MapPairExpr &node) override;
        void visit(parser::ast::node::MapLiteralExpr &node) override;
        void visit(parser::ast::node::ObjInitExpr &node) override;
        void visit(parser::ast::node::LambdaExpr &node) override;
        void visit(parser::ast::node::TernaryExpr &node) override;
        void visit(parser::ast::node::ParenthesizedExpr &node) override;
        void visit(parser::ast::node::CastExpr &node) override;
        void visit(parser::ast::node::InstOfExpr &node) override;
        void visit(parser::ast::node::AsyncThreading &node) override;
        void visit(parser::ast::node::Type &node) override;
        void visit(parser::ast::node::NamedVarSpecifier &node, bool omit_t);
        void visit(parser::ast::node::NamedVarSpecifier &node) override { visit(node, false); }
        void visit(parser::ast::node::NamedVarSpecifierList &node, bool omit_t);
        void visit(parser::ast::node::NamedVarSpecifierList &node) override { visit(node, false); }
        void visit(parser::ast::node::ForPyStatementCore &node) override;
        void visit(parser::ast::node::ForCStatementCore &node) override;
        void visit(parser::ast::node::ForState &node) override;
        void visit(parser::ast::node::WhileState &node) override;
        void visit(parser::ast::node::ElseState &node) override;
        void visit(parser::ast::node::IfState &node) override;
        void visit(parser::ast::node::SwitchCaseState &node) override;
        void visit(parser::ast::node::SwitchState &node) override;
        void visit(parser::ast::node::YieldState &node) override;
        void visit(parser::ast::node::DeleteState &node) override;

        void visit(parser::ast::node::ImportState &node) override;
        void visit(parser::ast::node::ImportItems &node) override;
        void visit(parser::ast::node::SingleImport &node) override;
        void visit(parser::ast::node::SpecImport &node) override;
        void visit(parser::ast::node::MultiImportState &node) override;

        void visit(parser::ast::node::ReturnState &node) override;
        void visit(parser::ast::node::BreakState &node) override;
        void visit(parser::ast::node::BlockState &node) override;
        void visit(parser::ast::node::SuiteState &node) override;
        void visit(parser::ast::node::ContinueState &node) override;
        void visit(parser::ast::node::CatchState &node) override;
        void visit(parser::ast::node::FinallyState &node) override;
        void visit(parser::ast::node::TryState &node) override;
        void visit(parser::ast::node::PanicState &node) override;
        void visit(parser::ast::node::ExprState &node) override;
        void visit(parser::ast::node::RequiresParamDecl &node) override;
        void visit(parser::ast::node::RequiresParamList &node) override;
        void visit(parser::ast::node::EnumMemberDecl &node) override;
        void visit(parser::ast::node::UDTDeriveDecl &node) override;
        void visit(parser::ast::node::TypeBoundList &node) override;
        void visit(parser::ast::node::TypeBoundDecl &node) override;
        void visit(parser::ast::node::RequiresDecl &node) override;
        void visit(parser::ast::node::ModuleDecl &node) override;
        void visit(parser::ast::node::StructDecl &node) override;
        void visit(parser::ast::node::ConstDecl &node) override;
        void visit(parser::ast::node::ClassDecl &node) override;
        void visit(parser::ast::node::ExtendDecl &node) override;
        void visit(parser::ast::node::InterDecl &node) override;
        void visit(parser::ast::node::EnumDecl &node) override;
        void visit(parser::ast::node::TypeDecl &node) override;
        void visit(parser::ast::node::FuncDecl &node, bool no_return_t);
        void visit(parser::ast::node::FuncDecl &node, bool in_udt, bool is_op);
        void visit(parser::ast::node::VarDecl &node) override;
        void visit(parser::ast::node::FFIDecl &node) override;

        void visit(parser::ast::node::LetDecl &node) override { visit(node, false); };
        void visit(parser::ast::node::LetDecl &node, bool is_in_statement);

        void visit(parser::ast::node::Program &node) override;
        void visit(parser::ast::node::FuncDecl &node) override {
            if (node.is_op) {
                visit(node, false, true);
            } else {
                visit(node, false);
            }
        };
    };

    // inline CXIR get_node_json(const __AST_VISITOR::NodeT<> &node) {
    //     auto visitor = CXIR();

    //     if (node == nullptr) {

    //     }

    //     node->accept(visitor);
    //     return visitor.json;
    // }
}
#endif  // __CXIR_H__