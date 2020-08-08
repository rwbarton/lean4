/-
Copyright (c) 2020 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
import Lean.Util.CollectLevelParams
import Lean.Meta.Check
import Lean.Meta.Tactic.Cases
import Lean.Meta.GeneralizeTelescope
import Lean.Meta.EqnCompiler.MVarRenaming
import Lean.Meta.EqnCompiler.CaseValues
import Lean.Meta.EqnCompiler.CaseArraySizes

namespace Lean
namespace Meta
namespace DepElim

abbrev VarId := Name

inductive Pattern (internal : Bool := false) : Type
| inaccessible (ref : Syntax) (e : Expr) : Pattern
| var          (ref : Syntax) (varId : VarId) : Pattern
| ctor         (ref : Syntax) (ctorName : Name) (us : List Level) (params : List Expr) (fields : List Pattern) : Pattern
| val          (ref : Syntax) (e : Expr) : Pattern
| arrayLit     (ref : Syntax) (type : Expr) (xs : List Pattern) : Pattern
| as           (ref : Syntax) (varId : VarId) (p : Pattern) : Pattern

abbrev IPattern := Pattern true

namespace Pattern

instance {b} : Inhabited (Pattern b) := ⟨Pattern.inaccessible Syntax.missing (arbitrary _)⟩

def ref {b : Bool} : Pattern b → Syntax
| inaccessible r _ => r
| var r _          => r
| ctor r _ _ _ _   => r
| val r _          => r
| arrayLit r _ _   => r
| as r _ _         => r

partial def toMessageData {b : Bool} : Pattern b → MessageData
| inaccessible _ e         => ".(" ++ e ++ ")"
| var _ varId              => if b then mkMVar varId else mkFVar varId
| ctor _ ctorName _ _ []   => ctorName
| ctor _ ctorName _ _ pats => "(" ++ ctorName ++ pats.foldl (fun (msg : MessageData) pat => msg ++ " " ++ toMessageData pat) Format.nil ++ ")"
| val _ e                  => "val!(" ++ e ++ ")"
| arrayLit _ _ pats        => "#[" ++ MessageData.joinSep (pats.map toMessageData) ", " ++ "]"
| as _ varId p             => (if b then mkMVar varId else mkFVar varId) ++ "@" ++toMessageData p

partial def toExpr {b} : Pattern b → MetaM Expr
| inaccessible _ e                 => pure e
| var _ varId                      => if b then pure (mkMVar varId) else pure (mkFVar varId)
| val _ e                          => pure e
| as _ _ p                         => toExpr p
| arrayLit _ type xs               => do
  xs ← xs.mapM toExpr;
  mkArrayLit type xs
| ctor _ ctorName us params fields => do
  fields ← fields.mapM toExpr;
  pure $ mkAppN (mkConst ctorName us) (params ++ fields).toArray

/- Apply the free variable substitution `s` to the given (internal) pattern -/
partial def applyFVarSubst (s : FVarSubst) : Pattern true → IPattern
| inaccessible r e  => inaccessible r $ s.apply e
| ctor r n us ps fs => ctor r n us (ps.map s.apply) $ fs.map applyFVarSubst
| val r e           => val r $ s.apply e
| arrayLit r t xs   => arrayLit r (s.apply t) $ xs.map applyFVarSubst
| var r id          => var r id
| as r v p          => as r v $ applyFVarSubst p

partial def instantiateMVars : IPattern →  MetaM IPattern
| inaccessible r e  => inaccessible r <$> Meta.instantiateMVars e
| ctor r n us ps fs => ctor r n us <$> ps.mapM Meta.instantiateMVars <*> fs.mapM instantiateMVars
| val r e           => val r <$> Meta.instantiateMVars e
| arrayLit r t xs   => arrayLit r <$> Meta.instantiateMVars t <*> xs.mapM instantiateMVars
| var ref mvarId    => do
  mctx ← getMCtx;
  match mctx.getExprAssignment? mvarId with
  | some v => inaccessible ref <$> Meta.instantiateMVars v
  | none   => pure (var ref mvarId)
| as ref mvarId p   => do
  mctx ← getMCtx;
  match mctx.getExprAssignment? mvarId with
  | some v => instantiateMVars p
  | none   => as ref mvarId <$> instantiateMVars p

