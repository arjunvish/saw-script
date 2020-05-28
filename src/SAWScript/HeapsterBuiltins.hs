{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}

module SAWScript.HeapsterBuiltins
       ( heapster_init_env
       , heapster_typecheck_fun
       , heapster_typecheck_mut_funs
       , heapster_define_opaque_perm
       , heapster_assume_fun
       , heapster_print_fun_trans
       , heapster_export_coq
       , heapster_parse_test
       ) where

import Data.Maybe
import qualified Data.Map as Map
import Data.String
import Data.IORef
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Unsafe.Coerce
import GHC.TypeNats

import Data.Binding.Hobbits

import Verifier.SAW.Term.Functor
import Verifier.SAW.Module
import Verifier.SAW.SharedTerm
import Verifier.SAW.OpenTerm

import Lang.Crucible.Types
import Lang.Crucible.FunctionHandle
import Lang.Crucible.CFG.Core
import Lang.Crucible.CFG.Extension
import Lang.Crucible.LLVM.Extension
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.LLVM.Translation

import SAWScript.Proof
import SAWScript.Prover.SolverStats
import SAWScript.TopLevel
import SAWScript.Value
import SAWScript.Utils as SS
import SAWScript.Options
import SAWScript.LLVMBuiltins
import SAWScript.Builtins
import SAWScript.Crucible.LLVM.Builtins
import SAWScript.Crucible.LLVM.MethodSpecIR

import SAWScript.Heapster.CruUtil
import SAWScript.Heapster.Permissions
import SAWScript.Heapster.TypedCrucible
import SAWScript.Heapster.SAWTranslation
import SAWScript.Heapster.PermParser

import SAWScript.Prover.Exporter
import Verifier.SAW.Translation.Coq
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))


getLLVMCFG :: ArchRepr arch -> SAW_CFG -> AnyCFG (LLVM arch)
getLLVMCFG _ (LLVM_CFG cfg) =
  -- FIXME: there should be an ArchRepr argument for LLVM_CFG to compare here!
  unsafeCoerce cfg
getLLVMCFG _ (JVM_CFG _) =
  error "getLLVMCFG: expected LLVM CFG, found JVM CFG!"

archReprWidth :: ArchRepr arch -> NatRepr (ArchWidth arch)
archReprWidth (X86Repr w) = w

-- FIXME: no longer needed...?
castFunPerm :: CFG ext blocks inits ret ->
               FunPerm ghosts args ret' ->
               TopLevel (FunPerm ghosts (CtxToRList inits) ret)
castFunPerm cfg fun_perm =
  case (testEquality (funPermArgs fun_perm) (mkCruCtx $ cfgArgTypes cfg),
        testEquality (funPermRet fun_perm) (cfgReturnType cfg)) of
    (Just Refl, Just Refl) -> return fun_perm
    (Nothing, _) ->
      fail $ unlines ["Function permission has incorrect argument types",
                      "Expected: " ++ show (cfgArgTypes cfg),
                      "Actual: " ++ show (funPermArgs fun_perm) ]
    (_, Nothing) ->
      fail $ unlines ["Function permission has incorrect return type",
                      "Expected: " ++ show (cfgReturnType cfg),
                      "Actual: " ++ show (funPermRet fun_perm)]

