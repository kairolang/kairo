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
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
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

    struct SourceMap { /* this all a part of the same c++ output object
        so a couple of things only the kairo file and locs change
        while the c++ source locs keep constant this should be a primary static strcut */
        inline static size_t cxx_line_num{1};
        inline static size_t cxx_column_num{1};

        std::vector<SourceLocation> locs;

        /* {filename : [locs...]}*/
        std::map<std::string, std::vector<std::string>> full_dict;
        std::string                                     file_name;

        SourceMap() = default;

        void finalize() {
            // finalize everything into the flatend dict
            /* exmaple:

            "kairo_file_name" : [
                (kairo_line, kairo_col): (cxir_line, cxir_col),
                (kairo_line, kairo_col): (cxir_line, cxir_col),
            ],

            */

            // add the file name to the dict
            auto [key, inserted] =
                full_dict.insert_or_assign(file_name, std::vector<std::string>{});

            auto &vec = key->second;

            // add the locs to the vector
            for (const auto &loc : locs) {
                vec.emplace_back(loc.to_dict());
            }

            // clear the locs
            locs.clear();
        }

        static void inc_line_num(size_t inc = 1) {
            // increment the line number
            cxx_line_num += inc;
            cxx_column_num = 1;
        }

        [[nodiscard]] static size_t get_line_num() { return cxx_line_num; }

        [[nodiscard]] static size_t get_column_num() { return cxx_column_num; }

        [[nodiscard]] static void inc_column_num(size_t inc = 1) { cxx_column_num += inc; }

        [[nodiscard]] static void reset_line_num() {
            cxx_line_num   = 1;
            cxx_column_num = 1;
        }

        [[nodiscard]] static std::string get_file_name(const CX_Token &token) {
            return token.get_file_name();
        }

        void set_file_name(const std::string &file_name) {
            // if both file names are the same return
            if (this->file_name == file_name) {
                return;
            }

            // everytime we set the file name we need to clear the locs and finalize the previous
            // locs
            if (!this->file_name.empty()) {
                finalize();
            }

            this->file_name = file_name;
        }

        void add_loc(const SourceLocation &loc) { locs.emplace_back(loc); }

        [[nodiscard]] string to_dict() const {
            // convert the locs to a string
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

    class CXIR : public __AST_VISITOR::Visitor {
      private:
        std::vector<std::unique_ptr<CX_Token>> tokens;
        std::vector<generator::CXIR::CXIR>     imports;
        std::filesystem::path                  core_dir;
        bool                                   forward_only = false;

      public:
        inline static SourceMap source_map;

        explicit CXIR(bool forward_only = false, std::vector<generator::CXIR::CXIR> imports = {})
            : imports(std::move(imports))
            , forward_only(forward_only) {}

        CXIR(const CXIR &)            = default;
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
        [[nodiscard]] std::string to_CXIR() const {
            std::string cxir;
            size_t      line_count = 0;

            if constexpr (add_core) {
                string core = get_core();
                line_count  = std::count(core.begin(), core.end(), '\n');
                cxir += core + "\n" + get_imports<false>() + "\n";
            } else {
                cxir += get_imports<false>() + "\n";
            }

            // count number of lines in the CXIR

            generator::CXIR::SourceMap::inc_line_num(line_count);
            cxir += generate_CXIR();

            if (cxir.empty()) {
                print("CXIR is empty after processing tokens.");
                return cxir;
            }

            return cxir;
        }

        [[nodiscard]] std::string to_readable_CXIR() const {
            std::string cxir = get_imports<true>() + "\n";
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

        [[nodiscard]] static std::string format_cxir(const std::string &cxir) {
            return cxir;
        }

        static std::string get_core();

        template <const bool readable>
        std::string get_imports() const {
            std::string cxir;

            for (const auto &import : this->imports) {
                if constexpr (readable) {
                    cxir += import.to_readable_CXIR();
                } else {
                    cxir += import.to_CXIR<false>();
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
        void visit(parser::ast::node::NamedVarSpecifier &node) override {
            visit(node, false);
        }
        void visit(parser::ast::node::NamedVarSpecifierList &node, bool omit_t);
        void visit(parser::ast::node::NamedVarSpecifierList &node) override {
            visit(node, false);
        }
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