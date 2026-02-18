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
        inline static size_t cxir_line{30};
        inline static size_t cxir_col{1};
        string cxir;
        SourceMap *source_map{nullptr};

        size_t kairo_line{1};
        size_t kairo_col{1};

        // we need a few functions to help us also build the source map
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
        explicit CXIRBuilder(const size_t len, SourceMap *source_map = nullptr) {
            // scale the size of the cxir string by about 3.125x
            if (len > (std::numeric_limits<size_t>::max() >> 4)) {
                this->cxir.reserve(std::numeric_limits<size_t>::max());
            }

            this->source_map = source_map;

            size_t tmp = (len << 4) + (len << 3) + len; // (16 + 8 + 1) * len = 25 * len
            this->cxir.reserve(tmp >> 3); // divide by 8 to get the size in bytes
        };

        CXIRBuilder &add_line() {
            this->cxir += "\n";
            ++this->cxir_line;
            this->cxir_col = 1;
            return *this;
        };

        CXIRBuilder &add_line(const string &str) {
            this->cxir += str + "\n";
            
            ++this->cxir_line;
            this->cxir_col = 1;
            
            return *this;
        };

        CXIRBuilder &add_line(const CX_Token &token) {
            bool new_line_added = token.get_value()[0] == '#';
            
            this->cxir += token.to_CXIR() + "\n";
        
            this->cxir_line += new_line_added ? 2 : 1;
            this->cxir_col = 1;
        
            return *this;
        };

        CXIRBuilder &add_line(const std::unique_ptr<CX_Token> &token) {
            if (token == nullptr) {
                return *this;
            }

            this->add_line(*token);
            return *this;
        };
        
        // ONLY add change the kairo mapping
        CXIRBuilder &add(const string &str) {
            auto lines = (std::count(str.begin(), str.end(), '\n'));
            
            this->cxir      += str + " ";
            add_to_source_map(); // add the current line and col to the source map

            ++this->cxir_col; // for the space
            
            this->cxir_line += lines;
            this->cxir_col  += lines > 0 ? (str.find_last_of('\n') == std::string::npos
                                         ? 0
                                         : (str.length() - str.find_last_of('\n') - 1))
                                         : str.length();
            return *this;
        };

        CXIRBuilder &add(const CX_Token &token) {
            bool new_line_added = token.get_value()[0] == '#';
            
            if (new_line_added) {
                ++this->cxir_line;
                this->cxir_col = 1;
                this->cxir += token.get_value() + " ";
            } else {
                this->cxir += token.to_CXIR() + " ";
            }
            
            
            this->add_to_source_map(&token);

            this->cxir_col += token.get_value().length() + 1;
            
            return *this;
        };

        CXIRBuilder &add(const std::unique_ptr<CX_Token> &token) {
            if (token == nullptr) {
                return *this;
            }

            this->add(*token);
            return *this;
        };

        CXIRBuilder &add_line_marker(const size_t line_num, const string &file_macro = "",
                                     const string &file_name = "") {
            this->add_line();
            this->add_line("#line " + std::to_string(line_num)
                          + (file_macro != "" ? " " + file_macro : ""));
            
            if (!file_name.empty() && !file_macro.empty()) {
                this->file_name = file_name;
                source_map->set_file_name(file_name);
            } else if (this->file_name.empty() && !file_macro.empty()) {
                this->file_name = "_H1HJA9ZLO_17.kairo-compiler.cxir";
                source_map->set_file_name(this->file_name);
            }

            return *this;
        };

        CXIRBuilder &add_macro(const string &str) {
            this->add_line();
            this->add_line(str);
            return *this;
        };

        CXIRBuilder &operator+=(const string &str) {
            this->add(str);
            return *this;
        };
        CXIRBuilder &operator+=(const CX_Token &token) {
            this->add(token);
            return *this;
        };
        CXIRBuilder &operator+=(const std::unique_ptr<CX_Token> &token) {
            this->add(token);
            return *this;
        };

        CXIRBuilder &operator<<(const string &str) {
            this->add_line(str);
            return *this;
        };
        CXIRBuilder &operator<<(const CX_Token &token) {
            this->add_line(token);
            return *this;
        };
        CXIRBuilder &operator<<(const std::unique_ptr<CX_Token> &token) {
            this->add_line(token);
            return *this;
        };

        [[nodiscard]] string build() const {
            this->source_map->finalize();
            return this->cxir;
        };
        [[nodiscard]] string get_file_name() const { return this->file_name; };
    };

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
        /// goals:
        /// 1. we have to genrate the first #line directive to point to the original file and line 1
        /// 2. everey CXIR token has to be separated by a newline (as to keep track of the excat
        /// position in the original file)
        ///    - this is important for the source map generation later on
        /// 3. some CXIR tokens may not have any location information, in this case we have to look
        /// ahead and behind to find the closest token with location information
        ///    - in the case the diffrerence on LL and LR is the same, we choose LR (right) since it
        ///    is more likely to be the correct one UNLESS theres a semicolon in between current and
        ///    LR, in this case we choose LL

        size_t      line_num = 1;
        std::string file_name;

        std::map<string, string> file_macros;
        // std::string              cxir;
        CXIRBuilder cxir(tokens.size(), &source_map);

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

        // generate the first #line directive
        // look for __$FILE_0__ in the map and use that as the file name

        if (file_macros.empty()) [[unlikely]] {
            /// we have a big problem here
            for (auto &tok : tokens) {
                print("\"", tok->get_file_name(), "\"");
            }

            return "#error \"Lost the original file name\"";
        }

        cxir.add_line_marker(1, file_macros.begin()->second,
                             file_macros.begin()->first); // add the first #line directive

        for (size_t i = 0; i < tokens.size(); ++i) {
            const auto &token = tokens[i];
            const auto &_file_name = ::generator::CXIR::get_file_name(token);
            const auto &_line_num = token->get_line();

            if (!token || token->get_value().empty()) {
                continue;
            }

            // macro processing
            if (is_1_token_pp_directive(token)) {
                cxir.add_macro(token->get_value());
                continue;
            }

            // macro processing
            if (is_2_token_pp_directive(token)) {
                if ((i + 1) < tokens.size()) {
                    cxir.add_macro(token->get_value() + " " + tokens[i + 1]->get_value());
                } else {
                    continue;
                }

                ++i;  // skip the next token
                continue;
            }

            // macro processing
            if ((token->get_value() == "#if" || token->get_type() == cxir_tokens::CXX_PP_IF) ||
                (token->get_value() == "#elif" || token->get_type() == cxir_tokens::CXX_PP_ELIF)) {
                // in this case we get the line from the next to next token since '#if (' - dont have a line number
                ++line_num;
                ++i; // skip #if or #elif

                // add all the tokens from the ( to the other ) keeping track of nesting
                size_t nesting = 0;
                size_t j       = i;
                
                cxir.add_line_marker(line_num);
                cxir.add_line()
                    .add(token); // add the #if or #elif

                for (; j < tokens.size(); ++j) {
                    if (tokens[j]->get_type() == cxir_tokens::CXX_LPAREN) {
                        ++nesting;
                    } else if (tokens[j]->get_type() == cxir_tokens::CXX_RPAREN) {
                        --nesting;
                    }

                    if (nesting == 0) {
                        i = j;

                        cxir.add(tokens[j]); // add the last )
                        break;
                    }

                    cxir.add(tokens[j]); // add the tokens in between
                }

                cxir.add_line(); // add a new line after the #if or #elif
                cxir.add_line_marker(line_num);

                continue;

            }
            
            if (!_file_name.empty() && _file_name != file_name) { // file change
                file_name = _file_name;
                cxir.add_line_marker(line_num, file_macros[file_name], file_name);
            }

            if (_line_num != 0 && _line_num != line_num) {
                line_num = _line_num;
                cxir.add_line_marker(line_num);
            }

            cxir.add(token);
        }

        return cxir.build();
    }

}  // namespace __CXIR_CODEGEN_END

