/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

import ASTNode::Expressions::*;

class <T> ExprVisitor {
    fn visit(self, e: *Expr) {
        if e == &null { return; }

        switch e->kind {
            case ExprKind::IntegerLiteralExpr       { return self.visit_integer_literal_expr(        cast::<IntegerLiteralExpr>(e));         }
            case ExprKind::FloatingLiteralExpr      { return self.visit_floating_literal_expr(       cast::<FloatingLiteralExpr>(e));        }
            case ExprKind::StringLiteralExpr        { return self.visit_string_literal_expr(         cast::<StringLiteralExpr>(e));          }
            case ExprKind::CharacterLiteralExpr     { return self.visit_character_literal_expr(      cast::<CharacterLiteralExpr>(e));       }
            case ExprKind::BooleanLiteralExpr       { return self.visit_boolean_literal_expr(        cast::<BooleanLiteralExpr>(e));         }
            case ExprKind::NullLiteralExpr          { return self.visit_null_literal_expr(           cast::<NullLiteralExpr>(e));            }
            case ExprKind::ListLiteralExpr          { return self.visit_list_literal_expr(           cast::<ListLiteralExpr>(e));            }
            case ExprKind::TupleLiteralExpr         { return self.visit_tuple_literal_expr(          cast::<TupleLiteralExpr>(e));           }
            case ExprKind::SetLiteralExpr           { return self.visit_set_literal_expr(            cast::<SetLiteralExpr>(e));             }
            case ExprKind::MapLiteralExpr           { return self.visit_map_literal_expr(            cast::<MapLiteralExpr>(e));             }
            case ExprKind::ArrayInitializerExpr     { return self.visit_array_initializer_expr(      cast::<ArrayInitializerExpr>(e));       }
            case ExprKind::VectorInitializerExpr    { return self.visit_vector_initializer_expr(     cast::<VectorInitializerExpr>(e));      }
            case ExprKind::MapInitializerExpr       { return self.visit_map_initializer_expr(        cast::<MapInitializerExpr>(e));         }
            case ExprKind::SetInitializerExpr       { return self.visit_set_initializer_expr(        cast::<SetInitializerExpr>(e));         }
            case ExprKind::NamedInitializerExpr     { return self.visit_named_initializer_expr(      cast::<NamedInitializerExpr>(e));       }
            case ExprKind::AnonInitializerExpr      { return self.visit_anon_initializer_expr(       cast::<AnonInitializerExpr>(e));        }
            case ExprKind::ChainExpr                { return self.visit_chain_expr(                  cast::<ChainExpr>(e));                  }
            case ExprKind::MethodCallExpr           { return self.visit_method_call_expr(            cast::<MethodCallExpr>(e));             }
            case ExprKind::GroupingExpr             { return self.visit_grouping_expr(               cast::<GroupingExpr>(e));               }
            case ExprKind::NamedIdentExpr           { return self.visit_named_ident_expr(            cast::<NamedIdentExpr>(e));             }
            case ExprKind::UnaryOperatorExpr        { return self.visit_unary_operator_expr(         cast::<UnaryOperatorExpr>(e));          }
            case ExprKind::BinaryOperatorExpr       { return self.visit_binary_operator_expr(        cast::<BinaryOperatorExpr>(e));         }
            case ExprKind::AssignOperatorExpr       { return self.visit_assign_operator_expr(        cast::<AssignOperatorExpr>(e));         }
            case ExprKind::ImplConformanceExpr      { return self.visit_impl_conformance_expr(       cast::<ImplConformanceExpr>(e));        }
            case ExprKind::DerivesRelationExpr      { return self.visit_derives_relation_expr(       cast::<DerivesRelationExpr>(e));        }
            case ExprKind::TernaryExpr              { return self.visit_ternary_expr(                cast::<TernaryExpr>(e));                }
            case ExprKind::IfExpr                   { return self.visit_if_expr(                     cast::<IfExpr>(e));                     }
            case ExprKind::InlineTryCatchExpr       { return self.visit_inline_try_catch_expr(       cast::<InlineTryCatchExpr>(e));         }
            case ExprKind::RangeExpr                { return self.visit_range_expr(                  cast::<RangeExpr>(e));                  }
            case ExprKind::ClosureExpr              { return self.visit_closure_expr(                cast::<ClosureExpr>(e));                }
            case ExprKind::AwaitExpr                { return self.visit_await_expr(                  cast::<AwaitExpr>(e));                  }
            case ExprKind::SpawnExpr                { return self.visit_spawn_expr(                  cast::<SpawnExpr>(e));                  }
            case ExprKind::ThreadExpr               { return self.visit_thread_expr(                 cast::<ThreadExpr>(e));                 }
            case ExprKind::MacroInvocationExpr      { return self.visit_macro_invocation_expr(       cast::<MacroInvocationExpr>(e));        }
            case ExprKind::SizeOfExpr               { return self.visit_size_of_expr(                cast::<SizeOfExpr>(e));                 }
            case ExprKind::AlignOfExpr              { return self.visit_align_of_expr(               cast::<AlignOfExpr>(e));                }
            case ExprKind::TypeOfExpr               { return self.visit_type_of_expr(                cast::<TypeOfExpr>(e));                 }
            case ExprKind::EvalExpr                 { return self.visit_eval_expr(                   cast::<EvalExpr>(e));                   }
            case ExprKind::SelfExpr                 { return self.visit_self_expr(                   cast::<SelfExpr>(e));                   }
            case ExprKind::UnsafeExpr               { return self.visit_unsafe_expr(                 cast::<UnsafeExpr>(e));                 }
            case ExprKind::DeleteExpr               { return self.visit_delete_expr(                 cast::<DeleteExpr>(e));                 }
            case ExprKind::SubscriptExpr            { return self.visit_subscript_expr(              cast::<SubscriptExpr>(e));              }
            case ExprKind::PackExpansionExpr        { return self.visit_pack_expansion_expr(         cast::<PackExpansionExpr>(e));          }
            case ExprKind::TypeCastExpr             { return self.visit_type_cast_expr(              cast::<TypeCastExpr>(e));               }
            case ExprKind::ImplicitBoundaryCastExpr { return self.visit_implicit_boundary_cast_expr( cast::<ImplicitBoundaryCastExpr>(e));   }
        }
    }

