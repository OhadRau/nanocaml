open Batteries
open Ast

type 'a loc = 'a Asttypes.loc
type fun_arg = Asttypes.arg_label * expression option * pattern

(** represents a nanopass definition **)
type np_pass =
  { npp_name : string
  ; npp_loc : Location.t
  ; npp_input : Lang.np_language
  ; npp_output : Lang.np_language
  ; npp_pre : expression -> expression
  ; npp_post : expression
  ; npp_procs : np_processor list }

(** represents a processor definition (a transformation
    between nonterminals in a nanopass) **)
and np_processor =
  { npc_name : string
  ; npc_loc : Location.t
  ; npc_nonterm : Lang.np_nonterm
  ; npc_args : fun_arg list
  ; npc_clauses : clause list }

and clause = np_pat * expression

(** represents a pattern in a production. the pattern must be parsed
    by nanocaml so that we can correctly map over lists and apply
    catamorphims, e.g. for expressions like [(x, e [@r]) [@l]]. **)
and np_pat
  = NPpat of pattern (* <other patterns, like constants or :: > *)
  | NPpat_any of Location.t (* _ *)
  | NPpat_var of string loc (* x *)
  | NPpat_alias of np_pat * string loc (* p as x *)
  | NPpat_tuple of np_pat list * Location.t (* (p, ...) *)
  | NPpat_variant of string * np_pat option * Location.t (* `X p *)
  | NPpat_map of np_pat (* list destructuring, e.g. (p [@l]) *)
  | NPpat_cata of np_pat * expression option (* p [@r <optional explicit cata>] *)


(** returns the [Location.t] of the given pattern. **)
let rec loc_of_pat = function
  | NPpat {ppat_loc} -> ppat_loc
  | NPpat_any loc -> loc
  | NPpat_var {loc} -> loc
  | NPpat_alias (_, {loc}) -> loc
  | NPpat_tuple (_, loc) -> loc
  | NPpat_variant (_, _, loc) -> loc
  | NPpat_map p -> loc_of_pat p
  | NPpat_cata (p, _) -> loc_of_pat p


(** convert the RHS of a [let] into a [np_processor]. **)
let rec processor_of_rhs ~name ~nonterm ~loc e0 =
  let rec get_args acc = function
    | {pexp_desc = Pexp_fun (lbl, dflt, pat, body)} ->
       let arg = lbl, dflt, pat in
       get_args (arg::acc) body
    | {pexp_desc = Pexp_function cases } ->
       List.rev acc, cases
    | {pexp_loc = loc} ->
       Location.raise_errorf ~loc
         "processor must end in 'function' expression"
  in
  let clause_of_case {pc_lhs = p; pc_rhs = e; pc_guard = g} =
    match g with
    | Some {pexp_loc = loc} ->
       Location.raise_errorf ~loc
         "guards not allowed in nanopass clauses"
    | None ->
       pat_of_pattern p, e
  in
  let args, cases = get_args [] e0 in
  let clauses = List.map clause_of_case cases in
  {npc_name = name;
   npc_nonterm = nonterm;
   npc_loc = loc;
   npc_args = args;
   npc_clauses = clauses}

(** convert a [pattern] into a [np_pat]. **)
and pat_of_pattern p =
  let base_pat =
    match p.ppat_desc with
    | Ppat_any -> NPpat_any p.ppat_loc
    | Ppat_var x -> NPpat_var x
    | Ppat_alias (p, name) ->
       NPpat_alias (pat_of_pattern p, name)
    | Ppat_tuple ps ->
       NPpat_tuple (List.map pat_of_pattern ps, p.ppat_loc)
    | Ppat_variant (v, arg) ->
       NPpat_variant (v, Option.map pat_of_pattern arg, p.ppat_loc)
    | _ -> NPpat p
  in
  p.ppat_attributes
  |> List.fold_left
       (fun pat (attr, payload)->
         let {txt; loc} : string loc = attr in
         match txt, payload with
         | "l", _ -> NPpat_map pat
         | "r", _ -> NPpat_cata (pat, None)
         | _ -> pat)
       base_pat


let signature_arrow = "=>"

(** extract [L0] and [L1] out of expression of form [L0 --> L1].
    returns [("L0", loc_L0), ("L1", loc_L1)] (for this particular example). **)
let extract_pass_sig = function
  | {pexp_desc =
       Pexp_apply
         ({pexp_desc = Pexp_ident {txt = Lident arrow}},
          [ Nolabel, {pexp_desc = Pexp_construct ({txt = Lident l0_name; loc = l0_loc}, None)};
            Nolabel, {pexp_desc = Pexp_construct ({txt = Lident l1_name; loc = l1_loc}, None)} ])}
       when arrow = signature_arrow
    ->
     (l0_name, l0_loc),
     (l1_name, l1_loc)

  | {pexp_loc = loc} ->
     Location.raise_errorf ~loc
       "invalid language specification; expected 'LX %s LY'"
       signature_arrow


(** convert a [value_binding] into a [np_pass] *)
let pass_of_value_binding = function
  | {pvb_pat = {ppat_desc = Ppat_var {txt = name}};
     pvb_loc = loc;
     pvb_expr = e0;
     pvb_attributes = pass_attr::_} ->

     (* parse language from [[@pass L0 => L1]] *)
     let find_lang l loc =
       Lang.find_language l
         ~exn:(Location.Error
                 (Location.errorf ~loc "language %S has not been defined" l))
     in
     let l0, l1 =
       match snd pass_attr with
       | PStr [ {pstr_desc = Pstr_eval (lang_expr, [])} ] ->
          let (l0_name, l0_loc), (l1_name, l1_loc) = extract_pass_sig lang_expr in
          find_lang l0_name l0_loc,
          find_lang l1_name l1_loc
       | _ ->
          Location.raise_errorf ~loc:(fst pass_attr).loc
            "invalid [@pass] syntax"
     in

     (* convert expression [e] into [f, vbs, body], where
        [vbs] are the value_bindings of the processors, [body]
        is the final expression, and [f] is a function that inserts
        its argument in place of the processors/body. *)
     let rec extract_definitions f =
       function
       | {pexp_desc = Pexp_extension ({txt = "passes"}, PStr stmts); pexp_loc = passes_loc} ->
          let entry = ref None in
          let extract_stmt_bindings = begin function
            | {pstr_desc = Pstr_value (Recursive, vbs)} ->
              let set_entry_name = begin function
                | Ppat_var {txt = name} -> entry := Some name
                | _ -> ()
              end in
              List.iter (fun vb -> if List.exists (fun ({Asttypes.txt}, _) -> txt = "entry") vb.pvb_attributes then set_entry_name vb.pvb_pat.ppat_desc) vbs;
              vbs
            | _ -> []
          end in
          let vbs = List.fold_right (fun bindings lst -> extract_stmt_bindings bindings @ lst) stmts []
          and body = match !entry with
            | None -> failwith "[%passes ...] requires a designated [@entry] function"
            | Some id -> {pexp_desc = Pexp_ident {txt = Lident id; loc = passes_loc};
                          pexp_loc = passes_loc;
                          pexp_attributes = []} in
          f, vbs, body

       | {pexp_desc = Pexp_fun (lbl, dflt, pat, body)} as e ->
          extract_definitions
            (fun e' -> f {e with pexp_desc = Pexp_fun (lbl, dflt, pat, e')})
            body

       | {pexp_desc = Pexp_let (recf, vbs, ({pexp_desc = Pexp_let _} as body))} as e
       | ({pexp_desc = Pexp_let (recf, vbs, ({pexp_desc = Pexp_extension _} as body))} as e) ->
          extract_definitions
            (fun e' -> f {e with pexp_desc = Pexp_let (recf, vbs, e')})
            body

       | {pexp_desc = Pexp_let (Recursive, vbs, body)} ->
          f, vbs, body

       | {pexp_loc = loc} ->
          Location.raise_errorf ~loc
            "let[@pass] must end in recursive let, followed by a single expression"
     in
     let pre, bindings, post = extract_definitions identity e0 in

     (* parse processors from bindings in final letrec *)
     let procs =
       List.map (function
           | {pvb_pat = {ppat_desc = Ppat_var {txt = name}};
              pvb_expr = proc_rhs;
              pvb_loc = loc;
              pvb_attributes = ats}
             ->
              (* TODO: naming scheme for processors;
                 nonterm configurable using attributes? *)
              let nt_name = name in
              let nonterm =
                Lang.language_nonterm l0 nt_name
                  ~exn:(Location.Error
                          (Location.errorf ~loc
                             "no such nonterminal %S in language %S" nt_name l0.Lang.npl_name))
              in
              processor_of_rhs ~name ~nonterm ~loc proc_rhs

           | {pvb_loc = loc} ->
              Location.raise_errorf ~loc
                "invalid processor definition")
         bindings
     in

     {npp_name = name;
      npp_loc = loc;
      npp_input = l0;
      npp_output = l1;
      npp_pre = pre;
      npp_post = post;
      npp_procs = procs}


  | {pvb_loc = loc} ->
     Location.raise_errorf ~loc
       "invalid pass definition"