// This logic is very flawed and needs to be re-written
//     SourceLocation source_mapped_token = {.line   = token->get_line(),
//                                           .column = token->get_column(),
//                                           .length = token->get_length()};

//     // find the nearest valid token
//     if (token->get_line() == 0) {
//         size_t LL = SIZE_MAX;  // left token index
//         size_t LR = SIZE_MAX;  // left token index
//         size_t NI = SIZE_MAX;  // nearest token index

//         for (size_t j = i; j < tokens.size(); j++) {  // find the nearest token on the right
//             if (tokens[j]->get_line() != 0) {
//                 LR = j;
//                 break;
//             }
//         }

//         for (size_t j = i; j > 0; j--) {  // find the nearest token on the left
//             if (tokens[j]->get_line() != 0) {
//                 LL = j;
//                 break;
//             }
//         }

//         if (LL == SIZE_MAX && LR == SIZE_MAX) {
//             source_mapped_token = {.line           = 0,
//                                    .column         = 0,
//                                    .length         = token->get_length(),
//                                    .is_placeholder = true};

//             goto APPEND_TOKEN_TO_CXIR;
//         }

//         if (LL == SIZE_MAX) {
//             NI = LR;
//         } else if (LR == SIZE_MAX) {
//             NI = LL;
//         } else {
//             if (LR - i == i - LL) {
//                 // if the difference is the same, we choose LR unless there is a semicolon
//                 // in between current and LR

//                 bool semicolon_found = false;

//                 for (size_t j = i; j < LR; j++) {
//                     if (tokens[j]->get_value() == ";" ||
//                         tokens[j]->get_type() == cxir_tokens::CXX_SEMICOLON) {
//                         semicolon_found = true;
//                         break;
//                     }
//                 }

//                 if (semicolon_found) {
//                     NI = LL;
//                 } else {
//                     NI = LR;
//                 }
//             } else if (LR - i < i - LL) {  // choose the nearest one
//                 NI = LR;
//             } else {
//                 NI = LL;
//             }
//         }

//         if (NI == SIZE_MAX) {
//             source_mapped_token = {.line   = tokens[NI]->get_line(),
//                                    .column = tokens[NI]->get_column(),
//                                    .length = tokens[NI]->get_length()};
//         } else {
//             if (LR != SIZE_MAX && LR != 0) {
//                 source_mapped_token = {.line   = tokens[LR]->get_line(),
//                                        .column = tokens[LR]->get_column(),
//                                        .length = tokens[LR]->get_length()};
//             } else if (LL != SIZE_MAX && LL != 0) {
//                 source_mapped_token = {.line   = tokens[LL]->get_line(),
//                                        .column = tokens[LL]->get_column(),
//                                        .length = tokens[LL]->get_length()};
//             } else {
//                 source_mapped_token = {.line   = 0,
//                                        .column = 0,
//                                        .length = token->get_length(),
//                                        .is_placeholder = true};
//             }
//         }
//     }

// APPEND_TOKEN_TO_CXIR:
//     handle_file_change(file_name, cxir, token, source_map, cxir_line, cxir_col);
//     source_map.append(source_mapped_token, cxir_line, cxir_col);

//     cxir += token->get_value() + " ";

//     if (cxir_col > 1000) {  // fill upto 1000 columns (this is for more efficient source map
//                             // generation)
//         cxir_col = 1;

//         cxir += "\n";
//         ++cxir_line;
//     } else {
//         cxir_col += (token->get_length() != 1 ? token->get_length() :
//         token->get_value().length()) + 1;
//     }