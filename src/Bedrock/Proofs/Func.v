Require Import Coq.ZArith.ZArith.
Require Import Coq.Strings.String.
Require Import Coq.Lists.List.
Require Import Coq.micromega.Lia.
Require Import bedrock2.Array.
Require Import bedrock2.Scalars.
Require Import bedrock2.Syntax.
Require Import bedrock2.ProgramLogic.
Require Import bedrock2.Map.Separation.
Require Import bedrock2.Map.SeparationLogic.
Require Import bedrock2.WeakestPreconditionProperties.
Require Import coqutil.Word.Interface.
Require Import coqutil.Word.Properties.
Require Import coqutil.Map.Interface.
Require Import coqutil.Map.Properties.
Require Import Crypto.Bedrock.Types.
Require Import Crypto.Bedrock.Tactics.
Require Import Crypto.Bedrock.Proofs.Cmd.
Require Import Crypto.Bedrock.Proofs.Flatten.
Require Import Crypto.Bedrock.Proofs.Varnames.
Require Import Crypto.Bedrock.Translation.Func.
Require Import Crypto.Bedrock.Translation.Flatten.
Require Import Crypto.Bedrock.Translation.LoadStoreList.
Require Import Crypto.Language.API.
Require Import Crypto.Util.ListUtil.
Import ListNotations. Local Open Scope Z_scope.

Import API.Compilers.
Import Wf.Compilers.expr.
Import Types.Notations Types.Types.

