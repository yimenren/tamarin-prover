{-# LANGUAGE FlexibleInstances #-}
-- |
-- Copyright   : (c) 2010, 2011 Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
-- 
-- Maintainer  : Benedikt Schmidt <beschmi@gmail.com>
--
-- One-step narrowing from a term.
module Term.Narrowing.Narrow (
    narrowSubsts
  ) where

import Term.Unification
import Term.Positions

import Control.Monad.Reader

import Extension.Prelude

import Debug.Trace

-- trace :: a -> b -> b
-- trace _ e = e

-- Narrowing
----------------------------------------------------------------------

-- | @narrowSubsts rules t@ returns all substitutions @s@ such that there is a
--   narrowing step for the term @t@ and the given rules.
--   Formally: If there is a step @(t,s(t[r]p),p,s,l->r)@ such that @p@ is a
--   non-variable position of @t@ and @s@ is an element of the complete set of
--   unifiers of @t|_p@ with @l@ (wrt. to 'unifyLNTerm') for the rule @l -> r@,
--   then @s@ is included in the list of returned substitutions.
narrowSubsts :: LNTerm -> WithMaude [LNSubstVFresh]
narrowSubsts t = reader $ \hnd -> sortednub $ do
    let rules0 = rrulesForMaudeSig $ mhMaudeSig hnd
    (l `RRule` _r) <- renameAvoiding rules0 t
    p <- positionsNonVar t
    subst <- unifyLNTerm [Equal (t >* p) l] `runReader` hnd
    guard (trace ("narrowSubsts"++ (show ((t >* p), l, restrictVFresh (frees t) subst))) True)
    return $ restrictVFresh (frees t) subst