/-
Copyright (c) 2020 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
import Lean.Util.ReplaceLevel
import Lean.Util.ReplaceExpr
import Lean.Util.CollectLevelParams
import Lean.Util.Constructions
import Lean.Meta.SizeOf
import Lean.Elab.Command
import Lean.Elab.CollectFVars
import Lean.Elab.DefView
import Lean.Elab.DeclUtil
import Lean.Elab.Deriving.Basic

namespace Lean.Elab.Command
open Meta

builtin_initialize
  registerTraceClass `Elab.inductive

def checkValidInductiveModifier [Monad m] [MonadError m] (modifiers : Modifiers) : m Unit := do
  if modifiers.isNoncomputable then
    throwError "invalid use of 'noncomputable' in inductive declaration"
  if modifiers.isPartial then
    throwError "invalid use of 'partial' in inductive declaration"
  unless modifiers.attrs.size == 0 || (modifiers.attrs.size == 1 && modifiers.attrs[0].name == `class) do
    throwError "invalid use of attributes in inductive declaration"

def checkValidCtorModifier [Monad m] [MonadError m] (modifiers : Modifiers) : m Unit := do
  if modifiers.isNoncomputable then
    throwError "invalid use of 'noncomputable' in constructor declaration"
  if modifiers.isPartial then
    throwError "invalid use of 'partial' in constructor declaration"
  if modifiers.isUnsafe then
    throwError "invalid use of 'unsafe' in constructor declaration"
  if modifiers.attrs.size != 0 then
    throwError "invalid use of attributes in constructor declaration"

structure CtorView where
  ref       : Syntax
  modifiers : Modifiers
  inferMod  : Bool  -- true if `{}` is used in the constructor declaration
  declName  : Name
  binders   : Syntax
  type?     : Option Syntax
  deriving Inhabited

structure InductiveView where
  ref             : Syntax
  modifiers       : Modifiers
  shortDeclName   : Name
  declName        : Name
  levelNames      : List Name
  binders         : Syntax
  type?           : Option Syntax
  ctors           : Array CtorView
  derivingClasses : Array DerivingClassView
  deriving Inhabited

structure ElabHeaderResult where
  view       : InductiveView
  lctx       : LocalContext
  localInsts : LocalInstances
  params     : Array Expr
  type       : Expr
  deriving Inhabited

private partial def elabHeaderAux (views : Array InductiveView) (i : Nat) (acc : Array ElabHeaderResult) : TermElabM (Array ElabHeaderResult) := do
  if h : i < views.size then
    let view := views.get ⟨i, h⟩
    let acc ← Term.withAutoBoundImplicitLocal <| Term.elabBinders view.binders.getArgs (catchAutoBoundImplicit := true) fun params => do
      match view.type? with
      | none         =>
        let u ← mkFreshLevelMVar
        let type := mkSort u
        let params ← Term.addAutoBoundImplicits params
        pure <| acc.push { lctx := (← getLCtx), localInsts := (← getLocalInstances), params := params, type := type, view := view }
      | some typeStx =>
        Term.elabTypeWithAutoBoundImplicit typeStx fun type => do
          unless (← isTypeFormerType type) do
            throwErrorAt typeStx "invalid inductive type, resultant type is not a sort"
          let params ← Term.addAutoBoundImplicits params
          pure <| acc.push { lctx := (← getLCtx), localInsts := (← getLocalInstances), params := params, type := type, view := view }
    elabHeaderAux views (i+1) acc
  else
    pure acc

private def checkNumParams (rs : Array ElabHeaderResult) : TermElabM Nat := do
  let numParams := rs[0].params.size
  for r in rs do
    unless r.params.size == numParams do
      throwErrorAt r.view.ref "invalid inductive type, number of parameters mismatch in mutually inductive datatypes"
  pure numParams

private def checkUnsafe (rs : Array ElabHeaderResult) : TermElabM Unit := do
  let isUnsafe := rs[0].view.modifiers.isUnsafe
  for r in rs do
    unless r.view.modifiers.isUnsafe == isUnsafe do
      throwErrorAt r.view.ref "invalid inductive type, cannot mix unsafe and safe declarations in a mutually inductive datatypes"

