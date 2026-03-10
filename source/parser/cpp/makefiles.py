exprs = [

]

states = [

]

annos = [

]



data_to_write = (
"""///--- The Kairo Project ------------------------------------------------------------------------///
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

#include "parser/ast/include/private/AST.hh"
#include "parser/ast/include/config/AST_config.def"

__AST_NODE_BEGIN {
PARSE_SIG(\0REPLACE\0) {
    if (tokens == nullptr || tokens->empty()) [[unlikely]] {
        return 0;
    }

    return 0;
}

TEST_SIG(\0REPLACE\0) {
    if (tokens == nullptr || tokens->empty()) [[unlikely]] {
        return false;
    }
    return false;
}

VISITOR_IMPL(\0REPLACE\0);
}  // namespace __AST_NODE_BEGIN
""")

import os


os.makedirs("expressions", exist_ok=True)
os.makedirs("statements", exist_ok=True)
os.makedirs("annotations", exist_ok=True)
os.makedirs("types", exist_ok=True)
os.makedirs("declarations", exist_ok=True)

for file in exprs:
    with open(f"expressions/AST_{file}.cc", "w") as f:
        f.write(data_to_write.replace("\0REPLACE\0", file))
        print(f"Created file: {file}.cc")

for file in states:
    with open(f"statements/AST_{file}.cc", "w") as f:
        f.write(data_to_write.replace("\0REPLACE\0", file))
        print(f"Created file: {file}.cc")

for file in annos:
    with open(f"annotations/AST_{file}.cc", "w") as f:
        f.write(data_to_write.replace("\0REPLACE\0", file))
        print(f"Created file: {file}.cc")

print("Done!")
