///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __CX_UTILS__
#define __CX_UTILS__

#include <algorithm>
#include <cctype>
#include <chrono>
#include <concepts>
#include <cstdio>
#include <ctime>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

#include "generator/include/CX-IR/CXIR.hh"
#include "generator/include/config/Gen_config.def"
#include "neo-panic/include/error.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/AST.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_declarations.hh"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "parser/ast/include/private/AST_generate.hh"
#include "parser/ast/include/private/base/AST_base_expression.hh"
#include "parser/ast/include/types/AST_modifiers.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "parser/preprocessor/include/private/utils.hh"
#include "token/include/Token.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"
#include "token/include/private/Token_generate.hh"

enum class OperatorType { UnaryPrefix, UnaryPostfix, Binary, Array, Call, None };

inline std::string generate_unique_name() {
    auto now    = std::chrono::system_clock::now();
    auto epoch  = now.time_since_epoch();
    auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(epoch).count();

    std::random_device              rd;
    std::mt19937                    gen(rd());
    std::uniform_int_distribution<> dis(1000, 9999);
    int                             randomComponent = dis(gen);

    std::ostringstream uniqueName;
    uniqueName << "$_" << millis << "_" << randomComponent;

    return uniqueName.str();
}

inline std::pair<bool, bool>
contains_self_static(const __AST_N::NodeT<__AST_NODE::FuncDecl> &func_decl) {
    std::pair<bool, bool>               found_self_static = {false, false};
    __AST_N::NodeT<__AST_NODE::VarDecl> self_arg          = nullptr;

    if (!func_decl->params.empty() && func_decl->params[0] != nullptr) {
        self_arg = func_decl->params[0];
        if (self_arg->var->path->name.value() == "self") {
            if (self_arg->var->type != nullptr || self_arg->value != nullptr) {
                throw error::Panic(
                    error::CodeError{.pof = &self_arg->var->path->name, .err_code = 0.3006});
            }
            found_self_static.first = true;  // found 'self'
        }
    }

    if (func_decl->modifiers.contains(__TOKEN_N::KEYWORD_STATIC)) {
        found_self_static.second = true;  // found 'static'
    }

    return found_self_static;
}

inline std::pair<bool, bool>
contains_self_static(const __AST_N::NodeT<__AST_NODE::OpDecl> &op_decl) {
    auto func_decl       = op_decl->func;
    func_decl->modifiers = op_decl->modifiers;

    return contains_self_static(func_decl);
}

inline void handle_static_self_fn_decl(__AST_N::NodeT<__AST_NODE::FuncDecl> &func_decl,
                                       token::Token                         &pof) {
    auto [has_self, has_static] = contains_self_static(func_decl);

    if (!has_static) {
        if (!has_self) {
            error::Panic(error::CodeError{.pof = &pof, .err_code = 0.3004});

            func_decl->modifiers.add(__AST_N::FunctionSpecifier(
                token::Token(__TOKEN_N::KEYWORD_STATIC, "helix_internal.file")));
        }
    } else if (has_self) {
        error::Panic(error::CodeError{.pof = &pof, .err_code = 0.3005});
    }

    if (has_self) {
        func_decl->params.erase(func_decl->params.begin());
    }
}

inline void handle_static_self_fn_decl(__AST_N::NodeT<__AST_NODE::OpDecl> &op_decl,
                                       token::Token                       &pof,
                                       bool                                in_udt = true) {
    auto &func_decl      = op_decl->func;
    func_decl->modifiers = op_decl->modifiers;

    if (!in_udt) {  // free fucntion, cannot have self
        auto [has_self, has_static] = contains_self_static(func_decl);

        if (has_self) {
            CODEGEN_ERROR(pof, "cannot have 'self' in a free function");
            return;
        }

        return;  // free function, no need to do any processing or checks
    }

    handle_static_self_fn_decl(func_decl, pof);
}

template <typename T>
concept HasVisiblityModifier = requires(T t) {
    { t->vis } -> std::same_as<__AST_N::Modifiers>;
};

inline void add_public(generator::CXIR::CXIR *self) {
    self->append(generator::CXIR::cxir_tokens::CXX_PUBLIC);
    self->append(generator::CXIR::cxir_tokens::CXX_COLON);
}

inline void add_protected(generator::CXIR::CXIR *self) {
    self->append(generator::CXIR::cxir_tokens::CXX_PROTECTED);
    self->append(generator::CXIR::cxir_tokens::CXX_COLON);
}