heapster_default_env :: Closed PermEnv
heapster_default_env =
  $(mkClosed
    [| let l_rw_ctx :: CruCtx (RNil :> LifetimeType :> RWModalityType) =
             knownRepr
           p_l_rw_ctx :: CruCtx (RNil :> ValuePermType (LLVMPointerType 64) :>
                                 LifetimeType :> RWModalityType) =
             knownRepr
           llvm64_tp :: TypeRepr (LLVMPointerType 64) = knownRepr
           w64_rpn = NamedPermName "list64" llvm64_tp l_rw_ctx
           list_rpn = NamedPermName "List" llvm64_tp p_l_rw_ctx in
       PermEnv
       {
         permEnvFunPerms = [],
         permEnvNamedPerms =
           [SomeNamedPerm $ NamedPerm_Rec $ RecPerm
            w64_rpn
            "Prelude.W64List"
            "Prelude.foldW64List"
            "Prelude.unfoldW64List"
            [(nuMulti (cruCtxProxies l_rw_ctx)
              (\_ -> ValPerm_Eq (PExpr_LLVMWord (PExpr_BV [] 0))),
              "Prelude.W64Nil")
            ,
             (nuMulti (cruCtxProxies l_rw_ctx)
              (\(_ :>: l :>: rw) ->
                ValPerm_Conj
                [Perm_LLVMField $ LLVMFieldPerm {
                    llvmFieldRW = PExpr_Var rw,
                    llvmFieldLifetime = PExpr_Var l,
                    llvmFieldOffset = PExpr_BV [] 0,
                    llvmFieldContents =
                        ValPerm_Exists (nu $ \x ->
                                         ValPerm_Eq $ PExpr_LLVMWord $
                                         PExpr_Var x) },
                 Perm_LLVMField $ LLVMFieldPerm {
                    llvmFieldRW = PExpr_Var rw,
                    llvmFieldLifetime = PExpr_Var l,
                    llvmFieldOffset = PExpr_BV [] 8,
                    llvmFieldContents =
                        ValPerm_Named w64_rpn
                        (PExprs_Cons
                         (PExprs_Cons PExprs_Nil (PExpr_Var l))
                         (PExpr_Var rw)) }]
              ),
              "Prelude.W64Cons")
             ],
            SomeNamedPerm $ NamedPerm_Rec $ RecPerm
            list_rpn
            "Prelude.List"
            "Prelude.foldList"
            "Prelude.unfoldList"
            [(nuMulti (cruCtxProxies p_l_rw_ctx)
              (\_ -> ValPerm_Eq (PExpr_LLVMWord (PExpr_BV [] 0))),
              "Prelude.Nil")
            ,
             (nuMulti (cruCtxProxies p_l_rw_ctx)
              (\(_ :>: p :>: l :>: rw) ->
                ValPerm_Conj
                [Perm_LLVMField $ LLVMFieldPerm {
                    llvmFieldRW = PExpr_Var rw,
                    llvmFieldLifetime = PExpr_Var l,
                    llvmFieldOffset = PExpr_BV [] 0,
                    llvmFieldContents = ValPerm_Var p },
                 Perm_LLVMField $ LLVMFieldPerm {
                    llvmFieldRW = PExpr_Var rw,
                    llvmFieldLifetime = PExpr_Var l,
                    llvmFieldOffset = PExpr_BV [] 8,
                    llvmFieldContents =
                        ValPerm_Named list_rpn
                        (PExprs_Cons
                         (PExprs_Cons (PExprs_Cons PExprs_Nil (PExpr_Var p))
                          (PExpr_Var l))
                         (PExpr_Var rw)) }]
              ),
              "Prelude.Cons")
             ]
           ],
           permEnvGlobalSyms = []
       }
     |])

heapster_init_env :: BuiltinContext -> Options -> String -> String ->
                     TopLevel HeapsterEnv
heapster_init_env bic opts mod_str llvm_filename =
  do llvm_mod <- llvm_load_module llvm_filename
     sc <- getSharedContext
     let saw_mod_name = mkModuleName [mod_str]
     mod_loaded <- liftIO $ scModuleIsLoaded sc saw_mod_name
     if mod_loaded then
       fail ("SAW module with name " ++ show mod_str ++ " already defined!")
       else return ()
     liftIO $ scLoadModule sc (emptyModule saw_mod_name)
     let perm_env = unClosed heapster_default_env
     perm_env_ref <- liftIO $ newIORef perm_env
     return $ HeapsterEnv {
       heapsterEnvSAWModule = saw_mod_name,
       heapsterEnvPermEnvRef = perm_env_ref,
       heapsterEnvLLVMModule = llvm_mod
       }

-- | Define a new opaque named permission with the given name, arguments, and
-- type, that translates to the given named SAW core definition
heapster_define_opaque_perm :: BuiltinContext -> Options -> HeapsterEnv ->
                               String -> String -> String -> String ->
                               TopLevel ()
heapster_define_opaque_perm _bic _opts henv nm args_str tp_str i_string =
  do env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
     some_args <- case parseCtxString env args_str of
       Left err -> fail ("Error parsing argument types: " ++ show err)
       Right args -> return args
     some_tp <- case parseTypeString env tp_str of
       Left err -> fail ("Error parsing permission type: " ++ show err)
       Right tp -> return tp
     sc <- getSharedContext
     let i = fromString i_string
     -- FIXME: i could be a datatype as well
     -- _ <- liftIO $ scRequireDef sc i -- Ensure that i is defined
     case (some_args, some_tp) of
       (Some args, Some tp) ->
         let env' = permEnvAddOpaquePerm env nm args tp i in
         liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'

-- | Assume that the given named function has the supplied type and translates
-- to a SAW core definition given by name
heapster_assume_fun :: BuiltinContext -> Options -> HeapsterEnv ->
                       String -> String -> String -> TopLevel ()
