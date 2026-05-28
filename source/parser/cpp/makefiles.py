exprs = [

]

states = [

]

annos = [

]



data_to_write = (
"""/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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
