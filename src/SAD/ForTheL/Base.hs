{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

FoTheL state and state management, parsing of primitives, operations on
variables and macro expressions.
-}



module SAD.ForTheL.Base where

import Control.Applicative
import Control.Monad
import qualified Control.Monad.State.Class as MS
import Data.Char
import Data.List

import SAD.Data.Formula

import SAD.Parser.Base
import SAD.Parser.Combinators
import SAD.Parser.Primitives

import SAD.Core.SourcePos

import SAD.Data.Text.Decl (Decl(Decl))
import qualified SAD.Data.Text.Decl as Decl

import SAD.Core.Message (PIDE)
import qualified SAD.Core.Message as Message

type FTL = Parser FState


type UTerm   = (Formula -> Formula, Formula)

type UNotion = (Formula -> Formula, Formula, VarName)

type MTerm   = (Formula -> Formula, [Formula])
type MNotion = (Formula -> Formula, Formula, [VarName])

type Prim    = ([Patt], [Formula] -> Formula)

type VarName = (String, SourcePos)


data FState = FState {
  adjExpr, verExpr, ntnExpr, sntExpr :: [Prim],
  cfnExpr, rfnExpr, lfnExpr, ifnExpr :: [Prim],
  cprExpr, rprExpr, lprExpr, iprExpr :: [Prim],

  tvrExpr :: [TVar], strSyms :: [[String]], varDecl :: [String],
  idCount :: Int, hiddenCount :: Int, serialCounter :: Int,
  reports :: [Message.Report], pide :: Maybe PIDE }


initFS :: Maybe PIDE -> FState
initFS = FState
  eq [] nt sn
  cf rf [] []
  [] [] [] sp
  [] [] []
  0 0 0 []
  where
    eq = [
      ([Wd ["equal"], Wd ["to"], Vr], zTrm (-1) "="),
      ([Wd ["nonequal"], Wd ["to"], Vr], Not . zTrm (-1) "=") ]
    sp = [ 
      ([Sm "="], zTrm (-1) "="),
      ([Sm "!", Sm "="], Not . zTrm (-1) "="),
      ([Sm "-", Sm "<", Sm "-"], zTrm (-2) "iLess"),
      ([Sm "-~-"], \(m:n:_) -> zAll "" $
        Iff (zElem (zVar "") m) (zElem (zVar "") n)) ]
    sn = [ ([Sm "=", Vr], zTrm (-1) "=") ]
    nt = [
      ([Wd ["function","functions"], Nm], zFun . head),
      ([Wd ["set","sets"], Nm], zSet . head),
      ([Wd ["element", "elements"], Nm, Wd ["of"], Vr], \(x:m:_) -> zElem x m),
      ([Wd ["object", "objects"], Nm], zObj . head)]
    rf = [ ([Sm "[", Vr, Sm "]"], \(f:x:_) -> zApp f x)]
    cf = [
      ([Sm "Dom", Sm "(",Vr,Sm ")"], zDom . head),
      ([Sm "(", Vr, Sm ",", Vr, Sm ")"], \(x:y:_) -> zPair x y) ]




getExpr :: (FState -> [a]) -> (a -> FTL b) -> FTL b
getExpr e p = MS.gets e >>=  foldr ((-|-) . try . p ) mzero


getDecl :: FTL [String]
getDecl = MS.gets varDecl

addDecl :: [String] -> FTL a -> FTL a
addDecl vs p = do
  dcl <- MS.gets varDecl; MS.modify adv;
  after p $ MS.modify $ sbv dcl
  where
    adv s = s { varDecl = vs ++ varDecl s }
    sbv vs s = s { varDecl = vs }

getPretyped :: FTL [TVar]
getPretyped = MS.gets tvrExpr

makeDecl :: VarName -> FTL Decl
makeDecl (nm, pos) = do
  serial <- MS.gets serialCounter
  MS.modify (\st -> st {serialCounter = serial + 1})
  return $ Decl nm pos (serial + 1)

declared :: FTL MNotion -> FTL (Formula -> Formula, Formula, [Decl])
declared p = do (q, f, v) <- p; nv <- mapM makeDecl v; return (q, f, nv)

-- Predicates: verbs and adjectives

primVer, primAdj, primUnAdj :: FTL UTerm -> FTL UTerm

primVer = getExpr verExpr . primPrd
primAdj = getExpr adjExpr . primPrd
primUnAdj = getExpr (filter (unary . fst) . adjExpr) . primPrd
  where
    unary pt = Vr `notElem` pt

primPrd :: Parser st (b1 -> b1, Formula)
           -> ([Patt], [Formula] -> b2) -> Parser st (b1 -> b1, b2)
