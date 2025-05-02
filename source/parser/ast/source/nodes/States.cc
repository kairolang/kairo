//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0). You   //
//  are allowed to use, modify, redistribute, and create derivative works, even for commercial    //
//  purposes, provided that you give appropriate credit, and indicate if changes                  //
//  were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/   //
//                                                                                                //
//  SPDX-License-Identifier: CC-BY-4.0 // Copyright (c) 2024 (CC BY 4.0)                          //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//
///                                                                                              ///
///  @file States.cc                                                                             ///
///  @brief This file contains the entire logic to parse statements using a recursive descent    ///
///         parser. the parser adheres to an ll(1) grammar, which means it processes the input   ///
///         left-to-right and constructs the leftmost derivation using one token of lookahead.   ///
///                                                                                              ///
///  The parser is implemented using the `parse` method, which is a recursive descent parser     ///
///     that uses the token list to parse the Statement grammar.                                 ///
///                                                                                              ///
///  @code                                                                                       ///
///  Statement state(tokens);                                                                    ///
///  ParseResult<> node = state.parse();                                                         ///
///                                                                                              ///
///  if (node.has_value()) {                                                                     ///
///      NodeT<> ast = node.value();                                                             ///
///  } else {                                                                                    ///
///      std::cerr << node.error().what() << std::endl;                                          ///
///  }                                                                                           ///
///  @endcode                                                                                    ///
///                                                                                              ///
///  By default, the parser will parse the entire statement, but you can also parse a specific   ///
///     statement by calling the specific parse method. or get a specific node by calling parse  ///
///     and then passing a template argument to the method.                                      ///
///                                                                                              ///
///  @code                                                                                       ///
///  Statement state(tokens);                                                                    ///
///  ParseResult<ReturnState> node = state.parse<ReturnState>();                                 ///
///  @endcode                                                                                    ///
///                                                                                              ///
/// The parser is implemented using the following grammar:                                       ///
///                                                                                              ///
/// STS *           /* node types */                                                             ///
/// [x] * Literal    * L                                                                         ///
/// [x] * Operator   * O                                                                         ///
/// [x] * Token      * T                                                                         ///
/// [x] * Statement  * E                                                                         ///
///                                                                                              ///
/// STS *               /* statement types */                                                    ///
/// [x] * BreakState     * 'break' ';'                                                           ///
/// [x] * ContinueState  * 'continue' ';'                                                        ///
/// [x] * ExprState      * E ';'                                                                 ///
/// [x] * BlockState     * '{' Statement* '}'                                                    ///
/// [x] * SuiteState     * BlockState | (':' Statement)                                          ///
/// [x] * ReturnState    * 'return' E? ';'                                                       ///
///                                                                                              ///
/// [x] * YieldState            * 'yield' E ';'                                                  ///
/// [x] * DeleteState           * 'delete' E ';'                                                 ///
/// [x] * IfState               * ('if' | 'unless') E SuiteState (ElseState)?                    ///
/// [x] * ElseState             * 'else' SuiteState                                              ///
/// [x] * WhileState            * 'while' E SuiteState                                           ///
/// [x] * ForState              * 'for' ForPyStatementCore | ForCStatementCore SuiteState        ///
/// [x] * ForPyStatementCore    * NamedVarSpecifier 'in' E SuiteState                            ///
/// [x] * ForCStatementCore     * (E)? ';' (E)? ';' (E)? SuiteState                              ///
/// [x] * NamedVarSpecifier     * Ident (':' E)?                                                 ///
/// [x] * NamedVarSpecifierList * NamedVarSpecifier (',' NamedVarSpecifier)*                     ///
/// [x] * SwitchState           * 'switch' E '{' SwitchCaseState* '}'                            ///
/// [x] * SwitchCaseState    * 'case' E SuiteState | 'default' SuiteState                        ///
/// [x] * TryState           * 'try' SuiteState (CatchState) (FinallyState)?                     ///
/// [x] * CatchState         * 'catch' (NamedVarSpecifier (',' NamedVarSpecifier)*)? SuiteState  ///
///                            (CatchState | FinallyState)?                                      ///
/// [x] * FinallyState       * 'finally' SuiteState                                              ///
/// [x] * PanicState         * 'panic' ';'                                                       ///
///
/// [ ] * ImportState        * 'import' (SpecImport | SingleImport) ';'
/// [ ] * ImportItems         * Ident (('::' Ident)*)?
/// [ ] * SingleImport       * ImportItems ('as' Ident)?
/// [ ] * SpecImport         * ImportItems '::' '{' SingleImport (',' SingleImport)* '}'
/// [ ] * MultiImportState   * 'import' '{' ImportState* '}'

/// CHANGE
/// [ ] * AliasState         *
/// [ ] * SingleImportState  *
/// [ ] * MultiImportState   *
///                                                                                              ///
//===-----------------------------------------------------------------------------------------====//

/// TODO: all the parser to work with a specific defined subset of tokens that can get scoped to
///       allow for shorthand notation of repetition
/// like if i have 10 vars in a call that are all priv and static
/// instaed of:
/*
priv static let a: int = 1;
priv static let b: int = 1;
priv static let c: int = 1;
priv static let d: int = 1;
priv static let e: int = 1;
priv static let f: int = 1;
priv static let g: int = 1;
priv static let h: int = 1;
*/
/// i can do:
/*
priv static {
    let a: int = 1;
    let b: int = 1;
    let c: int = 1;
    let d: int = 1;
    let e: int = 1;
    let f: int = 1;
    let g: int = 1;
    let h: int = 1;
}
*/

/// the follow should be allowed to do this they can get chained:
/// priv, pub, prot, static, inline, import, and ffi ...

// if import is passed, as soon as its been parsed spwan a new thread to parse the import ast and
// get symbols store symbols to to global symbols vec, while parsing set 'found import ...' (so if
// the parser comes accross the same import it can skip it) and also set 'being parsed to true' so
// that when we get to symbol resolution we can wait for the thread to finish or timeout

