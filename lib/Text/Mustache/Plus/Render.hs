-- |
-- Module      :  Text.Mustache.Plus.Render
-- Copyright   :  © 2016 Stack Builders
-- License     :  BSD 3 clause
--
-- Functions for rendering Mustache templates. You don't usually need to
-- import the module, because "Text.Mustache.Plus" re-exports everything you may
-- need, import that module instead.

{-# LANGUAGE OverloadedStrings #-}

module Text.Mustache.Plus.Render
  ( renderMustache
  , renderMustacheM )
where

import Data.Functor.Identity
import Control.Monad.RWS.Lazy
import Data.Aeson
import Control.Applicative
import Data.List.NonEmpty (NonEmpty (..))
import Data.DList (DList)
import qualified Data.DList as DL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Text.Megaparsec.Pos (Pos, unPos)
import Text.Mustache.Plus.Type
import qualified Data.ByteString.Lazy   as B
import qualified Data.HashMap.Strict    as H
import qualified Data.List.NonEmpty     as NE
import qualified Data.Map               as M
import qualified Data.Semigroup         as S
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as T
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy         as TL
import qualified Data.Vector            as V

----------------------------------------------------------------------------
-- The rendering monad

-- | Synonym for the monad we use for rendering.
--
-- * Reader: rendering context
-- * Writer: rendered result + warnings
-- * State: variables

type Render m a = RWST (RenderContext m) RenderOutput Object m a

-- | The render monad context.

data RenderContext m = RenderContext
  { -- | Actual indentation level
    rcIndent    :: Maybe Pos
    -- | The context stack
  , rcContext   :: NonEmpty Value
    -- | The template to render
  , rcTemplate  :: Template
    -- | Functions that can be called
  , rcFunctions :: M.Map Text (FunctionM m)
    -- | Is this last node in this partial?
  , rcLastNode  :: Bool
  }

data RenderOutput = RenderOutput {
  roBuilder  :: B.Builder,
  roWarnings :: DList String }

instance Semigroup RenderOutput where
  (<>) a b = RenderOutput {
    roBuilder  = roBuilder a <> roBuilder b,
    roWarnings = roWarnings a <> roWarnings b }

instance Monoid RenderOutput where
  mempty = RenderOutput mempty mempty

warn :: Monad m => String -> Render m ()
warn w = tell (RenderOutput mempty (DL.singleton w))
{-# INLINE warn #-}

----------------------------------------------------------------------------
-- High-level interface

-- | Render a Mustache 'Template' using Aeson's 'Value' to get actual values
-- for interpolation.

renderMustache
  :: M.Map Text Function -> Template -> Value -> (Text, [String])
renderMustache fs t v =
  runIdentity $ renderMustacheM (fmap (fmap Identity) fs) t v

renderMustacheM
  :: Monad m
  => M.Map Text (FunctionM m) -> Template -> Value -> m (Text, [String])
renderMustacheM fs t v =
  runRender (renderPartial (templateActual t) Nothing renderNode) fs t v

-- | Render a single 'Node'.

renderNode :: Monad m => Node -> Render m ()
renderNode (TextBlock txt) = outputIndented txt
renderNode (EscapedExpr e) =
  evaluateExpr e >>= outputRaw . escapeHtml . renderValue
renderNode (UnescapedExpr e) =
  evaluateExpr e >>= outputRaw . renderValue
renderNode (Assign k e) = do
  val <- evaluateExpr e
  modify (H.insert k val)
renderNode (Section k ns) = do
  val <- lookupKeyNone k
  unless (isBlank val) $
    case val of
      Array xs ->
        forM_ (V.toList xs) $ \x ->
          addToLocalContext x (renderMany renderNode ns)
      _ ->
        addToLocalContext val (renderMany renderNode ns)
renderNode (InvertedSection k ns) = do
  val <- lookupKeyNone k
  when (isBlank val) $
    renderMany renderNode ns
renderNode (Partial pname args indent) = do
  argVals <- forM args $ \(argName, arg) ->
    (,) argName `liftM` evaluateExpr arg
  vars <- get; put mempty
  -- Note that 'addToLocalContext' works in such a way that the resulting
  -- context will be 'resolvedArgs : vars : context'. Here's a relevant
  -- demonstration using 'local' (which 'addToLocalContext' uses):
  --
  -- >>> runReader (local (1:) $ local (2:) $ ask) []
  -- [2,1]
  addToLocalContext (Object vars) $
    addToLocalContext (Object (H.fromList argVals)) $
      renderPartial pname indent renderNode
  put vars

----------------------------------------------------------------------------
-- The rendering monad vocabulary

-- | Run 'Render' monad given template to render and a 'Value' to take
-- values from.

runRender
  :: Monad m
  => Render m a
  -> M.Map Text (FunctionM m)
  -> Template
  -> Value
  -> m (Text, [String])
runRender m f t v = (output . snd) `liftM` evalRWST m rc mempty
  where
    output (RenderOutput a b) = (TL.toStrict (B.toLazyText a), DL.toList b)
    rc = RenderContext
      { rcIndent    = Nothing
      , rcContext   = v :| []
      , rcTemplate  = t
      , rcFunctions = f
      , rcLastNode  = True }
{-# INLINE runRender #-}

-- | Output a piece of strict 'Text'.

outputRaw :: Monad m => Text -> Render m ()
outputRaw t = tell (RenderOutput (B.fromText t) mempty)
{-# INLINE outputRaw #-}

-- | Output indentation consisting of appropriate number of spaces.

outputIndent :: Monad m => Render m ()
outputIndent = asks rcIndent >>= outputRaw . buildIndent
{-# INLINE outputIndent #-}

-- | Output piece of strict 'Text' with added indentation.

outputIndented :: Monad m => Text -> Render m ()
outputIndented txt = do
  level <- asks rcIndent
  lnode <- asks rcLastNode
  let f x = outputRaw (T.replace "\n" ("\n" <> buildIndent level) x)
  if lnode && T.isSuffixOf "\n" txt
    then f (T.init txt) >> outputRaw "\n"
    else f txt
{-# INLINE outputIndented #-}

-- | Render a partial.

renderPartial
  :: Monad m
  => PName                 -- ^ Name of partial to render
  -> Maybe Pos             -- ^ Indentation level to use
  -> (Node -> Render m ()) -- ^ How to render nodes in that partial
  -> Render m ()
renderPartial pname i f = local u $ do
  outputIndent
  mbNodes <- getNodes
  case mbNodes of
    Just nodes ->
      renderMany f nodes
    Nothing ->
      warn $ "missing partial: " ++ T.unpack (unPName pname)
  where
    u rc = rc
      { rcIndent   = addIndents i (rcIndent rc)
      , rcTemplate = (rcTemplate rc) { templateActual = pname }
      , rcLastNode = True }
{-# INLINE renderPartial #-}

-- | Get collection of 'Node's for actual template.

getNodes :: Monad m => Render m (Maybe [Node])
getNodes = do
  Template actual cache <- asks rcTemplate
  return (M.lookup actual cache)
{-# INLINE getNodes #-}

-- | Render many nodes.

renderMany
  :: Monad m
  => (Node -> Render m ()) -- ^ How to render a node
  -> [Node]                -- ^ The collection of nodes to render
  -> Render m ()
renderMany _ [] = return ()
renderMany f [n] = do
  ln <- asks rcLastNode
  local (\rc -> rc { rcLastNode = ln && rcLastNode rc }) (f n)
renderMany f (n:ns) = do
  local (\rc -> rc { rcLastNode = False }) (f n)
  renderMany f ns

evaluateExpr :: Monad m => Expr -> Render m Value
evaluateExpr (Variable key) =
  lookupKeyWarn key
evaluateExpr (Literal val) =
  return val
evaluateExpr (Call fname args) = do
  mbFunc <- M.lookup fname `liftM` asks rcFunctions
  case mbFunc of
    Nothing -> do
      warn $ "unknown function: " ++ T.unpack fname
      return Null
    Just func -> do
      argVals <- mapM evaluateExpr args
      lift (func argVals)
evaluateExpr (Interpolated nodes) = do
  -- Get the output and don't add it to the rendered document
  vars <- get
  ((), res) <- censor (const mempty) (listen (renderMany renderNode nodes))
  put vars
  -- Output the warnings
  tell (res {roBuilder = mempty})
  -- Return the output
  return (String (TL.toStrict (B.toLazyText (roBuilder res))))

lookupKeyNone :: Monad m => Key -> Render m Value
lookupKeyNone k = fromMaybe Null `liftM` lookupKey k

lookupKeyWarn :: Monad m => Key -> Render m Value
lookupKeyWarn k = do
  mbV <- lookupKey k
  case mbV of
    Just v  -> return v
    Nothing -> do
      warn $ "missing key: " ++ keyToString k
      return Null

-- | Lookup a 'Value' by its 'Key'.

lookupKey :: Monad m => Key -> Render m (Maybe Value)
lookupKey (Key []) = (Just . NE.head) `liftM` asks rcContext
lookupKey k = do
  stack <- asks rcContext
  vars <- get
  return $ case k of
    Key [x] -> H.lookup x vars <|> lookupInStack k stack
    Key _   -> lookupInStack k stack

-- This is needed to implement https://github.com/mustache/spec/pull/48
data LookupResult
  = Found Value
  | MadeProgress
  | MadeNoProgress

lookupInStack :: Key -> NonEmpty Value -> Maybe Value
lookupInStack k vs =
  case simpleLookup k (NE.head vs) of
    Found x        -> Just x
    MadeProgress   -> Nothing
    MadeNoProgress -> lookupInStack k =<< NE.nonEmpty (NE.tail vs)

-- | Lookup a 'Value' by traversing another 'Value' using given 'Key' as
-- “path”.
simpleLookup :: Key -> Value -> LookupResult
simpleLookup (Key []) v = Found v
simpleLookup (Key (k:ks)) (Object m) =
  case H.lookup k m of
    Nothing -> MadeNoProgress
    Just v  -> case simpleLookup (Key ks) v of
      MadeNoProgress -> MadeProgress
      other          -> other
simpleLookup _ _ = MadeNoProgress
{-# INLINE simpleLookup #-}

-- | Add new value on the top of context. The new value has the highest
-- priority when lookup takes place.

addToLocalContext :: Monad m => Value -> Render m a -> Render m a
addToLocalContext (Object v) | H.null v = id
addToLocalContext v =
  local (\rc -> rc { rcContext = NE.cons v (rcContext rc) })
{-# INLINE addToLocalContext #-}

----------------------------------------------------------------------------
-- Helpers

-- | Add two 'Maybe' 'Pos' values together.

addIndents :: Maybe Pos -> Maybe Pos -> Maybe Pos
addIndents Nothing  Nothing  = Nothing
addIndents Nothing  (Just x) = Just x
addIndents (Just x) Nothing  = Just x
addIndents (Just x) (Just y) = Just (x S.<> y)
{-# INLINE addIndents #-}

-- | Build intentation of specified length by repeating the space character.

buildIndent :: Maybe Pos -> Text
buildIndent Nothing = ""
buildIndent (Just p) = let n = fromIntegral (unPos p) - 1 in T.replicate n " "
{-# INLINE buildIndent #-}

-- | Select invisible values.

isBlank :: Value -> Bool
isBlank Null         = True
isBlank (Bool False) = True
isBlank (Object   m) = H.null m
isBlank (Array    a) = V.null a
isBlank (String   s) = T.null s
isBlank _            = False
{-# INLINE isBlank #-}

-- | Render Aeson's 'Value' /without/ HTML escaping.

renderValue :: Value -> Text
renderValue Null         = ""
renderValue (String str) = str
renderValue value        = (T.decodeUtf8 . B.toStrict . encode) value
{-# INLINE renderValue #-}

-- | Escape HTML represented as strict 'Text'.

escapeHtml :: Text -> Text
escapeHtml txt = foldr (uncurry T.replace) txt
  [ ("\"", "&quot;")
  , ("'",  "&#39;")
  , ("<",  "&lt;")
  , (">",  "&gt;")
  , ("&",  "&amp;") ]
{-# INLINE escapeHtml #-}
