/**
 * @file Tree-sitter grammar for the Kairo programming language
 * @license Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *
 * Mirrors Compiler/Parser/{ASTParse,DeclParse,StmtParse,ExprParse,TypeParse,
 * PatternParse}.k and Compiler/Lexer/Lexer.k.
 *
 * Statements are newline-terminated. The external scanner emits `_newline`
 * only where the grammar accepts a terminator (so never inside brackets, the
 * nl_depth rule) and only when the next line does not open with a
 * continuation token (infix operators outside the unary set, `.`, `->`, `?.`,
 * `?->`, `=>`, `else`, `catch`, `requires`, `where`, `derives`, `impl`).
 */

const PREC = {
  OPEN: -1,        // trailing if / try / closure expressions
  ASSIGN: 1,
  COALESCE: 2,
  RANGE: 3,
  OR: 4,
  AND: 5,
  BIT_OR: 6,
  BIT_XOR: 7,
  BIT_AND: 8,
  EQUALITY: 9,
  COMPARE: 10,
  SHIFT: 11,
  ADD: 12,
  MUL: 13,
  POWER: 14,
  PTR_MEMBER: 15,
  CAST: 16,
  PREFIX: 17,
  POSTFIX: 18,
};

const ASSIGN_OPS = ['and_eq', 'or_eq', 'xor_eq', '=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '@='];

module.exports = grammar({
  name: 'kairo',

  externals: $ => [
    $._newline,
    $.block_comment,
    $.raw_block,
    $._init_open,
    $._dot_float,
    $._fstring,
    $._error_sentinel,
  ],

  extras: $ => [
    /\s/,
    $.line_comment,
    $.block_comment,
  ],

  word: $ => $.identifier,

  supertypes: $ => [
    $._expression,
    $._statement,
    $._type,
    $._pattern,
  ],

  inline: $ => [
    $._terminator,
    $._call_arg,
  ],

  // GLR conflicts. ASTParse resolves these with tentative parsing and the
  // disambiguation table; here GLR forks and dynamic precedence picks.
  conflicts: $ => [
    [$._binding_const, $._type_qualifier],
    [$.storage_head, $.unary_expr, $._type_qualifier],
    [$._decl_modifier, $.storage_head, $.unary_expr, $._type_qualifier],
    [$._decl_modifier, $.unary_expr, $._type_qualifier],
    [$._decl_modifier, $.unsafe_expr, $._type_qualifier],
    [$.storage_head, $._type_qualifier],
    [$._decl_modifier, $.storage_head, $._type_qualifier],
    [$._decl_modifier, $._type_qualifier],
    [$.unary_expr, $._type_qualifier],
    [$.unsafe_expr, $._type_qualifier],
    // generics vs comparison: `Foo<T>(x)` vs `a < b > (x)`
    [$._expression, $.generic_path_expr],
    [$.path_type_segment, $.identifier_expr],
    [$._member_name, $.path_type_segment],
    [$._member_target],
    [$.assignment_expr, $.binary_expr],
    [$.assignment_expr, $.binary_expr, $.range_expr],

    // type vs expression (generic args, sizeof, casts, params)
    [$._type_only, $._type_atom],
    [$._type, $.pack_type],
    [$.qualified_type],
    [$.qualified_type, $.annotated_type],
    [$.qualified_type, $.annotated_type, $.function_type],
    [$.param, $.type_qualifiers],
    [$.param, $.path_type_segment],
    [$.param, $.qualified_type, $.annotated_type],
    [$.param, $.function_type],
    [$.parameter_list, $.function_type],
    [$.argument_list, $.paren_expr],
    [$.argument_list, $.tuple_expr],
    [$.operator_name],

    // leading modifiers: `eval fn` / `eval x` / `eval var`, `const T` / `const x`
    [$.decl_modifiers],
    [$._decl_modifier, $.storage_head],
    [$._decl_modifier, $.unary_expr],
    [$._decl_modifier, $.unsafe_expr],
    [$._decl_modifier, $.storage_head, $.unary_expr],
    [$._decl_modifier, $.storage_head, $.type_qualifiers],
    [$._decl_modifier, $.unary_expr, $.type_qualifiers],
    [$._decl_modifier, $.unsafe_expr, $.type_qualifiers],
    [$._decl_modifier, $.storage_head, $.unary_expr, $.type_qualifiers],
    [$.storage_head, $.unary_expr],
    [$.storage_head, $.unary_expr, $.type_qualifiers],
    [$.yield_stmt, $.type_qualifiers],
    [$.destructuring_decl, $.type_qualifiers],
    [$.fn_modifiers],
    [$.binding],

    // `@attr fn f()` vs `@attr expr`
    [$.annotation],
    [$.annotation, $.attributed_expr],

    // `x as T` vs `x as const y { ... }`
    [$.type_qualifiers, $.binding_spec],

    // `if Foo {}`: empty initializer vs block; `{ x }` block vs set
    [$.initializer_expr, $._expression],
    [$.block, $.set_expr],
    [$.expression_stmt, $.set_expr],
    [$.declaration_list, $.set_expr],
    [$.dotted_variant_expr, $.field_initializer_tail],

    // patterns share their lead with expressions
    [$._expression, $._pattern_lead],
    [$._expression, $.literal_pattern, $._pattern_lead],
    [$.literal_pattern, $._pattern_lead],
    [$.initializer_expr, $._pattern_lead],
    [$.dotted_variant_expr, $.dotted_pattern],
    [$.identifier_expr, $.slice_pattern],
    [$.list_expr, $.slice_pattern],

    // `name:` label vs expression
    [$.labeled_stmt, $.identifier_expr],
    [$.labeled_stmt, $.identifier_expr, $.path_type_segment],

    [$.enum_body],
    [$.import_path],
  ],

  rules: {
    source_file: $ => repeat(choice(prec(1, seq($._item, $._terminator)), prec.dynamic(-1, $._item), $._terminator)),

    _item: $ => choice(
      $._declaration,
      $._statement,
    ),

    _terminator: $ => choice($._newline, ';'),

    // =====================================================================
    // Annotations / modifiers
    // =====================================================================
    annotation: $ => prec(PREC.PREFIX, seq(
      '@',
      field('name', $._annotation_name),
      optional(field('arguments', $.argument_list)),
    )),

    _annotation_name: $ => choice($.identifier, alias(choice('inline', 'const', 'unsafe', 'static', 'final', 'override', 'virtual', 'eval', 'type'), $.identifier)),

    hash_attribute: $ => seq('#[', $.identifier, optional($.argument_list), ']'),

    visibility: _ => choice('pub', 'priv', 'prot'),

    decl_modifiers: $ => repeat1($._decl_modifier),

    _decl_modifier: $ => prec(PREC.PREFIX, choice(
      $.annotation,
      $.hash_attribute,
      $.visibility,
      'static', 'virtual', 'override', 'final', 'inline', 'eval', 'const', 'async', 'unsafe', 'mutable',
    )),

    // =====================================================================
    // Declarations
    // =====================================================================
    _declaration: $ => choice(
      $.function_decl,
      $.class_decl,
      $.struct_decl,
      $.union_decl,
      $.interface_decl,
      $.enum_decl,
      $.extend_decl,
      $.type_alias_decl,
      $.module_decl,
      $.module_pin,
      $.test_decl,
      $.macro_decl,
      $.import_decl,
      $.ffi_decl,
      $.visibility_block,
      $.eval_block,
      $.variable_decl,
      $.destructuring_decl,
    ),

    declaration_list: $ => seq('{', repeat(choice(prec(1, seq($._member, $._terminator)), prec.dynamic(-1, $._member), $._terminator)), '}'),

    _member: $ => choice($._declaration, $._statement),

    visibility_block: $ => seq(
      $.visibility,
      $.declaration_list,
    ),

    eval_block: $ => seq('eval', $.declaration_list),

    module_pin: $ => prec.right(seq(optional($.decl_modifiers), 'module', $.path)),

    module_decl: $ => seq(
      optional($.decl_modifiers),
      'module',
      optional(field('name', $.path)),
      field('body', $.declaration_list),
    ),

    test_decl: $ => seq(
      optional($.decl_modifiers),
      'test',
      optional(field('label', $.string)),
      field('body', $.block),
    ),

    path: $ => prec.right(seq(optional('::'), sep1($.identifier, '::'))),

    // -- generics --------------------------------------------------------
    generic_params: $ => seq(
      '<',
      optional(seq(commaSep1($.generic_param))),
      '>',
    ),

    generic_param: $ => choice(
      seq(
        choice('eval', 'const'),
        field('name', $.identifier),
        ':',
        field('type', $._type),
        optional(seq('=', field('default', $._generic_arg))),
      ),
      seq(
        optional('...'),
        field('name', $.identifier),
        optional(seq(':', field('kind', $.kind_bound))),
        repeat($.heritage),
        optional(seq('=', field('default', $._generic_arg))),
      ),
    ),

    kind_bound: _ => choice('class', 'struct', 'enum', 'union', 'type'),

    heritage: $ => prec.right(seq(
      choice('derives', 'impl'),
      sep1($.heritage_edge, ','),
    )),

    heritage_edge: $ => seq(
      optional('virtual'),
      optional($.visibility),
      field('base', $._type),
    ),

    requires_clause: $ => seq('requires', field('condition', $._expression)),
    where_clause: $ => seq('where', field('condition', $._expression)),

    // -- functions ---------------------------------------------------------
    function_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'fn',
      optional(field('generics', $.generic_params)),
      field('name', $._fn_name),
      field('parameters', $.parameter_list),
      optional($.fn_modifiers),
      optional(seq('->', field('return_type', $._return_type))),
      optional($.requires_clause),
      optional($.where_clause),
      optional(field('body', $._fn_body)),
    )),

    _fn_name: $ => seq(
      repeat(seq(choice($.identifier, alias('Self', $.identifier)), optional($.generic_args), '::')),
      choice(
        seq('op', field('operator', $.operator_name)),
        seq(choice($.identifier, alias('self', $.identifier), alias('Self', $.identifier)), optional(field('specialization', $.generic_args))),
      ),
    ),

    operator_name: _ => choice(
      seq('(', ')'),
      seq('[', ']'),
      seq('<', '>'),
      seq('>', token.immediate('>')),
      seq('>', token.immediate('>'), token.immediate('=')),
      seq('>', token.immediate('=')),
      '+', '-', '*', '/', '%', '^^', '<', '>', '<<', 'and', 'or', 'xor', 'bitand', 'bitor', 'not', 'compl', 'not_eq', 'and_eq', 'or_eq', 'xor_eq',
      '^', '|', '&', '~', '!',
      '==', '!=', '<=>', '===', '&&', '||', '<=', '>=',
      '++', '--', 'l++', 'r++', 'l--', 'r--',
      '=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=',
      '->', '?', '..', '..=', '...', '??',
      'in', 'as', 'await', 'spawn', 'thread', 'delete', 'yield', 'panic', 'new',
    ),

    _return_type: $ => choice('!', $._type),

    parameter_list: $ => seq('(', commaSep($.param), ')'),

    param: $ => choice(
      seq(repeat($.annotation), optional($._binding_const), alias('self', $.self)),
      seq(
        repeat($.annotation),
        optional($._binding_const),
        optional('...'),
        optional(seq(field('name', $.identifier), optional('?'), ':')),
        field('type', $._type),
        optional(seq('=', field('default', $._expression))),
      ),
      seq(repeat($.annotation), '...'),
    ),

    fn_modifiers: $ => repeat1(choice(
      'const', 'volatile', 'unsafe', 'eval', 'async', 'final', 'inline', 'override', 'virtual', 'static',
      $.panic_clause,
    )),

    panic_clause: $ => prec.right(seq('panic', optional($.panic_set))),

    panic_set: $ => seq('(', commaSep($._type), ')'),

    _fn_body: $ => choice(
      $.block,
      seq('=', choice(alias(choice('default', 'delete', 'virtual'), $.special_body), $._expression)),
    ),

    // -- type declarations ----------------------------------------------
    class_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'class',
      $._type_head,
      optional(field('body', $.type_body)),
    )),

    struct_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'struct',
      $._type_head,
      optional(field('body', $.type_body)),
    )),

    union_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'union',
      $._type_head,
      optional(field('body', $.type_body)),
    )),

    interface_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'interface',
      optional(field('generics', $.generic_params)),
      field('name', $.identifier),
      optional(field('specialization', $.generic_args)),
      optional(seq('derives', field('derives', sep1($._expression, ',')))),
      optional($.requires_clause),
      optional(field('body', $.type_body)),
    )),

    _type_head: $ => seq(
      optional(field('generics', $.generic_params)),
      field('name', $.identifier),
      optional(field('specialization', $.generic_args)),
      repeat($.heritage),
      optional($.requires_clause),
    ),

    extend_decl: $ => seq(
      optional($.decl_modifiers),
      'extend',
      optional(field('generics', $.generic_params)),
      field('target', $._type),
      repeat($.heritage),
      optional($.requires_clause),
      field('body', $.type_body),
    ),

    type_body: $ => $.declaration_list,

    enum_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'enum',
      optional(field('generics', $.generic_params)),
      field('name', $.identifier),
      optional(field('specialization', $.generic_args)),
      optional(seq('derives', field('underlying', $._type))),
      optional($.requires_clause),
      optional(field('body', $.enum_body)),
    )),

    enum_body: $ => seq(
      '{',
      repeat($._newline),
      optional(seq(
        sep1($.enum_variant, seq(choice(',', $._newline), repeat($._newline))),
        optional(','),
        repeat($._newline),
      )),
      '}',
    ),

    enum_variant: $ => seq(
      repeat($.annotation),
      field('name', $.identifier),
      optional(choice(
        seq('{', commaSep($.field_spec), '}'),
        seq('(', commaSep($._type), ')'),
        seq('=', field('value', $._expression)),
      )),
    ),

    field_spec: $ => seq(field('name', $.identifier), ':', field('type', $._type)),

    type_alias_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'type',
      optional(field('generics', $.generic_params)),
      field('name', $.identifier),
      optional(field('specialization', $.generic_args)),
      optional(seq('impl', commaSep1($._type))),
      optional(seq('=', field('value', $._type))),
    )),

    // -- macros ------------------------------------------------------------
    macro_decl: $ => choice(
      seq(
        optional($.decl_modifiers),
        'macro',
        field('name', $.identifier),
        token.immediate('!'),
        optional(seq('(', commaSep($.macro_param), ')')),
        field('body', $.block),
      ),
      seq(
        optional($.decl_modifiers),
        'macro',
        '@',
        field('name', $.identifier),
        optional(field('parameters', $.parameter_list)),
        optional(seq('->', field('return_type', $._type))),
        field('body', $.block),
      ),
    ),

    macro_param: $ => choice(
      seq('...', optional($.identifier)),
      seq($.identifier, '...'),
      seq($.identifier, optional(seq(':', $._type)), optional(seq('=', $._expression))),
    ),

    // -- imports / ffi -----------------------------------------------------
    import_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'import',
      optional('module'),
      field('path', $.import_path),
      optional(seq('as', field('alias', $.identifier), optional(token.immediate('!')))),
    )),

    import_path: $ => seq(
      optional('::'),
      $._import_segment,
      repeat(seq('::', $._import_segment)),
      optional(seq('::', choice('*', $.import_list))),
    ),

    _import_segment: $ => seq($.identifier, optional(token.immediate('!'))),

    import_list: $ => seq('{', commaSep($.import_item), '}'),

    import_item: $ => choice(
      '*',
      seq(
        $._import_segment,
        repeat(seq('::', $._import_segment)),
        optional(seq('::', choice('*', $.import_list))),
        optional(seq('as', field('alias', $.identifier), optional(token.immediate('!')))),
      ),
    ),

    ffi_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      'ffi',
      field('language', $.string),
      choice(
        seq('import', field('header', $.string), optional(seq('as', field('alias', $.identifier)))),
        $.declaration_list,
        $._declaration,
      ),
    )),

    // -- variables -----------------------------------------------------------
    variable_decl: $ => prec.right(seq(
      optional($.decl_modifiers),
      $.storage_head,
      optional($.pointer_shorthand),
      field('name', $.identifier),
      optional('?'),
      optional(seq(':', field('type', $._type))),
      optional(seq('=', field('value', $._expression))),
    )),

    storage_head: _ => prec(PREC.PREFIX, choice(
      'var',
      seq('const', optional(choice(seq('static', optional('thread')), 'thread', 'eval'))),
      seq('static', optional('thread'), optional('const')),
      seq('thread', optional('const')),
      seq('eval', optional('const')),
    )),

    pointer_shorthand: _ => prec.right(seq(optional('unsafe'), repeat1('*'))),

    destructuring_decl: $ => seq(
      optional($.decl_modifiers),
      choice('var', 'const'),
      choice(
        seq('(', commaSep1($.binding), ')'),
        seq('{', commaSep1($.binding), '}'),
      ),
      optional(seq(':', $._type)),
      '=',
      field('value', $._expression),
    ),

    binding: $ => seq(
      optional(choice('var', $._binding_const)),
      optional(seq(optional('unsafe'), '*')),
      field('name', choice($.identifier, '_')),
      optional('?'),
      optional(seq(':', field('type', $._type))),
    ),

    binding_spec: $ => seq(
      choice('var', $._binding_const),
      choice($.binding, seq('(', commaSep1($.binding), ')')),
    ),

    // =====================================================================
    // Statements
    // =====================================================================
    _statement: $ => choice(
      $.expression_stmt,
      $.block,
      $.if_stmt,
      $.while_stmt,
      $.loop_stmt,
      $.for_stmt,
      $.match_stmt,
      $.return_stmt,
      $.break_stmt,
      $.continue_stmt,
      $.panic_stmt,
      $.yield_stmt,
      $.assert_stmt,
      $.try_stmt,
      $.finally_stmt,
      $.unsafe_block,
      $.inline_block,
      $.labeled_stmt,
      $.context_binding_stmt,
    ),

    block: $ => seq('{', repeat(choice(prec(1, seq($._member, $._terminator)), prec.dynamic(-1, $._member), $._terminator)), '}'),

    expression_stmt: $ => $._expression,

    if_stmt: $ => prec.right(seq(
      optional(choice('eval', $.annotation)),
      'if',
      field('condition', $._expression),
      field('consequence', $.block),
      optional(seq(
        optional($.annotation),
        'else',
        field('alternative', choice($.if_stmt, $.block)),
      )),
    )),

    while_stmt: $ => seq(
      'while',
      field('condition', $._expression),
      field('body', $.block),
    ),

    loop_stmt: $ => seq('loop', field('body', $.block)),

    for_stmt: $ => seq(
      optional('eval'),
      'for',
      choice(
        seq(
          optional(choice('var', $._binding_const)),
          field('binding', choice(
            $.binding,
            seq('(', commaSep1($.binding), ')'),
          )),
          'in',
          field('iterable', $._expression),
        ),
        seq(
          field('initializer', alias($.for_init, $.variable_decl)),
          ';',
          field('condition', optional($._expression)),
          ';',
          field('update', optional($._expression)),
        ),
      ),
      field('body', $.block),
    ),

    for_init: $ => seq(
      choice('var', 'const'),
      $.binding,
      optional(seq('=', field('value', $._expression))),
    ),

    labeled_stmt: $ => seq(
      field('label', $.identifier),
      ':',
      choice($.while_stmt, $.loop_stmt, $.for_stmt),
    ),

    match_stmt: $ => seq(
      'match',
      field('value', $._expression),
      field('body', $.match_body),
    ),

    match_body: $ => seq(
      '{',
      repeat(choice($.match_arm, $._terminator, ',')),
      '}',
    ),

    match_arm: $ => prec.right(seq(
      choice(
        seq('case', commaSep1($._pattern), optional($.where_clause)),
        'default',
      ),
      choice(
        field('body', $.block),
        seq('=>', field('value', $._expression)),
      ),
    )),

    return_stmt: $ => prec.right(seq('return', optional($._expression))),
    break_stmt: $ => prec.right(seq('break', optional($.identifier))),
    continue_stmt: $ => prec.right(seq('continue', optional($.identifier))),
    panic_stmt: $ => prec.right(seq('panic', optional($._expression))),
    yield_stmt: $ => prec.right(seq('yield', optional($._expression))),

    assert_stmt: $ => prec.right(seq(
      'assert',
      optional('static'),
      field('condition', $._expression),
      optional(seq(',', field('message', $._expression))),
    )),

    try_stmt: $ => prec.right(seq(
      'try',
      field('body', $.block),
      repeat1($.catch_clause),
      optional($.finally_clause),
    )),

    catch_clause: $ => seq(
      'catch',
      optional(choice('var', $._binding_const)),
      optional(seq(
        field('name', choice($.identifier, '_')),
        optional(seq(':', field('type', $._type))),
      )),
      field('body', $.block),
    ),

    finally_clause: $ => seq('finally', field('body', $.block)),
    finally_stmt: $ => seq('finally', field('body', $.block)),

    unsafe_block: $ => seq('unsafe', $.block),

    inline_block: $ => seq('inline', field('language', $.string), field('body', $.raw_block)),

    context_binding_stmt: $ => seq(
      field('value', $._expression),
      'as',
      field('binding', $.binding_spec),
      field('body', $.block),
    ),

    // =====================================================================
    // Expressions
    // =====================================================================
    _expression: $ => choice(
      $.assignment_expr,
      $.binary_expr,
      $.range_expr,
      $.cast_expr,
      $.unary_expr,
      $.attributed_expr,
      $.postfix_expr,
      $.call_expr,
      $.index_expr,
      $.member_expr,
      $.scope_expr,
      $.initializer_expr,
      $.identifier_expr,
      $.generic_path_expr,
      $.global_expr,
      $.dotted_variant_expr,
      $.macro_invocation,
      $.sizeof_expr,
      $.typeof_expr,
      $.number,
      $.float,
      $.string,
      $.char,
      $.boolean,
      $.null,
      $.paren_expr,
      $.tuple_expr,
      $.stmt_expr,
      $.list_expr,
      $.set_expr,
      $.map_expr,
      $.anon_initializer_expr,
      $.closure_expr,
      $.if_expr,
      $.try_expr,
      $.match_expr,
      $.unsafe_expr,
      $.builtin,
    ),

    assignment_expr: $ => prec.right(PREC.ASSIGN, seq(
      field('left', $._expression),
      field('operator', choice(...ASSIGN_OPS, seq('>', token.immediate('>'), token.immediate('=')))),
      field('right', $._expression),
    )),

    binary_expr: $ => {
      const table = [
        [prec.right, PREC.COALESCE, '??'],
        [prec.left, PREC.OR, choice('||', 'or')],
        [prec.left, PREC.AND, choice('&&', 'and')],
        [prec.left, PREC.BIT_OR, choice('|', 'bitor')],
        [prec.left, PREC.BIT_XOR, choice('^', 'xor')],
        [prec.left, PREC.BIT_AND, choice('&', 'bitand')],
        [prec.left, PREC.EQUALITY, choice('==', '!=', '===', 'not_eq')],
        [prec.left, PREC.COMPARE, choice('<', '>', '<=', seq('>', token.immediate('=')), '<=>', 'in', seq('not', 'in'))],
        [prec.left, PREC.SHIFT, choice('<<', seq('>', token.immediate('>')))],
        [prec.left, PREC.ADD, choice('+', '-')],
        [prec.left, PREC.MUL, choice('*', '/', '%')],
        [prec.right, PREC.POWER, '^^'],
        [prec.left, PREC.PTR_MEMBER, choice('.*', '->*', '?.*', '?->*')],
      ];
      return choice(
        ...table.map(([fn, p, op]) => fn(p, seq(
          field('left', $._expression),
          field('operator', op),
          field('right', $._expression),
        ))),
        prec(PREC.COMPARE, seq(
          field('left', $._expression),
          field('operator', choice('impl', 'derives')),
          field('right', $._type),
        )),
      );
    },

    range_expr: $ => prec.right(PREC.RANGE, choice(
      seq(field('start', $._expression), choice('..', '..='), optional(field('end', $._expression))),
      seq(choice('..', '..='), field('end', $._expression)),
      '..',
    )),

    cast_expr: $ => prec.left(PREC.CAST, seq(
      field('value', $._expression),
      'as',
      optional('static'),
      field('type', $._type),
    )),

    unary_expr: $ => prec.right(PREC.PREFIX, choice(
      seq(
        field('operator', choice(
          '!', 'not', '+', '-', '~', 'compl', '&', '*', '++', '--', '...',
          'await', 'spawn', 'thread', 'eval', 'yield',
        )),
        field('operand', $._expression),
      ),
      seq('delete', optional(seq('[', ']')), field('operand', $._expression)),
    )),

    unsafe_expr: $ => prec.right(PREC.PREFIX, seq('unsafe', field('operand', $._expression))),

    sizeof_expr: $ => prec.right(PREC.PREFIX, seq(
      choice('sizeof', 'alignof'),
      choice(seq('(', choice($._type, $._expression), ')'), $._expression, $._type_only),
    )),

    typeof_expr: $ => prec.right(PREC.PREFIX, seq('typeof', field('operand', $._expression))),

    attributed_expr: $ => prec.right(PREC.PREFIX, seq(
      '@',
      field('name', $._annotation_name),
      optional(field('generics', $.generic_args)),
      optional(field('arguments', $.argument_list)),
      optional(field('operand', $._expression)),
    )),

    postfix_expr: $ => prec.left(PREC.POSTFIX, seq(
      field('operand', $._expression),
      field('operator', choice('++', '--', '...', '?', token.immediate('!'))),
    )),

    call_expr: $ => prec.left(PREC.POSTFIX, seq(
      field('function', $._expression),
      field('arguments', $.argument_list),
    )),

    argument_list: $ => seq('(', commaSep($._call_arg), ')'),

    _call_arg: $ => choice($.named_argument, $._expression, $._type_only),

    named_argument: $ => seq(field('name', $.identifier), ':', field('value', $._expression)),

    index_expr: $ => prec.left(PREC.POSTFIX, seq(
      field('value', $._expression),
      '[',
      commaSep(field('index', $._expression)),
      ']',
    )),

    member_expr: $ => prec.left(PREC.POSTFIX, seq(
      field('value', $._expression),
      choice('.', '->', '?.', '?->'),
      $._member_target,
    )),

    scope_expr: $ => prec.left(PREC.POSTFIX, seq(
      field('scope', $._expression),
      '::',
      choice($._member_target, field('generics', $.generic_args)),
    )),

    _member_target: $ => choice(
      seq('op', field('operator', $.operator_name), optional($.generic_args)),
      field('index', alias(choice($._decimal, $._tuple_float), $.tuple_index)),
      seq(field('member', $._member_name), optional(field('generics', $.generic_args))),
    ),

    _member_name: $ => choice($.identifier, alias(choice('self', 'Self', 'type', 'delete'), $.identifier), $.builtin),

    initializer_expr: $ => prec.dynamic(-1, seq(
      field('type', choice($.identifier_expr, $.generic_path_expr, $.scope_expr, $.global_expr, $.dotted_variant_expr)),
      $.initializer_list,
    )),

    initializer_list: $ => choice(
      seq(alias($._init_open, '{'), commaSep1($.field_initializer), '}'),
      seq('{', '}'),
    ),

    field_initializer: $ => seq(
      choice(field('name', $.identifier), seq('.', field('name', $.identifier))),
      ':',
      field('value', $._expression),
    ),

    identifier_expr: $ => choice($.identifier, alias('self', $.self), alias('Self', $.identifier)),

    generic_path_expr: $ => prec.dynamic(1, seq(
      field('name', $.identifier_expr),
      field('generics', $.generic_args),
    )),

    global_expr: $ => prec.right(seq('::', $._member_name, optional($.generic_args))),

    dotted_variant_expr: $ => seq('.', field('name', $.identifier)),

    macro_invocation: $ => prec.right(PREC.POSTFIX, seq(
      field('name', $.identifier),
      token.immediate('!'),
      optional(field('arguments', $.macro_arguments)),
    )),

    macro_arguments: $ => seq('(', commaSep(choice($._expression, $._type_only, $.named_argument, $.block)), ')'),

    paren_expr: $ => seq('(', $._expression, ')'),

    tuple_expr: $ => seq(
      '(',
      choice(
        seq($._expression, ','),
        seq($._expression, repeat1(seq(',', $._expression)), optional(',')),
      ),
      ')',
    ),

    stmt_expr: $ => seq('(', $.block, ')'),

    list_expr: $ => seq('[', commaSep($._expression), ']'),

    set_expr: $ => seq('{', commaSep($._expression), '}'),

    map_expr: $ => seq('{', commaSep1($.map_entry), '}'),

    map_entry: $ => seq(field('key', $._expression), ':', field('value', $._expression)),

    anon_initializer_expr: $ => seq('{', commaSep1(seq('.', $.field_initializer_tail)), '}'),

    field_initializer_tail: $ => seq(field('name', $.identifier), ':', field('value', $._expression)),

    closure_expr: $ => prec.right(PREC.OPEN, seq(
      'fn',
      optional(field('generics', $.generic_params)),
      optional(field('parameters', $.parameter_list)),
      optional(field('captures', $.capture_list)),
      optional($.fn_modifiers),
      optional(seq('->', field('return_type', $._return_type))),
      choice(
        field('body', $.block),
        seq('=', field('body', $._expression)),
      ),
    )),

    capture_list: $ => choice('||', seq('|', commaSep($.capture), '|')),

    capture: $ => choice(
      seq(optional($._binding_const), optional('*'), choice($.identifier, alias('self', $.self))),
      seq(optional($._binding_const), '*'),
      '=',
    ),

    if_expr: $ => prec.right(PREC.OPEN, seq(
      'if',
      field('condition', $._expression),
      '=>',
      field('consequence', $._expression),
      repeat(seq('else', 'if', $._expression, '=>', $._expression)),
      optional(seq('else', '=>', field('alternative', $._expression))),
    )),

    try_expr: $ => prec.right(PREC.OPEN, seq(
      'try',
      field('operand', $._expression),
      repeat1($.catch_arm),
    )),

    catch_arm: $ => prec.right(PREC.OPEN, seq(
      'catch',
      optional(choice('var', $._binding_const)),
      optional(seq(
        field('name', choice($.identifier, '_')),
        optional(seq(':', field('type', $._type))),
      )),
      '=>',
      field('value', choice($._expression, $.block, $.return_stmt, $.break_stmt, $.continue_stmt, $.panic_stmt)),
    )),

    match_expr: $ => prec(-2, seq('match', field('value', $._expression), field('body', $.match_body))),

    builtin: _ => choice('__file__', '__line__', '__column__', '__function__', '__module__'),

    // =====================================================================
    // Types
    // =====================================================================
    _type: $ => choice(
      $.qualified_type,
      $._type_atom,
    ),

    qualified_type: $ => prec.right(seq(
      repeat($.annotation),
      $.type_qualifiers,
      $._type_atom,
    )),

    type_qualifiers: $ => repeat1($._type_qualifier),

    // `const` that introduces a binding, at the same precedence as the type
    // qualifier so `const x: T` vs `const T` forks instead of resolving statically
    _binding_const: _ => prec(PREC.PREFIX, 'const'),

    _type_qualifier: _ => prec(PREC.PREFIX, choice('const', 'volatile', 'atomic', 'unsafe', 'eval', 'mutable', 'yield', 'async', 'thread')),

    // a type that is not also an expression (used where both are accepted)
    _type_only: $ => choice(
      $.qualified_type,
      $.pointer_type,
      $.nullable_type,
      $.array_type,
      $.map_type,
      $.function_type,
    ),

    _type_atom: $ => choice(
      $.path_type,
      $.macro_type,
      $.pointer_type,
      $.nullable_type,
      $.pack_type,
      $.tuple_type,
      $.paren_type,
      $.list_type,
      $.array_type,
      $.set_type,
      $.map_type,
      $.function_type,
      $.typeof_type,
      $.annotated_type,
    ),

    annotated_type: $ => prec.right(seq($.annotation, $._type_atom)),

    path_type: $ => prec.right(seq(
      optional('::'),
      $.path_type_segment,
      repeat(seq('::', choice($.path_type_segment, field('generics', $.generic_args)))),
    )),

    path_type_segment: $ => prec.right(seq(
      field('name', choice($.identifier, alias('Self', $.identifier), alias('self', $.identifier))),
      optional(field('generics', $.generic_args)),
    )),

    macro_type: $ => seq($.identifier, token.immediate('!'), $.macro_arguments),

    pointer_type: $ => prec.right(seq(choice('*', '&'), $._type)),
    nullable_type: $ => prec.left(1, seq($._type_atom, '?')),
    pack_type: $ => prec.left(seq($._type_atom, '...')),
    paren_type: $ => seq('(', $._type, ')'),
    tuple_type: $ => seq('(', optional(seq($._type, ',', commaSep($._type))), ')'),
    list_type: $ => seq('[', $._type, ']'),
    array_type: $ => seq('[', field('element', $._type), ';', optional(field('size', $._expression)), ']'),
    set_type: $ => seq('{', $._type, '}'),
    map_type: $ => seq('{', field('key', $._type), ':', field('value', $._type), '}'),

    function_type: $ => prec.right(seq(
      'fn',
      '(',
      commaSep(seq(repeat($.annotation), optional(seq($.identifier, ':')), $._type)),
      ')',
      repeat(choice($.annotation, 'const', 'volatile', 'unsafe', 'eval', 'async', $.panic_clause)),
      optional(seq('->', $._return_type)),
    )),

    typeof_type: $ => prec.right(seq('typeof', $._expression)),

    generic_args: $ => prec.dynamic(2, seq(
      '<',
      commaSep($._generic_arg_entry),
      '>',
    )),

    _generic_arg_entry: $ => choice(
      $._generic_arg,
      seq(field('name', $.identifier), ':', $._generic_arg),
    ),

    _generic_arg: $ => choice(prec.dynamic(1, $._type), prec.left(PREC.SHIFT, $._expression)),

    // =====================================================================
    // Patterns
    // =====================================================================
    _pattern: $ => choice(
      $.wildcard_pattern,
      $.binding_pattern,
      $.tuple_pattern,
      $.slice_pattern,
      $.dotted_pattern,
      $.range_pattern,
      $.constructor_pattern,
      $.literal_pattern,
    ),

    wildcard_pattern: _ => '_',

    binding_pattern: $ => prec.right(seq(
      choice('var', $._binding_const),
      optional(seq(optional('unsafe'), '*')),
      field('name', choice($.identifier, '_')),
      optional('?'),
      optional(seq(':', field('type', $._type))),
    )),

    tuple_pattern: $ => seq('(', commaSep($._pattern), ')'),

    slice_pattern: $ => seq('[', commaSep(choice(seq('..', optional($.identifier)), $._pattern)), ']'),

    dotted_pattern: $ => prec.right(seq(
      '.',
      field('name', $.identifier),
      optional(seq('(', commaSep($._pattern), ')')),
    )),

    range_pattern: $ => prec.right(choice(
      seq(field('start', $._pattern_lead), choice('..', '..='), optional(field('end', $._expression))),
      seq(choice('..', '..='), field('end', $._expression)),
    )),

    constructor_pattern: $ => prec.right(seq(
      field('type', $._pattern_lead),
      optional(seq('(', commaSep($._pattern), ')')),
    )),

    literal_pattern: $ => choice(
      seq(optional('-'), choice($.number, $.float)),
      $.string,
      $.char,
      $.boolean,
      $.null,
    ),

    _pattern_lead: $ => choice(
      seq(optional('-'), choice($.number, $.float)),
      $.string,
      $.char,
      $.boolean,
      $.null,
      $.identifier_expr,
      $.generic_path_expr,
      $.scope_expr,
      $.global_expr,
    ),

    // =====================================================================
    // Lexical
    // =====================================================================
    identifier: _ => /[\p{XID_Start}_#][\p{XID_Continue}#]*/u,

    boolean: _ => choice('true', 'false'),
    null: _ => 'null',

    number: $ => choice($._decimal, $._radix_int),

    _decimal: _ => token(seq(/[0-9][0-9_]*/, optional(/[a-zA-Z][a-zA-Z0-9_]*/))),
    _radix_int: _ => token(seq(
      choice(
        seq(/0[xX][0-9a-fA-F_]+(\.[0-9a-fA-F_]*)?[pP][+-]?[0-9_]+/, optional(/[a-zA-Z][a-zA-Z0-9_]*/)),
        seq(/0[xX][0-9a-fA-F_]+/, optional(/[g-zG-Z_][a-zA-Z0-9_]*/)),
        seq(/0[bB][01_]+/, optional(/[a-zA-Z][a-zA-Z0-9_]*/)),
        seq(/0[oO][0-7_]+/, optional(/[a-zA-Z][a-zA-Z0-9_]*/)),
      ),
    )),

    float: $ => choice($._tuple_float, $._dot_float),

    _tuple_float: _ => token(choice(
      seq(/[0-9][0-9_]*\.[0-9][0-9_]*/, optional(/[eE][+-]?[0-9_]+/), optional(/[a-zA-Z][a-zA-Z0-9_]*/)),
      seq(/[0-9][0-9_]*[eE][+-]?[0-9_]+/, optional(/[a-zA-Z][a-zA-Z0-9_]*/)),
    )),

    string: $ => prec.right(repeat1($._string_piece)),

    _string_piece: $ => choice($.string_literal, alias($._fstring, $.string_literal), $.raw_string_literal, $.multiline_string_literal),

    multiline_string_literal: _ => token(seq(
      optional(choice('f', 'r', 'b', 'rf', 'fr', 'rb', 'br')),
      '"""',
      repeat(choice(/[^"\\]/, /\\(.|\n)/, /"[^"]/, /""[^"]/)),
      '"""',
    )),

    string_literal: _ => token(seq(
      optional('b'),
      '"',
      repeat(choice(/[^"\\\n]+/, /\\(.|\n)/)),
      '"',
      optional(token.immediate(/[a-zA-Z_][a-zA-Z0-9_]*/)),
    )),

    raw_string_literal: _ => token(seq(
      choice('r', 'rf', 'fr', 'rb', 'br'),
      '"',
      /[^"]*/,
      '"',
    )),

    char: _ => token(seq(
      optional(choice('f', 'r', 'b')),
      '\'',
      repeat1(choice(/[^'\\\n]/, /\\./, /\\[xuU]\{?[0-9a-fA-F]+\}?/)),
      '\'',
    )),

    line_comment: _ => token(seq('//', /[^\n]*/)),
  },
});

function sep1(rule, sep) {
  return seq(rule, repeat(seq(sep, rule)));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)), optional(','));
}

function commaSep(rule) {
  return optional(commaSep1(rule));
}
