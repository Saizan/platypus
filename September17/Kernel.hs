--------------------------------------------------------------------------------
{-# LANGUAGE GADTs, DataKinds, TypeOperators, KindSignatures, TypeInType,
             TypeFamilies, ExistentialQuantification, Rank2Types, ScopedTypeVariables,
             PatternGuards, PatternSynonyms #-}

module Kernel where

import Prelude hiding ((^^))
import Data.Kind

import Utils
import OPE

data Sort = Chk | Syn | Pnt
data Kind = Adicity :=> Sort
type Adicity = [Kind]
type Scope = Bwd Kind

type family SORT (k :: Kind) :: Sort where
 SORT (_ :=> s) = s

type family ADICITY (k :: Kind) :: Adicity where
  ADICITY (ks :=> _) = ks

type BSyn gamma = gamma :< ('[] :=> Syn)
type SYN1 = '[ '[] :=> Syn]

data Term :: Sort -> Scope -> * where
  Star :: Term Chk B0
  Pi   :: (TermK ('[] :=> Chk) >< TermK (SYN1 :=> Chk)) gamma ->
          Term Chk gamma
  Lam  :: TermK (SYN1 :=> Chk) gamma -> Term Chk gamma
  Emb  :: TermK ('[] :=> Syn) gamma -> Term Chk gamma
  Var  :: (This (ks :=> s) >< Spine ks) gamma -> Term s gamma -- meta level instantiation
  App  :: (TermK ('[] :=> Syn) >< TermK ('[] :=> Chk)) gamma -> Term Syn gamma -- object level app

data Spine :: [Kind] -> Scope -> * where
  S0 :: Spine '[] B0
  SC :: (TermK k >< Spine ks) gamma -> Spine (k:ks) gamma
  
type TermK k = Bind (ADICITY k) (Term (SORT k))

pattern c :$ ts = Var (Pair c It ts)

type family Bind (sc :: Adicity)(f :: Scope -> *) :: (Scope -> *)
  where
  Bind '[] f = f
  Bind (k:ks) f = k !- Bind ks f

isPi :: Term Chk ^ gamma -> Maybe
        ( String {- name used in abstraction -}
        , Term Chk ^ gamma {- domain-}
        , (('[] :=> Syn) !- Term Chk) ^ gamma {- range -}
        )
isPi (Pi pST :^ r) = (pST :^ r) >^< \ _S _T -> Just (nomth _T, _S, _T)
isPi _ = Nothing


data ContextEntry :: Kind -> Scope -> * where
  CESyn :: Term Chk ^ gamma {- type -}
        -> ContextEntry ('[] :=> Syn) gamma
  CEBind :: ContextEntry k gamma -> ContextEntry (ks :=> i) (gamma:<k) ->
            ContextEntry ((k:ks) :=> i) gamma
  -- something for Chk?

thCE :: ContextEntry k gamma -> gamma <= delta -> ContextEntry k delta
thCE (CESyn _S) r = CESyn (_S ^^ r)
thCE (CEBind _S _T) r = CEBind (thCE _S r) (thCE _T (OS r))

data Context :: Scope -> * where
  C0 :: Context B0
  CS :: Context gamma -> ContextEntry k gamma -> Context (gamma :< k)

data TmTy gamma =
  (:::) { term :: Term Chk ^ gamma, typ :: Term Chk ^ gamma }

{-
kind and scope indexed context entries
-}
data Image :: Scope -> Kind -> * where
  ISyn :: TmTy delta -> Image delta ('[] :=> Syn)
  IBind :: ContextEntry k delta ->
           Image (delta:<k) (ks :=> i) ->
           Image delta ((k:ks) :=> i)
  -- something for Chk?

-- We need to be able to thin an image.

thIm :: Image gamma k -> gamma <= delta -> Image delta k
thIm (ISyn (t ::: _T)) r = ISyn ((t ^^ r) ::: (_T ^^ r))
thIm (IBind _S u)      r = IBind (thCE _S r)(thIm u (OS r))

data Mor (gamma :: Scope)(delta :: Scope) :: * where
  Mor :: (Sorted delta)  {- we must know these lengths -}
      => Context delta  {- target context lets us reconstruct types -}
      -> Riffle rho gamma sigma   {- rho gets thinned; sigma subsituted -}
      -> rho <= delta             {- rho's thinning -}
      -> ALL (Image delta) sigma  {- sigma's substitution -}
      -> Mor gamma delta

morCx :: Mor gamma delta -> Context delta
morCx (Mor _De _ _ _) = _De

-- We need to be able to weaken a Mor.

idMor :: Sorted gamma => Context gamma -> Mor gamma gamma
idMor _Ga = Mor _Ga riffL oI A0

wkMor :: Mor gamma delta -> ContextEntry k delta -> Mor (gamma :< k) (delta :< k)
wkMor (Mor _De rs rDe sDe) _EDe =
  Mor (CS _De _EDe) (RL rs) (OS rDe) (mapIx (`thIm` O' oI) sDe)

subCxE :: Mor gamma delta -> ContextEntry k gamma -> ContextEntry k delta
subCxE m _E = undefined

-- It's hard to whittle a Mor gamma' delta by some gamma <= gamma',
-- because removing arbitrary entries from a Context won't work.
-- A variable that isn't used in a term might still be used in the
-- type of a variable that does get used.

-- Correspondingly, when we implement substitution, we need to keep
-- the whole morphism, but remember which variables are available.

subChk :: Mor gamma delta {- the morphism -}
       -> Term Chk ^ gamma {- the term to act on -}
       -> Term Chk ^ delta {- the target type -}
       -> Term Chk ^ delta {- the term we end up with -}
subChk m (Star :^ _) (Star :^ r) = Star :^ r
subChk m t           (Star :^ r)
  | Just (x, _S, _T) <- isPi t =
  let _S' = subChk m _S (Star :^ r)
      _T' = subChk (wkMor m (CESyn _S')) (dive _T) (Star :^ O' r)
  in  mapIx Pi (pair _S' (abstract x _T'))
subChk m (t :^ r0)    ty | Just (x, _S :^ r1, _T :^ r2) <- isPi ty =
  let y = case t of { Lam t' -> nom t' ; _ -> x }
  in  mapIx Lam (abstract y undefined)
subChk m (Emb e :^ r) _        = term (subSyn m (e :^ r))

subSyn :: Mor gamma delta {- the morphism -}
       -> Term Syn ^ gamma {- the elimination to act on -}
       -> TmTy delta
subSyn m@(Mor _De w r' sg) (Var its :^ r) = (its :^ r) >^< \ (It :^ i) ts ->
  case whiffle i w of
    Wh j (RL RZ) k ->
      let
      in   mapIx (Emb . Var) (pair (It :^ (r' -<=- j)) _) ::: _
    Wh j (RR RZ) k -> _
subSyn m@(Mor _De _ _ _) (App fs  :^ r) = (fs :^ r) >^< \ f s ->
  let f' ::: _F = subSyn m f
      Just (x, _S, _T) = isPi _F
      s' = subChk m s _S
  in  apply _De f' (_S, _T) s'

apply :: Sorted delta
      => Context delta
      -> Term Chk ^ delta {- function -}
      -> ( Term Chk ^ delta {- domain -}
         , TermK (SYN1 :=> Chk) ^ delta {- range -}
         )
      -> Term Chk ^ delta {- argument -}
      -> TmTy delta
apply _De (f :^ r) (_S, _T) s = case f of
    Lam t -> (inst _De (t :^ r) (s ::: _S) _Ts ::: _Ts)
    Emb e -> (mapIx (Emb . App) (pair (e :^ r) s) ::: _Ts)
  where _Ts = inst _De _T (s ::: _S) (Star :^ oN)

inst :: Sorted delta
     => Context delta
     -> TermK (SYN1 :=> Chk) ^ delta {- body -}
     -> TmTy delta {- argument -}
     -> Term Chk ^ delta {- target type -}
     -> Term Chk ^ delta {- body instantiated -}
inst _De (K t :^ r) _ _Ts =
  -- instantiating the type may demand eta expansion, even if there is
  -- no substitution
  subChk (idMor _De) (t :^ r) _Ts
inst _De (L _ t :^ r) sS _Ts =
  subChk (Mor _De (RR riffL) oI (AS A0 (ISyn sS)))
    (t :^ OS r)
    _Ts


-- some examples

idFun :: Term Chk B0
idFun = Lam (L "x" (Emb (CS' CZZ :$ S0)))

polyIdFunType :: Term Chk B0
polyIdFunType = Pi (Pair CZZ Star (L "X"
                  (Pi (Pair (CSS CZZ) (Emb (CS' CZZ :$ S0)) (K
                     (Emb (CS' CZZ :$ S0))
                  )))
                ))

polyIdFun = Lam (K idFun)
