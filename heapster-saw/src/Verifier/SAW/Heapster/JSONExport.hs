{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedLists, OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-orphans #-} -- hobbits instances for Value
module Verifier.SAW.Heapster.JSONExport
  (JsonExport, JsonExport1, ppToJson)
  where

import Data.Aeson ( ToJSON(toJSON), Value(..), object )
import Data.Binding.Hobbits
import Data.BitVector.Sized ( BV, asUnsigned )
import Data.Kind (Type)
import Data.Parameterized.BoolRepr ( BoolRepr )
import Data.Parameterized.Context ( Assignment )
import Data.Parameterized.Nonce (Nonce, indexValue)
import Data.Parameterized.TraversableFC ( FoldableFC(toListFC) )
import Data.Text (Text)
import Data.Traversable (for)
import Data.Type.RList ( mapToList )
import GHC.Natural (Natural)
import Lang.Crucible.FunctionHandle ( FnHandle )
import Lang.Crucible.LLVM.Bytes ( Bytes )
import Lang.Crucible.Types
import qualified Language.Haskell.TH as TH
import qualified Language.Haskell.TH.Datatype as TH
import Verifier.SAW.Heapster.CruUtil ( CruCtx )
import Verifier.SAW.Heapster.Permissions
import Verifier.SAW.Name ( Ident )
import What4.FunctionName ( FunctionName )

instance NuMatching Value where
    nuMatchingProof = unsafeMbTypeRepr

instance Liftable Value where
    mbLift = unClosed . mbLift . fmap unsafeClose

-- | Uniformly export the algebraic datatype structure
-- Heapster permissions.
ppToJson :: JsonExport a => PPInfo -> a -> Value
ppToJson ppi = let ?ppi = ppi in jsonExport

-- | Class of types that can be uniformly exported as JSON
-- using the Heapster pretty-printing information for names
class JsonExport a where
    jsonExport :: (?ppi::PPInfo) => a -> Value
    default jsonExport :: ToJSON a => (?ppi::PPInfo) => a -> Value
    jsonExport = toJSON

instance JsonExport (Name (t :: CrucibleType)) where
    jsonExport = toJSON . permPrettyString ?ppi

instance JsonExport1 f => JsonExport (Assignment f x) where
    jsonExport = toJSON . toListFC jsonExport1

instance JsonExport1 f => JsonExport (RAssign f x) where
    jsonExport = toJSON . mapToList jsonExport1

instance JsonExport b => JsonExport (Mb (a :: RList CrucibleType) b) where
    jsonExport mb = mbLift $ flip nuMultiWithElim1 mb $ \names body ->
        object [
            ("args", jsonExport names),
            ("body", jsonExport body)
        ]

instance JsonExport (Nonce a b) where
    jsonExport = toJSON . indexValue

instance JsonExport Bytes where
    jsonExport = toJSON . show -- Show instance is pretty

instance JsonExport Ident where
    jsonExport = toJSON . show -- Show instance is pretty

instance JsonExport FunctionName where
    jsonExport = toJSON . show -- Show instance is pretty

instance JsonExport a => JsonExport (Maybe a) where
    jsonExport = maybe Null jsonExport

instance (JsonExport a, JsonExport b) => JsonExport (a,b) where
    jsonExport (x,y) = toJSON (jsonExport x, jsonExport y)

instance JsonExport a => JsonExport [a] where
    jsonExport xs = toJSON (jsonExport <$> xs)

instance JsonExport (BV n) where
    jsonExport = toJSON . asUnsigned

instance JsonExport Natural
instance JsonExport Integer
instance JsonExport Int
instance JsonExport Bool
instance JsonExport Text
instance {-# OVERLAPPING #-} JsonExport String

-- | 'JsonExport' lifted to work on types with higher kinds
class JsonExport1 f where
    jsonExport1 :: (?ppi::PPInfo) => f a -> Value
    default jsonExport1 :: JsonExport (f a) => (?ppi::PPInfo) => f a -> Value
    jsonExport1 = jsonExport

instance JsonExport1 BaseTypeRepr
instance JsonExport1 TypeRepr
instance JsonExport1 (Name :: CrucibleType -> Type)
instance JsonExport1 LOwnedPerm
instance JsonExport1 PermExpr
instance JsonExport1 ValuePerm

-- This code generates generic JSON generation instances for
-- algebraic data types.
--
-- - All instances will generate an object.
-- - The object will have a @tag@ field containing the name
--   of the constructor used.
-- - Record constructors will add each record field to the
--   object using the field name
-- - Normal constructors with fields will have a field called
--   @contents@. If this constructor has more than one parameter
--   the @contents@ field will have a list. Otherwise it will
--   have a single element.
let fields :: String -> TH.ConstructorVariant -> [TH.ExpQ] -> TH.ExpQ

    -- Record constructor, use record field names as JSON field names
    fields tag (TH.RecordConstructor fieldNames) xs =
        TH.listE
          $ [| ("tag", tag) |]
          : [ [| (n, $x) |] | n <- TH.nameBase <$> fieldNames | x <- xs]

    -- No fields, so just report the constructor tag
    fields tag _ []  = [| [("tag", tag)] |]

    -- One field, just report that field as @contents@
    fields tag _ [x] = [| [("tag", tag), ("contents", $x)] |]

    -- Multiple fields, report them as a list as @contents@
    fields tag _ xs  = [| [("tag", tag), ("contents", Array $(TH.listE xs))] |]

    clauses :: TH.DatatypeInfo -> [TH.ClauseQ]
    clauses info =
        [do fieldVars <- for [0..length (TH.constructorFields con)-1] $ \i ->
                            TH.newName ("x" ++ show i)
            TH.clause
              [TH.conP (TH.constructorName con) (TH.varP <$> fieldVars)]
              (TH.normalB [|
                object
                    $(fields
                        (TH.nameBase (TH.constructorName con))
                        (TH.constructorVariant con)
                        [ [| jsonExport $(TH.varE v) |] | v <- fieldVars ]) |])
              []
        | con <- TH.datatypeCons info ]

    generateJsonExport :: TH.Name -> TH.DecQ
    generateJsonExport n =
      do info <- TH.reifyDatatype n
         let t = foldl TH.appT (TH.conT n)
               $ zipWith (\c _ -> TH.varT (TH.mkName [c])) ['a'..]
               $ TH.datatypeInstTypes info
         TH.instanceD (TH.cxt []) [t|JsonExport $t|]
           [TH.funD 'jsonExport (clauses info)]

    typesNeeded :: [TH.Name]
    typesNeeded =
        [''AtomicPerm, ''BaseTypeRepr, ''BoolRepr, ''BVFactor, ''BVProp,
        ''BVRange, ''CruCtx, ''FloatInfoRepr, ''FloatPrecisionRepr,
        ''FnHandle, ''FunPerm, ''LLVMArrayBorrow, ''LLVMArrayField,
        ''LLVMArrayIndex, ''LLVMArrayPerm, ''LLVMBlockPerm, ''LLVMFieldPerm,
        ''LLVMFieldShape, ''LOwnedPerm, ''NamedPermName, ''NamedShape,
        ''NamedShapeBody, ''NameReachConstr, ''NameSortRepr, ''NatRepr,
        ''PermExpr, ''PermOffset, ''StringInfoRepr, ''SymbolRepr, ''TypeRepr,
        ''ValuePerm, ''RWModality]

 in traverse generateJsonExport typesNeeded