private def checkLevelNames (views : Array InductiveView) : TermElabM Unit := do
  if views.size > 1 then
    let levelNames := views[0].levelNames
    for view in views do
      unless view.levelNames == levelNames do
        throwErrorAt view.ref "invalid inductive type, universe parameters mismatch in mutually inductive datatypes"

private def mkTypeFor (r : ElabHeaderResult) : TermElabM Expr := do
  withLCtx r.lctx r.localInsts do
    mkForallFVars r.params r.type

private def throwUnexpectedInductiveType {α} : TermElabM α :=
  throwError "unexpected inductive resulting type"

-- Given `e` of the form `forall As, B`, return `B`.
-- It assumes `B` doesn't depend on `As`.
private def getResultingType (e : Expr) : TermElabM Expr :=
  forallTelescopeReducing e fun _ r => pure r

private def eqvFirstTypeResult (firstType type : Expr) : MetaM Bool :=
  forallTelescopeReducing firstType fun _ firstTypeResult => isDefEq firstTypeResult type

-- Auxiliary function for checking whether the types in mutually inductive declaration are compatible.
private partial def checkParamsAndResultType (type firstType : Expr) (numParams : Nat) : TermElabM Unit := do
  try
    forallTelescopeCompatible type firstType numParams fun _ type firstType =>
    forallTelescopeReducing type fun _ type =>
    forallTelescopeReducing firstType fun _ firstType => do
    match type with
    | Expr.sort _ _        =>
      unless (← isDefEq firstType type) do
        throwError! "resulting universe mismatch, given{indentExpr type}\nexpected type{indentExpr firstType}"
    | _ =>
      throwError "unexpected inductive resulting type"
  catch
    | Exception.error ref msg => throw (Exception.error ref m!"invalid mutually inductive types, {msg}")
    | ex => throw ex

-- Auxiliary function for checking whether the types in mutually inductive declaration are compatible.
private def checkHeader (r : ElabHeaderResult) (numParams : Nat) (firstType? : Option Expr) : TermElabM Expr := do
  let type ← mkTypeFor r
  match firstType? with
  | none           => pure type
  | some firstType =>
    withRef r.view.ref $ checkParamsAndResultType type firstType numParams
    pure firstType

-- Auxiliary function for checking whether the types in mutually inductive declaration are compatible.
private partial def checkHeaders (rs : Array ElabHeaderResult) (numParams : Nat) (i : Nat) (firstType? : Option Expr) : TermElabM Unit := do
  if i < rs.size then
    let type ← checkHeader rs[i] numParams firstType?
    checkHeaders rs numParams (i+1) type

private def elabHeader (views : Array InductiveView) : TermElabM (Array ElabHeaderResult) := do
  let rs ← elabHeaderAux views 0 #[]
  if rs.size > 1 then
    checkUnsafe rs
    let numParams ← checkNumParams rs
    checkHeaders rs numParams 0 none
  pure rs

/- Create a local declaration for each inductive type in `rs`, and execute `x params indFVars`, where `params` are the inductive type parameters and
   `indFVars` are the new local declarations.
   We use the the local context/instances and parameters of rs[0].
   Note that this method is executed after we executed `checkHeaders` and established all
   parameters are compatible. -/
private partial def withInductiveLocalDecls {α} (rs : Array ElabHeaderResult) (x : Array Expr → Array Expr → TermElabM α) : TermElabM α := do
  let namesAndTypes ← rs.mapM fun r => do
    let type ← mkTypeFor r
    pure (r.view.shortDeclName, type)
  let r0     := rs[0]
  let params := r0.params
  withLCtx r0.lctx r0.localInsts $ withRef r0.view.ref do
    let rec loop (i : Nat) (indFVars : Array Expr) := do
      if h : i < namesAndTypes.size then
        let (id, type) := namesAndTypes.get ⟨i, h⟩
        withLocalDeclD id type fun indFVar => loop (i+1) (indFVars.push indFVar)
      else
        x params indFVars
    loop 0 #[]

