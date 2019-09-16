open Dedukti
open Encoding

type cic_universe =
  | Prop
  | Set
  | GlobalSort  of string
  | GlobalLevel of string
  | NamedSort   of string
  | NamedLevel  of string
  | Local of int
  | Succ of cic_universe * int
  | Max of cic_universe list
  | Rule of cic_universe * cic_universe
  | SInf

let mk_type i = Succ (Prop, i+1)


let add_prefix prefix name = Printf.sprintf "%s.%s" prefix name
let coq_var  x = Var (add_prefix (symb "encoding_file")   x)
let univ_var x = Var (add_prefix (symb "universe_file") x)

let vsymb s = coq_var (symb s)
let vsymbu s () = vsymb s

let coq_Sort  = vsymbu "Sort"
let coq_Nat   = vsymbu "Nat"
let coq_uset  = vsymbu "uSet"
let coq_s     = vsymbu "uSucc"
let coq_z     = vsymbu "uType0"
let coq_nat n = Utils.iterate n (app (coq_s ())) (coq_z())
let coq_prop  = vsymbu "prop"
let coq_set   = vsymbu "set"
let coq_type u = app (vsymb "type") u
(* let coq_nat_of_univ = app (vsymb "level")  *)

let coq_var_univ_name n = "s" ^ string_of_int n

let coq_univ_name s = String.concat "__" (String.split_on_char '.' s)

let coq_header () =
  [
    comment "This file was automatically generated by Coqine.";
    comment ("The encoding used was: \"" ^ (symb "encoding_name") ^ "\".");
    EmptyLine
  ]
let coq_footer = [ comment "End of translation." ]

module Std =
struct

  let coq_proj i t   = app (app (coq_var "proj") (coq_nat i)) t

  let coq_succ s    = app  (vsymb "uSucc") s
  let coq_succs s i = Utils.iterate i coq_succ s
  let rec coq_max  = function
    | [] -> assert false
    | [u] -> u
    | (u :: u_list) -> apps (vsymb "uMax") [u; coq_max u_list]
  let rec cl = function
    | Succ (u   ,0) -> cl u
    | Succ (Succ(u,i), j) -> cl (Succ (u,i+j))
    | Prop          -> assert false
    | Set           -> vsymb "uSet"
    | Succ (Set ,i) -> coq_nat (i-1)
    | Succ (Prop,i) -> coq_nat (i-1)
    | GlobalLevel n -> var (coq_univ_name n)
    | GlobalSort _  -> assert false
    | NamedLevel n  -> var (coq_univ_name n)
    | NamedSort _   -> assert false
    | Local n       -> var ("s" ^ string_of_int n)
    | Succ (u,i)    -> coq_succs (cl u) i
    | Max u_list    -> coq_max (List.map cl u_list)
    | Rule (s1,s2)  -> assert false (* coq_max [cl s1; cl s2] *)
    | SInf          -> assert false

  let coq_axiom s    = app  (vsymb "axiom") s
  let coq_axioms s i = Utils.iterate i coq_axiom s
  let coq_rule s1 s2 = apps (vsymb "rule") [s1; s2]
  let rec coq_sup  = function
    | [] -> coq_prop ()
    | [u] -> u
    | (u :: u_list) -> apps (vsymb "sup") [u; coq_sup u_list]
  let rec cu = function
    | Succ (u   ,0) -> cu u
    | Succ (Succ(u,i), j) -> cu (Succ (u,i+j))
    | Prop          -> coq_prop ()
    | Set           -> coq_set ()
    | Succ (Set ,i) -> coq_type (coq_nat (i-1))
    | Succ (Prop,i) -> coq_type (coq_nat (i-1))
    | GlobalSort name  -> univ_var (coq_univ_name name)
    | GlobalLevel name -> coq_type (univ_var (coq_univ_name name))
    | NamedSort name   -> var (coq_univ_name name)
    | NamedLevel name  -> coq_type (var (coq_univ_name name))
    | Local n          -> coq_type (var ("s" ^ string_of_int n))
    (* Locally quantified universe variable v is translated as "type v"
       when used as a Sort *)
    | Succ (u,i)    -> coq_axioms (cu u) i
    | Max u_list    -> coq_sup (List.map cu u_list)
    | Rule (s1,s2)  -> coq_rule (cu s1) (cu s2)
    | SInf          -> vsymb "_code_sinf"

  let rec cpu = function
    | Succ (u, 0)   -> cpu u
    | Succ (Succ(u,i), j) -> cpu (Succ (u,i+j))
    | Succ (u,i)    -> coq_axioms (cu u) i
    | Max u_list    -> coq_sup (List.map cpu u_list)
    | Rule (s1,s2)  -> coq_rule (cpu s1) (cpu s2)
    | u -> cu u
  let coq_pattern_universe u = cpu u
  let coq_nat_universe u = assert false

  let coq_U    s           = app  (vsymb "Univ") (cu s)
  let coq_term s  a        = apps (vsymb "Term") [cu s; a]

  let t_I = vsymbu "I"
  let coq_sort cu s = apps (vsymb "univ")
      (if (flag "pred_univ")
       then [cu s; cu (Succ (s,1)); t_I()]
       else [cu s])
  let coq_prod cu s1 s2 a b   = apps (vsymb "prod")
      (if (flag "pred_prod")
       then [cu s1; cu s2; cu (Rule (s1,s2)); t_I(); a; b]
       else [cu s1; cu s2; a; b])
  let coq_cast cu s1 s2 a b cstr t =
    let rec coq_cstr_inhabitant = function
      | [] -> t_I()
      | [ c ] -> c
      | c :: tl -> apps (vsymb "pair") [c; coq_cstr_inhabitant tl]
    in
    let cstr = coq_cstr_inhabitant (List.filter (fun c -> c <> t_I()) cstr) in
    apps (vsymb "cast")
      (if flag "pred_cast"
       then [cu s1; cu s2; a; b; cstr; t]
       else [cu s1; cu s2; a; b;       t])
  let coq_coded u t =
    apps (vsymb "_code") [ app (vsymb "_code_univ") u; t]
  let coq_pcast cu s1 s2 a b t =
    if flag "pred_cast"
    then
      if flag "priv_cast"
      then apps (vsymb "_cast") [cu s1; cu s2; a; b;t]
      else
        let ca = coq_coded (cu s1) a in
        let cb = coq_coded (cu s2) b in
        apps (vsymb "_uncode") [ cb; apps (vsymb "_code") [ca ; t ] ]
    else coq_cast cu s1 s2 a b [] t
  let coq_lift cu s1 s2 t = apps (vsymb "lift")
      (if flag "pred_lift"
       then [cu s1; cu s2; t_I(); t]
       else [cu s1; cu s2;        t])


  let cstr_le cu s1 s2 = app (vsymb "eps") (apps (vsymb "Cumul") [cu s1            ; cu s2])
  let cstr_lt cu s1 s2 = app (vsymb "eps") (apps (vsymb "Cumul") [coq_axiom (cu s1); cu s2])
  let cstr_eq cu s1 s2 = app (vsymb "eps") (apps (vsymb "Eq"   ) [cu s1            ; cu s2])

