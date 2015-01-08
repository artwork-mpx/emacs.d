-- The source language typechecker

{- We make typechecking (this file) happen before desugaring (Desugar.hs) so
that the error messages presented to the programmer can be clearer. However, an
undesired consequence of such approach for the compiler implementer is that the
implementation of the typing rules does not follow strictly the formalization.
For instance, in the formalization there is no rule for handling multi-field
records as they are desugared into intersections of single-field records first.
But here we have to handle such cases.-}

{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}

module TypeCheck
  ( typeCheck

  -- For REPL
  , typeCheckWithEnv
  , mkInitTcEnvWithEnv
  , TypeError
  ) where

import Src

import IOEnv
import JavaUtils
import PrettyUtils
import JvmTypeQuery
import Panic
import StringPrefixes

import Text.PrettyPrint.ANSI.Leijen

import System.IO
import System.Process

import Control.Monad.Error

import Data.Maybe (fromJust, fromMaybe)
import qualified Data.Map  as Map
import qualified Data.Set  as Set

import Prelude hiding (pred)

type Connection = (Handle, Handle)

typeCheck :: Expr Name -> IO (Either TypeError (Expr (Name,Type), Type))
-- type_server is (Handle, Handle)
typeCheck e = withTypeServer (\type_server ->
  (evalIOEnv (mkInitTcEnv type_server) . runErrorT . infer) e)

-- Temporary hack for REPL
typeCheckWithEnv :: ValueContext -> Expr Name -> IO (Either TypeError (Expr (Name,Type), Type))
-- type_server is (Handle, Handle)
typeCheckWithEnv value_ctxt e = withTypeServer (\type_server ->
  (evalIOEnv (mkInitTcEnvWithEnv value_ctxt type_server) . runErrorT . infer) e)

withTypeServer :: (Connection -> IO a) -> IO a
withTypeServer do_this =
  do cp <- getClassPath
     let p = (proc "java" ["-cp", cp, namespace ++ "TypeServer"])
               { std_in = CreatePipe, std_out = CreatePipe }
     (Just inp, Just out, _, proch) <- createProcess p
     hSetBuffering inp NoBuffering
     hSetBuffering out NoBuffering
     res <- do_this (inp, out)
     terminateProcess proch
     return res

data TcEnv
  = TcEnv
  { tceTypeContext     :: TypeContext
  , tceValueContext    :: ValueContext
  , tceTypeserver   :: Connection
  , tceMemoizedJavaClasses :: Set.Set ClassName -- Memoized Java class names
  }

mkInitTcEnv :: Connection -> TcEnv
mkInitTcEnv type_server
  = TcEnv
  { tceTypeContext     = Map.empty
  , tceValueContext    = Map.empty
  , tceTypeserver   = type_server
  , tceMemoizedJavaClasses = Set.empty
  }

-- Temporary hack for REPL
mkInitTcEnvWithEnv :: ValueContext -> Connection -> TcEnv
mkInitTcEnvWithEnv value_ctxt type_server
  = TcEnv
  { tceTypeContext     = Map.empty
  , tceValueContext    = value_ctxt
  , tceTypeserver   = type_server
  , tceMemoizedJavaClasses = Set.empty
  }

data TypeError
  = General Doc
  | ConflictingDefinitions Name
  | ExpectJClass
  | IndexTooLarge
  | Mismatch { expectedTy :: Type, actualTy :: Type }
  | MissingRHSAnnot
  | NotInScopeTVar Name
  | NotInScopeVar   Name
  | ProjectionOfNonProduct
  | NotWellKinded Type

  -- Java-specific type errors
  | NoSuchClass       ClassName
  | NoSuchConstructor ClassName [ClassName]
  | NoSuchMethod      (JCallee ClassName) MethodName [ClassName]
  | NoSuchField       (JCallee ClassName) FieldName
  deriving (Show)

instance Pretty TypeError where
  pretty (General doc)      = prettyError <+> doc
  pretty (NotInScopeTVar a) = prettyError <+> text "type" <+> prettyCode (text a) <+> text "is not in scope"
  pretty (NotWellKinded t)  = prettyError <+> prettyCode (pretty t) <+> text "is not well-kinded"
  pretty e                  = prettyError <+> text (show e)

