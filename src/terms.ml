(** Translation of Coq terms *)

open Term

open Environment

let infer_type env t =
  (fst (Typeops.infer env.env t)).Environ.uj_type
  
let infer_sort env a =
  (fst (Typeops.infer_type env.env a)).Environ.utj_type

let coq x = Dedukti.Var(Name.coq x)

let coq_type s = Dedukti.apps (coq "type") [s]
let coq_term s a = Dedukti.apps (coq "term") [s; a]
let coq_sort s = Dedukti.apps (coq "sort") [s]
let coq_prod s1 s2 a b = Dedukti.apps (coq "prod") [s1; s2; a; b]
let coq_cast s1 s2 a b t = Dedukti.apps (coq "cast") [s1; s2; a; b; t]

let translate_sort env s =
  match s with
  | Prop(Null) -> Universes.coq_p
  | Prop(Pos) -> Universes.coq_z
  | Type(i) -> Universes.translate_universe env i

(** Infer and translate the sort of [a].
    Coq fails if we try to type a sort that was already inferred.
    This function uses pattern matching to avoid it. *)
let infer_translate_sort env a =
   match Term.kind_of_type a with
  | SortType(s) -> Universes.coq_t (translate_sort env s)
  | _ -> translate_sort env (infer_sort env a)

(** Abstract over the variables of [context], ignoring let declarations. *)
let abstract_rel_context context t =
  let abstract_rel_declaration t (x, u, a) =
    match u with
    | None -> Term.mkLambda (x, a, t)
    | Some(_) -> t in
  List.fold_left abstract_rel_declaration t context

(** Generalize over the variables of [context], ignoring let declarations. *)
let generalize_rel_context context b =
  let generalize_rel_declaration b (x, u, a) =
    match u with
    | None -> Term.mkProd(x, a, b)
    | Some(_) -> b in
  List.fold_left generalize_rel_declaration b context

(** Apply the variables of [context] to [t], ignoring let declarations. *)
let apply_rel_context t context =
  let apply_rel_declaration (args, i) (x, t, a) =
    match t with
    | None -> (Term.mkRel(i) :: args, i + 1)
    | Some(_) -> (args, i + 1) in
  let args, _ = List.fold_left apply_rel_declaration ([], 1) context in
  Term.applistc t args

let convertible env a b =
  try let _ = Reduction.conv env.env a b in true
  with | Assert_failure _| Reduction.NotConvertible | Util.Anomaly _ -> false

(** This table holds the translations of fixpoints, so that we avoid
    translating the same definition multiple times (e.g. mutual fixpoints). *)
let fixpoint_table = Hashtbl.create 10007

