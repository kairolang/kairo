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

#include "parser/preprocessor/include/preprocessor.hh"
#define _SILENCE_CXX23_ALIGNED_UNION_DEPRECATION_WARNING
#define _SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING
#define _SILENCE_ALL_CXX17_DEPRECATION_WARNINGS

#include <neo-panic/include/error.hh>
#include <neo-pprint/include/hxpprint.hh>
#include <vector>

#include "controller/include/tooling/tooling.hh"
#include "controller/include/shared/logger.hh"

int main(int argc, char **argv) {
    std::vector<neo::json> errors;
    auto compiler = CompilationUnit();
    int  result   = 1;

    try {
        result = compiler.compile(argc, argv);
    } catch (error::Panic &e) {  // hard error
        errors.push_back(e.final_err.to_json());
    }

    if (result == 3) {  // just print dependencies
        // we print json format so its easy to parse
        print("{\"dependencies\": [");
        
        for (const auto &imp : DEPENDENCIES) {
            print("  \"" + imp.generic_string() + "\",");
        }
        
        print("]}");

        return 0;
    }

    if (LSP_MODE && error::ERRORS.size() > 0) {
        for (auto err : error::ERRORS) {
            if (err.line == 0 && err.col == 0 || err.level == "none") {
                continue;
            }
            
            errors.push_back(err.to_json());
        }

        neo::json error_json("error");
        error_json.add("errors", errors);

        print(error_json);

        return 1;  // soft error
    }

    if ((not LSP_MODE) and (result != 0 or error::HAS_ERRORED)) {
        print(string(colors::bold) + string(colors::fg8::red) + "error: " + string(colors::reset) + "aborting... due to previous errors");
    } else if (not LSP_MODE and !error::HAS_ERRORED) {
        print(string(colors::bold) + string(colors::fg8::green) + "success: " + string(colors::reset) + "compilation successful");
    } else if (not LSP_MODE) {
        print(string(colors::bold) + string(colors::fg8::yellow) + "warning: " + string(colors::reset) + "unknown... continuing?");
    }

    return result;
}