partial def applyMVarRenaming (m : MVarRenaming) : Pattern true → IPattern
| inaccessible r e  => inaccessible r $ m.apply e
| ctor r n us ps fs => ctor r n us (ps.map m.apply) $ fs.map applyMVarRenaming
| val r e           => val r $ m.apply e
| arrayLit r t xs   => arrayLit r (m.apply t) $ xs.map applyMVarRenaming
| var ref mvarId    =>
  match m.find? mvarId with
  | some newMVarId => var ref newMVarId
  | none           => var ref mvarId
| as ref mvarId p   =>
  match m.find? mvarId with
  | some newMVarId => as ref newMVarId $ applyMVarRenaming p
  | none           => as ref mvarId $ applyMVarRenaming p

partial def toIPattern (s : FVarSubst) : Pattern → IPattern
| inaccessible r e  => inaccessible r $ s.apply e
| ctor r n us ps fs => ctor r n us (ps.map s.apply) $ fs.map toIPattern
| val r e           => val r $ s.apply e
| arrayLit r t xs   => arrayLit r (s.apply t) $ xs.map toIPattern
| var ref fvarId    =>
  match s.get fvarId with
  | Expr.mvar mvarId _ => Pattern.var ref mvarId
  | _                  => unreachable!
| as ref fvarId p   =>
  match s.get fvarId with
  | Expr.mvar mvarId _ => Pattern.as ref mvarId $ toIPattern p
  | _                  => unreachable!

end Pattern

structure AltLHS :=
(fvarDecls : List LocalDecl) -- Free variables used in the patterns.
(patterns  : List Pattern)   -- We use `List Pattern` since we have nary match-expressions.

structure Alt :=
(idx       : Nat) -- for generating error messages
(rhs       : Expr)
(mvars     : List MVarId)
(patterns  : List IPattern)

namespace Alt

instance : Inhabited Alt := ⟨⟨0, arbitrary _, [], []⟩⟩

partial def toMessageData (alt : Alt) : MetaM MessageData := do
let msg : MessageData := alt.mvars.map mkMVar ++ " |- " ++ (alt.patterns.map Pattern.toMessageData) ++ " => " ++ alt.rhs;
addContext msg

private def convertMVar (s : FVarSubst) (m : MVarRenaming) (mvarId : MVarId) : MetaM (MVarRenaming × MVarId) :=
if s.isEmpty && m.isEmpty then pure (m, mvarId)
else do
  mvarDecl ← getMVarDecl mvarId;
  let mvarType0 := mvarDecl.type;
  mvarType0 ← instantiateMVars mvarType0;
  let mvarType := s.apply mvarType0;
  let mvarType := m.apply mvarType;
  let lctx := mvarDecl.lctx;
  if (s.any fun fvarId _ => lctx.contains fvarId) || mvarType != mvarType0 then do
    newMVar ← mkFreshExprMVar mvarType;
    let m := m.insert mvarId newMVar.mvarId!;
    pure (m, newMVar.mvarId!)
  else
    pure (m, mvarId)

