
osparklis:
	ocamlfind ocamlc -package js_of_ocaml -package js_of_ocaml.syntax -syntax camlp4o -linkpkg -o osparklis.byte osparklis.ml
	js_of_ocaml osparklis.byte
