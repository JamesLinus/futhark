module Futhark.Analysis.SymbolTable
  ( SymbolTable (bindings, annotationFunction)
  , empty
  , Entry (..)
  , lookup
  , lookupExp
  , lookupSubExp
  , lookupScalExp
  , lookupValue
  , lookupVar
  , deepen
  , depth
  , enclosingLoopVars
  , bindingEntries
  , insertBinding
  , insertBindingWith
  , insertParam
  , insertArrayParam
  , insertLoopVar
  , insertEntries
  , updateBounds
  , isAtLeast
  , UserAnnotation (..)
  )
  where

import Prelude hiding (lookup)

import Control.Applicative hiding (empty)
import Data.Ord
import Data.Maybe
import Data.List hiding (insert, lookup)
import qualified Data.Set as S
import qualified Data.HashMap.Lazy as HM

import Data.Loc
import Futhark.InternalRep hiding (insertBinding)
import Futhark.Analysis.ScalExp
import Futhark.Substitute
import qualified Futhark.Analysis.AlgSimplify as AS

data SymbolTable a = SymbolTable {
    loopDepth :: Int
  , bindings :: HM.HashMap VName (Entry a)
  , annotationFunction :: Entry () -> a
  }

empty :: UserAnnotation a => SymbolTable a
empty = SymbolTable 0 HM.empty annotationFor

deepen :: SymbolTable a -> SymbolTable a
deepen vtable = vtable { loopDepth = loopDepth vtable + 1 }

depth :: SymbolTable a -> Int
depth = loopDepth

class Substitute u => UserAnnotation u where
  annotationFor :: Entry () -> u

instance UserAnnotation () where
  annotationFor = const ()

data Entry a = Entry {
    asExp :: Maybe Exp
  , asScalExp :: Maybe ScalExp
  , bindingDepth :: Int
  , valueRange :: Range
  , loopVariable :: Bool
  , userAnnotation :: a
  } deriving (Eq, Show)

instance Substitute a => Substitute (Entry a) where
  substituteNames substs entry =
    entry { asExp = substituteNames substs <$> asExp entry
          , asScalExp = substituteNames substs <$> asScalExp entry
          , userAnnotation = userAnnotation entry
          }

type Range = (Maybe ScalExp, Maybe ScalExp)

lookup :: VName -> SymbolTable u -> Maybe (Entry u)
lookup name = HM.lookup name . bindings

lookupExp :: VName -> SymbolTable a -> Maybe Exp
lookupExp name vtable = asExp =<< lookup name vtable

lookupSubExp :: VName -> SymbolTable a -> Maybe SubExp
lookupSubExp name vtable = do
  e <- lookupExp name vtable
  case e of
    SubExp se -> Just se
    _         -> Nothing

lookupScalExp :: VName -> SymbolTable a -> Maybe ScalExp
lookupScalExp name vtable = asScalExp =<< lookup name vtable

lookupValue :: VName -> SymbolTable a -> Maybe Value
lookupValue name vtable = case lookupSubExp name vtable of
                            Just (Constant val _) -> Just val
                            _                     -> Nothing

lookupVar :: VName -> SymbolTable a -> Maybe VName
lookupVar name vtable = case lookupSubExp name vtable of
                          Just (Var v) -> Just $ identName v
                          _            -> Nothing

lookupRange :: VName -> SymbolTable a -> Range
lookupRange name vtable =
  maybe (Nothing, Nothing) valueRange $ lookup name vtable

enclosingLoopVars :: [VName] -> SymbolTable a -> [VName]
enclosingLoopVars free vtable =
  map fst $ reverse $
  sortBy (comparing (bindingDepth . snd)) $
  filter (loopVariable . snd) $ mapMaybe fetch free
  where fetch name = do e <- lookup name vtable
                        return (name, e)

defEntry :: SymbolTable a -> Entry ()
defEntry vtable = Entry {
    asExp = Nothing
  , asScalExp = Nothing
  , valueRange = (Nothing, Nothing)
  , bindingDepth = loopDepth vtable
  , loopVariable = False
  , userAnnotation = ()
  }

annotateEntry :: Entry () -> SymbolTable a -> Entry a
annotateEntry entry vtable =
  entry { userAnnotation = annotationFunction vtable entry }

