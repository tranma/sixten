{-# LANGUAGE GeneralizedNewtypeDeriving, MonadComprehensions, OverloadedStrings #-}
module Backend.Lift where

import Control.Monad.State
import Data.Bifunctor
import Data.Monoid
import Data.Void

import Syntax
import qualified Syntax.Sized.Closed as Closed
import qualified Syntax.Sized.Definition as Sized
import qualified Syntax.Sized.Lifted as Lifted
import Util

data LiftState = LiftState
  { freshNames :: [QName]
  , liftedFunctions :: [(QName, Sized.Function Lifted.Expr Void)]
  }

newtype Lift a = Lift { runLift :: State LiftState a }
  deriving (Functor, Applicative, Monad, MonadState LiftState)

liftFunction :: Sized.Function Lifted.Expr Void -> Lift QName
liftFunction f = do
  name:names <- gets freshNames
  modify $ \s -> s
    { freshNames = names
    , liftedFunctions = (name, f) : liftedFunctions s
    }
  return name

liftExpr
  :: Closed.Expr v
  -> Lift (Lifted.Expr v)
liftExpr expr = case expr of
  Closed.Var v -> return $ Lifted.Var v
  Closed.Global g -> return $ Lifted.Global g
  Closed.Lit l -> return $ Lifted.Lit l
  Closed.Con c es -> Lifted.Con c <$> mapM liftExpr es
  Closed.Lams tele s -> do
    s' <- transverseScope liftExpr s
    tele' <- transverseTelescope liftExpr tele
    f <- liftFunction $ Sized.Function tele' s'
    return $ Lifted.Global f
  Closed.Call e es -> Lifted.Call <$> liftExpr e <*> mapM liftExpr es
  Closed.PrimCall retDir e es -> Lifted.PrimCall retDir
    <$> liftExpr e
    <*> traverse (traverse liftExpr) es
  Closed.Let h e s -> Lifted.Let h
    <$> liftExpr e
    <*> transverseScope liftExpr s
  Closed.Case e brs -> Lifted.Case <$> liftExpr e <*> liftBranches brs
  Closed.ExternCode c -> Lifted.ExternCode <$> mapM liftExpr c
  Closed.Anno e t -> Lifted.Anno <$> liftExpr e <*> liftExpr t

liftBranches
  :: Branches QConstr () Closed.Expr v
  -> Lift (Branches QConstr () Lifted.Expr v)
liftBranches (ConBranches cbrs) = ConBranches <$> sequence
  [ ConBranch qc <$> transverseTelescope liftExpr tele <*> transverseScope liftExpr s
  | ConBranch qc tele s <- cbrs
  ]
liftBranches (LitBranches lbrs def) = LitBranches <$> sequence
  [ LitBranch l <$> liftExpr e
  | LitBranch l e <- lbrs
  ] <*> liftExpr def

liftToDefinitionM
  :: Closed.Expr Void
  -> Lift (Sized.Definition Lifted.Expr Void)
liftToDefinitionM (Closed.Anno (Closed.Lams tele s) _) = do
  tele' <- transverseTelescope liftExpr tele
  s' <- transverseScope liftExpr s
  return $ Sized.FunctionDef Public Sized.NonClosure $ Sized.Function tele' s'
liftToDefinitionM sexpr
  = Sized.ConstantDef Public . Sized.Constant <$> liftExpr sexpr

liftToDefinition
  :: QName
  -> Closed.Expr Void
  -> (Sized.Definition Lifted.Expr Void, [(QName, Sized.Function Lifted.Expr Void)])
liftToDefinition (QName mname name) expr
  = second liftedFunctions
  $ runState (runLift $ liftToDefinitionM expr) LiftState
  { freshNames = [QName mname $ name <> "-lifted" <> if n == 0 then "" else shower n | n <- [(0 :: Int)..]]
  , liftedFunctions = mempty
  }

liftDefinitionM
  :: Sized.Definition Closed.Expr Void
  -> Lift (Sized.Definition Lifted.Expr Void)
liftDefinitionM (Sized.FunctionDef vis cl (Sized.Function tele s)) = do
  tele' <- transverseTelescope liftExpr tele
  s' <- transverseScope liftExpr s
  return $ Sized.FunctionDef vis cl $ Sized.Function tele' s'
liftDefinitionM (Sized.ConstantDef vis (Sized.Constant e)) = do
  e' <- liftExpr e
  return $ Sized.ConstantDef vis $ Sized.Constant e'
liftDefinitionM Sized.AliasDef = return Sized.AliasDef

liftClosures
  :: QName
  -> Sized.Definition Closed.Expr Void
  -> (Sized.Definition Lifted.Expr Void, [(QName, Sized.Function Lifted.Expr Void)])
liftClosures (QName mname name) expr
  = second liftedFunctions
  $ runState (runLift $ liftDefinitionM expr) LiftState
  { freshNames = [QName mname $ name <> "-lifted-closure" <> if n == 0 then "" else shower n | n <- [(0 :: Int)..]]
  , liftedFunctions = mempty
  }