/** GPT response for the above comment:
### Objective:
- When an `import` statement is encountered during parsing, you want to process it in a separate
thread to:
  1. Parse the AST (Abstract Syntax Tree) of the imported module.
  2. Extract the symbols (e.g., functions, variables, types) from the imported module.
  3. Store the imported symbols in a global symbol table for use in the main parsing process.

- The system needs to handle the import efficiently by tracking which imports have already been
processed and managing potential race conditions with symbol resolution.

### Detailed Explanation:

1. **Import Parsing**:
   - When the parser encounters an `import` statement, it immediately spawns a new thread to process
that import.
   - This separate thread will:
     1. Parse the imported module's source code into its own AST.
     2. Extract the relevant symbols (functions, variables, etc.) from the AST.
     3. Add those symbols to a global symbol table so the main parser can reference them.

2. **Global Symbol Table**:
   - The global symbol table is a shared resource that stores symbols from all imported modules.
   - This table will help avoid redundant imports (i.e., if the same module is imported multiple
times, it is parsed only once).
   - The symbols from the import need to be safely added to this global table by the thread handling
the import.

3. **Handling Duplicates**:
   - You want to keep track of imports that are in progress or already completed:
     - **Tracking Imports**: When an `import` statement is encountered, the parser checks a list (or
map) of imports to see if the module has already been imported.
     - **Skipping Duplicate Imports**: If the module has already been imported or is currently being
processed in another thread, the parser can skip creating a new thread and move on.
     - **Marking Imports**: As soon as an import starts processing, mark it as `being parsed` to
prevent other threads or the main parser from redundantly processing the same import.

4. **Concurrency with Threads**:
   - Since the parsing of imports is done in parallel (in separate threads), it's crucial to manage
these threads:
     - **Waiting for Threads**: When the main parser reaches the symbol resolution stage (i.e., when
it needs to use symbols from the imported module), it should check if the thread parsing the import
has finished. If not, it waits for the thread to finish or times out after a certain period.
     - **Timeout Mechanism**: The timeout ensures that if an import takes too long to parse (due to
errors or large files), the main parser doesn’t hang indefinitely.

### Steps Summary:

1. **Encounter Import**:
   - When an `import` statement is found, check if this module is already in the global symbol
     table.
   - If it is, skip it.
   - If not, spawn a new thread to:
     1. Parse the module.
     2. Extract the symbols.
     3. Add those symbols to the global symbol table.

2. **Track Import Status**:
   - Maintain a data structure that tracks the status of each import:
     - **Not Found**: The module hasn’t been parsed yet.
     - **Being Parsed**: A thread is currently parsing the module.
     - **Parsed**: The module has been fully parsed, and its symbols are available.

3. **Symbol Resolution**:
   - When the main parser needs to resolve symbols from an imported module, it checks if the parsing
     thread for that module has finished:
     - If the thread is still running, wait for it to finish or use a timeout to prevent deadlocks.
     - If the thread has finished, use the symbols it has added to the global symbol table.

### Example Scenario:

- **Step 1**: The parser encounters `import my_module`.
- **Step 2**: It checks if `my_module` is already in the global symbol table or currently being
              parsed.
  - If it’s not being parsed, spawn a new thread to parse `my_module`.
  - Mark `my_module` as `being parsed`.
- **Step 3**: The thread for `my_module` parses the module and extracts symbols like `my_func` and
              `my_var`.
  - These symbols are added to the global symbol table.
  - Mark `my_module` as `parsed`.
- **Step 4**: When the parser later encounters a reference to `my_func` from `my_module`, it checks
              the symbol table:
  - If the `my_module` thread is still running, the parser waits or times out.
  - If the thread has completed, the parser resolves `my_func` from the global symbol table.

### Important Considerations:
- **Concurrency**: Since multiple threads may be accessing and modifying the global symbol table,
                   ensure thread-safe operations (e.g., using mutexes or locks).
- **Timeout**: You need to decide how long the main parser will wait for an import thread before
               timing out.
- **Error Handling**: If the import thread fails (e.g., due to a syntax error in the imported
                      module), ensure that the parser can handle this gracefully, perhaps by
                      skipping the faulty module or logging an error.

This design improves parsing performance by handling imports concurrently but also ensures that the
symbols from the imports are available when needed for resolution.
 */

#include <cstddef>
#include <expected>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

#include "neo-panic/include/error.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "parser/ast/include/private/AST_generate.hh"
#include "parser/ast/include/private/AST_nodes.hh"
#include "parser/ast/include/types/AST_jsonify_visitor.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "token/include/Token.hh"
#include "token/include/config/Token_cases.def"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_generate.hh"
#include "parser/preprocessor/include/preprocessor.hh"

// ---------------------------------------------------------------------------------------------- //

bool is_excepted(const __TOKEN_N::Token &tok, const std::unordered_set<__TOKEN_TYPES_N> &tokens);
std::vector<__TOKEN_N::Token> get_modifiers(__TOKEN_N::TokenList::TokenListIter &iter);
bool                          is_ffi_specifier(const __TOKEN_N::Token &tok);
bool                          is_type_qualifier(const __TOKEN_N::Token &tok);
bool                          is_access_specifier(const __TOKEN_N::Token &tok);
bool                          is_function_specifier(const __TOKEN_N::Token &tok);
bool                          is_function_qualifier(const __TOKEN_N::Token &tok);
bool                          is_storage_specifier(const __TOKEN_N::Token &tok);

// ---------------------------------------------------------------------------------------------- //

// REVALUATE: if a parse_primary is needed for statements or if it should be removed
// AST_BASE_IMPL(Statement, parse_primary) {  // NOLINT(readability-function-cognitive-complexity)
//     IS_NOT_EMPTY;
//     NOT_IMPLEMENTED;
// }

// ---------------------------------------------------------------------------------------------- //