bindingEntries :: Binding -> SymbolTable a -> [Entry a]
-- First, handle single-name bindings.  These are the most common.
bindingEntries (Let [_] e) vtable = [annotateEntry entry vtable]
  where entry = (defEntry vtable)
                { asExp = Just e
                , asScalExp = toScalExp (`lookupScalExp` vtable) e
                , valueRange = range
                }
        range = case e of
          SubExp se ->
            subExpRange se vtable
          Iota n _ ->
            (Just zero, (`SMinus` one) <$> subExpToScalExp n)
          Replicate _ v _ ->
            subExpRange v vtable
          Rearrange _ _ v _ ->
            subExpRange v vtable
          Split _ se _ _ _ ->
            subExpRange se vtable
          Copy se _ ->
            subExpRange se vtable
          Index _ v _ _ ->
            lookupRange (identName v) vtable
          _ -> (Nothing, Nothing)
        zero = Val $ IntVal 0
        one = Val $ IntVal 1
-- Then, handle others.  For now, this is only filter.
bindingEntries (Let _ (Filter _ _ inps _)) vtable =
  map (`annotateEntry` vtable) $ defEntry vtable : map makeBnd inps
  where makeBnd (Var v) =
          (defEntry vtable) { valueRange = lookupRange (identName v) vtable }
        makeBnd _ =
          defEntry vtable
bindingEntries (Let names _) vtable =
  map ((`annotateEntry` vtable) . const (defEntry vtable)) names

insertBinding :: Binding -> SymbolTable a -> SymbolTable a
-- First, handle single-name bindings.  These are the most common.
insertBinding bnd@(Let pat _) vtable =
  insertEntries (zip names $ bindingEntries bnd vtable) vtable
  where names = map identName pat

insertBindingWith :: (Entry () -> a) -> Binding -> SymbolTable a -> SymbolTable a
insertBindingWith f bnd vtable =
  (insertBinding bnd vtable { annotationFunction = f })
  { annotationFunction = annotationFunction vtable }

subExpRange :: SubExp -> SymbolTable a -> Range
subExpRange (Var v) vtable =
  lookupRange (identName v) vtable
subExpRange (Constant (BasicVal bv) _) _ =
  (Just $ Val bv, Just $ Val bv)
subExpRange (Constant (ArrayVal _ _) _) _ =
  (Nothing, Nothing)

subExpToScalExp :: SubExp -> Maybe ScalExp
subExpToScalExp (Var v)                    = Just $ Id v
subExpToScalExp (Constant (BasicVal bv) _) = Just $ Val bv
subExpToScalExp _                          = Nothing

insertEntry :: VName -> Entry () -> SymbolTable a -> SymbolTable a
insertEntry name entry =
  insertEntries' [(name,entry)]

insertEntries' :: [(VName, Entry ())] -> SymbolTable a -> SymbolTable a
insertEntries' entries vtable =
  insertEntries [ (name, annotateEntry entry vtable) |
                  (name,entry) <- entries] vtable

insertEntries :: [(VName, Entry a)] -> SymbolTable a -> SymbolTable a
insertEntries entries vtable =
  vtable { bindings = foldl insertWithDepth (bindings vtable) entries
         }
  where insertWithDepth bnds (name, entry) =
          let entry' = entry { bindingDepth = loopDepth vtable }
          in HM.insert name entry' bnds

insertParamWithRange :: Param -> Range -> SymbolTable a -> SymbolTable a
insertParamWithRange param range vtable =
  -- We know that the sizes in the type of param are at least zero,
  -- since they are array sizes.
  let vtable' = insertEntry name bind vtable
  in foldr (`isAtLeast` 0) vtable' sizevars
  where bind = (defEntry vtable) { valueRange = range
                               , loopVariable = True
                               }
        name = identName param
        sizevars = mapMaybe isVar $ arrayDims $ identType param
        isVar (Var v) = Just $ identName v
        isVar _       = Nothing

insertParam :: Param -> SymbolTable a -> SymbolTable a
insertParam param =
  insertParamWithRange param (Nothing, Nothing)

insertArrayParam :: Param -> SubExp -> SymbolTable a -> SymbolTable a
insertArrayParam param array vtable =
  -- We now know that the outer size of 'array' is at least one, and
  -- that the inner sizes are at least zero, since they are array
  -- sizes.
  let vtable' = insertParamWithRange param (subExpRange array vtable) vtable
  in case arrayDims $ subExpType array of
    Var v:_ -> (identName v `isAtLeast` 1) vtable'
    _       -> vtable'

insertLoopVar :: VName -> SubExp -> SymbolTable a -> SymbolTable a
insertLoopVar name bound vtable = insertEntry name bind vtable
  where bind = (defEntry vtable) {
            valueRange = (Just (Val (IntVal 0)),
                        minus1 <$> toScalExp look (SubExp bound))
          , loopVariable = True
          }
        look = (`lookupScalExp` vtable)
        minus1 = (`SMinus` Val (IntVal 1))

