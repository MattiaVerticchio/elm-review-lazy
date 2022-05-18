module NoEqualityBreakingLazyArgs exposing (rule)

{-|

@docs rule

-}

import Dict exposing (Dict)
import Elm.Syntax.Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression(..), LetDeclaration(..))
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern exposing (Pattern(..))
import Review.ModuleNameLookupTable as ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule exposing (ContextCreator, Error, Rule)
import Set exposing (Set)


{-| Reports... REPLACEME

    config =
        [ OnlyTopLevelFunctions.rule
        ]


## Fail

    a =
        "REPLACEME example to replace"


## Success

    a =
        "REPLACEME example to replace"


## When (not) to enable this rule

This rule is useful when REPLACEME.
This rule is not useful when REPLACEME.


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template noredink/elm-review-html-lazy/example --rules OnlyTopLevelFunctions
```

-}



-- Create a new rule


type Binding
    = FunctionBinding
    | ExpressionBinding (Maybe (Node Expression)) -- This is a Just if we can immediately resolve the binding.


type alias Context =
    { importedNames : ModuleNameLookupTable
    , topLevelNames : Set String
    , scopedNames : List (Dict String Binding)
    }


rule : Rule
rule =
    -- Define the rule with the same name as the module it is defined in
    Rule.newModuleRuleSchemaUsingContextCreator "OnlyTopLevelFunctions" initialContext
        -- Make it look at expressions
        |> Rule.withDeclarationListVisitor declarationListVisitor
        |> Rule.withExpressionEnterVisitor expressionEnterVisitor
        |> Rule.withExpressionExitVisitor expressionExitVisitor
        |> Rule.fromModuleRuleSchema



-- TODO: ModuleNameLookupTable does not properly handle "exposing (..)"


initialContext : ContextCreator () Context
initialContext =
    Rule.initContextCreator (\importedNames () -> { importedNames = importedNames, topLevelNames = Set.empty, scopedNames = [] })
        |> Rule.withModuleNameLookupTable



-- We use this visitor to construct a list of top level declarations


declarationListVisitor : List (Node Declaration) -> Context -> ( List (Error {}), Context )
declarationListVisitor declarations context =
    let
        topLevelFunctions =
            List.foldl
                (\(Node _ declaration) functions ->
                    case declaration of
                        FunctionDeclaration function ->
                            Node.value (Node.value function.declaration).name
                                :: functions

                        -- TODO: Grab all the names in the pattern, they are all top level as well
                        Destructuring _ _ ->
                            functions

                        _ ->
                            functions
                )
                []
                declarations
    in
    ( [], { context | topLevelNames = Set.fromList topLevelFunctions } )


functionNames : Set String
functionNames =
    Set.fromList [ "lazy", "lazy2", "lazy3", "lazy4", "lazy5", "lazy6", "lazy7", "lazy8" ]


isLazyFunction : Context -> Node Expression -> Bool
isLazyFunction { importedNames } node =
    case Node.value node of
        FunctionOrValue _ functionName ->
            Set.member functionName functionNames
                && (case ModuleNameLookupTable.moduleNameFor importedNames node of
                        Nothing ->
                            False

                        Just moduleName ->
                            moduleName == [ "Html", "Lazy" ] || moduleName == [ "Html", "Styled", "Lazy" ]
                   )

        _ ->
            False


expressionEnterVisitor : Node Expression -> Context -> ( List (Error {}), Context )
expressionEnterVisitor node context =
    case Node.value node of
        Expression.Application (functionNode :: firstArg :: args) ->
            if isLazyFunction context functionNode then
                ( validateLazyFunction context firstArg
                    :: List.map (validateLazyArg context) args
                    |> List.filterMap identity
                , context
                )

            else
                ( [], context )

        -- Let expressions can create new name bindings that we might need to follow to determine if they are problematic
        LetExpression { declarations } ->
            let
                newScopedNames =
                    List.concatMap
                        (\declartionNode ->
                            case Node.value declartionNode of
                                LetFunction { declaration } ->
                                    let
                                        { name, arguments, expression } =
                                            Node.value declaration
                                    in
                                    case arguments of
                                        [] ->
                                            [ ( Node.value name, Just expression |> ExpressionBinding ) ]

                                        _ ->
                                            [ ( Node.value name, FunctionBinding ) ]

                                LetDestructuring patternNode expresionNode ->
                                    destructurePatternBindings patternNode (Just expresionNode)
                        )
                        declarations
            in
            ( [], { context | scopedNames = Dict.fromList newScopedNames :: context.scopedNames } )

        _ ->
            ( [], context )


destructurePatternBindings : Node Pattern -> Maybe (Node Expression) -> List ( String, Binding )
destructurePatternBindings (Node _ pattern) maybeExpression =
    case pattern of
        TuplePattern nodes ->
            case maybeExpression of
                Nothing ->
                    List.concatMap (\node -> destructurePatternBindings node Nothing) nodes

                -- TODO: expand this case when we have tuple construction expressions
                Just _ ->
                    List.concatMap (\node -> destructurePatternBindings node Nothing) nodes

        RecordPattern nodes ->
            -- TODO: expand this case if we have a record construction expression
            List.map (\(Node _ name) -> ( name, ExpressionBinding Nothing ))
                nodes

        UnConsPattern headNode tailNode ->
            -- TODO: expand this case if we have a list construction expression
            destructurePatternBindings headNode Nothing ++ destructurePatternBindings tailNode Nothing

        ListPattern nodes ->
            -- TODO: expand this case if we have a list construction expression
            List.concatMap (\node -> destructurePatternBindings node Nothing) nodes

        VarPattern name ->
            [ ( name, ExpressionBinding maybeExpression ) ]

        NamedPattern _ nodes ->
            -- TODO: expand this case if we have a named construction expression
            List.concatMap (\node -> destructurePatternBindings node Nothing) nodes

        AsPattern innerPattern (Node _ name) ->
            -- TODO: If we see this expression being constructed on the right then this will always fail as an arg to lazy
            ( name, ExpressionBinding Nothing ) :: destructurePatternBindings innerPattern maybeExpression

        ParenthesizedPattern innerPatter ->
            destructurePatternBindings innerPatter maybeExpression

        _ ->
            []


expressionExitVisitor : Node Expression -> Context -> ( List (Error {}), Context )
expressionExitVisitor node context =
    case Node.value node of
        LetExpression _ ->
            ( [], { context | scopedNames = Maybe.withDefault [] (List.tail context.scopedNames) } )

        _ ->
            ( [], context )


lookupBinding : List (Dict String Binding) -> String -> Maybe Binding
lookupBinding bindingContexts name =
    case bindingContexts of
        [] ->
            Nothing

        dict :: rest ->
            case Dict.get name dict of
                Just expression ->
                    Just expression

                Nothing ->
                    lookupBinding rest name



-- The first argument passed to a call to lazy(2|3|4|5|6|7|8) is required to be a function of airity 1
-- This allows us to make more assumptions about the type.  Most notably we know that that expression will
-- be evaluated to a function and not a literal.


validateLazyFunction : Context -> Node Expression -> Maybe (Error {})
validateLazyFunction context node =
    case Node.value node of
        FunctionOrValue _ name ->
            case ModuleNameLookupTable.moduleNameFor context.importedNames node of
                -- Function is local in the module
                Just [] ->
                    -- Function is at the top level in this module
                    if Set.member name context.topLevelNames then
                        Nothing
                        -- Function name was bound in argument / let / case expresion

                    else
                        lookupBinding context.scopedNames name
                            |> Maybe.andThen
                                (\binding ->
                                    case binding of
                                        ExpressionBinding (Just expressionNode) ->
                                            validateLazyFunction context expressionNode

                                        _ ->
                                            Nothing
                                )

                -- Function is imported
                _ ->
                    Nothing

        _ ->
            Rule.error { message = "This must be a top level function in order to be properly optimized by lazy", details = [ "Do this" ] } (Node.range node)
                |> Just


validateLazyArg : Context -> Node Expression -> Maybe (Error {})
validateLazyArg _ (Node _ exp) =
    case exp of
        _ ->
            Nothing