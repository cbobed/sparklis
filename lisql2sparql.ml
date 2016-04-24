
open Jsutils
open Lisql
open Lisql_annot

(* translation from LISQL elts to SPARQL queries *)

(* SPARQL variable generator *)
class state (id_labelling : Lisql2nl.id_labelling) =
object (self)
  method id_labelling = id_labelling

  val mutable vars : Rdf.var list = []
  method add_var v = if not (List.mem v vars) then vars <- v::vars
  method vars = List.rev vars

  val h_var_aggreg : (Rdf.var, Rdf.var * aggreg * Sparql.formula) Hashtbl.t = Hashtbl.create 3
  method set_aggreg v aggreg : unit =
    Hashtbl.add h_var_aggreg v aggreg
  method aggreg v =
    try Some (Hashtbl.find h_var_aggreg v)
    with _ -> None

  val h_var_modif : (Rdf.var, modif_s2) Hashtbl.t = Hashtbl.create 13
  method set_modif (v : Rdf.var) (modif : modif_s2) : unit =
    Hashtbl.add h_var_modif v modif
  method modif (v : Rdf.var) =
    try Hashtbl.find h_var_modif v
    with _ -> (Select, Unordered)
  method project (v : Rdf.var) = fst (self#modif v)
  method order (v : Rdf.var) = snd (self#modif v)

end

let sparql_converter (conv_opt : num_conv option) : Sparql.converter =
  match conv_opt with
  | None -> (fun t -> (t :> Sparql.expr))
  | Some (conv,b) ->
    let func_conv =
      match conv with
      | `Integer -> "xsd:integer"
      | `Decimal -> "xsd:decimal"
      | `Double -> "xsd:double" in
    (fun t ->
      Sparql.expr_func func_conv
	[ if b
	  then Sparql.expr_func "str" [(t :> Sparql.expr)]
	  else (t :> Sparql.expr) ])
  
let sparql_aggreg = function
  | NumberOf -> Sparql.DistinctCOUNT
  | ListOf -> Sparql.DistinctCONCAT
  | Sample -> Sparql.SAMPLE
  | Total conv_opt -> Sparql.SUM (sparql_converter conv_opt)
  | Average conv_opt -> Sparql.AVG (sparql_converter conv_opt)
  | Maximum conv_opt -> Sparql.MAX (sparql_converter conv_opt)
  | Minimum conv_opt -> Sparql.MIN (sparql_converter conv_opt)

let sparql_order = function
  | Unordered -> None
  | Lowest conv_opt -> Some (Sparql.ASC (sparql_converter conv_opt))
  | Highest conv_opt -> Some (Sparql.DESC (sparql_converter conv_opt))

let filter_constr_gen ~(label_property_lang : string * string) (t : Sparql.term) (c : constr) : Sparql.formula =
  (* both [label_prop] and [label_lang] may be the empty string, meaning undefined *)
  let label_prop, label_lang = label_property_lang in
  let label_wrapper make_filter =
    if label_prop = ""
    then make_filter t
    else
      let open Sparql in
      let term_l = (var "constr_label" :> term) in
      formula_or_list
	[ make_filter t;
	  formula_and_list
	    [ Pattern (triple t (uri label_prop) term_l);
	      if label_lang = "" then True else Filter (expr_regex (expr_func "lang" [(term_l :> expr)]) label_lang);
	      make_filter term_l ] ] in
  match c with
    | True -> Sparql.True
    | MatchesAll [] -> Sparql.True
    | MatchesAll lpat ->
      label_wrapper (fun t ->
	Sparql.Filter
	  (Sparql.log_and
	     (List.map
		(fun pat -> Sparql.expr_regex (Sparql.expr_func "str" [(t :> Sparql.expr)]) pat)
		lpat)))
    | MatchesAny [] -> Sparql.True
    | MatchesAny lpat ->
      label_wrapper (fun t ->
	Sparql.Filter
	  (Sparql.log_or
	     (List.map
		(fun pat -> Sparql.expr_regex (Sparql.expr_func "str" [(t :> Sparql.expr)]) pat)
		lpat)))
    | After pat ->
      Sparql.Filter (Sparql.expr_comp ">=" (Sparql.expr_func "str" [(t :> Sparql.expr)]) (Sparql.string pat :> Sparql.expr))
    | Before pat ->
      Sparql.Filter (Sparql.expr_comp "<=" (Sparql.expr_func "str" [(t :> Sparql.expr)]) (Sparql.string pat :> Sparql.expr))
    | FromTo (pat1,pat2) ->
      Sparql.Filter
	(Sparql.log_and
	   [Sparql.expr_comp ">=" (Sparql.expr_func "str" [(t :> Sparql.expr)]) (Sparql.string pat1 :> Sparql.expr);
	    Sparql.expr_comp "<=" (Sparql.expr_func "str" [(t :> Sparql.expr)]) (Sparql.string pat2 :> Sparql.expr)])
    | HigherThan pat ->
      Sparql.Filter (Sparql.expr_comp ">=" (Sparql.conv_numeric (t :> Sparql.expr)) (Sparql.sparql pat))
    | LowerThan pat ->
      Sparql.Filter (Sparql.expr_comp "<=" (Sparql.conv_numeric (t :> Sparql.expr)) (Sparql.sparql pat))
    | Between (pat1,pat2) ->
      Sparql.Filter
	(Sparql.log_and
	   [Sparql.expr_comp ">=" (Sparql.conv_numeric (t :> Sparql.expr)) (Sparql.sparql pat1);
	    Sparql.expr_comp "<=" (Sparql.conv_numeric (t :> Sparql.expr)) (Sparql.sparql pat2)])
    | HasLang pat ->
      Sparql.Filter
	(Sparql.log_and
	   [Sparql.expr_func "isLiteral" [(t :> Sparql.expr)];
	    Sparql.expr_regex (Sparql.expr_func "lang" [(t :> Sparql.expr)]) pat])
    | HasDatatype pat ->
      Sparql.Filter
	(Sparql.log_and
	   [Sparql.expr_func "isLiteral" [(t :> Sparql.expr)];
	    Sparql.expr_regex (Sparql.expr_func "str" [Sparql.expr_func "datatype" [(t :> Sparql.expr)]]) pat])

let filter_constr_entity t c = filter_constr_gen ~label_property_lang:Lexicon.config_entity_lexicon#property_lang t c
let filter_constr_class t c = filter_constr_gen ~label_property_lang:Lexicon.config_class_lexicon#property_lang t c
let filter_constr_property t c = filter_constr_gen ~label_property_lang:Lexicon.config_property_lexicon#property_lang t c


let search_constr (t : Sparql.term) (c : constr) : Sparql.formula =
  let term_l = (Sparql.var "search_label" :> Sparql.term) in
  match c with
    | MatchesAll (w::lw) ->
      Sparql.formula_and_list
	[ Sparql.Pattern (Sparql.search_label t term_l);
	  Sparql.Pattern (Sparql.search_contains term_l w);
	  Sparql.Filter (Sparql.log_and (List.map (fun w -> Sparql.expr_regex (term_l :> Sparql.expr) w) lw)) ]
    | MatchesAny lw ->
      Sparql.formula_or_list
	(List.map
	   (fun w ->
	     Sparql.formula_and_list
	       [Sparql.Pattern (Sparql.search_label t term_l);
		Sparql.Pattern (Sparql.search_contains term_l w)])
	   lw)
    | _ ->
      Sparql.Pattern (Sparql.something t)


let triple_arg arg x y z =
  Sparql.Pattern
    ( match arg with
      | S -> Sparql.triple x y z
      | P -> Sparql.triple y x z
      | O -> Sparql.triple y z x )

let rec expr_apply func args =
  match func with
  | `Add -> Sparql.expr_infix "+" args
  | `Sub -> Sparql.expr_infix "-" args
  | `Mul -> Sparql.expr_infix "*" args
  | `Div -> Sparql.expr_infix "/" args
  | `Random2 ->
    ( match args with
    | [arg1; arg2] ->
      Sparql.expr_infix "+"
	[arg1;
	 Sparql.expr_infix "*"
	   [Sparql.expr_func "RAND" [];
	    Sparql.expr_infix "-" [arg2; arg1]]]
    | _ -> assert false )
  | `TODAY ->
    ( match args with
    | [] -> Sparql.expr_func "xsd:date" [Sparql.expr_func "NOW" []]
    | _ -> assert false )
  | `And -> Sparql.expr_infix " && " args
  | `Or -> Sparql.expr_infix " || " args
  | `EQ -> Sparql.expr_infix " = " args
  | `NEQ -> Sparql.expr_infix " != " args
  | `GT -> Sparql.expr_infix " > " args
  | `GEQ -> Sparql.expr_infix " >= " args
  | `LT -> Sparql.expr_infix " < " args
  | `LEQ -> Sparql.expr_infix " <= " args
  | func -> Sparql.expr_func (name_func func) args
and name_func = function
  | `Str -> "str"
  | `Lang -> "lang"
  | `Datatype -> "datatype"
  | `IRI -> "IRI"
  | `STRDT -> "STRDT"
  | `STRLANG -> "STRLANG"
  | `Strlen -> "strlen"
  | `Substr2 -> "substr"
  | `Substr3 -> "substr"
  | `Strbefore -> "strbefore"
  | `Strafter -> "strafter"
  | `Concat -> "concat"
  | `UCase -> "ucase"
  | `LCase -> "lcase"
  | `Encode_for_URI -> "encode_for_uri"
  | `Replace -> "replace"
  | `Integer -> "xsd:integer"
  | `Decimal -> "xsd:decimal"
  | `Double -> "xsd:double"
  | `Indicator -> "xsd:integer"
  | `Add | `Sub | `Mul | `Div -> invalid_arg "Lisql2sparql.name_func"
  | `Neg -> "-"
  | `Abs -> "abs"
  | `Round -> "round"
  | `Ceil -> "ceil"
  | `Floor -> "floor"
  | `Random2 -> invalid_arg "Lisql2sparql.name_func: Random2"
  | `Date -> "xsd:date"
  | `Time -> "xsd:time"
  | `Year -> "year"
  | `Month -> "month"
  | `Day -> "day"
  | `Hours -> "hours"
  | `Minutes -> "minutes"
  | `Seconds -> "seconds"
  | `TODAY -> invalid_arg "Lisql2sparql.name_func: TODAY"
  | `NOW -> "NOW"
  | `Not -> "!"
  | `And | `Or
  | `EQ | `NEQ | `GT | `GEQ | `LT | `LEQ -> invalid_arg "Lisql2sparql.name_func"
  | `BOUND -> "BOUND"
  | `IF -> "IF"
  | `IsIRI -> "IsIRI"
  | `IsBlank -> "IsBlank"
  | `IsLiteral -> "IsLiteral"
  | `IsNumeric -> "IsNumeric"
  | `StrStarts -> "strstarts"
  | `StrEnds -> "strends"
  | `Contains -> "contains"
  | `REGEX -> "REGEX"
  | `LangMatches -> "langMatches"

    
type sparql_p1 = Sparql.term -> Sparql.formula
type sparql_p2 = Sparql.term -> Sparql.term -> Sparql.formula
type sparql_s1 = sparql_p1 -> Sparql.formula
type sparql_s2 = sparql_p1 -> sparql_p1 -> Sparql.formula
type sparql_b1 = sparql_p2 -> Sparql.formula
type sparql_s = Sparql.formula


let rec form_p1 state : annot elt_p1 -> sparql_p1 = function
  | Is (annot,np) -> form_s1_as_p1 state np
  | Type (annot,c) -> (fun x -> Sparql.Pattern (Sparql.rdf_type x (Sparql.uri c)))
  | Rel (annot,p,m,np) ->
    let q_np = form_s1 state np in
    (fun x -> q_np (fun y ->
      let s, o = match m with Fwd -> x, y | Bwd -> y, x in
      Sparql.Pattern (Sparql.triple s (Sparql.uri p) o)))
  | Triple (annot,arg,np1,np2) ->
    let q_np1 = form_s1 state np1 in
    let q_np2 = form_s1 state np2 in
    (fun x -> q_np1 (fun y -> q_np2 (fun z -> triple_arg arg x y z)))
  | Search (annot,c) -> (fun x -> search_constr x c)
  | Filter (annot,c) -> (fun x -> filter_constr_entity x c)
  | And (annot,lr) ->
    let lr_d = List.map (fun elt -> form_p1 state elt) lr in
    (fun x -> Sparql.formula_and_list (List.map (fun d -> d x) lr_d))
  | Or (annot,lr) ->
    ( match annot#get_susp_focus_index with
    | Some i -> form_p1 state (List.nth lr i)
    | None ->
      let lr_d = List.map (fun elt -> form_p1 state elt) lr in
      (fun x -> Sparql.formula_or_list (List.map (fun d -> d x) lr_d)) )
  | Maybe (annot,f) ->
    if annot#is_susp_focus
    then form_p1 state f
    else
      let d = form_p1 state f in
      (fun x -> Sparql.formula_optional (d x))
  | Not (annot,f) ->
    if annot#is_susp_focus
    then form_p1 state f
    else
      let d = form_p1 (Oo.copy state) f in
      (fun x -> Sparql.formula_not (d x))
  | IsThere annot -> (fun x -> Sparql.True)
and form_p1_opt state = function
  | None -> (fun x -> Sparql.True)
  | Some rel -> form_p1 state rel
and form_s1_as_p1 state : annot elt_s1 -> sparql_p1 = function
  | Det (annot,det,rel_opt) ->
    let d1 = form_s2_as_p1 state det in
    let d2 = form_p1_opt state rel_opt in
    (fun x -> Sparql.formula_and (d1 x) (d2 x))
  | AnAggreg (annot,idg,modifg,g,relg_opt,np) ->
    if annot#is_susp_focus
    then form_s1_as_p1 state np
    else
      ( match np with
      | Det (_, An (id, _, _), _)
      | AnAggreg (_, id, _, _, _, _) ->
	form_aggreg_op state idg modifg g (form_p1_opt state relg_opt) id;
	form_s1_as_p1 state np
      | _ -> assert false )
  | NAnd (annot,lr) ->
    let lr_d = List.map (fun elt -> form_s1_as_p1 state elt) lr in
    (fun x -> Sparql.formula_and_list (List.map (fun d -> d x) lr_d))
  | NOr (annot,lr) ->
    ( match annot#get_susp_focus_index with
    | Some i -> form_s1_as_p1 state (List.nth lr i)
    | None ->
      let lr_d = List.map (fun elt -> form_s1_as_p1 state elt) lr in
      (fun x -> Sparql.formula_or_list (List.map (fun d -> d x) lr_d)) )
  | NMaybe (annot,f) ->
    if annot#is_susp_focus
    then form_s1_as_p1 state f
    else
      let d = form_s1_as_p1 state f in
      (fun x -> Sparql.formula_optional (d x))
  | NNot (annot,f) ->
    if annot#is_susp_focus
    then form_s1_as_p1 state f
    else
      let d = form_s1_as_p1 (Oo.copy state) f in
      (fun x -> Sparql.formula_not (d x))
and form_s2_as_p1 state : elt_s2 -> sparql_p1 = function
  | Term t ->
    (fun x -> Sparql.Filter (Sparql.expr_comp "=" (x :> Sparql.expr) (Sparql.term t :> Sparql.expr)))
(*    (fun x -> "BIND (" ^ Sparql.term t ^ " AS " ^ Sparql.term x ^ ")") *)
  | An (_id, _modif,head) ->
    let d_head =
      match head with
	| Thing -> (fun x -> Sparql.True)
	| Class c -> (fun x -> Sparql.Pattern (Sparql.rdf_type x (Sparql.uri c))) in
    d_head
  | The id ->
    (fun x ->
      let v = state#id_labelling#get_id_var id in
      let t = Rdf.Var v in
      Sparql.Filter (Sparql.expr_comp "=" (x :> Sparql.expr) (Sparql.term t :> Sparql.expr)))    
and form_s1 state : annot elt_s1 -> sparql_s1 = function
  | Det (annot,det,rel_opt) ->
    let qu = form_s2 state det in
    let d1 = form_p1_opt state rel_opt in
    (fun d -> qu d1 d)
  | AnAggreg (annot,idg,modifg,g,relg_opt,np) ->
    if annot#is_susp_focus
    then form_s1 state np
    else
      ( match np with
      | Det (_, An (id, _, _), _)
      | AnAggreg (_, id, _, _, _, _) ->
	form_aggreg_op state idg modifg g (form_p1_opt state relg_opt) id;
	form_s1 state np
      | _ -> assert false )
  | NAnd (annot,lr) ->
    let lr_q = List.map (fun elt -> form_s1 state elt) lr in
    (fun d -> Sparql.formula_and_list (List.map (fun q -> q d) lr_q))
  | NOr (annot,lr) ->
    ( match annot#get_susp_focus_index with
    | Some i -> form_s1 state (List.nth lr i)
    | None ->
      let lr_q = List.map (fun elt -> form_s1 state elt) lr in
      (fun d -> Sparql.formula_or_list (List.map (fun q -> q d) lr_q)) )
  | NMaybe (annot,f) ->
    if annot#is_susp_focus
    then form_s1 state f
    else
      let q = form_s1 state f in
      (fun d -> Sparql.formula_optional (q d))
  | NNot (annot,f) ->
    if annot#is_susp_focus
    then form_s1 state f
    else
      let q = form_s1 (Oo.copy state) f in
      (fun d -> Sparql.formula_not (q d))
(*      
  | NRelax f ->
    state#set_relax true;
    let q = form_s1 state f in
    state#set_relax false;
    q
*)
and form_s2 state : elt_s2 -> sparql_s2 = function
  | Term term ->
    let t = Sparql.term term in
    (fun d1 d2 -> Sparql.formula_and (d1 t) (d2 t))
  | An (id, modif, head) ->
    let qhead = form_head state head in
    let v = state#id_labelling#get_id_var id in
    state#set_modif v modif;
    let t = (Sparql.var v :> Sparql.term) in
    (fun d1 d2 -> state#add_var v; qhead t (Sparql.formula_and (d2 t) (d1 t))) (* YES: d2 - d1 *)
  | The id ->
    let v = state#id_labelling#get_id_var id in
    let t = (Sparql.var v :> Sparql.term) in
    (fun d1 d2 -> Sparql.formula_and (d2 t) (d1 t)) (* YES: d2 - s1 *)
and form_head state : elt_head -> (Sparql.term -> Sparql.formula -> Sparql.formula) = function
  | Thing ->
    (fun x form -> Sparql.formula_bind x form)
  | Class c ->
    (fun x form -> Sparql.formula_and (Sparql.Pattern (Sparql.rdf_type x (Sparql.uri c))) form)
and form_aggreg_op state idg modifg g (d : sparql_p1) id : unit =
  let vg = state#id_labelling#get_id_var idg in
  let v = state#id_labelling#get_id_var id in
  state#set_aggreg v (vg, g, (d (Sparql.var vg :> Sparql.term)));
  state#set_modif vg modifg
and form_dim state : annot elt_dim -> Sparql.projection option * Rdf.var option (* group by var *) * Sparql.formula (* relative *) = function
  | ForEachResult annot -> assert false
  | ForEach (annot,id,modif,rel_opt,id2) ->
    let v = state#id_labelling#get_id_var id in
    state#set_modif v modif;
    let d = form_p1_opt state rel_opt in
    let v2 = state#id_labelling#get_id_var id2 in
    Some (`Expr (Sparql.var v2 :> Sparql.expr), v), Some v2, (d (Sparql.var v2 :> Sparql.term))
  | ForTerm (annot,t,id2) ->
    let v2 = state#id_labelling#get_id_var id2 in
    None, None, Sparql.Filter (Sparql.expr_comp "=" (Sparql.var v2 :> Sparql.expr) (Sparql.term t :> Sparql.expr))
and form_aggreg state : annot elt_aggreg -> Sparql.projection * Rdf.var * Sparql.expr (* having expr *) = function
  | TheAggreg (annot,id,modif,g,rel_opt,id2) ->
    let v = state#id_labelling#get_id_var id in
    state#set_modif v modif;
    let d = form_p1_opt state rel_opt in
    let v2 = state#id_labelling#get_id_var id2 in
    let sparql_g = sparql_aggreg g in
    let t_v2 = (Sparql.var v2 :> Sparql.term) in
    (`Aggreg (sparql_g, t_v2), v), v2, Sparql.expr_of_formula (d (Sparql.term_aggreg sparql_g t_v2))
and form_expr state : annot elt_expr -> Sparql.expr = function
  | Undef annot -> Sparql.sparql ""
  | Const (annot,t) -> (Sparql.term t :> Sparql.expr)
  | Var (annot,id) -> (Sparql.var (state#id_labelling#get_id_var id) :> Sparql.expr)
  | Apply (annot,func,args) ->
    if not annot#defined
    then Sparql.sparql ""
    else
      ( match annot#focus_pos with
      | `Above (true, Some pos) -> form_expr state (List.nth args (pos-1))
      | _ ->
	let sparql_args = List.map (fun arg -> form_expr state arg) args in
	expr_apply func sparql_args )
and form_s state (s : annot elt_s) : seq_view * Sparql.view =
  let (_, view as seq_view), lr =
    match s with
    | Return (annot,np) -> (0, Atom (annot#ids,0)), [s]
    | Seq (annot,lr) -> (match annot#seq_view with Some seq_view -> seq_view | None -> assert false), lr
    | _ -> assert false in
  seq_view, form_view state lr view
and form_view state (lr : annot elt_s list) (v : view) : Sparql.view =
  let lv =
    match v with
    | Unit -> []
    | Atom _ -> [v]
    | InlineAggregs _ -> [v]
    | Aggreg _ -> [v]
    | Join (_,lv) -> lv in
  form_view_list state lr Sparql.empty_view lv
and form_view_list state (lr : annot elt_s list) (view : Sparql.view) : view list -> Sparql.view =
  let ids2vars ids = List.map state#id_labelling#get_id_var ids in
  function
  | [] -> view
  | Unit::lv -> form_view_list state lr view lv
  | Atom (ids,sid)::lv ->
    ( match List.nth lr sid with
    | Return (annot,np) ->
      let ids = annot#ids in
      let lx = ids2vars (Ids.elements ids.defs) in
      let form = form_s1 state np (fun t -> Sparql.True) in
      form_view_list state lr (Sparql.join_views [view; Sparql.simple_view lx form]) lv
    | SExpr (annot,name,id,modif,expr,rel_opt) ->
      let x = state#id_labelling#get_id_var id in
      state#set_modif x modif;
      let sparql_expr = form_expr state expr in
      let form =
	if sparql_expr = Sparql.sparql ""
	then Sparql.True
	else
	  let d = form_p1_opt state rel_opt in
	  Sparql.formula_and (Sparql.Pattern (Sparql.bind sparql_expr (Sparql.var x))) (d (Sparql.var x :> Sparql.term)) in
      form_view_list state lr (Sparql.join_views [view; Sparql.simple_view [x] form]) lv
    | SFilter (annot,id,expr) ->
      let x = state#id_labelling#get_id_var id in
      let sparql_expr = form_expr state expr in
      let lx, form =
	match annot#focus_pos with
	| `Above _ -> [x], Sparql.Pattern (Sparql.bind sparql_expr (Sparql.var x))
	| _ -> [], Sparql.Filter sparql_expr in
      let form =
	if sparql_expr = Sparql.sparql ""
	then Sparql.True
	else form in
      form_view_list state lr (Sparql.join_views [view; Sparql.simple_view lx form]) lv
    | _ -> assert false )
  | InlineAggregs (ids,sid,_ids2)::lv ->
    ( match List.nth lr sid with
    | SAggreg (annot, [ForEachResult _], aggregs) ->
      let l_aggregs = List.map (form_aggreg state) aggregs in
      let lx2 = List.map (fun (_,x2,_) -> x2) l_aggregs in
      let projections_aggregs = List.map (fun (proj,_,_) -> proj) l_aggregs in
      let havings_aggregs = List.map (fun (_,_,hav) -> hav) l_aggregs in
      let view =
	(fun ?limit () ->
	  let sq = view ?limit () in
	  { sq with
	    Sparql.projections = List.filter (fun (_,x) -> not (List.mem x lx2)) sq.Sparql.projections @ projections_aggregs;
	    groupings = List.filter (fun x -> not (List.mem x lx2)) sq.Sparql.groupings;
	    having = Sparql.log_and (sq.Sparql.having :: havings_aggregs) }) in
      form_view_list state lr view lv
    | _ -> assert false )
  | Aggreg (ids,sid,v2)::lv ->
    let aggregated_view = form_view state lr v2 in
    ( match List.nth lr sid with
    | SAggreg (annot,dims,aggregs) ->
      let l_dims = List.map (form_dim state) dims in
      let l_aggregs = List.map (form_aggreg state) aggregs in
      let projections_dims = List.fold_right (fun (proj_opt,_,_) res -> match proj_opt with None -> res | Some proj -> proj::res) l_dims [] in
      let projections_aggregs = List.map (fun (proj,_,_) -> proj) l_aggregs in
      let projections = projections_dims @ projections_aggregs in
      let groupings_dims = List.fold_right (fun (_,group_opt,_) res -> match group_opt with None -> res | Some group -> group::res) l_dims [] in
      let lf_dims = List.map (fun (_,_,hav) -> hav) l_dims in
      let havings_aggregs = List.map (fun (_,_,hav) -> hav) l_aggregs in
      let view_aggreg =
	(fun ?limit () ->
	  let form =
	    Sparql.formula_and_list
	      (Sparql.formula_of_view ?limit:(match limit with None -> None | Some l -> Some (10*l)) aggregated_view :: lf_dims) in
	  let form = (* special handling of GROUP_CONCAT without grouping, to avoid explosion *)
	    if groupings_dims = []
	    && List.exists (function (`Aggreg (Sparql.DistinctCONCAT, _), _) -> true | _ -> false) projections_aggregs
	    then Sparql.Subquery
	      (Sparql.make_subquery
		 ~projections:(List.fold_right
				 (fun (_,v2_opt,_) res -> match v2_opt with None -> res | Some v2 -> (`Bare,v2)::res) l_dims
				 (List.map (fun (_,v2,_) -> (`Bare,v2)) l_aggregs))
		 ~groupings:[]
		 ~having:Sparql.log_true
		 ?limit
		 form)
	    else form in
	  let sq_aggreg =
	    Sparql.make_subquery
	      ~projections
	      ~groupings:groupings_dims
	      ~having:(Sparql.log_and havings_aggregs)
	      ?limit
	      form in
	  if view = Sparql.empty_view && lv = []
	  then sq_aggreg (* isolated aggregation *)
	  else
	    Sparql.make_subquery
	      ~projections:(List.map (fun (_,x) -> (`Bare,x)) sq_aggreg.Sparql.projections)
	      ~groupings:(List.map (fun (_,x) -> x) sq_aggreg.Sparql.projections)
	      (Sparql.Subquery sq_aggreg)) in
      form_view_list state lr (Sparql.join_views [view; view_aggreg]) lv
    | _ -> assert false)
  | Join (_,lv1)::lv -> form_view_list state lr view (lv1@lv)


type template = ?constr:constr -> limit:int -> string

let make_query state t_list (view : Sparql.view) : template =
  (fun ?constr ~limit ->
    let sq_view = view ~limit () in
    let visible_projections =
      List.filter
	(fun (_,v) -> state#project v = Select || List.mem (Rdf.Var v) t_list)
	sq_view.Sparql.projections in
    let form_constr =
      match t_list, constr with
      | [(Rdf.Var _ as t)], Some c ->
	Sparql.formula_and sq_view.Sparql.formula (filter_constr_entity (Sparql.term t) c)
      | _ -> sq_view.Sparql.formula in
    let sq = { sq_view with
      Sparql.projections = visible_projections;
      Sparql.formula = form_constr } in
    let orderings =
      List.fold_right
	(fun (_,v) orderings ->
	  match sparql_order (state#order v) with
	  | None -> orderings
	  | Some order -> (order, Sparql.var v)::orderings)
	sq_view.Sparql.projections [] in
    let query = Sparql.select
      ~distinct:true
      ~projections:visible_projections
      ~groupings:(List.map Sparql.var sq.Sparql.groupings)
      ~having:sq.Sparql.having
      ~limit
      ~orderings
      (Sparql.pattern_of_formula form_constr) in
    (query :> string))

      
let s_annot (id_labelling : Lisql2nl.id_labelling) (ft : focus_term) (s_annot : annot elt_s)
    : Rdf.term list * template option * template option * template option * template option * seq_view =
  let state = new state id_labelling in
  let annot_view, view = form_s state s_annot in
  let t_list =
    match ft with
    | `TermIncr t | `TermNoIncr t -> [t]
    | `IdIncr id | `IdNoIncr id -> [Rdf.Var (id_labelling#get_id_var id)]
    | `Undefined -> [] in
  let query_opt =
    if Sparql.is_empty_view view
    then None
    else Some (make_query state t_list view) in
  let query_incr_opt (x : Rdf.var) filter_constr triple =
    match ft, t_list with
    | `IdNoIncr _, _
    | `TermNoIncr _, _ -> None (* no increments for this focus term (expressions, aggregations) *)
    | _, [t] ->
	let term_t = Sparql.term t in
	let tx = (Sparql.var x :> Sparql.term) in
	Some (fun ?(constr=True) ~limit ->
	  let form_x =
	    match t with
	    | Rdf.Var _
	    | Rdf.Bnode _ -> Sparql.formula_and (Sparql.formula_of_view ~limit view) (triple term_t tx)
	    | _ -> triple term_t tx in
	  (Sparql.select ~projections:[(`Bare,x)] ~limit
	    (Sparql.pattern_of_formula
	       (Sparql.formula_and form_x (filter_constr tx constr))) :> string))
      | _ -> None in
  let query_class_opt = query_incr_opt "class" filter_constr_class (fun t tc -> Sparql.Pattern (Sparql.rdf_type t tc)) in
  let query_prop_has_opt = query_incr_opt "prop" filter_constr_property (fun t tp -> Sparql.Pattern (Sparql.triple t tp (Sparql.bnode ""))) in
  let query_prop_isof_opt = query_incr_opt "prop" filter_constr_property (fun t tp -> Sparql.Pattern (Sparql.triple (Sparql.bnode "") tp t)) in
  t_list, query_opt, query_class_opt, query_prop_has_opt, query_prop_isof_opt, annot_view
