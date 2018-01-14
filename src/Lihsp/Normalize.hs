{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module Lihsp.Normalize where

import Control.Monad ((>=>))
import Control.Monad.Except (MonadError, throwError)

import Lihsp.AST
  ( ArgumentList(ArgumentList)
  , DataDeclaration(DataDeclaration)
  , Expression(EFunctionApplication, EIdentifier, ELetBlock, ELiteral)
  , FunctionApplication(FunctionApplication)
  , FunctionDefinition(FunctionDefinition)
  , Import(ImportItem, ImportType)
  , ImportList(ImportList)
  , LanguagePragma(LanguagePragma)
  , LetBlock(LetBlock)
  , Literal(LChar, LInt)
  , MacroDefinition(MacroDefinition)
  , QualifiedImport(QualifiedImport)
  , RestrictedImport(RestrictedImport)
  , Statement(SDataDeclaration, SFunctionDefinition, SLanguagePragma,
          SMacroDefinition, SModuleDeclaration, SQualifiedImport,
          SRestrictedImport, STypeSynonym, STypeclassInstance,
          SUnrestrictedImport)
  , TypeDefinition(ProperType, TypeConstructor)
  , TypeSynonym(TypeSynonym)
  , TypeclassInstance(TypeclassInstance)
  )

import Lihsp.Error (Error(NormalizeError))
import qualified Lihsp.Parse as Parse
  ( Expression(LiteralChar, LiteralInt, SExpression, Symbol)
  )

normalizeExpression :: (MonadError Error m) => Parse.Expression -> m Expression
normalizeExpression (Parse.LiteralChar char) = return $ ELiteral (LChar char)
normalizeExpression (Parse.LiteralInt int) = return $ ELiteral (LInt int)
normalizeExpression (Parse.SExpression items) =
  case items of
    [Parse.Symbol "let", Parse.SExpression bindings', body] ->
      let bindings =
            traverse
              (\case
                 Parse.SExpression [Parse.Symbol name, value'] ->
                   (name, ) <$> normalizeExpression value'
                 _ -> throwError $ NormalizeError "0001")
              bindings'
      in ELetBlock <$> (LetBlock <$> bindings <*> normalizeExpression body)
    [Parse.Symbol "quote", expression] ->
      return $ quoteParseExpression expression
    function:arguments ->
      EFunctionApplication <$>
      (FunctionApplication <$> normalizeExpression function <*>
       traverse normalizeExpression arguments)
    _ -> throwError $ NormalizeError "0002"
normalizeExpression (Parse.Symbol symbol) = return $ EIdentifier symbol

quoteParseExpression :: Parse.Expression -> Expression
quoteParseExpression (Parse.LiteralChar x) = ELiteral (LChar x)
quoteParseExpression (Parse.LiteralInt x) = ELiteral (LInt x)
quoteParseExpression (Parse.SExpression xs) =
  foldl
    (\acc x ->
       EFunctionApplication
         (FunctionApplication (EIdentifier ":") [quoteParseExpression x, acc]))
    (EIdentifier "[]")
    xs
quoteParseExpression (Parse.Symbol x) = EIdentifier x

normalizeDefinitions ::
     (MonadError Error m)
  => [Parse.Expression]
  -> m [(ArgumentList, Expression)]
normalizeDefinitions =
  traverse
    (\case
       Parse.SExpression [Parse.SExpression args', definition] ->
         (,) <$> (ArgumentList <$> traverse normalizeExpression args') <*>
         normalizeExpression definition
       _ -> throwError $ NormalizeError "0010")

normalizeStatement :: (MonadError Error m) => Parse.Expression -> m Statement
normalizeStatement (Parse.SExpression items) =
  case items of
    Parse.Symbol "=":Parse.Symbol functionName:typeSignature':definitions ->
      normalizeExpression typeSignature' >>= \case
        EFunctionApplication typeSignature ->
          SFunctionDefinition <$>
          (FunctionDefinition functionName typeSignature <$>
           normalizeDefinitions definitions)
        _ -> throwError $ NormalizeError "0011"
    [Parse.Symbol "data", typeDefinition', Parse.SExpression constructors'] ->
      let constructors =
            traverse
              (normalizeExpression >=> \case
                 EFunctionApplication functionApplication ->
                   return functionApplication
                 _ -> throwError $ NormalizeError "0003")
              constructors'
      in normalizeExpression typeDefinition' >>= \case
           EFunctionApplication typeConstructor ->
             SDataDeclaration <$>
             (DataDeclaration (TypeConstructor typeConstructor) <$> constructors)
           EIdentifier properType ->
             SDataDeclaration <$>
             (DataDeclaration (ProperType properType) <$> constructors)
           _ -> throwError $ NormalizeError "0004"
    Parse.Symbol "defmacro":Parse.Symbol macroName:definitions ->
      SMacroDefinition <$>
      (MacroDefinition macroName <$> normalizeDefinitions definitions)
    [Parse.Symbol "import", Parse.Symbol moduleName, Parse.SExpression imports] ->
      SRestrictedImport <$>
      (RestrictedImport moduleName <$> normalizeImportList imports)
    [Parse.Symbol "importq", Parse.Symbol moduleName, Parse.Symbol alias, Parse.SExpression imports] ->
      SQualifiedImport <$>
      (QualifiedImport moduleName alias <$> normalizeImportList imports)
    [Parse.Symbol "import-unrestricted", Parse.Symbol moduleName] ->
      return $ SUnrestrictedImport moduleName
    [Parse.Symbol "instance", instanceName', Parse.SExpression definitions'] ->
      let definitions =
            traverse
              (normalizeStatement >=> \case
                 SFunctionDefinition functionDefinition ->
                   return functionDefinition
                 _ -> throwError $ NormalizeError "0005")
              definitions'
      in STypeclassInstance <$>
         (TypeclassInstance <$> normalizeExpression instanceName' <*>
          definitions)
    [Parse.Symbol "language", Parse.Symbol languageName] ->
      return $ SLanguagePragma (LanguagePragma languageName)
    [Parse.Symbol "module", Parse.Symbol moduleName] ->
      return $ SModuleDeclaration moduleName
    [Parse.Symbol "type", alias', definition'] ->
      let alias = normalizeExpression alias'
          definition = normalizeExpression definition'
      in STypeSynonym <$> (TypeSynonym <$> alias <*> definition)
    _ -> throwError $ NormalizeError "0006"
  where
    normalizeImportList input =
      ImportList <$>
      traverse
        (\case
           Parse.Symbol import' -> return $ ImportItem import'
           Parse.SExpression (Parse.Symbol type':imports') ->
             let imports =
                   traverse
                     (\case
                        Parse.Symbol import' -> return import'
                        _ -> throwError $ NormalizeError "0009")
                     imports'
             in ImportType type' <$> imports
           _ -> throwError $ NormalizeError "0007")
        input
normalizeStatement _ = throwError $ NormalizeError "0008"

normalizeProgram :: (MonadError Error m) => [Parse.Expression] -> m [Statement]
normalizeProgram = traverse normalizeStatement