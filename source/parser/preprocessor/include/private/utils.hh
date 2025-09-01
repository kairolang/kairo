///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __FIND_P0_H__
#define __FIND_P0_H__

// helix_hdr -> 1
// helix_hdr_lib -> 2
// helix_mod -> 3
// helix_mod_lib -> 4
// invalid -> 0

#include <cctype>
#include <cstddef>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>

inline int find_import_priority(bool is_module,  // NOLINT
                                bool found_helix_mod,
                                bool found_helix_hdr,
                                bool found_helix_mod_lib,
                                bool found_helix_hdr_lib) {
    if (is_module) {
        if (found_helix_mod && found_helix_mod_lib) {
            return 4;
        }

        if (found_helix_mod_lib) {
            return 4;
        }

        if (found_helix_mod) {
            return 3;
        }
    }

    if (found_helix_mod && found_helix_hdr && found_helix_mod_lib && found_helix_hdr_lib) {
        return 1;
    }

    if (found_helix_mod && found_helix_mod_lib && found_helix_hdr_lib) {
        return 2;
    }

    if (found_helix_mod && found_helix_hdr && found_helix_hdr_lib) {
        return 1;
    }

    if (found_helix_mod && found_helix_hdr && found_helix_mod_lib) {
        return 4;
    }

    if (found_helix_hdr && found_helix_mod_lib && found_helix_hdr_lib) {
        return 2;
    }

    if (found_helix_mod && found_helix_hdr) {
        return 1;
    }

    if (found_helix_mod && found_helix_mod_lib) {
        return 4;
    }

    if (found_helix_mod && found_helix_hdr_lib) {
        return 2;
    }

    if (found_helix_hdr && found_helix_mod_lib) {
        return 4;
    }

    if (found_helix_hdr && found_helix_hdr_lib) {
        return 2;
    }

    if (found_helix_mod_lib && found_helix_hdr_lib) {
        return 2;
    }

    if (found_helix_mod) {
        return 3;
    }

    if (found_helix_hdr) {
        return 1;
    }

    if (found_helix_mod_lib) {
        return 4;
    }

    if (found_helix_hdr_lib) {
        return 2;
    }

    return 0;
}