inline void add_private(generator::CXIR::CXIR *self) {
    self->append(generator::CXIR::cxir_tokens::CXX_PRIVATE);
    self->append(generator::CXIR::cxir_tokens::CXX_COLON);
}

inline void add_visibility(generator::CXIR::CXIR                      *self,
                           const __AST_N::NodeT<__AST_NODE::FuncDecl> &func_decl) {
    if (func_decl->modifiers.contains(__TOKEN_N::KEYWORD_PROTECTED)) {
        add_protected(self);
    } else if (func_decl->modifiers.contains(__TOKEN_N::KEYWORD_PRIVATE)) {
        add_private(self);
    } else {
        add_public(self);
    }
}

inline void add_visibility(generator::CXIR::CXIR                    *self,
                           const __AST_N::NodeT<__AST_NODE::OpDecl> &op_decl) {
    if (op_decl->modifiers.contains(__TOKEN_N::KEYWORD_PROTECTED)) {
        add_protected(self);
    } else if (op_decl->modifiers.contains(__TOKEN_N::KEYWORD_PRIVATE)) {
        add_private(self);
    } else {
        add_public(self);
    }
}

template <typename T>
inline void add_visibility(generator::CXIR::CXIR *self, const T &decl) {
    if constexpr (HasVisiblityModifier<T>) {
        if (decl->vis.contains(__TOKEN_N::KEYWORD_PROTECTED)) {
            add_protected(self);
        } else if (decl->vis.contains(__TOKEN_N::KEYWORD_PRIVATE)) {
            add_private(self);
        } else {
            add_public(self);
        }
    }
}

inline OperatorType determine_operator_type(const __AST_N::NodeT<__AST_NODE::OpDecl> &op_decl) {
    // check for self and static context
    auto [is_self, is_static] = contains_self_static(op_decl);

    // helper to detect array operators
    auto is_array_operator = [&]() -> bool {
        return op_decl->op.size() == 2 && op_decl->op[0] == __TOKEN_N::PUNCTUATION_OPEN_BRACKET &&
               op_decl->op[1] == __TOKEN_N::PUNCTUATION_CLOSE_BRACKET;
    };

    // helper to detect call operators
    auto is_call_operator = [&]() -> bool {
        return op_decl->op.size() == 2 && op_decl->op[0] == __TOKEN_N::PUNCTUATION_OPEN_PAREN &&
               op_decl->op[1] == __TOKEN_N::PUNCTUATION_CLOSE_PAREN;
    };

    // distinguish unary prefix vs unary postfix
    auto is_unary_postfix = [&]() -> bool {
        return op_decl->func->params.size() == 1 &&
               (op_decl->op[0] == __TOKEN_N::tokens::OPERATOR_R_INC ||
                op_decl->op[0] == __TOKEN_N::tokens::OPERATOR_R_DEC);
    };

    // handle member operators
    if (is_self) {
        if (is_call_operator()) {
            return OperatorType::Call;  // call operator `()`
        }

        if (op_decl->func->params.size() == 2) {  // (self, ...)
            if (is_array_operator()) {
                return OperatorType::Array;  // array operator `[]`
            }

            return OperatorType::Binary;  // binary operator
        }

        if (op_decl->func->params.size() == 1) {  // (self)
            if (is_unary_postfix()) {
                return OperatorType::UnaryPostfix;  // unary postfix operator `x++` or `x--`
            }

            return OperatorType::UnaryPrefix;  // unary prefix operator
        }

        if (op_decl->func->params.size() > 2) {  // (self, ..., ...)
            if (is_call_operator()) {
                return OperatorType::Array;  // array operator `[]`
            }

            return OperatorType::None;
        }
    }

    // handle static operators (free functions)
    if (is_static) {
        if (is_call_operator()) {
            return OperatorType::None;  // call operator `()`
        }

        /// check if the operator is a member only operator
        if (is_array_operator() || is_call_operator() ||
            (op_decl->op.size() > 0 &&
             (op_decl->op.back() == __TOKEN_N::tokens::OPERATOR_ARROW ||
              op_decl->op.back() == __TOKEN_N::tokens::PUNCTUATION_COMMA))) {
            return OperatorType::None;
        }

        if (op_decl->func->params.empty() || op_decl->func->params.size() == 0) {  // (...)
            if (is_call_operator()) {
                return OperatorType::Call;  // call operator `()`
            }

            return OperatorType::None;
        }

        if (op_decl->func->params.size() == 1) {  // (...)
            if (is_unary_postfix()) {
                return OperatorType::UnaryPostfix;  // unary postfix operator `x++` or `x--`
            }

            return OperatorType::UnaryPrefix;  // unary prefix operator
        }

        if (op_decl->func->params.size() == 2) {  // (..., ...)
            return OperatorType::Binary;          // binary operator
        }

        if (op_decl->func->params.size() > 2) {  // (..., ..., ...)
            return OperatorType::Call;
        }
    }

    return OperatorType::None;  // default case: no valid operator type
}