Section Func.
  Context {p : parameters} {p_ok : @ok p}.
  Local Notation bedrock_func := (string * (list string * list string * cmd))%type.

  (* TODO: are these all needed? *)
  Local Existing Instance rep.Z.
  Local Instance sem_ok : Semantics.parameters_ok semantics
    := semantics_ok.
  Local Instance mem_ok : map.ok Semantics.mem
    := Semantics.mem_ok.
  Local Instance varname_eqb_spec x y : BoolSpec _ _ _
    := Decidable.String.eqb_spec x y.

  Inductive valid_func : forall {t}, @API.expr (fun _ => unit) t -> Prop :=
  | validf_Abs :
      forall {s d} f, valid_func (f tt) ->
                      valid_func (expr.Abs (s:=type.base s) (d:=d) f)
  | validf_base :
      forall {b} e, valid_cmd e -> valid_func (t:=type.base b) e
  .

  (* TODO : move *)
  (* separation-logic relation that says space exists in memory for lists
     (other values are ignored) *)
  Fixpoint lists_reserved {t}
    : base_list_lengths t ->
      Interface.map.rep (map:=Semantics.mem) -> (* memory *)
      Prop :=
    match t with
    | base.type.prod a b =>
      fun x => sep (lists_reserved (fst x)) (lists_reserved (snd x))
    | base_listZ =>
      fun n =>
        Lift1Prop.ex1
          (fun start : Semantics.word =>
             Lift1Prop.ex1
               (fun oldvalues : list Semantics.word =>
                  let size := Interface.word.of_Z (Z.of_nat n) in
                  array scalar size start oldvalues))
    | base_Z => fun _ _ => True
    |  _ => fun _ _ => False
    end.

  (* TODO : move *)
  Lemma load_arguments_correct {t} :
    forall (argnames : type.for_each_lhs_of_arrow ltype t)
           (arglengths : type.for_each_lhs_of_arrow list_lengths t)
           (args1 : type.for_each_lhs_of_arrow API.interp_type t)
           (args2 : type.for_each_lhs_of_arrow rtype t)
           (flat_args : list Semantics.word)
           (functions : list _)
           (tr : Semantics.trace)
           (locals : Semantics.locals)
           (mem : Semantics.mem)
           (nextn : nat)
           (R : Semantics.mem -> Prop),
        (* argument values (in their 3 forms) are equivalent *)
        sep (equivalent_args args1 args2 map.empty) R mem ->
        WeakestPrecondition.dexprs
          mem map.empty (flatten_args args2) flat_args ->
        (* locals have just been formed from arguments *)
        map.of_list_zip (flatten_argnames argnames) flat_args = Some locals ->
        (* load_arguments returns triple : # fresh variables used,
           new argnames with local lists, and cmd *)
        let out := load_arguments nextn argnames arglengths in
        (* translated function produces equivalent results *)
        WeakestPrecondition.cmd
          (WeakestPrecondition.call functions)
          (snd out)
          tr mem locals
          (fun tr' mem' locals' =>
             tr = tr' /\
             mem = mem' /\
             locally_equivalent_args args1 args2 locals').
  Proof.
  Admitted.

  Search list_lengths.

  (* idea: pull return list lengths from fiat-crypto type *)
  (* TODO : move *)
  Lemma store_return_values_correct {t} :
    forall (retnames_local : base_ltype t)
           (retnames_mem : base_ltype t)
           (retlengths : base_list_lengths t)
           (rets : base.interp t)
           (functions : list _)
           (tr : Semantics.trace)
           (locals : Semantics.locals)
           (mem : Semantics.mem)
           (R : Semantics.mem -> Prop),
        (* use old values of memory to set up frame for return values *)
        sep (lists_reserved retlengths) R mem ->
        (* rets are stored in local retnames *)
        locally_equivalent rets (rtype_of_ltype retnames_local) locals ->
        (* translated function produces equivalent results *)
        WeakestPrecondition.cmd
          (WeakestPrecondition.call functions)
          (store_return_values retnames_local retnames_mem)
          tr mem locals
          (fun tr' mem' locals' =>
             tr = tr' /\
             sep (equivalent rets (rtype_of_ltype retnames_mem) locals') R mem').
  Proof.
  Admitted.

  Fixpoint init_context {t} {listZ:rep.rep base_listZ}:
    type.for_each_lhs_of_arrow API.interp_type t ->
    type.for_each_lhs_of_arrow (ltype (listZ:=listZ)) t ->
    list {t' & (unit * API.interp_type t' * ltype t')%type} :=
            match t with
            | type.base b => fun _ _ => []
            | type.arrow (type.base a) b =>
              fun args argnames =>
                (existT _ (type.base a) (tt, fst args, fst argnames)
                        :: init_context (snd args) (snd argnames))
            | _ => fun _ _ => []
            end.

  Lemma translate_func'_correct {t}
        (* three exprs, representing the same Expr with different vars *)
        (e0 : @API.expr (fun _ => unit) t)
        (e1 : @API.expr API.interp_type t)
        (e2 : @API.expr ltype t)
        (* expressions are valid input to translate_func' *)
        (e0_valid : valid_func e0)
        (* context list (consists only of arguments) *)
        (G : list _) :
    (* exprs are all related *)
    wf3 G e0 e1 e2 ->
    forall (argnames : type.for_each_lhs_of_arrow ltype t)
           (args : type.for_each_lhs_of_arrow API.interp_type t)
           (nextn : nat),
      (* ret1 := fiat-crypto interpretation of e1 applied to args1 *)
      let ret1 : base.interp (type.final_codomain t) :=
          type.app_curried (API.interp e1) args in
      (* out := translation output for e2; triple of
         (# varnames used, return values, cmd) *)
      let out := translate_func' e2 nextn argnames in
      let nvars := fst (fst out) in
      let ret2 := rtype_of_ltype (snd (fst out)) in
      let body := snd out in
      (* G doesn't contain variables we could accidentally overwrite *)
      (forall n,
          (nextn <= n)%nat ->
          Forall (varname_not_in_context (varname_gen n)) G) ->
      forall (tr : Semantics.trace)
             (locals : Semantics.locals)
             (mem : Semantics.mem)
             (functions : list bedrock_func),
        (* contexts are equivalent; for every variable in the context list G,
             the fiat-crypto and bedrock2 results match *)
        context_equiv G locals ->
        (* executing translation output is equivalent to interpreting e *)
        WeakestPrecondition.cmd
          (WeakestPrecondition.call functions)
          body tr mem locals
          (fun tr' mem' locals' =>
             tr = tr' /\
             mem = mem' /\
             Interface.map.only_differ
               locals (used_varnames nextn nvars) locals' /\
             locally_equivalent (listZ:=rep.listZ_local) ret1 ret2 locals').
  Admitted.

  (* TODO : move *)
  Fixpoint list_lengths_from_value {t}
    : base.interp t -> base_list_lengths t :=
    match t as t0 return base.interp t0 -> base_list_lengths t0 with
    | base.type.prod a b =>
      fun x : base.interp a * base.interp b =>
        (list_lengths_from_value (fst x),
         list_lengths_from_value (snd x))
    | base_listZ => fun x : list Z => length x
    | _ => fun _ => tt
    end.

  (* TODO : move *)
  Fixpoint list_lengths_from_args {t}
    : type.for_each_lhs_of_arrow API.interp_type t ->
      type.for_each_lhs_of_arrow list_lengths t :=
    match t with
    | type.base b => fun _ => tt
    | type.arrow (type.base a) b =>
      fun x =>
        (list_lengths_from_value (fst x), list_lengths_from_args (snd x))
    | type.arrow a b =>
      fun x => (tt, list_lengths_from_args (snd x))
    end.


  (* This lemma handles looking up the return values *)
  (* TODO : rename *)
  Lemma look_up_return_values {t} :
    forall (ret : base.interp t)
           (retnames : base_ltype (listZ:=rep.listZ_mem) t)
           (locals : Semantics.locals)
           (mem : Semantics.mem)
           (R : Semantics.mem -> Prop),
    sep (equivalent ret (rtype_of_ltype retnames) locals) R mem ->
    WeakestPrecondition.list_map
      (WeakestPrecondition.get locals) (flatten_retnames retnames)
      (fun flat_rets =>
         exists ret',
           WeakestPrecondition.dexprs mem map.empty (flatten_rets ret') flat_rets /\
           sep (equivalent ret ret' map.empty) R mem).
  Proof.
    cbv [flatten_retnames].
    induction t; cbn [flatten_base_ltype equivalent]; break_match;
      repeat match goal with
             | _ => progress (intros; cleanup)
             | _ => progress subst
             | _ => progress cbn [rep.equiv rep.listZ_mem rep.Z] in *
             | _ => progress cbn [WeakestPrecondition.list_map WeakestPrecondition.list_map_body]
             | H : sep (emp _) _ _ |- _ => apply sep_emp_l in H
             | H : WeakestPrecondition.dexpr _ _ _ _ |- _ => destruct H
             | |- WeakestPrecondition.get _ _ _ => eexists; split; [ eassumption | ]
             end.
    (* TODO *)
  Admitted.

  Lemma translate_func_correct {t}
        (e : API.Expr t)
        (* expressions are valid input to translate_func *)
        (e_valid : valid_func (e _)) :
    Wf3 e ->
    forall (fname : string)
           (retnames : base_ltype (type.final_codomain t))
           (argnames : type.for_each_lhs_of_arrow ltype t)
           (args1 : type.for_each_lhs_of_arrow API.interp_type t)
           (args2 : type.for_each_lhs_of_arrow rtype t),
      (* rets1 := fiat-crypto interpretation of e1 applied to args1 *)
      let rets1 : base.interp (type.final_codomain t) :=
          type.app_curried (API.interp (e _)) args1 in
      (* extract list lengths from fiat-crypto arguments/return values *)
      let arglengths := list_lengths_from_args args1 in
      let retlengths := list_lengths_from_value rets1 in
      (* out := translation output for e2; triple of
         (function arguments, function return variable names, body) *)
      let out := translate_func e argnames arglengths retnames in
      let f : bedrock_func := (fname, out) in
      forall (tr : Semantics.trace)
             (mem : Semantics.mem)
             (flat_args : list Semantics.word)
             (functions : list bedrock_func)
             (P Ra Rr : Semantics.mem -> Prop),
        (* argument values (in their 3 forms) are equivalent *)
        sep (equivalent_args args1 args2 map.empty) Ra mem ->
        WeakestPrecondition.dexprs
          mem map.empty (flatten_args args2) flat_args ->
        (* seplogic frame for return values *)
        sep (lists_reserved retlengths) Rr mem ->
        (* translated function produces equivalent results *)
        WeakestPrecondition.call
          ((fname, out) :: functions) fname tr mem flat_args
          (fun tr' mem' flat_rets =>
             tr = tr' /\
             exists rets2 : base_rtype (type.final_codomain t),
               (* rets2 is a valid representation of flat_rets with no local
                  variables in context *)
               WeakestPrecondition.dexprs
                 mem' map.empty (flatten_rets rets2) flat_rets /\
               (* return values are equivalent *)
               sep (equivalent (listZ:=rep.listZ_mem) rets1 rets2 map.empty) Rr mem').
  Proof.
    cbv [translate_func Wf3]; intros.
    cbn [WeakestPrecondition.call WeakestPrecondition.call_body WeakestPrecondition.func].
    rewrite eqb_refl.
    match goal with H : _ |- _ =>
                    pose proof H; eapply of_list_zip_flatten_argnames in H;
                      destruct H
    end.
    eexists; split; [ eassumption | ].
    cbn [WeakestPrecondition.cmd WeakestPrecondition.cmd_body].
    eapply Proper_cmd; [ solve [apply Proper_call] | repeat intro | ].
    2 : {
      eapply load_arguments_correct; eassumption. }
    cbv beta in *. cleanup; subst.
    eapply Proper_cmd; [ solve [apply Proper_call] | repeat intro | ].
    2 : { eapply translate_func'_correct with (args:=args1); cbv [context_equiv]; eauto. }
    cbv beta in *. cleanup; subst.
    eapply Proper_cmd; [ solve [apply Proper_call] | repeat intro | ].
    2 : { eapply store_return_values_correct; eauto. }
    cbv beta in *. cleanup; subst.

    eapply Proper_list_map; [ solve [apply Proper_get]
                            | | eapply look_up_return_values; solve [eauto] ].
    repeat intro; eauto.
  Qed.
End Func.