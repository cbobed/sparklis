
open Js
open Jsutils
open Html

(* LISQL constraints <--> user patterns *)

let string_is_float =
  let re = Regexp.regexp "^[+-]?(\\d+|\\d*[.]\\d+|\\d+[.]\\d*[eE][+-]?\\d+|[.]\\d+[eE][+-]?\\d+|\\d+[eE][+-]?\\d+)$" in
  (fun s -> Regexp.string_match re s 0 <> None)

let make_constr op pat =
  let open Lisql in
  let lpat = List.filter ((<>) "") (Regexp.split (Regexp.regexp "[ ]+") pat) in
  if lpat = []
  then True
  else
    match op, lpat with
      | "matchesAll", _ -> MatchesAll lpat
      | "matchesAny", _ -> MatchesAny lpat
      | "after", pat::_ -> After pat
      | "before", pat::_ -> Before pat
      | "fromTo", pat1::[] -> After pat1
      | "fromTo", pat1::pat2::_ -> FromTo (pat1,pat2)
      | "higherThan", pat::_ ->
	if string_is_float pat 
	then HigherThan pat
	else invalid_arg "a numeric value is expected"
      | "lowerThan", pat::_ ->
	if string_is_float pat
	then LowerThan pat
	else invalid_arg "a numeric value is expected"
      | "between", pat::[] ->
	if string_is_float pat
	then HigherThan pat
	else invalid_arg "a numeric value is expected"
      | "between", pat1::pat2::_ ->
	if string_is_float pat1 && string_is_float pat2
	then Between (pat1, pat2)
	else invalid_arg "two numeric values are expected"
      | "hasLang", pat::_ -> HasLang pat
      | "hasDatatype", pat::_ -> HasDatatype pat
      | _ -> True

let operator_of_constr =
  let open Lisql in
      function
	| True -> "matchesAll"
	| MatchesAll _ -> "matchesAll"
	| MatchesAny _ -> "matchesAny"
	| After _ -> "after"
	| Before _ -> "before"
	| FromTo _ -> "fromTo"
	| HigherThan _ -> "higherThan"
	| LowerThan _ -> "lowerThan"
	| Between _ -> "between"
	| HasLang _ -> "hasLang"
	| HasDatatype _ -> "hasDatatype"

let pattern_of_constr =
  let open Lisql in
      function
	| True -> ""
	| MatchesAll lpat -> String.concat " " lpat
	| MatchesAny lpat -> String.concat " " lpat
	| After pat -> pat
	| Before pat -> pat
	| FromTo (pat1,pat2) -> pat1 ^ " " ^ pat2
	| HigherThan pat -> pat
	| LowerThan pat -> pat
	| Between (pat1,pat2) -> pat1 ^ " " ^ pat2
	| HasLang pat -> pat
	| HasDatatype pat -> pat

(* navigation place and history *)

class navigation =
object
  method change_endpoint (url : string) : unit = ()
  method update_focus ~(push_in_history : bool) (f : Lisql.focus -> Lisql.focus option) : unit = ()
end

class place =
object (self)
  val lis = new Lis.place "http://dbpedia.org/sparql" Lisql.factory#home_focus
