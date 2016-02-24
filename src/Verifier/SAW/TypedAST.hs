{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

{- |
Module      : Verifier.SAW.TypedAST
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.TypedAST
 ( -- * Module operations.
   Module
 , emptyModule
 , ModuleName, mkModuleName
 , moduleName
 , preludeName
 , ModuleDecl(..)
 , moduleDecls
 , allModuleDecls
 , TypedDataType
 , moduleDataTypes
 , moduleImports
 , findDataType
 , TypedCtor
 , moduleCtors
 , findCtor
 , TypedDef
 , TypedDefEqn
 , moduleDefs
 , allModuleDefs
 , findDef
 , insImport
 , insDataType
 , insDef
 , moduleActualDefs
 , allModuleActualDefs
 , modulePrimitives
 , allModulePrimitives
 , moduleAxioms
 , allModuleAxioms
   -- * Data types and defintiions.
 , DataType(..)
 , Ctor(..)
 , GenericDef(..)
 , Def
 , DefQualifier(..)
 , LocalDef
 , localVarNames
 , DefEqn(..)
 , Pat(..)
 , patBoundVarCount
 , patUnusedVarCount
   -- * Terms and associated operations.
 , Term(..)
 , incVars
 , piArgCount
 , TermF(..)
 , FlatTermF(..)
 , Termlike(..)
 , zipWithFlatTermF
 , freesTerm
 , freesTermF
 , termToPat

 , LocalVarDoc
 , emptyLocalVarDoc
 , docShowLocalNames
 , docShowLocalTypes

 , TermPrinter
 , TermDoc(..)
 , PPOpts(..)
 , defaultPPOpts
 , ppTermDoc
 , Prec(..)
 , ppAppParens
 , ppTerm
 , ppTermF
 , ppTermF'
 , ppFlatTermF
 , ppFlatTermF'
 , ppRecordF
 , ppTermDepth
   -- * Primitive types.
 , Sort, mkSort, sortOf, maxSort
 , Ident(identModule, identName), mkIdent
 , parseIdent
 , isIdent
 , ppIdent
 , ppDefEqn
 , DeBruijnIndex
 , FieldName
 , instantiateVarList
 , ExtCns(..)
 , VarIndex
   -- * Utility functions
 , BitSet
 , commaSepList
 , semiTermList
 , ppParens
 ) where

import Control.Applicative hiding (empty)
import Control.Exception (assert)
import Control.Lens
import Data.Bits
import qualified Data.ByteString.UTF8 as BS
import Data.Char
#if !MIN_VERSION_base(4,8,0)
import Data.Foldable (Foldable)
#endif
import Data.Foldable (foldl', sum, all)
import Data.Hashable
import Data.List (intercalate)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.Word
import GHC.Generics (Generic)
import GHC.Exts (IsString(..))
import Numeric (showIntAtBase)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import qualified Text.PrettyPrint.ANSI.Leijen as Leijen ((<$>))
import qualified Text.PrettyPrint.ANSI.Leijen as PPL

import Prelude hiding (all, foldr, sum)

import Verifier.SAW.Utils (internalError, sumBy)
import qualified Verifier.SAW.TermNet as Net



(<<$>>) :: Doc -> Doc -> Doc
x <<$>> y = (PPL.<$>) x y


instance (Hashable k, Hashable a) => Hashable (Map k a) where
    hashWithSalt x m = hashWithSalt x (Map.assocs m)

instance Hashable a => Hashable (Vector a) where
    hashWithSalt x v = hashWithSalt x (V.toList v)

doublecolon :: Doc
doublecolon = colon <> colon

bracesList :: [Doc] -> Doc
bracesList = encloseSep lbrace rbrace comma

-- | Print a list of items separated by semicolons
semiTermList :: [Doc] -> Doc
semiTermList = hsep . fmap (<> semi)

commaSepList :: [Doc] -> Doc
commaSepList [] = empty
commaSepList [d] = d
commaSepList (d:l) = d <> comma <+> commaSepList l

-- | Add parenthesis around a document if condition is true.
ppParens :: Bool -> Doc -> Doc
ppParens b = if b then parens . align else id

newtype ModuleName = ModuleName BS.ByteString -- [String]
  deriving (Eq, Ord, Generic)

instance Hashable ModuleName -- automatically derived

instance Show ModuleName where
  show (ModuleName s) = BS.toString s

-- | Crete a module name given a list of strings with the top-most
-- module name given first.
mkModuleName :: [String] -> ModuleName
mkModuleName [] = error "internal: mkModuleName given empty module name"
mkModuleName nms = assert (all isCtor nms) $ ModuleName (BS.fromString s)
  where s = intercalate "." (reverse nms)

isIdent :: String -> Bool
isIdent (c:l) = isAlpha c && all isIdChar l
isIdent [] = False

isCtor :: String -> Bool
isCtor (c:l) = isUpper c && all isIdChar l
isCtor [] = False

-- | Returns true if character can appear in identifier.
isIdChar :: Char -> Bool
isIdChar c = isAlphaNum c || (c == '_') || (c == '\'')


preludeName :: ModuleName
preludeName = mkModuleName ["Prelude"]

data Ident = Ident { identModule :: ModuleName
                   , identName :: String
                   }
  deriving (Eq, Ord, Generic)

instance Hashable Ident -- automatically derived

instance Show Ident where
  show (Ident m s) = shows m ('.' : s)

mkIdent :: ModuleName -> String -> Ident
mkIdent = Ident

-- | Parse a fully qualified identifier.
parseIdent :: String -> Ident
parseIdent s0 =
    case reverse (breakEach s0) of
      (_:[]) -> internalError $ "parseIdent given empty module name."
      (nm:rMod) -> mkIdent (mkModuleName (reverse rMod)) nm
      _ -> internalError $ "parseIdent given bad identifier " ++ show s0
  where breakEach s =
          case break (=='.') s of
            (h,[]) -> [h]
            (h,'.':r) -> h : breakEach r
            _ -> internalError "parseIdent.breakEach failed"

instance IsString Ident where
  fromString = parseIdent

newtype Sort = SortCtor { _sortIndex :: Integer }
  deriving (Eq, Ord, Generic)

instance Hashable Sort -- automatically derived

instance Show Sort where
  showsPrec p (SortCtor i) = showParen (p >= 10) (showString "sort " . shows i)

-- | Create sort for given integer.
mkSort :: Integer -> Sort
mkSort i | 0 <= i = SortCtor i
         | otherwise = error "Negative index given to sort."

-- | Returns sort of the given sort.
sortOf :: Sort -> Sort
sortOf (SortCtor i) = SortCtor (i + 1)

-- | Returns the larger of the two sorts.
maxSort :: Sort -> Sort -> Sort
maxSort (SortCtor x) (SortCtor y) = SortCtor (max x y)

type DeBruijnIndex = Int

type FieldName = String

-- Patterns are used to match equations.
data Pat e = -- | Variable bound by pattern.
             -- Variables may be bound in context in a different order than
             -- a left-to-right traversal.  The DeBruijnIndex indicates the order.
             PVar String DeBruijnIndex e
             -- | The
           | PUnused DeBruijnIndex e
           | PUnit
           | PPair (Pat e) (Pat e)
           | PEmpty
           | PField (Pat e) (Pat e) (Pat e) -- ^ Field name, field value, rest of record
           | PString String
           | PCtor Ident [Pat e]
  deriving (Eq,Ord, Show, Functor, Foldable, Traversable, Generic)

instance Hashable e => Hashable (Pat e) -- automatically derived

patBoundVarCount :: Pat e -> DeBruijnIndex
patBoundVarCount p =
  case p of
    PVar{} -> 1
    PUnused{} -> 0
    PCtor _ l -> sumBy patBoundVarCount l
    PUnit     -> 0
    PPair x y -> patBoundVarCount x + patBoundVarCount y
    PEmpty    -> 0
    PField f x y -> patBoundVarCount f + patBoundVarCount x + patBoundVarCount y
    PString _ -> 0

patUnusedVarCount :: Pat e -> DeBruijnIndex
patUnusedVarCount p =
  case p of
    PVar{} -> 0
    PUnused{} -> 1
    PCtor _ l -> sumBy patUnusedVarCount l
    PUnit     -> 0
    PPair x y -> patUnusedVarCount x + patUnusedVarCount y
    PEmpty    -> 0
    PField _ x y -> patUnusedVarCount x + patUnusedVarCount y
    PString _ -> 0

patBoundVars :: Pat e -> [String]
patBoundVars p =
  case p of
    PVar s _ _ -> [s]
    PCtor _ l -> concatMap patBoundVars l
    PUnit     -> []
    PPair x y -> patBoundVars x ++ patBoundVars y
    PEmpty    -> []
    PField _ x y -> patBoundVars x ++ patBoundVars y
    PString _ -> []
    PUnused{} -> []

lift2 :: (a -> b) -> (b -> b -> c) -> a -> a -> c
lift2 f h x y = h (f x) (f y)

data DefQualifier
  = NoQualifier
  | PrimQualifier
  | AxiomQualifier
 deriving (Eq,Ord,Show,Generic)

instance Hashable DefQualifier -- automatically derived

-- | A Definition contains an identifier, the type of the definition, and a list of equations.
data GenericDef n e =
    Def { defIdent :: n
        , defQualifier :: DefQualifier
        , defType :: e
        , defEqs :: [DefEqn e]
        }
    deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Generic)

type Def = GenericDef Ident
type LocalDef = GenericDef String

instance (Hashable n, Hashable e) => Hashable (GenericDef n e) -- automatically derived

localVarNames :: LocalDef e -> [String]
localVarNames (Def nm _ _ _) = [nm]


data LocalVarDoc = LVD { docModuleName :: Map ModuleName String
                       , _docShowLocalNames :: Bool
                       , _docShowLocalTypes :: Bool
                       , docMap :: !(Map DeBruijnIndex Doc)
                       , docLvl :: !DeBruijnIndex
                       , docUsedMap :: Map String DeBruijnIndex
                       }

-- | Flag indicates doc should use local names (default True)
docShowLocalNames :: Simple Lens LocalVarDoc Bool
docShowLocalNames = lens _docShowLocalNames (\s v -> s { _docShowLocalNames = v })

-- | Flag indicates doc should print type for locals (default false)
docShowLocalTypes :: Simple Lens LocalVarDoc Bool
docShowLocalTypes = lens _docShowLocalTypes (\s v -> s { _docShowLocalTypes = v })

emptyLocalVarDoc :: LocalVarDoc
emptyLocalVarDoc = LVD { docModuleName = Map.empty
                       , _docShowLocalNames = True
                       , _docShowLocalTypes = False
                       , docMap = Map.empty
                       , docLvl = 0
                       , docUsedMap = Map.empty
                       }

freshVariant :: Map String a -> String -> String
freshVariant used name
  | Map.member name used = freshVariant used (name ++ "'")
  | otherwise = name

consBinding :: LocalVarDoc -> String -> LocalVarDoc
consBinding lvd i = lvd { docMap = Map.insert lvl (text i) m
                        , docLvl = lvl + 1
                        , docUsedMap = Map.insert i lvl (docUsedMap lvd)
                        }
 where lvl = docLvl lvd
       m = case Map.lookup i (docUsedMap lvd) of
             Just pl -> Map.delete pl (docMap lvd)
             Nothing -> docMap lvd

lookupDoc :: LocalVarDoc -> DeBruijnIndex -> Doc
lookupDoc lvd i
    | lvd^.docShowLocalNames =
        case Map.lookup lvl (docMap lvd) of
          Just d -> d
          Nothing -> text ('!' : show (i - docLvl lvd))
    | otherwise = text ('!' : show i)
  where lvl = docLvl lvd - i - 1

data DefEqn e
  = DefEqn [Pat e] e -- ^ List of patterns and a right hand side
  deriving (Functor, Foldable, Traversable, Generic, Show)

instance Hashable e => Hashable (DefEqn e) -- automatically derived

instance (Eq e) => Eq (DefEqn e) where
  DefEqn xp xr == DefEqn yp yr = xp == yp && xr == yr

instance (Ord e) => Ord (DefEqn e) where
  compare (DefEqn xp xr) (DefEqn yp yr) = compare (xp,xr) (yp,yr)

data Ctor n tp = Ctor { ctorName :: !n
                        -- | The type of the constructor (should contain no free variables).
                      , ctorType :: tp
                      }
  deriving (Functor, Foldable, Traversable)

instance Eq n => Eq (Ctor n tp) where
  (==) = lift2 ctorName (==)

instance Ord n => Ord (Ctor n tp) where
  compare = lift2 ctorName compare

instance Show n => Show (Ctor n tp) where
  show = show . ctorName

data PPOpts = PPOpts { ppBase :: Int }

defaultPPOpts :: PPOpts
defaultPPOpts = PPOpts { ppBase = 10 }

ppNat :: PPOpts -> Integer -> Doc
ppNat opts i
  | base > 36 = integer i
  | otherwise = prefix <> text value
  where
    base = ppBase opts

    prefix = case base of
      2  -> text "0b"
      8  -> text "0o"
      10 -> empty
      16 -> text "0x"
      _  -> text "0"  <> char '<' <> int base <> char '>'

    value  = showIntAtBase (toInteger base) (digits !!) i ""
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"

ppCtor :: TermPrinter e -> Ctor Ident e -> Doc
ppCtor f c = hang 2 $ group (ppIdent (ctorName c) <<$>> doublecolon <+> tp)
  where lcls = emptyLocalVarDoc
        tp = f lcls PrecLambda (ctorType c)

data DataType n t = DataType { dtName :: n
                             , dtType :: t
                             , dtCtors :: [Ctor n t]
                             , dtIsPrimitive :: Bool
                             }
  deriving (Functor, Foldable, Traversable)

instance Eq n => Eq (DataType n t) where
  (==) = lift2 dtName (==)

instance Ord n => Ord (DataType n t) where
  compare = lift2 dtName compare

instance Show n => Show (DataType n t) where
  show = show . dtName

ppDataType :: TermPrinter e -> DataType Ident e -> Doc
ppDataType f dt =
  group $ (group ((text "data" <+> tc) <<$>> (text "where" <+> lbrace)))
          <<$>>
          vcat ((indent 2 . ppc) <$> dtCtors dt)
          <$$>
          rbrace

  where lcls = emptyLocalVarDoc
        sym = ppIdent (dtName dt)
        tc = ppTypeConstraint f lcls sym (dtType dt)
        ppc c = ppCtor f c <> semi

type VarIndex = Word64

-- NB: If you add constructors to FlatTermF, make sure you update
--     zipWithFlatTermF!
data FlatTermF e
  = GlobalDef !Ident  -- ^ Global variables are referenced by label.

    -- Tuples are represented as nested pairs, grouped to the right,
    -- terminated with unit at the end.
  | UnitValue
  | UnitType
  | PairValue e e
  | PairType e e
  | PairLeft e
  | PairRight e
  | EmptyValue
  | EmptyType
  | FieldValue e e e -- Field name, field value, remainder of record
  | FieldType e e e
  | RecordSelector e e -- Record value, field name

  | CtorApp !Ident ![e]
  | DataTypeApp !Ident ![e]

  | Sort !Sort

    -- Primitive builtin values
    -- | Natural number with given value (negative numbers are not allowed).
  | NatLit !Integer
    -- | Array value includes type of elements followed by elements.
  | ArrayValue e (Vector e)
    -- | Floating point literal
  | FloatLit !Float
    -- | Double precision floating point literal.
  | DoubleLit !Double
    -- | String literal.
  | StringLit !String

    -- | An external constant with a name.
  | ExtCns !(ExtCns e)
  deriving (Eq, Ord, Functor, Foldable, Traversable, Generic)

-- | An external constant with a name.
-- Names are necessarily unique, but the var index should be.
data ExtCns e = EC { ecVarIndex :: !VarIndex
                   , ecName :: !String
                   , ecType :: !e
                   }
  deriving (Functor, Foldable, Traversable)

instance Eq (ExtCns e) where
  x == y = ecVarIndex x == ecVarIndex y

instance Ord (ExtCns e) where
  compare x y = compare (ecVarIndex x) (ecVarIndex y)

instance Hashable (ExtCns e) where
  hashWithSalt x ec = hashWithSalt x (ecVarIndex ec)

instance Hashable e => Hashable (FlatTermF e) -- automatically derived

zipWithFlatTermF :: (x -> y -> z) -> FlatTermF x -> FlatTermF y -> Maybe (FlatTermF z)
zipWithFlatTermF f = go
  where go (GlobalDef x) (GlobalDef y) | x == y = Just $ GlobalDef x

        go UnitValue UnitValue = Just UnitValue
        go UnitType UnitType = Just UnitType
        go (PairValue x1 x2) (PairValue y1 y2) = Just (PairValue (f x1 y1) (f x2 y2))
        go (PairType x1 x2) (PairType y1 y2) = Just (PairType (f x1 y1) (f x2 y2))
        go (PairLeft x) (PairLeft y) = Just (PairLeft (f x y))
        go (PairRight x) (PairRight y) = Just (PairLeft (f x y))

        go EmptyValue EmptyValue = Just EmptyValue
        go EmptyType EmptyType = Just EmptyType
        go (FieldValue x1 x2 x3) (FieldValue y1 y2 y3) =
          Just $ FieldValue (f x1 y1) (f x2 y2) (f x3 y3)
        go (FieldType x1 x2 x3) (FieldType y1 y2 y3) =
          Just $ FieldType (f x1 y1) (f x2 y2) (f x3 y3)
        go (RecordSelector x1 x2) (RecordSelector y1 y2) =
          Just $ RecordSelector (f x1 y1) (f x2 y2)

        go (CtorApp cx lx) (CtorApp cy ly)
          | cx == cy = Just $ CtorApp cx (zipWith f lx ly)
        go (DataTypeApp dx lx) (DataTypeApp dy ly)
          | dx == dy = Just $ DataTypeApp dx (zipWith f lx ly)
        go (Sort sx) (Sort sy) | sx == sy = Just (Sort sx)
        go (NatLit i) (NatLit j) | i == j = Just (NatLit i)
        go (FloatLit fx) (FloatLit fy)
          | fx == fy = Just $ FloatLit fx
        go (DoubleLit fx) (DoubleLit fy)
          | fx == fy = Just $ DoubleLit fx
        go (StringLit s) (StringLit t) | s == t = Just (StringLit s)
        go (ArrayValue tx vx) (ArrayValue ty vy)
          | V.length vx == V.length vy = Just $ ArrayValue (f tx ty) (V.zipWith f vx vy)
        go (ExtCns (EC xi xn xt)) (ExtCns (EC yi _ yt))
          | xi == yi = Just (ExtCns (EC xi xn (f xt yt)))

        go _ _ = Nothing

data TermF e
    = FTermF !(FlatTermF e)  -- ^ Global variables are referenced by label.
    | App !e !e
    | Lambda !String !e !e
    | Pi !String !e !e
       -- | List of bindings and the let expression itself.
      -- Let expressions introduce variables for each identifier.
      -- Let definitions are bound in the order they appear, e.g., the first symbol
      -- is referred to by the largest deBruijnIndex within the let, and the last
      -- symbol has index 0 within the let.
    | Let [LocalDef e] !e
      -- | Local variables are referenced by deBruijn index.
      -- The type of the var is in the context of when the variable was bound.
    | LocalVar !DeBruijnIndex
    | Constant String !e !e  -- ^ An abstract constant packaged with its definition and type.
  deriving (Eq, Ord, Functor, Foldable, Traversable, Generic)

instance Hashable e => Hashable (TermF e) -- automatically derived.

class Termlike t where
  unwrapTermF :: t -> TermF t

termToPat :: Termlike t => t -> Net.Pat
termToPat t =
    case unwrapTermF t of
      Constant d _ _            -> Net.Atom d
      App t1 t2                 -> Net.App (termToPat t1) (termToPat t2)
      FTermF (GlobalDef d)      -> Net.Atom (identName d)
      FTermF (Sort s)           -> Net.Atom ('*' : show s)
      FTermF (NatLit n)         -> Net.Atom (show n)
      FTermF (DataTypeApp c ts) -> foldl Net.App (Net.Atom (identName c)) (map termToPat ts)
      FTermF (CtorApp c ts)     -> foldl Net.App (Net.Atom (identName c)) (map termToPat ts)
      _                         -> Net.Var

instance Net.Pattern Term where
  toPat = termToPat

ppIdent :: Ident -> Doc
ppIdent i = text (show i)

ppTypeConstraint :: TermPrinter e -> LocalVarDoc -> Doc -> e -> Doc
ppTypeConstraint f lcls sym tp = hang 2 $ group (sym <<$>> doublecolon <+> f lcls PrecLambda tp)

ppDef :: PPOpts -> LocalVarDoc -> Def Term -> Doc
ppDef opts lcls d = vcat (tpd : (ppDefEqn (ppTerm opts) lcls sym <$> (reverse $ defEqs d)))
  where sym = ppIdent (defIdent d)
        tpd = ppTypeConstraint (ppTerm opts) lcls sym (defType d) <> semi

ppLocalDef :: Applicative f
           => (LocalVarDoc -> Prec -> e -> f Doc)
           -> LocalVarDoc -- ^ Context outside let
           -> LocalVarDoc -- ^ Context inside let
           -> LocalDef e
           -> f Doc
ppLocalDef pp lcls lcls' (Def nm _qual tp eqs) =
    ppd <$> (pptc <$> pp lcls PrecLambda tp)
        <*> traverse (ppDefEqnF pp lcls' sym) (reverse eqs)
  where sym = text nm
        pptc tpd = hang 2 $ group (sym <<$>> doublecolon <+> tpd <> semi)
        ppd tpd eqds = vcat (tpd : eqds)

ppDefEqn :: TermPrinter e -> LocalVarDoc -> Doc -> DefEqn e -> Doc
ppDefEqn pp lcls sym eq = runIdentity (ppDefEqnF pp' lcls sym eq)
  where pp' l' p' e' = pure (pp l' p' e')

ppDefEqnF :: Applicative f
          => (LocalVarDoc -> Prec -> e -> f Doc)
          -> LocalVarDoc -> Doc -> DefEqn e -> f Doc
ppDefEqnF f lcls sym (DefEqn pats rhs) =
    ppEq <$> traverse ppPat' pats
-- Is this OK?
         <*> f lcls' PrecNone rhs
--         <*> f lcls' PrecLambda rhs
  where ppEq pd rhs' = group $ nest 2 (sym <+> (hsep (pd++[equals])) <<$>> rhs' <> semi)
        lcls' = foldl' consBinding lcls (concatMap patBoundVars pats)
        ppPat' = fmap ppTermDoc . ppPat (\p e -> TermDoc <$> f lcls' p e) PrecArg

data Prec
  = PrecNone   -- ^ Nonterminal 'Term'
  | PrecLambda -- ^ Nonterminal 'LTerm'
  | PrecApp    -- ^ Nonterminal 'AppTerm'
  | PrecArg    -- ^ Nonterminal 'AppArg'
  deriving (Eq, Ord)

-- | Type TermDoc facilitates the pretty-printing of nested tuple and
-- record structures using non-nested syntax.
data TermDoc
  = TermDoc Doc
  | TupleDoc [Doc]
  | TupleTDoc [Doc]
  | RecordDoc [(FieldName, Doc)]
  | RecordTDoc [(FieldName, Doc)]
  | LabelDoc FieldName

ppTermDoc :: TermDoc -> Doc
ppTermDoc td =
  case td of
    TermDoc doc       -> doc
    TupleDoc docs     -> tupled docs
    TupleTDoc docs    -> char '#' <> tupled docs
    RecordDoc fields  -> bracesList (map (ppField "=") fields)
    RecordTDoc fields -> char '#' <> bracesList (map (ppField ":") fields)
    LabelDoc s        -> text (show s)
  where
    ppField s (name, rhs) = group (nest 2 (text name <+> text s <<$>> rhs))

ppPairValue :: TermDoc -> TermDoc -> TermDoc
ppPairValue x (TupleDoc docs) = TupleDoc (ppTermDoc x : docs)
ppPairValue x y = TermDoc $ parens (ppTermDoc x <+> char '|' <+> ppTermDoc y)

ppPairType :: TermDoc -> TermDoc -> TermDoc
ppPairType x (TupleTDoc docs) = TupleTDoc (ppTermDoc x : docs)
ppPairType x y = TermDoc $ char '#' <> parens (ppTermDoc x <+> char '|' <+> ppTermDoc y)

ppFieldValue :: TermDoc -> TermDoc -> TermDoc -> TermDoc
ppFieldValue (LabelDoc f) x (RecordDoc fields) = RecordDoc ((f, ppTermDoc x) : fields)
ppFieldValue f x y = TermDoc $ braces (eqn (ppTermDoc f) x <+> char '|' <+> ppTermDoc y)
  where eqn l r = group (nest 2 (l <+> equals <<$>> ppTermDoc r))

ppFieldType :: TermDoc -> TermDoc -> TermDoc -> TermDoc
ppFieldType (LabelDoc f) x (RecordTDoc fields) = RecordTDoc ((f, ppTermDoc x) : fields)
ppFieldType f x y = TermDoc $ char '#' <> braces (eqn (ppTermDoc f) x <+> char '|' <+> ppTermDoc y)
  where eqn l r = group (nest 2 (l <+> equals <<$>> ppTermDoc r))

ppRecordSelector :: TermDoc -> TermDoc -> TermDoc
ppRecordSelector x (LabelDoc f) = TermDoc (ppTermDoc x <> char '.' <> text f)
ppRecordSelector x f = TermDoc (ppTermDoc x <> char '.' <> ppParens True (ppTermDoc f))

ppAppParens :: Prec -> Doc -> Doc
ppAppParens p d = ppParens (p > PrecApp) d

ppAppList :: Prec -> Doc -> [Doc] -> Doc
ppAppList _ sym [] = sym
ppAppList p sym l = ppAppParens p $ hsep (sym : l)

ppPat :: Applicative f
      => (Prec -> e -> f TermDoc)
      -> Prec -> Pat e -> f TermDoc
ppPat f p pat =
  case pat of
    PVar i _ _ -> pure $ TermDoc $ text i
    PUnused{}  -> pure $ TermDoc $ char '_'
    PCtor c pl -> TermDoc . ppAppList p (ppIdent c) . map ppTermDoc <$>
                  traverse (ppPat f PrecArg) pl
    PUnit      -> pure $ TermDoc $ text "()"
    PPair x y  -> ppPairValue <$> ppPat f PrecNone x <*> ppPat f PrecNone y
    PEmpty     -> pure $ TermDoc $ text "{}"
    PField n x y -> ppFieldValue <$> ppPat f PrecNone n
                    <*> ppPat f PrecNone x <*> ppPat f PrecNone y
    PString s  -> pure $ LabelDoc s

type TermPrinter e = LocalVarDoc -> Prec -> e -> Doc

ppRecordF :: Applicative f => (t -> f Doc) -> Map String t -> f Doc
ppRecordF pp m = braces . semiTermList <$> traverse ppFld (Map.toList m)
  where ppFld (fld,v) = eqCat (text fld) <$> pp v
        eqCat x y = group $ nest 2 (x <+> equals <<$>> y)

ppFlatTermF' :: Applicative f => PPOpts -> (Prec -> t -> f TermDoc) -> Prec -> FlatTermF t -> f TermDoc
ppFlatTermF' opts pp prec tf =
  case tf of
    GlobalDef i   -> pure $ TermDoc $ ppIdent i
    UnitValue     -> pure $ TupleDoc []
    UnitType      -> pure $ TupleTDoc []
    PairValue x y -> ppPairValue <$> pp PrecNone x <*> pp PrecNone y
    PairType x y  -> ppPairType <$> pp PrecNone x <*> pp PrecNone y
    PairLeft t    -> TermDoc . ppParens (prec > PrecArg) . (<> (text ".L")) <$> pp' PrecArg t
    PairRight t   -> TermDoc . ppParens (prec > PrecArg) . (<> (text ".R")) <$> pp' PrecArg t
    EmptyValue         -> pure $ RecordDoc []
    EmptyType          -> pure $ RecordTDoc []
    FieldValue f x y   -> ppFieldValue <$> pp PrecNone f <*> pp PrecNone x <*> pp PrecNone y
    FieldType f x y    -> ppFieldType <$> pp PrecNone f <*> pp PrecNone x <*> pp PrecNone y
    RecordSelector t f -> ppRecordSelector <$> pp PrecArg t <*> pp PrecArg f

    CtorApp c l      -> TermDoc . ppAppList prec (ppIdent c) <$> traverse (pp' PrecArg) l
    DataTypeApp dt l -> TermDoc . ppAppList prec (ppIdent dt) <$> traverse (pp' PrecArg) l

    Sort s -> pure $ TermDoc $ text (show s)
    NatLit i -> pure $ TermDoc $ ppNat opts i
    ArrayValue _ vl -> TermDoc . list <$> traverse (pp' PrecNone) (V.toList vl)
    FloatLit v  -> pure $ TermDoc $ text (show v)
    DoubleLit v -> pure $ TermDoc $ text (show v)
    StringLit s -> pure $ LabelDoc s
    ExtCns (EC _ v _) -> pure $ TermDoc $ text v
  where
    pp' p t = ppTermDoc <$> pp p t

-- | This version has the type expected by various modules in
-- Verifier/SAW/Typechecker, but it does not properly display nested
-- tuples or records.
ppFlatTermF :: Applicative f => PPOpts -> (Prec -> t -> f Doc) -> Prec -> FlatTermF t -> f Doc
ppFlatTermF opts pp prec tf = fmap ppTermDoc (ppFlatTermF' opts pp' prec tf)
  where pp' p t = fmap TermDoc (pp p t)

newtype Term = Term (TermF Term)
  deriving (Eq)

instance Termlike Term where
  unwrapTermF (Term tf) = tf

{-
asApp :: Term -> (Term, [Term])
asApp = go []
  where go l (Term (FTermF (App t u))) = go (u:l) t
        go l t = (t,l)
-}

-- | Returns the number of nested pi expressions.
piArgCount :: Term -> Int
piArgCount = go 0
  where go i (Term (Pi _ _ rhs)) = go (i+1) rhs
        go i _ = i

bitwiseOrOf :: (Bits a, Num a) => Fold s a -> s -> a
bitwiseOrOf fld = foldlOf' fld (.|.) 0

-- | A @BitSet@ represents a set of natural numbers.
-- Bit n is a 1 iff n is in the set.
type BitSet = Integer

freesPat :: Pat BitSet -> BitSet
freesPat p0 =
  case p0 of
    PVar  _ i tp -> tp `shiftR` i
    PUnused i tp -> tp `shiftR` i
    PUnit        -> 0
    PPair x y    -> freesPat x .|. freesPat y
    PEmpty       -> 0
    PField _ x y -> freesPat x .|. freesPat y
    PCtor _ pl   -> bitwiseOrOf folded (freesPat <$> pl)
    PString _    -> 0

freesDefEqn :: DefEqn BitSet -> BitSet
freesDefEqn (DefEqn pl rhs) =
    bitwiseOrOf folded (freesPat <$> pl) .|. rhs `shiftR` pc
  where pc = sum (patBoundVarCount <$> pl) 

freesTermF :: TermF BitSet -> BitSet
freesTermF tf =
    case tf of
      FTermF ftf -> bitwiseOrOf folded ftf
      App l r -> l .|. r
      Lambda _name tp rhs -> tp .|. rhs `shiftR` 1
      Pi _name lhs rhs -> lhs .|. rhs `shiftR` 1
      Let lcls rhs ->
          bitwiseOrOf (folded . folded) lcls' .|. rhs `shiftR` n
        where n = length lcls
              freesLocalDef :: LocalDef BitSet -> [BitSet]
              freesLocalDef (Def _ _ tp eqs) = 
                tp : fmap ((`shiftR` n) . freesDefEqn) eqs
              lcls' = freesLocalDef <$> lcls
      LocalVar i -> bit i
      Constant _ _ _ -> 0 -- assume rhs is a closed term

freesTerm :: Term -> BitSet
freesTerm (Term t) = freesTermF (fmap freesTerm t)

-- | @instantiateVars f l t@ substitutes each dangling bound variable
-- @LocalVar j t@ with the term @f i j t@, where @i@ is the number of
-- binders surrounding @LocalVar j t@.
instantiateVars :: (DeBruijnIndex -> DeBruijnIndex -> Term)
                -> DeBruijnIndex -> Term -> Term
instantiateVars f initialLevel = go initialLevel
  where goList :: DeBruijnIndex -> [Term] -> [Term]
        goList _ []  = []
        goList l (e:r) = go l e : goList (l+1) r

        gof l ftf =
          case ftf of
            PairValue x y -> PairValue (go l x) (go l y)
            PairType a b  -> PairType (go l a) (go l b)
            PairLeft x    -> PairLeft (go l x)
            PairRight x   -> PairRight (go l x)
            FieldValue fld x y   -> FieldValue fld (go l x) (go l y)
            FieldType fld x y    -> FieldType fld (go l x) (go l y)
            RecordSelector x fld -> RecordSelector (go l x) fld
            CtorApp c ll      -> CtorApp c (goList l ll)
            DataTypeApp dt ll -> DataTypeApp dt (goList l ll)
            _ -> ftf
        go :: DeBruijnIndex -> Term -> Term
        go l (Term tf) =
          case tf of
            FTermF ftf ->  Term $ FTermF $ gof l ftf
            App x y         -> Term $ App (go l x) (go l y)
            Constant _ _rhs _ -> Term tf -- assume rhs is a closed term, so leave it unchanged
            Lambda i tp rhs -> Term $ Lambda i (go l tp) (go (l+1) rhs)
            Pi i lhs rhs    -> Term $ Pi i (go l lhs) (go (l+1) rhs)
            Let defs r      -> Term $ Let (procDef <$> defs) (go l' r)
              where l' = l + length defs
                    procDef (Def sym qual tp eqs) = Def sym qual tp' eqs'
                      where tp' = go l tp
                            eqs' = procEq <$> eqs
                    procEq (DefEqn pats rhs) = DefEqn pats (go eql rhs)
                      where eql = l' + sum (patBoundVarCount <$> pats)
            LocalVar i
              | i < l -> Term $ LocalVar i
              | otherwise -> f l i

-- | @incVars j k t@ increments free variables at least @j@ by @k@.
-- e.g., incVars 1 2 (C ?0 ?1) = C ?0 ?3
incVars :: DeBruijnIndex -> DeBruijnIndex -> Term -> Term
incVars _ 0 = id
incVars initialLevel j = assert (j > 0) $ instantiateVars fn initialLevel
  where fn _ i = Term $ LocalVar (i+j)

-- | Substitute @ts@ for variables @[k .. k + length ts - 1]@ and
-- decrement all higher loose variables by @length ts@.
instantiateVarList :: DeBruijnIndex -> [Term] -> Term -> Term
instantiateVarList _ [] = id
instantiateVarList k ts = instantiateVars fn 0
  where
    l = length ts
    -- Use terms to memoize instantiated versions of ts.
    terms = [ [ incVars 0 i t | i <- [0..] ] | t <- ts ]
    -- Instantiate variables [k .. k+l-1].
    fn i j | j >= i + k + l = Term $ LocalVar (j - l)
           | j >= i + k     = (terms !! (j - i - k)) !! i
           | otherwise      = Term $ LocalVar j
-- ^ Specification in terms of @instantiateVar@ (by example):
-- @instantiateVarList 0 [x,y,z] t@ is the beta-reduced form of @Lam
-- (Lam (Lam t)) `App` z `App` y `App` x@, i.e. @instantiateVarList 0
-- [x,y,z] t == instantiateVar 0 x (instantiateVar 1 (incVars 0 1 y)
-- (instantiateVar 2 (incVars 0 2 z) t))@.

{-
-- | Substitute @t@ for variable 0 in @s@ and decrement all remaining
-- variables.
betaReduce :: Term -> Term -> Term
betaReduce s t = instantiateVar 0 t s
-}

-- | Pretty print a term with the given outer precedence.
ppTerm :: PPOpts -> TermPrinter Term
ppTerm opts lcls0 p0 trm = ppTermDoc (pp lcls0 p0 trm)
  where
    pp :: LocalVarDoc -> Prec -> Term -> TermDoc
    pp lcls p (Term t) = ppTermF opts pp lcls p t

ppTermF :: PPOpts -> (LocalVarDoc -> Prec -> t -> TermDoc)
        -> LocalVarDoc -> Prec -> TermF t -> TermDoc
ppTermF opts pp lcls p tf = runIdentity (ppTermF' opts pp' lcls p tf)
  where pp' l' p' t' = pure (pp l' p' t')

ppTermF' :: Applicative f
         => PPOpts
         -> (LocalVarDoc -> Prec -> e -> f TermDoc)
         -> LocalVarDoc
         -> Prec
         -> TermF e
         -> f TermDoc
ppTermF' opts pp lcls prec (FTermF tf) = ppFlatTermF' opts (pp lcls) prec tf
  --(group . nest 2) <$> (ppFlatTermF' (pp lcls) p tf)
ppTermF' _opts pp lcls prec (App l r) = ppApp <$> pp lcls PrecApp l <*> pp lcls PrecArg r
  where ppApp l' r' = TermDoc $ ppAppParens prec $ group $ hang 2 $
                      ppTermDoc l' Leijen.<$> ppTermDoc r'

ppTermF' _opts pp lcls p (Lambda name tp rhs) =
    ppLam
      <$> pp lcls  PrecLambda tp
      <*> pp lcls' PrecLambda rhs
  where ppLam tp' rhs' = TermDoc $
          ppParens (p > PrecLambda) $ group $ hang 2 $
            text "\\" <> parens (text name' <> doublecolon <> ppTermDoc tp')
              <+> text "->" Leijen.<$> ppTermDoc rhs'
        name' = freshVariant (docUsedMap lcls) name
        lcls' = consBinding lcls name'

ppTermF' _opts pp lcls p (Pi name tp rhs) = ppPi <$> lhs <*> pp lcls' PrecLambda rhs
  where ppPi lhs' rhs' = TermDoc $ ppParens (p > PrecLambda) $
                         lhs' <<$>> text "->" <+> ppTermDoc rhs'
        subDoc = align . group . nest 2 . ppTermDoc
        lhs | name == "_" = subDoc <$> pp lcls PrecApp tp
            | otherwise = ppArg <$> pp lcls PrecLambda tp
        ppArg tp' = parens (text name' <+> doublecolon <+> subDoc tp')
        name' = freshVariant (docUsedMap lcls) name
        lcls' = consBinding lcls name'

ppTermF' _opts pp lcls p (Let dl u) =
    ppLet <$> traverse (ppLocalDef pp' lcls lcls') dl
          <*> pp lcls' PrecNone u
  where ppLet dl' u' = TermDoc $
          ppParens (p > PrecNone) $
            text "let" <+> lbrace <+> align (vcat dl') <$$>
            indent 4 rbrace <$$>
            text " in" <+> ppTermDoc u'
        nms = concatMap localVarNames dl
        lcls' = foldl' consBinding lcls nms
        pp' a b c = ppTermDoc <$> pp a b c
ppTermF' _opts _pp lcls _p (LocalVar i)
--    | lcls^.docShowLocalTypes = pptc <$> pp lcls PrecLambda tp
    | otherwise = pure $ TermDoc d
  where d = lookupDoc lcls i
--        pptc tpd = ppParens (p > PrecNone)
--                            (d <> doublecolon <> tpd)
ppTermF' _ _ _ _ (Constant i _ _) = pure $ TermDoc $ text i

ppTermDepth :: forall t. Termlike t => PPOpts -> Int -> t -> Doc
ppTermDepth opts d0 = pp d0 emptyLocalVarDoc PrecNone
  where
    pp :: Int -> TermPrinter t
    pp d lcls p t = ppTermDoc (pp' d lcls p t)

    pp' :: Int -> LocalVarDoc -> Prec -> t -> TermDoc
    pp' 0 _ _ _ = TermDoc $ text "_"
    pp' d lcls p t = case unwrapTermF t of
      App t1 t2 -> TermDoc $
        ppAppParens p $ group $ hang 2 $
        (pp d lcls PrecApp t1) Leijen.<$>
        (pp (d-1) lcls PrecArg t2)
      tf ->
        ppTermF opts (pp' (d-1)) lcls p tf

instance Show Term where
  showsPrec _ t = shows $ ppTerm defaultPPOpts emptyLocalVarDoc PrecNone t

type TypedDataType = DataType Ident Term
type TypedCtor = Ctor Ident Term
type TypedDef = Def Term
type TypedDefEqn = DefEqn Term

data ModuleDecl = TypeDecl TypedDataType
                | DefDecl TypedDef

data Module = Module {
          moduleName    :: !ModuleName
        , _moduleImports :: !(Map ModuleName Module)
        , moduleTypeMap :: !(Map String TypedDataType)
        , moduleCtorMap :: !(Map String TypedCtor)
        , moduleDefMap  :: !(Map String TypedDef)
        , moduleRDecls   :: [ModuleDecl] -- ^ All declarations in reverse order they were added.
        }

moduleImports :: Simple Lens Module (Map ModuleName Module)
moduleImports = lens _moduleImports (\m v -> m { _moduleImports = v })

instance Show Module where
  show m = flip displayS "" $ renderPretty 0.8 80 $
             vcat $ concat $ fmap (map (<> line)) $
                   [ fmap ppImport (Map.keys (m^.moduleImports))
                   , fmap ppdecl   (moduleRDecls m)
                   ]
    where ppImport nm = text $ "import " ++ show nm
          ppdecl (TypeDecl d) = ppDataType (ppTerm defaultPPOpts) d
          ppdecl (DefDecl d) = ppDef defaultPPOpts emptyLocalVarDoc d

emptyModule :: ModuleName -> Module
emptyModule nm =
  Module { moduleName = nm
         , _moduleImports = Map.empty
         , moduleTypeMap = Map.empty
         , moduleCtorMap = Map.empty
         , moduleDefMap  = Map.empty
         , moduleRDecls = []
         }

findDataType :: Module -> Ident -> Maybe TypedDataType
findDataType m i = do
  m' <- findDeclaringModule m (identModule i)
  Map.lookup (identName i) (moduleTypeMap m')

-- | @insImport i m@ returns module obtained by importing @i@ into @m@.
insImport :: Module -> Module -> Module
insImport i = moduleImports . at (moduleName i) ?~ i

insDataType :: Module -> TypedDataType -> Module
insDataType m dt
    | identModule (dtName dt) == moduleName m =
        m { moduleTypeMap = Map.insert (identName (dtName dt)) dt (moduleTypeMap m)
          , moduleCtorMap = foldl' insCtor (moduleCtorMap m) (dtCtors dt)
          , moduleRDecls = TypeDecl dt : moduleRDecls m
          }
    | otherwise = internalError "insDataType given datatype from another module."
  where insCtor m' c = Map.insert (identName (ctorName c)) c m' 

-- | Data types defined in module.
moduleDataTypes :: Module -> [TypedDataType]
moduleDataTypes = Map.elems . moduleTypeMap

-- | Ctors defined in module.
moduleCtors :: Module -> [TypedCtor]
moduleCtors = Map.elems . moduleCtorMap

findDeclaringModule :: Module -> ModuleName -> Maybe Module
findDeclaringModule m nm
  | moduleName m == nm = Just m
  | otherwise = m^.moduleImports^.at nm

findCtor :: Module -> Ident -> Maybe TypedCtor
findCtor m i = do
  m' <- findDeclaringModule m (identModule i)
  Map.lookup (identName i) (moduleCtorMap m')

moduleDefs :: Module -> [TypedDef]
moduleDefs = Map.elems . moduleDefMap

allModuleDefs :: Module -> [TypedDef]
allModuleDefs m = concatMap moduleDefs (m : Map.elems (m^.moduleImports))

findDef :: Module -> Ident -> Maybe TypedDef
findDef m i = do
  m' <- findDeclaringModule m (identModule i)
  Map.lookup (identName i) (moduleDefMap m')

insDef :: Module -> Def Term -> Module
insDef m d
  | identModule (defIdent d) == moduleName m =
      m { moduleDefMap = Map.insert (identName (defIdent d)) d (moduleDefMap m)
        , moduleRDecls = DefDecl d : moduleRDecls m
        }
  | otherwise = internalError "insDef given def from another module."

moduleDecls :: Module -> [ModuleDecl]
moduleDecls = reverse . moduleRDecls

allModuleDecls :: Module -> [ModuleDecl]
allModuleDecls m = concatMap moduleDecls (m : Map.elems (m^.moduleImports))

modulePrimitives :: Module -> [TypedDef]
modulePrimitives m =
    [ def
    | DefDecl def <- moduleDecls m
    , defQualifier def == PrimQualifier
    ]

moduleAxioms :: Module -> [TypedDef]
moduleAxioms m =
    [ def
    | DefDecl def <- moduleDecls m
    , defQualifier def == AxiomQualifier
    ]

moduleActualDefs :: Module -> [TypedDef]
moduleActualDefs m =
    [ def
    | DefDecl def <- moduleDecls m
    , defQualifier def == NoQualifier
    ]

allModulePrimitives :: Module -> [TypedDef]
allModulePrimitives m =
    [ def
    | DefDecl def <- allModuleDecls m
    , defQualifier def == PrimQualifier
    ]

allModuleAxioms :: Module -> [TypedDef]
allModuleAxioms m =
    [ def
    | DefDecl def <- allModuleDecls m
    , defQualifier def == AxiomQualifier
    ]

allModuleActualDefs :: Module -> [TypedDef]
allModuleActualDefs m =
    [ def
    | DefDecl def <- allModuleDecls m
    , defQualifier def == NoQualifier
    ]