end


(* ------------ Redefining all functions for readable translation ------- *)
module Short =
struct

  let nat_name u = "_n" ^ (string_of_int u)
  let nat_var  u = (var (nat_name u))

  let sort_name u = "_" ^ (string_of_int u)
  let sort_var  u = (var (sort_name u))

  let code_name u = "_u" ^ (string_of_int u)
  let code_var  u = (var (code_name u))

  let rec short_nat i =
    if i <= 9 then nat_var i else app (coq_s()) (short_nat (i-1))

  let short_type i =
    if i <= 9 then sort_var i else coq_type (short_nat i)

  let rec scl = function
    | Succ (u,0)    -> scl u
    | Succ (Succ(u,i), j) -> scl (Succ (u,i+j))
    | Succ (Set ,i) -> short_nat (i-1)
    | Succ (Prop,i) -> assert (i > 0); short_nat (i-1)
    | Succ (u,i)    -> Std.coq_succs (scl u) i
    | Max u_list    -> Std.coq_max (List.map scl u_list)
    | Rule (s1,s2)  -> Std.coq_max [scl s1; scl s2]
    | s -> Std.cl s

  let rec scu = function
    | Succ (u,0)    -> scu u
    | Succ (Succ(u,i), j) -> scu (Succ (u,i+j))
    | Succ (Set ,i) -> short_type (i-1)
    | Succ (Prop,i) -> short_type (i-1)
    | Succ (u,i)    -> Std.coq_axioms (scu u) i
    | Max u_list    -> Std.coq_sup (List.map scu u_list)
    | Rule (s1,s2)  -> Std.coq_rule (scu s1) (scu s2)
    | s -> Std.cu s

  let short_code i =
    if i <= 9 then code_var i else Std.coq_sort scu (Succ(Set,i+1))

  let short_U    s   = app  (vsymb "Univ") (scu s)
  let short_term s a = apps (vsymb "Term") [scu s; a]
  let rec short_sort = function
    | Succ (u   ,0) -> short_sort u
    | Succ (Succ(u,i), j) -> short_sort (Succ (u,i+j))
    | Max [] -> var "_prop"
    | Max [u] -> short_sort u
    | Succ (Set ,i) -> short_code (i-1)
    | Succ (Prop,i) -> short_code (i-1)
    | Set  -> var "_set"
    | Prop -> var "_prop"
    | u -> Std.coq_sort scu u

  let short_proj i t = app (app (coq_var "proj") (short_nat i)) t

  (* Redefining headers first then overriding previous definitions. *)
  let coq_header () =
    let res = ref [] in
    let add n t = res := (udefinition false n t) :: !res in
    add (nat_name 0) (coq_z());
    for i = 1 to 9 do add ( nat_name i) (app (coq_s()     ) (nat_var (i-1))) done;
    for i = 0 to 9 do add (sort_name i) (coq_type           (nat_var i    )) done;
    for i = 0 to 9 do add (code_name i) (Std.coq_sort scu (mk_type i)) done;
    add "_Set"  (Std.coq_U    Set );
    add "_Prop" (Std.coq_U    Prop);
    add "_set"  (Std.coq_sort scu Set );
    add "_prop" (Std.coq_sort scu Prop);
    coq_header() @
    (comment "------------  Short definitions  -----------") ::
    EmptyLine ::
    (List.rev !res) @
    EmptyLine ::
    (comment "--------  Begining of translation  ---------") ::
    EmptyLine :: []

