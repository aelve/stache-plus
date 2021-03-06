-- |
-- Module      :  Text.Mustache.Plus.Parser
-- Copyright   :  © 2016 Stack Builders
-- License     :  BSD 3 clause
--
-- Megaparsec parser for Mustache templates. You don't usually need to
-- import the module, because "Text.Mustache.Plus" re-exports everything you may
-- need, import that module instead.

{-# LANGUAGE OverloadedStrings #-}

module Text.Mustache.Plus.Parser
  ( parseMustache )
where

import Data.Functor
import Control.Monad
import Control.Monad.State.Strict
import Data.Char (isSpace)
import Data.Maybe (catMaybes)
import Text.Megaparsec
import Text.Megaparsec.Char
import Data.Semigroup ((<>))
import Data.Aeson (Value(..))
import Data.Scientific (Scientific)
import Text.Mustache.Plus.Type
import Data.Text (Text)
import Data.Void
import qualified Data.Text             as T
import qualified Text.Megaparsec.Char.Lexer as L

----------------------------------------------------------------------------
-- Parser

-- | Parse given Mustache template.

parseMustache
  :: FilePath
     -- ^ Location of file to parse
  -> Text
     -- ^ File contents (Mustache template)
  -> Either (ParseError Char Void) [Node]
     -- ^ Parsed nodes or parse error
parseMustache = parse $
  evalStateT (pMustache eof) (Delimiters "{{" "}}")

pMustache :: Parser () -> Parser [Node]
pMustache = fmap catMaybes . manyTill (choice alts)
  where
    alts =
      [ Just    <$> pAssign
      , Nothing <$  withStandalone pComment
      , Just    <$> pSection "#" Section
      , Just    <$> pSection "^" InvertedSection
      , Just    <$> pStandalone (pPartial Just)
      , Just    <$> pPartial (const Nothing)
      , Nothing <$  withStandalone pSetDelimiters
      , Just    <$> pUnescapedExpr
      , Just    <$> pUnescapedSpecial
      , Just    <$> pEscapedExpr
      , Just    <$> pTextBlock
      , Just    <$> fmap TextBlock (string "|]") ]
{-# INLINE pMustache #-}

pTextBlock :: Parser Node
pTextBlock = do
  start <- gets openingDel
  void . notFollowedBy $ string start <|> string "|]"
  let terminator = choice
        [ void . lookAhead $ string start <|> string "|]"
        , pBol
        , eof ]
  TextBlock . T.pack <$> someTill anyChar terminator
{-# INLINE pTextBlock #-}

pUnescapedExpr :: Parser Node
pUnescapedExpr = UnescapedExpr <$> pTagExpr "&"
{-# INLINE pUnescapedExpr #-}

pUnescapedSpecial :: Parser Node
pUnescapedSpecial = do
  start <- gets openingDel
  end   <- gets closingDel
  between (symbol $ start <> "{") (string $ "}" <> end) $
    UnescapedExpr <$> pExpr True
{-# INLINE pUnescapedSpecial #-}

pAssign :: Parser Node
pAssign = do
  start <- gets openingDel
  end   <- gets closingDel
  vname <- try $ do
    void $ symbol start
    vname <- lexeme (label "variable" pVarName)
    void $ symbol "="
    return vname
  rightSide <- pExpr True
  void $ string end
  return (Assign vname rightSide)
{-# INLINE pAssign #-}

pSection :: Text -> (Key -> [Node] -> Node) -> Parser Node
pSection suffix f = do
  key   <- withStandalone (pTagKey suffix)
  nodes <- (pMustache . withStandalone . pClosingTag) key
  return (f key nodes)
{-# INLINE pSection #-}

pPartial :: (Pos -> Maybe Pos) -> Parser Node
pPartial f = do
  pos <- f <$> L.indentLevel
  start <- gets openingDel
  end   <- gets closingDel
  between (symbol $ start <> ">") (string end) $ do
    key <- pKey
    let pname = PName $ T.intercalate (T.pack ".") (unKey key)
    args <- many $ do
      argName <- lexeme (label "argument name" pVarName)
      void $ symbol "="
      argVal <- pExpr False
      return (argName, argVal)
    return (Partial pname args pos)
{-# INLINE pPartial #-}

-- TODO: move these out into a separate library
pJsonString :: Parser T.Text
pJsonString = label "JSON string" $
  T.pack <$> between (char '"') (char '"') (many pChar)
  where
    pChar = raw <|> (char '\\' *> quoted)
    raw = satisfy (\c -> c /= '"' && c /= '\\')
    quoted = choice [
      char '"'  $> '"',
      char '/'  $> '/',
      char '\\' $> '\\',
      char 'b'  $> '\b',
      char 't'  $> '\t',
      char 'f'  $> '\f',
      char 'n'  $> '\n',
      char 'r'  $> '\r',
      char 'u' *> (decodeUtf <$> count 4 hexDigitChar) ]
    decodeUtf x = toEnum (read ('0':'x':x) :: Int)
{-# INLINE pJsonString #-}

pJsonNumber :: Parser Scientific
pJsonNumber = label "number" $
  read . concat <$> sequence
    [ option "" $ T.unpack <$> string "-"
    , T.unpack <$> string "0" <|> some digitChar
    , option "" $ (:) <$> char '.' <*> some digitChar
    , option "" $ concat <$> sequence
        [ T.unpack <$> (string "e" <|> string "E")
        , option "" $ T.unpack <$> (string "+" <|> string "-")
        , some digitChar
        ]
    ]
{-# INLINE pJsonNumber #-}

pComment :: Parser ()
pComment = void $ do
  start <- gets openingDel
  end   <- gets closingDel
  (void . symbol) (start <> "!")
  manyTill anyChar (string end)
{-# INLINE pComment #-}

pSetDelimiters :: Parser ()
pSetDelimiters = void $ do
  start <- gets openingDel
  end   <- gets closingDel
  (void . symbol) (start <> "=")
  start' <- pDelimiter <* scn
  end'   <- pDelimiter <* scn
  (void . string) ("=" <> end)
  put (Delimiters start' end')
{-# INLINE pSetDelimiters #-}

pEscapedExpr :: Parser Node
pEscapedExpr = EscapedExpr <$> pTagExpr ""
{-# INLINE pEscapedExpr #-}

withStandalone :: Parser a -> Parser a
withStandalone p = pStandalone p <|> p
{-# INLINE withStandalone #-}

pStandalone :: Parser a -> Parser a
pStandalone p = pBol *> try (between sc (sc <* (void eol <|> eof)) p)
{-# INLINE pStandalone #-}

pTagExpr :: Text -> Parser Expr
pTagExpr suffix = do
  start <- gets openingDel
  end   <- gets closingDel
  between (symbol $ start <> suffix) (string end) (pExpr True)
{-# INLINE pTagExpr #-}

pTagKey :: Text -> Parser Key
pTagKey suffix = do
  start <- gets openingDel
  end   <- gets closingDel
  between (symbol $ start <> suffix) (string end) pKey
{-# INLINE pTagKey #-}

pClosingTag :: Key -> Parser ()
pClosingTag key = do
  start <- gets openingDel
  end   <- gets closingDel
  let str = keyToString key
  void $ between (symbol $ start <> "/") (string end) (symbol (T.pack str))
{-# INLINE pClosingTag #-}

pVarName :: Parser Text
pVarName = T.pack <$> some (alphaNumChar <|> char '-' <|> char '_')
{-# INLINE pVarName #-}

pKey :: Parser Key
pKey = (fmap Key . lexeme . label "key") (implicit <|> other)
  where
    implicit = [] <$ char '.'
    other    = sepBy1 pVarName (char '.')
{-# INLINE pKey #-}

pExpr
  :: Bool          -- ^ Whether function calls without parens are allowed
  -> Parser Expr
pExpr callsAllowed = if callsAllowed then single <|> call else single
  where
    call = Call <$> lexeme (char '%' *> label "function" pVarName)
                <*> many (pExpr False)
    single = choice $ [
      Literal      <$> pLiteral,
      Variable     <$> pKey,
      Interpolated <$> pInterpolated,
      between (symbol "(") (symbol ")") (pExpr True) ]

-- TODO: allow more things than just strings and numbers
pLiteral :: Parser Value
pLiteral = lexeme $ label "JSON value" $
  choice [
    String <$> pJsonString,
    Number <$> pJsonNumber ]
{-# INLINE pLiteral #-}

pInterpolated :: Parser [Node]
pInterpolated = do
  void $ string "[|"
  delims <- get :: Parser Delimiters
  nodes <- pMustache (void (symbol "|]"))
  put delims
  return nodes
{-# INLINE pInterpolated #-}

pDelimiter :: Parser Text
pDelimiter = T.pack <$> some (satisfy delChar) <?> "delimiter"
  where delChar x = not (isSpace x) && x /= '='
{-# INLINE pDelimiter #-}

pBol :: Parser ()
pBol = do
  level <- L.indentLevel
  unless (level == pos1) empty
{-# INLINE pBol #-}

----------------------------------------------------------------------------
-- Auxiliary types

-- | Type of Mustache parser monad stack.

type Parser = StateT Delimiters (Parsec Void Text)

-- | State used in Mustache parser. It includes currently set opening and
-- closing delimiters.

data Delimiters = Delimiters
  { openingDel :: Text
  , closingDel :: Text }

----------------------------------------------------------------------------
-- Lexer helpers and other

scn :: Parser ()
scn = L.space (void spaceChar) empty empty
{-# INLINE scn #-}

sc :: Parser ()
sc = L.space (void $ char ' ' <|> char '\t') empty empty
{-# INLINE sc #-}

lexeme :: Parser a -> Parser a
lexeme = L.lexeme scn
{-# INLINE lexeme #-}

symbol :: Text -> Parser Text
symbol = L.symbol scn
{-# INLINE symbol #-}