class Int {
  private:
    bool                 isNegative{};
    std::vector<uint8_t> digits;  // Each entry is a digit (0-9) for simplicity

    // Internal helper to multiply digits by base
    void multiplyByBase(uint8_t base) {
        uint16_t carry = 0;
        for (auto &digit : digits) {
            uint16_t result = digit * base + carry;
            digit           = result % 10;
            carry           = result / 10;
        }
        while (carry != 0U) {
            digits.push_back(carry % 10);
            carry /= 10;
        }
    }

    // Internal helper to add a digit
    void addDigit(uint8_t value) {
        uint16_t carry = value;
        for (auto &digit : digits) {
            uint16_t result = digit + carry;
            digit           = result % 10;
            carry           = result / 10;
            if (!carry) {
                break;
            }
        }
        while (carry != 0U) {
            digits.push_back(carry % 10);
            carry /= 10;
        }
    }

  public:
    Int() { digits.push_back(0); }

    explicit Int(const std::string &numStr) { parse(numStr); }

    // Parse a string in any valid numeric format
    void parse(const std::string &numStr) {
        digits.clear();
        isNegative = false;

        size_t start = 0;
        int    base  = 10;

        // Handle sign
        if (numStr[start] == '-') {
            isNegative = true;
            start++;
        } else if (numStr[start] == '+') {
            start++;
        }

        // Detect base
        if (numStr[start] == '0') {
            if (numStr[start + 1] == 'x' || numStr[start + 1] == 'X') {
                base = 16;
                start += 2;
            } else if (numStr[start + 1] == 'b' || numStr[start + 1] == 'B') {
                base = 2;
                start += 2;
            } else if (std::isdigit(numStr[start + 1])) {
                base = 8;
                start += 1;
            }
        }

        // Parse digits
        for (size_t i = start; i < numStr.size(); ++i) {
            char    c     = numStr[i];
            uint8_t value = 0;

            if (c >= '0' && c <= '9')
                value = c - '0';
            else if (c >= 'a' && c <= 'f')
                value = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                value = c - 'A' + 10;
            else
                throw std::invalid_argument("Invalid character in numeric string");

            if (value >= base)
                throw std::invalid_argument("Digit exceeds base");

            multiplyByBase(base);
            addDigit(value);
        }

        // Remove leading zeros
        while (digits.size() > 1 && digits.back() == 0)
            digits.pop_back();
    }

    enum class IntRange {
        NONE,

        I8,
        I16,
        I32,
        I64,
        I128,
        I256,

        U8,
        U16,
        U32,
        U64,
        U128,
        U256
    };

    IntRange determineRange() const {
        if (isNegative) {
            if (*this >= Int("-128")) {
                return IntRange::I8;
            }
            if (*this >= Int("-32768")) {
                return IntRange::I16;
            }
            if (*this >= Int("-2147483648")) {
                return IntRange::I32;
            }
            if (*this >= Int("-9223372036854775808")) {
                return IntRange::I64;
            }
            if (*this >= Int("-170141183460469231731687303715884105728")) {
                return IntRange::I128;
            }
            if (*this >= Int("-57896044618658097711785492504343953926634992332820282019728792003"
                             "956564819968")) {
                return IntRange::I256;
            }
        } else {
            if (*this <= Int("255")) {
                return IntRange::U8;
            }
            if (*this <= Int("65535")) {
                return IntRange::U16;
            }
            if (*this <= Int("4294967295")) {
                return IntRange::U32;
            }
            if (*this <= Int("18446744073709551615")) {
                return IntRange::U64;
            }
            if (*this <= Int("340282366920938463463374607431768211455")) {
                return IntRange::U128;
            }
            if (*this <= Int("115792089237316195423570985008687907853269984665640564039457584007"
                             "913129639935")) {
                return IntRange::U256;
            }
        }

        return IntRange::NONE;
    }

    bool operator==(const Int &other) const {
        return isNegative == other.isNegative && digits == other.digits;
    }

    bool operator!=(const Int &other) const { return !(*this == other); }