instance Error TypeError where
  -- strMsg

type Checker a = ErrorT TypeError (IOEnv TcEnv) a

getTcEnv :: Checker TcEnv
getTcEnv = lift getEnv

setTcEnv :: TcEnv -> Checker ()
setTcEnv tc_env = lift $ setEnv tc_env

getTypeContext = liftM tceTypeContext getTcEnv

getValueContext = liftM tceValueContext getTcEnv

getTypeServer :: Checker (Handle, Handle)
getTypeServer = liftM tceTypeserver getTcEnv

getMemoizedJavaClasses :: Checker (Set.Set ClassName)
getMemoizedJavaClasses = liftM tceMemoizedJavaClasses getTcEnv

memoizeJavaClass :: ClassName -> Checker ()
memoizeJavaClass c
  = do TcEnv{..} <- getTcEnv
       memoized_java_classes <- getMemoizedJavaClasses
       setTcEnv TcEnv{ tceMemoizedJavaClasses = c `Set.insert` memoized_java_classes, ..}

withLocalTVars :: [(Name, (Kind, Maybe Type))] -> Checker a -> Checker a
withLocalTVars tvars do_this
  = do delta <- getTypeContext
       let delta' = Map.fromList tvars `Map.union` delta
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceTypeContext = delta', ..}
       r <- do_this
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceTypeContext = delta, ..}
       return r

withLocalVars :: [(Name, Type)]-> Checker a -> Checker a
withLocalVars vars do_this
  = do gamma <- getValueContext
       let gamma' = Map.fromList vars `Map.union` gamma
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceValueContext = gamma', ..}
       r <- do_this
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceValueContext = gamma, ..}
       return r

type TypeSubstitution = Map.Map Name Type

