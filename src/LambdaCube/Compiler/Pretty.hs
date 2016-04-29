{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ExistentialQuantification #-}
module LambdaCube.Compiler.Pretty
    ( module LambdaCube.Compiler.Pretty
    ) where

import Data.Monoid
import Data.String
import Data.Char
--import qualified Data.Set as Set
--import qualified Data.Map as Map
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State
import Control.Arrow hiding ((<+>))
import Control.DeepSeq
--import Debug.Trace

import qualified Text.PrettyPrint.ANSI.Leijen as P

import LambdaCube.Compiler.Utils

-------------------------------------------------------------------------------- fixity

data Fixity
    = Infix  !Int
    | InfixL !Int
    | InfixR !Int
    deriving (Eq, Show)

instance PShow Fixity where
    pShow = \case
        Infix  i -> "infix"  `DApp` pShow i
        InfixL i -> "infixl" `DApp` pShow i
        InfixR i -> "infixr" `DApp` pShow i

precedence, leftPrecedence, rightPrecedence :: Fixity -> Int

precedence = \case
    Infix i  -> i
    InfixR i -> i
    InfixL i -> i

leftPrecedence (InfixL i) = i
leftPrecedence f = precedence f + 1

rightPrecedence (InfixR i) = i
rightPrecedence f = precedence f + 1

-------------------------------------------------------------------------------- doc data type

data Doc
    = forall f . Traversable f => DDocOp (f P.Doc -> P.Doc) (f Doc)
    | DFormat (P.Doc -> P.Doc) Doc

    | DAtom DocAtom
    | DInfix Fixity Doc DocAtom Doc

    | DFreshName Bool{-used-} Doc
    | DVar Int
    | DUp Int Doc

    | DExpand Doc Doc

data DocAtom
    = SimpleAtom String
    | ComplexAtom String Int Doc DocAtom

mapDocAtom f (SimpleAtom s) = SimpleAtom s
mapDocAtom f (ComplexAtom s i d a) = ComplexAtom s i (f s i d) $ mapDocAtom f a

instance IsString Doc where
    fromString = text

text = DText
pattern DText s = DAtom (SimpleAtom s)

instance Monoid Doc where
    mempty = text ""
    mappend = dTwo mappend

instance NFData Doc where
    rnf x = rnf $ show x    -- TODO

strip :: Doc -> Doc
strip = \case
    DFormat _ x    -> strip x
    DUp _ x        -> strip x
    DFreshName _ x -> strip x
    x              -> x

simple :: Doc -> Bool
simple x = case strip x of
    DAtom{} -> True
    DVar{} -> True
    _ -> False

instance Show Doc where
    show = show . renderDoc

plainShow :: PShow a => a -> String
plainShow = show . P.plain . renderDoc . pShow

renderDoc :: Doc -> P.Doc
renderDoc
    = render
    . addPar (-10)
    . flip runReader ((\s n -> '_': n: s) <$> iterate ('\'':) "" <*> ['a'..'z'])
    . flip evalStateT (flip (:) <$> iterate ('\'':) "" <*> ['a'..'z'])
    . showVars
    . expand True
  where
    noexpand = expand False
    expand full = \case
        DExpand short long -> expand full $ if full then long else short
        DFormat c x -> DFormat c $ expand full x
        DDocOp x d -> DDocOp x $ expand full <$> d
        DAtom s -> DAtom $ mapDocAtom (\_ _ -> noexpand) s
        DInfix pr x op y -> DInfix pr (noexpand x) (mapDocAtom (\_ _ -> noexpand) op) (noexpand y)
        DVar i -> DVar i
        DFreshName b x -> DFreshName b $ noexpand x
        DUp i x -> DUp i $ noexpand x

    showVars = \case
        DAtom s -> DAtom <$> showVarA s
        DFormat c x -> DFormat c <$> showVars x
        DDocOp x d -> DDocOp x <$> traverse showVars d
        DInfix pr x op y -> DInfix pr <$> showVars x <*> showVarA op <*> showVars y
        DVar i -> asks $ text . (!! i)
        DFreshName True x -> gets head >>= \n -> modify tail >> local (n:) (showVars x)
        DFreshName False x -> local ("_":) $ showVars x
        DUp i x -> local (dropIndex i) $ showVars x
      where
        showVarA (SimpleAtom s) = pure $ SimpleAtom s
        showVarA (ComplexAtom s i d a) = ComplexAtom s i <$> showVars d <*> showVarA a

    addPar :: Int -> Doc -> Doc
    addPar pr x = case x of
        DAtom x -> DAtom $ addParA x
        DInfix pr' x op y -> (if protect then DParen else id)
                       $ DInfix pr' (addPar (leftPrecedence pr') x) (addParA op) (addPar (rightPrecedence pr') y)
        DFormat c x -> DFormat c $ addPar pr x
        DDocOp x d -> DDocOp x $ addPar (-10) <$> d
      where
        addParA = mapDocAtom (\_ -> addPar)

        protect = case x of
            DInfix f _ _ _ -> precedence f < pr
            _ -> False

    render :: Doc -> P.Doc
    render = snd . render'
      where
        render' = \case
            DFormat c x -> second c $ render' x
            DDocOp f d -> (('\0', '\0'), f $ render <$> d)
            DAtom x -> renderA x
            DInfix _ x op y -> render' x <++> renderA op <++> render' y

        renderA (SimpleAtom s) = rtext s
        renderA (ComplexAtom s _ d a) = rtext s <++> render' d <++> renderA a

        rtext "" = (('\0', '\0'), mempty)
        rtext s@(h:_) = ((h, last s), P.text s)

        ((lx, rx), x) <++> ((ly, ry), y) = ((lx, ry), z)
          where
            z | sep rx ly = x P.<+> y
              | otherwise = x P.<> y

        sep x y
            | x == '\0' || y == '\0' = False
            | isSpace x || isSpace y = False
            | y == ',' = False
            | x == ',' = True
            | x == '\\' && (isOpen y || isAlph y) = False
            | isOpen x = False
            | isClose y = False
            | otherwise = True
          where
            isAlph c = isAlphaNum c || c `elem` ("'_" :: String)
            isOpen c = c `elem` ("({[" :: String)
            isClose c = c `elem` (")}]" :: String)

-------------------------------------------------------------------------- combinators

-- add wl-pprint combinators as necessary here
red         = DFormat P.dullred
green       = DFormat P.dullgreen
blue        = DFormat P.dullblue
onred       = DFormat P.ondullred
ongreen     = DFormat P.ondullgreen
onblue      = DFormat P.ondullblue
underline   = DFormat P.underline

-- add wl-pprint combinators as necessary here
(<+>)  = dTwo (P.<+>)
(</>)  = dTwo (P.</>)
(<$$>) = dTwo (P.<$$>)
nest n = dOne (P.nest n)
tupled = dList P.tupled
hsep   = dList P.hsep
vcat   = dList P.vcat

dOne f     = DDocOp (f . runIdentity) . Identity
dTwo f x y = DDocOp (\(Two x y) -> f x y) (Two x y)
dList f    = DDocOp f

data Two a = Two a a
    deriving (Functor, Foldable, Traversable)

bracketed [] = text "[]"
bracketed xs = DPar "[" (foldr1 DComma xs) "]"

shVar = DVar

shortForm d = DPar "" d ""
expand = DExpand

pattern DPar l d r = DAtom (ComplexAtom l (-20) d (SimpleAtom r))
pattern DParen x = DPar "(" x ")"
pattern DBrace x = DPar "{" x "}"
pattern DOp s f l r = DInfix f l (SimpleAtom s) r
pattern DSep p a b = DOp " " p a b
pattern DGlue p a b = DOp "" p a b

pattern DArr_ s x y = DOp s (InfixR (-1)) x y
pattern DArr x y = DArr_ "->" x y
pattern DAnn x y = DOp "::" (InfixR (-3)) x y
pattern DApp x y = DSep (InfixL 10) x y
pattern DComma a b = DOp "," (InfixR (-20)) a b

braces = DBrace
parens = DParen

shTuple [] = "()"
shTuple [x] = DParen $ DParen x
shTuple xs = DParen $ foldr1 DComma xs

shLet i a b = shLam' (shLet' (blue $ shVar i) $ DUp i a) (DUp i b)
shLet_ a b = DFreshName True $ shLam' (shLet' (shVar 0) $ DUp 0 a) b
shLet' = DOp ":=" (Infix (-4))

