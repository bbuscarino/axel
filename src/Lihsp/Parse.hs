-- NOTE Because `Lihsp.Parse.AST` will be used as the header of auto-generated macro programs,
--      it can't have any project-specific dependencies. As such, the instance definition for
--      `BottomUp Expression` can't be defined in the same file as `Expression` itself
--      (due to the dependency on `BottomUp`). Fortunately, `Lihsp.Parse.AST` will (should)
--      never be imported by itself but only implicitly as part of this module.
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Lihsp.Parse
  ( module Lihsp.Parse
  , module Lihsp.Parse.AST
  ) where

import Control.Monad.Except (MonadError, throwError)

import Lihsp.Error (Error(ParseError))

-- Re-exporting these so that consumers of parsed ASTs do not need
-- to know about the internal file.
import Lihsp.Parse.AST
  ( Expression(LiteralChar, LiteralInt, SExpression, Symbol)
  )
import Lihsp.Utils.Display (isOperator, kebabToCamelCase)
import Lihsp.Utils.Recursion (Recursive(bottomUp, bottomUpTraverse))

import Text.Parsec (ParsecT, Stream, (<|>), eof, parse, try)
import Text.Parsec.Char (alphaNum, char, digit, letter, noneOf, oneOf, space)
import Text.Parsec.Combinator (many1, optional)
import Text.Parsec.Prim (many)

any' :: Stream s m Char => ParsecT s u m Char
any' = noneOf ""

whitespace :: Stream s m Char => ParsecT s u m String
whitespace = many space

literalChar :: Stream s m Char => ParsecT s u m Expression
literalChar = LiteralChar <$> (char '\\' *> any')

literalInt :: Stream s m Char => ParsecT s u m Expression
literalInt = LiteralInt . read <$> many1 digit

literalString :: Stream s m Char => ParsecT s u m Expression
literalString = do
  chars <- char '"' *> many (noneOf "\"") <* char '"'
  pure $ SExpression [Symbol "quote", SExpression (map LiteralChar chars)]

sExpression :: Stream s m Char => ParsecT s u m Expression
sExpression = SExpression <$> (char '(' *> many item <* char ')')
  where
    item = try (whitespace *> expression) <|> expression

symbol :: Stream s m Char => ParsecT s u m Expression
symbol =
  Symbol <$>
  ((:) <$> (letter <|> validSymbol) <*> many (alphaNum <|> validSymbol))
  where
    validSymbol = oneOf "!@#$%^&*-=~_+,./<>?\\|':"

expression :: Stream s m Char => ParsecT s u m Expression
expression =
  literalChar <|> literalInt <|> literalString <|> sExpression <|> symbol

program :: Stream s m Char => ParsecT s u m [Expression]
program =
  many (try (whitespace *> sExpression) <|> sExpression) <* optional whitespace <*
  eof

normalizeCase :: Expression -> Expression
normalizeCase (Symbol x) =
  if isOperator x
    then Symbol x
    else Symbol (kebabToCamelCase x)
normalizeCase x = x

-- TODO `Expression` should probably instead be an instance of `Traversable`, use recursion schemes, etc.
--      If so, should I provide `toFix` and `fromFix` functions for macros to take advantage of?
--      (Maybe all macros have the argument automatically `fromFix`-ed to make consumption simpler?)
instance Recursive Expression where
  bottomUp :: (Expression -> Expression) -> Expression -> Expression
  bottomUp f x =
    case x of
      LiteralChar _ -> f x
      LiteralInt _ -> f x
      SExpression xs -> f $ SExpression (map (bottomUp f) xs)
      Symbol _ -> f x
  bottomUpTraverse ::
       (Monad m) => (Expression -> m Expression) -> Expression -> m Expression
  bottomUpTraverse f x =
    case x of
      LiteralChar _ -> f x
      LiteralInt _ -> f x
      SExpression xs -> f =<< (SExpression <$> traverse (bottomUpTraverse f) xs)
      Symbol _ -> f x

parseProgram :: (MonadError Error m) => String -> m [Expression]
parseProgram =
  either (throwError . ParseError) (return . map (bottomUp normalizeCase)) .
  parse program ""