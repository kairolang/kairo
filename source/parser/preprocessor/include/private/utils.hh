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
#include <stdexcept>
#include <string>

#include "neo-types/include/hxint.hh"

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

enum class ObjectType : u8 { Module, Class, Struct, Function, Operator, Reserved, Internal, None };

inline std::string mangle(const std::string &input, ObjectType type) {
    if (input.empty()) {
        throw std::invalid_argument("Input string cannot be empty");
    }

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
    }

    std::string output = prefix;

    for (char ch : input) {
        if (std::isalnum(ch) || ch == '_') {
            output += ch;
        } else {
            output += '$';
            char hex[3];
            snprintf(hex, sizeof(hex), "%02X", static_cast<unsigned char>(ch));
            output += hex;
        }
    }

    output += "$L";
    output += std::to_string(input.length()) + "_E$";

    return output;
}

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
    }

    if (!input.starts_with(expected_prefix)) {
        throw std::invalid_argument("Invalid mangled name or type mismatch");
    }

    size_t len_pos = input.rfind("$L");
    if (len_pos == std::string::npos) {
        throw std::invalid_argument("Invalid mangled name: missing length");
    }

    size_t end_pos = input.rfind("_E$");
    if (end_pos == std::string::npos || end_pos <= len_pos) {
        throw std::invalid_argument("Invalid mangled name: missing end marker");
    }

    std::string len_str = input.substr(len_pos + 2 /* part after: "$L" */,
                                       end_pos - len_pos - 2 /* part before: "_E$" */);

    if (len_str.empty()) {
        throw std::invalid_argument("Invalid length in mangled name");
    }

    size_t expected_len;
    try {
        expected_len = std::stoul(len_str);
    } catch (...) { throw std::invalid_argument("Invalid length in mangled name"); }

    std::string encoded =
        input.substr(expected_prefix.length(), len_pos - expected_prefix.length());
    std::string output;

    for (size_t i = 0; i < encoded.length(); ++i) {
        if (encoded[i] == '$' && i + 2 < encoded.length()) {
            std::string hex = encoded.substr(i + 1, 2);
            try {
                unsigned char ch = static_cast<unsigned char>(std::stoul(hex, nullptr, 16));
                output += ch;
                i += 2;
            } catch (...) { throw std::invalid_argument("Invalid hex encoding in mangled name"); }
        } else {
            output += encoded[i];
        }
    }

    if (output.length() != expected_len) {
        throw std::invalid_argument("Demangled length mismatch");
    }

    return output;
}

inline ObjectType is_mangled(const std::string &input) {
    if (input.length() < 4 || input[0] != '_' || input[1] != '$') {
        return ObjectType::None;  // Not a recognized mangled name
    }

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

    return ObjectType::None;  // Not a recognized mangled name
}

// function to demangle a part of a name such as in helix::_$M_foo$L3::bar
// to helix::foo::bar
inline std::string demangle_parttial(const std::string &input) {
    // read from each char in the string untill we find a _$
    // then read ill the chars until we find a _E$ and then keep checking the rest of the string

    std::string output;

    for (size_t i = 0; i < input.length(); ++i) {
        if (i + 3 < input.length() && input[i] == '_' && input[i + 1] == '$') {
            switch (input[i + 2]) {
                case 'M':
                case 'C':
                case 'S':
                case 'F':
                case 'O':
                case 'R':
                case 'I':
                    break;
                default:
                    output += input[i];
                    continue;
            }

            // found a prefix, now read until we find a _E$
            size_t end_pos = input.find("_E$", i);

            if (end_pos != std::string::npos) {
                std::string mangled = input.substr(i, end_pos - i + 3);
                i                   = end_pos + 2;  // move past _E$

                auto type = is_mangled(mangled);
                if (type == ObjectType::None) {
                    output += input.substr(i, end_pos - i + 3);  // keep the mangled name as is
                    continue;
                }

                // demangle the name
                std::string demangled = demangle(mangled, type);
                output += demangled;
                continue;
            }
        }

        output += input[i];
    }
}
}  // namespace helix::abi

#endif  // __FIND_P0_H__