heapster_assume_fun bic opts henv nm perms_string i_string =
  let some_lm = heapsterEnvLLVMModule henv in
  case some_lm of
    Some lm -> do
      sc <- getSharedContext
      let i = fromString i_string
      _ <- liftIO $ scRequireDef sc i -- Ensure that i is defined
      let trans_tm = globalOpenTerm i

      let arch = llvmArch $ _transContext (lm ^. modTrans)
      let w = archReprWidth arch
      env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
      any_cfg <- (getLLVMCFG arch <$> crucible_llvm_cfg bic opts some_lm nm)
      leq_proof <- case decideLeq (knownNat @1) w of
        Left pf -> return pf
        Right _ -> fail "LLVM arch width is 0!"
      case any_cfg of
        AnyCFG cfg ->
          withKnownNat w $ withLeqProof leq_proof $
          let args = mkCruCtx $ handleArgTypes $ cfgHandle cfg
              ret = handleReturnType $ cfgHandle cfg in
          case parseFunPermString env args ret perms_string of
            Left err -> fail $ show err
            Right (SomeFunPerm fun_perm) ->
              liftIO $ writeIORef (heapsterEnvPermEnvRef henv) $
              permEnvAddGlobalSymFun env (GlobalSymbol $
                                          fromString nm) w fun_perm trans_tm


heapster_typecheck_mut_funs :: BuiltinContext -> Options -> HeapsterEnv ->
                               [(String, String)] -> TopLevel ()
heapster_typecheck_mut_funs bic opts henv fn_names_and_perms =
  let some_lm = heapsterEnvLLVMModule henv in
  case some_lm of
    Some lm -> do
      let arch = llvmArch $ _transContext (lm ^. modTrans)
      let w = archReprWidth arch
      env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
      some_cfgs_and_perms <- forM fn_names_and_perms $ \(nm,perms_string) ->
        (getLLVMCFG arch <$>
         crucible_llvm_cfg bic opts some_lm nm) >>= \any_cfg ->
        case any_cfg of
          AnyCFG cfg ->
            do let args = mkCruCtx $ handleArgTypes $ cfgHandle cfg
               let ret = handleReturnType $ cfgHandle cfg
               case parseFunPermString env args ret perms_string of
                 Left err -> fail $ show err
                 Right (SomeFunPerm fun_perm) ->
                   return $ SomeCFGAndPerm (GlobalSymbol $
                                            fromString nm) cfg fun_perm
      sc <- getSharedContext
      let saw_modname = heapsterEnvSAWModule henv
      leq_proof <- case decideLeq (knownNat @1) w of
        Left pf -> return pf
        Right _ -> fail "LLVM arch width is 0!"
      env' <- liftIO $ withKnownNat w $ withLeqProof leq_proof $
        tcTranslateAddCFGs sc saw_modname w env some_cfgs_and_perms
      liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'


heapster_typecheck_fun :: BuiltinContext -> Options -> HeapsterEnv ->
                          String -> String -> TopLevel ()
heapster_typecheck_fun bic opts henv fn_name perms_string =
  heapster_typecheck_mut_funs bic opts henv [(fn_name, perms_string)]

heapster_print_fun_trans :: BuiltinContext -> Options -> HeapsterEnv ->
                            String -> TopLevel ()
heapster_print_fun_trans bic opts henv fn_name =
  do pp_opts <- getTopLevelPPOpts
     sc <- getSharedContext
     let saw_modname = heapsterEnvSAWModule henv
     fun_term <-
       fmap (fromJust . defBody) $
       liftIO $ scRequireDef sc $ mkIdent saw_modname fn_name
     liftIO $ putStrLn $ scPrettyTerm pp_opts fun_term

heapster_export_coq :: BuiltinContext -> Options -> HeapsterEnv ->
                       String -> TopLevel ()
heapster_export_coq bic opts henv filename =
  do let coq_trans_conf = coqTranslationConfiguration [] []
     sc <- getSharedContext
     saw_mod <- liftIO $ scFindModule sc $ heapsterEnvSAWModule henv
     let coq_doc =
           vcat [preamblePlus coq_trans_conf
                 (string "From CryptolToCoq Require Import SAWCorePrelude."),
                 translateSAWModule coq_trans_conf saw_mod]
     liftIO $ writeFile filename (show coq_doc)

heapster_parse_test :: BuiltinContext -> Options -> Some LLVMModule ->
                       String -> String ->  TopLevel ()
heapster_parse_test bic opts some_lm fn_name perms_string =
  case some_lm of
    Some lm -> do
      let env = unClosed heapster_default_env -- FIXME: cl_env should be an argument
      let arch = llvmArch $ _transContext (lm ^. modTrans)
      any_cfg <- getLLVMCFG arch <$> crucible_llvm_cfg bic opts some_lm fn_name
      case any_cfg of
        AnyCFG cfg -> do
          let args = mkCruCtx $ handleArgTypes $ cfgHandle cfg
          let ret = handleReturnType $ cfgHandle cfg
          case parseFunPermString env args ret perms_string of
            Left err -> fail $ show err
            Right (SomeFunPerm fun_perm) ->
              liftIO $ putStrLn $ permPrettyString emptyPPInfo fun_perm