end

module T =
struct

  let coq_Nat           = coq_Nat
  let coq_Sort          = coq_Sort
  let coq_var_univ_name = coq_var_univ_name
  let coq_univ_name     = coq_univ_name
  let coq_global_univ   = univ_var
  let coq_pattern_universe = Std.coq_pattern_universe
  let coq_nat_universe = Std.coq_nat_universe

  let a () = not (is_readable_on ())

  let coq_level    s = if a() then Std.cl       s else Short.scl        s
  let coq_universe s = if a() then Std.cu       s else Short.scu        s
  let coq_U        s = if a() then Std.coq_U    s else Short.short_U    s
  let coq_term     s = if a() then Std.coq_term s else Short.short_term s
  let coq_sort     s = if a() then Std.coq_sort Std.cu s else Short.short_sort s

  let coq_prod     s = Std.coq_prod  (if a() then Std.cu else Short.scu) s
  let coq_cast     s = Std.coq_cast  (if a() then Std.cu else Short.scu) s
  let coq_pcast    s = Std.coq_pcast (if a() then Std.cu else Short.scu) s
  let coq_lift     s = Std.coq_lift  (if a() then Std.cu else Short.scu) s
  let coq_coded = Std.coq_coded

  let cstr_le      s = Std.cstr_le   (if a() then Std.cu else Short.scu) s
  let cstr_lt      s = Std.cstr_lt   (if a() then Std.cu else Short.scu) s
  let cstr_eq      s = Std.cstr_eq   (if a() then Std.cu else Short.scu) s
  let coq_cstr = function
    | Univ.Lt -> cstr_lt
    | Univ.Le -> cstr_le
    | Univ.Eq -> cstr_eq
  let coq_I = Std.t_I

  let coq_pattern_lifted_from_sort s t =
    match symb "lifted_type_pattern" with
    | "lift" ->
      (if (flag "pred_lift")
         then apps (vsymb "_lift") [s;wildcard;t]
         else apps (vsymb  "lift") [s;wildcard;t])
    | "cast" ->
      let univ s =
        if (flag "priv_univ")
        then apps (vsymb "_univ") [s; wildcard]
        else
          apps (vsymb "univ")
            (if (flag "pred_univ")
             then [s; wildcard; wildcard]
             else [s]) in
      if (flag "priv_cast")
      then apps (vsymb "_cast") [wildcard;wildcard;univ s;wildcard;t]
      else
        let uwildcard =
          apps (vsymb "univ") (if (flag "pred_univ")
                               then [wildcard]
                               else [wildcard;wildcard;wildcard]) in
        apps (vsymb "cast")
          (if (flag "pred_cast")
           then [wildcard;wildcard;univ s;uwildcard;wildcard;t]
           else [wildcard;wildcard;univ s;uwildcard;t])
    | "recoded" ->
      let s_code = app (vsymb "_code_univ") s in
      apps (vsymb "_uncode") [wildcard;apps (vsymb "_code") [s_code;t]]
    | s -> failwith ("Unexpected lifted_type_pattern value: " ^ s)
  let coq_pattern_lifted_from_level l t =
    coq_pattern_lifted_from_sort (coq_type (Dedukti.var l)) t

  let coq_proj     s = if a() then Std.coq_proj s else Short.short_proj s
  let coq_header   s = if a() then coq_header   s else Short.coq_header s
  let coq_footer  () = coq_footer

  let coq_fixpoint n arities bodies i =
    let coq_N n =
      assert (n >= 0);
      if n < 10 then coq_var (string_of_int n)
      else Utils.iterate n (app (vsymb "S")) (vsymb "0") in
    let coq_arity (s,k,a) =
      apps (vsymb "SA") [coq_N k; s; a] in
    assert (Encoding.is_fixpoint_inlined ());
    assert (Array.length arities = n);
    assert (Array.length bodies = n);
    assert (i < n);
    let make_arities =
      ulam "c" (apps (var "c") (Array.to_list (Array.map coq_arity arities))) in
    let make_bodies =
      ulam "c" (apps (var "c") (Array.to_list bodies)) in
    apps (vsymb "fix_oneline")
      (if flag "fix_arity_sort"
       then [ coq_N n; make_arities; make_bodies; coq_N i]
       else
         let (sort,_,_) = arities.(0) in
         [ sort; coq_N n; make_arities; make_bodies; coq_N i]
      )

  let coq_guarded consname args =
    let applied_cons = Utils.iterate args (fun x -> app x wildcard) (var consname) in
    let lhs =
      if flag "code_guarded"
      then apps (vsymb "code_guard")      [wildcard; applied_cons]
      else apps (vsymb "guard") [wildcard; wildcard; applied_cons] in
    rewrite ([],lhs,vsymb "guarded")

end
