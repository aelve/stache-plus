-- |
-- Module      :  Text.Mustache.Compile.TH
-- Copyright   :  © 2016 Stack Builders
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov@openmailbox.org>
-- Stability   :  experimental
-- Portability :  portable
--
-- Template Haskell helpers to compile Mustache templates at compile time.
-- This module is not imported as part of "Text.Mustache", so you need to
-- import it yourself. Qualified import is recommended, but not necessary.
--
-- At the moment, functions in this module only work with GHC 8 (they
-- require at least @template-haskell-2.11@).

{-# LANGUAGE CPP             #-}
{-# LANGUAGE TemplateHaskell #-}

module Text.Mustache.Compile.TH
  ( compileMustacheDir
  , compileMustacheFile
  , compileMustacheText )
where

import Control.Monad.Catch (try)
import Data.Text.Lazy (Text)
import Language.Haskell.TH hiding (Dec)
import Text.Megaparsec hiding (try)
import Text.Mustache.Type
import qualified Text.Mustache.Compile as C

#if MIN_VERSION_template_haskell(2,11,0)
import Language.Haskell.TH.Syntax (liftData)
#else
import Data.Data (Data)
liftData :: Data a => a -> Q Exp
liftData _ = fail "The feature requires at least GHC 8 to work"
#endif

-- | Compile all templates in specified directory and select one. Template
-- files should have extension @mustache@, (e.g. @foo.mustache@) to be
-- recognized.
--
-- This version compiles the templates at compile time.

compileMustacheDir :: FilePath -> PName -> Q Exp
compileMustacheDir path pname =
  (runIO . try) (C.compileMustacheDir path pname) >>= handleEither

-- | Compile single Mustache template and select it.
--
-- This version compiles the template at compile time.

compileMustacheFile :: FilePath -> Q Exp
compileMustacheFile path =
  (runIO . try) (C.compileMustacheFile path) >>= handleEither

-- | Compile Mustache template from 'Text' value. The cache will contain
-- only this template named according to given 'Key'.
--
-- This version compiles the template at compile time.

compileMustacheText :: PName -> Text -> Q Exp
compileMustacheText pname text =
  handleEither (C.compileMustacheText pname text)

-- | Given an 'Either' result return 'Right' and signal pretty-printed error
-- if we have a 'Left'.

handleEither :: Either (ParseError Char Dec) Template -> Q Exp
handleEither val =
  case val of
    Left err -> fail (parseErrorPretty err)
    Right template -> liftData template