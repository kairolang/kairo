/// --- The Kairo Project ------------------- Codegen/Emit/EmitTypes.k ----- ///
///
///   \brief Type-position emission. Walks a ChainType and emits its segments
///          verbatim, separated by `::`. That is the whole file.
///
///   \par There is no builtin table here, on purpose
///     `i32` is emitted as `i32`. If the C++ output needs `::kairo::i32`,
///     Sema's Lower/ stage rewrites the ChainType into three segments   a
///     leading `::`, `kairo`, `i32`   interning the new identifiers and
///     stamping each with the ORIGINAL `i32` token's range. Codegen then
///     emits exactly what it is handed and the carets still land on the four
///     bytes the user typed.
///
///     Codegen cannot own that mapping. Deciding `i32` is a builtin means
///     deciding it was not shadowed, not aliased, not a user type in scope
///     that happens to share the spelling. That is name lookup. Name lookup
///     is sema, it needs scopes and diagnostics, and it can FAIL   and there
///     is no such thing as a codegen error.
///
///     A name table in this file was the seed of every Stage 0 layer
///     violation. It is not coming back.
///
///   Import law: this file imports CodegenContext ONLY. An
///   `ffi "c++" import "clang/..."` appearing here is a layer-fusion bug.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;

class EmitTypes {
    priv var _cg: obs::<CodegenContext>;

    default fn EmitTypes(self);

    fn EmitTypes(self, cg: *CodegenContext) {
        self._cg = cg;
    }

    /// Emit \p t in type position.
    ///
    /// ChainType is the only kind codegen handles and, by design, close to
    /// the only kind that should ever reach it: pointers, arrays, nullable,
    /// and function types are Kairo spellings of C++ constructs, so Lower/
    /// reduces them to their codegen-shaped form. A kind landing in the
    /// default arm is a missing lowering, not a missing emitter case.
    fn emit(self, t: *Type) {
        std::ICE(t != &null, "EmitTypes: null type reached codegen");

        switch t->kind {
            case TypeKind::ChainType { self._chain(cast::<ChainType>(t)); }
            default {
                std::ICE(false,
                    "EmitTypes: non-chain type reached codegen; Lower/ must "
                    "reduce it to its codegen-shaped form");
            }
        }
    }

    /// `a::b::C`   emit each segment's identifier, prefixed by `::` when the
    /// segment carries that separator. A leading `::` (global scope) is
    /// segment 0 with sep == ColonColon and falls out of the same loop.
    ///
    /// The `::` borrows the FIRST byte of the segment's range, which covers
    /// the separator, so the caret lands on the separator itself.
    priv fn _chain(self, n: *ChainType) {
        std::ICE(!n->segments.is_empty(),
            "EmitTypes: chain type with no segments reached codegen");

        for var i: usize = 0; i < n->segments.size(); ++i {
            var seg = n->segments.get(i);

            std::ICE(seg->name != &null,
                "EmitTypes: chain segment with no identifier reached codegen");
            std::ICE(seg->generic_args.is_empty(),
                "EmitTypes: generic arguments in type position are M3");

            if seg->sep == ChainType::SegmentSeparator::ColonColon {
                self._cg->sink->synth_at_start(
                    seg->range, clang::tok::coloncolon);
            }

            // create() ICEs on a keyword token, which is the sema gate: a
            // primitive type name (`void`, `i32`) is a Kairo KEYWORD and has
            // no automatic C++ meaning. Lower/ rewrites those into identifier
            // chains   `i32` is an alias to `int32_t` in the runtime   and
            // codegen emits whatever names it is handed.
            self._cg->sink->create(seg->name->name);
        }
    }
}