    bool operator<(const Int &other) const {
        if (isNegative != other.isNegative)
            return isNegative;
        if (digits.size() != other.digits.size()) {
            return isNegative ? digits.size() > other.digits.size()
                              : digits.size() < other.digits.size();
        }
        for (size_t i = 0; i < digits.size(); ++i) {
            if (digits[digits.size() - 1 - i] != other.digits[other.digits.size() - 1 - i]) {
                return isNegative ? digits[digits.size() - 1 - i] >
                                        other.digits[other.digits.size() - 1 - i]
                                  : digits[digits.size() - 1 - i] <
                                        other.digits[other.digits.size() - 1 - i];
            }
        }
        return false;
    }

    bool operator<=(const Int &other) const { return *this < other || *this == other; }

    bool operator>(const Int &other) const { return !(*this <= other); }

    bool operator>=(const Int &other) const { return !(*this < other); }

    // Print the number
    friend std::ostream &operator<<(std::ostream &os, const Int &num) {
        if (num.isNegative)
            os << '-';
        for (auto it = num.digits.rbegin(); it != num.digits.rend(); ++it)
            os << static_cast<char>('0' + *it);
        return os;
    }
};

struct OpType {
    enum Type {
        GeneratorOp,
        ContainsOp,
        CastOp,
        DeleteOp,
        MoveAssignOp,
        CopyAssignOp,
        Error,
        QuestionOp,
        PanicOp,
        None,
    };

    Type              type = None;
    __TOKEN_N::Token *tok  = nullptr;

    OpType(const __AST_NODE::OpDecl &op, bool in_udt) {
        if (in_udt) {
            type = det_t(op);
        }
    }

