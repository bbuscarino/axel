{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

module Axel.Macros where

import Axel.AST
  ( MacroDefinition
  , Statement(SMacroDefinition, STopLevel)
  , ToHaskell(toHaskell)
  , definitions
  , name
  , statements
  )
import Axel.Error (Error(MacroError))
import Axel.Eval (evalSource)
import Axel.Normalize
  ( denormalizeExpression
  , normalizeStatement
  )
import qualified Axel.Parse as Parse
  ( Expression(LiteralChar, LiteralInt, LiteralString, SExpression,
           Symbol)
  , parseMultiple
  )
import Axel.Utils.Display (isOperator)
import Axel.Utils.Recursion (Recursive(bottomUpTraverse), exhaustM)
import Axel.Utils.Resources (readDataFile)
import Axel.Utils.String (replace)

import Control.Lens.Operators ((%~), (.~), (^.))
import Control.Monad (foldM)
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.List (foldl')
import Data.Semigroup ((<>))

getAstDefinition :: IO String
getAstDefinition = readDataFile "autogenerated/macros/Header.hs"

generateMacroProgram ::
     (MonadIO m) => MacroDefinition -> [Parse.Expression] -> m String
generateMacroProgram macroDefinition applicationArguments =
  (<>) <$> liftIO getFileHeader <*> liftIO getFileFooter
  where
    getFileHeader = getAstDefinition
    getFileFooter =
      let insertApplicationArguments =
            let applicationArgumentsPlaceholder = "%%%ARGUMENTS%%%"
            in replace
                 applicationArgumentsPlaceholder
                 (show applicationArguments)
          insertDefinitionBody =
            let definitionBodyPlaceholder = "%%%MACRO_DEFINITION%%%"
            in replace
                 definitionBodyPlaceholder
                 (toHaskell $ (name .~ newMacroName) macroDefinition)
          insertDefinitionName =
            let definitionNamePlaceholder = "%%%MACRO_NAME%%%"
            in replace definitionNamePlaceholder newMacroName
      in insertApplicationArguments .
         insertDefinitionName . insertDefinitionBody <$>
         readDataFile "macros/Footer.hs"
    newMacroName =
      (macroDefinition ^. name) ++
      if isOperator (macroDefinition ^. name)
        then "%%%%%%%%%%"
        else "_AXEL_AUTOGENERATED_MACRO_DEFINITION"

extractIndependentMacroDefinitions :: [Parse.Expression] -> [Parse.Expression]
extractIndependentMacroDefinitions stmts =
  let candidateMacroDefinitions = filter isMacroDefinition stmts
  in filter
       (not . isDependentOnAny candidateMacroDefinitions)
       stmts
  where
    isMacroDefinition (Parse.SExpression (Parse.Symbol "defmacro":_)) = True
    isMacroDefinition _ = False
    macroNameFromDefinition (Parse.SExpression (Parse.Symbol "defmacro":Parse.Symbol macroName:_)) =
      macroName
    macroNameFromDefinition _ =
      error
        "macroNameFromDefinition should only be called with a valid macro definition!"
    isDependentOn macroDefinition (Parse.SExpression (Parse.Symbol symbol:exprs)) =
      macroNameFromDefinition macroDefinition == symbol ||
      any (isDependentOn macroDefinition) exprs
    isDependentOn macroDefinition (Parse.SExpression exprs) = any (isDependentOn macroDefinition) exprs
    isDependentOn _ _ = False
    isDependentOnAny macroDefinitions expr =
      any (`isDependentOn` expr) macroDefinitions

expansionPass ::
     (MonadError Error m, MonadIO m) => Parse.Expression -> m Parse.Expression
expansionPass programExpr = do
  let independentMacroDefinitions =
        extractIndependentMacroDefinitions $ programToStatements programExpr
  normalizedDefs <- traverse normalizeDefinition independentMacroDefinitions
  expandMacros normalizedDefs programExpr
  where
    normalizeDefinition expr =
      let unwrap stmt =
            case stmt of
              SMacroDefinition macroDefinition -> macroDefinition
              _ -> error "TODO: Handle parsing errors"
      in unwrap <$> normalizeStatement expr
    programToStatements :: Parse.Expression -> [Parse.Expression]
    programToStatements (Parse.SExpression (Parse.Symbol "begin":stmts)) = stmts
    programToStatements _ =
      error "programToStatements must be passed a top-level program!"

exhaustivelyExpandMacros ::
     (MonadError Error m, MonadIO m) => Parse.Expression -> m Parse.Expression
exhaustivelyExpandMacros = exhaustM expansionPass

expandMacros ::
     (MonadError Error m, MonadIO m)
  => [MacroDefinition]
  -> Parse.Expression
  -> m Parse.Expression
expandMacros environment =
  bottomUpTraverse $ \expression ->
    case expression of
      Parse.LiteralChar _ -> pure expression
      Parse.LiteralInt _ -> pure expression
      Parse.LiteralString _ -> pure expression
      Parse.SExpression xs ->
        Parse.SExpression <$>
        foldM
          (\acc x ->
             case x of
               Parse.LiteralChar _ -> pure $ acc ++ [x]
               Parse.LiteralInt _ -> pure $ acc ++ [x]
               Parse.LiteralString _ -> pure $ acc ++ [x]
               Parse.SExpression [] -> pure $ acc ++ [x]
               Parse.SExpression (function:args) ->
                 lookupMacroDefinition environment function >>= \case
                   Just macroDefinition ->
                     (acc ++) <$> expandMacroApplication macroDefinition args
                   Nothing -> pure $ acc ++ [x]
               Parse.Symbol _ -> pure $ acc ++ [x])
          []
          xs
      Parse.Symbol _ -> pure expression
  where
    expandMacroApplication macroDefinition args =
      generateMacroProgram macroDefinition args >>= evalSource >>=
      Parse.parseMultiple

lookupMacroDefinition ::
     (MonadError Error m)
  => [MacroDefinition]
  -> Parse.Expression
  -> m (Maybe MacroDefinition)
lookupMacroDefinition environment identifierExpression =
  case identifierExpression of
    Parse.LiteralChar _ -> pure Nothing
    Parse.LiteralInt _ -> pure Nothing
    Parse.LiteralString _ -> pure Nothing
    Parse.SExpression _ -> pure Nothing
    Parse.Symbol identifier ->
      case filter
             (\macroDefinition -> macroDefinition ^. name == identifier)
             environment of
        [] -> pure Nothing
        [macroDefinition] -> pure $ Just macroDefinition
        _ -> throwError (MacroError "0012")

-- TODO This probably needs heavy optimization. If so, I will need to decrease the running time.
extractMacroDefinitions :: Statement -> [MacroDefinition]
extractMacroDefinitions (STopLevel topLevel) =
  foldl'
    (\env statement ->
       case statement of
         SMacroDefinition macroDefinition ->
           let newEnv = macroDefinition : env
               isDependentOnNewEnv x =
                 any (`isDefinitionDependentOnMacro` x) newEnv
           in filter (not . isDependentOnNewEnv) newEnv
         _ -> env)
    []
    (topLevel ^. statements)
extractMacroDefinitions _ = []

isDefinitionDependentOnMacro :: MacroDefinition -> MacroDefinition -> Bool
isDefinitionDependentOnMacro needle haystack =
  let definitionBodies = map snd (haystack ^. definitions)
  in any
       (isExpressionDependentOnMacro needle)
       (map denormalizeExpression definitionBodies)

isExpressionDependentOnMacro :: MacroDefinition -> Parse.Expression -> Bool
isExpressionDependentOnMacro _ (Parse.LiteralChar _) = False
isExpressionDependentOnMacro _ (Parse.LiteralInt _) = False
isExpressionDependentOnMacro _ (Parse.LiteralString _) = False
isExpressionDependentOnMacro needle (Parse.SExpression xs) =
  any (isExpressionDependentOnMacro needle) xs
isExpressionDependentOnMacro needle (Parse.Symbol x) = x == needle ^. name

stripMacroDefinitions :: Statement -> Statement
stripMacroDefinitions x =
  case x of
    STopLevel topLevel ->
      STopLevel $ (statements %~ filter (not . isMacroDefinition)) topLevel
    _ -> x
  where
    isMacroDefinition (SMacroDefinition _) = True
    isMacroDefinition _ = False