    fn visit_integer_literal_expr(       self, e: *IntegerLiteralExpr       ) { 0; };
    fn visit_floating_literal_expr(      self, e: *FloatingLiteralExpr      ) { 0; };
    fn visit_string_literal_expr(        self, e: *StringLiteralExpr        ) { 0; };
    fn visit_character_literal_expr(     self, e: *CharacterLiteralExpr     ) { 0; };
    fn visit_boolean_literal_expr(       self, e: *BooleanLiteralExpr       ) { 0; };
    fn visit_null_literal_expr(          self, e: *NullLiteralExpr          ) { 0; };
    fn visit_list_literal_expr(          self, e: *ListLiteralExpr          ) { 0; };
    fn visit_tuple_literal_expr(         self, e: *TupleLiteralExpr         ) { 0; };
    fn visit_set_literal_expr(           self, e: *SetLiteralExpr           ) { 0; };
    fn visit_map_literal_expr(           self, e: *MapLiteralExpr           ) { 0; };
    fn visit_array_initializer_expr(     self, e: *ArrayInitializerExpr     ) { 0; };
    fn visit_vector_initializer_expr(    self, e: *VectorInitializerExpr    ) { 0; };
    fn visit_map_initializer_expr(       self, e: *MapInitializerExpr       ) { 0; };
    fn visit_set_initializer_expr(       self, e: *SetInitializerExpr       ) { 0; };
    fn visit_named_initializer_expr(     self, e: *NamedInitializerExpr     ) { 0; };
    fn visit_anon_initializer_expr(      self, e: *AnonInitializerExpr      ) { 0; };
    fn visit_chain_expr(                 self, e: *ChainExpr                ) { 0; };
    fn visit_method_call_expr(           self, e: *MethodCallExpr           ) { 0; };
    fn visit_grouping_expr(              self, e: *GroupingExpr             ) { 0; };
    fn visit_named_ident_expr(           self, e: *NamedIdentExpr           ) { 0; };
    fn visit_unary_operator_expr(        self, e: *UnaryOperatorExpr        ) { 0; };
    fn visit_binary_operator_expr(       self, e: *BinaryOperatorExpr       ) { 0; };
    fn visit_assign_operator_expr(       self, e: *AssignOperatorExpr       ) { 0; };
    fn visit_impl_conformance_expr(      self, e: *ImplConformanceExpr      ) { 0; };
    fn visit_derives_relation_expr(      self, e: *DerivesRelationExpr      ) { 0; };
    fn visit_ternary_expr(               self, e: *TernaryExpr              ) { 0; };
    fn visit_if_expr(                    self, e: *IfExpr                   ) { 0; };
    fn visit_inline_try_catch_expr(      self, e: *InlineTryCatchExpr       ) { 0; };
    fn visit_range_expr(                 self, e: *RangeExpr                ) { 0; };
    fn visit_closure_expr(               self, e: *ClosureExpr              ) { 0; };
    fn visit_await_expr(                 self, e: *AwaitExpr                ) { 0; };
    fn visit_spawn_expr(                 self, e: *SpawnExpr                ) { 0; };
    fn visit_thread_expr(                self, e: *ThreadExpr               ) { 0; };
    fn visit_macro_invocation_expr(      self, e: *MacroInvocationExpr      ) { 0; };
    fn visit_size_of_expr(               self, e: *SizeOfExpr               ) { 0; };
    fn visit_align_of_expr(              self, e: *AlignOfExpr              ) { 0; };
    fn visit_type_of_expr(               self, e: *TypeOfExpr               ) { 0; };
    fn visit_eval_expr(                  self, e: *EvalExpr                 ) { 0; };
    fn visit_self_expr(                  self, e: *SelfExpr                 ) { 0; };
    fn visit_unsafe_expr(                self, e: *UnsafeExpr               ) { 0; };
    fn visit_delete_expr(                self, e: *DeleteExpr               ) { 0; };
    fn visit_subscript_expr(             self, e: *SubscriptExpr            ) { 0; };
    fn visit_pack_expansion_expr(        self, e: *PackExpansionExpr        ) { 0; };
    fn visit_type_cast_expr(             self, e: *TypeCastExpr             ) { 0; };
    fn visit_implicit_boundary_cast_expr(self, e: *ImplicitBoundaryCastExpr ) { 0; };
}

// class MyVisitor derives ExprVisitor::<MyVisitor> {
//     override fn visit_integer_literal_expr(self, e: *IntegerLiteralExpr) {
//         // handle integer literal
//     }

//     override fn visit_binary_operator_expr(self, e: *BinaryOperatorExpr) {
//         // handle binary operator
//     }
    
//     // override other visit methods as needed
// }

// we also have a ASTVisitor that combines StmtVisitor, DeclVisitor, TypeVisitor and ExprVisitor for visiting any node in the ast