    Type det_t(const __AST_NODE::OpDecl &op) {
        /// see the token and signature
        if (op.op.size() < 1) {
            return None;
        }

        tok                   = const_cast<__TOKEN_N::Token *>(&op.op.front());
        auto [$self, $static] = contains_self_static(std::make_shared<__AST_NODE::OpDecl>(op));

        if (op.op.size() == 1 && op.op.back() == __TOKEN_N::KEYWORD_IN) {
            if ($static) {
                error::Panic(error::CodeError{
                    .pof          = tok,
                    .err_code     = 0.3002,
                    .err_fmt_args = {"the 'in' operator can not be marked static"}});

                return Error;
            }

            if (!$self) {
                error::Panic(error::CodeError{
                    .pof          = tok,
                    .err_code     = 0.3002,
                    .err_fmt_args = {"the 'in' operator must take a self paramater since it has to "
                                     "be a member function"}});

                return Error;
            }

            // check the signature we don't give a shit about the func name rn
            if ($self && op.func->params.size() == 1) {  // most likely GeneratorOp
                if (op.func->returns &&
                    op.func->returns->specifiers.contains(__TOKEN_N::KEYWORD_YIELD)) {
                    return GeneratorOp;
                }
            } else if ($self && op.func->params.size() == 2) {  // most likely ContainsOp
                if (op.func->returns &&
                    op.func->returns->value->getNodeType() == __AST_NODE::nodes::IdentExpr) {
                    // make sure the ret is a bool
                    auto node = __AST_N::as<__AST_NODE::IdentExpr>(op.func->returns->value);

                    if (node->is_reserved_primitive && node->name.value() == "bool") {
                        return ContainsOp;
                    }
                }
            }

            error::Panic(error::CodeError{
                .pof          = tok,
                .err_code     = 0.3002,
                .err_fmt_args = {"invalid 'in' operator, must be 'op in fn <name>(self) -> yield "
                                 "<type>' or 'op in fn <name>(self, arg: <type>) -> bool'"}});

            return Error;
        }

        if (op.op.size() == 1 && op.op.back() == __TOKEN_N::KEYWORD_AS) {
            // op as fn (self) -> string {}
            // the as op must take self as the only arg and return any type
            if ($static) {
                error::Panic(error::CodeError{
                    .pof          = tok,
                    .err_code     = 0.3002,
                    .err_fmt_args = {"can not mark 'as' operator with static, signature must be "
                                     "'op as fn (self) -> <type>'"}});

                return Error;
            }

            if (!op.func->returns) {
                error::Panic(error::CodeError{
                    .pof          = tok,
                    .err_code     = 0.3002,
                    .err_fmt_args = {"'as' operator must have a return type even if its void"}});

                return Error;
            }

            if ($self && op.func->params.size() == 1) {
                if (op.func->returns) {
                    return CastOp;
                }
            }

            error::Panic(error::CodeError{
                .pof          = tok,
                .err_code     = 0.3002,
                .err_fmt_args = {"invalid 'as' operator, must be 'op as fn (self) -> <type>'"}});

            return Error;
        }

        if (op.op.size() == 1 && op.op.back() == __TOKEN_N::KEYWORD_DELETE) {
            // delete can not take any parms but self, and must be in a udt, it can not return
            // anyhitng either

            if ($static) {
                error::Panic(error::CodeError{
                    .pof          = tok,
                    .err_code     = 0.3002,
                    .err_fmt_args = {
                        "can not mark 'delete' operator with static, signature must be "
                        "'op delete fn (self)' delete should not return anything even if its "
                        "'void'."}});

                return Error;
            }

            if ($self && op.func->params.size() == 1) {
                if (!op.func->returns) {
                    return DeleteOp;
                }
            }

            error::Panic(error::CodeError{
                .pof          = tok,
                .err_code     = 0.3002,
                .err_fmt_args = {"invalid 'delete' operator, must be 'op delete fn (self)' delete "
                                 "should not return anything even if its 'void'."}});

            return Error;
        }

        if (op.op.size() == 1 && op.op.back() == __TOKEN_N::OPERATOR_ASSIGN) {
            // ClassName& operator=(ClassName&&)
            // ClassName& operator=(const ClassName&)
            // signature for move assign is `op = fn (self, _: const ClassName&) -> ... {}`

            // for copy we need to check:
            // takes 2 params incl. self
            // the 1 param (excl. self) is a const ref to the class
            // the func is not marked static or const

            // for move we need to check:
            // takes 2 params incl. self
            // the 1 param (excl. self) is a rvalue ref to the class
            // the func is not marked static or const

            if ($static) {
                return None;  // neither move nor copy operator
            }
        }

        // panic operator signature is `op panic fn (self) -> string {}` or `static op panic fn ()
        // -> string {}`
        if (op.op.size() == 1 && op.op.back() == __TOKEN_N::KEYWORD_PANIC) {
            if ((($self && op.func->params.size() == 1) || ($static && op.func->params.empty())) &&
                op.func->returns &&
                op.func->returns->value->getNodeType() == __AST_NODE::nodes::IdentExpr &&
                __AST_N::as<__AST_NODE::IdentExpr>(op.func->returns->value)->name.value() ==
                    "string") {
                return PanicOp;
            }

            error::Panic(error::CodeError{
                .pof          = tok,
                .err_code     = 0.3002,
                .err_fmt_args = {
                    "invalid 'panic' operator, must be 'op panic fn (self) -> string' or 'static "
                    "op panic fn () -> string'"}});
        }

        // question operator signature is `op ? fn (self) -> bool {}`
        if (op.op.size() == 1 && op.op.back() == __TOKEN_N::PUNCTUATION_QUESTION_MARK) {
            if ($self && op.func->params.size() == 1 && op.func->returns &&
                op.func->returns->value->getNodeType() == __AST_NODE::nodes::IdentExpr &&
                __AST_N::as<__AST_NODE::IdentExpr>(op.func->returns->value)->name.value() ==
                    "bool") {
                return QuestionOp;
            }

            error::Panic(error::CodeError{
                .pof          = tok,
                .err_code     = 0.3002,
                .err_fmt_args = {"invalid '?' operator, must be 'op ? fn (self) -> bool'"}});

            return Error;
        }

        return None;
    }
};

inline void add_func_modifiers(__CXIR_CODEGEN_N::CXIR *self, __AST_N::Modifiers modifiers) {
    /*

    helix          | c++ (eq)
    -------------- | --------
    const          | const
    let eval       | constinit
    const eval     | consteval
    eval fn        | constexpr
    const eval fn  | const constexpr

    */

    if (modifiers.contains(__TOKEN_N::KEYWORD_INLINE)) {
        self->append(std ::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_INLINE, modifiers.get(__TOKEN_N::KEYWORD_INLINE)));
    }

    if (modifiers.contains(__TOKEN_N::KEYWORD_STATIC)) {
        self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_STATIC, modifiers.get(__TOKEN_N::KEYWORD_STATIC)));
    }

    if (modifiers.contains(__TOKEN_N::KEYWORD_CONST) &&
        modifiers.contains(__TOKEN_N::KEYWORD_EVAL)) {
        bool right_order = false;

        for (auto& mod : modifiers.get<__AST_N::FunctionSpecifier>()) {
            if (mod.type == __AST_N::FunctionSpecifier::Specifier::Eval) {
                break;
            }

            if (mod.type == __AST_N::FunctionSpecifier::Specifier::Const) {
                right_order = true;
                break;
            }
        }
        
        if (right_order) {
            self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                __CXIR_CODEGEN_N::cxir_tokens::CXX_CONSTEVAL, modifiers.get(__TOKEN_N::KEYWORD_EVAL)));
        } else {
            self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                __CXIR_CODEGEN_N::cxir_tokens::CXX_CONSTEXPR, modifiers.get(__TOKEN_N::KEYWORD_EVAL)));
        }
    } else if (modifiers.contains(__TOKEN_N::KEYWORD_EVAL)) {
        self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_CONSTEXPR, modifiers.get(__TOKEN_N::KEYWORD_EVAL)));
    } else if (modifiers.contains(__TOKEN_N::KEYWORD_VIRTUAL)) {
        self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_VIRTUAL, modifiers.get(__TOKEN_N::KEYWORD_VIRTUAL)));
    }
}

