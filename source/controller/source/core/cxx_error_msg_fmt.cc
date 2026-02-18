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

#include <map>

#include "controller/include/shared/file_system.hh"
#include "controller/include/tooling/tooling.hh"
#include "generator/include/CX-IR/loc.hh"
#include "parser/preprocessor/include/private/utils.hh"


/// key is the line number in the output, value is the line and column, and length associated in the
/// source

std::tuple<size_t, size_t> get_meta(const std::string &file_name, size_t line_number) {
    std::optional<controller::file_system::fs_path> path =
        __CONTROLLER_FS_N::resolve_path(file_name, true, true);

    if (!path.has_value()) {
        return {1, 1};
    }

    auto data = controller::file_system::get_line(file_name, line_number);

    if (!data.has_value()) {
        return {1, 1};
    }

    // no skip any whitespcae and add that to coloum nuymber
    size_t col_num = 1;
    for (char chr : *data) {
        switch (chr) {
            case ' ':
                [[fallthrough]];
            case '\t':
                [[fallthrough]];
            case '\f':
                [[fallthrough]];
            case '\v':
                ++col_num;
                continue;
            default:
                goto BREAK_LOOP;
                break;
        }

    BREAK_LOOP:
        break;
    }  // we now have the col num

    // strip all whitespace on the right
    (*data).erase(std::find_if((*data).rbegin(),
                               (*data).rend(),
                               [](unsigned char chr) { return std::isspace(chr) == 0; })
                      .base(),
                  (*data).end());

    // now get the (*data) length and - col_num
    return {col_num - 1, (*data).length() - col_num + 1};
}

CXIRCompiler::ErrorPOFNormalized CXIRCompiler::parse_clang_err(std::string clang_out) {
    std::string file_path;
    size_t      line_number   = 0;
    size_t      column_number = 0;
    std::string message;

    std::istringstream stream(clang_out);
    std::getline(stream, file_path, ':');  // Extract file path
    stream >> line_number;                 // Extract line number
    stream.ignore();                       // Ignore the next colon
    stream >> column_number;               // Extract column number
    stream.ignore();                       // Ignore the next colon
    std::getline(stream, message);         // Extract the message

    // see if filepath is in std::unordered_map<std::string, SourceMap> SOURCE_MAPS
    // if it is, call SOURCE_MAPS[file_path].get_pof(line_number, column_number, length)

    if (file_path.empty()) {
        return {token::Token(), "", ""};
    }

    // open the cached file jump to the line and get the length and col
    auto meta = get_meta(file_path, line_number);

    token::Token pof = token::Token(line_number,
                                    std::get<0>(meta),
                                    std::get<1>(meta),
                                    (std::get<0>(meta) + line_number),
                                    "/*error*/",
                                    file_path,
                                    "<other>");

    return {pof, message, file_path};
}

CXIRCompiler::ErrorPOFNormalized CXIRCompiler::parse_gcc_err(std::string gcc_out) {
    return parse_clang_err(gcc_out);
}

std::string preprocess_msvc_output(const std::string &msvc_out) {
    std::regex with_block(R"(with\s*\[([^\]]+)\])");
    return std::regex_replace(msvc_out, with_block, R"(with($1))");
}

CXIRCompiler::ErrorPOFNormalized CXIRCompiler::parse_msvc_err(std::string msvc_out) {
    // Preprocess the MSVC output to inline 'with' blocks and simplify parsing
    msvc_out = preprocess_msvc_output(msvc_out);

    std::string file_path;
    size_t      line_number = 0;
    std::string message;

    std::istringstream stream(msvc_out);

    // Extract the file path up to the opening parenthesis '('
    if (!std::getline(stream, file_path, '(')) {
        return {token::Token(), "", ""};
    }

    // Verify if the extracted portion is a valid file path
    bool isFile = false;
    try {
        std::filesystem::path path(file_path);
        isFile = !path.empty();
    } catch (...) { isFile = false; }

    if (!isFile) {
        return {token::Token(), "", ""};
    }

    // Parse the line number between the parentheses
    char opening_parenthesis = msvc_out[file_path.size()];  // First character after file_path
    if (opening_parenthesis != '(') {
        return {token::Token(), "", ""};  // Invalid format
    }

    char closing_parenthesis;
    stream >> line_number >> closing_parenthesis;

    if (closing_parenthesis != ')') {
        return {token::Token(), "", ""};  // Invalid format
    }

    // Ensure the colon after the closing parenthesis
    char colon;
    stream >> colon;
    if (colon != ':') {
        return {token::Token(), "", ""};
    }

    // Extract the error message
    std::getline(stream, message);

    // Generate the token
    token::Token pof;

    auto meta = get_meta(file_path, line_number);

    pof = token::Token(line_number,
                       std::get<0>(meta),
                       std::get<1>(meta),
                       (std::get<0>(meta) + line_number),
                       "/*error*/",
                       file_path,
                       "<other>");

    return {pof, helix::abi::demangle_partial(message), file_path};
}

