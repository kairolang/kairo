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

#include "generator/include/CX-IR/CXIR.hh"
#include "neo-panic/include/error.hh"
#include "neo-types/include/hxint.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"
#include "utils.hh"

static size_t f_index = 0;

__CXIR_CODEGEN_BEGIN {

    class CXIRBuilder {
    private:
        std::string output;
        LSPPositionMapper *lsp_mapper{nullptr};
        
        // Current C++ position (tracked as we write)
        size_t cpp_line{1};
        size_t cpp_col{1};
        
        // Current Helix position (updated from tokens)
        std::string helix_file;
        size_t helix_line{0};
        size_t helix_col{0};
        
        // Emit raw text and update C++ position
        void emit_raw(const std::string& text) {
            for (char c : text) {
                output += c;
                if (c == '\n') {
                    ++cpp_line;
                    cpp_col = 1;
                } else {
                    ++cpp_col;
                }
            }
        }
        
        // Record a position mapping
        void record_position() {
            if (!lsp_mapper || helix_line == 0 || helix_col == 0 || helix_file.empty()) {
                return;
            }
            
            // Skip internal files
            if (helix_file == "_H1HJA9ZLO_17.kairo-compiler.cxir" ||
                helix_file == "kairo_internal.file") {
                return;
            }
            
            lsp_mapper->add_mapping(helix_file, helix_line, helix_col, cpp_line, cpp_col);
        }
        
    public:
        explicit CXIRBuilder(size_t reserve_size, LSPPositionMapper *mapper = nullptr,
                           size_t start_line = 1)
            : lsp_mapper(mapper), cpp_line(start_line) {
            output.reserve(reserve_size);
        }
        
        // Emit a token with position tracking
        void emit_token(const CX_Token& token) {
            // Update Helix position from token
            if (token.get_line() > 0 && token.get_column() > 0) {
                helix_line = token.get_line();
                helix_col = token.get_column();
                
                std::string fname = token.get_file_name();
                if (!fname.empty() && 
                    fname != "_H1HJA9ZLO_17.kairo-compiler.cxir" &&
                    fname != "kairo_internal.file") {
                    helix_file = fname;
                }
            }
            
            // Record position mapping BEFORE emitting
            record_position();
            
            // Emit the token
            emit_raw(token.to_CXIR());
        }
        
        // Emit plain text (for macros, directives, etc.)
        void emit_text(const std::string& text) {
            emit_raw(text);
        }
        
        // Emit newline
        void emit_newline() {
            emit_raw("\n");
        }
        
        // Emit #line directive and update tracking
        void emit_line_directive(size_t line_num, const std::string& file_macro = "",
                                const std::string& file_name = "") {
            emit_newline();
            
            std::string directive = "#line " + std::to_string(line_num);
            if (!file_macro.empty()) {
                directive += " " + file_macro;
            }
            
            emit_raw(directive + "\n");
            
            // Update our Helix tracking
            helix_line = line_num;
            helix_col = 1;
            
            if (!file_name.empty()) {
                helix_file = file_name;
            }
        }
        
        // Get current C++ position
        size_t get_cpp_line() const { return cpp_line; }
        size_t get_cpp_col() const { return cpp_col; }
        
        // Build final output
        std::string build() const {
            return output;
        }
    };

    std::string normalize_file_name(std::string file_name) {
        if (file_name.empty()) {
            return "";
        }

        if (file_name == "_H1HJA9ZLO_17.kairo-compiler.cxir" ||
            file_name == "kairo_internal.file") {
            return "";
        }

        return file_name;
    }

    std::string get_file_name(const std::unique_ptr<CX_Token> &tok) {
        if ((tok != nullptr) && (tok->get_line() != 0) &&
            (!normalize_file_name(tok->get_file_name()).empty())) {
            return tok->get_file_name();
        }
        return "";
    }

    bool is_2_token_pp_directive(const std::unique_ptr<CX_Token> &token) {
        return (token->get_value() == "#include" ||
                token->get_type() == cxir_tokens::CXX_PP_INCLUDE) ||
               (token->get_value() == "#define" ||
                token->get_type() == cxir_tokens::CXX_PP_DEFINE) ||
               (token->get_value() == "#ifdef" || token->get_type() == cxir_tokens::CXX_PP_IFDEF) ||
               (token->get_value() == "#ifndef" ||
                token->get_type() == cxir_tokens::CXX_PP_IFNDEF) ||
               (token->get_value() == "#pragma" ||
                token->get_type() == cxir_tokens::CXX_PP_PRAGMA) ||
               (token->get_value() == "#undef" || token->get_type() == cxir_tokens::CXX_PP_UNDEF) ||
               (token->get_value() == "#error" || token->get_type() == cxir_tokens::CXX_PP_ERROR) ||
               (token->get_value() == "#warning" ||
                token->get_type() == cxir_tokens::CXX_PP_WARNING) ||
               (token->get_value() == "#line" || token->get_type() == cxir_tokens::CXX_PP_LINE);
    }

    bool is_1_token_pp_directive(const std::unique_ptr<CX_Token> &token) {
        return (token->get_value() == "#endif" || token->get_type() == cxir_tokens::CXX_PP_ENDIF) ||
               (token->get_value() == "#else" || token->get_type() == cxir_tokens::CXX_PP_ELSE);
    }

    std::string CXIR::generate_CXIR() const {
        size_t line_num = 1;
        std::string file_name;
        std::map<std::string, std::string> file_macros;
        
        size_t starting_line = 30;
        for (const auto& import : imports) {
            std::string import_cxir = import.to_CXIR<false>();
            starting_line += std::count(import_cxir.begin(), import_cxir.end(), '\n');
        }
        
        size_t estimated_size = 0;
        for (const auto& token : tokens) {
            estimated_size += token->get_value().size() + 1;
        }
        
        CXIRBuilder builder(estimated_size, &lsp_position_mapper, starting_line);

        // Build file macros
        for (const auto &token : tokens) {
            file_name = get_file_name(token);
            if (file_name.empty() || file_macros.find(file_name) != file_macros.end()) {
                continue;
            }
            file_macros[file_name] = "__$FILE_" + std::to_string(f_index) + "__";
            ++f_index;
        }

        // Emit file macro definitions
        for (const auto &[fname, macro] : file_macros) {
            builder.emit_text("\n#define " + macro + " \"" + fname + "\"\n");
        }

        if (file_macros.empty()) [[unlikely]] {
            return "#error \"Lost the original file name\"";
        }

        // Emit first #line directive
        builder.emit_line_directive(1, file_macros.begin()->second, file_macros.begin()->first);

        // Process tokens
        for (size_t i = 0; i < tokens.size(); ++i) {
            const auto &token = tokens[i];
            const auto &_file_name = get_file_name(token);
            const auto &_line_num = token->get_line();

            if (!token || token->get_value().empty()) {
                continue;
            }

            // macro processing
            if (is_1_token_pp_directive(token)) {
                builder.emit_text("\n" + token->get_value() + "\n");
                continue;
            }

            // macro processing
            if (is_2_token_pp_directive(token)) {
                if ((i + 1) < tokens.size()) {
                    builder.emit_text("\n" + token->get_value() + " " + tokens[i + 1]->get_value() + "\n");
                } else {
                    continue;
                }
                ++i;
                continue;
            }

            // macro processing
            if ((token->get_value() == "#if" || token->get_type() == cxir_tokens::CXX_PP_IF) ||
                (token->get_value() == "#elif" || token->get_type() == cxir_tokens::CXX_PP_ELIF)) {
                ++line_num;
                ++i;

                size_t nesting = 0;
                size_t j       = i;
                
                builder.emit_line_directive(line_num);
                builder.emit_newline();
                builder.emit_token(*token);

                for (; j < tokens.size(); ++j) {
                    if (tokens[j]->get_type() == cxir_tokens::CXX_LPAREN) {
                        ++nesting;
                    } else if (tokens[j]->get_type() == cxir_tokens::CXX_RPAREN) {
                        --nesting;
                    }

                    if (nesting == 0) {
                        i = j;
                        builder.emit_token(*tokens[j]);
                        break;
                    }

                    builder.emit_token(*tokens[j]);
                }

                builder.emit_newline();
                builder.emit_line_directive(line_num);

                continue;
            }
            
            bool has_position = (_line_num != 0 && !_file_name.empty());

            if (has_position) {
                // File changed
                if (_file_name != file_name) { 
                    file_name = _file_name;
                    builder.emit_newline();
                    builder.emit_line_directive(_line_num, file_macros[file_name], file_name);
                    line_num = _line_num;
                } 
                // Line changed (same file)
                else if (_line_num != line_num) {
                    line_num = _line_num;
                    builder.emit_newline();
                    builder.emit_line_directive(line_num);
                }
            }
            // If token has no position info (line=0), just emit it without #line

            builder.emit_token(*token);
        }
        
        return builder.build();
    }

}  // namespace __CXIR_CODEGEN_END