inline void add_func_specifiers(__CXIR_CODEGEN_N::CXIR *self, __AST_N::Modifiers modifiers) {
    if (modifiers.contains(__TOKEN_N::KEYWORD_CONST)) {
        self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_CONST, modifiers.get(__TOKEN_N::KEYWORD_CONST)));
    }

    if (modifiers.contains(__TOKEN_N::KEYWORD_NOPANIC)) {
        self->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_NOEXCEPT, modifiers.get(__TOKEN_N::KEYWORD_NOPANIC)));
    }
}

namespace __CXIR_CODEGEN_N {
class ModifyNestedFunctions {
  private:
    __CXIR_CODEGEN_N::CXIR *emitter = nullptr;

  public:
    ModifyNestedFunctions(__CXIR_CODEGEN_N::CXIR *emitter)
        : emitter(emitter) {}

    bool operator()(const __AST_N::NodeT<> &elm) const {
        emitter->append(std::make_unique<CX_Token>(CXX_SEMICOLON));

        if (elm->getNodeType() == __AST_NODE::nodes::FuncDecl) {
            __AST_N::NodeT<__AST_NODE::FuncDecl> func_decl = __AST_N::as<__AST_NODE::FuncDecl>(elm);

            if (func_decl->name != nullptr) {
                emitter->append(std::make_unique<CX_Token>(CXX_AUTO));
                emitter->append(std::make_unique<CX_Token>(CXX_CORE_IDENTIFIER,
                                                           func_decl->name->get_back_name().value(),
                                                           func_decl->marker));
                emitter->append(std::make_unique<CX_Token>(CXX_EQUAL));
            }

            emitter->append(std::make_unique<CX_Token>(CXX_LBRACKET));
            emitter->append(std::make_unique<CX_Token>(CXX_RBRACKET));

            if (func_decl->generics) {
                emitter->append(std::make_unique<CX_Token>(CXX_LESS));
                func_decl->generics->params->accept(*emitter);
                emitter->append(std::make_unique<CX_Token>(CXX_GREATER));
            }

            emitter->append(std::make_unique<CX_Token>(CXX_LPAREN));
            if (!func_decl->params.empty()) {
                if (func_decl->params[0] != nullptr) {
                    func_decl->params[0]->accept(*emitter);
                };
                for (size_t i = 1; i < func_decl->params.size(); ++i) {
                    emitter->append(std::make_unique<CX_Token>(CXX_CORE_OPERATOR, ","));
                    ;
                    if (func_decl->params[i] != nullptr) {
                        func_decl->params[i]->accept(*emitter);
                    };
                }
            };
            emitter->append(std::make_unique<CX_Token>(CXX_RPAREN));

            emitter->append(std::make_unique<CX_Token>(CXX_PTR_ACC));

            if (func_decl->returns) {
                func_decl->returns->accept(*emitter);
            } else {
                emitter->append(std::make_unique<CX_Token>(CXX_VOID, func_decl->marker));
            }

            if (func_decl->generics) {
                if (func_decl->generics->bounds) {
                    emitter->append(std::make_unique<CX_Token>(CXX_REQUIRES));
                    func_decl->generics->bounds->accept(*emitter);
                }
            }

            func_decl->body->accept(*emitter);
            emitter->append(std::make_unique<CX_Token>(CXX_SEMICOLON));
            return true;
        }

        if (elm->getNodeType() == __AST_NODE::nodes::OpDecl) {
            __AST_N::NodeT<__AST_NODE::OpDecl> func_decl = __AST_N::as<__AST_NODE::OpDecl>(elm);

            error::Panic _(error::CodeError{
                .pof          = &func_decl->func->marker,
                .err_code     = 0.0001,
                .err_fmt_args = {"operator declarenanos are not allowed in functions, remove it or "
                                 "modify the function to be a functor."}});

            return true;
        }

        if (elm->getNodeType() == __AST_NODE::nodes::LetDecl) {
            __AST_N::NodeT<__AST_NODE::LetDecl> node = __AST_N::as<__AST_NODE::LetDecl>(elm);
            emitter->visit(*node, true);
            emitter->append(std::make_unique<CX_Token>(CXX_SEMICOLON));

            return true;
        }

        elm->accept(*emitter);
        return true;
    }
};

inline void check_for_yield_and_panic(const __AST_N::NodeT<__AST_NODE::SuiteState> &body,
                                      const __AST_N::NodeT<__AST_NODE::Type>       &return_type) {
    // we check for 2 rules here panic and yield
    // panic: if the body of a function/operator contains a panic statement then the return type
    // must be nullable yield: if the body of a function/operator contains a yield statement then
    // the return type must have a yield specifier

    if (body == nullptr) {
        return;
    }

    bool has_panic = false;
    bool has_yield = false;

    __TOKEN_N::Token panic_marker;
    __TOKEN_N::Token yield_marker;

    for (auto &child : body->body->body) {
        if (child->getNodeType() == __AST_NODE::nodes::PanicState) { // if panic is there then warn and change the panic to throw instead
            has_panic    = true;
            panic_marker = __AST_N::as<__AST_NODE::PanicState>(child)->marker;
            auto panic  = __AST_N::as<__AST_NODE::PanicState>(child);
            panic->crash = true;

        } else if (child->getNodeType() == __AST_NODE::nodes::YieldState) {
            has_yield    = true;
            yield_marker = __AST_N::as<__AST_NODE::YieldState>(child)->marker;
        }
    }

    if (has_panic && !return_type->nullable) {
        error::Panic(error::CodeError{.pof = &return_type->marker, .err_code = 0.3008, .level = error::Level::WARN});
        error::Panic(error::CodeError{
            .pof = &panic_marker, .err_code = 0.3018, .mark_pof = false, .fix_fmt_args = {}, .err_fmt_args = {}, .opt_fixes = {}, .level = error::Level::NONE, .indent = 1});
    }

    if (has_yield && !return_type->specifiers.contains(token::tokens::KEYWORD_YIELD)) {
        error::Panic(error::CodeError{.pof = &return_type->marker, .err_code = 0.3009});
        error::Panic(error::CodeError{
            .pof = &yield_marker, .err_code = 0.3019, .mark_pof = false, .fix_fmt_args = {}, .err_fmt_args = {}, .opt_fixes = {}, .level = error::Level::NONE, .indent = 1});
    }
}

inline void default_constructor(CXIR *self, const __AST_N::NodeT<__AST_NODE::IdentExpr> &name) {
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_PUBLIC));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_COLON));

    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_DEFAULT, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
}