shAnn True x (strip -> DText "Type") = x
shAnn _ x y = DOp "::" (InfixR (-3)) x y

shArr = DArr

shCstr = DOp "~" (Infix (-2))

pattern DForall vs e = DArr_ "." (DSep (Infix 10) (DText "forall") vs) e
pattern DContext vs e = DArr_ "=>" vs e
pattern DParContext vs e = DContext (DParen vs) e
pattern DLam vs e = DSep (InfixR (-10)) (DAtom (ComplexAtom "\\" 11 vs (SimpleAtom "->"))) e

shLam' x (DFreshName True d) = DFreshName True $ shLam' (DUp 0 x) d
shLam' x (DLam xs y) = DLam (DSep (InfixR 11) x xs) y
shLam' x y = DLam x y

showForall x (DFreshName u d) = DFreshName u $ showForall (DUp 0 x) d
showForall x (DForall xs y) = DForall (DSep (InfixR 11) x xs) y
showForall x y = DForall x y

showContext x (DFreshName u d) = DFreshName u $ showContext (DUp 0 x) d
showContext x (DParContext xs y) = DParContext (DComma x xs) y
showContext x (DContext xs y) = DParContext (DComma x xs) y
showContext x y = DContext x y

--------------------------------------------------------------------------------

class PShow a where
    pShow :: a -> Doc

ppShow :: PShow a => a -> String
ppShow = show . pShow

instance PShow Doc     where pShow = id
instance PShow Int     where pShow = fromString . show
instance PShow Integer where pShow = fromString . show
instance PShow Double  where pShow = fromString . show
instance PShow Char    where pShow = fromString . show
instance PShow ()      where pShow _ = "()"

instance PShow Bool where
    pShow b = if b then "True" else "False"

instance (PShow a, PShow b) => PShow (Either a b) where
   pShow = either (("Left" `DApp`) . pShow) (("Right" `DApp`) . pShow)

instance (PShow a, PShow b) => PShow (a, b) where
    pShow (a, b) = tupled [pShow a, pShow b]

instance (PShow a, PShow b, PShow c) => PShow (a, b, c) where
    pShow (a, b, c) = tupled [pShow a, pShow b, pShow c]

instance PShow a => PShow [a] where
    pShow = bracketed . map pShow

instance PShow a => PShow (Maybe a) where
    pShow = maybe "Nothing" (("Just" `DApp`) . pShow)

--instance PShow a => PShow (Set a) where
--    pShow = pShow . Set.toList

--instance (PShow s, PShow a) => PShow (Map s a) where
--    pShow = braces . vcat . map (\(k, t) -> pShow k <> P.colon <+> pShow t) . Map.toList