(** Translate the Coq term [t] as a Dedukti term. *)
let rec translate_constr ?expected_type env t =
  (* Check if the expected type coincides, otherwise make an explicit cast. *)
  let t =
    match expected_type with
    | None -> t
    | Some(a) ->
        let b = infer_type env t in
        if convertible env a b then t else Term.mkCast(t, Term.VMcast, a) in
  match Term.kind_of_term t with
  | Rel(i) ->
      (* If it's a let definition, replace by its value. *)
      let (x, u, _) = Environ.lookup_rel i env.env in
      begin match u with
      | Some(u) -> translate_constr env (Term.lift i u)
      | None -> Dedukti.var (Name.translate_name ~ensure_name:true x)
      end
  | Var(x) ->
      Dedukti.var (Name.translate_identifier x)
  | Meta(metavariable) -> failwith "Not implemented: Meta"
  | Evar(pexistential) -> failwith "Not implemented: Evar"
  | Sort(s) ->
      let s' = translate_sort env s in
      coq_sort s'
  | Cast(t, _, b) ->
      let a = infer_type env t in
      let s1' = infer_translate_sort env a in
      let s2' = infer_translate_sort env b in
      let a' = translate_constr env a in
      let b' = translate_constr env b in
      let t' = translate_constr env t in
      coq_cast s1' s2' a' b' t'
  | Prod(x, a, b) ->
      let x = Name.fresh_name env x in
      let s1' = infer_translate_sort env a in
      let s2' = infer_translate_sort (Environment.push_rel (x, None, a) env) b in
      let x' = Name.translate_name x in
      let a' = translate_constr env a in
      let a'' = translate_types env a in
      let b' = translate_constr (Environment.push_rel (x, None, a) env) b in
      coq_prod s1' s2' a' (Dedukti.lam (x', a'') b')
  | Lambda(x, a, t) ->
      let x = Name.fresh_name ~default:"var" env x in
      let x' = Name.translate_name x in
      let a'' = translate_types env a in
      let t' = translate_constr (Environment.push_rel (x, None, a) env) t in
      Dedukti.lam (x', a'') t'
  | LetIn(x, u, a, t) ->
      let env, u = lift_let env x u a in
      translate_constr (Environment.push_rel (x, Some(u), a) env) t
  | App(t, args) ->
      let a = infer_type env t in
      let translate_app (t', a) u =
        let _, c, d = Term.destProd (Reduction.whd_betadeltaiota env.env a) in
        let u' = translate_constr ~expected_type:c env u in
        (Dedukti.app t' u', Term.subst1 u d) in
      let t' = translate_constr env t in
      fst (Array.fold_left translate_app (t', a) args)
  | Const(c) ->
      Dedukti.var(Name.translate_constant env c)
  | Ind(i) ->
      Dedukti.var(Name.translate_inductive env i)
  | Construct(c) ->
      Dedukti.var(Name.translate_constructor env c)
  | Case(case_info, return_type, matched, branches) ->
      let ind = case_info.ci_ind in
      let mind_body, ind_body = Inductive.lookup_mind_specif env.env case_info.ci_ind in
      let n_params = mind_body.Declarations.mind_nparams in
      let n_reals = ind_body.Declarations.mind_nrealargs in
      let _, ind_args = Inductive.find_inductive env.env (infer_type env matched) in
      let params, reals = Util.list_chop n_params ind_args in
      let context, end_type = Term.decompose_lam_n_assum (n_reals + 1) return_type in
      let return_sort = infer_sort (Environment.push_rel_context context env) end_type in
      let match_function' = Dedukti.var (Name.translate_match_function env ind) in
      let params' = List.map (translate_constr env) params in
      let reals' = List.map (translate_constr env) reals in
      let return_sort' = translate_sort env return_sort in
      let return_type' = translate_constr env return_type in
      let matched' = translate_constr env matched in
      let branches' = Array.to_list (Array.map (translate_constr env) branches) in
      Dedukti.apps match_function' (params' @ return_sort' :: return_type' :: branches' @ reals' @  [matched'])
  | Fix((rec_indices, i), ((names, types, bodies) as rec_declaration)) ->
      let n = Array.length names in
      let env, fix_declarations =
        try Hashtbl.find fixpoint_table rec_declaration
        with Not_found -> lift_fix env names types bodies rec_indices in
      let env = Array.fold_left (fun env declaration ->
        Environment.push_rel declaration env) env fix_declarations in
      translate_constr env (Term.mkRel (n - i))
  | CoFix(pcofixpoint) -> failwith "Not implemented: CoFix"

(** Translate the Coq type [a] as a Dedukti type. *)
and translate_types env a =
  (* Specialize on the type to get a nicer and more compact translation. *)
  match Term.kind_of_type a with
  | SortType(s) ->
      let s' = translate_sort env s in
      coq_type s'
  | CastType(a, b) ->
      failwith "Not implemented: CastType"
  | ProdType(x, a, b) ->
      let x = Name.fresh_name env x in
      let x' = Name.translate_name x in
      let a' = translate_types env a in
      let b' = translate_types (Environment.push_rel (x, None, a) env) b in
      Dedukti.pie (x', a') b'
  | LetInType(x, u, a, b) ->
      let env, u = lift_let env x u a in
      translate_constr (Environment.push_rel (x, Some(u), a) env) b
  | AtomicType(_) ->
      (* Fall back on the usual translation of types. *)
      let s = infer_sort env a in
      let s' = translate_sort env s in
      let a' = translate_constr env a in
      coq_term s' a'

and lift_let env x u a =
(*  Environ.push_rel (x, Some(u), a) env*)
  let y = Name.fresh_identifier_of_name ~global:true ~prefix:["let"] ~default:"_" env x in
  let rel_context = Environ.rel_context env.env in
  let a_closed = generalize_rel_context rel_context a in
  let u_closed = abstract_rel_context rel_context u in
  let env = Environment.push_named (y, Some(u_closed), a_closed) env in
  let y' = Name.translate_identifier y in
  let a_closed' = translate_types env a_closed in
  let u_closed' = translate_constr env u_closed in
  Dedukti.print env.out (Dedukti.definition false y' a_closed' u_closed');
  env, apply_rel_context (Term.mkVar y) rel_context

and lift_fix env names types bodies rec_indices =
  (* A fixpoint is translated by 3 functions:
     - The first function duplicates the argument and sends it to the second.
     - The second pattern matches on the second arguments, then throws it away
       and passes the first argument to the third function.
     - The third function executes the body of the fixpoint. *)
  (* fix1_f : |G| -> |x1| : ||A1|| -> ... -> |xr| : ||I u1 ... un|| -> ||A||.
     fix2_f : |G| -> |x1| : ||A1|| -> ... -> |xr| : ||I u1 ... un|| -> |y1| : ||B1|| -> ... -> |yn| : ||Bn|| -> ||I y1 ... yn|| -> ||A||.
     fix3_f : |G| -> |x1| : ||A1|| -> ... -> |xr| : ||I u1 ... un|| -> ||A||.
     [...] fix1_f |G| |x1| ... |xr| --> fix2_f |x1| ... |xr| |u1| ... |un| |xr|.
     [...] fix2_f |G| |x1| ... |xr| {|uj1|} ... {|ujn|} (|cj z1 ... zkj|) --> fix3_f |G| |x1| ... |xr|.
     [...] fix3_f |G| |x1| ... |xr| --> |[(fix1_f G)/f]t|. *)
  let n = Array.length names in
  let fix_names1 = Array.map (Name.fresh_identifier_of_name ~global:true ~prefix:["fix"] ~default:"_" env) names in
  let fix_names2 = Array.map (Name.fresh_identifier_of_name ~global:true ~prefix:["fix"] ~default:"_" env) names in
  let fix_names3 = Array.map (Name.fresh_identifier_of_name ~global:true ~prefix:["fix"] ~default:"_" env) names in
  let contexts_return_types = Array.mapi (fun i -> Term.decompose_prod_n_assum (rec_indices.(i) + 1)) types in
  let contexts = Array.map fst contexts_return_types in
  for i = 0 to n - 1 do
    assert (List.length contexts.(i) > rec_indices.(i));
(*    assert (List.length contexts.(i) = rel_context_length contexts.(i))*)
  done;
  let return_types = Array.map snd contexts_return_types in
  let ind_applieds = Array.map (fun context -> let (_, _, a) = List.hd context in a) contexts in
  let inds_args = Array.map (Inductive.find_inductive env.env) ind_applieds in
  let inds = Array.map fst inds_args in
  let ind_args = Array.map snd inds_args in
  let ind_specifs = Array.map (Inductive.lookup_mind_specif env.env) inds in
  let arities = Array.map (fun ind_specif -> Inductive.type_of_inductive env.env ind_specif) ind_specifs in
  let arity_contexts = Array.map (fun arity -> fst (Term.decompose_prod_assum arity)) arities in
  let ind_applied_arities = Array.init n (fun i -> apply_rel_context (Term.mkInd inds.(i)) arity_contexts.(i)) in
  let types1 = types in
  let types2 = Array.init n (fun i ->
    generalize_rel_context contexts.(i) (
    generalize_rel_context arity_contexts.(i) (
    Term.mkArrow ind_applied_arities.(i) (Term.lift (List.length arity_contexts.(i) + 1) return_types.(i))))) in
  let types3 = types in
  let rel_context = Environ.rel_context env.env in
  let types1_closed = Array.map (generalize_rel_context rel_context) types1 in
  let types2_closed = Array.map (generalize_rel_context rel_context) types2 in
  let types3_closed = Array.map (generalize_rel_context rel_context) types3 in
  let name1_declarations = Array.init n (fun j -> (fix_names1.(j), None, types1_closed.(j))) in
  let name2_declarations = Array.init n (fun j -> (fix_names2.(j), None, types2_closed.(j))) in
  let name3_declarations = Array.init n (fun j -> (fix_names3.(j), None, types3_closed.(j))) in
  let fix_names1' = Array.map Name.translate_identifier fix_names1 in
  let fix_names2' = Array.map Name.translate_identifier fix_names2 in
  let fix_names3' = Array.map Name.translate_identifier fix_names3 in
  let types1_closed' = Array.map (translate_types env) types1_closed in
  let types2_closed' = Array.map (translate_types env) types2_closed in
  let types3_closed' = Array.map (translate_types env) types3_closed in
  for i = 0 to n - 1 do
    Dedukti.print env.out (Dedukti.declaration fix_names1'.(i) types1_closed'.(i));
    Dedukti.print env.out (Dedukti.declaration fix_names2'.(i) types2_closed'.(i));
    Dedukti.print env.out (Dedukti.declaration fix_names3'.(i) types3_closed'.(i));
  done;
  let fix_terms1 = Array.init n (fun i -> Term.mkVar fix_names1.(i)) in
  let fix_terms2 = Array.init n (fun i -> Term.mkVar fix_names2.(i)) in
  let fix_terms3 = Array.init n (fun i -> Term.mkVar fix_names3.(i)) in
  let fix_rules1 = Array.init n (fun i ->
    let env, context' = translate_rel_context env (contexts.(i) @ rel_context) in
    let fix_term1' = translate_constr env fix_terms1.(i) in
    let fix_term2' = translate_constr env fix_terms2.(i) in
    let ind_args' = List.map (translate_constr env) ind_args.(i) in
    [(context', Dedukti.apply_context fix_term1' context',
      Dedukti.apps (Dedukti.apply_context fix_term2' context')
        (ind_args' @ [Dedukti.var (fst (List.nth context' (List.length context' - 1)))]))]) in
  let fix_rules2 = Array.init n (fun i ->
    let cons_arities = Inductive.arities_of_constructors inds.(i) ind_specifs.(i) in
    let cons_contexts_types = Array.map Term.decompose_prod_assum cons_arities in
    let cons_contexts = Array.map fst cons_contexts_types in
    let cons_types = Array.map snd cons_contexts_types in
    let cons_ind_args = Array.map (fun cons_type -> snd (Inductive.find_inductive env.env cons_type)) cons_types in
    let n_cons = Array.length cons_types in
    let cons_rules = Array.init n_cons (fun j ->
      let env, context' = translate_rel_context env (contexts.(i) @ rel_context) in
      let env, cons_context' = translate_rel_context env (cons_contexts.(j)) in
      let fix_term2' = translate_constr env fix_terms2.(i) in
      let fix_term3' = translate_constr env fix_terms3.(i) in
      let cons_term' = translate_constr env (Term.mkConstruct ((inds.(i), j + 1))) in
      let cons_term_applied' = Dedukti.apply_context cons_term' cons_context' in
      let cons_ind_args' = List.map (translate_constr env) cons_ind_args.(j) in
      (context' @ cons_context', Dedukti.apps (Dedukti.apply_context fix_term2' context') (cons_ind_args' @ [cons_term_applied']),
        Dedukti.apply_context fix_term3' context')) in
    Array.to_list cons_rules) in
  let env = Array.fold_left (fun env declaration -> Environment.push_named declaration env) env name1_declarations in
  let env = Array.fold_left (fun env declaration -> Environment.push_named declaration env) env name2_declarations in
  let env = Array.fold_left (fun env declaration -> Environment.push_named declaration env) env name3_declarations in
  let fix_applieds1 = Array.init n (fun i -> apply_rel_context fix_terms1.(i) rel_context) in
  (* The declarations need to be lifted to account for the displacement. *)
  let fix_declarations1 = Array.init n (fun i ->
    (names.(i), Some(Term.lift i fix_applieds1.(i)), Term.lift i types.(i))) in
  let fix_rules3 = Array.init n (fun i ->
    let env, rel_context' = translate_rel_context (Environment.global_env env) rel_context in
    let env = Array.fold_left (fun env declaration -> Environment.push_named declaration env) env name1_declarations in
    let env = Array.fold_left (fun env declaration -> Environment.push_named declaration env) env name2_declarations in
    let env = Array.fold_left (fun env declaration -> Environment.push_named declaration env) env name3_declarations in
    let fix_term3' = translate_constr env fix_terms3.(i) in
    let env = Array.fold_left (fun env declaration ->
      Environment.push_rel declaration env) env fix_declarations1 in
    let body' = translate_constr env bodies.(i) in
    let env , context' = translate_rel_context env contexts.(i) in
    [(rel_context' @ context', Dedukti.apply_context fix_term3' rel_context', body')]) in
  for i = 0 to n - 1 do
    Dedukti.print env.out (Dedukti.rewrite(fix_rules1.(i)));
    Dedukti.print env.out (Dedukti.rewrite(fix_rules2.(i)));
    Dedukti.print env.out (Dedukti.rewrite(fix_rules3.(i)))
  done;
  Hashtbl.add fixpoint_table (names, types, bodies) (env, fix_declarations1);
  env, fix_declarations1

(** Translate the context [x1 : a1, ..., xn : an] into the list
    [x1, ||a1||; ...; x1, ||an||], ignoring let declarations. *)
and translate_rel_context env context =
  let translate_rel_declaration (x, u, a) (env, translated) =
    match u with
    | None ->
        let x = Name.fresh_name ~default:"var" env x in
        let x' = Name.translate_name x in
        let a' = translate_types env a in
        (Environment.push_rel (x, u, a) env, (x', a') :: translated)
    | Some(u) ->
        (Environment.push_rel (x, Some(u), a) env, translated) in
  let env, translated = List.fold_right translate_rel_declaration context (env, []) in
  (* Reverse the list as the newer declarations are on top. *)
  (env, List.rev translated)

let translate_args env ts =
  List.map (translate_constr env) ts

(** Translate an external declaration which does not have a real type in Coq
    and push it on the environment. *)
let translate_external env identifier =
  (Environment.push_identifier identifier env, Name.translate_identifier identifier)