inline void default_destructor(CXIR *self, const __AST_N::NodeT<__AST_NODE::IdentExpr> &name) {
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_PUBLIC));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_COLON));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_TILDE, name->name));
    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_DEFAULT, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
}

inline void delete_copy_constructor(CXIR *self, const __AST_N::NodeT<__AST_NODE::IdentExpr> &name) {
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_PUBLIC));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_COLON));

    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_CONST, name->name));
    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_AMPERSAND, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_DEFAULT, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
}

inline void delete_copy_assignment(CXIR *self, const __AST_N::NodeT<__AST_NODE::IdentExpr> &name) {
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_PUBLIC));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_COLON));

    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_AMPERSAND, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_OPERATOR, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_CONST, name->name));
    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_AMPERSAND, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_DEFAULT, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
}

inline void default_move_constructor(CXIR                                        *self,
                                     const __AST_N::NodeT<__AST_NODE::IdentExpr> &name) {
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_PUBLIC));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_COLON));

    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_AMPERSAND, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_NOEXCEPT));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_DEFAULT, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
}

inline void default_move_assignment(CXIR *self, const __AST_N::NodeT<__AST_NODE::IdentExpr> &name) {
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_PUBLIC));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_COLON));

    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_AMPERSAND, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_OPERATOR, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
    self->append(std::make_unique<CX_Token>(
        cxir_tokens::CXX_CORE_IDENTIFIER, name->name.value(), name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_AMPERSAND, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_NOEXCEPT));

    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_ASSIGN));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_DEFAULT, name->name));
    self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
}