parser ::ast ::ParseResult<>
parser ::ast ::node ::Statement ::parse(const std::shared_ptr<__TOKEN_N::TokenList> modifiers) {  // NOLINT(readability-function-cognitive-complexity)
    IS_NOT_EMPTY;                  /// simple macro to check if the iterator is empty, expands to:
                                   /// if(iter.remaining_n() == 0) { return std::unexpected(...); }

    __TOKEN_N::Token tok = CURRENT_TOK;  /// get the current token from the iterator
    // modifiers        = get_modifiers(iter);  /// get the modifiers for the statement

    switch (tok.token_kind()) {
        case __TOKEN_N::KEYWORD_IF:
        case __TOKEN_N::KEYWORD_UNLESS: {
            if (modifiers != nullptr) {
                bool has_const = false;
                bool has_eval = false;

                for (auto &tok : *modifiers) {
                    if (tok.current().get().token_kind() == __TOKEN_N::KEYWORD_CONST) {
                        has_const = true;
                    } else if (tok.current().get().token_kind() == __TOKEN_N::KEYWORD_EVAL) {
                        has_eval = true;
                    }
                }

                return parse<IfState>(has_const, has_eval);
            }
            return parse<IfState>();

        } case __TOKEN_N::KEYWORD_RETURN:
            return parse<ReturnState>();

        case __TOKEN_N::KEYWORD_FOR:
            return parse<ForState>();

        case __TOKEN_N::KEYWORD_WHILE:
            return parse<WhileState>();

        case __TOKEN_N::KEYWORD_BREAK:
            return parse<BreakState>();

        case __TOKEN_N::KEYWORD_CONTINUE:
            return parse<ContinueState>();

        case __TOKEN_N::KEYWORD_SWITCH:
            return parse<SwitchState>();

        case __TOKEN_N::KEYWORD_TRY:
            return parse<TryState>();

        case __TOKEN_N::KEYWORD_PANIC:
            return parse<PanicState>();

        case __TOKEN_N::KEYWORD_FINALLY:
            return parse<FinallyState>();

        case __TOKEN_N::KEYWORD_YIELD:
            return parse<YieldState>();

        case __TOKEN_N::KEYWORD_DELETE:
            return parse<DeleteState>();

        case __TOKEN_N::KEYWORD_ELSE:
            return std::unexpected(PARSE_ERROR(
                CURRENT_TOK, "found dangling 'else' without a matching 'if' or 'unless'"));

        case __TOKEN_N::KEYWORD_CASE:
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "found dangling 'case' without a matching 'switch'"));

        case __TOKEN_N::KEYWORD_DEFAULT:
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "found dangling 'default' without a matching 'switch'"));

        case __TOKEN_N::KEYWORD_CATCH:
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "found dangling 'catch' without a matching 'try'"));

        default:
            return parse<ExprState>();
    }
}

// ---------------------------------------------------------------------------------------------- //

