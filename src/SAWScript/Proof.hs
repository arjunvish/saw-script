{- |
Module      : SAWScript.Proof
Description : Representations of SAW-Script proof states.
License     : BSD3
Maintainer  : huffman
Stability   : provisional
-}
module SAWScript.Proof where

import Verifier.SAW.Recognizer
import Verifier.SAW.SharedTerm
import SAWScript.Prover.SolverStats

-- | A theorem must contain a boolean term, possibly surrounded by one
-- or more lambdas which are interpreted as universal quantifiers.
data Theorem = Theorem { thmTerm :: Term }

data Quantification = Existential | Universal
  deriving Eq

-- | A ProofGoal is a term of type @sort n@, or a pi type of any arity
-- with a @sort n@ result type. The abstracted arguments are treated
-- as either universally quantified. If the 'goalQuant' field is set
-- to 'Existential', then the entire goal is considered to be
-- logically negated, so it is as if the quantifiers are existential.
data ProofGoal =
  ProofGoal
  { goalQuant :: Quantification
  , goalNum  :: Int
  , goalType :: String
  , goalName :: String
  , goalTerm :: Term
  }

-- | Construct a 'ProofGoal' from a term of type @Bool@, or a function
-- of any arity with a boolean result type. Any function arguments are
-- treated as quantified variables.
makeProofGoal ::
  SharedContext ->
  Quantification ->
  Int    {- goal number    -} ->
  String {- goal type      -} ->
  String {- goal name      -} ->
  Term   {- goal predicate -} ->
  IO ProofGoal
makeProofGoal sc quant gnum gtype gname t =
  do t' <- predicateToProp sc quant [] t
     return (ProofGoal quant gnum gtype gname t')

-- | Convert a term with a function type of any arity into a pi type.
-- Negate the term if the result type is @Bool@ and the quantification
-- is 'Existential'.
predicateToProp :: SharedContext -> Quantification -> [Term] -> Term -> IO Term
predicateToProp sc quant env t =
  case asLambda t of
    Just (x, ty, body) ->
      do body' <- predicateToProp sc quant (ty : env) body
         scPi sc x ty body'
    Nothing ->
      do (argTs, resT) <- asPiList <$> scTypeOf' sc env t
         let toPi [] t0 =
               case asBoolType resT of
                 Nothing -> return t0 -- TODO: check quantification
                 Just () ->
                   case quant of
                     Universal -> scEqTrue sc t0
                     Existential -> scEqTrue sc =<< scNot sc t0
             toPi ((x, xT) : tys) t0 =
               do t1 <- incVars sc 0 1 t0
                  t2 <- scApply sc t1 =<< scLocalVar sc 0
                  t3 <- toPi tys t2
                  scPi sc x xT t3
         toPi argTs t

-- | Turn a pi type with an @EqTrue@ result into a lambda term with a
-- boolean result type. This function exists to interface the new
-- pi-type proof goals with older proof tactic implementations that
-- expect the old lambda-term representation.
propToPredicate :: SharedContext -> Term -> IO Term
propToPredicate sc goal =
  do let (args, t1) = asPiList goal
     t2 <- asEqTrue t1
     scLambdaList sc args t2

-- | A ProofState represents a sequent, where the collection of goals
-- implies the conclusion.
data ProofState =
  ProofState
  { psGoals :: [ProofGoal]
  , psConcl :: ProofGoal
  , psStats :: SolverStats
  , psTimeout :: Maybe Integer
  }

startProof :: ProofGoal -> ProofState
startProof g = ProofState [g] g mempty Nothing

finishProof :: ProofState -> (SolverStats, Maybe Theorem)
finishProof (ProofState gs concl stats _) =
  case gs of
    []    -> (stats, Just (Theorem (goalTerm concl)))
    _ : _ -> (stats, Nothing)