primPrd p (pt, fm) = do 
  (q, ts) <- wdPatt p pt
  return (q, fm $ zHole:ts)


-- Multi-subject predicates: [a,b are] equal

primMultiVer, primMultiAdj, primMultiUnAdj :: FTL UTerm -> FTL UTerm

primMultiVer = getExpr verExpr . prim_ml_prd
primMultiAdj = getExpr adjExpr . prim_ml_prd
primMultiUnAdj = getExpr (filter (unary . fst) . adjExpr) . prim_ml_prd
  where
    unary (Vr : pt) = Vr `notElem` pt
    unary (_  : pt) = unary pt
    unary _ = True

prim_ml_prd :: Parser st (b1 -> b1, Formula)
               -> ([Patt], [Formula] -> b2) -> Parser st (b1 -> b1, b2)
prim_ml_prd p (pt, fm) = do
  (q, ts) <- mlPatt p pt
  return (q, fm $ zHole:zSlot:ts)


-- Notions and functions

primNtn, primOfNtn :: FTL UTerm -> FTL MNotion

primNtn p  = getExpr ntnExpr ntn
  where
    ntn (pt, fm) = do
      (q, vs, ts) <- ntPatt p pt
      return (q, fm $ zHole:ts, vs)

primOfNtn p = getExpr ntnExpr ntn
  where
    ntn (pt, fm) = do
      (q, vs, ts) <- ofPatt p pt
      let fn v = fm $ (pVar v):zHole:ts
      return (q, foldr1 And $ map fn vs, vs)

primCmNtn :: FTL UTerm -> FTL MTerm -> FTL MNotion
primCmNtn p s = getExpr ntnExpr ntn
  where
    ntn (pt, fm) = do
      (q, vs, as, ts) <- cmPatt p s pt
      let fn v = fm $ zHole:v:ts
      return (q, foldr1 And $ map fn as, vs)

primFun :: FTL UTerm -> FTL UTerm
primFun  = (>>= fun) . primNtn
  where
    fun (q, Trm {trName = "=", trArgs = [_, t]}, _)
      | not (occursH t) = return (q, t)
    fun _ = mzero


-- Symbolic primitives

primCpr :: Parser FState Formula -> FTL Formula
primCpr = getExpr cprExpr . primCsm
primRpr :: Parser FState Formula -> FTL (Formula -> Formula)
primRpr = getExpr rprExpr . primRsm
primLpr :: Parser FState Formula -> FTL (Formula -> Formula)
primLpr = getExpr lprExpr . primLsm
primIpr :: Parser FState Formula
           -> FTL (Formula -> Formula -> Formula)
primIpr = getExpr iprExpr . primIsm

primCfn :: Parser FState Formula -> FTL Formula
primCfn = getExpr cfnExpr . primCsm
primRfn :: Parser FState Formula -> FTL (Formula -> Formula)
primRfn = getExpr rfnExpr . primRsm
primLfn :: Parser FState Formula -> FTL (Formula -> Formula)
primLfn = getExpr lfnExpr . primLsm
primIfn :: Parser FState Formula
           -> FTL (Formula -> Formula -> Formula)
primIfn = getExpr ifnExpr . primIsm

primCsm :: Parser st a -> ([Patt], [a] -> b) -> Parser st b
primCsm p (pt, fm) = smPatt p pt >>= \l -> return $ fm l
primRsm :: Parser st a -> ([Patt], [a] -> t) -> Parser st (a -> t)
primRsm p (pt, fm) = smPatt p pt >>= \l -> return $ \t -> fm $ t:l
primLsm :: Parser st a -> ([Patt], [a] -> t) -> Parser st (a -> t)
primLsm p (pt, fm) = smPatt p pt >>= \l -> return $ \s -> fm $ l++[s]
primIsm :: Parser st a
           -> ([Patt], [a] -> t) -> Parser st (a -> a -> t)
primIsm p (pt, fm) = smPatt p pt >>= \l -> return $ \t s -> fm $ t:l++[s]


primSnt :: FTL Formula -> FTL MNotion
primSnt p  = noError $ varlist >>= getExpr sntExpr . snt
  where
    snt vs (pt, fm) = smPatt p pt >>= \l -> return (id, fm $ zHole:l, vs)




data Patt = Wd [String] | Sm String | Vr | Nm deriving (Eq, Show)

-- | DANGER: Not symmetric on `Wd`
samePat :: [Patt] -> [Patt] -> Bool
samePat [] [] = True
samePat (x:xs) (y:ys) = samePat1 x y && samePat xs ys
  where
    samePat1 (Wd ls) (Wd rs) = all (`elem` rs) ls
    samePat1 Vr Vr = True
    samePat1 Nm Nm = True
    samePat1 (Sm s) (Sm t) = s == t
    samePat1 _ _ = False
