; Kairo highlights

(line_comment) @comment
(block_comment) @comment

[
  "fn" "class" "struct" "union" "interface" "enum" "extend" "type"
  "module" "test" "macro" "import" "ffi" "var" "const" "static" "thread"
  "eval" "inline" "virtual" "override" "final" "async" "unsafe" "mutable"
  "volatile" "atomic" "derives" "impl" "requires" "where" "op" "as"
  "pub" "priv" "prot"
] @keyword

[
  "if" "else" "while" "loop" "for" "in" "match" "case" "default"
  "break" "continue" "return" "try" "catch" "finally" "panic" "yield"
  "assert" "await" "spawn" "delete"
] @keyword.control

[
  "sizeof" "alignof" "typeof"
  "and" "or" "xor" "not" "bitand" "bitor" "not_eq" "compl"
  "and_eq" "or_eq" "xor_eq"
] @keyword.operator

(boolean) @constant.builtin
(null) @constant.builtin
(builtin) @constant.builtin
(self) @variable.builtin
(wildcard_pattern) @variable.builtin

(number) @number
(float) @number
(tuple_index) @number
(string) @string
(char) @string
(raw_block) @embedded

(annotation "@" @attribute name: (_) @attribute)
(attributed_expr "@" @attribute name: (_) @attribute)
(hash_attribute) @attribute
(macro_decl name: (identifier) @function.macro)
(macro_invocation name: (identifier) @function.macro)
(macro_type (identifier) @function.macro)

; declarations
(function_decl name: (identifier) @function)
(function_decl (operator_name) @operator)
(param name: (identifier) @variable.parameter)
(macro_param (identifier) @variable.parameter)
(generic_param name: (identifier) @type)
(class_decl name: (identifier) @type)
(struct_decl name: (identifier) @type)
(union_decl name: (identifier) @type)
(interface_decl name: (identifier) @type)
(enum_decl name: (identifier) @type)
(type_alias_decl name: (identifier) @type)
(enum_variant name: (identifier) @constant)
(field_spec name: (identifier) @property)
(variable_decl name: (identifier) @variable)
(module_decl name: (path (identifier) @module))
(module_pin (path (identifier) @module))
(import_path (identifier) @module)
(kind_bound) @keyword

; types
(path_type_segment name: (identifier) @type)

; expressions
(call_expr function: (identifier_expr (identifier) @function.call))
(call_expr function: (member_expr member: (identifier) @function.method))
(call_expr function: (scope_expr member: (identifier) @function.call))
(call_expr function: (generic_path_expr name: (identifier_expr (identifier) @function.call)))
(member_expr member: (identifier) @property)
(field_initializer name: (identifier) @property)
(field_initializer_tail name: (identifier) @property)
(named_argument name: (identifier) @variable.parameter)
(dotted_variant_expr name: (identifier) @constant)
(dotted_pattern name: (identifier) @constant)
(labeled_stmt label: (identifier) @label)

((identifier) @type
  (#match? @type "^(void|bool|byte|char|usize|isize|string|[uif](8|16|32|64|128|256|512)|f80|bf16|f8e4m3|f8e5m2)$"))

[
  "=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" "@="
  "+" "-" "*" "/" "%" "^^" "<<" "^" "|" "&" "~" "!" "?" "??"
  "==" "!=" "===" "<=>" "<=" "&&" "||" "++" "--" ".." "..=" "..."
  "->" "=>" ".*" "->*" "?.*" "?->*" "?." "?->"
] @operator

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" ":" "::" "."] @punctuation.delimiter
