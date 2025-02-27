module Language.PureScript.Sugar.ObjectWildcards
  ( desugarObjectConstructors
  , desugarDecl
  ) where

import           Prelude.Compat

import           Control.Monad (forM)
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.Supply.Class
import           Data.Foldable (toList)
import           Data.List (foldl')
import           Data.Maybe (catMaybes)
import           Language.PureScript.AST
import           Language.PureScript.Environment (NameKind(..))
import           Language.PureScript.Errors
import           Language.PureScript.Names
import           Language.PureScript.PSString (PSString)


desugarObjectConstructors
  :: forall m
   . (MonadSupply m, MonadError MultipleErrors m)
  => Module
  -> m Module
desugarObjectConstructors (Module ss coms mn ds exts) = Module ss coms mn <$> mapM desugarDecl ds <*> pure exts

desugarDecl :: forall m. (MonadSupply m, MonadError MultipleErrors m) => Declaration -> m Declaration
desugarDecl d = rethrowWithPosition (declSourceSpan d) $ fn d
  where
  (fn, _, _) = everywhereOnValuesTopDownM return desugarExpr return

  desugarExpr :: Expr -> m Expr
  desugarExpr (Literal ss (ObjectLiteral ps)) = wrapLambdaAssoc (Literal ss . ObjectLiteral) ps
  desugarExpr (ObjectUpdateNested obj ps) = transformNestedUpdate obj ps
  desugarExpr (Accessor prop u)
    | Just props <- peelAnonAccessorChain u = do
      arg <- freshIdent'
      return $ Abs (VarBinder nullSourceSpan arg) $ foldr Accessor (argToExpr arg) (prop:props)
  desugarExpr (Case args cas) | any isAnonymousArgument args = do
    argIdents <- forM args freshIfAnon
    let args' = zipWith (`maybe` argToExpr) args argIdents
    return $ foldr (Abs . VarBinder nullSourceSpan) (Case args' cas) (catMaybes argIdents)
  desugarExpr (IfThenElse u t f) | any isAnonymousArgument [u, t, f] = do
    u' <- freshIfAnon u
    t' <- freshIfAnon t
    f' <- freshIfAnon f
    let if_ = IfThenElse (maybe u argToExpr u') (maybe t argToExpr t') (maybe f argToExpr f')
    return $ foldr (Abs . VarBinder nullSourceSpan) if_ (catMaybes [u', t', f'])
  desugarExpr e = return e

  transformNestedUpdate :: Expr -> PathTree Expr -> m Expr
  transformNestedUpdate obj ps = do
    -- If we don't have an anonymous argument then we need to generate a let wrapper
    -- so that the object expression isn't re-evaluated for each nested update.
    val <- freshIdent'
    let valExpr = argToExpr val
    if isAnonymousArgument obj
      then Abs (VarBinder nullSourceSpan val) <$> wrapLambda (buildUpdates valExpr) ps
      else wrapLambda (buildLet val . buildUpdates valExpr) ps
    where
      buildLet val = Let FromLet [ValueDecl (declSourceSpan d, []) val Public [] [MkUnguarded obj]]

      -- recursively build up the nested `ObjectUpdate` expressions
      buildUpdates :: Expr -> PathTree Expr -> Expr
      buildUpdates val (PathTree vs) = ObjectUpdate val (goLayer [] <$> runAssocList vs) where
        goLayer :: [PSString] -> (PSString, PathNode Expr) -> (PSString, Expr)
        goLayer _ (key, Leaf expr) = (key, expr)
        goLayer path (key, Branch (PathTree branch)) =
          let path' = path ++ [key]
              updates = goLayer path' <$> runAssocList branch
              accessor = foldl' (flip Accessor) val path'
              objectUpdate = ObjectUpdate accessor updates
          in (key, objectUpdate)

  wrapLambda :: forall t. Traversable t => (t Expr -> Expr) -> t Expr -> m Expr
  wrapLambda mkVal ps = do
    args <- traverse processExpr ps
    return $ foldr (Abs . VarBinder nullSourceSpan) (mkVal (snd <$> args)) (catMaybes $ toList (fst <$> args))
    where
      processExpr :: Expr -> m (Maybe Ident, Expr)
      processExpr e = do
        arg <- freshIfAnon e
        return (arg, maybe e argToExpr arg)

  wrapLambdaAssoc :: ([(PSString, Expr)] -> Expr) -> [(PSString, Expr)] -> m Expr
  wrapLambdaAssoc mkVal = wrapLambda (mkVal . runAssocList) . AssocList

  peelAnonAccessorChain :: Expr -> Maybe [PSString]
  peelAnonAccessorChain (Accessor p e) = (p :) <$> peelAnonAccessorChain e
  peelAnonAccessorChain (PositionedValue _ _ e) = peelAnonAccessorChain e
  peelAnonAccessorChain AnonymousArgument = Just []
  peelAnonAccessorChain _ = Nothing

  freshIfAnon :: Expr -> m (Maybe Ident)
  freshIfAnon u
    | isAnonymousArgument u = Just <$> freshIdent'
    | otherwise = return Nothing

  argToExpr :: Ident -> Expr
  argToExpr = Var nullSourceSpan . Qualified ByNullSourcePos
