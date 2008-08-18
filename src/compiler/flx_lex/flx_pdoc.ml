open Flx_token
open Flx_ast
open Flx_util
open Flx_keywords
open List

type action_t = [`Scheme of string | `None]
type symbol_t = [`Atom of token | `Group of dyalt_t list]
and dyalt_t = symbol_t list * range_srcref * action_t * anote_t

type gdoc_entry_t = [
    | `Doc of string * string
    | `Prod of string * dyalt_t list
]

type ddoc_entry_t = [
    | `dsslDoc of string * string
    | `dsslProd of string * dyalt_t list
]

type page_entry_t = [
  | `Nt of string
  | `Subpage of string * page_entry_t list
]


let silly_strtoken k =
  match k with
  | NAME (_,s) -> s
  | _ -> Flx_prelex.string_of_token k


(* This stuff is a hack to emit documentation
   for the reference manual
*)
let document_grammar = ref false
let grammar_doc = Hashtbl.create 97
let ntgroups = Hashtbl.create 97
let dssls = Hashtbl.create 97

let record_rule dssl nt dyalts =
  let old = try Hashtbl.find grammar_doc nt with Not_found -> [] in
  Hashtbl.replace grammar_doc nt (`Prod (dssl,dyalts) :: old);

  let old = try Hashtbl.find dssls dssl with Not_found -> [] in
  Hashtbl.replace dssls dssl (`dsslProd (nt,dyalts) :: old)
;;

let record_doc dssl nt s =
  let old = try Hashtbl.find grammar_doc nt with Not_found -> [] in
  Hashtbl.replace grammar_doc nt (`Doc (dssl,s) :: old);

  let old = try Hashtbl.find dssls dssl with Not_found -> [] in
  Hashtbl.replace dssls dssl (`dsslDoc (nt,s) :: old)

let record_group group nts =
  let old = try Hashtbl.find ntgroups group with Not_found -> [] in
  Hashtbl.replace ntgroups group (concat [old; nts])


let nt2tok = [
  "lpar","(";
  "rpar",")";
  "lsqb","[";
  "rsqb","]";
  "lbrace","{";
  "rbrace","}";
  "star","*";
  "plus","+";
  "quest","?";
  "strue","true";
  "sfalse","false";
  "colon",":";
  "ssemi",";";
  "vbar","|";
  "sname","<SPAN CLASS=\"predef\">NAME</SPAN>";
  "sinteger","<SPAN CLASS=\"predef\">INTEGER</SPAN>";
  "sstring","<SPAN CLASS=\"predef\">STRING</SPAN>";
  "scstring","<SPAN CLASS=\"predef\">CSTRING</SPAN>";
  "sepsilon","<SPAN CLASS=\"predef\">epsilon</SPAN>";
]

let spelling = flx_keywords @ flx_syms

let nt2page = Hashtbl.create 97

let uri s =
  try (Hashtbl.find nt2page s ^ ".html") ^ "#"^s
  with Not_found -> s ^ ".html"

let anchor s =
  "<A NAME=\""^s^"\">"

let href a s =
  "<A HREF=\""^a^"\">" ^ s ^ "</A>"

let href_nt s = href (uri s) s

let href_page s = href (s^".html") s

let href_dssl s = href ("dssl_"^s^".html") s

let span cl s =
  "<SPAN CLASS=\""^cl^"\">"^s^"</SPAN>"

let begin_div cl =
  "<DIV CLASS=\""^cl^"\">"

let end_div = "</DIV>"

let ljust n s =
  let s = s ^ String.make n ' ' in
  String.sub s 0 n

