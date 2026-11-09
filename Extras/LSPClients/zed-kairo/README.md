# zed-kairo

Kairo support for Zed: highlighting, outline, bracket matching, auto-indent, text objects, and C/C++ injection into `inline "c++" { ... }` bodies.

## Install (dev)

1. Point `[grammars.kairo]` in `extension.toml` at the grammar:
   - local:  `repository = "file:///path/to/kairo-lang/tree-sitter-kairo"`
   - remote: the tree-sitter-kairo repo URL and set `rev` to a full commit SHA in that repo.
2. The grammar repo must have `src/parser.c` and `src/tree_sitter/` committed (run `tree-sitter generate` and commit the output); Zed compiles it to wasm.
3. Zed: command palette -> `zed: install dev extension` -> pick this directory.