/*
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

#include "generator/include/CX-IR/loc.hh"
#include "generator/include/CX-IR/CXIR.hh"
#include "neo-panic/include/error.hh"
#include "neo-types/include/hxint.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"
#include "utils.hh"

static size_t f_index = 0;

__CXIR_CODEGEN_BEGIN {

    class CXIRBuilder {
        string file_name;
        size_t cxir_line{1};
        size_t cxir_col{1};
        string cxir;
        SourceMap *source_map{nullptr};
        LSPPositionMapper *lsp_mapper{nullptr};

        size_t kairo_line{1};
        size_t kairo_col{1};

        // Track every character we output to C++
        void track_output(const string& text) {
            for (char c : text) {
                if (c == '\n') {
                    ++cxir_line;
                    cxir_col = 1;
                } else {
                    ++cxir_col;
                }
            }
        }

        // Record a mapping point
        void record_mapping() {
            if (this->lsp_mapper == nullptr) {
                return;
            }

            if (kairo_line == 0 || kairo_col == 0 || file_name.empty()) {
                return;
            }

            // Skip internal files
            if (file_name == "_H1HJA9ZLO_17.kairo-compiler.cxir" ||
                file_name == "kairo_internal.file") {
                return;
            }

            this->lsp_mapper->add_mapping(
                file_name,
                kairo_line,
                kairo_col,
                cxir_line,
                cxir_col
            );
        }

        // Add to legacy SourceMap
        void add_to_source_map(const CX_Token *token = nullptr) {
            if (this->source_map == nullptr) {
                return;
            }

            if (token == nullptr) {
                this->source_map->add_loc(SourceLocation{
                    .kairo = {this->kairo_line, this->kairo_col},
                    .cxir  = {this->cxir_line, this->cxir_col}
                });
            } else {
                this->kairo_line = token->get_line();
                this->kairo_col = token->get_column();

                if (this->kairo_line == 0 || this->kairo_col == 0) {
                    return;
                }

                this->source_map->add_loc(SourceLocation{
                    .kairo = {this->kairo_line, this->kairo_col},
                    .cxir  = {this->cxir_line, this->cxir_col}
                });
            }
        }

        public:
        explicit CXIRBuilder(const size_t len, SourceMap *source_map = nullptr,
                           LSPPositionMapper *lsp_mapper = nullptr)
            : source_map(source_map), lsp_mapper(lsp_mapper) {
            if (len > (std::numeric_limits<size_t>::max() >> 4)) {
                this->cxir.reserve(std::numeric_limits<size_t>::max());
            } else {
                size_t tmp = (len << 4) + (len << 3) + len;
                this->cxir.reserve(tmp >> 3);
            }
        };

        CXIRBuilder &add_line() {
            this->cxir += "\n";
            track_output("\n");
            return *this;
        };

        CXIRBuilder &add_line(const string &str) {
            this->cxir += str + "\n";
            track_output(str + "\n");
            return *this;
        };

        CXIRBuilder &add_line(const CX_Token &token) {
            string output = token.to_CXIR() + "\n";
            this->cxir += output;
            track_output(output);
            return *this;
        };

        CXIRBuilder &add_line(const std::unique_ptr<CX_Token> &token) {
            if (token == nullptr) {
                return *this;
            }
            return this->add_line(*token);
        };

        // Add without newline - tracks Kairo position
        CXIRBuilder &add(const string &str) {
            // Record mapping at start of this string
            record_mapping();
            add_to_source_map();

            // Output the string plus space
            string output = str + " ";
            this->cxir += output;
            track_output(output);

            return *this;
        };

        CXIRBuilder &add(const CX_Token &token) {
            // Update Kairo position from token
            if (token.get_line() != 0 && token.get_column() != 0) {
                this->kairo_line = token.get_line();
                this->kairo_col = token.get_column();
                
                string fname = token.get_file_name();
                if (!fname.empty() && 
                    fname != "_H1HJA9ZLO_17.kairo-compiler.cxir" &&
                    fname != "kairo_internal.file") {
                    this->file_name = fname;
                }
            }

            // Record mapping at current C++ position
            record_mapping();
            add_to_source_map(&token);

            // Output token
            string output = token.to_CXIR();
            this->cxir += output;
            track_output(output);

            return *this;
        };

        CXIRBuilder &add(const std::unique_ptr<CX_Token> &token) {
            if (token == nullptr) {
                return *this;
            }
            return this->add(*token);
        };

        CXIRBuilder &add_line_marker(const size_t line_num, const string &file_macro = "",
                                     const string &file_name = "") {
            this->add_line();
            
            string line_directive = "#line " + std::to_string(line_num);
            if (!file_macro.empty()) {
                line_directive += " " + file_macro;
            }
            this->add_line(line_directive);
            
            if (!file_name.empty() && !file_macro.empty()) {
                this->file_name = file_name;
                if (source_map) {
                    source_map->set_file_name(file_name);
                }
            } else if (this->file_name.empty() && !file_macro.empty()) {
                this->file_name = "_H1HJA9ZLO_17.kairo-compiler.cxir";
                if (source_map) {
                    source_map->set_file_name(this->file_name);
                }
            }

            // After #line directive, update our Kairo tracking
            this->kairo_line = line_num;
            this->kairo_col = 1;

            return *this;
        };

        CXIRBuilder &add_macro(const string &str) {
            this->add_line();
            this->add_line(str);
            return *this;
        };

        CXIRBuilder &operator+=(const string &str) {
            return this->add(str);
        };
        CXIRBuilder &operator+=(const CX_Token &token) {
            return this->add(token);
        };
        CXIRBuilder &operator+=(const std::unique_ptr<CX_Token> &token) {
            return this->add(token);
        };

        CXIRBuilder &operator<<(const string &str) {
            return this->add_line(str);
        };
        CXIRBuilder &operator<<(const CX_Token &token) {
            return this->add_line(token);
        };
        CXIRBuilder &operator<<(const std::unique_ptr<CX_Token> &token) {
            return this->add_line(token);
        };

        [[nodiscard]] string build() const {
            if (this->source_map) {
                this->source_map->finalize();
            }
            return this->cxir;
        };
        
        [[nodiscard]] string get_file_name() const { return this->file_name; };
    };

    // ... rest of your helper functions unchanged ...
    
    std::string normalize_file_name(std::string file_name) {
        if (file_name.empty()) {
            return "";
        }

        if (file_name == "_H1HJA9ZLO_17.kairo-compiler.cxir" ||
            file_name == "kairo_internal.file") {
            file_name.clear();
            file_name = "";
        }

        return file_name;
    }

    std::string get_file_name(const std::unique_ptr<CX_Token> &tok) {
        if ((tok != nullptr) && (tok->get_line() != 0) &&
            (!normalize_file_name(tok->get_file_name()).empty())) {
            return tok->get_file_name();
        }

        return "";
    }

    bool is_2_token_pp_directive(const std::unique_ptr<CX_Token> &token) {
        return (token->get_value() == "#include" ||
                token->get_type() == cxir_tokens::CXX_PP_INCLUDE) ||
               (token->get_value() == "#define" ||
                token->get_type() == cxir_tokens::CXX_PP_DEFINE) ||
               (token->get_value() == "#ifdef" || token->get_type() == cxir_tokens::CXX_PP_IFDEF) ||
               (token->get_value() == "#ifndef" ||
                token->get_type() == cxir_tokens::CXX_PP_IFNDEF) ||
               (token->get_value() == "#pragma" ||
                token->get_type() == cxir_tokens::CXX_PP_PRAGMA) ||
               (token->get_value() == "#undef" || token->get_type() == cxir_tokens::CXX_PP_UNDEF) ||
               (token->get_value() == "#error" || token->get_type() == cxir_tokens::CXX_PP_ERROR) ||
               (token->get_value() == "#warning" ||
                token->get_type() == cxir_tokens::CXX_PP_WARNING) ||
               (token->get_value() == "#line" || token->get_type() == cxir_tokens::CXX_PP_LINE);
    }

    bool is_1_token_pp_directive(const std::unique_ptr<CX_Token> &token) {
        return (token->get_value() == "#endif" || token->get_type() == cxir_tokens::CXX_PP_ENDIF) ||
               (token->get_value() == "#else" || token->get_type() == cxir_tokens::CXX_PP_ELSE);
    }

    std::string CXIR::generate_CXIR() const {
        size_t      line_num = 1;
        std::string file_name;

        std::map<string, string> file_macros;
        CXIRBuilder cxir(tokens.size(), &source_map, &lsp_position_mapper);

        // get the first file name
        for (const auto &token : tokens) {
            file_name = ::generator::CXIR::get_file_name(token);

            if (file_name.empty() || file_macros.find(file_name) != file_macros.end()) {
                continue;
            }

            file_macros[file_name] = "__$FILE_" + std::to_string(f_index) + "__";
            ++f_index;
        }

        for (const auto &file_macro : file_macros) {
            cxir.add_macro("#define " + file_macro.second + " \"" + file_macro.first + "\"");
        }

        if (file_macros.empty()) [[unlikely]] {
            for (auto &tok : tokens) {
                print("\"", tok->get_file_name(), "\"");
            }
            return "#error \"Lost the original file name\"";
        }

        cxir.add_line_marker(1, file_macros.begin()->second,
                             file_macros.begin()->first);

        for (size_t i = 0; i < tokens.size(); ++i) {
            const auto &token = tokens[i];
            const auto &_file_name = ::generator::CXIR::get_file_name(token);
            const auto &_line_num = token->get_line();

            if (!token || token->get_value().empty()) {
                continue;
            }

            if (is_1_token_pp_directive(token)) {
                cxir.add_macro(token->get_value());
                continue;
            }

            if (is_2_token_pp_directive(token)) {
                if ((i + 1) < tokens.size()) {
                    cxir.add_macro(token->get_value() + " " + tokens[i + 1]->get_value());
                } else {
                    continue;
                }
                ++i;
                continue;
            }

            if ((token->get_value() == "#if" || token->get_type() == cxir_tokens::CXX_PP_IF) ||
                (token->get_value() == "#elif" || token->get_type() == cxir_tokens::CXX_PP_ELIF)) {
                ++line_num;
                ++i;

                size_t nesting = 0;
                size_t j       = i;
                
                cxir.add_line_marker(line_num);
                cxir.add_line()
                    .add(token);

                for (; j < tokens.size(); ++j) {
                    if (tokens[j]->get_type() == cxir_tokens::CXX_LPAREN) {
                        ++nesting;
                    } else if (tokens[j]->get_type() == cxir_tokens::CXX_RPAREN) {
                        --nesting;
                    }

                    if (nesting == 0) {
                        i = j;
                        cxir.add(tokens[j]);
                        break;
                    }

                    cxir.add(tokens[j]);
                }

                cxir.add_line();
                cxir.add_line_marker(line_num);

                continue;
            }
            
            if (!_file_name.empty() && _file_name != file_name) {
                file_name = _file_name;
                cxir.add_line_marker(line_num, file_macros[file_name], file_name);
            }

            if (_line_num != 0 && _line_num != line_num) {
                line_num = _line_num;
                cxir.add_line_marker(line_num);
            }

            cxir.add(token);
        }
        
        // lets dump the lsp position mappings for debugging
        std::cout << "LSP Position Mappings:" << lsp_position_mapper.dump() << std::endl;
        return cxir.build();
    }

}  // namespace __CXIR_CODEGEN_END
*/