updateBounds :: Bool -> SubExp -> SymbolTable a -> SymbolTable a
updateBounds isTrue cond vtable =
  case toScalExp (`lookupScalExp` vtable) $ SubExp cond of
    Nothing    -> vtable
    Just cond' ->
      let cond'' | isTrue    = cond'
                 | otherwise = SNot cond'
      in updateBounds' (srclocOf cond) cond'' vtable
-- | Refines the ranges in the symbol table with
--     ranges extracted from branch conditions.
--   `cond' is the condition of the if-branch.
updateBounds' :: SrcLoc -> ScalExp -> SymbolTable a -> SymbolTable a
updateBounds' loc cond sym_tab =
  foldr updateBound sym_tab $ mapMaybe solve_leq0 $
  either (const []) getNotFactorsLEQ0 $ AS.simplify (SNot cond) loc ranges
    where
      updateBound (sym,True ,bound) = setUpperBound (identName sym) bound
      updateBound (sym,False,bound) = setLowerBound (identName sym) bound

      ranges = HM.filter nonEmptyRange $ HM.map toRep $ bindings sym_tab
      toRep entry = (bindingDepth entry, lower, upper)
        where (lower, upper) = valueRange entry
      nonEmptyRange (_, lower, upper) = isJust lower || isJust upper

      -- | Input: a bool exp in DNF form, named `cond'
      --   It gets the terms of the argument,
      --         i.e., cond = c1 || ... || cn
      --   and negates them.
      --   Returns [not c1, ..., not cn], i.e., the factors
      --   of `not cond' in CNF form: not cond = (not c1) && ... && (not cn)
      getNotFactorsLEQ0 :: ScalExp -> [ScalExp]
      getNotFactorsLEQ0 (RelExp rel e_scal) =
          if scalExpType e_scal /= Int then []
          else let leq0_escal = if rel == LTH0
                                then SMinus (Val (IntVal 0)) e_scal
                                else SMinus (Val (IntVal 1)) e_scal

               in  either (const []) (:[]) $ AS.simplify leq0_escal loc ranges
      getNotFactorsLEQ0 (SLogOr  e1 e2) = getNotFactorsLEQ0 e1 ++ getNotFactorsLEQ0 e2
      getNotFactorsLEQ0 _ = []

      -- | Argument is scalar expression `e'.
      --    Implementation finds the symbol defined at
      --    the highest depth in expression `e', call it `i',
      --    and decomposes e = a*i + b.  If `a' and `b' are
      --    free of `i', AND `a == 1 or -1' THEN the upper/lower
      --    bound can be improved. Otherwise Nothing.
      --
      --  Returns: Nothing or
      --  Just (i, a == 1, -a*b), i.e., (symbol, isUpperBound, bound)
      solve_leq0 :: ScalExp -> Maybe (Ident, Bool, ScalExp)
      solve_leq0 e_scal = do
        sym <- AS.pickSymToElim ranges S.empty e_scal
        (a,b) <- either (const Nothing) id $ AS.linFormScalE sym e_scal loc ranges
        case a of
          Val (IntVal (-1)) -> Just (sym, False, b)
          Val (IntVal 1)    -> do
            mb <- either (const Nothing) Just $ AS.simplify (SMinus (Val (IntVal 0)) b) loc ranges
            Just (sym, True, mb)
          _ -> Nothing

setUpperBound :: VName -> ScalExp -> SymbolTable a -> SymbolTable a
setUpperBound name bound vtable =
  vtable { bindings = HM.adjust setUpperBound' name $ bindings vtable }
  where setUpperBound' bind =
          let (oldLowerBound, oldUpperBound) = valueRange bind
          in bind { valueRange =
                      (oldLowerBound,
                       Just $ maybe bound (MaxMin True . (:[bound])) oldUpperBound)
                  }

setLowerBound :: VName -> ScalExp -> SymbolTable a -> SymbolTable a
setLowerBound name bound vtable =
  vtable { bindings = HM.adjust setLowerBound' name $ bindings vtable }
  where setLowerBound' bind =
          let (oldLowerBound, oldUpperBound) = valueRange bind
          in bind { valueRange =
                      (Just $ maybe bound (MaxMin False . (:[bound])) oldLowerBound,
                       oldUpperBound)
                  }

isAtLeast :: VName -> Int -> SymbolTable a -> SymbolTable a
isAtLeast name x =
  setLowerBound name $ Val $ IntVal x