samePat _ _ = False


-- adding error reporting to pattern parsing
patternWdTokenOf :: [String] -> Parser st ()
patternWdTokenOf l = label ("a word of " ++ show l) $ wdTokenOf l
patternSmTokenOf :: [Char] -> Parser st ()
patternSmTokenOf l = label ("the symbol " ++ show l) $ smTokenOf l

-- most basic pattern parser: simply follow the pattern and parse terms with p
-- at variable places
wdPatt :: Parser st (b -> b, a) -> [Patt] -> Parser st (b-> b, [a])
wdPatt p (Wd l : ls) = patternWdTokenOf l >> wdPatt p ls
wdPatt p (Vr : ls) = do
  (r, t) <- p
  (q, ts) <- wdPatt p ls
  return (r . q, t:ts)
wdPatt _ [] = return (id, [])
wdPatt _ _ = mzero

-- parses a symbolic pattern
smPatt :: Parser st a -> [Patt] -> Parser st [a]
smPatt p (Vr : ls) = liftM2 (:) p $ smPatt p ls
smPatt p (Sm s : ls) = patternSmTokenOf s >> smPatt p ls
smPatt _ [] = return []
smPatt _ _ = mzero

-- parses a multi-subject pattern: follow the pattern, but ignore the wdToken
-- right before the first variable. Then check that all "and" tokens have been
-- consumed. Example pattern: [Wd ["commute","commutes"], Wd ["with"], Vr]. Then
-- we can parse "a commutes with c and d" as well as "a and b commute".
mlPatt :: Parser st (b -> b, a) -> [Patt] -> Parser st (b -> b, [a])
mlPatt p (Wd l :_: Vr : ls) = patternWdTokenOf l >> naPatt p ls
mlPatt p (Wd l : ls) = patternWdTokenOf l >> mlPatt p ls
mlPatt _ _ = mzero


-- parses a notion: follow the pattern to the name place, record names,
-- then keep following the pattern
ntPatt :: Parser FState (b -> b, a)
          -> [Patt] -> Parser FState (b -> b, [([Char], SourcePos)], [a])
ntPatt p (Wd l : ls) = patternWdTokenOf l >> ntPatt p ls
ntPatt p (Nm : ls) = do
  vs <- namlist
  (q, ts) <- wdPatt p ls
  return (q, vs, ts)
ntPatt _ _ = mzero

-- parse an "of"-notion: follow the pattern to the notion name, then check that
-- "of" follows the name followed by a variable that is not followed by "and"
ofPatt :: Parser FState (b -> b, a)
          -> [Patt] -> Parser FState (b -> b, [([Char], SourcePos)], [a])
ofPatt p (Wd l : ls) = patternWdTokenOf l >> ofPatt p ls
ofPatt p (Nm : Wd l : Vr : ls) = do
  guard $ elem "of" l; vs <- namlist
  (q, ts) <- naPatt p ls
  return (q, vs, ts)
ofPatt _ _ = mzero

-- | parse a "common"-notion: basically like the above. We use the special parser
-- s for the first variable place after the "of" since we expect multiple terms
-- here. Example: A common *divisor of m and n*.
cmPatt :: Parser FState (b -> b, a1)
          -> Parser FState (b -> c, [a2])
          -> [Patt]
          -> Parser FState (b -> c, [([Char], SourcePos)], [a2], [a1])
cmPatt p s (Wd l:ls) = patternWdTokenOf l >> cmPatt p s ls
cmPatt p s (Nm : Wd l : Vr : ls) = do
  guard $ elem "of" l; vs <- namlist; patternWdTokenOf l
  (r, as) <- s
  when (null $ tail as) $ fail "several objects expected for `common'"
  (q, ts) <- naPatt p ls
  return (r . q, vs, as, ts)
cmPatt _ _ _ = mzero

-- an auxiliary pattern parser that checks that we are not dealing with an "and"
-- wdToken and then continues to follow the pattern
naPatt :: Parser st (b -> b, a)
          -> [Patt] -> Parser st (b -> b, [a])
naPatt p (Wd l : ls) = guard (notElem "and" l) >> patternWdTokenOf l >> wdPatt p ls
naPatt p ls = wdPatt p ls



-- Variables

namlist :: Parser FState [(String, SourcePos)]
namlist = varlist -|- fmap (:[]) hidden

varlist :: Parser st [(String, SourcePos)]
varlist = do
  vs <- var `sepBy` wdToken ","
  nodups $ map fst vs ; return vs

