{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
module Verifier.SAW.Heapster.IDESupport where

import Control.Monad.Reader
import Control.Monad.Writer
import Data.Aeson ( encodeFile, ToJSON )
import Data.Binding.Hobbits
import Data.Maybe
import Data.Parameterized.Some (Some (..))
import qualified Data.Text as T
import qualified Data.Type.RList as RL
import GHC.Generics ( Generic )
import Lang.Crucible.Types
import What4.FunctionName ( FunctionName(functionName) )
import What4.ProgramLoc
    ( Position(InternalPos, SourcePos, BinaryPos, OtherPos),
      ProgramLoc(..) )

import Verifier.SAW.Heapster.CruUtil
import Verifier.SAW.Heapster.Implication
import Verifier.SAW.Heapster.Permissions
import Verifier.SAW.Heapster.TypedCrucible
import Verifier.SAW.Heapster.JSONExport(ppToJson)
import Data.Aeson (Value)

import Debug.Trace


-- | The entry point for dumping a Heapster environment to a file for IDE
-- consumption.
printIDEInfo :: PermEnv -> [Some SomeTypedCFG] -> FilePath -> PPInfo -> IO ()
printIDEInfo _penv tcfgs file ppinfo =
  encodeFile file $ IDELog (runWithLoc ppinfo tcfgs)


type ExtractionM = ReaderT (PPInfo, ProgramLoc) (Writer [LogEntry])

emit :: LogEntry -> ExtractionM ()
emit entry = tell [entry]

-- | A single entry in the IDE info dump log.  At a bare minimum, this must
-- include a location and corresponding permission.  Once the basics are
-- working, we can enrich the information we log.
data LogEntry
  = LogEntry
      { leLocation :: String
      , leExport :: Value
      , lePermissions :: String
      }
  | LogError
      { lerrLocation :: String
      , lerrError :: String
      }
  deriving (Generic, Show)
instance ToJSON LogEntry
instance NuMatching LogEntry where
  nuMatchingProof = unsafeMbTypeRepr
instance Liftable LogEntry where
  mbLift mb = case mbMatch mb of
    [nuMP| LogEntry x y z |] -> LogEntry (mbLift x) (mbLift y) (mbLift z)
    [nuMP| LogError x y |] -> LogError (mbLift x) (mbLift y)

-- | A complete IDE info dump log, which is just a sequence of entries.  Once
-- the basics are working, we can enrich the information we log.
newtype IDELog = IDELog {
  lmfEntries :: [LogEntry]
} deriving (Generic, Show)
instance ToJSON IDELog


class ExtractLogEntries a where
  extractLogEntries :: a -> ExtractionM ()

instance (PermCheckExtC ext)
    => ExtractLogEntries
         (TypedEntry TransPhase ext blocks tops ret args ghosts) where
  extractLogEntries te = do
    let loc = trace "typed entry loc" (mbLift $ fmap getFirstProgramLocTS (typedEntryBody te))
    withLoc loc (mbExtractLogEntries (typedEntryBody te))
    mbExtractLogEntries (typedEntryPermsIn te)

instance ExtractLogEntries (ValuePerms ctx) where
  extractLogEntries vps =
    do (ppi, loc) <- ask
       let loc' = snd (ppLoc loc)
       let strs = foldValuePerms (\xs vp -> (ppToJson ppi vp, permPrettyString ppi vp) : xs) [] vps
       tell [LogEntry loc' export str | (export, str) <- strs]

instance ExtractLogEntries (TypedStmtSeq ext blocks tops ret ps_in) where
  extractLogEntries (TypedImplStmt (AnnotPermImpl _str pimpl)) =
    -- fmap (setErrorMsg str) <$> extractLogEntries pimpl
    extractLogEntries pimpl
  extractLogEntries (TypedConsStmt loc _ _ rest) = do
    withLoc loc $ mbExtractLogEntries rest
  extractLogEntries (TypedTermStmt _ _) = pure ()

instance ExtractLogEntries
    (PermImpl (TypedStmtSeq ext blocks tops ret) ps_in) where
  extractLogEntries (PermImpl_Step pi1 mbpis) = do
    pi1Entries <- extractLogEntries pi1
    pisEntries <- extractLogEntries mbpis
    return $ pi1Entries <> pisEntries
  extractLogEntries (PermImpl_Done stmts) = extractLogEntries stmts

instance ExtractLogEntries (PermImpl1 ps_in ps_outs) where
  extractLogEntries (Impl1_Fail err) =
    -- The error message is available further up the stack, so we just leave it
    -- empty here
    do (_, loc) <- ask
       emit (LogError (snd (ppLoc loc)) (ppError err))
  extractLogEntries _ = pure ()

instance ExtractLogEntries
    (MbPermImpls (TypedStmtSeq ext blocks tops ret) ps_outs) where
  extractLogEntries (MbPermImpls_Cons _ mbpis pis) = do
    mbExtractLogEntries pis
    extractLogEntries mbpis
  extractLogEntries MbPermImpls_Nil = pure ()

instance (PermCheckExtC ext)
  => ExtractLogEntries (TypedCFG ext blocks ghosts inits ret) where
    extractLogEntries tcfg = extractLogEntries $ tpcfgBlockMap tcfg

instance (PermCheckExtC ext)
  => ExtractLogEntries (TypedBlockMap TransPhase ext blocks tops ret) where
  extractLogEntries tbm =
    sequence_ $ RL.mapToList extractLogEntries tbm

instance (PermCheckExtC ext)
  => ExtractLogEntries (TypedBlock TransPhase ext blocks tops ret args) where
    extractLogEntries tb =
      mapM_ (\(Some te) -> extractLogEntries te) $ _typedBlockEntries tb


mbExtractLogEntries
  :: ExtractLogEntries a => Mb (ctx :: RList CrucibleType) a -> ExtractionM ()
mbExtractLogEntries mb_a =
  ReaderT $ \(ppi, loc) ->
  tell $ mbLift $ flip nuMultiWithElim1 mb_a $ \ns x ->
  execWriter $ runReaderT (extractLogEntries x) (ppInfoAddExprNames "x" ns ppi, loc)

typedStmtOutCtx :: TypedStmt ext rets ps_in ps_next -> CruCtx rets
typedStmtOutCtx = error "FIXME: write typedStmtOutCtx"

withLoc :: ProgramLoc -> ExtractionM a -> ExtractionM a
withLoc loc = local (\(ppinfo, _) -> (ppinfo, loc))

setErrorMsg :: String -> LogEntry -> LogEntry
setErrorMsg msg le@LogError {} = le { lerrError = msg }
setErrorMsg msg le@LogEntry {} =
  LogError { lerrError = msg, lerrLocation = leLocation le}


runWithLoc :: PPInfo -> [Some SomeTypedCFG] -> [LogEntry]
runWithLoc ppi =
  trace "runWithLoc"
  concatMap (runWithLocHelper ppi)
  where
    runWithLocHelper :: PPInfo -> Some SomeTypedCFG -> [LogEntry]
    runWithLocHelper ppi' sstcfg = case trace "runWith Helper Case" sstcfg of
      Some (SomeTypedCFG tcfg) -> do
        let env = trace "runWithLocHelper" (ppi', getFirstProgramLoc tcfg)
        execWriter (runReaderT (trace "calling extract" extractLogEntries tcfg) env)

getFirstProgramLoc
  :: PermCheckExtC ext
  => TypedCFG ext blocks ghosts inits ret -> ProgramLoc
getFirstProgramLoc tcfg =
  case trace "getFirstProgramLoc" listToMaybe $ catMaybes $
         RL.mapToList getFirstProgramLocBM $ tpcfgBlockMap tcfg of
    Just pl -> pl
    _ -> error "Unable to get initial program location"

getFirstProgramLocBM
  :: PermCheckExtC ext
  => TypedBlock TransPhase ext blocks tops ret ctx
  -> Maybe ProgramLoc
getFirstProgramLocBM block =
  listToMaybe $ mapMaybe helper (_typedBlockEntries block)
  where
    helper
      :: PermCheckExtC ext
      => Some (TypedEntry TransPhase ext blocks tops ret ctx)
      -> Maybe ProgramLoc
    helper ste = case ste of
      Some TypedEntry { typedEntryBody = stmts } ->
        Just $ mbLift $ fmap getFirstProgramLocTS stmts

-- | From the sequence, get the first program location we encounter, which
-- should correspond to the permissions for the entry point we want to log
getFirstProgramLocTS :: PermCheckExtC ext
  => TypedStmtSeq ext blocks tops ret ctx
  -> ProgramLoc
getFirstProgramLocTS (TypedImplStmt (AnnotPermImpl _ pis)) =
  getFirstProgramLocPI pis
getFirstProgramLocTS (TypedConsStmt loc _ _ _) = loc
getFirstProgramLocTS (TypedTermStmt loc _) = loc

getFirstProgramLocPI
  :: PermCheckExtC ext
  => PermImpl (TypedStmtSeq ext blocks tops ret) ctx
  -> ProgramLoc
getFirstProgramLocPI (PermImpl_Done stmts) = getFirstProgramLocTS stmts
getFirstProgramLocPI (PermImpl_Step _ mbps) = getFirstProgramLocMBPI mbps

getFirstProgramLocMBPI
  :: PermCheckExtC ext
  => MbPermImpls (TypedStmtSeq ext blocks tops ret) ctx
  -> ProgramLoc
getFirstProgramLocMBPI MbPermImpls_Nil =
  error "Error finding program location for IDE log"
getFirstProgramLocMBPI (MbPermImpls_Cons _ _ pis) =
  mbLift $ fmap getFirstProgramLocPI pis

-- | Print a `ProgramLoc` in a way that is useful for an IDE, i.e., machine
-- readable
ppLoc :: ProgramLoc -> (String, String)
ppLoc pl =
  let fnName = T.unpack $ functionName $ plFunction pl
      locStr = ppPos $ plSourceLoc pl

      ppPos (SourcePos file line column) =
        T.unpack file <> ":" <> show line <> ":" <> show column
      ppPos (BinaryPos _ _) = "<unknown binary pos>"
      ppPos (OtherPos _) = "<unknown other pos>"
      ppPos InternalPos = "<unknown internal pos>"
  in (fnName, locStr)