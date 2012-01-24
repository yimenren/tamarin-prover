{-# LANGUAGE ViewPatterns, DeriveDataTypeable, TupleSections, TypeOperators, TemplateHaskell, TypeSynonymInstances, FlexibleInstances, FlexibleContexts, GeneralizedNewtypeDeriving #-}
-- |
-- Copyright   : (c) 2010, 2011 Benedikt Schmidt & Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- Proof states and their transformations; i.e., logical deduction.
module Theory.Proof.Sequent (
  -- * Sequent construction
    sequentFromFormula

  -- * Prove methods

  -- ** SeProof monad
  , SeProof
  , execSeProof
  , runSeProof
  , getMaudeHandle

  -- ** Goals
  , openGoals
  , solveGoal

  -- ** Equalitiy solving
  , SplitStrategy(..)
  , solveSubstEqs

  -- ** Conjunction with other sequents
  , conjoinSequent

  -- ** Simplification
  , simplifySequent

  -- * Contradiction
  , proveCyclic
  , hasNonNormalTerms
  , hasForbiddenExp
  , formulasFalse
  , nonUniqueFactInstances
  , contradictorySequent

  -- * Convenience export of used modules
  , module Theory.Proof.Types
  , module Theory.Proof.EquationStore
  ) where

import           Debug.Trace

import           Prelude hiding ( (.), id )

import           Data.List
import           Data.Either
import qualified Data.DAG.Simple  as D (cyclic, reachableSet)
import qualified Data.Set         as S
import qualified Data.Map         as M
import           Data.Monoid (Monoid, mappend )

import           Control.Basics
import           Control.Category
import           Control.Monad.Disj
import           Control.Monad.Reader
import           Control.Monad.Bind
import           Control.Monad.State (StateT, runStateT, execStateT, gets, put)

import           Text.Isar

import           Extension.Prelude
import           Extension.Data.Label

import           Logic.Connectives

import           Theory.Rule
import           Theory.Proof.SolveGuarded
import           Theory.Proof.Types
import           Theory.Proof.EquationStore

------------------------------------------------------------------------------
-- Sequents
------------------------------------------------------------------------------

-- Construction
---------------

-- | Returns the sequent that has to be proven to show that
--   given formula holds in the context of the given theory.
sequentFromFormula :: CaseDistKind -> LNFormula -> Sequent
sequentFromFormula kind f = 
    set sFormulas (S.singleton gf) (emptySequent kind)
  where 
    gf = either error id (fromFormulaNegate f)


------------------------------------------------------------------------------
-- Graph reasoning
------------------------------------------------------------------------------

-- | True iff there are terms in the sequent that are not in normal form wrt.
-- to 'Term.Rewriting.Norm.norm' (DH/AC).
--
-- FIXME: Might also want to check clauses, equation store, and other
-- components of sequent.
hasNonNormalTerms :: SignatureWithMaude -> Sequent -> Bool
hasNonNormalTerms sig se =
    any (not . (`runReader` (sigmMaudeHandle sig)) . nfRule) . M.elems . get sNodes $ se

-- | True if there is no @EXP-down@ rule that should be replaced by an
-- @EXP-up@ rule.
hasForbiddenExp :: Sequent -> Bool
hasForbiddenExp se =
    any (isForbiddenExp) $ M.elems $ get sNodes se

-- | @isForbiddenExp ru@ returns @True@ if @ru@ is not allowed in
-- a normal dependency graph.
-- > isForbiddenExp (Rule () [undefined, Fact KUFact [undefined, Mult (Inv x1) x2]]
--                           [Fact KDFact [expTagToTerm IsExp, Exp p1 (Mult x2 x3)]] [])
-- > False
-- > isForbiddenExp (Rule () [undefined, Fact KUFact [undefined, Mult (Inv x1) x2]]
--                           [Fact KDFact [expTagToTerm IsExp, Exp p1 x2]] [])
-- > True
isForbiddenExp :: Rule a -> Bool
isForbiddenExp ru = maybe False id $ do
    [_,p2] <- return $ get rPrems ru
    [conc] <- return $ get rConcs ru
    (UpK, _,          b)       <- kFactView p2
    (DnK, Just IsExp, FApp (NonAC ("exp",2)) [g,c]) <- kFactView conc

    -- g should be public and the required inputs for c already required by b
    guard (sortOfTerm g == LSortPub && (input c \\ input b == []))
    return True
  where
    sortOfTerm (Lit (Var lv)) = lvarSort lv
    sortOfTerm (Lit (Con n))  = sortOfName n
    sortOfTerm _              = LSortMsg

{-
-- | True iff the sequent has a last node followed by a node with an action.
hasNonLastNode :: Sequent -> Bool
hasNonLastNode se =
    any violation $ S.toList $ D.reachableSet lastNodes  (sRawLessRel se)
  where
    lastNodes   = sLastAtoms se
    violation i = 
        (not $ i `elem` lastNodes) &&
        maybe False (not . null . get rActs) (M.lookup i $ get sNodes se)
-}

-- | Compute all contradictions to unique fact instances.
--
-- Constraint systems are contradictory, where 'f' is a fact symbol
-- with unique instances and temporal variables i, j, and k are ordered
-- according to i < j < k, j requires a premise f(t), and i provides a
-- conclusion f(t) for the node k. Graphically, the edge from i to k is
-- interrupted by the node j that requires the same fact carried on the edge.
nonUniqueFactInstances :: SignatureWithMaude -> Sequent 
                       -> [(NodeId, NodeId, NodeId)]
nonUniqueFactInstances sig se = do
    Edge c@(NodeConc (i, _)) (NodePrem (k, _)) <- S.toList $ get sEdges se
    let tag = factTag (nodeConcFact c se)
    guard (tag `S.member` sigmUniqueInsts sig)
    j <- S.toList $ D.reachableSet [i] less

    let isCounterExample = (j /= i) && (j /= k) && 
                           maybe False checkRule (M.lookup j $ get sNodes se)

        checkRule jRu    = any ((tag ==) . factTag) (get rPrems jRu) &&
                           k `S.member` D.reachableSet [j] less
                 
    guard isCounterExample
    return (i, j, k) -- counter-example to unique fact instances
  where
    less = sRawLessRel se



-- Under-approximating minimal deducability
-------------------------------------------

-- | @proveCyclic se@ under-approximates @|se| ==> Ex v. v >+> v@.
proveCyclic :: Sequent -> Bool
proveCyclic = D.cyclic . sRawLessRel

-- | @formulasFalse se@ returns @True@ if False is included in the formulas of @se@
formulasFalse :: Sequent -> Bool
formulasFalse = S.member gfalse . get sFormulas

-- | @contradictorySequent se@ holds if the sequent is trivially contradictory.
--   FIXME: duplication with contradictions in Proof
contradictorySequent :: SignatureWithMaude -> Sequent -> Bool
contradictorySequent sig se =
    formulasFalse se                              ||
    eqsIsFalse (get sEqStore se)                  ||
    proveCyclic se                                ||
    hasNonNormalTerms sig se                      ||
    -- hasNonLastNode se                             ||
    hasForbiddenExp se                            ||
    not (null (nonUniqueFactInstances sig se))


-- SeProof monad
----------------

-- | A proof with respect to a sequent. The fresh variables are existential
-- variables of the sequent and the multiple results are to be interpreted as a
-- disjunction while the inner-most maybe indicates if the proof method is
-- applicable/was successful or not.
type SeProof = StateT Sequent (FreshT (DisjT (Reader ProofContext)))

runSeProof :: SeProof a -> ProofContext -> Sequent -> FreshState 
           -> Disj ((a, Sequent), FreshState)
runSeProof m ctxt se fs = 
    Disj $ (`runReader` ctxt) $ runDisjT $ (`runFreshT` fs) $ runStateT m se

execSeProof :: SeProof a -> ProofContext -> Sequent -> FreshState 
            -> [(Sequent, FreshState)]
execSeProof m ctxt se fs = 
    (`runReader` ctxt) . runDisjT . (`runFreshT` fs) $ execStateT m se

-- | Retrieve the 'MaudeHandle' from the 'ProofContext'.
getMaudeHandle :: SeProof MaudeHandle
getMaudeHandle = sigmMaudeHandle <$> askM pcSignature

-- | Import a rule with fresh variables.
importRule :: MonadFresh m
           => RuleAC
           -> m (RuleACInst, Maybe RuleACConstrs)
importRule ru = someRuleACInst ru `evalBindT` noBindings

-- | @proveLinearConc se (v,i)@ tries to prove that the @i@-th conclusion of node
-- @v@ is a linear fact.
proveLinearConc :: Sequent -> NodeConc -> Bool
proveLinearConc se (NodeConc (v,i)) =
    maybe False (isLinearFact . (get (rConc i))) $ M.lookup v $ get sNodes se

-- | Create a node labelled with a fresh instance of one of the rules and solve
-- it's fresh conditions immediatly.
--
-- PRE: Node must not yet be labelled with a rule.
ruleNode :: NodeId -> [RuleAC] -> SeProof RuleACInst
ruleNode i rules = do
    (ru, mrconstrs) <- importRule =<< disjunctionOfList rules
    solveRuleConstraints mrconstrs i
    modM sNodes (M.insert i ru)
    let freshs = do
          (v, Fact FreshFact [m]) <- zip [0..] $ get rPrems ru
          return $ do
            j <- freshLVar "vf" LSortNode
            modM sNodes (M.insert j (mkFreshRuleAC m))
            modM sEdges (S.insert $ Edge (NodeConc (j,0)) (NodePrem (i,v)))
    let knows = do
          (v, Fact KnowsFact [m]) <- zip [0..] $ get rPrems ru
          return $ do
            j <- freshLVar "vf" LSortNode
            ruKnows <- mkKnowsRuleAC m
            modM sNodes (M.insert j ruKnows)
            modM sEdges (S.insert $ Edge (NodeConc (j,0)) (NodePrem (i,v)))
    -- solve all Fresh premises
    sequence_ freshs
    sequence_ knows
    return ru
  where
    mkKnowsRuleAC m = do
        faPrem <- kuFact Nothing m
        return $ Rule (ProtoInfo KnowsRule) [faPrem] [knowsFact m] []

    mkFreshRuleAC m = Rule (ProtoInfo FreshRule) [] [freshFact m] []

-- | Create a fresh node labelled with a fresh instance of one of the rules
-- and solve it's fresh conditions immediatly.
freshRuleNode :: [RuleAC] -> SeProof (NodeId, RuleACInst)
freshRuleNode rules = do
    i <- freshLVar "vr" LSortNode
    (,) i <$> ruleNode i rules

-- | Generate a fresh coerce rule node; return node-index, premise, and
-- conclusion.
freshCoerceRuleNode :: SeProof (LVar, (LNFact, LNFact))
freshCoerceRuleNode = do
    i <- freshLVar "vc" LSortNode
    x <- varTerm <$> freshLVar "x" LSortMsg
    v <- freshLVar "f_" LSortMsg
    let faPrem = Fact KDFact [varTerm v, x]
        faConc = Fact KUFact [varTerm v, x]
    modM sNodes (M.insert i (Rule (IntrInfo CoerceRule) [faPrem] [faConc] []))
    return (i, (faPrem, faConc))

-- | Create a fresh node labelled with a fresh instance of one of the rules
-- and return one of the conclusions.
freshRuleConc :: [RuleAC]
              -> SeProof (RuleACInst, NodeConc, LNFact)
freshRuleConc rules = do
    (i, ru) <- freshRuleNode rules
    (v, fa) <- disjunctionOfList $ zip [0..] $ get rConcs ru
    return (ru, NodeConc (i,v), fa)

-- | Insert the edges and ensure the equality between the facts
-- at either end of the edge.
insertEdges :: [(NodeConc, LNFact, LNFact, NodePrem)] -> SeProof ()
insertEdges edges = do
    solveFactEqs SplitNow [ Equal fa1 fa2 | (_, fa1, fa2, _) <- edges ]
    modM sEdges (\es -> foldr S.insert es [ Edge c p | (c,_,_,p) <- edges])


-- Simplification
-----------------

-- | Repeatedly apply the following simplifications to the sequent:
--
--   - remove sequents that violate the sort constraints
--   - merge nodes marked as the last node
--   - merge nodes with equal instances of Fresh rules
--   - merge multiple rule labels of the same node
--   - merge nodes with equal non-pair message conclusions
--   - merge targets of multiple edges from a linear fact and
--     sources of multiple incoming edges to the same fact.
--   - solve Pub and Fresh goals
--   - solve unique action atoms
--
-- The simplification stops when the sequent doesn't change anymore.
--
simplifySequent :: SeProof ()
simplifySequent = do
    -- start simplification, indicating that some change happened
    go (0 :: Int) [True]
    -- ensure that the substitution is applied to the whole sequent
    substSequent
    exploitUniqueMsgOrder
  where
    go n changes0
      | not (or changes0) = return ()
      | otherwise        = do
          -- perform one simplification pass
          substSequent
          c1 <- exploitFreshUnique
          when c1 (substNodes >> return ())
          c2 <- exploitUniqueMsgConcs
          when c2 (substNodes >> return ())
          c3 <- exploitLastNode
          when c3 (substNodes >> return ())
          -- There may have been some change: propagate to edges
          c4 <- solveSimpleUpK
          substPart sEdges
          c5 <- exploitEdgeProps
          substPart sAtoms
          c6 <- solveUniqueActions 
          substPart sFormulas
          substPart sSolvedFormulas
          c7 <- simplifyNegativeOrderings
          c8 <- saturateFormulas

          -- report on looping behaviour if necessary
          se <- gets id
          let changes = [c1, c2, c3, c4, c5, c6, c7, c8]
              traceLoop
                | n <= 10   = id
                | otherwise = 
                      trace ("   simplify: " ++ show n ++ " " ++ show changes)
                    . trace (render $ prettySequent se)

          -- Repeat simplification, if there was some change in this step.
          traceLoop $ go (n + 1) changes


-- | Saturate the formulas. Return True, if the sequent was changed.
saturateFormulas :: SeProof Bool
saturateFormulas = do
    se     <- gets id
    hnd    <- getMaudeHandle
    result <- saturateGuarded hnd se
    case result of
      Nothing         -> do return False
      Just (eqs, se') -> do put se'
                            solveTermEqs SplitNow eqs
                            return True


-- | Solve premise goals that can be solved directly by exploiting special
-- properties of normalized derivation graphs.
--
--  Solve K-up premises can just be connected to already derived knowledge.
--
solveSimpleUpK :: SeProof Bool
solveSimpleUpK = do
    nodes <- M.toList <$> getM sNodes
    let (down, up) = partitionEithers $ do
            (i, ru)   <- nodes
            (v, fa)   <- zip [0..] $ get rConcs ru
            (d, _, m) <- maybe mzero return $ kFactView fa
            let tag = case d of UpK -> Right; DnK -> Left
            return $ tag (m, (d, fa, NodeConc (i, v)))
        -- retain the up-entry if there are duplicates
        derived = M.fromList $ down ++ up

    goals <- gets (map snd . openPremiseGoals)
    or <$> mapM (trySolve derived) goals
  where
    trySolve derived (PremUpKG p m) = case M.lookup m derived of
      Just (UpK, faConc, c) -> do
          se <- gets id
          let Just faPrem = resolveNodePremFact p se
          case kFactView faPrem of
            Just (UpK, _ , m') | m == m' ->
                -- this implies m' == inp m'
                insertEdges [(c, faPrem, faConc, p)]
            _                            ->
                modM sMsgEdges (S.insert (MsgEdge c p))
          return True

      Just (DnK, faConc, c) -> do
          se <- gets id
          let Just faPrem = resolveNodePremFact p se
          (j, (faPrem', faConc')) <- freshCoerceRuleNode
          insertEdges [ (c,              faConc , faPrem', NodePrem (j,0))
                      , (NodeConc (j,0), faConc', faPrem , p             ) ]
          return True

      Nothing               -> return False

    -- all other goals cannot be solved => the sequent doesn't change
    trySolve _ _ = return False


-- | Solve unique actions. Returns 'True' iff the sequent was changed.
solveUniqueActions :: SeProof Bool
solveUniqueActions = do
    rules       <- nonSilentRules <$> askM pcRules
    actionAtoms <- gets sActionAtoms

    let uniqueActions = [ x | [x] <- group (sort allActions) ]
        allActions    = [ (tag, length ts) 
                        | ru <- rules, Fact tag ts <- get rActs ru ]

        isUnique (Fact tag ts) = (tag, length ts) `elem` uniqueActions

        trySolve (i, fa)
          | isUnique fa = solveAction rules (i, fa) >> return True
          | otherwise   = return False

    or <$> mapM trySolve actionAtoms


-- | Exploit that up-premises must always be before the same down-premise.
exploitUniqueMsgOrder :: SeProof ()
exploitUniqueMsgOrder = do
    nodes     <- M.toList <$> getM sNodes
    dedBefore <- gets sDedBeforeAtoms
    let prems = M.fromList $ 
            dedBefore <|> -- also incorporate deducible-before atoms.
            do (i, ru) <- nodes
               fa      <- get rPrems ru
               case kFactView fa of
                 Just (UpK, _, m) -> [ (m', i) | m' <- input m ]
                 _                -> mzero

        concs = M.fromList $ do
            (i, ru) <- nodes
            fa      <- get rConcs ru
            case kFactView fa of
              Just (DnK, _, m) -> return (m, i)
              _                -> mzero

        mkLess i j = Less (varTerm i) (varTerm j)

    -- we can add all elements where we have an intersection
    modM sAtoms $ flip S.union $ S.fromList
                $ M.elems $ M.intersectionWith mkLess concs prems

-- | Exploit that fresh nodes produces unique conclusions.
exploitFreshUnique :: SeProof Bool -- ^ True, if a simplification step happened.
exploitFreshUnique = do
    -- gather fresh rule nodes and merge nodes with identical conclusions
    updates <- gets ( map merge
                    . groupSortOn (get (rConc 0) . snd)
                    . filter (isFreshRule . snd)
                    . M.toList
                    . get sNodes
                    )
    -- check if there are changes to be applied
    if all (null . snd) updates
      then do return False
      else do modM sNodes (foldr (.) id $ map fst updates)
              solveNodeIdEqs $ concatMap snd updates
              return True
  where
    -- merge duplicate ones by removing all but one node and adding the
    -- equalities between the kept nodes and the removed nodes
    merge []            = error "exploitFreshUnique: impossible"
    merge (keep:remove) =
      ( \nodes -> foldl' (flip M.delete) nodes (map fst remove)
      , map (Equal (fst keep) . fst) remove
      )

-- | Merge multiple incoming edges to all facts and multiple outgoing edges
-- from linear facts.
exploitEdgeProps :: SeProof Bool -- True, if a simplification step happened.
exploitEdgeProps = do
    se <- gets id
    let edges  = [ (getNodeConc src, getNodePrem prem)
                 | Edge src prem <- S.toList (get sEdges se) ]
        rawEqs = mergeEqs fst snd edges ++
                 mergeEqs snd fst (filter (proveLinearConc se . NodeConc . fst) edges)
    -- check if there are changes to be applied
    if all null rawEqs
      then do return False
      else do
        let eqs = concat rawEqs
        -- all indices of merged premises and conclusions must be equal
        contradictoryIf (not $ and [snd l == snd r | Equal l r <- eqs])
        -- nodes must be equal
        solveNodeIdEqs $ map (fmap fst) eqs
        return True
  where
    mergeEqs :: Ord c => (a -> b) -> (a -> c) -> [a] -> [[Equal b]]
    mergeEqs what on = map (merge what) . groupSortOn on

    merge :: (a -> b) -> [a] -> [Equal b]
    merge _    []            = error "exploitEdgeProps: impossible"
    merge proj (keep:remove) = map (Equal (proj keep) . proj) remove


-- | Merge nodes with equal non-pair msg conclusions.
exploitUniqueMsgConcs :: SeProof Bool
exploitUniqueMsgConcs = do
    nodes <- M.toList <$> getM sNodes
    let (coerce, nonCoerce) = partitionEithers $ do
          node@(_, ru) <- nodes
          fa      <- get rConcs ru
          case kFactView fa of
            Nothing                          -> mzero
            Just (_, _, m) | isCoerceRule ru -> return $ Left  (m, node)
                           | otherwise       -> return $ Right (m, node)

        (removals1, eqs1) = analyze coerce
        (removals2, eqs2) = analyze nonCoerce
        eqs               = eqs1 ++ eqs2

    -- check if there are any changes to be done
    if null eqs
        then return False
        else do
            modM sNodes (removals1 . removals2)
            solveNodeIdEqs          $ map (fmap fst) eqs
            solveRuleEqs   SplitNow $ map (fmap snd) eqs
            return True
  where
    analyze = (foldr (.) id *** concat) . unzip . map merge . groupSortOn fst

    merge []            = error "exploitUniqueMsgs: impossible"
    merge (keep:remove) =
      ( \nodes -> foldl' (flip M.delete) nodes (map (fst . snd) remove)
      , map (Equal (snd keep) . snd) remove
      )

-- | Apply a list of changes to the proof state. Return True, if at least one
-- change was applied; i.e., the list of changes is not null.
applyChanges :: [SeProof ()] -> SeProof Bool
applyChanges changes = sequence_ changes >> return (not $ null changes)

-- | Are these two rule instances unifiable.
unifiableRuleACInsts :: MaudeHandle -> RuleACInst -> RuleACInst -> Bool
unifiableRuleACInsts maude ru1 ru2 = 
    not $ null $ (`runReader` maude) $ unifyRuleACInstEqs [Equal ru1 ru2]

-- | Simplify implications of the form @ (i < j) ==> F @: They are left-alone,
-- if either @i@ or @j@ have not yet a node associated, converted to @j < i@,
-- if the nodes of @j@ and @i@ are non-unifiable, and converted to the
-- disjunction @i = j | j < i@, otherwise.
--
-- True is returned if some change was performed.
simplifyNegativeOrderings :: SeProof Bool
simplifyNegativeOrderings = do
    fms   <- getM sFormulas
    nodes <- getM sNodes
    maude <- getMaudeHandle
    applyChanges $ do
        fm@(GGuarded All [] [Less i0 j0] gf) <- S.toList fms
        guard (gf == gfalse)
        case  unifiableRuleACInsts maude <$> M.lookup (nodeFromTerm i0) nodes
                                         <*> M.lookup (nodeFromTerm j0) nodes
         of
          Just b  -> return $ do
            modM sFormulas       $ S.delete fm
            modM sSolvedFormulas $ S.insert fm
            if b
              then modM sFormulas $ S.insert $ 
                       gdisj $ [GAto (EqE i0 j0), GAto (Less j0 i0)]
              else modM sAtoms $ S.insert $ bvarToLVar $ Less j0 i0
          Nothing -> []
  where
    nodeFromTerm (Lit (Var (Free v))) | lvarSort v == LSortNode = v
    nodeFromTerm t                                              = error $
        "expected free node variable, but got '" ++ show t ++ "'"


-- | Exploit that no node with a label can be after the last node. For
-- non-unifiable, nodes the ordering is introduced directly. For the
-- remaining, ones a disjunction is introduced.
--
-- True is returned if some change was performed.
exploitLastNode :: SeProof Bool
exploitLastNode = do
    lasts <- gets sLastAtoms
    nodes <- getM sNodes
    case lasts of
      []      -> return False
      [iLast] -> -- single last node => add ordering constraints
         case M.lookup iLast nodes of
           Nothing     -> return False
           Just ruLast -> do
              beforeLast <- gets (D.reachableSet lasts . sRawGreaterRel)
              fms        <- getM sFormulas
              maude      <- getMaudeHandle
              applyChanges $ do
                  (i, ru) <- M.toList nodes
                  let disj = mkOrdDisj i iLast
                  guard $ (i /= iLast) &&
                           -- only consider nodes with action constraints
                          (not $ null $ get rActs ru)  && 
                          (i `S.notMember` beforeLast) &&
                          (disj `S.notMember` fms)
                  if unifiableRuleACInsts maude ru ruLast
                    then return $ modM sFormulas $ S.insert disj
                    else return $ modM sAtoms $ S.insert $ 
                             Less (varTerm i) (varTerm iLast)

      _ -> do -- multiple last nodes => merge them
              solveTermEqs SplitNow $ zipWith mkEq lasts (tail lasts)
              return True
  where
    mkEq i j        = Equal (varTerm i) (varTerm j)
    mkOrdDisj i0 j0 = gdisj $ [GAto (EqE i j), GAto (Less i j)]
      where
        i = Lit $ Var $ Free i0
        j = Lit $ Var $ Free j0

-- | @setNodes nodes@ normalizes the @nodes@ such that node ids are unique and
-- then updates the @sNodes@ field of the proof state to the corresponding map.
-- Return @True@ iff new equalities have been added to the equation store.
setNodes :: [(NodeId, RuleACInst)] -> SeProof Bool
setNodes nodes0 = do
    sNodes =: M.fromList nodes
    if null ruleEqs then                         return False
                    else solveRuleEqs SplitLater ruleEqs >> return True
  where
    -- merge nodes with equal node id
    (ruleEqs, nodes) = first concat $ unzip $ map merge $ groupSortOn fst nodes0

    merge []            = error "setNodes: impossible"
    merge (keep:remove) = (map (Equal (snd keep) . snd) remove, keep)

-- | Apply the current substitution of the equation store to the domain
-- of the '_sNodes' field and restore the one-rule-per-node property. Returns
-- @True@ if there were additional equalities added to the equation store.
substNodesDomain :: SeProof Bool
substNodesDomain =
    go False
  where
    go changed = do
        subst <- getM sSubst
        nodes <- gets (map (first (apply subst)) . M.toList . get sNodes)
        changed' <- setNodes nodes
        if changed' then go True
                    else return changed

-- | Apply the current substitution of the equation store to the '_sNodes'
-- field. Returns @True@ if there were additional equalities added to the
-- equation store.
substNodes :: SeProof Bool
substNodes = do
    changed <- substNodesDomain
    (modM sNodes . M.map . apply) =<< getM sSubst
    return changed

-- | Apply the current substitution of the equation store to the whole sequent.
substSequent :: SeProof ()
substSequent = do
    _ <- substNodes
    substPart sEdges
    substPart sMsgEdges
    substPart sChains
    hnd <- getMaudeHandle
    -- FIXME: Check if this is necessary, Eqstore might be already up-to-date
    modM sEqStore =<< (applyEqStore hnd <$> getM sSubst)
    substPart sAtoms
    substPart sFormulas
    substPart sSolvedFormulas
    substPart sLemmas

-- | Apply the current substitution of the equation store to a part of the
-- sequent.
substPart :: Apply a => (Sequent :-> a) -> SeProof ()
substPart l = modM l =<< (apply <$> getM sSubst)

-- | @conjoinSequent se@ conjoins the logical information in @se@ to the proof
-- state. It assumes that the free variables in @se@ are shared with the free
-- variables in the proof state.
conjoinSequent :: Sequent -> SeProof ()
conjoinSequent se = do
    kind <- getM sCaseDistKind 
    unless (kind == get sCaseDistKind se) $
        error "conjoinSequent: typing-kind mismatch"
    joinSets sEdges
    joinSets sMsgEdges
    joinSets sChains
    joinSets sAtoms
    joinSets sFormulas
    joinSets sSolvedFormulas
    joinSets sLemmas
    -- update nodes
    _ <- (setNodes . (M.toList (get sNodes se) ++) . M.toList) =<< getM sNodes
    -- conjoin equation store
    modM sConjDisjEqs (`mappend` get sConjDisjEqs se)
    solveSubstEqs SplitNow $ get sSubst se
    -- propagate substitution changes
    substSequent
  where
    joinSets :: Ord a => (Sequent :-> S.Set a) -> SeProof ()
    joinSets proj = modM proj (`S.union` get proj se)


-- Unification through the equation store of the embedded sequent
-----------------------------------------------------------------

-- | @noContradictoryEqStore@ suceeds iff the equation store is not
-- contradictory.
noContradictoryEqStore :: SeProof ()
noContradictoryEqStore =
    (contradictoryIf . eqsIsFalse) =<< getM sEqStore

-- | Add a list of term equalities to the equation store. And
--  split resulting disjunction of equations according
--  to given split strategy.
solveTermEqs :: SplitStrategy -> [Equal LNTerm] -> SeProof ()
solveTermEqs splitStrat eqs = do
    hnd <- getMaudeHandle
    setM sEqStore =<< simp hnd
                  =<< disjunctionOfList
                  =<< addEqs splitStrat hnd eqs
                  =<< getM sEqStore
    noContradictoryEqStore

-- | Add a list of equalities in substitution form to the equation store
solveSubstEqs :: SplitStrategy -> LNSubst -> SeProof ()
solveSubstEqs split subst =
    solveTermEqs split [Equal (varTerm v) t | (v, t) <- substToList subst]

-- | Add a list of node equalities to the equation store.
solveNodeIdEqs :: [Equal NodeId] -> SeProof ()
solveNodeIdEqs = solveTermEqs SplitNow . map (fmap varTerm)

-- | Add a list of fact equalities to the equation store, if possible.
solveFactEqs :: SplitStrategy -> [Equal LNFact] -> SeProof ()
solveFactEqs split eqs = do
    contradictoryIf (not $ all evalEqual $ map (fmap factTag) eqs)
    solveListEqs (solveTermEqs split) $ map (fmap factTerms) eqs

-- | Add a list of rule equalities to the equation store, if possible.
solveRuleEqs :: SplitStrategy -> [Equal RuleACInst] -> SeProof ()
solveRuleEqs split eqs = do
    contradictoryIf (not $ all evalEqual $ map (fmap (get rInfo)) eqs)
    solveListEqs (solveFactEqs split) $
        map (fmap (get rConcs)) eqs ++ map (fmap (get rPrems)) eqs

-- | Solve a list of equalities using the given solver.
solveListEqs :: ([Equal a] -> SeProof b) -> [(Equal [a])] -> SeProof b
solveListEqs solver eqs = do
    contradictoryIf (not $ all evalEqual $ map (fmap length) eqs)
    solver $ concatMap flatten eqs
  where
    flatten (Equal l r) = zipWith Equal l r


-- | Solve the constraints associated with a rule with the given vertex.
solveRuleConstraints :: Maybe RuleACConstrs -> NodeId -> SeProof ()
solveRuleConstraints (Just eqConstr) _v = do
    hnd <- getMaudeHandle
    setM sEqStore
        =<< (simp hnd . addRuleVariants eqConstr)
        =<< getM sEqStore
    noContradictoryEqStore
solveRuleConstraints Nothing _ = return ()

------------------------------------------------------------------------------
-- Extracting and solving goals
------------------------------------------------------------------------------

data Usefulness = Useful | Useless
  deriving (Show, Eq)

-- | All open premises stemming both from labelled nodes and requires facts.
openPremiseGoals :: Sequent -> [(Usefulness, Goal)]
openPremiseGoals se = do
    (i, ru) <- oneOfMap $ get sNodes se
    (u, fa) <- zip [0..] $ get rPrems ru
    let p = NodePrem (i, u)
    case fa of
      -- up-K facts
      (kFactView -> Just (UpK, _, m))  -> case input m of
          [m'] | m == m' -> do
            guard (not (trivial m') && (p, m') `S.notMember` coveredMsgPrems)
            return $ markUseless m' i $ PremiseG p fa
          m's            -> do
            m' <- sortednub m's
            guard (not (trivial m') && (p, m') `S.notMember` coveredMsgPrems)
            return $ markUseless m' i $ PremUpKG p m'

      -- down-K facts
      (kFactView -> Just (DnK, _, _))
        | p `S.member` coveredPrems -> mzero
        | otherwise                 -> return . (Useful,)  $ PremDnKG p
      -- all other facts
      _ | p `S.member` coveredPrems -> mzero
        | otherwise                 -> return . (Useful,) $ PremiseG p fa
  where

    coveredPrems     = S.fromList $ eTgt <$> S.toList (get sEdges se) <|>
                                    cTgt <$> S.toList (get sChains se)

    coveredMsgPrems  = S.fromList $ do
        (c, p) <- [ (c, p) | MsgEdge c p <- S.toList (get sMsgEdges se) ] <|>
                  [ (c, p) | Edge c p    <- S.toList (get sEdges se)    ]

        case kFactView =<< resolveNodeConcFact c se of
          Just (UpK, _, m) -> return (p, m)
          _                -> []

    markUseless _m _i = (Useful,)
    {- FIXME: This heuristic is helpful in POST case studies. However, it
     -        hampers experimentation. We should make it conditional.
     -
    markUseless m i
        | containsFreshVars m && not (deducibleNoContr m i) = (Useful,)
        | otherwise                                         = (Useless,)

    containsFreshVars = any ((==LSortFresh) . lvarSort) . frees

    -- | deducible without immediate contradiction
    deducibleNoContr m i = not (null newDeps || any (\d -> D.cyclic (d:otherDeps)) newDeps)
      where newDeps = do
                (j,ru) <- M.toList $ get sNodes se
                let msgConcs = [ m' | Fact SendFact [m'] <- get rConcs ru] <|>
                               [ m' | Just (DnK,_,m') <- kFactView <$> get rConcs ru]
                guard (m `elem` msgConcs)
                return (j,i)
            otherDeps = sRawLessRel se
    -}

-- | All open chain goals. These are all the chains that do not end in a
-- message variable in the sequent because they are deleted upon solving.
openChainGoals :: Sequent -> [Goal]
openChainGoals se = do
    ch@(Chain c _) <- S.toList $ get sChains se
    case kFactView (nodeConcFact c se) of
      Just (DnK, _, m) | isMsgVar m -> mzero
                       | otherwise  -> return $ ChainG ch
      fa -> error $ "openChainGoals: impossible fact: " ++ show fa

-- | All open splitting goals.
openSplitGoals :: Sequent -> [Goal]
openSplitGoals se = SplitG <$> eqSplits (get sEqStore se)

-- | All open action goals.
openActionGoals :: Sequent -> [Goal]
openActionGoals se = uncurry ActionG <$> sActionAtoms se

-- | All open goals (non-deterministic choices of possible proof steps) in the
-- sequent.
openGoals :: Sequent -> [Goal]
openGoals se = delayUseless $ concat $
   [ (Useful,) <$> openActionGoals se
   , (Useful,) <$> openDisjunctionGoals se
   , (Useful,) <$> openChainGoals se
   , preferProtoFactGoals $ openPremiseGoals se
   -- FIXME: Commented out as automatic saturation works again.
   -- , (Useful,) <$> openImplicationGoals se
   , (Useful,) <$> openSplitGoals se
   ]
  where
    isProtoFactGoal (_, PremiseG _ _) = True
    isProtoFactGoal _                 = False
    preferProtoFactGoals goals =
        uncurry (++) $ partition isProtoFactGoal goals

    delayUseless :: [(Usefulness, Goal)] -> [Goal]
    delayUseless goals | null useful = map snd goals
                       | otherwise   = map snd useful

      where useful = filter ((==Useful) . fst) goals

-- | Solve an action goal.
solveAction :: [RuleAC]       -- ^ All rules labelled with an action
            -> (LVar, LNFact) -- ^ The action we are looking for.
            -> SeProof String -- ^ Sensible case name.
solveAction rules (i, fa) = do
    modM sAtoms (S.delete (Action (varTerm i) fa))
    mayRu <- M.lookup i <$> getM sNodes
    showRuleCaseName <$> case mayRu of
        Nothing -> do ru <- ruleNode i rules
                      a  <- disjunctionOfList $ get rActs ru
                      solveFactEqs SplitNow [Equal fa a]
                      return ru
        Just ru -> do unless (fa `elem` get rActs ru) $ do
                        a <- disjunctionOfList $ get rActs ru
                        solveFactEqs SplitNow [Equal fa a]
                      return ru

-- | Solve a K-up-knowledge premise.
solvePremUpK :: [RuleAC]  -- ^ All construction rules.
             -> NodePrem
             -> LNTerm
             -> SeProof String
solvePremUpK rules p m = do
    (ru, c, faConc) <- freshRuleConc rules
    case kFactView faConc of
      Just (UpK, _, m') ->
        do solveTermEqs SplitNow [(Equal m m')]
           modM sMsgEdges (S.insert (MsgEdge c p))
           return $ showRuleCaseName ru

      _ -> error $ "solvePremUpK: unexpected fact: " ++ show faConc

-- | Solve a non-knowledge premise.
solvePremise :: [RuleAC]       -- ^ All rules that don't derive a knowledge fact.
             -> NodePrem       -- ^ Premise to solve.
             -> LNFact         -- ^ Fact required at this premise.
             -> SeProof String -- ^ Case name to use
solvePremise rules p faPrem = do
    (ru, c, faConc) <- freshRuleConc rules
    solveFactEqs SplitNow [(Equal faPrem faConc)]
    modM sEdges (S.insert (Edge c p))
    return $ showRuleCaseName ru

-- | Solve a K-down-knowledge premise.
solvePremDnK :: [RuleAC] -- ^ All rules that derive a send fact.
             -> NodePrem -- ^ The K-down premise to solve.
             -> SeProof String
solvePremDnK rules p = do
    iLearn    <- freshLVar "vl" LSortNode
    mLearn    <- varTerm <$> freshLVar "t" LSortMsg
    concLearn <- kdFact (Just IsNoExp) mLearn
    let premLearn = sendFact mLearn
        ruLearn = Rule (ProtoInfo LearnRule) [premLearn] [concLearn] []
        cLearn = NodeConc (iLearn, 0)
        pLearn = NodePrem (iLearn, 0)
    modM sNodes  (M.insert iLearn ruLearn)
    modM sChains (S.insert (Chain cLearn p))
    solvePremise rules pLearn premLearn



-- | Solve a chain constraint.
solveChain :: [RuleAC]        -- ^ All destruction rules.
           -> Chain           -- ^ The chain to extend by one step
           -> SeProof String
solveChain rules ch@(Chain c p) = do
    modM sChains (S.delete ch)
    faConc  <- gets $ nodeConcFact c
    (do -- solve it by a direct edge
        faPrem <- gets $ nodePremFact p
        solveFactEqs SplitNow [(Equal faPrem faConc)]
        modM sEdges  (S.insert (Edge c p))
        let m = case kFactView faConc of
                  Just (DnK, _, m') -> m'
                  _                 -> error $ "solveChain: impossible"
            caseName (FApp o _) = show o
            caseName t          = show t
        return $ caseName m 
     `disjunction`
     do -- extend it with one step
        (i, ru)     <- freshRuleNode rules
        (v, faPrem) <- disjunctionOfList $ zip [0..] $ get rPrems ru
        solveFactEqs SplitNow [(Equal faPrem faConc)]
        modM sEdges (S.insert (Edge c (NodePrem (i,v))))
        modM sChains (S.insert (Chain (NodeConc (i,0)) p))
        return $ showRuleCaseName ru
     )

-- | Solve an equation or typing split.
solveSplit :: SplitId -> SeProof String
solveSplit x = do
    split <- gets ((`splitAtPos` x) . get sEqStore)
    let errMsg = error "solveSplit: split of equations on unconstrained variable!"
    store  <- maybe errMsg disjunctionOfList split
    hnd    <- getMaudeHandle
    store' <- simp hnd store
    contradictoryIf (eqsIsFalse store')
    sEqStore =: store'
    return "split"

-- | Solve a disjunction of guarded formulas using splitting.
-- Returns a case name.
solveDisjunction :: Disj LNGuarded -> SeProof String
solveDisjunction disj = do
    modM sSolvedFormulas (S.insert $ GDisj disj)
    modM sSolvedFormulas (S.insert $ GDisj disj)
    (i, gfm) <- disjunctionOfList $ zip [(1::Int)..] $ getDisj disj
    modM sFormulas (S.insert gfm)
    return $ "case_" ++ show i


-- | @solveGoal rules goal@ enumerates all possible solutions how this goal
-- could be solved in the context of the given @rules@.
--
-- Returns a usable case name.
--
solveGoal :: Goal -> SeProof String
solveGoal goal = do
    rules <- askM pcRules
    trace ("   solving goal: " ++ render (prettyGoal goal)) $
      case goal of
        ActionG i fa   -> solveAction  (nonSilentRules rules) (i, fa) 
        PremiseG p fa  -> 
            solvePremise (get crProtocol  rules ++ get crConstruct rules) p fa
        PremDnKG p     -> solvePremDnK (get crProtocol  rules) p
        PremUpKG p m   -> solvePremUpK (get crConstruct rules) p m
        ChainG ch      -> solveChain   (get crDestruct  rules) ch
        SplitG i       -> solveSplit i
        DisjG disj     -> solveDisjunction disj
        ImplG gf       -> modM sFormulas (S.insert gf) >> return "add_formula"
