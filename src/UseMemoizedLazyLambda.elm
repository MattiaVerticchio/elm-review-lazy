module UseMemoizedLazyLambda exposing (rule)

{-| Require calling `lazy` exclusively at the top level of a point free function with a lambda expression as its first argument.

@docs rule

-}

import Elm.Syntax.Declaration exposing (Declaration(..))
import Elm.Syntax.Expression exposing (Expression(..))
import Elm.Syntax.Expression.Extra exposing (fold, normalizeApplication)
import Elm.Syntax.Node as Node exposing (Node(..))
import Helpers.IdentifyLazy as IdentifyLazy exposing (identifyLazyFunction)
import Review.ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule exposing (ContextCreator, Error, Rule)
import Set exposing (Set)


type alias ModuleContext =
    { importedNames : ModuleNameLookupTable
    , importedExposingAll : Set String
    }


{-| This is a **highly** opinionated rule that requires all calls of `lazy` to be at the top level of a point-free function with a lambda expression as the first argument.
This prevents errors in the view function argument to lazy.


### What does this look like?

    view : Model -> Html a
    view = lazy (\model -> ...)

    view2 : Model -> Time.Zone -> Html a
    view2 = lazy (\model timezone -> ...)


## Motivation

Proper use of `lazy` is **extremely** hard to get right and on top of that maintaining correctness in the presence of refactorings is even worse!

In order for `lazy` to be able to skip evaluating the view function (and thus avoiding a potentionally expensive computation)
the Elm runtime will check each argument to `lazy` against the value from the previous call using Javascript reference equality (think `===`). Note
that this includes the first function argument to lazy as well!

A very common source of errors is to not have a top-level function as the first arugment
to an unmemoized lazy call, but instead having a partially applied function or a function defined in a let or a function composition or a lambda expression.

For example all of the following functions are bad and will result in lazy calls _never_ being cached:

    badView1 : Model -> Int -> Html a
    badView1 model counter =
        lazy (viewFunc counter) model

    badView2 : Model -> Html a
    badView2 model =
        lazy (\m -> viewFunc model) model

    badView3 : Model -> Html a
    badView3 model =
        let viewFunc m = ...
        in
        lazy viewFunc model


## A Better Path

However, if we define our view to be point-free, then our application of the view function to lazy is effectively memoized, and the paritially applied and lambda styles above are permissable.

For example:

    goodView1 : Model -> Html a
    goodView1 =
        lazy (viewFunc x)

    goodView2 : Model -> Html a
    goodView2 =
        lazy (\model -> viewFunc model)

As this is an opinionated rule, we choose to enforce the lambda expression form for several reasons:

1.  It forces the remaining lazy arguments to have explicitly defined local names, which improves readability as the point-free requirement means they are not named in the function definition itself.
2.  The code for the entire view can remain in one function, if the author so wishes.
3.  It just plain looks like a standard function definition (e.g. `func = \x1 x2 -> x1 + x2`). Some functional languages (like Roc) even require functions to be defined in this form.


## Minutiae

This rule also adds a couple additional contraints that aren't stricly necessary, but we think are helpful for clarity:

1.  Functions calling lazy must have a type signature (which assists the other rules in this package).
2.  The lambda expression argument must be of full airity for the given `lazy` function. `lazy` requires a labmda expression accepting 1 argument, `lazy2` requires a lambda with 2 arguments and so on.


## Additional Notes

This rule applies to all calls of `lazy` ... `lazy8` from [Html.Lazy](https://package.elm-lang.org/packages/elm/html/latest/Html-Lazy)
and `lazy` ... `lazy7` from [Html.Styled.Lazy](https://package.elm-lang.org/packages/rtfeldman/elm-css/latest/Html.Styled.Lazy)

-}
rule : Rule
rule =
    Rule.newModuleRuleSchemaUsingContextCreator "UseMemoizedLambda" initialContext
        |> Rule.withImportVisitor IdentifyLazy.importVisitor
        |> Rule.withDeclarationEnterVisitor declarationEnterVisitor
        |> Rule.fromModuleRuleSchema


initialContext : ContextCreator () ModuleContext
initialContext =
    Rule.initContextCreator
        (\importedNames _ ->
            { importedNames = importedNames
            , importedExposingAll = Set.empty
            }
        )
        |> Rule.withModuleNameLookupTable


findLazyCalls : ModuleContext -> Node Expression -> List (Node Expression)
findLazyCalls moduleContext expression =
    fold
        (\exp accum ->
            case identifyLazyFunction moduleContext exp of
                Just _ ->
                    exp :: accum

                _ ->
                    []
        )
        []
        expression
        |> List.reverse


declarationEnterVisitor : Node Declaration -> ModuleContext -> ( List (Error {}), ModuleContext )
declarationEnterVisitor node moduleContext =
    case Node.value node of
        FunctionDeclaration { declaration } ->
            let
                decl =
                    Node.value declaration

                badLazyCalls =
                    case ( normalizeApplication decl.expression, decl.arguments ) of
                        ( [ lazyFunc, lambda ], [] ) ->
                            case ( identifyLazyFunction moduleContext lazyFunc, lambda ) of
                                ( Just _, Node _ (LambdaExpression _) ) ->
                                    findLazyCalls moduleContext lambda

                                _ ->
                                    findLazyCalls moduleContext decl.expression

                        _ ->
                            findLazyCalls moduleContext decl.expression

                errors =
                    badLazyCalls
                        |> List.map (Node.range >> Rule.error { message = "Calls to lazy should be memoized at the top level of a view function with a lambda function argument.", details = [ "See here" ] })
            in
            ( errors, moduleContext )

        _ ->
            ( [], moduleContext )
