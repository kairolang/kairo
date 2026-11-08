; Kairo highlights (Zed capture names)

(line_comment) @comment
((line_comment) @comment.doc (#match? @comment.doc "^///"))
(block_comment) @comment
((block_comment) @comment.doc (#match? @comment.doc "^/\\*\\*"))

(identifier) @variable

((identifier) @type
  (#match? @type "^(void|bool|byte|char|usize|isize|string|[ui](8|16|32|64|128|256|512)|f(8|16|32|64|80|128|256|512)|bf16|f8e4m3|f8e5m2)$"))
((identifier) @type (#match? @type "^[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*$"))
((identifier) @constant (#match? @constant "^[A-Z][A-Z0-9_]+$"))

[
  "fn" "class" "struct" "union" "interface" "enum" "extend" "type"
  "module" "test" "macro" "import" "ffi" "var" "const" "static" "thread"
  "eval" "inline" "virtual" "override" "final" "async" "unsafe" "mutable"
  "volatile" "atomic" "derives" "impl" "requires" "where" "op" "as"
  "pub" "priv" "prot"
  "if" "else" "while" "loop" "for" "in" "match" "case" "default"
  "break" "continue" "return" "try" "catch" "finally" "panic" "yield"
  "assert" "await" "spawn" "delete"
  "sizeof" "alignof" "typeof"
] @keyword

[
  "and" "or" "xor" "not" "bitand" "bitor" "not_eq" "compl"
  "and_eq" "or_eq" "xor_eq"
] @keyword

(boolean) @boolean
(null) @constant
(builtin) @constant
(self) @variable.special
(wildcard_pattern) @variable.special
(kind_bound) @keyword
(special_body) @keyword

(number) @number
(float) @number
(tuple_index) @number
(string_literal) @string
(raw_string_literal) @string
(multiline_string_literal) @string
(char) @string
(raw_block) @embedded

; attributes / macros
(annotation "@" @attribute name: (_) @attribute)
(attributed_expr "@" @attribute name: (_) @attribute)
(hash_attribute) @attribute
(macro_decl name: (identifier) @function)
(macro_invocation name: (identifier) @function)
(macro_type (identifier) @function)

; declarations
(function_decl name: (identifier) @function)
(function_decl (operator_name) @operator)
(param name: (identifier) @variable.parameter)
(macro_param (identifier) @variable.parameter)
(capture (identifier) @variable.parameter)
(generic_param name: (identifier) @type)
(class_decl name: (identifier) @type)
(struct_decl name: (identifier) @type)
(union_decl name: (identifier) @type)
(interface_decl name: (identifier) @type)
(enum_decl name: (identifier) @type)
(type_alias_decl name: (identifier) @type)
(enum_variant name: (identifier) @variant)
(field_spec name: (identifier) @property)
(module_decl name: (path (identifier) @type))
(module_pin (path (identifier) @type))
(import_path (identifier) @type)
(labeled_stmt label: (identifier) @label)

; types
(path_type_segment name: (identifier) @type)

; expressions
(call_expr function: (identifier_expr (identifier) @function))
(call_expr function: (member_expr member: (identifier) @function))
(call_expr function: (scope_expr member: (identifier) @function))
(call_expr function: (generic_path_expr name: (identifier_expr (identifier) @function)))
(member_expr member: (identifier) @property)
(field_initializer name: (identifier) @property)
(field_initializer_tail name: (identifier) @property)
(named_argument name: (identifier) @property)
(dotted_variant_expr name: (identifier) @variant)
(dotted_pattern name: (identifier) @variant)

[
  "=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" "@="
  "+" "-" "*" "/" "%" "^^" "<<" "^" "|" "&" "~" "!" "?" "??"
  "==" "!=" "===" "<=>" "<=" "&&" "||" "++" "--" ".." "..=" "..."
  "->" "=>" ".*" "->*" "?.*" "?->*" "?." "?->"
] @operator

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" ":" "::" "."] @punctuation.delimiter