/** in helix i would extend:
macro return_if_empty! {
if self.iter.remaining_n() == 0:
    return std::unexpected(...);
};

extend Statement for NamedVarSpecifier {
    fn parse(self, bool force_type) {
        return_if_empty!

        ...
    }
}

*/
AST_NODE_IMPL(Statement, NamedVarSpecifier, bool force_type) {
    IS_NOT_EMPTY;

    // := const? Ident (':' Type)?
    auto node = make_node<NamedVarSpecifier>(true);

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_CONST)) {
        iter.advance();  // skip 'const'
        node->is_const = true;
    }

    ParseResult<IdentExpr> path = expr_parser.parse<IdentExpr>();
    RETURN_IF_ERROR(path);

    if (force_type) {
        if (path.value()->name.value() == "self") {
            node->path = path.value();
            return node;
        }

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_COLON);
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COLON)) {
        iter.advance();  // skip ':'

        ParseResult<Type> type = expr_parser.parse<Type>();
        RETURN_IF_ERROR(type);

        node->path = path.value();
        node->type = type.value();

        return node;
    }

    node->path = path.value();
    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, NamedVarSpecifier) {
    json.section("NamedVarSpecifier")
        .add("path", get_node_json(node.path))
        .add("type", get_node_json(node.type));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, NamedVarSpecifierList, bool force_type) {
    IS_NOT_EMPTY;

    // := NamedVarSpecifier (',' NamedVarSpecifier)*

    NodeT<NamedVarSpecifierList> node = make_node<NamedVarSpecifierList>(true);

    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::IDENTIFIER)) {
        return std::unexpected(
            PARSE_ERROR(CURRENT_TOK,
                        "expected an identifier for the variable name, but found: " +
                            CURRENT_TOK.token_kind_repr()));
    }

    ParseResult<NamedVarSpecifier> var = parse<NamedVarSpecifier>(force_type);
    RETURN_IF_ERROR(var);

    node->vars.emplace_back(var.value());

    while (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
        iter.advance();  // skip ','

        ParseResult<NamedVarSpecifier> next_var = parse<NamedVarSpecifier>(force_type);
        RETURN_IF_ERROR(next_var);

        node->vars.emplace_back(next_var.value());
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, NamedVarSpecifierList) {
    std::vector<neo::json> vars;

    for (const auto &var : node.vars) {
        vars.push_back(get_node_json(var));
    }

    json.section("NamedVarSpecifierList", vars);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ForPyStatementCore, bool skip_start) {
    IS_NOT_EMPTY;
    // := NamedVarSpecifier* 'in' E SuiteState

    bool                      except_closing_paren = false;
    __TOKEN_N::Token          starting_tok;
    NodeT<ForPyStatementCore> node = make_node<ForPyStatementCore>(true);

    if (!skip_start) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_FOR);
        iter.advance();  // skip 'for'
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_PAREN)) {
        except_closing_paren = true;
        starting_tok         = CURRENT_TOK;
        iter.advance();  // skip '('
    }

    // vars can be untyped
    ParseResult<NamedVarSpecifierList> vars = parse<NamedVarSpecifierList>(false);
    RETURN_IF_ERROR(vars);

    // if there structured binding unpacking, then the vars should be untyped
    if (vars.value()->vars.size() > 1) {
        for (const auto &var : vars.value()->vars) {
            if (var->type != nullptr) {
                error::Panic(error::CodeError{
                    .pof      = const_cast<__TOKEN_N::Token *>(&var->path->name),
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{
                        GET_DEBUG_INFO +
                        "do not specify a type for unpacking loop vars, type info is ignored here"},
                    .opt_fixes{},
                    .level = error::WARN,
                });

                var->type = nullptr;  // remove the type
            }
        }
    }

    node->vars = vars.value();

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_IN);
    node->in_marker = CURRENT_TOK;
    iter.advance();  // skip 'in'

    ParseResult<> range = expr_parser.parse();
    RETURN_IF_ERROR(range);

    if (except_closing_paren) {
        if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_PAREN)) {
            return std::unexpected(PARSE_ERROR(starting_tok,
                                               "expected ')' to close the for loop, but found: " +
                                                   CURRENT_TOK.token_kind_repr()));
        }

        iter.advance();  // skip ')'
    }

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->range = range.value();
    node->body  = body.value();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ForPyStatementCore) {
    json.section("ForPyStatementCore")
        .add("range", get_node_json(node.range))
        .add("body", get_node_json(node.body))
        .add("in_marker", node.in_marker)
        .add("vars", get_node_json(node.vars));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ForCStatementCore, bool skip_start) {
    IS_NOT_EMPTY;
    // := (S)? ';' (E)? ';' (E)? SuiteState

    bool except_closing_paren = false;

    __TOKEN_N::Token         starting_tok;
    NodeT<ForCStatementCore> node = make_node<ForCStatementCore>(true);

    if (!skip_start) {
        if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_FOR)) {
            iter.advance();  // skip 'for'
        }
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_PAREN)) {  // '('
        except_closing_paren = true;
        starting_tok         = CURRENT_TOK;
        iter.advance();  // skip '('
    }

    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_SEMICOLON)) {
        auto         *decl_parser = new Declaration(iter);
        ParseResult<> init        = decl_parser->parse();
        delete decl_parser;
        RETURN_IF_ERROR(init);

        node->init = init.value();  // next semi colon has been skipped
    } else {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
        iter.advance();  // skip ';'
    }

    // first semi colon is skipped

    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_SEMICOLON)) {
        ParseResult<> condition = expr_parser.parse();
        RETURN_IF_ERROR(condition);

        node->condition = condition.value();

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
        iter.advance();  // skip ';' - 2
    } else {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
        iter.advance();  // skip ';' - 2
    }

    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_OPEN_BRACE) &&
        CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_COLON)) {
        // update condition
        ParseResult<> update = expr_parser.parse();
        RETURN_IF_ERROR(update);

        node->update = update.value();
    }  // no semicolon after this

    if (except_closing_paren) {
        if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_PAREN)) {
            return std::unexpected(PARSE_ERROR(starting_tok,
                                               "expected ')' to close the for loop, but found: " +
                                                   CURRENT_TOK.token_kind_repr()));
        }

        iter.advance();  // skip ')'
    }

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->body = body.value();
    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ForCStatementCore) {
    json.section("ForCStatementCore")
        .add("init", get_node_json(node.init))
        .add("condition", get_node_json(node.condition))
        .add("update", get_node_json(node.update))
        .add("body", get_node_json(node.body));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ForState) {
    IS_NOT_EMPTY;

    // := 'for' ForPyStatementCore | ForCStatementCore SuiteState

    bool except_closing_paren = false;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_FOR);
    iter.advance();  // skip 'for'

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_PAREN)) {
        except_closing_paren = true;
        iter.advance();  // skip '('
    }

    /// here we can do a few checks now to see if we are parsing a python or c style for loop
    /// if the curent token is not a ident we are in a c style loop
    /// if the token is a ident then parse a NamedVarSpecifier* then if theres 'in' then its a
    /// python style loop

    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::IDENTIFIER)) {
    c_style_for:
        if (except_closing_paren) {
            iter.reverse();  // go back to the '('
        }

        ParseResult<ForCStatementCore> c_for = parse<ForCStatementCore>(true);
        RETURN_IF_ERROR(c_for);

        return make_node<ForState>(c_for.value(), ForState::ForType::C);
    }

    // if we dont have (',' | ':' | 'in') then we are in a c style loop
    if (iter.peek().has_value() && (NEXT_TOK.token_kind() != __TOKEN_N::PUNCTUATION_COMMA &&
                                    NEXT_TOK.token_kind() != __TOKEN_N::PUNCTUATION_COLON &&
                                    NEXT_TOK.token_kind() != __TOKEN_N::KEYWORD_IN)) {
        goto c_style_for;
    }

    if (except_closing_paren) {
        iter.reverse();  // go back to the '('
    }

    ParseResult<ForPyStatementCore> py_for = parse<ForPyStatementCore>(true);
    RETURN_IF_ERROR(py_for);

    return make_node<ForState>(py_for.value(), ForState::ForType::Python);
}

AST_NODE_IMPL_VISITOR(Jsonify, ForState) {
    json.section("ForState").add("core", get_node_json(node.core)).add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, WhileState) {
    IS_NOT_EMPTY;
    // := 'while' E SuiteState

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_WHILE);
    iter.advance();  // skip 'while'

    ParseResult<> condition = expr_parser.parse();
    RETURN_IF_ERROR(condition);

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    return make_node<WhileState>(condition.value(), body.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, WhileState) {
    json.section("WhileState")
        .add("condition", get_node_json(node.condition))
        .add("body", get_node_json(node.body));
}

// ---------------------------------------------------------------------------------------------- //

/* TODO: REFACTOR */
AST_NODE_IMPL(Statement, ElseState) {
    IS_NOT_EMPTY;

    // := ('else' Suite) | ('else' ('if' | 'unless') E Suite)

    NodeT<ElseState> node = make_node<ElseState>(true);

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_ELSE);
    iter.advance();  // skip 'else'

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_IF) || CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_UNLESS)) {
        node->type = CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_IF) ? ElseState::ElseType::ElseIf
                                                             : ElseState::ElseType::ElseUnless;
        iter.advance();  // skip 'if' | 'unless'

        ParseResult<> expr = expr_parser.parse();
        RETURN_IF_ERROR(expr);

        node->condition = expr.value();
    }

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->body = body.value();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ElseState) {
    json.section("ElseState")
        .add("condition", get_node_json(node.condition))
        .add("body", get_node_json(node.body))
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

/* TODO: REFACTOR */
AST_NODE_IMPL(Statement, IfState, bool has_const, bool has_eval) {
    IS_NOT_EMPTY;

    // := ('if' | 'unless') E SuiteState (ElseState*)?

    NodeT<IfState> node;
    bool           is_unless = false;

#define IF_UNLESS_TOKENS {__TOKEN_N::KEYWORD_IF, __TOKEN_N::KEYWORD_UNLESS}
    IS_IN_EXCEPTED_TOKENS(IF_UNLESS_TOKENS);
    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_UNLESS)) {
        is_unless = true;
    }

    iter.advance();  // skip 'if' or 'unless'
