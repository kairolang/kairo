(function_decl "fn" @context name: (identifier) @name) @item
(class_decl "class" @context name: (identifier) @name) @item
(struct_decl "struct" @context name: (identifier) @name) @item
(union_decl "union" @context name: (identifier) @name) @item
(interface_decl "interface" @context name: (identifier) @name) @item
(enum_decl "enum" @context name: (identifier) @name) @item
(enum_variant name: (identifier) @name) @item
(extend_decl "extend" @context target: (_) @name) @item
(type_alias_decl "type" @context name: (identifier) @name) @item
(module_decl "module" @context name: (path) @name) @item
(test_decl "test" @context label: (string) @name) @item
(macro_decl "macro" @context name: (identifier) @name) @item
(source_file (variable_decl (storage_head) @context name: (identifier) @name) @item)
(declaration_list (variable_decl (storage_head) @context name: (identifier) @name) @item)
