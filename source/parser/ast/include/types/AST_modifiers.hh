//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).       //
//  You are allowed to use, modify, redistribute, and create derivative works, even for           //
//  commercial purposes, provided that you give appropriate credit, and indicate if changes       //
//   were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/  //
//                                                                                                //
//  SPDX-License-Identifier: CC-BY-4.0                                                            //
//  Copyright (c) 2024 (CC BY 4.0)                                                                //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//
//                                                                                                //
//  @author @ze71111                                                                              //
//                                                                                                //
//===-----------------------------------------------------------------------------------------====//

#ifndef __MODIFIERS_H__
#define __MODIFIERS_H__

#include <unordered_map>
#include <unordered_set>
#include <variant>
#include <vector>

#include "neo-json/include/json.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/config/AST_config.def"
#include "token/include/Token.hh"

// Specifier - the part before the signature
// Qualifier - the part after the signature

bool is_excepted(const __TOKEN_N::Token &tok, const std::unordered_set<__TOKEN_TYPES_N> &tokens);

__AST_BEGIN {
    struct StorageSpecifier {
        enum class Specifier : char {
            Ffi,     ///< 'ffi'
            Static,  ///< 'static'
        };

        static bool is_storage_specifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_FFI || tok == __TOKEN_N::KEYWORD_STATIC;
        }

        explicit StorageSpecifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_FFI:
                    type = Specifier::Ffi;
                    break;
                case __TOKEN_N::KEYWORD_STATIC:
                    type = Specifier::Static;
                    break;
                default:
                    throw std::runtime_error("Invalid storage specifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("StorageSpecifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Specifier        type;
    };

    struct FFIQualifier {  // excepted after the ffi keyword
        enum class Qualifier : char {
            Class,      ///< 'class'
            Interface,  ///< 'interface'
            Struct,     ///< 'struct'
            Enum,       ///< 'enum'
            Union,      ///< 'union'
            Type,       ///< 'type'
        };

        static bool is_ffi_specifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_CLASS || tok == __TOKEN_N::KEYWORD_INTERFACE ||
                   tok == __TOKEN_N::KEYWORD_STRUCT || tok == __TOKEN_N::KEYWORD_ENUM ||
                   tok == __TOKEN_N::KEYWORD_UNION || tok == __TOKEN_N::KEYWORD_TYPE;
        }

        explicit FFIQualifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_CLASS:
                    type = Qualifier::Class;
                    break;
                case __TOKEN_N::KEYWORD_INTERFACE:
                    type = Qualifier::Interface;
                    break;
                case __TOKEN_N::KEYWORD_STRUCT:
                    type = Qualifier::Struct;
                    break;
                case __TOKEN_N::KEYWORD_ENUM:
                    type = Qualifier::Enum;
                    break;
                case __TOKEN_N::KEYWORD_UNION:
                    type = Qualifier::Union;
                    break;
                case __TOKEN_N::KEYWORD_TYPE:
                    type = Qualifier::Type;
                    break;
                default:
                    throw std::runtime_error("Invalid ffi specifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("FFIQualifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Qualifier        type;
    };

    struct TypeSpecifier {
        enum class Specifier : char {
            Const,   ///< 'const'
            Yield,   ///< 'yield'
            Async,   ///< 'async'
            Module,  ///< 'module'
            Ffi,     ///< 'ffi'
            Unsafe,  ///< 'unsafe'
            Static,  ///< 'static'
        };

        static bool is_type_qualifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_CONST || tok == __TOKEN_N::KEYWORD_MODULE ||
                   tok == __TOKEN_N::KEYWORD_YIELD || tok == __TOKEN_N::KEYWORD_ASYNC ||
                   tok == __TOKEN_N::KEYWORD_FFI || tok == __TOKEN_N::KEYWORD_UNSAFE ||
                   tok == __TOKEN_N::KEYWORD_STATIC;
        }

        explicit TypeSpecifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_CONST:
                    type = Specifier::Const;
                    break;
                case __TOKEN_N::KEYWORD_MODULE:
                    type = Specifier::Module;
                    break;
                case __TOKEN_N::KEYWORD_YIELD:
                    type = Specifier::Yield;
                    break;
                case __TOKEN_N::KEYWORD_ASYNC:
                    type = Specifier::Async;
                    break;
                case __TOKEN_N::KEYWORD_FFI:
                    type = Specifier::Ffi;
                    break;
                case __TOKEN_N::KEYWORD_UNSAFE:
                    type = Specifier::Unsafe;
                    break;
                case __TOKEN_N::KEYWORD_STATIC:
                    type = Specifier::Static;
                    break;
                default:
                    throw std::runtime_error("Invalid type specifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("TypeSpecifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Specifier        type;
    };

    struct AccessSpecifier {
        enum class Specifier : char {
            Public,     ///< 'pub' - default = exposed by linkage and visibility
            Private,    ///< 'priv'          = not exposed by linkage and visibility
            Protected,  ///< 'prot'          = not exposed by linkage but by visibility
            Internal    ///< 'intl'          = exposed by linkage but not visibility
        };

        static bool is_access_specifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_PUBLIC || tok == __TOKEN_N::KEYWORD_PRIVATE ||
                   tok == __TOKEN_N::KEYWORD_PROTECTED || tok == __TOKEN_N::KEYWORD_INTERNAL;
        }

        explicit AccessSpecifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_PUBLIC:
                    type = Specifier::Public;
                    break;
                case __TOKEN_N::KEYWORD_PRIVATE:
                    type = Specifier::Private;
                    break;
                case __TOKEN_N::KEYWORD_PROTECTED:
                    type = Specifier::Protected;
                    break;
                case __TOKEN_N::KEYWORD_INTERNAL:
                    type = Specifier::Internal;
                    break;
                default:
                    throw std::runtime_error("Invalid access specifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("AccessSpecifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Specifier        type;
    };

    struct FunctionSpecifier {  // the part before the function signature
        enum class Specifier : char {
            Inline,   ///< 'inline'
            Async,    ///< 'async'
            Static,   ///< 'static'
            Const,    ///< 'const' - in functions this is 'const' but for classes its 'final'
            Eval,     ///< 'eval' - eval in the case of functions default to 'constinit' for
                      ///           'constexpr' or 'consteval' use 'const eval'
            Override, ///< 'override'
            Virtual,  ///< 'virtual'
            Delete,  ///< 'discard'
            NoPanic,  ///< 'no_panic'
            Default,  ///< 'default'
        };

        static bool is_function_specifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_INLINE  || tok == __TOKEN_N::KEYWORD_ASYNC    ||
                   tok == __TOKEN_N::KEYWORD_STATIC  || tok == __TOKEN_N::KEYWORD_CONST    ||
                   tok == __TOKEN_N::KEYWORD_EVAL    || tok == __TOKEN_N::KEYWORD_VIRTUAL  ||
                   tok == __TOKEN_N::KEYWORD_OVERRIDE|| tok == __TOKEN_N::KEYWORD_DEFAULT  ||
                   tok == __TOKEN_N::KEYWORD_NOPANIC || tok == __TOKEN_N::KEYWORD_DELETE;
        }

        explicit FunctionSpecifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_INLINE:
                    type = Specifier::Inline;
                    break;
                case __TOKEN_N::KEYWORD_ASYNC:
                    type = Specifier::Async;
                    break;
                case __TOKEN_N::KEYWORD_STATIC:
                    type = Specifier::Static;
                    break;
                case __TOKEN_N::KEYWORD_CONST:
                    type = Specifier::Const;
                    break;
                case __TOKEN_N::KEYWORD_EVAL:
                    type = Specifier::Eval;
                    break;
                case __TOKEN_N::KEYWORD_OVERRIDE:
                    type = Specifier::Override;
                    break;
                case __TOKEN_N::KEYWORD_VIRTUAL:
                    type = Specifier::Virtual;
                    break;
                case __TOKEN_N::KEYWORD_DELETE:
                    type = Specifier::Delete;
                    break;
                case __TOKEN_N::KEYWORD_NOPANIC:
                    type = Specifier::NoPanic;
                    break;
                case __TOKEN_N::KEYWORD_DEFAULT:
                    type = Specifier::Default;
                    break;
                default:
                    throw std::runtime_error("Invalid function specifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("FunctionSpecifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Specifier        type;
    };

    struct FunctionQualifier {
        enum class Qualifier : char {  // the part after the function signature
            Default,                   ///< 'default'
            Panic,                     ///< 'panic'
            Delete,                    ///< 'delete'
            Const,                     ///< 'const'
        };

        static bool is_function_qualifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_DEFAULT || tok == __TOKEN_N::KEYWORD_PANIC ||
                   tok == __TOKEN_N::KEYWORD_DELETE || tok == __TOKEN_N::KEYWORD_CONST;
        }

        explicit FunctionQualifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_DEFAULT:
                    type = Qualifier::Default;
                    break;
                case __TOKEN_N::KEYWORD_PANIC:
                    type = Qualifier::Panic;
                    break;
                case __TOKEN_N::KEYWORD_DELETE:
                    type = Qualifier::Delete;
                    break;
                case __TOKEN_N::KEYWORD_CONST:
                    type = Qualifier::Const;
                    break;
                default:
                    throw std::runtime_error("Invalid function qualifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("FunctionQualifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Qualifier        type;
    };

    struct ClassSpecifier {
        enum class Specifier : char {
            Static,  ///< 'static'
            Const,   ///< 'const' - in functions this is 'const' but for classes its 'final'
            Default,  ///< 'default'
        };

        static bool is_class_specifier(const __TOKEN_N::Token &tok) {
            return tok == __TOKEN_N::KEYWORD_CONST || tok == __TOKEN_N::KEYWORD_STATIC || tok == __TOKEN_N::KEYWORD_DEFAULT;
        }

        explicit ClassSpecifier(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {
            switch (marker.token_kind()) {
                case __TOKEN_N::KEYWORD_CONST:
                    type = Specifier::Const;
                    break;
                case __TOKEN_N::KEYWORD_STATIC:
                    type = Specifier::Static;
                    break;
                case __TOKEN_N::KEYWORD_DEFAULT:
                    type = Specifier::Default;
                    break;
                default:
                    throw std::runtime_error("Invalid class specifier");
                    break;
            }
        }

        TO_NEO_JSON_IMPL {
            neo::json json("ClassSpecifier");

            json.add("type", (int)type).add("marker", marker);

            return json;
        }

        __TOKEN_N::Token marker;
        Specifier        type;
    };

    struct Modifiers {
      public:
        enum class ExpectedModifier : char {
            StorageSpec,  ///< 'ffi' | 'static'
            FfiSpec,      ///< 'class' | 'interface' | 'struct' | 'enum' | 'union' | 'type'
            TypeSpec,     ///< 'const' | 'module' | 'yield' | 'async' | 'ffi' | 'unsafe'
            AccessSpec,   ///< 'pub' | 'priv' | 'prot' | 'intl'
            FuncSpec,     ///< 'inline' | 'async' | 'static' | 'const' | 'eval'
            FuncQual,     ///< 'default' | 'panic' | 'delete' | 'const'
            ClassSpec,    ///< 'const' | 'static' | 'default'
        };

      private:
        std::vector<ExpectedModifier>                                      expected_modifiers;
        std::unordered_set<__TOKEN_TYPES_N>                                allowed_modifiers;
        std::unordered_map<ExpectedModifier, std::vector<__TOKEN_TYPES_N>> modifiers_map = {
            {ExpectedModifier::StorageSpec, {__TOKEN_N::KEYWORD_FFI, __TOKEN_N::KEYWORD_STATIC}},
            {ExpectedModifier::FfiSpec,
             {__TOKEN_N::KEYWORD_CLASS,
              __TOKEN_N::KEYWORD_INTERFACE,
              __TOKEN_N::KEYWORD_STRUCT,
              __TOKEN_N::KEYWORD_ENUM,
              __TOKEN_N::KEYWORD_UNION,
              __TOKEN_N::KEYWORD_TYPE}},
            {ExpectedModifier::TypeSpec,
             {__TOKEN_N::KEYWORD_CONST,
              __TOKEN_N::KEYWORD_MODULE,
              __TOKEN_N::KEYWORD_YIELD,
              __TOKEN_N::KEYWORD_ASYNC,
              __TOKEN_N::KEYWORD_FFI,
              __TOKEN_N::KEYWORD_UNSAFE,
              __TOKEN_N::KEYWORD_STATIC}},
            {ExpectedModifier::AccessSpec,
             {__TOKEN_N::KEYWORD_PUBLIC,
              __TOKEN_N::KEYWORD_PRIVATE,
              __TOKEN_N::KEYWORD_PROTECTED,
              __TOKEN_N::KEYWORD_INTERNAL}},
            {ExpectedModifier::FuncSpec,
             {__TOKEN_N::KEYWORD_INLINE,
              __TOKEN_N::KEYWORD_ASYNC,
              __TOKEN_N::KEYWORD_STATIC,
              __TOKEN_N::KEYWORD_CONST,
              __TOKEN_N::KEYWORD_VIRTUAL,
            __TOKEN_N::KEYWORD_OVERRIDE,
            __TOKEN_N::KEYWORD_DEFAULT,
            __TOKEN_N::KEYWORD_NOPANIC,
            __TOKEN_N::KEYWORD_DELETE,
              __TOKEN_N::KEYWORD_EVAL}},
            {ExpectedModifier::FuncQual,
             {__TOKEN_N::KEYWORD_DEFAULT,
              __TOKEN_N::KEYWORD_PANIC,
              __TOKEN_N::KEYWORD_DELETE,
              __TOKEN_N::KEYWORD_CONST}},
            {ExpectedModifier::ClassSpec, {__TOKEN_N::KEYWORD_CONST, __TOKEN_N::KEYWORD_STATIC, __TOKEN_N::KEYWORD_DEFAULT}}};


      public:
        std::vector<std::variant<StorageSpecifier,
                                 FFIQualifier,
                                 TypeSpecifier,
                                 AccessSpecifier,
                                 FunctionSpecifier,
                                 FunctionQualifier,
                                 ClassSpecifier>>
            modifiers;
            
        template <typename... Args>
        explicit Modifiers(Args &&...args)
            : expected_modifiers{std::forward<Args>(args)...} {
            for (const auto &modifier : expected_modifiers) {
                const auto &tokens = modifiers_map[modifier];
                allowed_modifiers.insert(tokens.begin(), tokens.end());
            }
        }

        // so if we set the modifiers to another Modifiers object
        // we can copy the expected_modifiers and allowed_modifiers and verify if the other
        // object has the modifiers we are looking for

        static bool is_modifier(const __TOKEN_N::Token &tok, ExpectedModifier modifier) {
            switch (modifier) {
                case ExpectedModifier::StorageSpec:
                    return StorageSpecifier::is_storage_specifier(tok);
                case ExpectedModifier::FfiSpec:
                    return FFIQualifier::is_ffi_specifier(tok);
                case ExpectedModifier::TypeSpec:
                    return TypeSpecifier::is_type_qualifier(tok);
                case ExpectedModifier::AccessSpec:
                    return AccessSpecifier::is_access_specifier(tok);
                case ExpectedModifier::FuncSpec:
                    return FunctionSpecifier::is_function_specifier(tok);
                case ExpectedModifier::FuncQual:
                    return FunctionQualifier::is_function_qualifier(tok);
                case ExpectedModifier::ClassSpec:
                    return ClassSpecifier::is_class_specifier(tok);
                default:
                    return false;
            }
        }
        static bool is_modifier(const __TOKEN_N::Token &tok) {
            return StorageSpecifier::is_storage_specifier(tok) ||
                   AccessSpecifier::is_access_specifier(tok) ||
                   FunctionSpecifier::is_function_specifier(tok) ||
                   ClassSpecifier::is_class_specifier(tok);
        }

        [[nodiscard]] bool find_add(const __TOKEN_N::Token &current_token) {

            if (allowed_modifiers.find(current_token.token_kind()) == allowed_modifiers.end()) {
                return false;  // not a modifier
            }

            for (const auto &modifier_type : expected_modifiers) {
                if (is_modifier(current_token, modifier_type)) {
                    switch (modifier_type) {
                        case ExpectedModifier::StorageSpec:
                            modifiers.emplace_back(StorageSpecifier(current_token));
                            break;
                        case ExpectedModifier::FfiSpec:
                            modifiers.emplace_back(FFIQualifier(current_token));
                            break;
                        case ExpectedModifier::TypeSpec:
                            modifiers.emplace_back(TypeSpecifier(current_token));
                            break;
                        case ExpectedModifier::AccessSpec:
                            modifiers.emplace_back(AccessSpecifier(current_token));
                            break;
                        case ExpectedModifier::FuncSpec:
                            modifiers.emplace_back(FunctionSpecifier(current_token));
                            break;
                        case ExpectedModifier::FuncQual:
                            modifiers.emplace_back(FunctionQualifier(current_token));
                            break;
                        case ExpectedModifier::ClassSpec:
                            modifiers.emplace_back(ClassSpecifier(current_token));
                            break;
                        default:
                            return false;
                    }

                    return true;
                }
            }

            return false;
        }

        template <typename T>
        [[nodiscard]] std::vector<T> get() const {
            std::vector<T> result;

            for (const auto &modifier : modifiers) {
                if (std::holds_alternative<T>(modifier)) {
                    result.push_back(std::get<T>(modifier));
                }
            }

            return result;
        }

        [[nodiscard]] bool empty() const { return modifiers.empty(); }

        void clear() { modifiers.clear(); }

        explicit operator bool() const { return !empty(); }

        [[nodiscard]] size_t size() const { return modifiers.size(); }

        template <typename T>
        [[nodiscard]] T first() {
            if (modifiers.empty()) {
                throw std::runtime_error("No modifiers found");
            }

            return std::get<T>(modifiers.front());
        }

        template <typename T>
        [[nodiscard]] T last() {
            if (modifiers.empty()) {
                throw std::runtime_error("No modifiers found");
            }

            return std::get<T>(modifiers.back());
        }

        template <typename T>
        [[nodiscard]] T pop_first() {
            if (modifiers.empty()) {
                throw std::runtime_error("No modifiers found");
            }

            T result = std::get<T>(modifiers.front());
            modifiers.erase(modifiers.begin());
            return result;
        }

        template <typename T>
        [[nodiscard]] T pop_last() {
            if (modifiers.empty()) {
                throw std::runtime_error("No modifiers found");
            }

            T result = std::get<T>(modifiers.back());
            modifiers.pop_back();
            return result;
        }

        template <typename T>
        void remove(long long index) {
            if (index >= static_cast<long long>(modifiers.size())) {
                throw std::runtime_error("Index out of bounds");
            }

            modifiers.erase(modifiers.begin() + index);
        }

        [[nodiscard]] bool contains(const token::tokens &token_kind) const {
            return std::ranges::any_of(modifiers, [&](const auto &modifier) {
                if (std::holds_alternative<StorageSpecifier>(modifier)) {
                    return std::get<StorageSpecifier>(modifier).marker.token_kind() == token_kind;
                }

                if (std::holds_alternative<FFIQualifier>(modifier)) {
                    return std::get<FFIQualifier>(modifier).marker.token_kind() == token_kind;
                }

                if (std::holds_alternative<TypeSpecifier>(modifier)) {
                    return std::get<TypeSpecifier>(modifier).marker.token_kind() == token_kind;
                }

                if (std::holds_alternative<AccessSpecifier>(modifier)) {
                    return std::get<AccessSpecifier>(modifier).marker.token_kind() == token_kind;
                }

                if (std::holds_alternative<FunctionSpecifier>(modifier)) {
                    return std::get<FunctionSpecifier>(modifier).marker.token_kind() == token_kind;
                }

                if (std::holds_alternative<FunctionQualifier>(modifier)) {
                    return std::get<FunctionQualifier>(modifier).marker.token_kind() == token_kind;
                }

                if (std::holds_alternative<ClassSpecifier>(modifier)) {
                    return std::get<ClassSpecifier>(modifier).marker.token_kind() == token_kind;
                }

                return false;
            });
        }

        [[nodiscard]] token::Token get(const token::tokens &token_kind) const {
            for (auto &mod : modifiers) {
                if (std::holds_alternative<StorageSpecifier>(mod)) {
                    if (std::get<StorageSpecifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<StorageSpecifier>(mod).marker;
                    }
                }

                if (std::holds_alternative<FFIQualifier>(mod)) {
                    if (std::get<FFIQualifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<FFIQualifier>(mod).marker;
                    }
                }

                if (std::holds_alternative<TypeSpecifier>(mod)) {
                    if (std::get<TypeSpecifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<TypeSpecifier>(mod).marker;
                    }
                }

                if (std::holds_alternative<AccessSpecifier>(mod)) {
                    if (std::get<AccessSpecifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<AccessSpecifier>(mod).marker;
                    }
                }

                if (std::holds_alternative<FunctionSpecifier>(mod)) {
                    if (std::get<FunctionSpecifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<FunctionSpecifier>(mod).marker;
                    }
                }

                if (std::holds_alternative<FunctionQualifier>(mod)) {
                    if (std::get<FunctionQualifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<FunctionQualifier>(mod).marker;
                    }
                }

                if (std::holds_alternative<ClassSpecifier>(mod)) {
                    if (std::get<ClassSpecifier>(mod).marker.token_kind() == token_kind) {
                        return std::get<ClassSpecifier>(mod).marker;
                    }
                }
            }

            return token::Token();
        }

        template <typename T>
        void add(T modifier) {
            modifiers.push_back(modifier);
        }

        TO_NEO_JSON_IMPL {
            neo::json              json("Modifiers");
            std::vector<neo::json> modifiers_json;

            for (const auto &modifier : modifiers) {
                if (std::holds_alternative<StorageSpecifier>(modifier)) {
                    modifiers_json.push_back(std::get<StorageSpecifier>(modifier).to_json());
                } else if (std::holds_alternative<FFIQualifier>(modifier)) {
                    modifiers_json.push_back(std::get<FFIQualifier>(modifier).to_json());
                } else if (std::holds_alternative<TypeSpecifier>(modifier)) {
                    modifiers_json.push_back(std::get<TypeSpecifier>(modifier).to_json());
                } else if (std::holds_alternative<AccessSpecifier>(modifier)) {
                    modifiers_json.push_back(std::get<AccessSpecifier>(modifier).to_json());
                } else if (std::holds_alternative<FunctionSpecifier>(modifier)) {
                    modifiers_json.push_back(std::get<FunctionSpecifier>(modifier).to_json());
                } else if (std::holds_alternative<FunctionQualifier>(modifier)) {
                    modifiers_json.push_back(std::get<FunctionQualifier>(modifier).to_json());
                } else if (std::holds_alternative<ClassSpecifier>(modifier)) {
                    modifiers_json.push_back(std::get<ClassSpecifier>(modifier).to_json());
                }
            }

            json.add("modifiers", modifiers_json);
            return json;
        }
    };
}

#endif  // __MODIFIERS_H__