#undef IF_UNLESS_TOKENS

    ParseResult<> condition = expr_parser.parse();
    RETURN_IF_ERROR(condition);

    node = make_node<IfState>(condition.value());
    node->has_const = has_const;
    node->has_eval  = has_eval;

    if (is_unless) {
        node->type = IfState::IfType::Unless;
    }

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->body = body.value();

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_ELSE) {
        bool             captured_final_else = false;
        __TOKEN_N::Token starting_else;

        ParseResult<ElseState> else_body = parse<ElseState>();
        RETURN_IF_ERROR(else_body);

        node->else_body.emplace_back(else_body.value());

        if (else_body.value()->type == ElseState::ElseType::Else) {
            captured_final_else = true;
        }

        while (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_ELSE)) {
            starting_else = CURRENT_TOK;

            else_body = parse<ElseState>();
            RETURN_IF_ERROR(else_body);

            node->else_body.emplace_back(else_body.value());

            if (else_body.value()->type == ElseState::ElseType::Else) {
                if (captured_final_else) {
                    return std::unexpected(
                        PARSE_ERROR(starting_else, "redefinition of captured else block"));
                }

                captured_final_else = true;
            }
        }
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, IfState) {
    std::vector<neo::json> else_body;

    for (const auto &else_state : node.else_body) {
        else_body.push_back(get_node_json(else_state));
    }

    json.section("IfState")
        .add("condition", get_node_json(node.condition))
        .add("body", get_node_json(node.body))
        .add("else_body", else_body)
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, SwitchCaseState) {
    IS_NOT_EMPTY;
    // := ('case' E SuiteState) | 'default' SuiteState

    __TOKEN_N::Token marker = CURRENT_TOK;
    /*
    Case
    Default
    Fallthrough
    
    case: ... <- fallthrough
    case: {}  <- fallthrough
    case {}   <- case
    
    default:    <- default
    default {}  <- default
    default: {} <- default
    */
    SwitchCaseState::CaseType case_type = SwitchCaseState::CaseType::Case;
    ParseResult<> condition;


    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_CASE)) {
        iter.advance();  // skip 'case'
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_DEFAULT)) {
        case_type = SwitchCaseState::CaseType::Default;
        iter.advance();  // skip 'default'
    } else {
        return std::unexpected(PARSE_ERROR(
            CURRENT_TOK, "expected 'case' or 'default' but found: " + CURRENT_TOK.token_kind_repr()));
    }

    if (case_type != SwitchCaseState::CaseType::Default) {
        condition = expr_parser.parse();
        RETURN_IF_ERROR(condition);
    }

    // if the next token is ':' then we have a fallthrough
    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COLON)) {
        if (HAS_NEXT_TOK && NEXT_TOK.token_kind() == __TOKEN_N::PUNCTUATION_OPEN_BRACE) { // : {
            iter.advance();  // skip ':'
        }

        if (case_type != SwitchCaseState::CaseType::Default) {
            case_type = SwitchCaseState::CaseType::Fallthrough;
        }

        // if we dont have any Suite after the case we have a fall though
        if (HAS_NEXT_TOK &&
            (NEXT_TOK.token_kind() == __TOKEN_N::KEYWORD_DEFAULT ||
             NEXT_TOK.token_kind() == __TOKEN_N::KEYWORD_CASE)) {
            iter.advance();  // skip ':'
            return make_node<SwitchCaseState>(condition.value_or(nullptr), make_node<SuiteState>(nullptr), case_type, marker);
        }

    } else {
        if (case_type == SwitchCaseState::CaseType::Default) {
            if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_OPEN_BRACE)) {
                return std::unexpected(PARSE_ERROR(
                    CURRENT_TOK, "expected '{', or ':' for default case, but found: " + CURRENT_TOK.token_kind_repr()));
            }
        }
    }
    
    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    return make_node<SwitchCaseState>(condition.value_or(nullptr), body.value(), case_type, marker);

}

AST_NODE_IMPL_VISITOR(Jsonify, SwitchCaseState) {
    json.section("SwitchCaseState")
        .add("condition", get_node_json(node.condition))
        .add("body", get_node_json(node.body))
        .add("type", (int)node.type)
        .add("marker", node.marker);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, SwitchState) {
    IS_NOT_EMPTY;
    // := 'switch' expr (('{' SwitchCaseState* '}') | (':' SwitchCaseState))

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_SWITCH);
    iter.advance();  // skip 'switch'

    ParseResult<> expr = expr_parser.parse();
    RETURN_IF_ERROR(expr);

    NodeT<SwitchState> node = make_node<SwitchState>(expr.value());

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE)) {
        iter.advance();  // skip '{'

        while (iter.remaining_n() > 0 && CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_BRACE)) {
            ParseResult<SwitchCaseState> case_state = parse<SwitchCaseState>();
            RETURN_IF_ERROR(case_state);

            node->cases.emplace_back(case_state.value());
        }

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
        iter.advance();  // skip '}'
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COLON)) {
        iter.advance();  // skip ':'

        if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_CASE) ||
            CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_DEFAULT)) {
            // warn saying this is redundant and an if statement should be used instead
            error::Panic(error::CodeError{
                .pof      = const_cast<__TOKEN_N::Token *>(&CURRENT_TOK),
                .err_code = 0.0001,
                .mark_pof = true,
                .fix_fmt_args{},
                .err_fmt_args{
                    GET_DEBUG_INFO +
                    "redundant switch statement with only one case, use an if statement instead"},
                .opt_fixes{},
                .level = error::WARN,
            });
        }

        ParseResult<SwitchCaseState> case_state = parse<SwitchCaseState>();
        RETURN_IF_ERROR(case_state);

        node->cases.emplace_back(case_state.value());
    } else {
        if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_SEMICOLON)) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "expected a scope with cases but found ';'"));
        }

        return std::unexpected(PARSE_ERROR(
            CURRENT_TOK, "expected '{' or ':', but found: " + CURRENT_TOK.token_kind_repr()));
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, SwitchState) {
    std::vector<neo::json> cases;

    for (const auto &case_state : node.cases) {
        cases.push_back(get_node_json(case_state));
    }

    json.section("SwitchState").add("condition", get_node_json(node.condition)).add("cases", cases);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, YieldState) {
    IS_NOT_EMPTY;

    // := 'yield' E ';'

    __TOKEN_N::Token marker;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_YIELD);
    marker = CURRENT_TOK;
    iter.advance();

    ParseResult<> expr = expr_parser.parse();
    RETURN_IF_ERROR(expr);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();

    return make_node<YieldState>(expr.value(), marker);
}