applyTSubst :: TypeSubstitution -> Type -> Type
applyTSubst s (TVar a)     = fromMaybe (TVar a) (Map.lookup a s)
-- applyTSubst _ (JClass c)   = JClass c
applyTSubst _ (JType c)    = JType c
applyTSubst s (Fun t1 t2)  = Fun (applyTSubst s t1) (applyTSubst s t2)
applyTSubst s (Forall a t) = Forall a (applyTSubst s' t) where s' = Map.delete a s
applyTSubst _ _            = sorry "TypeCheck.applyTSubst"

-- Kinding
kind :: TypeContext -> Type -> IO (Maybe Kind)
kind d (TVar a)     = case Map.lookup a d of Nothing     -> return Nothing
                                             Just (k, _) -> return (Just k)
kind _ (JType _)    = return (Just Star) -- TODO
kind _  Unit        = return (Just Star)
kind d (Fun t1 t2)  = justStarIffAllHaveKindStar d [t1, t2]
kind d (Forall a t) = kind d' t where d' = Map.insert a (Star, Nothing) d
kind d (Product ts) = justStarIffAllHaveKindStar d ts
kind d (Record fs)  = justStarIffAllHaveKindStar d (map snd fs)
kind d (ListOf t)   = kind d t
kind d (And t1 t2)  = justStarIffAllHaveKindStar d [t1, t2]
kind d (Thunk t)    = kind d t
kind d (OpAbs _x t) = do -- Restriction compared to F_omega: x can only have kind *
  maybe_k <- kind d t
  case maybe_k of
    Nothing -> return Nothing
    Just k  -> return $ Just (KArrow Star k)
-- \Delta |- T1 :: K11 => K12  \Delta |- T2 :: K11
-- -------------------------------------------- (K-App)
-- \Delta |- T1 T2 :: K12
kind d (OpApp t1 t2) = do
  maybe_k1 <- kind d t1
  maybe_k2 <- kind d t2
  case (maybe_k1, maybe_k2) of
    (Just (KArrow k11 k12), Just k2) | k2 == k11 -> return (Just k12)
    _ -> return Nothing
kind _ t = sorry (show t)

justStarIffAllHaveKindStar :: TypeContext -> [Type] -> IO (Maybe Kind)
justStarIffAllHaveKindStar d ts
  = do ps <- mapM (hasKindStar d) ts
       if and ps
          then return (Just Star)
          else return Nothing

hasKindStar :: TypeContext -> Type -> IO Bool
hasKindStar d t
  = do k <- kind d t
       return (k == Just Star)

infer :: Expr Name -> Checker (Expr (Name,Type), Type)
infer (Var name)
  = do value_ctxt <- getValueContext
       case Map.lookup name value_ctxt of
         Just t  -> return (Var (name,t), t)
         Nothing -> throwError (NotInScopeVar name)

infer (Lit lit) = return (Lit lit, srcLitType lit)

infer (Lam (x1,t1) e)
  = do checkType t1
       (e', t) <- withLocalVars [(x1,t1)] (infer e)
       return (Lam (x1,t1) e', Fun t1 t)

infer (App e1 e2)
  = do (e1', t1) <- infer e1
       (e2', t2) <- infer e2
       case t1 of
         Fun t11 t12 -> do t11' <- expandType t11
                           t2'  <- expandType t2
                           unless (dethunk t2' `subtype` dethunk t11') $
                             throwError
                               (General
                                  (prettyCode (pretty e1) <+> text "expects an argument of type" <+>
                                   prettyCode (pretty t11) <+> text "or a subtype of that" <> comma <+>
                                   text "but the argument" <+> prettyCode (pretty e2) <+> text "has type" <+> pretty t2))
                           return (App e1' e2', t12)
         _         -> throwError (General (prettyCode (pretty e1) <+> text "is of type" <+> prettyCode (pretty t1) <> text "; it cannot be applied"))

infer (BLam a e)
  = do (e', t) <- withLocalTVars [(a, (Star, Nothing))] (infer e)
       return (BLam a e', Forall a t)

infer (TApp e targ)
  = do (e', t) <- infer e
       checkType targ
       case t of
         Forall a t1 -> return (TApp e' targ, fsubstTT (a, targ) t1)
         _           -> sorry "TypeCheck.infer: TApp"

infer (Tuple es)
  | length es < 2 = panic "Src.TypeCheck.infer: Tuple: fewer than two items"
  | otherwise     = do (es', ts) <- mapAndUnzipM infer es
                       return (Tuple es', Product ts)

infer (Proj e i)
  = do (e', t) <- infer e
       case t of
         Product ts
           | 1 <= i && i <= length ts -> return (Proj e' i, ts !! (i - 1))
           | otherwise -> throwError IndexTooLarge
         _ -> throwError ProjectionOfNonProduct

infer (PrimOp e1 op e2)
  = case op of
      Arith _ ->
        do (e1', _t1) <- inferAgainst e1 (JType $ JClass "java.lang.Integer")
           (e2', _t2) <- inferAgainst e2 (JType $ JClass "java.lang.Integer")
           return (PrimOp e1' op e2', JType $ JClass "java.lang.Integer")
      Compare _ ->
        do (e1', t1)  <- infer e1
           (e2', _t2) <- inferAgainst e2 t1
           return (PrimOp e1' op e2', JType $ JClass "java.lang.Boolean")
      Logic _ ->
        do (e1', _t1) <- inferAgainst e1 (JType $ JClass "java.lang.Boolean")
           (e2', _t2) <- inferAgainst e2 (JType $ JClass "java.lang.Boolean")
           return (PrimOp e1' op e2', JType $ JClass "java.lang.Boolean")

infer (If pred b1 b2)
  = do (pred', _pred_ty) <- inferAgainst pred (JType $ JClass "java.lang.Boolean")
       (b1', t1)         <- infer b1
       (b2', _t2)        <- inferAgainst b2 t1
       return (If pred' b1' b2', t1)

infer (Let rec_flag binds e) =
  do checkDupNames (map bindId binds)
     binds' <- case rec_flag of
                 NonRec -> mapM inferBind binds
                 Rec    -> do sigs <- collectBindNameSigs binds
                              withLocalVars sigs (mapM inferBind binds)
     (e', t) <- withLocalVars (map (\ (f,t,_) -> (f,t)) binds') (infer e)
     return (LetOut rec_flag binds' e', t)

infer (LetOut{..}) = panic "TypeCheck.infer: LetOut"

-- JNew, JMethod, and JField

infer (JNew c args)
  = do checkClassName c
       (args', arg_cs) <- mapAndUnzipM inferAgainstAnyJClass args
       checkConstruction c arg_cs
       return (JNew c args', JType (JClass c))

infer (JMethod callee m args _)
  = case callee of
      Static c ->
        do (args', arg_cs) <- mapAndUnzipM inferAgainstAnyJClass args
           ret_c <- checkMethodCall (Static c) m arg_cs
           if ret_c == "char"
             then return (JMethod (Static c) m args' ret_c, JType $ JPrim "char")
             else return (JMethod (Static c) m args' ret_c, JType $ JClass ret_c)
      NonStatic e ->
        do (e', c)         <- inferAgainstAnyJClass e
           (args', arg_cs) <- mapAndUnzipM inferAgainstAnyJClass args
           ret_c <- checkMethodCall (NonStatic c) m arg_cs
           if ret_c == "char"
             then return (JMethod (NonStatic e') m args' ret_c, JType $ JPrim "char")
             else return (JMethod (NonStatic e') m args' ret_c, JType $ JClass ret_c)

infer (JField callee f _)
  = case callee of
      Static c ->
        do ret_c <- checkFieldAccess (Static c) f
           if ret_c == "char"
              then return (JField (Static c) f ret_c, JType $ JPrim ret_c)
              else return (JField (Static c) f ret_c, JType $ JClass ret_c)
      NonStatic e ->
        do (e', t) <- infer e
           case t of
             Record _ -> infer (RecordAccess e f) -- Then the typechecker realized!
             JType (JClass c)   ->
               do ret_c   <- checkFieldAccess (NonStatic c) f
                  if ret_c == "char"
                    then return (JField (NonStatic e') f ret_c, JType $ JPrim "char")
                    else return (JField (NonStatic e') f ret_c, JType $ JClass ret_c)
             And t1 t2 -> return (RecordAccess e' f, fromJust (lookup (Just f) (fields t1 ++ fields t2)))
             _          -> throwError
                           (General
                            (prettyCode (pretty e) <+> text "has type" <+> prettyCode (pretty t) <>
                             text ", which does not support the dot notation"))

infer (Seq es) = do
  (es', ts) <- mapAndUnzipM infer es
  return (Seq es', last ts)

infer (Merge e1 e2) =
  do (e1', t1) <- infer e1
     (e2', t2) <- infer e2
     return (Merge e1' e2', And t1 t2)

infer (PrimList l) =
      do (es, ts) <- mapAndUnzipM infer l
         case ts of [] -> return (PrimList es, JType $ JClass (namespace ++ "FunctionalList"))
                    _  -> if all (`alphaEq` head ts) ts
                            then return (PrimList es, JType $ JClass (namespace ++ "FunctionalList"))
                            else throwError $ General (text "Primitive List Type Mismatch" <+> text (show (PrimList l)))

infer (RecordLit fs) =
  do (es', ts) <- mapAndUnzipM infer (map snd fs)
     return (RecordLit (zip (map fst fs) es'), Record (zip (map fst fs) ts))

infer (RecordAccess e l) =
  do (e', t) <- infer e
     return (RecordAccess e' l, fromJust (lookup (Just l) (fields t)))

infer (RecordUpdate e fs) =
  do (es', _ts) <- mapAndUnzipM infer (map snd fs)
     (e', t) <- infer e
     return (RecordUpdate e' (zip (map fst fs) es'), t)

-- Well, I know the desugaring is too early to happen here...
infer (LetModule (Module m binds) e) =
  do let fs = map bindId binds
     let letrec = Let Rec binds (RecordLit (map (\f -> (f, Var f)) fs))
     infer $ Let NonRec [Bind m [] [] letrec Nothing] e
infer (ModuleAccess m f) = infer (RecordAccess (Var m) f)

-- Type synonyms: type T A1 ... An = t in e
-- First make sure that A1 ... An are distinct.
-- Then rewrite to "type T = \A1. ... An. t in e" and kind-check \A1. ... \An. t.
infer (Type t params rhs e)
  = do checkDupNames params
       typeContext <- getTypeContext
       maybe_kind <- liftIO $ kind typeContext pulledRight
       case maybe_kind of
         Nothing -> throwError $ NotWellKinded pulledRight
         Just k  -> withLocalTVars [(t, (k, Just pulledRight))] $ infer e
  where
    pulledRight = pullRight params rhs

-- | "Pull" the type params at the LHS of the equal sign to the right.
-- A (high-level) example:
--   A B t  ->  \A. \B. t
-- Another concrete example:
--   ghci> pullRight ["A", "B"] (JType (JClass "java.lang.Integer"))
--   OpAbs "A" (OpAbs "B" (JType (JClass "java.lang.Integer")))
pullRight :: [Name] -> Type -> Type
pullRight params t = foldr OpAbs t params

inferAgainst :: Expr Name -> Type -> Checker (Expr (Name,Type), Type)
inferAgainst expr expected_ty
  = do (expr', actual_ty) <- infer expr
       if actual_ty `alphaEq` expected_ty
          then return (expr', actual_ty)
          else throwError (Mismatch expected_ty actual_ty)

inferAgainstAnyJClass :: Expr Name -> Checker (Expr (Name,Type), ClassName)
inferAgainstAnyJClass expr
  = do (expr', ty) <- infer expr
       case dethunk ty of
        JType (JPrim "char") -> return (expr', "java.lang.Character")
        JType (JClass c) -> return (expr', c)
        _ -> throwError $
             General
             (prettyCode (pretty expr) <+> text "has type" <+> prettyCode (pretty ty) <> comma <+>
              text "but is expected to be of some Java class")

-- f A1 ... An (x1:T1) ... (xn:Tn) = e
inferBind :: Bind Name -> Checker (Name, Type, Expr (Name,Type))
inferBind bind
  = do bind' <- checkBindLHS bind
       (bindRhs', bindRhsTy) <- withLocalTVars (map (\a -> (a, (Star, Nothing))) (bindTargs bind')) $
                                  do expandedBindArgs <- mapM (\(x,t) -> do { t' <- expandType t; return (x,t') }) (bindArgs bind')
                                     withLocalVars expandedBindArgs (infer (bindRhs bind'))
       return ( bindId bind'
              , wrap Forall (bindTargs bind') (wrap Fun (map snd (bindArgs bind')) bindRhsTy)
              , wrap BLam (bindTargs bind') (wrap Lam (bindArgs bind') bindRhs'))

checkBindLHS :: Bind Name -> Checker (Bind Name)
checkBindLHS bind@Bind{..}
  = do checkDupNames bindTargs
       checkDupNames [x | (x, _) <- bindArgs]
       bindArgs' <- withLocalTVars (map (\a -> (a, (Star, Nothing))) bindTargs) $
         forM bindArgs (\(x, t) ->
          do --checkType t
             t' <- expandType t
             return (x,t'))
       return bind { bindArgs = bindArgs' }

collectBindNameSigs :: [Bind Name] -> Checker [(Name, Type)]
collectBindNameSigs
  = mapM (\ Bind{..} ->
            case bindRhsAnnot of
              Nothing    -> throwError MissingRHSAnnot
              Just rhsTy -> return (bindId,
                                    wrap Forall bindTargs $
                                    wrap Fun [ty |  (_,ty) <- bindArgs]
                                    rhsTy))

checkType :: Type -> Checker ()
checkType t
  = case t of
      JType (JClass c) -> checkClassName c
      _        ->
        do type_ctxt <- getTypeContext
           let free_ty_vars = freeTVars t `Set.difference` Set.fromList (map fst (filter (\(_,(k,_)) -> k == Star) (Map.toList type_ctxt)))
           unless (Set.null free_ty_vars) $
             throwError (NotInScopeTVar (head (Set.toList free_ty_vars)))

unlessIO :: (Monad m, MonadIO m) => IO Bool -> m () -> m ()
unlessIO test do_this
  = do ok <- liftIO test
       unless ok do_this

-- Client library of typeserver API

checkClassName :: ClassName -> Checker ()
checkClassName c
  = do memoized_java_classes <- getMemoizedJavaClasses
       unless (c `Set.member` memoized_java_classes) $
         do h  <- getTypeServer
            res <- liftIO (isJvmType h c)
            if res
               then memoizeJavaClass c
               else throwError (NoSuchClass c)

checkConstruction :: ClassName -> [ClassName] -> Checker ()
checkConstruction c args
  = do h <- getTypeServer
       unlessIO (hasConstructor h c args) $
         throwError (NoSuchConstructor c args)

checkMethodCall :: JCallee ClassName -> MethodName -> [ClassName] -> Checker ClassName
checkMethodCall callee m args
  = do typeserver <- getTypeServer
       res <- liftIO (methodTypeOf typeserver c (m, static_flag) args)
       case res of
         Nothing           -> throwError (NoSuchMethod callee m args)
         Just return_class -> return return_class
    where
       (static_flag, c) = unwrapJCallee callee

checkFieldAccess :: JCallee ClassName -> FieldName -> Checker ClassName
checkFieldAccess callee f
  = do typeserver <- getTypeServer
       res <- liftIO (fieldTypeOf typeserver c (f, static_flag))
       case res of
         Nothing           -> throwError (NoSuchField callee f)
         Just return_class -> return return_class
    where
       (static_flag, c) = unwrapJCallee callee

-- | Expand the type.
expandType :: Type -> Checker Type
expandType (TVar a)
  = do typeContext <- getTypeContext
       case Map.lookup a typeContext of
         Nothing            -> return (TVar a)
         Just (_, Nothing)  -> return (TVar a)
         Just (_, Just def) -> expandType def
expandType (JType t) = return (JType t)
expandType Unit       = return Unit
expandType (Fun t1 t2)
  = do t1' <- expandType t1
       t2' <- expandType t2
       return (Fun t1' t2')
expandType (Forall a t)
  = do t' <- withLocalTVars [(a, (Star, Nothing))] (expandType t)
       return (Forall a t')
expandType (Product ts)
  = do ts' <- mapM expandType ts
       return (Product ts')
expandType (Record fs)
  = do ts' <- mapM (expandType . snd) fs
       return (Record (zip (map fst fs) ts'))
expandType (ListOf t)
  = do t' <- expandType t
       return (ListOf t')
expandType (And t1 t2)
  = do t1' <- expandType t1
       t2' <- expandType t2
       return (And t1' t2')
expandType (Thunk t)
  = do t' <- expandType t
       return (Thunk t')
expandType (OpApp (TVar t1) t2)
  = do typeContext <- getTypeContext
       case Map.lookup t1 typeContext of
         Just (_, Just (OpAbs param t)) -> return (fsubstTT (param, t2) t)

unwrapJCallee :: JCallee ClassName -> (Bool, ClassName)
unwrapJCallee (NonStatic c) = (False, c)
unwrapJCallee (Static    c) = (True, c)

srcLitType :: Lit -> Type
srcLitType (Int _)    = JType $ JClass "java.lang.Integer"
srcLitType (String _) = JType $ JClass "java.lang.String"
srcLitType (Bool _)   = JType $ JClass "java.lang.Boolean"
srcLitType (Char _)   = JType $ JClass "java.lang.Character"
srcLitType UnitLit    = Unit

checkDupNames :: [Name] -> Checker ()
checkDupNames names
  = case findOneDup names of
      Nothing   -> return ()
      Just name -> throwError (ConflictingDefinitions name)

-- | Find one instance of duplicate in a list.
findOneDup :: Ord a => [a] -> Maybe a
findOneDup xs = go xs Set.empty
  where
    go []      _ = Nothing
    go (x:xs') s = if Set.member x s
                     then Just x
                     else go xs' (Set.insert x s)
