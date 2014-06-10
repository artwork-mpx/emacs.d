{
module SystemFParser where

import SystemFTokens
import SystemFLexer
import SystemF

import Data.Maybe       (fromJust)

}

%name parseSF
%tokentype  { SystemFToken }
%error      { parseError }

%token

"/\\"  { TokenTLambda }
"\\"   { TokenLambda }
fix    { TokenFix }
","    { TokenComma }
"."    { TokenDot }
"->"   { TokenArrow }
":"    { TokenColon }
let    { TokenLet }
"="    { TokenEQ }
in     { TokenIn }
"("    { TokenOParen }
")"    { TokenCParen }
forall { TokenForall }
Int    { TokenIntType }
var    { TokenLowId $$ }
tvar   { TokenUpId $$ }
int    { TokenInt $$ }
if0    { TokenIf0 }
then   { TokenThen }
else   { TokenElse }
primOp { TokenPrimOp $$ }
tupleField { TokenTupleField $$ }

%left "->"
%nonassoc "else"

%%

Exp : var  { \(tenv, env) -> FVar (fromJust (lookup $1 env)) }
    | "/\\" tvar "." Exp  { \(tenv, env) -> FBLam (\a -> $4 (($2, a):tenv, env)) }
    | "\\" "(" var ":" Typ ")" "." Exp  
        { \(tenv, env) -> FLam ($5 tenv) (\x -> $8 (tenv, ($3, x):env)) }
    | Exp Exp  { \(tenv, env) -> FApp  ($1 (tenv, env)) ($2 (tenv, env)) }
    -- let x = e : T in f  rewrites to  (\(x : T) . f) e
    | let var "=" Exp ":" Typ in Exp  
        { \(tenv, env) -> FApp (FLam ($6 tenv) (\x -> $8 (tenv, ($2, x):env))) ($4 (tenv, env)) }
    | Exp Typ  { \(tenv, env) -> FTApp ($1 (tenv, env)) ($2 tenv) }
    | Exp primOp Exp  { \e -> FPrimOp ($1 e) $2 ($3 e) }
    | int  { \_e -> FLit $1 }
    | if0 Exp then Exp else Exp  { \e -> Fif0 ($2 e) ($4 e) ($6 e) }
    | "(" Exps ")"  { \(tenv, env) -> FTuple ($2 (tenv, env)) }
    | Exp "." tupleField { \e -> FProj $3 ($1 e) } 
    | fix var "." "\\" "(" var ":" Typ ")" "." Exp ":" Typ 
        { \(tenv, env) -> 
            FFix ($8 tenv) (\y -> \x -> $11 (tenv, ($6, x):($2, y):env)) ($13 tenv) 
        }
    | "(" Exp ")"  { $2 }

Exps : Exp "," Exp   { \(tenv, env) -> ($1 (tenv, env):[$3 (tenv, env)]) }
     | Exp "," Exps  { \(tenv, env) -> ($1 (tenv, env):$3 (tenv, env)) }

-- data PFTyp t = FTVar t | FForall (t -> PFTyp t) | FFun (PFTyp t) (PFTyp t) | PFInt
Typ : tvar                 { \tenv -> FTVar (fromJust (lookup $1 tenv)) }
    | forall tvar "." Typ  { \tenv -> FForall (\a -> $4 (($2, a):tenv)) }
    | Typ "->" Typ  { \tenv -> FFun ($1 tenv) ($3 tenv) }
    | Int           { \_    -> PFInt }
    | "(" Typ ")"   { $2 }

{
parseError :: [SystemFToken] -> a
parseError tokens = error $ "Parse error before tokens:\n\t" ++ show tokens

readSF :: String -> PFExp t e
readSF = (\parser -> parser emptyEnvs) . parseSF . lexSF
    where emptyEnvs = ([], [])

}