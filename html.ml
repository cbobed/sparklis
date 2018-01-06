(*
  Copyright 2013-2017 Sébastien Ferré, IRISA, Université de Rennes 1

  This file is part of Sparklis.
*)

open Js
open Jsutils
open Lisql
open Lisql_annot

(* generic dictionary with automatic generation of keys *)

class ['a] dico (prefix : string) =
object
  val mutable cpt = 0
  val ht : (string,'a) Hashtbl.t = Hashtbl.create 101
  val rev_ht : ('a,string) Hashtbl.t = Hashtbl.create 101

  method add (x : 'a) : string =
    try Hashtbl.find rev_ht x
    with Not_found ->
      let k = cpt <- cpt + 1; prefix ^ string_of_int cpt in
      Hashtbl.add ht k x;
      Hashtbl.add rev_ht x k;
      k

  method add_key (key : string) (x : 'a) : unit =
    Hashtbl.add ht key x;
    Hashtbl.add rev_ht x key

  method get (key : string) : 'a =
    try Hashtbl.find ht key
    with _ ->
      Firebug.console##log(string ("Missing element in dico: " ^ key));
      failwith "Osparqlis.dico#get"

  method get_key (x : 'a) : string option =
    try Some (Hashtbl.find rev_ht x)
    with Not_found -> None
end

(* HTML state with dictionaries for foci and increments in user interface *)

let focus_key_of_root = "root"
let focus_key_of_id (id : Lisql.id) : string = "id" ^ string_of_int id

let collapse_of_key key = "collapse-" ^ key
let key_of_collapse =
  let l = String.length "collapse-" in
  fun s -> String.sub s l (String.length s - l)
								    
class state (id_labelling : Lisql2nl.id_labelling) =
object
  method id_labelling = id_labelling
  val dico_foci : Lisql.focus dico = new dico "focus"
  method add_focus (focus : Lisql.focus) : string =
    let key = dico_foci#add focus in
    if Lisql.is_root_focus focus then
      dico_foci#add_key focus_key_of_root focus;
    ( match Lisql.id_of_focus focus with
      | Some id -> dico_foci#add_key (focus_key_of_id id) focus
      | None -> () );
    key
  method get_focus (key : string) : Lisql.focus = dico_foci#get key

  val dico_incrs : Lisql.increment dico = new dico "incr"
  method dico_incrs = dico_incrs

  val dico_results : (int * Lisql.id * Rdf.term) dico = new dico "cell"
  method dico_results = dico_results
end

(* pretty-printing of terms, NL in HTML *)

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

let html_a url html =
  "<a target=\"_blank\" href=\"" ^ url ^ "\">" ^ html ^ "</a>"

let html_img ?id ?classe ~height ~alt ~title url =
  "<img" ^
    (match id with None -> "" | Some i -> " id=\"" ^ i ^ "\"") ^
    (match classe with None -> "" | Some c -> " class=\"" ^ c ^ "\"") ^
    " src=\"" ^ url ^ "\" height=\"" ^ string_of_int height ^ "\" alt=\"" ^ alt ^ "\" title=\"" ^ title ^ "\">"

let html_glyphicon name = "<span class=\"glyphicon glyphicon-" ^ name ^ "\"></span>"

let html_open_new_window ~height uri =
  html_a uri (html_img ~classe:"open-new-window" ~height ~alt:"Open" ~title:Lisql2nl.config_lang#grammar#tooltip_open_resource "icon-open-new-window.png")

let html_delete ?id ~title () =
  html_img ?id ~height:16 ~alt:"Delete" ~title "icon-delete.png"

let html_literal s = html_span ~classe:"Literal" (escapeHTML s)
let html_uri ~classe uri s = html_span ~classe ~title:uri (escapeHTML s)
let html_function f = html_span ~classe:"function" (escapeHTML f)
let html_modifier m = html_span ~classe:"modifier" (escapeHTML m)

let html_word = function
  | `Thing -> Lisql2nl.config_lang#grammar#thing
  | `Relation -> html_modifier Lisql2nl.config_lang#grammar#relation
  | `Literal s -> html_literal s
  | `TypedLiteral (s,t) ->
    if Lisql2nl.config_show_datatypes#value
    then html_literal s ^ " (" ^ escapeHTML t ^ ")"
    else html_literal s
  | `Blank id -> html_span ~classe:"nodeID" (escapeHTML id) ^ " (bnode)"
  | `Entity (uri,s) -> html_uri ~classe:"URI" uri s ^ " " ^ html_open_new_window ~height:12 uri
  | `Class (uri,s) -> html_uri ~classe:"classURI" uri s
  | `Prop (uri,s) -> html_uri ~classe:"propURI" uri s
  | `Func s -> html_span ~classe:"function" (escapeHTML s)
  | `Op op -> html_modifier op
  | `Undefined -> "___"
  | `DummyFocus -> html_span ~classe:"highlighted" "___"

let html_input dt =
  let t, hint =
    match dt with
    | `IRI -> "url", "http://"
    | `String -> "text", ""
    | `Float -> "number", "0.0e+0"
    | `Integer -> "number", "0"
    | `Date -> "text", "yyyy-mm-dd"
    | `Time -> "text", "hh:mm:ss"
    | `DateTime -> "text", "yyyy-mm-ddThh:mm:ss"
  (*    | `Time -> "text", "hh:mm:ss" *)
  in
  "<input class=\"term-input\" type=\"" ^ t ^ "\" placeholder=\"" ^ hint ^ "\">"

let append_node_to_xml node xml =
  List.rev (node :: List.rev xml)
let append_node_to_xml_list node lxml =
  match List.rev lxml with
  | [] -> [[node]]
  | last::rest -> List.rev (append_node_to_xml node last :: rest)
    
let rec html_of_nl_xml ?(highlight=false) (state : state) (xml : Lisql2nl.xml) : string =
  let open Lisql2nl in
  match xml with
  | Enum (sep,lxml) :: DeleteCurrentFocus :: xml ->
    html_of_nl_xml ~highlight state (Enum (sep, append_node_to_xml_list DeleteCurrentFocus lxml) :: xml)
  | Coord (coord,lxml) :: DeleteCurrentFocus :: xml ->
    html_of_nl_xml ~highlight state (Coord (coord, append_node_to_xml_list DeleteCurrentFocus lxml) :: xml)
  | Focus (foc,xml1) :: DeleteCurrentFocus :: xml ->
    html_of_nl_xml ~highlight state (Focus (foc, append_node_to_xml DeleteCurrentFocus xml1) :: xml)
  | Highlight xml1 :: DeleteCurrentFocus :: xml ->
    html_of_nl_xml ~highlight state (Highlight (append_node_to_xml DeleteCurrentFocus xml1) :: xml)
  | Focus (foc1, xml1) :: Focus (foc2, xml2) :: xml when foc1 = foc2 -> html_of_nl_xml ~highlight state (Focus (foc1, xml1 @ xml2) :: xml)
  | Highlight xml1 :: Highlight xml2 :: xml -> html_of_nl_xml ~highlight state (Highlight (xml1 @ xml2) :: xml)
  | node :: xml -> html_of_nl_node ~highlight state node ^ (if xml=[] then "" else " " ^ html_of_nl_xml ~highlight state xml)
  | [] -> ""
and html_of_nl_node ?(highlight=false) (state : state) : Lisql2nl.node -> string = 
  let open Lisql2nl in
  function
    | Kwd s -> s
    | Word w -> html_word w
    | Input dt -> html_input dt
    | Suffix (xml,suf) -> html_of_nl_xml ~highlight state xml ^ suf
    | Enum (sep,lxml) -> String.concat sep (List.map (html_of_nl_xml ~highlight state) lxml)
    | Quote (left, xml, right) -> left ^ html_of_nl_xml ~highlight state xml ^ right
    | Coord (coord,lxml) ->
      "<ul class=\"coordination\"><li>"
      ^ String.concat ("</li><li> " ^ html_highlight highlight (html_of_nl_xml ~highlight state coord ^ " "))
	(List.map (fun xml -> html_highlight highlight (html_of_nl_xml ~highlight state xml)) lxml)
      ^ "</li></ul>"
    | Focus (focus,xml) ->
      let id = state#add_focus focus in
      html_span ~id ~classe:"focus" (html_of_nl_xml ~highlight state xml)
    | Highlight xml ->
      html_highlight true (html_of_nl_xml ~highlight:true state xml)
    | Suspended xml ->
      html_span ~classe:"suspended" (html_of_nl_xml ~highlight state xml)
    | DeleteCurrentFocus ->
      html_delete ~id:"delete-current-focus" ~title:Lisql2nl.config_lang#grammar#tooltip_delete_current_focus ()
    | DeleteIncr ->
      html_delete ~title:Lisql2nl.config_lang#grammar#tooltip_remove_element_at_focus ()
and html_highlight h xml =
  if h
  then html_span ~classe:"highlighted" xml
  else xml

(* HTML of different AST elements *)

let html_term (t : Rdf.term) : string =
  html_word (Lisql2nl.word_of_term t)

let html_query (state : state) (query : annot elt_s) : string =
  let grammar = Lisql2nl.config_lang#grammar in
  let id_labelling = state#id_labelling in
  html_of_nl_xml state
    (Lisql2nl.xml_s grammar ~id_labelling
       (Lisql2nl.map_s Lisql2nl.main_transf
	  (Lisql2nl.s_of_elt_s grammar ~id_labelling
	     query)))


let html_id (state : state) (id : int) : string =
  html_of_nl_xml state
    (Lisql2nl.xml_np_id Lisql2nl.config_lang#grammar state#id_labelling
       id)

(* HTML of increment lists *)

let html_count_unit freq (unit,units) =
  let count = freq.Lis.value in
  let s_count = string_of_int count in
  let s_count = if freq.Lis.partial then s_count ^ "+" else s_count in
  if count = 0 then Lisql2nl.config_lang#grammar#no ^ " " ^ unit
  else if count = 1 then s_count ^ " " ^ unit
  else s_count ^ " " ^ units

let freq_text_html_increment_frequency focus (state : state) (incr,freq_opt) =
  let key = state#dico_incrs#add incr in
  let xml = Lisql2nl.xml_incr Lisql2nl.config_lang#grammar state#id_labelling focus incr in
  let text =
    Lisql2nl.word_text_content Lisql2nl.config_lang#grammar
      (Lisql2nl.word_of_incr Lisql2nl.config_lang#grammar
	 incr) in
  let text = String.lowercase text in
  let data =
    try `Number (float_of_string text)
    with _ -> `Words (Regexp.split (Regexp.regexp "[- ,;:.()]+") text) in
  let html = html_of_nl_xml state xml in
  let rank, title_opt =
    let grammar = Lisql2nl.config_lang#grammar in
    match incr with
      | IncrId _ -> 1, None
      | IncrForeachResult -> 1, Some grammar#tooltip_foreach_result
      | IncrForeachId _ -> 1, Some grammar#tooltip_foreach_id
      | IncrAggregId _ -> 2, Some grammar#tooltip_aggreg_id
	
      | IncrInput _ -> 2, None
      | IncrName _ -> 2, Some grammar#tooltip_input_name
      | IncrTerm _ -> 2, None
	
      | IncrTriple _ -> 3, None
      | IncrLatLong _ -> 3, Some grammar#tooltip_geolocation
      | IncrType _ -> 4, None
      | IncrRel _ -> 5, None
      | IncrTransitive _ -> 5, Some grammar#tooltip_transitive
	
      | IncrAnd -> 6, None
      | IncrDuplicate -> 6, Some grammar#tooltip_duplicate_focus
      | IncrOr -> 7, Some grammar#tooltip_or
      | IncrChoice -> 7, Some grammar#tooltip_or
      | IncrMaybe -> 8, Some grammar#tooltip_optionally
      | IncrNot -> 9, Some grammar#tooltip_not
      | IncrIn -> 10, None (* TODO: tooltip *)
      | IncrInWhichThereIs -> 10, None (* TODO: tooltip *)
      | IncrTriplify -> 10, Some grammar#tooltip_focus_on_property
      | IncrThatIs -> 11, None
      | IncrSomethingThatIs -> 11, None
      | IncrOrder (Highest _) -> 12, Some grammar#tooltip_highest
      | IncrOrder (Lowest _) -> 13, Some grammar#tooltip_lowest
      | IncrOrder _ -> 12, None
      | IncrUnselect -> 14, Some grammar#tooltip_any
      | IncrForeach -> 14, Some grammar#tooltip_foreach
      | IncrAggreg Sample -> 15, Some grammar#tooltip_sample
      | IncrAggreg _ -> 16, Some grammar#tooltip_aggreg
      | IncrFuncArg _ -> 17, Some grammar#tooltip_func
  in
  let freq, html_freq =
    match freq_opt with
    | None -> 1, ""
    | Some {Lis.value=1} -> 1, ""
    | Some {Lis.value; max_value; partial; unit} ->
      let s = string_of_int value in
      let s = if partial then s ^ "+" else s in
      (*let s = match max_value with None -> s | Some max -> s ^ "/" ^ string_of_int max in*)
      value,
      ( match unit with
      | `Results -> html_span ~classe:"frequency-results" ~title:"number of results matching this" s
      | `Entities -> html_span ~classe:"frequency-entities" ~title:"number of entities matching this" s
      | `Concepts | `Modifiers -> " <" ^ s ^ ">" (* should not happen *)
      ) in
  freq, rank, data, key, html_span ~id:key ~classe:"increment" ?title:title_opt (html ^ html_freq)

(* TODO: avoid to pass focus as argument, use NL generation on increments *)
let html_index focus (state : state) (index : Lis.incr_freq_index) =
  let sort_node_list nodes =
    List.sort
      (fun (`Node ((f1,r1,data1,_,_),_)) (`Node ((f2,r2,data2,_,_),_)) ->
	let c = Pervasives.compare (f2,r1) (f1,r2) in
	if c <> 0
	then c
	else
	  match data1, data2 with
	  | `Number f1, `Number f2 -> Pervasives.compare f1 f2
	  | `Number _, `Words _ -> 1 (* words before numbers *)
	  | `Words _, `Number _ -> -1
	  | `Words lw1, `Words lw2 ->
	    if List.for_all (fun w1 -> List.mem w1 lw2) lw1 then -1
	    else if List.for_all (fun w2 -> List.mem w2 lw1) lw2 then 1
	    else Pervasives.compare lw1 lw2)
      nodes in
  let rec aux buf nodes =
    let sorted_nodes = sort_node_list nodes in
    Buffer.add_string buf "<ul>";
    List.iter
      (fun (`Node ((_freq,_rank,_data,key,html), children)) ->
	let check_id = collapse_of_key key in
	Buffer.add_string buf "<li class=\"col-xs-11\">";
	if children = [] then begin
	    Buffer.add_string buf "<label style=\"visibility:hidden;\">►&nbsp;</label>";
	    Buffer.add_string buf html
	end
	else begin
	  Buffer.add_string buf ("<input class=\"input-treeview\" type=\"checkbox\" id=\"" ^ check_id ^ "\">");
	  Buffer.add_string buf ("<label for=\"" ^ check_id ^ "\" class=\"label-checked\">▼&nbsp;</label>");
	  Buffer.add_string buf ("<label for=\"" ^ check_id ^ "\" class=\"label-unchecked\">►&nbsp;</label>");
	  Buffer.add_string buf html;
	  aux buf children
	end;
	Buffer.add_string buf "</li>")
      sorted_nodes;
    Buffer.add_string buf "</ul>"
  in
  let enriched_index_tree = index#map_tree (freq_text_html_increment_frequency focus state) in
  let buf = Buffer.create 1000 in
  aux buf enriched_index_tree;
  Buffer.contents buf

(* HTML of results *)

let html_cell_img ?(height = 120) url =
  let label = Lexicon.name_of_uri url in
  html_img ~height ~alt:label ~title:label url ^ html_open_new_window ~height:16 url

let html_cell_video url mime =
  "<video width=\"320\" height=\"240\" controls>\
  <source src=\"" ^ url ^ "\" type=\"" ^ mime ^ "\">\
  Your browser does not support the video tag.\
  </video>" ^
    html_open_new_window ~height:16 url

let html_cell_audio url mime =
  "<audio controls>\
  <source src=\"" ^ url ^ "\" type=\"" ^ mime ^ "\">\
  Your browser does not support this audio format.\
  </audio>" ^ 
    html_open_new_window ~height:16 url

let html_cell_contents (t : Rdf.term) =
  match t with
  | Rdf.URI uri ->
     if Rdf.uri_has_ext uri ["jpg"; "JPG"; "jpeg"; "JPEG"; "png"; "PNG"; "gif"; "GIF"] then
       html_cell_img uri
     else if Rdf.uri_has_ext uri ["mp4"; "MP4"] then
       html_cell_video uri "video/mp4"
     else if Rdf.uri_has_ext uri ["ogg"; "OGG"] then
       html_cell_video uri "video/ogg"
     else if Rdf.uri_has_ext uri ["mp3"; "MP3"] then
       html_cell_audio uri "audio/mpeg"
     else html_word (Lisql2nl.word_of_term t)
  | _ -> html_word (Lisql2nl.word_of_term t)  
			 
let html_cell state ~(line : int) ~(column : Lisql.id) t =
  let contents = html_cell_contents t in
  let key = state#dico_results#add (line,column,t) in
  html_span ~id:key ~classe:"cell" contents

let html_table_of_results (state : state) ~first_rank ~focus_var results =
  let open Sparql_endpoint in
  let focus_id = match focus_var with None -> -1 | Some v -> state#id_labelling#get_var_id v in
  let id_i_list = List.map (fun (var,i) -> (state#id_labelling#get_var_id var, i)) results.vars in
  let buf = Buffer.create 1000 in
  Buffer.add_string buf ("<div class=\"table-responsive\"><table id=\"extension\" class=\"table table-bordered table-condensed table-hover\"><tr><th id=\"" ^ focus_key_of_root ^ "\" class=\"header\" title=\"" ^ Lisql2nl.config_lang#grammar#tooltip_header_hide_focus ^ "\"></th>");
  List.iter
    (fun (id,i) ->
      Buffer.add_string buf
	(if id = focus_id
	 then "<th class=\"header highlighted\">"
	 else "<th id=\"" ^ focus_key_of_id id ^ "\" class=\"header\" title=\"" ^ Lisql2nl.config_lang#grammar#tooltip_header_set_focus ^ "\">");
      Buffer.add_string buf
	(html_of_nl_xml state
	   (Lisql2nl.xml_ng_id ~isolated:true
	      Lisql2nl.config_lang#grammar
	      ~id_labelling:(state#id_labelling)
	      id));
      Buffer.add_string buf "</th>")
    id_i_list;
  Buffer.add_string buf "</tr>";
  let rank = ref first_rank in
  List.iter
    (fun binding ->
      Buffer.add_string buf "<tr>";
      Buffer.add_string buf "<td>";
      Buffer.add_string buf (string_of_int !rank);
      Buffer.add_string buf "</td>";
      List.iter
	(fun (id,i) ->
	  Buffer.add_string buf "<td>";
	  ( match binding.(i) with
	    | None -> ()
	    | Some t -> Buffer.add_string buf (html_cell state ~line:(!rank) ~column:id t) );
	  Buffer.add_string buf "</td>")
	id_i_list;
      Buffer.add_string buf "</tr>";
      incr rank)
    results.bindings;
  Buffer.add_string buf "</table></div>";
  Buffer.contents buf


let html_slides slides =
  let buf = Buffer.create 1000 in
  let i = ref 0 in
  List.iter
    (fun uri ->
     Buffer.add_string buf "<div class=\"item";
     if !i=0 then Buffer.add_string buf " active";
     Buffer.add_string buf "\"><img src=\"";
     Buffer.add_string buf uri;
     Buffer.add_string buf "\"></div>";
     incr i)
    slides;
  Buffer.contents buf
