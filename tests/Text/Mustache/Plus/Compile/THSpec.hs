{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Text.Mustache.Plus.Compile.THSpec
  ( main
  , spec )
where

import Test.Hspec

import Data.Semigroup ((<>))
import Text.Mustache.Plus.Type
import qualified Data.Map as M
import qualified Text.Mustache.Plus.Compile.TH as TH

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "compileMustacheText" $
    it "compiles template from text at compile time" $
      $(TH.compileMustacheText "foo" "This is the ‘foo’.\n")
        `shouldBe` fooTemplate
  describe "compileMustacheFile" $
    it "compiles template from file at compile time" $
      $(TH.compileMustacheFile "templates/foo.mustache")
        `shouldBe` fooTemplate
  describe "compileMustacheDir" $
    it "compiles templates from directory at compile time" $
      $(TH.compileMustacheDir "foo" "templates/")
        `shouldBe` (fooTemplate <> barTemplate)

fooTemplate :: Template
fooTemplate = Template "foo" $
  M.singleton "foo" [TextBlock "This is the ‘foo’.\n"]

barTemplate :: Template
barTemplate = Template "bar" $
  M.singleton "bar" [TextBlock "And this is the ‘bar’.\n"]