AST_NODE_IMPL_VISITOR(Jsonify, YieldState) {
    json.section("YieldState", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, DeleteState) {
    IS_NOT_EMPTY;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_DELETE);
    iter.advance();

    ParseResult<> expr = expr_parser.parse();
    RETURN_IF_ERROR(expr);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();

    return make_node<DeleteState>(expr.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, DeleteState) {
    json.section("DeleteState", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

/* UPDATED GRAMMARS:

/// ImportState        := 'import' (SpecImport | SingleImport) ';'
/// SingleImport       := (ScopePath | StringLiteral) ('as' Ident)?
/// ImportItems        := SingleImport (',' SingleImport)*
/// SpecImport         := SingleImport '::' ('{' ImportItems '}') | ('*')

*/

AST_NODE_IMPL(Statement, ImportState, bool is_ffi) {
    IS_NOT_EMPTY;
    bool is_module = false;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_IMPORT);
    iter.advance();  // skip 'import'

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_MODULE) {
        is_module = true;
        iter.advance();  // skip 'module`
    }

    ParseResult<SingleImport> single_import = parse<SingleImport>();
    RETURN_IF_ERROR(single_import);

    if (single_import.value()->is_wildcard) {
        /// not allowed if its an file import or ffi
        if (is_ffi) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "wildcard imports are not allowed in ffi imports"));
        }

        if (single_import.value()->type == SingleImport::Type::File) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "wildcard imports are not allowed in file imports"));
        }

        if (single_import.value()->alias != nullptr) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "wildcard imports cannot have an alias"));
        }

        // excpt a semi colon:
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
        iter.advance(); // skip ';'

        /// convert the single import to a spec import
        NodeT<SpecImport> spec_import = make_node<SpecImport>(single_import.value());
        return make_node<ImportState>(spec_import, is_module);
    }

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_OPEN_BRACE) {
        if (is_ffi) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "import items are not allowed in ffi imports"));
        }

        /// if we have a open brace then we have a spec import
        ParseResult<SpecImport> spec_import = parse<SpecImport>(single_import.value());
        RETURN_IF_ERROR(spec_import);

        return make_node<ImportState>(spec_import.value(), is_module);
    }

    return make_node<ImportState>(single_import.value(), is_module);
}

