/// --- The Kairo Project ---------------- Sema/OperatorSignatureCheck.k --- ///
///
///   \brief Check against the table for Valid and applicable op overloads
///          to see if the code is correct or not.
///
///   \detail
///         fn op -> (Foo) // this is an illigal overload in the global scope
///
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaImports::*;

// & | ^ ~
static var AllowedOverloadOperatorSet = {

}


// Invalid = 0,
// Plus,
// Minus,
// Increment,
// Decrement,

// // Bitwise ops
// Amp,
// Pipe,
// Caret,
// Tilde,

// Exclaim,
// In,
// Range,
// Cast,
// Delete,
// Await,




/*

OVERLOADED_OPERATOR_MULTI(New            , "new"                      , true , true , false)
OVERLOADED_OPERATOR_MULTI(Delete         , "delete"                   , true , true , false)
OVERLOADED_OPERATOR_MULTI(Array_New      , "new[]"                    , true , true , false)
OVERLOADED_OPERATOR_MULTI(Array_Delete   , "delete[]"                 , true , true , false)
OVERLOADED_OPERATOR(Plus                 , "+"   , plus               , true , true , false)
OVERLOADED_OPERATOR(Minus                , "-"   , minus              , true , true , false)
OVERLOADED_OPERATOR(Star                 , "*"   , star               , true , true , false)
OVERLOADED_OPERATOR(Slash                , "/"   , slash              , false, true , false)
OVERLOADED_OPERATOR(Percent              , "%"   , percent            , false, true , false)
OVERLOADED_OPERATOR(Caret                , "^"   , caret              , false, true , false)
OVERLOADED_OPERATOR(Amp                  , "&"   , amp                , true , true , false)
OVERLOADED_OPERATOR(Pipe                 , "|"   , pipe               , false, true , false)
OVERLOADED_OPERATOR(Tilde                , "~"   , tilde              , true , false, false)
OVERLOADED_OPERATOR(Exclaim              , "!"   , exclaim            , true , false, false)
OVERLOADED_OPERATOR(Equal                , "="   , equal              , false, true , true)
OVERLOADED_OPERATOR(Less                 , "<"   , less               , false, true , false)
OVERLOADED_OPERATOR(Greater              , ">"   , greater            , false, true , false)
OVERLOADED_OPERATOR(PlusEqual            , "+="  , plusequal          , false, true , false)
OVERLOADED_OPERATOR(MinusEqual           , "-="  , minusequal         , false, true , false)
OVERLOADED_OPERATOR(StarEqual            , "*="  , starequal          , false, true , false)
OVERLOADED_OPERATOR(SlashEqual           , "/="  , slashequal         , false, true , false)
OVERLOADED_OPERATOR(PercentEqual         , "%="  , percentequal       , false, true , false)
OVERLOADED_OPERATOR(CaretEqual           , "^="  , caretequal         , false, true , false)
OVERLOADED_OPERATOR(AmpEqual             , "&="  , ampequal           , false, true , false)
OVERLOADED_OPERATOR(PipeEqual            , "|="  , pipeequal          , false, true , false)
OVERLOADED_OPERATOR(LessLess             , "<<"  , lessless           , false, true , false)
OVERLOADED_OPERATOR(GreaterGreater       , ">>"  , greatergreater     , false, true , false)
OVERLOADED_OPERATOR(LessLessEqual        , "<<=" , lesslessequal      , false, true , false)
OVERLOADED_OPERATOR(GreaterGreaterEqual  , ">>=" , greatergreaterequal, false, true , false)
OVERLOADED_OPERATOR(EqualEqual           , "=="  , equalequal         , false, true , false)
OVERLOADED_OPERATOR(ExclaimEqual         , "!="  , exclaimequal       , false, true , false)
OVERLOADED_OPERATOR(LessEqual            , "<="  , lessequal          , false, true , false)
OVERLOADED_OPERATOR(GreaterEqual         , ">="  , greaterequal       , false, true , false)
OVERLOADED_OPERATOR(Spaceship            , "<=>" , spaceship          , false, true , false)
OVERLOADED_OPERATOR(AmpAmp               , "&&"  , ampamp             , false, true , false)
OVERLOADED_OPERATOR(PipePipe             , "||"  , pipepipe           , false, true , false)
OVERLOADED_OPERATOR(PlusPlus             , "++"  , plusplus           , true , true , false)
OVERLOADED_OPERATOR(MinusMinus           , "--"  , minusminus         , true , true , false)
OVERLOADED_OPERATOR(Comma                , ","   , comma              , false, true , false)
OVERLOADED_OPERATOR(ArrowStar            , "->*" , arrowstar          , false, true , false)
OVERLOADED_OPERATOR(Arrow                , "->"  , arrow              , true , false, true)
OVERLOADED_OPERATOR_MULTI(Call           , "()"                       , true , true , true)
OVERLOADED_OPERATOR_MULTI(Subscript      , "[]"                       , false, true , true)
// ?: can *not* be overloaded, but we need the overload
// resolution machinery for it.
OVERLOADED_OPERATOR_MULTI(Conditional    , "?"                        , false, true , false)
OVERLOADED_OPERATOR(Coawait              , "co_await", kw_co_await    , true , false, false)
*/





// Operator	            Overload-able	        Const-overloadable	Notes
// + - * / %	                   ok	        no                  Returns a new value.
// Unary + -	                   ok	        no                  Returns a new value.
// ^^	                           ok	        no	                Returns a new value.
// << >>	                       ok	        no	                Returns a new value.
// & | ^ ~ (bitwise)	           ok	        no	                Returns a new value.
// == !=	                       ok	        no	                Returns bool.
// < <= > >=	                   ok	        no	                May be implemented via <=>.
// <=>	                           ok	        no	                Returns Ordering.
// ===	                           ok	        no	                Returns bool.
// l++ r++ l-- r--	               ok	        no	                Mutating operators.
// []	                           ok	        ok	                Returns a place into self (*T / *const T).
// ->	                           ok	        ok	                Returns a place into self (*T / *const T).
// .*	                           ok	        ok	                Returns a place into self (*T / *const T).
// ->*	                           ok	        ok	                Returns a place into self (*T / *const T).
// in (containment) 	           ok	        no	                Returns bool.
// in (iteration)	               ok	        no	                Returns yield T.
// as	                           ok	        no	                Returns a converted value.
// delete	                       ok	        no	                Custom destructor.
// await	                       ok	        no	                Returns the awaited value.
// =	                           no	        no	                Generated by the compiler; cannot be overloaded.
// += -= *= /= %= &= |= ^= <<= >>= no           no	                Desugar to the corresponding binary operator and assignment.
// . ::	                           no	        no	                Language syntax; not overloadable.
// Unary & *	                   no	        no	                Built-in pointer operations.
// && || !	                       no	        no	                Preserve built-in short-circuit semantics.
// ?. ?-> ?.* ?->*	               no	        no	                Derived automatically from the corresponding non-null-safe operator.
// .. ..=	                       no	        no	                Implemented through the Steppable interface.
// sizeof alignof typeof	       no	        no	                Compile-time language keywords.
//

///
/// This has to be split into 2 passes
/// this pass needs to run after type resolve - required...
///
class OperatorSignatureCheck derives RecursiveASTVisitor::<OperatorSignatureCheck> {
    ///
    /// The point of this is really simple in kairo you have a fixed set of
    /// things that can be overloaded, in specific signature formats - and
    /// some not globally hence the reason for this existing. if any is
    /// dissatisfied then we compile error
    ///
}