private def convertMVars (s : FVarSubst) (mvars : List MVarId) : MetaM (MVarRenaming × List MVarId) := do
(m, mvars) ← mvars.foldlM
  (fun (acc : MVarRenaming × List MVarId) mvarId => do
    let (m, mvarIds) := acc;
    (m, mvarId') ← convertMVar s m mvarId;
    let m := if mvarId == mvarId' then m else m.insert mvarId mvarId';
    pure (m, mvarId'::mvarIds))
  ({}, []);
pure (m, mvars.reverse)

def applyFVarSubst (s : FVarSubst) (alt : Alt) : MetaM Alt := do
(m, mvars) ← convertMVars s alt.mvars;
let patterns := alt.patterns.map fun p => (p.applyFVarSubst s).applyMVarRenaming m;
let rhs      := m.apply $ s.apply alt.rhs;
pure { alt with patterns := patterns, mvars := mvars, rhs := rhs }

private def copyMVar (m : MVarRenaming) (mvarId : MVarId) : MetaM (MVarRenaming × MVarId) := do
mvarDecl ← getMVarDecl mvarId;
let mvarType := mvarDecl.type;
mvarType ← instantiateMVars mvarType;
let mvarType := m.apply mvarType;
newMVar ← mkFreshExprMVar mvarType;
let m := m.insert mvarId newMVar.mvarId!;
pure (m, newMVar.mvarId!)

private def copyMVars (mvars : List MVarId) : MetaM (MVarRenaming × List MVarId) := do
(m, mvars) ← mvars.foldlM
  (fun (acc : MVarRenaming × List MVarId) mvarId => do
    let (m, mvarIds) := acc;
    (m, mvarId) ← copyMVar m mvarId;
    pure (m, mvarId::mvarIds))
  ({}, []);
pure (m, mvars.reverse)

def copyCore (alt : Alt) : MetaM (MVarRenaming × Alt) := do
(m, mvars) ← copyMVars alt.mvars;
let patterns := alt.patterns.map fun p => p.applyMVarRenaming m;
let rhs      := m.apply alt.rhs;
pure (m, { alt with patterns := patterns, mvars := mvars, rhs := rhs })

/- Create a copy of the given alternative with fresh metavariables. -/
def copy (alt : Alt) : MetaM Alt := do
(m, alt) ← copyCore alt;
pure alt

end Alt

inductive Example
| var        : FVarId → Example
| underscore : Example
| ctor       : Name → List Example → Example
| val        : Expr → Example
| arrayLit   : List Example → Example

namespace Example

partial def replaceFVarId (fvarId : FVarId) (ex : Example) : Example → Example
| var x        => if x == fvarId then ex else var x
| ctor n exs   => ctor n $ exs.map replaceFVarId
| arrayLit exs => arrayLit $ exs.map replaceFVarId
| ex           => ex

partial def applyFVarSubst (s : FVarSubst) : Example → Example
| var fvarId =>
  match s.get fvarId with
  | Expr.fvar fvarId' _ => var fvarId'
  | _                   => underscore
| ctor n exs   => ctor n $ exs.map applyFVarSubst
| arrayLit exs => arrayLit $ exs.map applyFVarSubst
| ex           => ex

partial def varsToUnderscore : Example → Example
| var x        => underscore
| ctor n exs   => ctor n $ exs.map varsToUnderscore
| arrayLit exs => arrayLit $ exs.map varsToUnderscore
| ex           => ex

partial def toMessageData : Example → MessageData
| var fvarId        => mkFVar fvarId
| ctor ctorName []  => mkConst ctorName
| ctor ctorName exs => "(" ++ mkConst ctorName ++ exs.foldl (fun (msg : MessageData) pat => msg ++ " " ++ toMessageData pat) Format.nil ++ ")"
| arrayLit exs      => "#" ++ MessageData.ofList (exs.map toMessageData)
| val e             => e
| underscore        => "_"

end Example

def examplesToMessageData (cex : List Example) : MessageData :=
MessageData.joinSep (cex.map (Example.toMessageData ∘ Example.varsToUnderscore)) ", "

structure Problem :=
(mvarId        : MVarId)
(vars          : List Expr)
(alts          : List Alt)
(examples      : List Example)

def withGoalOf {α} (p : Problem) (x : MetaM α) : MetaM α :=
withMVarContext p.mvarId x

namespace Problem

instance : Inhabited Problem := ⟨{ mvarId := arbitrary _, vars := [], alts := [], examples := []}⟩

def toMessageData (p : Problem) : MetaM MessageData :=
withGoalOf p do
  alts ← p.alts.mapM Alt.toMessageData;
  pure $ "vars " ++ p.vars.toArray
    -- ++ Format.line ++ "var ids " ++ toString (p.vars.map (fun x => match x with | Expr.fvar id _ => toString id | _ => "[nonvar]"))
    ++ Format.line ++ MessageData.joinSep alts Format.line
    ++ Format.line ++ "examples: " ++ examplesToMessageData p.examples
    ++ Format.line
end Problem

abbrev CounterExample := List Example

def counterExampleToMessageData (cex : CounterExample) : MessageData :=
examplesToMessageData cex

def counterExamplesToMessageData (cexs : List CounterExample) : MessageData :=
MessageData.joinSep (cexs.map counterExampleToMessageData) Format.line

structure ElimResult :=
(elim            : Expr) -- The eliminator. It is not just `Expr.const elimName` because the type of the major premises may contain free variables.
(counterExamples : List CounterExample)
(unusedAltIdxs   : List Nat)

/- The number of patterns in each AltLHS must be equal to majors.length -/
private def checkNumPatterns (majors : List Expr) (lhss : List AltLHS) : MetaM Unit :=
let num := majors.length;
when (lhss.any (fun lhs => lhs.patterns.length != num)) $
  throwOther "incorrect number of patterns"

/-
 Given major premises `(x_1 : A_1) (x_2 : A_2[x_1]) ... (x_n : A_n[x_1, x_2, ...])`, return
 `forall (x_1 : A_1) (x_2 : A_2[x_1]) ... (x_n : A_n[x_1, x_2, ...]), sortv` -/
private def withMotive {α} (majors : Array Expr) (sortv : Expr) (k : Expr → MetaM α) : MetaM α := do
type ← mkForall majors sortv;
trace! `Meta.EqnCompiler.matchDebug ("motive: " ++ type);
withLocalDecl `motive type BinderInfo.default k

private def localDeclsToMVarsAux : List LocalDecl → List MVarId → FVarSubst → MetaM (List MVarId × FVarSubst)
| [],    mvars, s => pure (mvars.reverse, s)
| d::ds, mvars, s => do
  let type := s.apply d.type;
  mvar ← mkFreshExprMVar type;
  let s := s.insert d.fvarId mvar;
  localDeclsToMVarsAux ds (mvar.mvarId! :: mvars) s

private def localDeclsToMVars (fvarDecls : List LocalDecl) : MetaM (List MVarId × FVarSubst) :=
localDeclsToMVarsAux fvarDecls [] {}

private partial def withAltsAux {α} (motive : Expr) : List AltLHS → List Alt → Array Expr → (List Alt → Array Expr → MetaM α) → MetaM α
| [],        alts, minors, k => k alts.reverse minors
| lhs::lhss, alts, minors, k => do
  let xs := lhs.fvarDecls.toArray.map LocalDecl.toExpr;
  minorType ← withExistingLocalDecls lhs.fvarDecls do {
    args ← lhs.patterns.toArray.mapM Pattern.toExpr;
    let minorType := mkAppN motive args;
    mkForall xs minorType
  };
  let idx       := alts.length;
  let minorName := (`h).appendIndexAfter (idx+1);
  trace! `Meta.EqnCompiler.matchDebug ("minor premise " ++ minorName ++ " : " ++ minorType);
  withLocalDecl minorName minorType BinderInfo.default fun minor => do
    let rhs    := mkAppN minor xs;
    let minors := minors.push minor;
    (mvars, s) ← localDeclsToMVars lhs.fvarDecls;
    let patterns := lhs.patterns.map (fun p => p.toIPattern s);
    let rhs      := s.apply rhs;
    let alts   := { idx := idx, rhs := rhs, mvars := mvars, patterns := patterns : Alt } :: alts;
    withAltsAux lhss alts minors k

/- Given a list of `AltLHS`, create a minor premise for each one, convert them into `Alt`, and then execute `k` -/
private partial def withAlts {α} (motive : Expr) (lhss : List AltLHS) (k : List Alt → Array Expr → MetaM α) : MetaM α :=
withAltsAux motive lhss [] #[] k

def assignGoalOf (p : Problem) (e : Expr) : MetaM Unit :=
withGoalOf p (assignExprMVar p.mvarId e)

structure State :=
(used            : Std.HashSet Nat := {}) -- used alternatives
(counterExamples : List (List Example) := [])

/-- Return true if the given (sub-)problem has been solved. -/
private def isDone (p : Problem) : Bool :=
p.vars.isEmpty

/-- Return true if the next element on the `p.vars` list is a variable. -/
private def isNextVar (p : Problem) : Bool :=
match p.vars with
| Expr.fvar _ _ :: _ => true
| _                  => false

private def hasAsPattern (p : Problem) : Bool :=
p.alts.any fun alt => match alt.patterns with
  | Pattern.as _ _ _ :: _ => true
  | _                     => false

/- Return true if the next pattern of each remaining alternative is an inaccessible term or a variable -/
private def isVariableTransition (p : Problem) : Bool :=
p.alts.all fun alt => match alt.patterns with
  | Pattern.inaccessible _ _ :: _ => true
  | Pattern.var _ _ :: _          => true
  | _                             => false

/- Return true if the next pattern of each remaining alternative is a constructor application -/
private def isConstructorTransition (p : Problem) : Bool :=
p.alts.all fun alt => match alt.patterns with
  | Pattern.ctor _ _ _ _ _ :: _ => true
  | _                           => false

/- Return true if the next pattern of the remaining alternatives contain variables AND constructors. -/
private def isCompleteTransition (p : Problem) : Bool :=
let (ok, hasVar, hasCtor) := p.alts.foldl
  (fun (acc : Bool × Bool × Bool) (alt : Alt) =>
    let (ok, hasVar, hasCtor) := acc;
    match alt.patterns with
    | Pattern.ctor _ _ _ _ _ :: _ => (ok, hasVar, true)
    | Pattern.var _ _ :: _        => (ok, true, hasCtor)
    | _                           => (false, hasVar, hasCtor))
  (true, false, false);
ok && hasVar && hasCtor

/- Return true if the next pattern of the remaining alternatives contain variables AND values. -/
private def isValueTransition (p : Problem) : Bool :=
let (ok, hasVar, hasVal) := p.alts.foldl
  (fun (acc : Bool × Bool × Bool) (alt : Alt) =>
    let (ok, hasVar, hasVal) := acc;
    match alt.patterns with
    | Pattern.val _ _ :: _ => (ok, hasVar, true)
    | Pattern.var _ _ :: _ => (ok, true, hasVal)
    | _                    => (false, hasVar, hasVal))
  (true, false, false);
ok && hasVar && hasVal

/- Return true if the next pattern of the remaining alternatives contain variables AND array literals. -/
private def isArrayLitTransition (p : Problem) : Bool :=
let (ok, hasVar, hasArray) := p.alts.foldl
  (fun (acc : Bool × Bool × Bool) (alt : Alt) =>
    let (ok, hasVar, hasArray) := acc;
    match alt.patterns with
    | Pattern.arrayLit _ _ _ :: _ => (ok, hasVar, true)
    | Pattern.var _ _ :: _        => (ok, true, hasArray)
    | _                           => (false, hasVar, hasArray))
  (true, false, false);
ok && hasVar && hasArray

private def processNonVariable (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("non variable step");
match p.vars with
| x :: xs =>
  let alts := p.alts.map fun alt => match alt.patterns with
    | _ :: ps => { alt with patterns := ps }
    | _       => unreachable!;
  process { p with alts := alts, vars := xs } s
| _ => unreachable!

private def processLeaf (p : Problem) (s : State) : MetaM State :=
match p.alts with
| []       => do
  admit p.mvarId;
  pure { s with counterExamples := p.examples :: s.counterExamples }
| alt :: _ => do
  -- TODO: check whether we have unassigned metavars in rhs
  assignGoalOf p alt.rhs;
  pure { s with used := s.used.insert alt.idx }

private def processAsPattern (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("as-pattern step");
match p.vars with
| []      => unreachable!
| x :: xs => do
  alts ← p.alts.mapM fun alt => match alt.patterns with
    | Pattern.as _ mvarId p :: ps     => do
      assignExprMVar mvarId x;
      rhs ← instantiateMVars alt.rhs;
      let mvars := alt.mvars.erase mvarId;
      let ps := p :: ps;
      ps ← ps.mapM fun p => p.instantiateMVars;
      pure { alt with patterns := ps, rhs := rhs, mvars := mvars }
    | _                              => pure alt;
  process { p with alts := alts } s

private def processVariable (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("variable step");
match p.vars with
| []      => unreachable!
| x :: xs => do
  alts ← p.alts.mapM fun alt => match alt.patterns with
    | Pattern.inaccessible _ _ :: ps => pure { alt with patterns := ps }
    | Pattern.var _ mvarId :: ps     => do
      -- trace! `Meta.EqnCompiler.matchDebug (">> assign " ++ mkMVar mvarId ++ " := " ++ x);
      assignExprMVar mvarId x;
      rhs ← instantiateMVars alt.rhs;
      let mvars := alt.mvars.erase mvarId;
      -- trace! `Meta.EqnCompiler.matchDebug (">> patterns before assignment: " ++ MessageData.ofList (ps.map Pattern.toMessageData));
      patterns ← ps.mapM fun p => p.instantiateMVars;
      -- trace! `Meta.EqnCompiler.matchDebug (">> patterns after assignment: " ++ MessageData.ofList (patterns.map Pattern.toMessageData));
      pure { alt with patterns := patterns, rhs := rhs, mvars := mvars }
    | _                              => unreachable!;
  process { p with alts := alts, vars := xs } s

private def isFirstPatternCtor (ctorName : Name) (alt : Alt) : Bool :=
match alt.patterns with
| Pattern.ctor _ n _ _ _ :: _ => n == ctorName
| _                           => false

private def processConstructor (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("constructor step");
match p.vars with
| []      => unreachable!
| x :: xs => do
  subgoals ← cases p.mvarId x.fvarId!;
  subgoals.foldlM
    (fun (s : State) subgoal => do
      let subst    := subgoal.subst;
      let fields   := subgoal.fields.toList;
      let newVars  := fields ++ xs;
      let newVars  := newVars.map fun x => x.applyFVarSubst subst;
      let subex    := Example.ctor subgoal.ctorName $ fields.map fun field => match field with
        | Expr.fvar fvarId _ => Example.var fvarId
        | _                  => Example.underscore; -- This case can happen due to dependent elimination
      let examples := p.examples.map $ Example.replaceFVarId x.fvarId! subex;
      let examples := examples.map $ Example.applyFVarSubst subst;
      let newAlts  := p.alts.filter $ isFirstPatternCtor subgoal.ctorName;
      let newAlts  := newAlts.map fun alt => match alt.patterns with
        | Pattern.ctor _ _ _ _ fields :: ps => { alt with patterns := fields ++ ps }
        | _                                 => unreachable!;
      newAlts ← newAlts.mapM fun alt => alt.applyFVarSubst subst;
      newAlts ← newAlts.mapM fun alt => alt.copy;
      process { mvarId := subgoal.mvarId, vars := newVars, alts := newAlts, examples := examples } s)
    s

private def throwInductiveTypeExpected {α} (type : Expr) : MetaM α := do
throwOther ("failed to compile pattern matching, inductive type expected" ++ indentExpr type)

private partial def tryConstructorAux (alt : Alt) (ref : Syntax) (mvarId : MVarId) (ctorName : Name) (us : List Level) (params : Array Expr) (mvars : Array Expr)
    : Nat → Array MVarId → Array IPattern → MetaM Alt
| i, newMVars, fields => do
  if h : i < mvars.size then do
    let mvar := mvars.get ⟨i, h⟩;
    e ← instantiateMVars mvar;
    match e with
    | Expr.mvar mvarId _ => tryConstructorAux (i+1) (newMVars.push mvarId) (fields.push (Pattern.var ref mvarId))
    | _                  => tryConstructorAux (i+1) newMVars (fields.push (Pattern.inaccessible ref e))
  else do
    let p := Pattern.ctor ref ctorName us params.toList fields.toList;
    e ← p.toExpr;
    assignExprMVar mvarId e;
    ps ← alt.patterns.mapM Pattern.instantiateMVars;
    let ps := p :: ps;
    rhs ← instantiateMVars alt.rhs;
    unless (alt.mvars.contains mvarId) $
      throwOther "ill-format alternative"; -- TODO: improve error message
    let mvars := (alt.mvars.map fun mvarId' => if mvarId' == mvarId then newMVars.toList else [mvarId']).join;
    mvars ← mvars.filterM fun mvarId => not <$> isExprMVarAssigned mvarId;
    pure { alt with rhs := rhs, mvars := mvars, patterns := ps }

private def tryConstructor? (alt : Alt) (ref : Syntax) (mvarId : MVarId) (ctorName : Name) (us : List Level) (params : Array Expr) (expectedType : Expr)
    : MetaM (Option Alt) := do
let ctor := mkAppN (mkConst ctorName us) params;
ctorType ← inferType ctor;
(mvars, _, resultType) ← forallMetaTelescopeReducing ctorType;
trace! `Meta.EqnCompiler.matchDebug ("ctorName: " ++ ctorName ++ ", resultType: " ++ resultType ++ ", expectedType: " ++ expectedType);
condM (isDefEq resultType expectedType)
  (Option.some <$> tryConstructorAux alt ref mvarId ctorName us params mvars 0 #[] #[])
  (pure none)

private def expandAlt (alt : Alt) (ref : Syntax) (mvarId : MVarId) : MetaM (List Alt) := do
env ← getEnv;
mvarDecl ← getMVarDecl mvarId;
let expectedType := mvarDecl.type;
expectedType ← whnfD expectedType;
matchConst env expectedType.getAppFn (fun _ => throwInductiveTypeExpected expectedType) fun info us =>
  match info with
  | ConstantInfo.inductInfo val =>
    val.ctors.foldlM
      (fun (result : List Alt) ctor => do
        (mvarSubst, alt) ← alt.copyCore;
        let mvarId := mvarSubst.find! mvarId;
        mvarDecl ← getMVarDecl mvarId;
        let expectedType := mvarDecl.type;
        expectedType ← whnfD expectedType;
        let I     := expectedType.getAppFn;
        let Iargs := expectedType.getAppArgs;
        let params := Iargs.extract 0 val.nparams;
        alt? ← tryConstructor? alt ref mvarId ctor us params expectedType;
        match alt? with
        | none     => pure result
        | some alt => pure (alt :: result))
      []
  | _ => throwInductiveTypeExpected expectedType

private def processComplete (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("complete step");
withGoalOf p do
env ← getEnv;
newAlts ← p.alts.foldlM
  (fun (newAlts : List Alt) alt =>
    match alt.patterns with
    | Pattern.ctor _ _ _ _ _ :: ps     => pure (alt :: newAlts)
    | p@(Pattern.var ref mvarId) :: ps => do
        let alt := { alt with patterns := ps };
        alts ← expandAlt alt ref mvarId;
        pure (alts ++ newAlts)
    | _ => unreachable!)
  [];
process { p with alts := newAlts.reverse } s

private def collectValues (p : Problem) : Array Expr :=
p.alts.foldl
  (fun (values : Array Expr) alt =>
    match alt.patterns with
    | Pattern.val _ v :: _ => if values.contains v then values else values.push v
    | _                    => values)
  #[]

private def isFirstPatternVar (alt : Alt) : Bool :=
match alt.patterns with
| Pattern.var _ _ :: _ => true
| _                    => false

private def processValue (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("value step");
match p.vars with
| []      => unreachable!
| x :: xs => do
  let values := collectValues p;
  subgoals ← caseValues p.mvarId x.fvarId! values;
  subgoals.size.foldM
    (fun i (s : State) =>
      let subgoal := subgoals.get! i;
      if h : i < values.size then do
        let value := values.get ⟨i, h⟩;
        -- (x = value) branch
        let subst := subgoal.subst;
        let examples := p.examples.map $ Example.replaceFVarId x.fvarId! (Example.val value);
        let examples := examples.map $ Example.applyFVarSubst subst;
        let newAlts  := p.alts.filter fun alt => match alt.patterns with
          | Pattern.val _ v :: _ => v == value
          | Pattern.var _ _ :: _ => true
          | _                    => false;
        newAlts ← newAlts.mapM fun alt => alt.applyFVarSubst subst;
        newAlts ← newAlts.mapM fun alt => alt.copy;
        newAlts ← newAlts.mapM fun alt => match alt.patterns with
          | Pattern.val _ _ :: ps      => pure { alt with patterns := ps }
          | Pattern.var _ mvarId :: ps => do
            assignExprMVar mvarId value;
            ps  ← ps.mapM Pattern.instantiateMVars;
            rhs ← instantiateMVars alt.rhs;
            let mvars := alt.mvars.erase mvarId;
            pure { alt with rhs := rhs, mvars := mvars, patterns := ps }
          | _  => unreachable!;
        let newVars := xs.map fun x => x.applyFVarSubst subst;
        process { mvarId := subgoal.mvarId, vars := newVars, alts := newAlts, examples := examples } s
      else do
        -- else branch
        let newAlts := p.alts.filter isFirstPatternVar;
        newAlts ← newAlts.mapM fun alt => alt.copy;
        process { p with mvarId := subgoal.mvarId, alts := newAlts, vars := x::xs } s)
    s

private def collectArraySizes (p : Problem) : Array Nat :=
p.alts.foldl
  (fun (sizes : Array Nat) alt =>
    match alt.patterns with
    | Pattern.arrayLit _ _ ps :: _ => let sz := ps.length; if sizes.contains sz then sizes else sizes.push sz
    | _                            => sizes)
  #[]

private def processArrayLit (process : Problem → State → MetaM State) (p : Problem) (s : State) : MetaM State := do
trace! `Meta.EqnCompiler.match ("array literal step");
match p.vars with
| []      => unreachable!
| x :: xs => do
  let sizes := collectArraySizes p;
  subgoals ← caseArraySizes p.mvarId x.fvarId! sizes;
  subgoals.size.foldM
    (fun i (s : State) =>
      let subgoal := subgoals.get! i;
      if h : i < sizes.size then do
        let size     := sizes.get! i;
        let subst    := subgoal.subst;
        let elems    := subgoal.elems.toList;
        let newVars  := elems.map mkFVar ++ xs;
        let newVars  := newVars.map fun x => x.applyFVarSubst subst;
        let subex    := Example.arrayLit $ elems.map Example.var;
        let examples := p.examples.map $ Example.replaceFVarId x.fvarId! subex;
        let examples := examples.map $ Example.applyFVarSubst subst;
        let newAlts  := p.alts.filter fun alt => match alt.patterns with
          | Pattern.arrayLit _ _ ps :: _ => ps.length == size
          | Pattern.var _ _ :: _         => true
          | _                            => false;
        newAlts ← newAlts.mapM fun alt => alt.applyFVarSubst subst;
        newAlts ← newAlts.mapM fun alt => alt.copy;
        newAlts ← newAlts.mapM fun alt => match alt.patterns with
          | Pattern.arrayLit _ _ pats :: ps      => pure { alt with patterns := pats ++ ps }
          | Pattern.var ref mvarId :: ps => do
            α ← getArrayArgType x;
            newMVars ← size.foldM
              (fun _ (newMVars : List Expr) => do
                newMVar ← mkFreshExprMVar α;
                pure (newMVar :: newMVars))
              [];
            arrayLit ← mkArrayLit α newMVars;
            assignExprMVar mvarId arrayLit;
            ps  ← ps.mapM Pattern.instantiateMVars;
            rhs ← instantiateMVars alt.rhs;
            let mvars := alt.mvars.erase mvarId;
            let mvars := newMVars.map Expr.mvarId! ++ mvars;
            let ps    := newMVars.map (fun mvar => Pattern.var ref mvar.mvarId!) ++ ps;
            pure { alt with rhs := rhs, mvars := mvars, patterns := ps }
          | _  => unreachable!;
        process { mvarId := subgoal.mvarId, vars := newVars, alts := newAlts, examples := examples } s
      else do
        -- else branch
        let newAlts := p.alts.filter isFirstPatternVar;
        newAlts ← newAlts.mapM fun alt => alt.copy;
        process { p with mvarId := subgoal.mvarId, alts := newAlts, vars := x::xs } s)
    s

private partial def process : Problem → State → MetaM State
| p, s => withIncRecDepth do
  withGoalOf p (traceM `Meta.EqnCompiler.match p.toMessageData);
  if isDone p then
    processLeaf p s
  else if hasAsPattern p then
    processAsPattern process p s
  else if !isNextVar p then
    processNonVariable process p s
  else if isVariableTransition p then
    processVariable process p s
  else if isConstructorTransition p then
    processConstructor process p s
  else if isCompleteTransition p then
    processComplete process p s
  else if isValueTransition p then
    processValue process p s
  else if isArrayLitTransition p then
    processArrayLit process p s
  else do
    msg ← p.toMessageData;
    -- TODO: remaining cases
    throwOther ("not implement yet " ++ msg)

def getUnusedLevelParam (majors : List Expr) (lhss : List AltLHS) : MetaM Level := do
let s : CollectLevelParams.State := {};
s ← majors.foldlM
  (fun s major => do
    major ← instantiateMVars major;
    majorType ← inferType major;
    majorType ← instantiateMVars majorType;
    let s := collectLevelParams s major;
    pure $ collectLevelParams s majorType)
  s;
pure s.getUnusedLevelParam

/- Return `Prop` if `inProf == true` and `Sort u` otherwise, where `u` is a fresh universe level parameter. -/
private def mkElimSort (majors : List Expr) (lhss : List AltLHS) (inProp : Bool) : MetaM Expr :=
if inProp then
  pure $ mkSort $ levelZero
else do
  v ← getUnusedLevelParam majors lhss;
  pure $ mkSort $ v

def mkElimCore (elimName : Name) (motive : Expr) (majors : List Expr) (lhss : List AltLHS) (inProp : Bool := false) : MetaM ElimResult := do
checkNumPatterns majors lhss;
generalizeTelescope majors.toArray `_d fun majors => do
  let mvarType  := mkAppN motive majors;
  trace! `Meta.EqnCompiler.matchDebug ("target: " ++ mvarType);
  withAlts motive lhss fun alts minors => do
    mvar ← mkFreshExprMVar mvarType;
    let examples := majors.toList.map fun major => Example.var major.fvarId!;
    s    ← process { mvarId := mvar.mvarId!, vars := majors.toList, alts := alts, examples := examples } {};
    let args := #[motive] ++ majors ++ minors;
    type ← mkForall args mvarType;
    val  ← mkLambda args mvar;
    trace! `Meta.EqnCompiler.matchDebug ("eliminator value: " ++ val ++ "\ntype: " ++ type);
    elim ← mkAuxDefinition elimName type val;
    trace! `Meta.EqnCompiler.matchDebug ("eliminator: " ++ elim);
    let unusedAltIdxs : List Nat := lhss.length.fold
      (fun i r => if s.used.contains i then r else i::r)
      [];
    pure { elim := elim, counterExamples := s.counterExamples, unusedAltIdxs := unusedAltIdxs.reverse }

def mkElim (elimName : Name) (majors : List Expr) (lhss : List AltLHS) (inProp : Bool := false) : MetaM ElimResult := do
sortv ← mkElimSort majors lhss inProp;
generalizeTelescope majors.toArray `_d fun majors => do
  withMotive majors sortv fun motive =>
    mkElimCore elimName motive majors.toList lhss inProp

@[init] private def regTraceClasses : IO Unit := do
registerTraceClass `Meta.EqnCompiler.match;
registerTraceClass `Meta.EqnCompiler.matchDebug

end DepElim
end Meta
end Lean