namespace helix::abi {
inline std::string sanitize_string(const std::string &input) {
    std::string output = "_$";

    for (char ch : input) {
        if ((std::isalnum(ch) != 0) || ch == '_') {
            output += ch;
        } else {
            output += '_';
        }
    }

    return output + "_N";
}

enum class ObjectType : unsigned char {
    Module,
    Class,
    Struct,
    Function,
    Operator,
    Reserved,
    Internal,
    None
};

// --- Mangler: encodes non-alnum/_ as $XXXX, appends $L<length>_E$
inline std::string mangle(const std::string &input, ObjectType type) {
    if (input.empty())
        throw std::invalid_argument("Input string cannot be empty");

    std::string prefix;
    switch (type) {
        case ObjectType::Module:
            prefix = "_$M_";
            break;
        case ObjectType::Class:
            prefix = "_$C_";
            break;
        case ObjectType::Struct:
            prefix = "_$S_";
            break;
        case ObjectType::Function:
            prefix = "_$F_";
            break;
        case ObjectType::Operator:
            prefix = "_$O_";
            break;
        case ObjectType::Reserved:
            prefix = "_$R_";
            break;
        case ObjectType::Internal:
            prefix = "_$I_";
            break;
        default:
            break;
    }

    std::string output = prefix;

    for (char ch : input) {
        if (std::isalnum(static_cast<unsigned char>(ch)) || ch == '_') {
            output += ch;
        } else {
            std::ostringstream oss;
            oss << '$' << std::uppercase << std::hex << std::setw(4) << std::setfill('0')
                << (static_cast<unsigned int>(static_cast<unsigned char>(ch)));
            output += oss.str();
        }
    }

    output += "$L" + std::to_string(input.length()) + "_E$";
    return output;
}

// --- Detect mangled type by prefix
inline ObjectType is_mangled(const std::string &input) {
    if (input.size() < 4 || input[0] != '_' || input[1] != '$')
        return ObjectType::None;

    std::string prefix = input.substr(0, 3);
    if (prefix == "_$M_")
        return ObjectType::Module;
    if (prefix == "_$C_")
        return ObjectType::Class;
    if (prefix == "_$S_")
        return ObjectType::Struct;
    if (prefix == "_$F_")
        return ObjectType::Function;
    if (prefix == "_$O_")
        return ObjectType::Operator;
    if (prefix == "_$R_")
        return ObjectType::Reserved;
    if (prefix == "_$I_")
        return ObjectType::Internal;

    return ObjectType::None;
}

// --- Check hex digit
inline bool is_hex_digit(char c) {
    return std::isdigit(static_cast<unsigned char>(c)) || (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}

// --- Extract basename without extension
inline std::string basename_no_ext(const std::string &path) {
    size_t slash  = path.rfind('/');
    size_t bslash = path.rfind('\\');
    size_t sep    = (slash == std::string::npos)
                        ? bslash
                        : ((bslash != std::string::npos && bslash > slash) ? bslash : slash);
    size_t start  = (sep == std::string::npos) ? 0 : sep + 1;
    size_t dot    = path.rfind('.');
    size_t end    = (dot != std::string::npos && dot > start) ? dot : path.length();
    return path.substr(start, end - start);
}

// --- Demangler: supports $XX and $XXXX, validates length
inline std::string demangle(const std::string &input, ObjectType type) {
    std::string expected_prefix;
    switch (type) {
        case ObjectType::Module:
            expected_prefix = "_$M_";
            break;
        case ObjectType::Class:
            expected_prefix = "_$C_";
            break;
        case ObjectType::Struct:
            expected_prefix = "_$S_";
            break;
        case ObjectType::Function:
            expected_prefix = "_$F_";
            break;
        case ObjectType::Operator:
            expected_prefix = "_$O_";
            break;
        case ObjectType::Reserved:
            expected_prefix = "_$R_";
            break;
        case ObjectType::Internal:
            expected_prefix = "_$I_";
            break;
        default:
            break;
    }

    if (!input.starts_with(expected_prefix))
        throw std::invalid_argument("Invalid mangled name or type mismatch");

    size_t len_pos = input.rfind("$L");
    size_t end_pos = input.rfind("_E$");
    if (len_pos == std::string::npos || end_pos == std::string::npos || end_pos <= len_pos)
        throw std::invalid_argument("Invalid mangled name: missing length markers");

    std::string len_str = input.substr(len_pos + 2, end_pos - len_pos - 2);
    if (len_str.empty())
        throw std::invalid_argument("Invalid length in mangled name");

    size_t expected_len = std::stoul(len_str);

    std::string encoded =
        input.substr(expected_prefix.length(), len_pos - expected_prefix.length());
    std::string output;

    for (size_t i = 0; i < encoded.size();) {
        if (encoded[i] == '$') {
            size_t j     = i + 1;
            size_t count = 0;
            while (j < encoded.size() && count < 4 && is_hex_digit(encoded[j])) {
                ++j;
                ++count;
            }
            if (count == 4 || count == 2) {
                unsigned long code = std::stoul(encoded.substr(i + 1, count), nullptr, 16);
                output += static_cast<char>(code);
                i = j;
                continue;
            }
        }
        output += encoded[i++];
    }

    if (output.size() != expected_len)
        throw std::invalid_argument("Demangled length mismatch");

    return output;
}

// --- Demangle partial segments, strip directories for Modules
inline std::string demangle_partial(const std::string &input) {
    std::string output;
    for (size_t i = 0; i < input.size(); ++i) {
        if (i + 3 < input.size() && input[i] == '_' && input[i + 1] == '$') {
            ObjectType ty = ObjectType::None;
            switch (input[i + 2]) {
                case 'M':
                    ty = ObjectType::Module;
                    break;
                case 'C':
                    ty = ObjectType::Class;
                    break;
                case 'S':
                    ty = ObjectType::Struct;
                    break;
                case 'F':
                    ty = ObjectType::Function;
                    break;
                case 'O':
                    ty = ObjectType::Operator;
                    break;
                case 'R':
                    ty = ObjectType::Reserved;
                    break;
                case 'I':
                    ty = ObjectType::Internal;
                    break;
                default:
                    output += input[i];
                    continue;
            }

            size_t end_pos = input.find("_E$", i);
            if (end_pos == std::string::npos) {
                output += input[i];
                continue;
            }

            std::string mangled = input.substr(i, end_pos - i + 3);
            std::string dem     = demangle(mangled, ty);
            if (ty == ObjectType::Module)
                dem = basename_no_ext(dem);
            output += dem;
            i = end_pos + 2;  // loop will ++
            continue;
        }

        output += input[i];
    }
    return output;
}

// --- Strip leading helix:: prefix
inline std::string strip_helix_prefix(const std::string &input) {
    const std::string p1 = "helix::";
    const std::string p2 = "::helix::";
    if (input.starts_with(p1))
        return input.substr(p1.length());
    if (input.starts_with(p2))
        return input.substr(p2.length());
    return input;
}
}  // namespace helix::abi

#endif  // __FIND_P0_H__