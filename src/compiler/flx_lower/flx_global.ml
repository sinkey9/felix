open Flx_util
open Flx_ast
open Flx_types
open Flx_btype
open Flx_bexpr
open Flx_bexe
open Flx_bbdcl
open Flx_print
open Flx_set
open Flx_mtypes2
open Flx_typing
open Flx_unify
open Flx_maps
open Flx_exceptions
open Flx_use

(* Garbage collector usage. The gc is required for non-stacked
  procedure calls, applications, closure formations,
  and variant constructors
*)

let throw_on_gc bsym_table e : unit = match e with
  | BEXPR_closure (i,_),_ ->
    (*
    print_endline ("Found closure of " ^ si i);
    *)
    raise Not_found

  | BEXPR_apply_direct _,_ -> raise Not_found
  | BEXPR_apply( (BEXPR_closure (_,_),_),_),_ -> raise Not_found
  | BEXPR_apply_struct (i,_,_),_ ->
    begin match Flx_bsym_table.find_bbdcl bsym_table i with
    | BBDCL_nonconst_ctor _ -> raise Not_found
    | _ -> ()
    end

  | BEXPR_case (_,t),_ ->
    begin match t with
    | BTYP_sum args when not (all_units args) -> raise Not_found
    | BTYP_inst (i,ts) ->
      begin match Flx_bsym_table.find_bbdcl bsym_table i with
      | BBDCL_union (vs,idts) when not
          (all_voids (List.map (fun (_,_,t)->t) idts)) -> raise Not_found
      | _ -> ()
      end
    | _ -> ()
    end
  | _ -> ()

let expr_uses_gc bsym_table e =
  Flx_bexpr.iter ~f_bexpr:(throw_on_gc bsym_table) e

let exe_uses_gc bsym_table exe =
  match exe with
  | BEXE_jump_direct _
  | BEXE_call_direct _ -> raise Not_found

  (* this test is used to trap use of gc by primitives *)
  | BEXE_call_prim (sr,i,ts,a) ->
      let bsym = Flx_bsym_table.find bsym_table i in
      begin match Flx_bsym.bbdcl bsym with
      | BBDCL_external_fun (props,vs,ps,BTYP_fix (0,_),_,_,_)
      | BBDCL_external_fun (props,vs,ps,BTYP_void,_,_,_) ->
          if List.mem `Uses_gc props then begin
            (* Flagged as using gc *)
            raise Not_found
          end;

          Flx_bexe.iter ~f_bexpr:(expr_uses_gc bsym_table) exe
      | _ ->
          print_endline ("Call primitive to non-primitive " ^ Flx_bsym.id bsym ^
            "<" ^ string_of_bid i ^ ">");
          assert false
      end

  | _ ->
      Flx_bexe.iter ~f_bexpr:(expr_uses_gc bsym_table) exe

let exes_use_gc bsym_table exes =
  try
    List.iter (exe_uses_gc bsym_table) exes;
    false
  with
    Not_found ->
    (*
    print_endline "GC USED HERE";
    *)
    true

let exe_uses_yield exe =
  match exe with
  | BEXE_yield _ -> raise Not_found
  | _ -> ()

let exes_use_yield exes =
  try
    List.iter exe_uses_yield exes;
    false
  with
    Not_found ->
    (*
    print_endline "YIELD USED HERE";
    *)
    true

(* ALSO calculates if a function uses a yield *)
let set_gc_use bsym_table index bsym =
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props, vs, ps, rt, exes) ->
      let props = if exes_use_gc bsym_table exes
        then `Uses_gc :: props
        else props
      in
      let props =
        match rt with
        | BTYP_void -> props
        | _ ->
            if exes_use_yield exes
              then `Heap_closure :: `Yields :: `Generator :: props
              else props
      in
      let bbdcl = bbdcl_fun (props,vs,ps,rt,exes) in
      Flx_bsym_table.update_bbdcl bsym_table index bbdcl

  | _ -> ()

let throw_on_global bsym_table i =
  if Flx_bsym_table.is_global_var bsym_table i then raise Not_found

let expr_uses_global bsym_table e =
  Flx_bexpr.iter ~f_bid:(throw_on_global bsym_table) e

let exe_uses_global bsym_table exe =
  Flx_bexe.iter
    ~f_bid:(throw_on_global bsym_table)
    ~f_bexpr:(expr_uses_global bsym_table)
    exe

let exes_use_global bsym_table exes =
  try
    List.iter (exe_uses_global bsym_table) exes;
    false
  with Not_found -> true

let set_local_globals bsym_table index bsym =
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,ps,rt,exes) ->
      if exes_use_global bsym_table exes then begin
        let bbdcl = bbdcl_fun (`Uses_global_var :: props,vs,ps,rt,exes) in
        Flx_bsym_table.update_bbdcl bsym_table index bbdcl
      end
  | _ -> ()