private def isInductiveFamily (numParams : Nat) (indFVar : Expr) : TermElabM Bool := do
  let indFVarType ← inferType indFVar
  forallTelescopeReducing indFVarType fun xs _ =>
    pure $ xs.size > numParams

/-
  Elaborate constructor types.

  Remark: we check whether the resulting type is correct, but
  we do not check for:
  - Positivity (it is a rare failure, and the kernel already checks for it).
  - Universe constraints (the kernel checks for it). -/
private def elabCtors (indFVar : Expr) (params : Array Expr) (r : ElabHeaderResult) : TermElabM (List Constructor) :=
  withRef r.view.ref do
  let indFamily ← isInductiveFamily params.size indFVar
  r.view.ctors.toList.mapM fun ctorView => Term.elabBinders ctorView.binders.getArgs fun ctorParams =>
    withRef ctorView.ref do
    let type ← match ctorView.type? with
      | none          =>
        if indFamily then
          throwError "constructor resulting type must be specified in inductive family declaration"
        pure (mkAppN indFVar params)
      | some ctorType =>
        let type ← Term.elabTerm ctorType none
        let resultingType ← getResultingType type
        unless resultingType.getAppFn == indFVar do
          throwError! "unexpected constructor resulting type{indentExpr resultingType}"
        unless (← isType resultingType) do
          throwError! "unexpected constructor resulting type, type expected{indentExpr resultingType}"
        let args := resultingType.getAppArgs
        for i in [:params.size] do
          let param := params[i]
          let arg   := args[i]
          unless (← isDefEq param arg) do
            throwError! "inductive datatype parameter mismatch{indentExpr arg}\nexpected{indentExpr param}"
        pure type
    let type ← mkForallFVars ctorParams type
    let type ← mkForallFVars params type
    pure { name := ctorView.declName, type := type }

/- Convert universe metavariables occurring in the `indTypes` into new parameters.
   Remark: if the resulting inductive datatype has universe metavariables, we will fix it later using
   `inferResultingUniverse`. -/
private def levelMVarToParamAux (indTypes : List InductiveType) : StateRefT Nat TermElabM (List InductiveType) :=
  indTypes.mapM fun indType => do
    let type  ← Term.levelMVarToParam' indType.type
    let ctors ← indType.ctors.mapM fun ctor => do
      let ctorType ← Term.levelMVarToParam' ctor.type
      pure { ctor with type := ctorType }
    pure { indType with ctors := ctors, type := type }

private def levelMVarToParam (indTypes : List InductiveType) : TermElabM (List InductiveType) :=
  (levelMVarToParamAux indTypes).run' 1

private def getResultingUniverse : List InductiveType → TermElabM Level
  | []           => throwError "unexpected empty inductive declaration"
  | indType :: _ => do
    let r ← getResultingType indType.type
    match r with
    | Expr.sort u _ => pure u
    | _             => throwError "unexpected inductive type resulting type"