class Validator {
  public:
    virtual ~Validator() = default;
    virtual bool validate(const std::shared_ptr<__AST_NODE::ArgumentExpr> & /* unused */) const {
        return true;
    };
};

template <__AST_NODE::ArgumentExpr::ArgumentType argType,
          __AST_NODE::LiteralExpr::LiteralType   litType>
struct ArgumentValidate : public Validator {
    ArgumentValidate() = delete;
    explicit ArgumentValidate(std::string value)
        : expected_value(std::move(value)) {}
    explicit ArgumentValidate(std::string name, std::string value)
        : expected_name(std::move(name))
        , expected_value(std::move(value))
        , has_name(true) {}

    [[nodiscard]] bool validate(const std::shared_ptr<__AST_NODE::ArgumentExpr> &arg) const {
        if (arg->type == __AST_NODE::ArgumentExpr::ArgumentType::Positional) {
            if (has_name) {
                return false;
            }

            if (arg->value->getNodeType() != __AST_NODE::nodes::LiteralExpr) {
                return false;
            }

            auto literal = __AST_N::as<__AST_NODE::LiteralExpr>(arg->value);
            return literal->type == litType && literal->value.value() == expected_value;
        }

        if (arg->type == __AST_NODE::ArgumentExpr::ArgumentType::Keyword) {
            if (!has_name) {
                return false;
            }

            if (arg->value->getNodeType() != __AST_NODE::nodes::NamedArgumentExpr) {
                return false;
            }

            auto named = __AST_N::as<__AST_NODE::NamedArgumentExpr>(arg->value);
            if (named->name->name.value() != expected_name) {
                return false;
            }

            auto literal = __AST_N::as<__AST_NODE::LiteralExpr>(named->value);
            return literal->type == litType && literal->value.value() == expected_value;
        }

        return false;
    }

    std::string expected_value;
    std::string expected_name;
    bool        has_name = false;
};

template <size_t NumArgs>
struct ValidateFunctionDirective {
    std::string                    directiveName;
    std::array<Validator, NumArgs> validators;

    template <typename... Validators>
        requires(sizeof...(Validators) == NumArgs &&
                 (std::is_base_of_v<Validator, Validators> && ...))
    ValidateFunctionDirective(std::string name, Validators &&...args)
        : directiveName(std::move(name))
        , validators({std::forward<Validator>(args)...}) {

        // make sure all the validators have a bool validate(const
        // std::shared_ptr<__AST_NODE::ArgumentExpr>& arg) const method
        static_assert(sizeof...(args) == NumArgs,
                      "Number of validators must match the number of arguments");
    }

    [[nodiscard]] bool validate(const std::shared_ptr<__AST_NODE::FunctionCallExpr> &call) const {
        if ((call->path->path_length() != 1 ||
             call->path->get_back_name().value() != directiveName) ||
            (call->args->getNodeType() != __AST_NODE::nodes::ArgumentListExpr)) {
            return false;
        }

        auto args = __AST_N::as<__AST_NODE::ArgumentListExpr>(call->args);

        if (args->args.size() != NumArgs) {
            return false;
        }

        for (size_t i = 0; i < NumArgs; ++i) {
            if (args->args[i]->getNodeType() != __AST_NODE::nodes::ArgumentExpr) {
                return false;
            }

            auto arg = __AST_N::as<__AST_NODE::ArgumentExpr>(args->args[i]);
            if (!validators[i].validate(arg)) {
                return false;
            }
        }

        return true;
    }
};

inline bool contains_trivial_import_directive(const __AST_N::NodeV<> &directives) {
    if (directives.empty()) {
        return false;
    }

    auto validator = __CXIR_CODEGEN_N::ValidateFunctionDirective<1>(
        "trivially_import",
        __CXIR_CODEGEN_N::ArgumentValidate<
            __AST_NODE::ArgumentExpr::ArgumentType::Positional,
            __AST_NODE::LiteralExpr::LiteralType::Boolean>
            ("true")
    );

    return std::ranges::any_of(directives, [&](const auto &directive) {
        if (directive->getNodeType() == __AST_NODE::nodes::FunctionCallExpr) {
            auto call = __AST_N::as<__AST_NODE::FunctionCallExpr>(directive);

            if (validator.validate(call)) {
                return true;
            }
        }
        return false;
    });
}

}  // namespace __CXIR_CODEGEN_N

#endif  // __CX_UTILS__