nodups :: [String] -> Parser st ()
nodups vs = unless ((null :: [b] -> Bool) $ duplicateNames vs) $
  fail $ "duplicate names: " ++ show vs

hidden :: Parser FState (String, SourcePos)
hidden = do
  n <- MS.gets hiddenCount
  MS.modify $ \st -> st {hiddenCount = succ n}
  return ('h':show n, noSourcePos)

var :: Parser st (String, SourcePos)
var = do
  pos <- getPos
  v <- satisfy (\s -> all isAlphaNum s && isAlpha (head s))
  return ('x':v, pos)

--- pretyped Variables

type TVar = ([String], Formula)

primTvr :: FTL MNotion
primTvr = getExpr tvrExpr tvr
  where
    tvr (vr, nt) = do
      vs <- varlist
      guard $ all (`elem` vr) $ map fst vs
      return (id, nt, vs)

-- free

freeVars :: Formula -> Parser FState [String]
freeVars f = do dvs <- getDecl; return $ free dvs f
freeVarPositions :: Formula -> Parser FState [(String, SourcePos)]
freeVarPositions f = do dvs <- getDecl; return $ freePositions dvs f

--- decl

{- produce the variables delcared by a formula together with their positions. As
parameter we pass the already known variables-}
decl :: [String] -> Formula -> [VarName]
decl vs = dive
  where
    dive (All _ f) = dive f
    dive (Exi _ f) = dive f
    dive (Tag _ f) = dive f
    dive (Imp f g) = filter (noc f) (dive g)
    dive (And f g) = dive f `varNameUnion` filter (noc f) (dive g)
    dive Trm {trName = 'a':_, trArgs = v@Var{trName = u@('x':_)}:ts}
      | all (not . occurs v) ts =
          guard (u `notElem` vs) >> return (u, trPosition v)
    dive Trm{trName = "=", trArgs = [v@Var{trName = u@('x':_)}, t]}
      | isTrm t && not (occurs v t) =
          guard (u `notElem` vs) >> return (u, trPosition v)
    dive _ = []

    noc f v = not $ occurs (pVar v) f
    varNameUnion = unionBy $ \a b -> fst a == fst b

{- produce variable names declared by a formula -}
declNames :: [String] -> Formula -> [String]
declNames vs = map fst . decl vs

{- produce the bindings in a formula in a Decl data type ant take care of
the serial counter. -}
bindings :: [String] -> Formula -> FTL [Decl]
bindings vs = mapM makeDecl . decl vs


overfree :: [String] -> Formula -> Maybe String
overfree vs f
    | occurs zSlot f = Just $ "too few subjects for an m-predicate " ++ inf
    | not (null sbs) = Just $ "free undeclared variables: "   ++ sbs ++ inf
    | not (null ovl) = Just $ "overlapped variables: "        ++ ovl ++ inf
    | otherwise      = Nothing
  where
    sbs = unwords $ map showVar $ free vs f
    ovl = unwords $ map showVar $ over vs f
    inf = "\n in translation: " ++ show f

    over vs (All v f) = bvrs vs (Decl.name v) f
    over vs (Exi v f) = bvrs vs (Decl.name v) f
    over vs f = foldF (over vs) f

    bvrs vs v f
      | elem v vs = [v]
      | null v    = over vs f
      | otherwise = over (v:vs) f


--- macro expressions


comma :: Parser st ()
comma = wdTokenOf [",", "and"]
is :: Parser st ()
is = wdTokenOf ["is", "be", "are"]
art :: Parser st ()
art = opt () $ wdTokenOf ["a","an","the"]
an :: Parser st ()
an = wdTokenOf ["a", "an"]
the :: Parser st ()
the = wdToken "the"
iff :: Parser st ()
iff = wdToken "iff" <|> mapM_ wdToken ["if", "and", "only", "if"]
that :: Parser st ()
that = wdToken "that"
standFor :: Parser st ()
standFor = wdToken "denote" <|> (wdToken "stand" >> wdToken "for")
arrow :: Parser st ()
arrow = symbol "->"
there :: Parser st ()
there = wdToken "there" >> wdTokenOf ["is","exist","exists"]
does :: Parser st ()
does = opt () $ wdTokenOf ["does", "do"]
has :: Parser st ()
has = wdTokenOf ["has" , "have"]
with :: Parser st ()
with = wdTokenOf ["with", "of", "having"]
such :: Parser st ()
such = wdTokenOf ["such", "so"]



--just for now:

showVar :: [Char] -> [Char]
showVar ('x':nm) = nm
showVar nm = nm