def tmpIndParam := mkLevelParam `_tmp_ind_univ_param

/--
  Return true if `u` is of the form `?m + k`.
  Return false if `u` does not contain universe metavariables.
  Throw exception otherwise. -/
def shouldInferResultUniverse (u : Level) : TermElabM Bool := do
  let u ← instantiateLevelMVars u
  if u.hasMVar then
    match u.getLevelOffset with
    | Level.mvar mvarId _ => do
      Term.assignLevelMVar mvarId tmpIndParam
      pure true
    | _ =>
      throwError! "cannot infer resulting universe level of inductive datatype, given level contains metavariables {mkSort u}, provide universe explicitly"
  else
    pure false

/-
  Auxiliary function for `updateResultingUniverse`
  `accLevelAtCtor u r rOffset us` add `u` components to `us` if they are not already there and it is different from the resulting universe level `r+rOffset`.
  If `u` is a `max`, then its components are recursively processed.
  If `u` is a `succ` and `rOffset > 0`, we process the `u`s child using `rOffset-1`.

  This method is used to infer the resulting universe level of an inductive datatype. -/
def accLevelAtCtor : Level → Level → Nat → Array Level → TermElabM (Array Level)
  | Level.max u v _,  r, rOffset,   us => do let us ← accLevelAtCtor u r rOffset us; accLevelAtCtor v r rOffset us
  | Level.imax u v _, r, rOffset,   us => do let us ← accLevelAtCtor u r rOffset us; accLevelAtCtor v r rOffset us
  | Level.zero _,     _, _,         us => pure us
  | Level.succ u _,   r, rOffset+1, us => accLevelAtCtor u r rOffset us
  | u,                r, rOffset,   us =>
    if rOffset == 0 && u == r then pure us
    else if r.occurs u  then throwError! "failed to compute resulting universe level of inductive datatype, provide universe explicitly"
    else if rOffset > 0 then throwError! "failed to compute resulting universe level of inductive datatype, provide universe explicitly"
    else if us.contains u then pure us
    else pure (us.push u)

/- Auxiliary function for `updateResultingUniverse` -/
private partial def collectUniversesFromCtorTypeAux (r : Level) (rOffset : Nat) : Nat → Expr → Array Level → TermElabM (Array Level)
  | 0,   Expr.forallE n d b c, us => do
    let u ← getLevel d
    let u ← instantiateLevelMVars u
    let us ← accLevelAtCtor u r rOffset us
    withLocalDecl n c.binderInfo d fun x =>
      let e := b.instantiate1 x
      collectUniversesFromCtorTypeAux r rOffset 0 e us
  | i+1, Expr.forallE n d b c, us => do
    withLocalDecl n c.binderInfo d fun x =>
      let e := b.instantiate1 x
      collectUniversesFromCtorTypeAux r rOffset i e us
  | _, _, us => pure us

/- Auxiliary function for `updateResultingUniverse` -/
private partial def collectUniversesFromCtorType
    (r : Level) (rOffset : Nat) (ctorType : Expr) (numParams : Nat) (us : Array Level) : TermElabM (Array Level) :=
  collectUniversesFromCtorTypeAux r rOffset numParams ctorType us

/- Auxiliary function for `updateResultingUniverse` -/
private partial def collectUniverses (r : Level) (rOffset : Nat) (numParams : Nat) (indTypes : List InductiveType) : TermElabM (Array Level) :=
  indTypes.foldlM (init := #[]) fun us indType =>
    indType.ctors.foldlM (init := us) fun us ctor =>
      collectUniversesFromCtorType r rOffset ctor.type numParams us

def mkResultUniverse (us : Array Level) (rOffset : Nat) : Level :=
  if us.isEmpty && rOffset == 0 then
    levelOne
  else
    let r := Level.mkNaryMax us.toList
    if rOffset == 0 && !r.isZero && !r.isNeverZero then
      (mkLevelMax r levelOne).normalize
    else
      r.normalize

private def updateResultingUniverse (numParams : Nat) (indTypes : List InductiveType) : TermElabM (List InductiveType) := do
  let r ← getResultingUniverse indTypes
  let rOffset : Nat   := r.getOffset
  let r       : Level := r.getLevelOffset
  unless r.isParam do
    throwError "failed to compute resulting universe level of inductive datatype, provide universe explicitly"
  let us ← collectUniverses r rOffset numParams indTypes
  trace[Elab.inductive]! "updateResultingUniverse us: {us}, r: {r}, rOffset: {rOffset}"
  let rNew := mkResultUniverse us rOffset
  let updateLevel (e : Expr) : Expr := e.replaceLevel fun u => if u == tmpIndParam then some rNew else none
  return indTypes.map fun indType =>
    let type := updateLevel indType.type;
    let ctors := indType.ctors.map fun ctor => { ctor with type := updateLevel ctor.type };
    { indType with type := type, ctors := ctors }

builtin_initialize
  registerOption `bootstrap.inductiveCheckResultingUniverse {
    defValue := true,
    group    := "bootstrap",
    descr    := "by default the `inductive/structure commands report an error if the resulting universe is not zero, but may be zero for some universe parameters. Reason: unless this type is a subsingleton, it is hardly what the user wants since it can only eliminate into `Prop`. In the `Init` package, we define subsingletons, and we use this option to disable the check. This option may be deleted in the future after we improve the validator"
  }