AST_NODE_IMPL_VISITOR(Jsonify, ImportState) {
    json.section("ImportState")
        .add("import", get_node_json(node.import))
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ImportItems) {
    IS_NOT_EMPTY;

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACE);
    iter.advance();  // skip '{'

    ParseResult<SingleImport> first = parse<SingleImport>();

    if (first.value()->is_wildcard) {
        return std::unexpected(PARSE_ERROR(CURRENT_TOK, "wildcard imports are not allowed here"));
    }

    if (first.value()->type == SingleImport::Type::File) {
        return std::unexpected(PARSE_ERROR(CURRENT_TOK, "file imports are not allowed here"));
    }

    NodeT<ImportItems> node = make_node<ImportItems>(first.value());

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
                break;
            }

            ParseResult<SingleImport> next = parse<SingleImport>();
            RETURN_IF_ERROR(next);

            if (next.value()->is_wildcard) {
                return std::unexpected(
                    PARSE_ERROR(CURRENT_TOK, "wildcard imports are not allowed here"));
            }

            if (next.value()->type == SingleImport::Type::File) {
                return std::unexpected(
                    PARSE_ERROR(CURRENT_TOK, "file imports are not allowed here"));
            }

            node->imports.emplace_back(next.value());
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
    iter.advance();  // skip '}'

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ImportItems) {
    json.section("ImportItems");

    std::vector<neo::json> imports;

    for (const auto &import : node.imports) {
        imports.push_back(get_node_json(import));
    }

    json.add("imports", imports);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, SingleImport) {
    IS_NOT_EMPTY;

    bool is_file_import = false;

    switch (CURRENT_TOK.token_kind()) {
        case token::LITERAL_TRUE:
        case token::LITERAL_FALSE:
        case token::LITERAL_INTEGER:
        case token::LITERAL_COMPILER_DIRECTIVE:
        case token::LITERAL_FLOATING_POINT:
        case token::LITERAL_CHAR:
        case token::LITERAL_NULL:
            return std::unexpected(PARSE_ERROR(
                CURRENT_TOK, "expected a string literal or a scope, got another kind of literal."));
            break;
        case token::LITERAL_STRING:
            is_file_import = true;
        case token::IDENTIFIER:
            break;
        default:
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "expected a string literal or a scope for imports."));
            break;
    }

    NodeT<SingleImport> node = make_node<SingleImport>(is_file_import ? SingleImport::Type::File
                                                                      : SingleImport::Type::Module);
    ParseResult<>       path;

    if (!is_file_import) {
        path = expr_parser.parse<ScopePathExpr>(nullptr, false, true);
        RETURN_IF_ERROR(path);
    } else {
        path = expr_parser.parse<LiteralExpr>();
        RETURN_IF_ERROR(path);

        auto lit_path = __AST_N::as<LiteralExpr>(path.value());

        if (lit_path->contains_format_args) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "f-strings are not allowed in imports."));
        }

        // convert the path to an absoulte one, by doing the following:
        // 1. check if the path is a relative path
        // 2. if it is, look for the right file, go in order of:
        //    - current file directory
        //    - dirs specifed in include paths
        //    - if not found then error saying file not found
        // 3. if the path is an absolute path, then check if the file exists

        // remove the quotes
        auto str_path = (lit_path->value.value()).substr(1, (lit_path->value.value()).size() - 2);
        auto fs_path = std::filesystem::path(str_path);
        auto included_dirs = import_processor->get_dirs();

        if (fs_path.is_relative()) {
            // check if the file exists in the current file directory
            auto current_file_dir = std::filesystem::path(CURRENT_TOK.file_name()).parent_path();
            auto current_file_path = current_file_dir / fs_path;

            if (!std::filesystem::exists(current_file_path)) {
                bool found = false;

                for (const auto &dir : included_dirs) {
                    auto dir_path = std::filesystem::path(dir) / fs_path;

                    if (std::filesystem::exists(dir_path)) {
                        found = true;
                        current_file_path = dir_path;
                        break;
                    }
                }

                if (found) {
                    // set the path to the found path
                    lit_path->value.set_value("\"" + current_file_path.generic_string() + "\"");
                }
                
            } else {
                lit_path->value.set_value("\"" + current_file_path.generic_string() + "\"");
            }
        }

        path = lit_path;
    }

    node->path = path.value();

    if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_MUL)) {
        iter.advance();  // skip '*'
        node->is_wildcard = true;

        if (is_file_import) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "wildcard imports are not allowed in file imports."));
        }
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE)) {
        if (is_file_import) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "file imports cannot have import items."));
        }

        return node;
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_AS)) {
        iter.advance();  // skip 'as'

        ParseResult<IdentExpr> alias = expr_parser.parse<IdentExpr>();
        RETURN_IF_ERROR(alias);

        node->alias = alias.value();
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, SingleImport) {
    json.section("SingleImport")
        .add("path", get_node_json(node.path))
        .add("alias", get_node_json(node.alias))
        .add("is_wildcard", node.is_wildcard ? "true" : "false")
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, SpecImport, ParseResult<SingleImport> path) {
    IS_NOT_EMPTY;

    NodeT<SpecImport> node;
    bool              is_wildcard = false;
    bool              is_symbol   = false;

    IS_NULL_RESULT(path) {
        /// parse a ScopePathExpr
        ParseResult<ScopePathExpr> path = expr_parser.parse<ScopePathExpr>(nullptr, false, true);
        RETURN_IF_ERROR(path);

        if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_MUL)) {
            iter.advance();  // skip '*'
            is_wildcard = true;
        } else if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE)) {
            is_symbol = true;
        }

        node = make_node<SpecImport>(path.value());
    }
    else {
        if (path.value()->type == SingleImport::Type::File) {
            return std::unexpected(
                PARSE_ERROR(CURRENT_TOK, "file imports cannot have import items."));
        }

        node = make_node<SpecImport>(__AST_N::as<ScopePathExpr>(path.value()->path));
        /// we only get here if there is a open brace
        is_wildcard = path.value()->is_wildcard;
        is_symbol   = true;
    }

    if (is_symbol && is_wildcard) {
        return std::unexpected(
            PARSE_ERROR(CURRENT_TOK, "wildcard imports are not allowed in direct symbol imports."));
    }

    if (is_symbol) {
        ParseResult<ImportItems> items = parse<ImportItems>();
        RETURN_IF_ERROR(items);

        node->imports = items.value();
        node->type    = SpecImport::Type::Symbol;
    } else {
        node->type = SpecImport::Type::Wildcard;
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, SpecImport) {
    json.section("SpecImport")
        .add("path", get_node_json(node.path))
        .add("imports", get_node_json(node.imports))
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, MultiImportState) { NOT_IMPLEMENTED; }

AST_NODE_IMPL_VISITOR(Jsonify, MultiImportState) { json.section("MultiImportState"); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ReturnState) {
    IS_NOT_EMPTY;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_RETURN);
    iter.advance();  // skip 'return'

    ParseResult<> expr = expr_parser.parse();
    RETURN_IF_ERROR(expr);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();  // skip ';'

    return make_node<ReturnState>(expr.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, ReturnState) {
    json.section("ReturnState", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, BreakState) {
    IS_NOT_EMPTY;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_BREAK);
    NodeT<BreakState> node = make_node<BreakState>(CURRENT_TOK);

    iter.advance();

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, BreakState) { json.section("BreakState", node.marker); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ContinueState) {
    IS_NOT_EMPTY;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_CONTINUE);
    NodeT<ContinueState> node = make_node<ContinueState>(CURRENT_TOK);

    iter.advance();

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ContinueState) { json.section("ContinueState", node.marker); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, ExprState) {
    IS_NOT_EMPTY;

    ParseResult<> expr = expr_parser.parse();
    RETURN_IF_ERROR(expr);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();

    return make_node<ExprState>(expr.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, ExprState) {
    json.section("ExprState").add("expr", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, SuiteState) {
    IS_NOT_EMPTY;

    // := BlockState | (':' Statement)

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_OPEN_BRACE) {
        ParseResult<BlockState> block = parse<BlockState>();
        RETURN_IF_ERROR(block);

        return make_node<SuiteState>(block.value());
    }

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_COLON) {
        iter.advance();  // skip ':'

        Declaration decl_parser(iter);

        ParseResult<> decl = decl_parser.parse();
        RETURN_IF_ERROR(decl);

        NodeT<BlockState> block = make_node<BlockState>(NodeV<>{decl.value()});
        return make_node<SuiteState>(block);
    }

    return std::unexpected(
        PARSE_ERROR(CURRENT_TOK,
                    "expected a suite block or a single statement, '{' or ':', but found: " +
                        CURRENT_TOK.token_kind_repr()));
}

