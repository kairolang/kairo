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
    class LSPPositionMapper {
    public:
        struct Position {
            size_t line;
            size_t col;
            
            bool operator<(const Position& other) const {
                if (line != other.line) return line < other.line;
                return col < other.col;
            }
        };
        
    private:
        // file -> (helix_pos -> cpp_pos)
        std::map<std::string, std::map<Position, Position>> helix_to_cpp;
        
        // file -> (cpp_pos -> helix_pos)
        std::map<std::string, std::map<Position, Position>> cpp_to_helix;
        
    public:
        LSPPositionMapper() = default;
        
        void add_mapping(const std::string& helix_file,
                        size_t helix_line, size_t helix_col,
                        size_t cpp_line, size_t cpp_col) {
            Position h_pos{helix_line, helix_col};
            Position c_pos{cpp_line, cpp_col};
            
            helix_to_cpp[helix_file][h_pos] = c_pos;
            cpp_to_helix[helix_file][c_pos] = h_pos;  // Assume 1:1 file mapping
        }
        
        std::optional<Position> map_helix_to_cpp(const std::string& helix_file,
                                                size_t line, size_t col) const {
            auto file_it = helix_to_cpp.find(helix_file);
            if (file_it == helix_to_cpp.end()) return std::nullopt;
            
            Position query{line, col};
            const auto& mappings = file_it->second;
            
            // Exact match
            auto exact = mappings.find(query);
            if (exact != mappings.end()) {
                return exact->second;
            }
            
            // Find closest mapping before or at this position
            auto it = mappings.upper_bound(query);
            if (it == mappings.begin()) return std::nullopt;
            
            --it;  // Go to largest mapping <= query
            
            // Apply offset
            size_t line_offset = line - it->first.line;
            size_t col_offset = (line == it->first.line) ? (col - it->first.col) : col;
            
            return Position{it->second.line + line_offset, it->second.col + col_offset};
        }
        
        std::optional<Position> map_cpp_to_helix(const std::string& helix_file,
                                                size_t line, size_t col) const {
            auto file_it = cpp_to_helix.find(helix_file);
            if (file_it == cpp_to_helix.end()) return std::nullopt;
            
            Position query{line, col};
            const auto& mappings = file_it->second;
            
            auto exact = mappings.find(query);
            if (exact != mappings.end()) {
                return exact->second;
            }
            
            auto it = mappings.upper_bound(query);
            if (it == mappings.begin()) return std::nullopt;
            
            --it;
            
            size_t line_offset = line - it->first.line;
            size_t col_offset = (line == it->first.line) ? (col - it->first.col) : col;
            
            return Position{it->second.line + line_offset, it->second.col + col_offset};
        }
        
        std::string dump() const {
            std::string result = "LSP Position Mappings:\n";
            
            for (const auto& [file, mappings] : helix_to_cpp) {
                result += "File: " + file + "\n";
                result += "  Helix -> C++:\n";
                
                for (const auto& [h_pos, c_pos] : mappings) {
                    result += "    (" + std::to_string(h_pos.line) + "," + std::to_string(h_pos.col) + 
                            ") -> (" + std::to_string(c_pos.line) + "," + std::to_string(c_pos.col) + ")\n";
                }
            }
            
            return result;
        }
        
        void clear() {
            helix_to_cpp.clear();
            cpp_to_helix.clear();
        }
    };

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

    class CXIR : public __AST_VISITOR::Visitor {
      private:
        std::vector<std::unique_ptr<CX_Token>> tokens;
        std::vector<generator::CXIR::CXIR>     imports;
        std::filesystem::path                  core_dir;
        bool                                   forward_only = false;

      public:
        inline static LSPPositionMapper lsp_position_mapper;

        explicit CXIR(bool forward_only = false, std::vector<generator::CXIR::CXIR> imports = {})
            : imports(std::move(imports))
            , forward_only(forward_only) {}

        CXIR(const CXIR &) = delete;              // Disable copy constructor
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

        static std::string get_file_name(const std::unique_ptr<CX_Token> &token)  {
            if (!token) {
                return "";
            }
            
            return token->get_file_name();
        }

        void append(std::unique_ptr<CX_Token> token) { tokens.push_back(std::move(token)); }
        void append(cxir_tokens type) { tokens.push_back(std::make_unique<CX_Token>(type)); }

        [[nodiscard]] std::string generate_CXIR() const;

        template <const bool add_core = true>
        [[nodiscard]] std::string to_CXIR() const {
            std::string cxir;

            if constexpr (add_core) {
                cxir += get_core() + "\n" + get_imports<false>() + "\n";
            } else {
                cxir += get_imports<false>() + "\n";
            }

            cxir += generate_CXIR();

            if (cxir.empty()) {
                print("CXIR is empty after processing tokens.");
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