def getCheckResultingUniverseOption (opts : Options) : Bool :=
  opts.get `bootstrap.inductiveCheckResultingUniverse true

def checkResultingUniverse (u : Level) : TermElabM Unit := do
  if getCheckResultingUniverseOption (← getOptions) then
    let u ← instantiateLevelMVars u
    if !u.isZero && !u.isNeverZero then
      throwError! "invalid universe polymorphic type, the resultant universe is not Prop (i.e., 0), but it may be Prop for some parameter values (solution: use 'u+1' or 'max 1 u'{indentD u}"

private def checkResultingUniverses (indTypes : List InductiveType) : TermElabM Unit := do
  checkResultingUniverse (← getResultingUniverse indTypes)

private def collectUsed (indTypes : List InductiveType) : StateRefT CollectFVars.State TermElabM Unit := do
  indTypes.forM fun indType => do
    Term.collectUsedFVars indType.type
    indType.ctors.forM fun ctor =>
      Term.collectUsedFVars ctor.type

private def removeUnused (vars : Array Expr) (indTypes : List InductiveType) : TermElabM (LocalContext × LocalInstances × Array Expr) := do
  let (_, used) ← (collectUsed indTypes).run {}
  Term.removeUnused vars used

private def withUsed {α} (vars : Array Expr) (indTypes : List InductiveType) (k : Array Expr → TermElabM α) : TermElabM α := do
  let (lctx, localInsts, vars) ← removeUnused vars indTypes
  withLCtx lctx localInsts $ k vars

private def updateParams (vars : Array Expr) (indTypes : List InductiveType) : TermElabM (List InductiveType) :=
  indTypes.mapM fun indType => do
    let type ← mkForallFVars vars indType.type
    let ctors ← indType.ctors.mapM fun ctor => do
      let ctorType ← mkForallFVars vars ctor.type
      pure { ctor with type := ctorType }
    pure { indType with type := type, ctors := ctors }

private def collectLevelParamsInInductive (indTypes : List InductiveType) : Array Name :=
  let usedParams := indTypes.foldl (init := {}) fun (usedParams : CollectLevelParams.State) indType =>
    let usedParams := collectLevelParams usedParams indType.type;
    indType.ctors.foldl (init := usedParams) fun (usedParams : CollectLevelParams.State) ctor =>
      collectLevelParams usedParams ctor.type
  usedParams.params

private def mkIndFVar2Const (views : Array InductiveView) (indFVars : Array Expr) (levelNames : List Name) : ExprMap Expr :=
  let levelParams := levelNames.map mkLevelParam;
  views.size.fold (init := {}) fun i (m : ExprMap Expr) =>
    let view    := views[i]
    let indFVar := indFVars[i]
    m.insert indFVar (mkConst view.declName levelParams)

/- Remark: `numVars <= numParams`. `numVars` is the number of context `variables` used in the inductive declaration,
   and `numParams` is `numVars` + number of explicit parameters provided in the declaration. -/
private def replaceIndFVarsWithConsts (views : Array InductiveView) (indFVars : Array Expr) (levelNames : List Name)
    (numVars : Nat) (numParams : Nat) (indTypes : List InductiveType) : TermElabM (List InductiveType) :=
  let indFVar2Const := mkIndFVar2Const views indFVars levelNames
  indTypes.mapM fun indType => do
    let ctors ← indType.ctors.mapM fun ctor => do
      let type ← forallBoundedTelescope ctor.type numParams fun params type => do
        let type := type.replace fun e =>
          if !e.isFVar then
            none
          else match indFVar2Const.find? e with
            | none   => none
            | some c => mkAppN c (params.extract 0 numVars)
        mkForallFVars params type
      pure { ctor with type := type }
    pure { indType with ctors := ctors }

abbrev Ctor2InferMod := Std.HashMap Name Bool

private def mkCtor2InferMod (views : Array InductiveView) : Ctor2InferMod :=
  views.foldl (init := {}) fun m view =>
    view.ctors.foldl (init := m) fun m ctorView =>
      m.insert ctorView.declName ctorView.inferMod

private def applyInferMod (views : Array InductiveView) (numParams : Nat) (indTypes : List InductiveType) : List InductiveType :=
  let ctor2InferMod := mkCtor2InferMod views
  indTypes.map fun indType =>
    let ctors := indType.ctors.map fun ctor =>
      let inferMod := ctor2InferMod.find! ctor.name -- true if `{}` was used
      let ctorType := ctor.type.inferImplicit numParams !inferMod
      { ctor with type := ctorType }
    { indType with ctors := ctors }

private def mkAuxConstructions (views : Array InductiveView) : TermElabM Unit := do
  let env ← getEnv
  let hasEq   := env.contains `Eq
  let hasHEq  := env.contains `HEq
  let hasUnit := env.contains `PUnit
  let hasProd := env.contains `Prod
  for view in views do
    let n := view.declName
    mkRecOn n
    if hasUnit then mkCasesOn n
    if hasUnit && hasEq && hasHEq then mkNoConfusion n
    if hasUnit && hasProd then mkBelow n
    if hasUnit && hasProd then mkIBelow n
  for view in views do
    let n := view.declName;
    if hasUnit && hasProd then mkBRecOn n
    if hasUnit && hasProd then mkBInductionOn n

private def mkInductiveDecl (vars : Array Expr) (views : Array InductiveView) : TermElabM Unit := do
  let view0 := views[0]
  let scopeLevelNames ← Term.getLevelNames
  checkLevelNames views
  let allUserLevelNames := view0.levelNames
  let isUnsafe          := view0.modifiers.isUnsafe
  withRef view0.ref <| Term.withLevelNames allUserLevelNames do
    let rs ← elabHeader views
    withInductiveLocalDecls rs fun params indFVars => do
      let numExplicitParams := params.size
      let indTypes ← views.size.foldM (init := []) fun i (indTypes : List InductiveType) => do
        let indFVar := indFVars[i]
        let r       := rs[i]
        let type  ← mkForallFVars params r.type
        let ctors ← elabCtors indFVar params r
        let indType := { name := r.view.declName, type := type, ctors := ctors : InductiveType }
        pure (indType :: indTypes)
      let indTypes := indTypes.reverse
      Term.synthesizeSyntheticMVarsNoPostponing
      let u ← getResultingUniverse indTypes
      let inferLevel ← shouldInferResultUniverse u
      withUsed vars indTypes fun vars => do
        let numVars   := vars.size
        let numParams := numVars + numExplicitParams
        let indTypes ← updateParams vars indTypes
        let indTypes ← levelMVarToParam indTypes
        let indTypes ← if inferLevel then updateResultingUniverse numParams indTypes else checkResultingUniverses indTypes; pure indTypes
        let usedLevelNames := collectLevelParamsInInductive indTypes
        match sortDeclLevelParams scopeLevelNames allUserLevelNames usedLevelNames with
        | Except.error msg      => throwError msg
        | Except.ok levelParams => do
          let indTypes ← replaceIndFVarsWithConsts views indFVars levelParams numVars numParams indTypes
          let indTypes := applyInferMod views numParams indTypes
          let decl := Declaration.inductDecl levelParams numParams indTypes isUnsafe
          Term.ensureNoUnassignedMVars decl
          addDecl decl
          mkAuxConstructions views
          -- We need to invoke `applyAttributes` because `class` is implemented as an attribute.
          for view in views do
            Term.applyAttributesAt view.declName view.modifiers.attrs AttributeApplicationTime.afterTypeChecking

private def applyDerivingHandlers (views : Array InductiveView) : CommandElabM Unit := do
  let mut processed : NameSet := {}
  for view in views do
    for classView in view.derivingClasses do
      let className := classView.className
      unless processed.contains className do
        processed := processed.insert className
        let mut declNames := #[]
        for view in views do
          if view.derivingClasses.any fun classView => classView.className == className then
            declNames := declNames.push view.declName
        classView.applyHandlers declNames

def elabInductiveViews (views : Array InductiveView) : CommandElabM Unit := do
  let view0 := views[0]
  let ref := view0.ref
  runTermElabM view0.declName fun vars => withRef ref do
    mkInductiveDecl vars views
    mkSizeOfInstances view0.declName  
  applyDerivingHandlers views

end Lean.Elab.Command