AST_NODE_IMPL_VISITOR(Jsonify, SuiteState) { json.section("SuiteState", get_node_json(node.body)); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, BlockState) {
    IS_NOT_EMPTY;
    // := '{' Statement* '}'

    NodeV<>          body;
    __TOKEN_N::Token starting_tok;
    Declaration      decl_parser(iter);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACE);
    starting_tok = CURRENT_TOK;
    iter.advance();  // skip '{'

    while (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_BRACE)) {  // TODO: implement this kind
                                                                        // of bounds checks for all
        // the pair token parsers '(', '[', '{'.
        ParseResult<> decl = decl_parser.parse();
        RETURN_IF_ERROR(decl);

        body.push_back(decl.value());
    }

    if (iter.remaining_n() == 0) {
        return std::unexpected(
            PARSE_ERROR(starting_tok, "expected '}' to close the block, but found EOF"));
    }

    iter.advance();  // skip '}'
    return make_node<BlockState>(body);
}

AST_NODE_IMPL_VISITOR(Jsonify, BlockState) {
    std::vector<neo::json> body_json;

    for (const auto &node : node.body) {
        body_json.push_back(get_node_json(node));
    }

    json.section("BlockState", body_json);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, TryState) {
    IS_NOT_EMPTY;

    // := 'try' SuiteState (CatchState)* (FinallyState)?

    NodeT<TryState> node;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_TRY);
    iter.advance();  // skip 'try'

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node = make_node<TryState>(body.value());

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_FINALLY) {
        ParseResult<FinallyState> finally_state = parse<FinallyState>();
        RETURN_IF_ERROR(finally_state);

        node->no_catch      = true;
        node->finally_state = finally_state.value();

        return node;
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_CATCH);

    ParseResult<CatchState> catch_state = parse<CatchState>();
    RETURN_IF_ERROR(catch_state);

    node->catch_states.emplace_back(catch_state.value());

    while
        CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_CATCH) {
            ParseResult<CatchState> next_catch = parse<CatchState>();
            RETURN_IF_ERROR(next_catch);

            node->catch_states.emplace_back(next_catch.value());
        }

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_FINALLY) {
        ParseResult<FinallyState> finally_state = parse<FinallyState>();
        RETURN_IF_ERROR(finally_state);

        node->finally_state = finally_state.value();
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, TryState) {
    std::vector<neo::json> catch_states;

    for (const auto &catch_state : node.catch_states) {
        catch_states.push_back(get_node_json(catch_state));
    }

    json.section("TryState")
        .add("body", get_node_json(node.body))
        .add("catches", catch_states)
        .add("finally", get_node_json(node.finally_state))
        .add("no_catch", (int)node.no_catch);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, CatchState) {
    IS_NOT_EMPTY;

    // := 'catch' (NamedVarSpecifier | Type)? SuiteState (CatchState)?

    __TOKEN_N::Token starting_tok;
    bool             except_closing_paren = false;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_CATCH);
    iter.advance();  // skip 'catch'

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_PAREN)) {
        except_closing_paren = true;
        starting_tok         = CURRENT_TOK;
        iter.advance();  // skip '('
    }
    
    // either have a var like: e: Exception
    // or just a type like: Exception
    // or none at all
    ParseResult<> catch_state;

    if (CURRENT_TOKEN_IS(__TOKEN_N::IDENTIFIER) && HAS_NEXT_TOK && NEXT_TOK.token_kind() == __TOKEN_N::PUNCTUATION_COLON) {
        catch_state = parse<NamedVarSpecifier>(true);
        RETURN_IF_ERROR(catch_state);
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE) || CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COLON)) {
        catch_state = nullptr;
    } else {
        catch_state = expr_parser.parse<Type>();
        RETURN_IF_ERROR(catch_state);
    }

    if (except_closing_paren) {
        if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_PAREN)) {
            return std::unexpected(
                PARSE_ERROR(starting_tok,
                            "expected ')' to close the catch block, but found: " +
                                CURRENT_TOK.token_kind_repr()));
        }

        iter.advance();  // skip ')'
    }

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    return make_node<CatchState>(catch_state.has_value() ? catch_state.value() : nullptr, body.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, CatchState) {
    json.section("CatchState")
        .add("catch", get_node_json(node.catch_state))
        .add("body", get_node_json(node.body));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, PanicState) {
    IS_NOT_EMPTY;

    // := 'panic' E ';'
    __TOKEN_N::Token marker;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_PANIC);
    marker = CURRENT_TOK;
    iter.advance();  // skip 'panic'

    ParseResult<> expr = expr_parser.parse();
    RETURN_IF_ERROR(expr);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();  // skip ';'

    return make_node<PanicState>(expr.value(), marker);
}

AST_NODE_IMPL_VISITOR(Jsonify, PanicState) { json.section("PanicState", get_node_json(node.expr)); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Statement, FinallyState) {
    IS_NOT_EMPTY;

    // := 'finally' SuiteState

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_FINALLY);
    iter.advance();  // skip 'finally'

    ParseResult<SuiteState> body = parse<SuiteState>();
    RETURN_IF_ERROR(body);

    return make_node<FinallyState>(body.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, FinallyState) {
    json.section("FinallyState", get_node_json(node.body));
}

// ---------------------------------------------------------------------------------------------- //

std::vector<__TOKEN_N::Token> get_modifiers(__TOKEN_N::TokenList::TokenListIter &iter) {
    std::vector<__TOKEN_N::Token> modifiers;

    while (iter.remaining_n() > 0) {
        switch (iter->token_kind()) {
            case __TOKEN_N::KEYWORD_INLINE:
            case __TOKEN_N::KEYWORD_STATIC:
            case __TOKEN_N::KEYWORD_ASYNC:
            case __TOKEN_N::KEYWORD_EVAL:
            case __TOKEN_N::KEYWORD_PRIVATE:
            case __TOKEN_N::KEYWORD_CONST:
            case __TOKEN_N::KEYWORD_UNSAFE:
            case __TOKEN_N::KEYWORD_PUBLIC:
            case __TOKEN_N::KEYWORD_PROTECTED:
            case __TOKEN_N::KEYWORD_INTERNAL:
            case __TOKEN_N::LITERAL_COMPILER_DIRECTIVE:
                modifiers.push_back(CURRENT_TOK);
                iter.advance();
                break;
            default:
                goto exit_loop;
        }
    }

exit_loop:
    return modifiers;
}