let emit_rule dssl name dyalts : string list =
  let done_space = ref false in
  let b = Buffer.create 1000 in
  let emit s = Buffer.add_string b s in
  let spc () =
    if !done_space then () else
    done_space :=true; emit " "
  in
  let semit s = spc(); emit s; done_space := false in

  let emit_ter tok = semit tok in
  let emit_nt s = semit (href_nt s) in
  let emit_enc s = emit (span "metatoken" s) in
  let emit_user_keyword s =
    spc();
    emit (span "userkeyword" s);
    done_space := false
  in
  let rec emit_symbol sym = match sym with
    | `Group dyalts ->
      spc(); emit_enc "("; done_space := false;
      let first = ref true in
      List.iter (fun x ->
        if not (!first) then emit_enc "|";
        first := false;
        emit_dyalt x)
      dyalts;
      emit_enc ")"

    | `Atom a -> match a with
      | NAME (_,s) ->
        begin try
          let tok = List.assoc s nt2tok in
          emit_ter tok
        with Not_found -> emit_nt s
        end
      | STRING (_,s) -> semit("\"" ^ s ^ "\"")
      | STAR _ -> emit_enc "*"
      | QUEST _ -> emit_enc "?"
      | PLUS _  -> emit_enc "+"
      | USER_KEYWORD (_,s) -> emit_user_keyword s
      | x ->
        let s =  silly_strtoken x in
        let s = try List.assoc s spelling with Not_found -> s in
        semit s

  and emit_dyalt (rhs,sr,action,anote) =
    List.iter emit_symbol rhs;
    match action with
    | `Scheme s when String.length s > 1->
      if anote <> "" then
      emit (span "anote" anote)
      else
      if s.[0] == '\'' then
      emit (span "assocfun" (String.sub s 1 (String.length s - 1)));

    | _ -> ()

  in
  let ss = List.map
    (fun x->
      Buffer.clear b;
      emit "  "; emit_enc "|"; done_space:=false; emit_dyalt x;
      Buffer.contents b
    )
    dyalts
  in
  ss

;;

let rec get_nts entry : string list = match entry with
  | `Nt nt -> [nt]
  | `Subpage (_,entries) -> concat (map get_nts entries)


let make_ntdoc w page nt =
  let dfn =
    (*
    print_endline ("DOCUMENTING NONTERMINAL " ^ nt );
    *)
    try rev (Hashtbl.find grammar_doc nt)
    with Not_found ->
     print_endline ("ERROR, page " ^ page ^ " nonterminal " ^ nt ^ " NOT FOUND");
     []
  in
  w (begin_div "ntlist");
  w (" " ^ nt ^ anchor nt ^ span "metatoken" ":=" ^ "\n");
  List.iter (* all separate productions of nonterminal *)
      (fun gd -> match gd with
      | `Prod (dssl,dyalts) ->
        let ss = emit_rule dssl nt dyalts in
        begin match ss with
        | [] -> assert false
        | h :: t ->
        w ( begin_div "rule" ^ href_dssl dssl ^ span "production" h ^end_div);
        List.iter (* alternatives of a production *)
          (fun h ->
            w (begin_div "rule" ^span "production" h ^ end_div)
          )
          t
        ;
        end
      | `Doc (dssl,s) -> w s
    )
  dfn
  ;
  w end_div

let make_dssldoc w dssl entries =
  w ("<H1>DSSL " ^ dssl ^ "</H1>");
  w (begin_div "ntlist");
  w ("syntax " ^ dssl ^ anchor dssl ^ span "metatoken" " {" ^ "\n");
  List.iter
  (fun gd -> match gd with
      | `dsslProd (nt,dyalts) ->
        let ss = emit_rule dssl nt dyalts in
        begin match ss with
        | [] -> assert false
        | h :: t ->
        let ds = ljust 20 ("  " ^ dssl) in
        w ( begin_div "rule" ^ span "nt" nt ^ span "dsslproduction" h ^end_div);
        let ds = ljust 20 ""in
        List.iter (* alternatives of a production *)
          (fun h ->
            w (begin_div "rule" ^span "dssl" ds ^ span "dsslproduction" h ^ end_div)
          )
          t
        ;
        end
      | `dsslDoc (nt,s) -> w s
  )
  entries
  ;
  w (span "metatoken" "}\n");
  w end_div

let rec make_body w page level heading entries =
      w (
        "<h"^string_of_int level^">" ^ heading ^
        "</h"^string_of_int level^">\n"
      );
      iter
      (fun entry ->
        match entry with
        | `Nt nt -> make_ntdoc w page nt
        | `Subpage (subhead,entries) -> make_body w page (level+1) subhead entries
      )
      entries

let gen_doc () =
    let _ = try Unix.mkdir "doc" 0o775 with _ -> () in
    let _ = try Unix.mkdir "doc/gramdoc" 0o775 with _ -> () in

    (* calculate partial nonterminal -> page map *)
    Hashtbl.iter
    (fun page entries ->
      iter
        (fun entry ->
          let nts2 = get_nts entry in
          iter
          (fun nt ->
            (* Note: this is actually OK .. stuff gets documented twice! *)
            if Hashtbl.mem nt2page nt then
              print_endline ("Warning: nonterminal " ^ nt ^ " in two groups!")
            ;
            Hashtbl.replace nt2page nt page
           )
           nts2
        )
        entries
    )
    ntgroups
    ;

    (* complete the group listing by placing orphans in
      their own family
    *)
    Hashtbl.iter
    (fun k _ ->
      if not (Hashtbl.mem nt2page k)
      then Hashtbl.add ntgroups k [(`Nt k :> page_entry_t)]
    )
    grammar_doc
    ;

    Hashtbl.iter (* all dssls *)
    (fun dssl entries ->
      (*
      print_endline ("PAGE " ^ page );
      *)
      let f = open_out ("doc/gramdoc/dssl_" ^ dssl ^ ".html") in
      let w s = output_string f s in
      w "<html><head>\n";
      w "<meta content=\"text/html; charset=utf8\" http-equiv=\"Content-Type\">\n";
      w "<link rel=stylesheet href=\"gramdoc.css\" type=\"text/css\">\n";
      w ("<title> DSSL " ^ dssl ^ "</title>\n");
      w "</head>\n";
      w "<body>";
      make_dssldoc w dssl entries;
      w "</body></html>\n";
      close_out f
    )
    dssls
    ;
    Hashtbl.iter (* all pages *)
    (fun page entries ->
      (*
      print_endline ("PAGE " ^ page );
      *)
      let f = open_out ("doc/gramdoc/" ^ page ^ ".html") in
      let w s = output_string f s in
      w "<html><head>\n";
      w "<meta content=\"text/html; charset=utf8\" http-equiv=\"Content-Type\">\n";
      w "<link rel=stylesheet href=\"gramdoc.css\" type=\"text/css\">\n";
      w ("<title>" ^ page ^ "</title>\n");
      w "</head>\n";
      w "<body>";
      make_body w page 1 page entries;
      w "</body></html>\n";
      close_out f
    )
    ntgroups
    ;
    let grammar_list = Hashtbl.fold (fun k _ acc -> k::acc) grammar_doc [] in
    let grammar_list = List.sort compare grammar_list in
    let f = open_out ("doc/gramdoc/index.html") in
    let w s = output_string f s in
    w "<html><head>\n";
    w "<meta content=\"text/html; charset=utf8\" http-equiv=\"Content-Type\">\n";
    w "<link rel=stylesheet href=\"gramdoc.css\" type=\"text/css\">";
    w ("<title>Felix Grammar</title>\n");
    w "</head>\n";
    w "<body>\n";
    w "<H1>DSSL Index</H1>";
    w (begin_div "index");
    let dssl_list = Hashtbl.fold (fun k _ acc -> k::acc) dssls [] in
    let dssl_list = List.sort compare dssl_list in
    List.iter
    (fun name ->
      w (" " ^ href_dssl name ^ "\n");
    )
    dssl_list
    ;
    w end_div;
    w "<H1>Topic Index</H1>";
    w (begin_div "index");
    let page_list = Hashtbl.fold (fun k _ acc -> k::acc) ntgroups [] in
    let page_list = List.sort compare page_list in
    List.iter
    (fun name ->
      w (" " ^ href_page name ^ "\n");
    )
    page_list
    ;
    w end_div;
    w "<H1>Nonterminal Index</H1>";
    w (begin_div "index");
    List.iter
    (fun name ->
      w (" " ^ href_nt name ^ "\n");
    )
    grammar_list
    ;
    w end_div;
    w "</body></html>\n";
    close_out f