(*  val lis = new Lis.place "http://localhost:3030/ds/sparql" Lisql.factory#home_focus *)
  method lis = lis

  val mutable offset = 0
  val mutable limit = 10

  val mutable term_constr = Lisql.True
  val mutable property_constr = Lisql.True

  val mutable navigation = new navigation
  method set_navigation (navig : navigation) = navigation <- navig

  val mutable lisql_state = new Html.lisql_state (new Lisql2nl.lexicon)
  val mutable index_state = new Html.index_state (new Lisql2nl.lexicon)

  method show_permalink : unit =
    let args =
      if self#is_home
      then [("endpoint", lis#endpoint)]
      else [("endpoint", lis#endpoint); ("query", Permalink.of_query lis#query)] in
    try
      let permalink_url =
	match Url.Current.get () with
	  | None -> raise Not_found
	  | Some (Url.Http url) -> Url.Http { url with Url.hu_arguments = args }
	  | Some (Url.Https url) -> Url.Http { url with Url.hu_arguments = args }
	  | Some (Url.File url) -> Url.File { url with Url.fu_arguments = args } in
      ignore
	(prompt
	   "The following URL points to the current endpoint and query (Ctrl+C, Enter to copy to clipboard)."
	   (Url.string_of_url permalink_url))
    with _ -> ()

  method private refresh_lisql =
    jquery "#lisql" (fun elt ->
      elt##innerHTML <- string (html_focus lisql_state lis#focus);
      jquery_all_from elt ".focus" (onclick (fun elt_foc ev ->
	Dom_html.stopPropagation ev;
	navigation#update_focus ~push_in_history:false (fun _ ->
	  let key = to_string (elt_foc##id) in
	  Firebug.console##log(string key);
	  Some (lisql_state#dico_foci#get key))));
      jquery_from elt "#delete-current-focus"
	(onclick (fun elt_button ev ->
	  Dom_html.stopPropagation ev;
	  navigation#update_focus ~push_in_history:true Lisql.delete_focus)))

  method private refresh_constrs =
    List.iter
      (fun (sel_select, sel_input, constr) ->
	jquery_select sel_select (fun select ->
	  jquery_input sel_input (fun input ->
	    select##value <- string (operator_of_constr constr);
	    input##value <- string (pattern_of_constr constr))))
      [("#select-terms", "#pattern-terms", term_constr);
       ("#select-properties", "#pattern-properties", property_constr);
       ("#select-modifiers", "#pattern-modifiers", Lisql.True)]

  method private refresh_extension =
    let open Sparql_endpoint in
    jquery "#results" (fun elt_results ->
      if lis#results_dim = 0 then begin
	elt_results##style##display <- string "none" end
      else begin
	elt_results##style##display <- string "block";
	jquery_set_innerHTML "#list-results"
	  (html_table_of_results
	     ~first_rank:(offset+1)
	     ~focus_var:(match lis#focus_term_list with [Rdf.Var v] -> v | _ -> "")
	     (lis#results_page offset limit));
	jquery_all ".count-results" (fun elt ->
	  elt##innerHTML <- string
	    (let nb = lis#results_nb in
	     if nb = 0
	     then "No results"
	     else
		let a, b = offset+1, min nb (offset+limit) in
		if a = 1 && b = nb && nb < Lis.max_results then
		  string_of_int b ^ (if b=1 then " result" else " results")
		else
		  "Results " ^ string_of_int a ^ " - " ^ string_of_int b ^
		    " of " ^ string_of_int nb ^ (if nb < Lis.max_results then "" else "+")))
      end)

  method private refresh_term_increments_init =
    jquery "#list-terms" (fun elt ->
      lis#ajax_index_terms_init term_constr [elt]
	(fun index ->
	  elt##innerHTML <- string (html_index lis#focus index_state index);
	  jquery_all_from elt ".increment" (onclick (fun elt ev ->
	    navigation#update_focus ~push_in_history:true
	      (Lisql.insert_increment (index_state#dico_incrs#get (to_string (elt##id))))));
	  jquery_set_innerHTML "#count-terms"
	    (html_count_unit (List.length index) 100 "entity" "entities")))

  method private refresh_term_increments =
    let index = lis#index_ids @ lis#index_terms in
    jquery "#list-terms" (fun elt ->
      elt##innerHTML <- string
	(html_index lis#focus index_state index);
      jquery_all_from elt ".increment" (onclick (fun elt ev ->
	navigation#update_focus ~push_in_history:true
	  (Lisql.insert_increment (index_state#dico_incrs#get (to_string (elt##id)))))));
    jquery_set_innerHTML "#count-terms"
      (html_count_unit (List.length index) Lis.max_results "entity" "entities")

  method private refresh_property_increments_init =
    jquery "#list-properties" (fun elt ->
      lis#ajax_index_properties_init property_constr elt
	(fun index ->
	  elt##innerHTML <- string (html_index lis#focus index_state index);
	  jquery_all_from elt ".increment" (onclick (fun elt ev ->
	    navigation#update_focus ~push_in_history:true
	      (Lisql.insert_increment (index_state#dico_incrs#get (to_string (elt##id))))));
	  jquery_set_innerHTML "#count-properties"
	    (html_count_unit (List.length index) 1000 "concept" "concepts")))

  method private refresh_property_increments =
    jquery "#list-properties" (fun elt ->
      lis#ajax_index_properties property_constr elt
	(fun index ->
	  elt##innerHTML <- string (html_index lis#focus index_state index);
	  jquery_all_from elt ".increment" (onclick (fun elt ev ->
	    navigation#update_focus ~push_in_history:true
	      (Lisql.insert_increment (index_state#dico_incrs#get (to_string (elt##id))))));
	  jquery_set_innerHTML "#count-properties"
	    (html_count_unit (List.length index) Lis.max_properties "concept" "concepts")))

  method private refresh_modifier_increments ~(init : bool) =
    jquery "#list-modifiers" (fun elt ->
      let index = lis#index_modifiers ~init in
      elt##innerHTML <- string (html_index lis#focus index_state index);
      jquery_all_from elt ".increment" (onclick (fun elt ev ->
	navigation#update_focus ~push_in_history:true
	  (Lisql.insert_increment (index_state#dico_incrs#get (to_string (elt##id))))));
      jquery_set_innerHTML "#count-modifiers"
	(html_count_unit (List.length index) max_int "modifier" "modifiers"))

  method refresh =
    lisql_state <- new Html.lisql_state lis#lexicon;
    index_state <- new Html.index_state lis#lexicon;
    jquery_input "#sparql-endpoint-input" (fun input -> input##value <- string lis#endpoint);
    self#refresh_lisql;
    self#refresh_constrs;
    jquery "#increments" (fun elt_incrs ->
      jquery "#results" (fun elt_res ->
	( match lis#focus_term_list with
	  | [] -> elt_incrs##style##display <- string "none"
	  | _::_ -> elt_incrs##style##display <- string "block" );
	lis#ajax_sparql_results term_constr [elt_incrs; elt_res]
	  (function
	    | None ->
	      jquery_set_innerHTML "#sparql-query" "";
	      jquery "#sparql" (fun elt -> elt##style##display <- string "none");
	      jquery "#results" (fun elt -> elt##style##display <- string "none");
	      (*jquery_input "#pattern-terms" (fun input -> input##disabled <- bool true);*)
	      jquery_all ".list-incrs" (fun elt -> elt##innerHTML <- string "");
	      jquery_all ".count-incrs" (fun elt -> elt##innerHTML <- string "---");
	      ( match lis#focus_term_list with
		| [] -> ()
		| [Rdf.Var v] ->
		  self#refresh_term_increments_init;
		  self#refresh_property_increments_init;
		  self#refresh_modifier_increments ~init:true
		| _ ->
		  self#refresh_term_increments;
		  self#refresh_property_increments;
		  self#refresh_modifier_increments ~init:false)
	    | Some sparql ->
	      jquery_set_innerHTML "#sparql-query" (html_pre sparql);
	      jquery "#sparql" (fun elt -> elt##style##display <- string "block");
	      self#refresh_extension;
	      jquery_input "#pattern-terms" (fun input -> input##disabled <- bool false);
	      ( match lis#focus_term_list with
		| [] -> ()
		| _ ->
		  self#refresh_term_increments;
		  self#refresh_property_increments;
		  self#refresh_modifier_increments ~init:false ))))

  method is_home =
    Lisql.is_home_focus lis#focus

  method set_term_constr constr =
    if constr <> term_constr
    then
      if self#is_home
      then begin
	term_constr <- constr;
	self#refresh_term_increments_init end      
      else begin
	Firebug.console##log(string "set_term_constr!");
	term_constr <- constr;
	self#refresh
      end

  method set_property_constr constr =
    if constr <> property_constr
    then
      if self#is_home
      then begin
	property_constr <- constr;
	self#refresh_property_increments_init end
      else begin
	property_constr <- constr;
	self#refresh_property_increments
      end

  method pattern_changed
    ~(select : Dom_html.selectElement t)
    ~(input : Dom_html.inputElement t)
    ~(elt_list : Dom_html.element t)
    (k : Lisql.constr -> unit)
    =
    let op = to_string (select##value) in
    let pat = to_string (input##value) in
    Firebug.console##log(string pat);
    if pat = ""
    then k Lisql.True
    else
    try
      let constr = make_constr op pat in
      let matcher = Lisql.compile_constr constr in
      let there_is_match = ref false in
      jquery_all_from elt_list "li" (fun elt_li ->
	jquery_from elt_li ".increment" (fun elt_incr ->
	  let incr = index_state#dico_incrs#get (to_string (elt_incr##id)) in
	  let t =
	    match Lisql.term_of_increment incr with
	      | Some t -> t
	      | None ->
		let s = Opt.case (elt_incr##querySelector(string ".modifier"))
		  (fun () -> to_string (elt_incr##innerHTML))
		  (fun elt -> to_string (elt##innerHTML)) in
		Rdf.PlainLiteral (s, "") in
	  if matcher t
	  then begin elt_li##style##display <- string "list-item"; there_is_match := true end
	  else elt_li##style##display <- string "none"));
      let n = String.length pat in
      if (not !there_is_match && (pat = "" || pat.[n - 1] = ' ')) || (n >= 2 && pat.[n-1] = ' ' && pat.[n-2] = ' ')
      then begin
	Firebug.console##log(string "pattern: no match, call k");
	k constr
      end
    with Invalid_argument msg -> ()

  method set_limit n =
    limit <- n;
    self#refresh_extension

  method give_more =
    if offset + limit < lis#results_nb
    then self#set_limit (limit+10)

  method give_less =
    if limit > 10
    then self#set_limit (limit-10)

  method page_down =
    let offset' = offset + limit in
    if offset' < lis#results_nb
    then begin
      offset <- offset';
      self#refresh_extension
    end

  method page_up =
    let offset' = offset - limit in
    if offset' >= 0
    then begin
      offset <- offset';
      self#refresh_extension end
    else begin
      offset <- 0;
      self#refresh_extension
    end

  method new_place endpoint focus =
    {< lis = new Lis.place endpoint focus;
       offset = 0;
       term_constr = Lisql.True;
       property_constr = Lisql.True; >}

end

let history =
object (self)
  val mutable past : place list = []
  val mutable present : place = new place
  val mutable future : place list = []

  initializer present#set_navigation (self :> navigation)

  method present : place = present

  method push (p : place) : unit =
    past <- present::past;
    present <- p;
    future <- []

  method change_endpoint url =
    present#lis#abort_all_ajax;
    let focus = Lisql.factory#reset; Lisql.factory#home_focus in
    let p = present#new_place url focus in
    p#set_navigation (self :> navigation);
    self#push p;
    p#refresh

  method update_focus ~push_in_history f =
    match f present#lis#focus with
      | None -> ()
      | Some foc ->
	present#lis#abort_all_ajax;
	let p = present#new_place present#lis#endpoint foc in
	p#set_navigation (self :> navigation);
	if push_in_history then self#push p else present <- p;
	p#refresh

  method home =
    self#update_focus ~push_in_history:true
      (fun _ -> Lisql.factory#reset; Some Lisql.factory#home_focus)

  method back : unit =
    match past with
      | [] -> ()
      | p::lp ->
	present#lis#abort_all_ajax;
	future <- present::future;
	present <- p;
	past <- lp;
	p#refresh

  method forward : unit =
    match future with
      | [] -> ()
      | p::lp ->
	present#lis#abort_all_ajax;
	past <- present::past;
	present <- p;
	future <- lp;
	p#refresh

end

(* main *)

let _ =
  Firebug.console##log(string "Starting Sparklis");
  Dom_html.window##onload <- Dom.handler (fun ev ->
    jquery "#home" (onclick (fun elt ev -> history#home));
    jquery "#back" (onclick (fun elt ev -> history#back));
    jquery "#forward" (onclick (fun elt ev -> history#forward));
    jquery "#sparql-endpoint-button" (onclick (fun elt ev ->
      jquery_input "#sparql-endpoint-input" (fun input ->
	let url = to_string (input##value) in
	history#change_endpoint url)));
    jquery "#permalink" (onclick (fun elt ev -> history#present#show_permalink));

    jquery "#button-terms" (onclick (fun elt ev ->
      jquery_select "#select-terms" (fun select ->
	jquery_input "#pattern-terms" (fun input ->
	  let op = to_string (select##value) in
	  let pat = to_string (input##value) in
	  try
	    let constr = make_constr op pat in
	    if constr = Lisql.True
	    then
	      Dom_html.window##alert(string "Invalid filter")
	    else
	      history#update_focus ~push_in_history:true
		(Lisql.insert_constr constr)
	  with Invalid_argument msg ->
	    Dom_html.window##alert(string ("Invalid filter: " ^ msg))))));
    List.iter
      (fun (sel_select, sel_input, sel_list, k) ->
	jquery_select sel_select (fun select ->
	  jquery_input sel_input (fun input ->
	    jquery sel_list (fun elt_list ->
	      (oninput
		 (fun input ev -> history#present#pattern_changed ~select ~input ~elt_list k)
		 input)))))
      [("#select-terms", "#pattern-terms", "#list-terms", (fun constr -> history#present#set_term_constr constr));
       ("#select-properties", "#pattern-properties", "#list-properties", (fun constr -> history#present#set_property_constr constr));
       ("#select-modifiers", "#pattern-modifiers", "#list-modifiers", (fun constr -> ()))];
    
    jquery_all ".previous-results" (onclick (fun elt ev -> history#present#page_up));
    jquery_all ".next-results" (onclick (fun elt ev -> history#present#page_down));
    jquery_all ".limit-results" (fun elt ->
      Opt.iter (Dom_html.CoerceTo.select elt) (onchange (fun select ev ->
	Firebug.console##log(select##value);
	let limit = int_of_string (to_string (select##value)) in
	history#present#set_limit limit)));

(*    let _ = to_string Dom_html.window##location##search in *)
    let _ =
      let args = Url.Current.arguments in
      let args =
	match args with
	  | [] -> []
	  | (k,v)::l -> (String.sub k 1 (String.length k - 1), v)::l in (* bug: '?' remains in first key *)
      Firebug.console##log(string (String.concat " & " (List.map (fun (k,v) -> k ^ " = " ^ v) args)));
      try
	let url = List.assoc "endpoint" args in
	history#change_endpoint url;
	try
	  let query = Permalink.to_query (List.assoc "query" args) in
	  history#update_focus ~push_in_history:true (Lisql.goto query)
	with _ -> ()
      with _ ->
	history#present#refresh in
    bool true)
