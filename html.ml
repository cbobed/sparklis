
open Js
open Jsutils
open Lisql

(* dictionaries *)

(* dictionaries for foci and increments in user interface *)

class ['a] dico (prefix : string) =
object
  val mutable cpt = 0
  val ht : (string,'a) Hashtbl.t = Hashtbl.create 100

  method add (x : 'a) : string =
    cpt <- cpt + 1;
    let key = prefix ^ string_of_int cpt in
    Hashtbl.add ht key x;
    key

  method get (key : string) : 'a =
    try Hashtbl.find ht key
    with _ ->
      Firebug.console##log(string ("Missing element in dico: " ^ key));
      failwith "Osparqlis.dico#get"
end

class lisql_state (lex : Lisql2nl.lexicon) =
object
  method lexicon = lex
  val dico_foci : Lisql.focus dico = new dico "focus"
  method dico_foci = dico_foci
end

class index_state (lex : Lisql2nl.lexicon) =
object
  inherit lisql_state lex
  val dico_incrs : Lisql.increment dico = new dico "incr"
  method dico_incrs = dico_incrs
end

(* pretty-printing of terms, NL in HTML *)

let name_of_uri uri =
  let uri = to_string (decodeURI (string uri)) in
  let s =
    match Regexp.search (Regexp.regexp "[^/#]+$") uri 0 with
      | Some (_,res) ->
	( match Regexp.matched_string res with "" -> uri | name -> name )
      | None -> uri in
  escapeHTML s

let html_pre text =
  let text = Regexp.global_replace (Regexp.regexp "<") text "&lt;" in
  let text = Regexp.global_replace (Regexp.regexp ">") text "&gt;" in  
  "<pre>" ^ text ^ "</pre>"

let html_span ?id ?classe ?title text =
  "<span" ^
    (match id with None -> "" | Some id -> " id=\"" ^ id ^ "\"") ^
    (match classe with None -> "" | Some cl -> " class=\"" ^ cl ^ "\"") ^
    (match title with None -> "" | Some tit -> " title=\"" ^ tit ^ "\"") ^
    ">" ^ text ^ "</span>"

let html_div ?classe ?title text =
  "<div" ^
    (match classe with None -> "" | Some cl -> " class=\"" ^ cl ^ "\"") ^
    (match title with None -> "" | Some tit -> " title=\"" ^ tit ^ "\"") ^
    ">" ^ text ^ "</div>"

let html_suspended ~suspended html =
  if suspended
  then html_span ~classe:"suspended" html
  else html

let html_a url html =
  "<a target=\"_blank\" href=\"" ^ url ^ "\">" ^ html ^ "</a>"

let html_literal s = html_span ~classe:"Literal" (escapeHTML s)
let html_uri uri = html_span ~classe:"URI" ~title:uri (name_of_uri uri)
let html_class c = html_span ~classe:"classURI" ~title:c (name_of_uri c)
let html_prop p = html_span ~classe:"propURI" ~title:p (name_of_uri p)
let html_modifier m = html_span ~classe:"modifier" m
let html_id state id = html_span ~classe:"lisqlID" (state#lexicon#get_id_label id)

let rec html_term ?(link = false) = function
  | Rdf.URI uri ->
    (*if uri_is_image uri (* too heavy loading *)
    then
      if link
      then html_a uri (html_img uri)
      else html_img ~height:60 uri
    else*)
      if link
      then html_a uri (name_of_uri uri)
      else html_uri uri
  | Rdf.Number (f,s,dt) -> html_term ~link (Rdf.TypedLiteral (s,dt))
  | Rdf.TypedLiteral (s,dt) -> html_literal s ^ " (" ^ name_of_uri dt ^ ")"
  | Rdf.PlainLiteral (s,lang) -> html_literal s ^ (if lang="" then "" else " (" ^ lang ^ ")")
  | Rdf.Bnode id -> "_:" ^ id
  | Rdf.Var v -> "?" ^ v

let html_and ar_html =
  let html = ref ("<ul class=\"list-and\"><li>" ^ ar_html.(0) ^ "</li>") in
  for i=1 to Array.length ar_html - 1 do
    html := !html ^ " <li>and " ^ ar_html.(i) ^ "</li>"
  done;
  !html ^ "</ul>"
let html_or ?(suspended=None) ar_html =
  let susp_or = suspended <> None in
  let susp_elt i = suspended <> None && suspended <> Some i in
  let html = ref ("<ul class=\"list-or\"><li>" ^ html_suspended ~suspended:(susp_elt 0) ar_html.(0) ^ "</li>") in
  for i=1 to Array.length ar_html - 1 do
    html :=
      !html ^
      " <li>" ^ html_suspended ~suspended:susp_or (html_modifier "or") ^ " " ^
      html_suspended ~suspended:(susp_elt i) ar_html.(i) ^ "</li>"
  done;
  !html ^ "</ul>"
let html_maybe ?(suspended=false) html = html_suspended ~suspended (html_modifier "optionally") ^ " " ^ html
let html_not ?(suspended=false) html = html_suspended ~suspended (html_modifier "not") ^ " " ^ html
let html_return np = "Give me " ^ np
let html_dummy_focus = "<span class=\"in-current-focus\">___</span>"
let html_ellipsis = "..."

let html_current_focus html =
  html_span ~id:"current-focus" ~classe:"in-current-focus"
      (html ^ " <img src=\"icon-delete.png\" height=\"16\" alt=\"Delete\" id=\"delete-current-focus\" title=\"Click on this red cross to delete the current focus\">")

let html_word state = function
  | `Thing -> "thing"
  | `Term t -> html_term t
  | `Class c -> html_class c
  | `Prop p -> html_prop p
  | `Relation -> html_modifier "relation"
  | `Literal l -> html_literal l
  | `Op op -> html_modifier op
  | `Id id -> html_id state id
  | `DummyFocus -> html_dummy_focus

let html_nl_focus state (foc : Lisql2nl.nl_focus) (html : string) : string =
  match foc with
    | `NoFocus -> html
    | `Focus (focus, pos) ->
      let id = state#dico_foci#add focus in
      let class_pos =
	match pos with
	  | `In -> "in-current-focus"
	  | `At -> "in-current-focus"
	  | `Out -> "out-current-focus"
	  | `Ex -> "ex-current-focus" in
      let html = "<span id=\"" ^ id ^ "\" class=\"focus " ^ class_pos ^ "\">" ^ html ^ "</span>" in
      if pos = `At
      then html_current_focus html
      else html

let rec html_s state (foc, nl : Lisql2nl.s) : string =
  let html =
    match nl with
      | `Return np -> html_return (html_np state np) in
  html_nl_focus state foc html			  
and html_np state (foc, nl : Lisql2nl.np) : string =
  let html =
    match nl with
      | `PN (w, rel) -> html_word state w ^ html_rel_opt state rel
      | `Qu (qu, adj, `Thing, (foc2, `That (_, `IsNP ((`NoFocus, `Qu ((`A | `The), `Nil, w, rel2)), [])))) ->
	html_qu qu ^ html_adj state adj ^ html_nl_focus state foc2 (html_word state w ^ html_rel_opt state rel2)
      | `Qu (`A, `Nil, `Thing, rel) -> "something" ^ html_rel_opt state rel
      | `Qu (qu, adj, w, rel) -> html_qu qu ^ html_adj state adj ^ html_word state w ^ html_rel_opt state rel
      | `QuOneOf (_, [w]) -> html_word state w
      | `QuOneOf (qu, lw) -> html_qu qu ^ "of " ^ String.concat ", " (List.map (html_word state) lw)
      | `And ar -> html_and (Array.map (html_np state) ar)
      | `Or (susp, ar) -> html_or ~suspended:susp (Array.map (html_np state) ar)
      | `Maybe (suspended, np) -> html_maybe ~suspended (html_np state np)
      | `Not (suspended, np) -> html_not ~suspended (html_np state np) in
  html_nl_focus state foc html
and html_qu : Lisql2nl.qu -> string = function
  | `A -> "a "
  | `Any susp -> html_suspended ~suspended:susp (html_modifier "any ")
  | `The -> "the "
  | `All -> "all "
  | `One -> "one "
and html_adj state : Lisql2nl.adj -> string = function
  | `Nil -> ""
  | `Order w -> html_word state w ^ " "
  | `Aggreg (susp, a, w) -> html_suspended ~suspended:susp (html_adj state a ^ html_word state w) ^ " "
  | `Adj (a, w) -> html_adj state a ^ html_word state w ^ " "
and html_rel_opt state foc_nl =
  if foc_nl = Lisql2nl.top_rel
  then ""
  else " " ^ html_rel state foc_nl
and html_rel state (foc, nl : Lisql2nl.rel) : string =
  match nl with (* transformations *)
    | `That (_, `And ar) -> html_rel state (foc, `And (Array.map (fun (foc_i,nl_i) -> (foc_i, `That (`NoFocus, nl_i))) ar))
    | `That (_, `Or (susp,ar)) -> html_rel state (foc, `Or (susp, Array.map (fun (foc_i,nl_i) -> (foc_i, `That (`NoFocus, nl_i))) ar))
    | _ ->
      let html =
	match nl with
	  | `Nil -> ""
	  | `That (_, `IsThere) -> html_ellipsis
	  | `That (_, `HasProp (p, (foc2, `Qu (`A, `Nil, `Thing, (foc3, `That (_,nl_vp)))), lpp)) ->
	    "whose " ^ html_nl_focus state foc2 (html_word state p ^ html_pp_list state lpp ^ " " ^ html_vp state (foc3,nl_vp))
	  | `That (_, `IsPP pp) -> html_pp state pp
	  | `That vp -> "that " ^ html_vp state vp
	  | `Of np -> "of " ^ html_np state np
	  | `Ing (w, np) -> html_word state w ^ " " ^ html_np state np
	  | `And ar -> html_and (Array.map (html_rel state) ar)
	  | `Or (susp, ar) -> html_or ~suspended:susp (Array.map (html_rel state) ar) in
      html_nl_focus state foc html
and html_vp state (foc, nl : Lisql2nl.vp) : string =
  let html =
    match nl with
      | `IsThere -> html_ellipsis
      | `IsNP (np,lpp) -> "is " ^ html_np state np ^ html_pp_list state lpp
      | `IsPP pp -> "is " ^ html_pp state pp
      | `HasProp (w, (foc2, `Qu (qu, adj, `Thing, rel)), lpp) -> html_vp state (foc, `Has ((foc2, `Qu (qu, adj, w, rel)), lpp))
      | `HasProp (p, np, lpp) -> "has " ^ html_word state p ^ " " ^ html_np state np ^ html_pp_list state lpp
      | `Has (np, lpp) -> "has " ^ html_np state np ^ html_pp_list state lpp
      | `VT (w, np, lpp) -> html_word state w ^ " " ^ html_np state np ^ html_pp_list state lpp
      | `And ar -> html_and (Array.map (html_vp state) ar)
      | `Or (susp, ar) -> html_or ~suspended:susp (Array.map (html_vp state) ar)
      | `Maybe (suspended, vp) -> html_maybe ~suspended (html_vp state vp)
      | `Not (suspended, vp) -> html_not ~suspended (html_vp state vp)
      | `DummyFocus -> html_dummy_focus in
  html_nl_focus state foc html
and html_pp_list state : Lisql2nl.pp list -> string = function
  | [] -> ""
  | pp::lpp -> " " ^ html_pp state pp ^ html_pp_list state lpp
and html_pp state : Lisql2nl.pp -> string = function
  | `Prep (prep,np) -> html_word state prep ^ " " ^ html_np state np
  | `PrepBin (prep1,np1,prep2,np2) -> html_word state prep1 ^ " " ^ html_np state np1 ^ " " ^ html_word state prep2 ^ " " ^ html_np state np2

let html_focus (state : #lisql_state) (focus : focus) : string = html_s state (Lisql2nl.s_of_focus focus)


(* HTML of increment lists *)

let html_count_unit count max unit units =
  if count = 0 then "No " ^ unit
  else if count = 1 then "1 " ^ unit
  else if count >= max then string_of_int count ^ "+ " ^ units
  else string_of_int count ^ " " ^ units

let html_increment_coordinate focus html =
  match focus with
    | AtS1 _ -> html
    | AtP1 (IsThere, _) -> html
    | _ -> "and " ^ html

let html_increment_frequency focus state (incr,freq) =
  let key = state#dico_incrs#add incr in
  let text =
    match incr with
      | IncrTerm t ->
	( match focus with
	  | AtS1 _ -> html_term t
	  | _ -> html_increment_coordinate focus ("that is " ^ html_term t) )
      | IncrId id ->
	( match focus with
	  | AtS1 _ -> "the " ^ html_id state id
	  | _ -> html_increment_coordinate focus ("that is the " ^ html_id state id) )
      | IncrClass c ->
	( match focus with
	  | AtS1 (Det (Term _, _), _) -> "a " ^ html_class c
	  | AtS1 (Det (An (_, _, Thing), _), _) -> "a " ^ html_class c
	  | AtS1 (Det (An (_, _, Class c0), _), _) when c0 = c ->
	    (*"<del>a " ^ html_class c ^ "</del>"*)
	    "a " ^ html_class c ^ " <img src=\"icon-delete.png\" height=\"16\" alt=\"Delete\" title=\"Remove this class at the head of the focus\">"
	  | _ -> html_increment_coordinate focus ("that is a " ^ html_class c) )
      | IncrProp p -> html_increment_coordinate focus ("that has a " ^ html_prop p)
      | IncrInvProp p -> html_increment_coordinate focus ("that is the " ^ html_prop p ^ " of ...")
      | IncrTriple (S | O as arg) -> html_increment_coordinate focus ("that has a relation " ^ (if arg = S then "to ..." else "from ..."))
      | IncrTriple P -> html_increment_coordinate focus "that is a relation from ... to ..."
      | IncrTriplify -> "has a relation from/to"
      | IncrIs -> html_increment_coordinate focus "that is ..."
      | IncrAnd -> "and " ^ html_ellipsis
      | IncrOr -> html_modifier "or " ^ html_ellipsis (*html_or [|html_dummy_focus; html_ellipsis|]*)
      | IncrMaybe -> html_maybe html_dummy_focus
      | IncrNot -> html_not html_dummy_focus
      | IncrUnselect ->
	html_np state
	  (Lisql2nl.head_of_modif `NoFocus `DummyFocus Lisql2nl.top_rel (Unselect,Unordered))
      | IncrAggreg g ->
	html_np state
	  (Lisql2nl.head_of_modif `NoFocus `DummyFocus Lisql2nl.top_rel (Aggreg (g,Unordered),Unordered))
      | IncrOrder order ->
	html_np state
	  (Lisql2nl.head_of_modif `NoFocus `DummyFocus Lisql2nl.top_rel (Select,order))
  in
  let text_freq =
    if freq = 1
    then ""
    else " [" ^ string_of_int freq ^ "]" in
  "<span class=\"increment\" id=\"" ^ key ^ "\">" ^ text ^ text_freq ^ "</span>"

(* TODO: avoid to pass focus as argument, use NL generation on increments *)
let html_index focus state (index : Lisql.increment Lis.index) =
  let buf = Buffer.create 1000 in
  Buffer.add_string buf "<ul>";
  List.iter
    (fun incr_freq ->
      Buffer.add_string buf "<li>";
      Buffer.add_string buf (html_increment_frequency focus state incr_freq);
      Buffer.add_string buf "</li>")
    index;
  Buffer.add_string buf "</ul>";
  Buffer.contents buf

(* HTML of results *)

let html_img ?(height = 120) url =
  "<img src=\"" ^ url ^ "\" alt=\"" ^ name_of_uri url ^ "\" height=\"" ^ string_of_int height ^ "\">"

let html_video url mime =
  "<video width=\"320\" height=\"240\" controls>\
  <source src=\"" ^ url ^ "\" type=\"" ^ mime ^ "\">\
  Your browser does not support the video tag.\
  </video>"

let html_audio url mime =
  "<audio controls>\
  <source src=\"" ^ url ^ "\" type=\"" ^ mime ^ "\">\
  Your browser does not support this audio format.\
  </audio>"

let html_cell t =
  match t with
    | Rdf.URI uri ->
      if Rdf.uri_has_ext uri ["jpg"; "JPG"; "jpeg"; "JPEG"; "png"; "PNG"; "gif"; "GIF"] then
	html_a uri (html_img uri)
      else if Rdf.uri_has_ext uri ["mp4"; "MP4"] then
	html_video uri "video/mp4"
      else if Rdf.uri_has_ext uri ["ogg"; "OGG"] then
	html_video uri "video/ogg"
      else if Rdf.uri_has_ext uri ["mp3"; "MP3"] then
	html_audio uri "audio/mpeg"
      else html_term ~link:true t
    | _ -> html_term ~link:true t

let html_table_of_results ~first_rank ~focus_var results =
  let open Sparql_endpoint in
  let buf = Buffer.create 1000 in
  Buffer.add_string buf "<table id=\"extension\"><tr><th></th>";
  List.iter
    (fun (var,i) ->
      Buffer.add_string buf
	(if var = focus_var
	 then "<th class=\"in-current-focus\">"
	 else "<th>");
      Buffer.add_string buf var;
      Buffer.add_string buf "</th>")
    results.vars;
  Buffer.add_string buf "</tr>";
  let li = List.map snd results.vars in
  let rank = ref first_rank in
  List.iter
    (fun binding ->
      Buffer.add_string buf "<tr>";
      Buffer.add_string buf "<td>";
      Buffer.add_string buf (string_of_int !rank);
      Buffer.add_string buf "</td>";
      List.iter
	(fun i ->
	  Buffer.add_string buf "<td>";
	  ( match binding.(i) with
	    | None -> ()
	    | Some t -> Buffer.add_string buf (html_cell t) );
	  Buffer.add_string buf "</td>")
	li;
      Buffer.add_string buf "</tr>";
      incr rank)
    results.bindings;
  Buffer.add_string buf "</table>";
  Buffer.contents buf
