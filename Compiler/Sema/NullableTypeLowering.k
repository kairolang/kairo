/// --- The Kairo Project ----------------- Compiler/Sema/NullableTypeLowering.k --- ///
///
///   \brief Lower T? -> std::Nullable<T> at type positions.
///
///   \detail
///     Type-level desugar. Distinct from the value-level nullable lowerings
///     below (??, ?, narrowed access).
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

/// this i mearly and exmaple. used as a refrence point from here on out on usage
/// of the RAV and tree transformer

class NullableTypeLowering derives TreeTransform::<NullableTypeLowering> {
    fn transform_nullable_type(self, n: *NullableType) -> *Type {
        var inner = self.dyn()->transform_type(n->inner);

        // Build: std::Nullable::<inner>
        //
        // ChainType has segments: [std, Nullable<inner>]
        //   segment 0: name = "std",      generic_args = []
        //   segment 1: name = "Nullable", generic_args = [inner]

        var seg_buf = self.ctx->alloc_array::<ChainType::ChainSegment>(2);

        // segment 0: "std"
        seg_buf[0].name = NamedIdentExpr::create(
            self.ctx, n->range, /* token for "std" */
        );
        seg_buf[0].generic_args = FrozenList::<ChainType::GenericArg>::empty();

        // segment 1: "Nullable" with generic arg
        seg_buf[1].name = NamedIdentExpr::create(
            self.ctx, n->range, /* token for "Nullable" */
        );

        var arg = self.ctx->alloc::<ChainType::GenericArg>();
        arg->ty = inner;
        // arg->name = &null;  // positional, not named

        var arg_frozen = FrozenList::<ChainType::GenericArg>{};
        arg_frozen.from_raw(arg, 1);

        seg_buf[1].generic_args = arg_frozen;

        // Build the ChainType
        var chain = ChainType::create(self.ctx, n->range);
        chain->segments.from_raw(seg_buf, 2);
        chain->is_rooted = true;  // ::std::Nullable, global root

        return chain;
    }
}