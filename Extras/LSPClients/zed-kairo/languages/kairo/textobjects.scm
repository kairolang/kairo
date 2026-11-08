(function_decl body: (_) @function.inside) @function.around
(closure_expr body: (_) @function.inside) @function.around
(class_decl body: (_) @class.inside) @class.around
(struct_decl body: (_) @class.inside) @class.around
(interface_decl body: (_) @class.inside) @class.around
(enum_decl body: (_) @class.inside) @class.around
(line_comment)+ @comment.around
(block_comment) @comment.around
