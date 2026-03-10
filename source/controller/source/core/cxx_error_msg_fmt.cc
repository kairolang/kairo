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
    if (clang_out.empty()) return {token::Token(), "", ""};

    std::string file_path;
    size_t      line_number   = 0;
    size_t      column_number = 0;
    std::string message;

    // Detect Windows drive prefix: line starts with a letter followed by ':'
    // e.g. "C:\...", "Z:/..."
    bool has_drive_prefix = (clang_out.size() >= 2 &&
                              std::isalpha((unsigned char)clang_out[0]) &&
                              clang_out[1] == ':');

    if (has_drive_prefix) {
        // Two possible formats on Windows:
        //
        //   clang-cl: Z:\path\file.hh(line,col): severity: message
        //   clang:    Z:/path/file.hh:line:col: severity: message
        //
        // Disambiguate by searching for '(' starting after the drive colon (index 2).
        // If found, it's clang-cl format. Otherwise it's clang-on-Windows format.
        //
        // We do NOT compare paren_pos vs colon_pos because Windows paths contain
        // colons in places like "10.0.26100.0" and "VC\Tools\MSVC\14.50.35717",
        // which would cause colon_pos to land inside the path rather than after it.

        size_t paren_pos = clang_out.find('(', 2);

        if (paren_pos != std::string::npos) {
            // ── clang-cl format: path(line,col): severity: message ──────────
            file_path = clang_out.substr(0, paren_pos);

            size_t close_paren = clang_out.find(')', paren_pos);
            if (close_paren == std::string::npos) return {token::Token(), "", ""};

            std::string loc = clang_out.substr(paren_pos + 1, close_paren - paren_pos - 1);
            auto comma = loc.find(',');
            try {
                if (comma != std::string::npos) {
                    line_number   = std::stoul(loc.substr(0, comma));
                    column_number = std::stoul(loc.substr(comma + 1));
                } else {
                    if (loc.empty()) return {token::Token(), "", ""};
                    line_number = std::stoul(loc);
                }
            } catch (...) {
                return {token::Token(), "", ""};
            }

            // after close_paren expect ": severity: message"
            size_t msg_start = clang_out.find(':', close_paren);
            if (msg_start == std::string::npos) return {token::Token(), "", ""};
            message = clang_out.substr(msg_start + 1);
            if (!message.empty() && message[0] == ' ') message = message.substr(1);

        } else {
            // ── clang-on-Windows format: Z:/path/file.hh:line:col: message ──
            // Find the colon that separates path from line number.
            // Skip the drive colon at index 1, then find the next ':'.
            size_t path_colon = clang_out.find(':', 2);
            if (path_colon == std::string::npos) return {token::Token(), "", ""};

            file_path = clang_out.substr(0, path_colon);

            std::istringstream stream(clang_out.substr(path_colon + 1));
            try {
                if (!(stream >> line_number)) return {token::Token(), "", ""};
                char sep = 0;
                stream >> sep; // ':'
                if (!(stream >> column_number)) return {token::Token(), "", ""};
                stream >> sep; // ':'
            } catch (...) {
                return {token::Token(), "", ""};
            }
            std::getline(stream, message);
            if (!message.empty() && message[0] == ' ') message = message.substr(1);
        }

    } else {
        // ── POSIX format: /path/file.hh:line:col: severity: message ─────────
        std::istringstream stream(clang_out);
        std::getline(stream, file_path, ':');
        try {
            if (!(stream >> line_number)) return {token::Token(), "", ""};
            char sep = 0;
            stream >> sep; // ':'
            if (!(stream >> column_number)) return {token::Token(), "", ""};
            stream >> sep; // ':'
        } catch (...) {
            return {token::Token(), "", ""};
        }
        std::getline(stream, message);
        if (!message.empty() && message[0] == ' ') message = message.substr(1);
    }

    if (file_path.empty() || line_number == 0) {
        return {token::Token(), "", ""};
    }

    auto meta = get_meta(file_path, line_number);

    token::Token pof = token::Token(line_number,
                                    std::get<0>(meta),
                                    std::get<1>(meta),
                                    std::get<0>(meta) + line_number,
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

