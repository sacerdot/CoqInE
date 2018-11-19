(** Translation of Coq universe levels *)

open Debug

module T = Dedukti.Translator

(** Get all global universes names together with their concrete levels *)
let get_universes_levels (universes:UGraph.t) =
  let universes = UGraph.sort_universes universes in
  let res = ref [] in
  let register constraint_type j k =
    match constraint_type with
    | Univ.Eq ->
      let closed_univ = Scanf.sscanf k "Type.%d" (fun x -> x) in
      res := (T.coq_univ_name j, Dedukti.mk_type closed_univ):: !res
    | Univ.Lt | Univ.Le -> () in
  UGraph.dump_universes register universes;
  !res


module StringSet = Set.Make(struct type t = string let compare = String.compare end)

(** Returns all global universes names and all constraints on these universes *)
let get_universes_constraints (universes:UGraph.t) =
  let defined_univs = ref StringSet.empty in
  let reg u =
    if      u = "Set"  then Dedukti.Set
    else if u = "Prop" then Dedukti.Prop
    else if Utils.str_starts_with "Type." u
    then
      let closed_univ = Scanf.sscanf u "Type.%d" (fun x -> x) in
      Dedukti.mk_type closed_univ
    else begin
      if not (StringSet.mem u !defined_univs)
      then defined_univs := StringSet.add u !defined_univs;
      Dedukti.Global u
    end
  in
  let res = ref [] in
  let register constraint_type j k =
    match reg j, reg k with
    | Dedukti.Prop, Dedukti.Set -> () (* ignore the Prop < Set constraint *)
    | jd, kd -> res := (j, jd, constraint_type, k, kd) :: !res in
  UGraph.dump_universes register universes;
  (StringSet.elements !defined_univs, List.rev !res)


(** Instructions for universe declaration as constant symbols and
  reduction rules on "sup" operator *)
let universe_encoding_float_noconstr (universes:UGraph.t) =
  (* This generates far too many constraints: takes a long time to typecheck. *)
  let unames, cstr = get_universes_constraints universes in
  let rw a b = Dedukti.rewrite ([], T.coq_pattern_universe a, T.coq_universe b) in
  let register inst (j, jd, constraint_type, k, kd) =
    match constraint_type with
    | Univ.Eq -> (rw jd                     kd) :: inst
    | Univ.Le -> (rw (Dedukti.Max [jd; kd]) kd) :: inst
    | Univ.Lt -> (rw (Dedukti.Max [jd; kd]) kd) ::
                 (rw (Dedukti.Max [Dedukti.Succ(jd,1); kd]) kd) :: inst in
  let decl_u u = Dedukti.declaration false (T.coq_univ_name u) (T.coq_Sort ()) in
  (List.map decl_u unames) @ Dedukti.EmptyLine :: (List.fold_left register [] cstr)

(** Instructions for universe declaration as constant symbols and
  constant constraints constructors. *)
let universe_encoding_float_constr (universes:UGraph.t) =
  let unames, cstr = get_universes_constraints universes in
  let counter = ref 0 in
  let decl cstr_type =
    incr counter;
    let fresh_name = "cstr_" ^ (string_of_int !counter) in
    Dedukti.declaration false fresh_name cstr_type
  in
  let register inst (j, jd, constraint_type, k, kd) =
    match constraint_type with
    | Univ.Eq -> (decl (T.cstr_leq jd kd)) ::
                 (decl (T.cstr_leq kd jd)) :: inst
    | Univ.Le -> (decl (T.cstr_leq jd kd)) :: inst
    | Univ.Lt -> (decl (T.cstr_le  jd kd)) :: inst in
  let decl_u u = Dedukti.declaration false (T.coq_univ_name u) (T.coq_Sort ()) in
  (List.map decl_u unames) @ Dedukti.EmptyLine :: (List.fold_left register [] cstr)

(** Instructions for universes declaration as defined symbols
  reducing to their concrete levels. *)
let universe_encoding_nofloat (universes:UGraph.t) =
  let get_definition (name, lvl) =
    Dedukti.definition false name (T.coq_Sort ()) (T.coq_universe lvl) in
  List.map get_definition (get_universes_levels universes)

let translate_all_universes (info:Info.info) (universes:UGraph.t) =
  message "Translating global universes";
  (pp_list "" Dedukti.printc) info.Info.fmt
    (match Encoding.is_float_univ_on (), Encoding.is_constraints_on () with
     | true , true  -> universe_encoding_float_constr   universes
     | true , false -> universe_encoding_float_noconstr universes
     | false, _     -> universe_encoding_nofloat universes)