type ptf_required = | Required | Not_required | Unknown

let rec set_ptf_usage bsym_table usage excludes i bsym =
  (* cal reqs for functions we call and fold together *)
  let cal_reqs calls i : ptf_required * property_t =
    let result1 =
      List.fold_left begin fun u (j,_) ->
        let bsym = Flx_bsym_table.find bsym_table j in
        let r = set_ptf_usage bsym_table usage (i::excludes) j bsym in
          (*
          print_endline ("Call of " ^ si i^ " to " ^ si j ^ " PTF of j " ^ (
            match r with
            | Unknown -> "UNKNOWN"
            | Required -> "REQUIRED"
            | Not_required -> "NOT REQUIRED"
          ));
          *)

          begin match u,r with
          | Unknown, x | x, Unknown -> x
          | Required, _ | _, Required -> Required
          | Not_required, _ (* | _, Not_required *) -> Not_required
          end
      end Not_required calls
    in
    let result2 =
      match result1 with
      | Required -> `Requires_ptf
      | Not_required -> `Not_requires_ptf
      | _ -> assert false
    in
    result1, result2
  in

  if List.mem i excludes then Unknown else

  (* main routine *)
  let calls = try Hashtbl.find usage i with Not_found -> [] in

  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,ps,rt,exes) ->
    if List.mem `Requires_ptf props then Required
    else if List.mem `Not_requires_ptf props then Not_required
    else if
      List.mem `Uses_global_var props or
      List.mem `Uses_gc props or
      List.mem `Heap_closure props then begin
        let bbdcl = bbdcl_fun (`Requires_ptf :: props,vs,ps,rt,exes) in
        Flx_bsym_table.update_bbdcl bsym_table i bbdcl;
        Required
    end else begin
      let result1, result2 = cal_reqs calls i in
      let bbdcl = bbdcl_fun (result2 :: props,vs,ps,rt,exes) in
      Flx_bsym_table.update_bbdcl bsym_table i bbdcl;
      result1
   end

  | BBDCL_external_fun (props,vs,ps,ret,ct,reqs,prec) ->
    if List.mem `Requires_ptf props then Required
    else if List.mem `Not_requires_ptf props then Not_required
    else if
      List.mem `Uses_global_var props or
      List.mem `Uses_gc props or
      List.mem `Heap_closure props then begin
        Flx_bsym_table.update_bbdcl bsym_table i (bbdcl_external_fun (
          `Requires_ptf :: props,
          vs,
          ps,
          ret,
          ct,
          reqs,
          prec));
        Required
    end else Not_required

  | _ -> Not_required

let set_globals_for_symbol bsym_table uses index symbol =
  ignore (set_ptf_usage bsym_table uses [] index symbol)

let set_globals_for_symbols bsym_table uses bids =
  (* Iterate through each symbol and mark if the function needs a frame. *)
  List.iter begin fun bid ->
    let symbol =
      try Some (Flx_bsym_table.find bsym_table bid)
      with Not_found -> None
    in
    match symbol with
    | Some bsym -> set_globals_for_symbol bsym_table uses bid bsym
    | None -> ()
  end bids;

  bids

let set_globals bsym_table =
  Flx_bsym_table.iter begin fun bid _ bsym ->
    set_local_globals bsym_table bid bsym
  end bsym_table;

  Flx_bsym_table.iter begin fun bid _ bsym ->
    set_gc_use bsym_table bid bsym
  end bsym_table;

  let uses, _ = Flx_call.call_data bsym_table in

  (* Iterate through each symbol and mark if the function needs a frame. *)
  Flx_bsym_table.iter begin fun bid _ bsym ->
    set_globals_for_symbol bsym_table uses bid bsym
  end bsym_table

let find_global_vars bsym_table =
  let global_vars = ref BidSet.empty in
  Flx_bsym_table.iter begin fun bid _ _ ->
    if Flx_bsym_table.is_global_var bsym_table bid
    then global_vars := BidSet.add bid !global_vars
  end bsym_table;

  !global_vars

let check_used used i =
  Hashtbl.mem used i

let check_all_used used ii =
  let all_used = ref true in
  BidSet.iter (fun i -> if not (check_used used i)
    then begin
      print_endline ("FOUND UNUSED VARIABLE " ^ string_of_bid i);
      all_used := false
    end
  )
  ii
  ;
  if !all_used then
    print_endline "ALL GLOBAL VARS ARE USED"
  else
    print_endline "Some UNUSED vars!"

let check_global_vars_all_used bsym_table used =
  let ii = find_global_vars bsym_table in
  check_all_used used ii
