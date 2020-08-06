type capture = {
    capture_name : string;
  }

module IntMap = Map.Make(Int)

type match_ = {
    name : string option;
    pattern : Pcre.regexp;
    captures : capture IntMap.t;
  }

type delim = {
    delim_begin : Pcre.regexp;
    delim_end : Pcre.regexp;
    delim_patterns : pattern list;
    delim_name : string option;
    delim_content_name : string option;
    delim_pats : pattern list;
    delim_begin_captures : capture IntMap.t;
    delim_end_captures : capture IntMap.t;
  }

and pattern_kind =
  | Match of match_
  | Delim of delim
  | Include of string

and pattern = {
    pattern_kind : pattern_kind;
  }

type grammar = {
    name : string;
    patterns : pattern list;
    repository : (string, pattern list) Hashtbl.t;
  }

let rec find key = function
  | [] -> None
  | (k, v) :: obj ->
     if k = key then
       Some v
     else
       find key obj

let find_exn key obj =
  match find key obj with
  | Some v -> v
  | None -> failwith (key ^ " not found")

let get_dict = function
  | `Dict d -> d
  | _ -> failwith "Type error: Expected dict"

let get_string = function
  | `String s -> s
  | _ -> failwith "Type error: Expected string"

let get_list f = function
  | `Array l -> List.map f l
  | _ -> failwith "Type error: Expected list"

let of_plist plist =
  let iflags = Pcre.cflags [`ANCHORED; `DOLLAR_ENDONLY] in
  let rec get_captures acc = function
    | [] -> acc
    | (k, v) :: kvs ->
       let idx = int_of_string k in
       let v = get_dict v in
       let name = match find "name" v with
         | None -> failwith "No name key in capture"
         | Some name -> get_string name
       in get_captures (IntMap.add idx { capture_name = name } acc) kvs
  in
  let rec get_patterns obj =
    get_list (fun x -> get_dict x |> patterns_of_plist)
      (find_exn "patterns" obj)
  and patterns_of_plist obj =
    let kind =
      match find "include" obj with
      | Some s -> Include (get_string s)
      | None ->
         match find "match" obj, find "begin" obj, find "end" obj with
         | Some s, None, None ->
            Match {
                pattern = Pcre.regexp ~iflags (get_string s);
                name = Option.map get_string (find "name" obj);
                captures =
                  match find "captures" obj with
                  | None -> IntMap.empty
                  | Some value ->
                     get_captures IntMap.empty (get_dict value)
              }
         | None, Some b, Some e ->
            let delim_begin_captures, delim_end_captures =
              match find "captures" obj with
              | Some value ->
                 let captures = get_captures IntMap.empty (get_dict value) in
                 captures, captures
              | None ->
                 ( (match find "beginCaptures" obj with
                    | Some value ->
                       get_captures IntMap.empty (get_dict value)
                    | None -> IntMap.empty)
                 , (match find "endCaptures" obj with
                    | Some value ->
                       get_captures IntMap.empty (get_dict value)
                    | None -> IntMap.empty) )
            in
            Delim {
                delim_begin = Pcre.regexp ~iflags (get_string b);
                delim_end = Pcre.regexp ~iflags (get_string e);
                delim_patterns =
                  begin match find "patterns" obj with
                  | None -> []
                  | Some v ->
                     get_list (fun x -> get_dict x |> patterns_of_plist) v
                  end;
                delim_name = Option.map get_string (find "name" obj);
                delim_content_name =
                  Option.map get_string (find "contentName" obj);
                delim_pats = [];
                delim_begin_captures;
                delim_end_captures;
              }
         | Some _, Some _, Some _ ->
            failwith "match, begin, and end keys all present"
         | Some _, Some _, None -> failwith "match and begin keys present"
         | Some _, None, Some _ -> failwith "match and end keys present"
         | None, Some _, None -> failwith "begin key without end key"
         | None, None, Some _ -> failwith "end key without begin key"
         | None, None, None -> failwith "Missing match or begin and end keys"
    in { pattern_kind = kind; }
  in
  let obj = get_dict plist in
  { name = get_string (find_exn "name" obj)
  ; patterns = get_patterns obj
  ; repository =
      match find "repository" obj with
      | None -> Hashtbl.create 0
      | Some kvs ->
         let hashtbl = Hashtbl.create 31 in
         List.iter (fun (k, v) ->
             let v = get_dict v in
             let pats = get_patterns v in
             Hashtbl.add hashtbl k pats
           ) (get_dict kvs);
         hashtbl
  }

type token =
  | Span of string option * int
  | Delim_open of delim * int
  | Delim_close of delim * int

let contains_at idx str prefix =
  let pre_len = String.length prefix in
  let str_len = String.length str in
  if idx + pre_len > str_len then
    false
  else
    String.sub str idx pre_len = prefix

type rules_tree = Rule of string * string option * rules_tree list

let rec eval_rules idx str = function
  | [] -> None
  | (Rule(name, klass, children)) :: rules ->
     if contains_at idx str name then
       match eval_rules (idx + String.length name) str children with
       | Some a -> Some a
       | None -> klass
     else
       eval_rules idx str rules

let get_class str =
  let rules =
    [ Rule("comment", Some "co", [])
    ; Rule("constant", None,
           [ Rule(".numeric", Some "bn", [])
           ; Rule(".language", Some "cn", []) ])
    ; Rule("keyword", Some "kw",
           [ Rule(".control", Some "cf", [])
           ; Rule(".operator", Some "op", []) ])
    ; Rule("entity", None,
           [ Rule(".name", Some "va",
                  [ Rule(".function", Some "fu", [])
                  ; Rule(".type", Some "dt", []) ])
           ]
        )
    ; Rule("variable", Some "va", [])
    ]
  in
  eval_rules 0 str rules

(** If the stack is empty, returns the main patterns associated with the
    grammar. Otherwise, returns the patterns associated with the delimiter at
    the top of the stack. *)
let next_pats grammar = function
  | [] -> grammar.patterns
  | delim :: _ -> delim.delim_pats

let handle_captures default substring =
  IntMap.fold (fun idx capture acc ->
      let start, end_ = Pcre.get_substring_ofs substring idx in
      (Span(Some capture.capture_name, end_)) :: (Span(default, start)) :: acc)

(** Tokenizes a line according to the grammar.

    [grammar]: The language grammar.
    [stack]: The stack that keeps track of nested delimiters
    [len]: The length of the string.
    [pos]: The current index into the string.
    [acc]: The list of tokens, with the rightmost ones at the front.
    [line]: The string that is being matched and tokenized.
    [rem_pats]: The remaining patterns that have yet to be tried *)
let rec match_line ~grammar ~stack ~len ~pos ~acc ~line rem_pats =
  let default = match stack with
    | [] -> None
    | x :: _ -> x.delim_name
  in
  (* Try each pattern in the list until one matches. If none match, increment
     [pos] and try all the patterns again. *)
  let rec try_pats ~k = function
    | [] -> k () (* No patterns have matched, so call the callback *)
    | { pattern_kind = Match m } :: pats ->
       (try
          let subs = Pcre.exec ~pos ~rex:m.pattern line in
          let (start, end_) = Pcre.get_substring_ofs subs 0 in
          assert (start = pos);
          let acc = (Span(default, pos)) :: acc in
          let acc = handle_captures default subs m.captures acc in
          let acc = (Span(m.name, end_)) :: acc in
          match_line ~grammar ~stack ~len ~pos:end_ ~acc ~line
            (next_pats grammar stack)
        with Not_found -> try_pats ~k pats)
    | { pattern_kind = Delim d } :: pats ->
       (try
          (* Try to match the delimiter's begin pattern *)
          let subs = Pcre.exec ~pos ~rex:d.delim_begin line in
          let (start, end_) = Pcre.get_substring_ofs subs 0 in
          assert (start = pos);
          let acc = (Span(default, pos)) :: acc in
          let acc = handle_captures default subs d.delim_begin_captures acc in
          let acc = (Delim_open(d, end_)) :: acc in
          (* Push the delimiter on the stack and continue *)
          match_line ~grammar ~stack:(d :: stack) ~len ~pos:end_ ~acc ~line
            d.delim_pats
        with Not_found -> try_pats ~k pats)
    | { pattern_kind = Include name } :: pats ->
       let len = String.length name in
       if name = "$self" then
         failwith "Unimplemented"
       else if len > 0 && String.get name 0 = '#' then
         let key = String.sub name 1 (len - 1) in
         match Hashtbl.find_opt grammar.repository key with
         | None -> failwith ("Unknown repo key " ^ key)
         | Some pats' -> try_pats pats' ~k:(fun () -> try_pats ~k pats)
       else
         failwith "Unimplemented"
  in
  if pos > len then
    (List.rev acc, stack) (* End of string reached *)
  else
    (* No patterns have matched, so increment the position and try again *)
    let k () =
      match_line ~grammar ~stack ~len ~pos:(pos + 1) ~acc ~line grammar.patterns
    in
    match stack with
    | [] -> try_pats rem_pats ~k
    | delim :: stack' ->
       try
         (* Try to match the delimiter's end pattern *)
         let subs = Pcre.exec ~pos ~rex:delim.delim_end line in
         let (start, end_) = Pcre.get_substring_ofs subs 0 in
         assert (start = pos);
         let acc = (Span(default, pos)) :: acc in
         let acc = handle_captures default subs delim.delim_end_captures acc in
         let acc = (Delim_close(delim, end_)) :: acc in
         (* Pop the delimiter off the stack and continue *)
         match_line ~grammar
           ~stack:stack' ~len ~pos:end_  ~acc ~line (next_pats grammar stack)
       with Not_found -> try_pats rem_pats ~k

type exists_node = Node : 'a Soup.node -> exists_node

let create_node name i j line =
  assert (j >= i);
  let inner_text = String.sub line i (j - i) in
  let class_ = match Option.bind name get_class with
    | None -> None
    | Some a -> Some a
  in
  match class_ with
  | Some class_ -> Node (Soup.create_element ~class_ "span" ~inner_text)
  | None -> Node (Soup.create_text inner_text)

let rec highlight_tokens i acc line = function
  | [] -> List.rev acc, i
  | Span(name, j) :: toks ->
     let span = create_node name i j line in
     highlight_tokens j (span :: acc) line toks
  | Delim_open(d, j) :: toks ->
     let span = create_node d.delim_name i j line in
     highlight_tokens j (span :: acc) line toks
  | Delim_close(d, j) :: toks ->
     let span = create_node d.delim_name i j line in
     highlight_tokens j (span :: acc) line toks

let tokenize_line grammar stack line =
  match_line ~grammar ~stack ~len:(String.length line) ~pos:0 ~acc:[] ~line
    (next_pats grammar stack)

(** Maps over the list while keeping track of some state.

    Discards the state because I don't need it. *)
let rec map_fold f acc = function
  | [] -> []
  | x :: xs ->
     let y, acc = f acc x in
     y :: map_fold f acc xs

let tokenize_block grammar code =
  let lines = String.split_on_char '\n' code in
  (* Some patterns don't work if there isn't a newline *)
  let lines = List.map (fun s -> s ^ "\n") lines in
  let a's =
    map_fold (fun stack line ->
        let tokens, stack = tokenize_line grammar stack line in
        let nodes, last = highlight_tokens 0 [] line tokens in
        let a = Soup.create_element "a" ~class_:"sourceLine" in
        List.iter (fun (Node node) -> Soup.append_child a node) nodes;
        let name = match stack with
          | [] -> None
          | x :: _ -> x.delim_name
        in
        let Node n = create_node name last (String.length line) line in
        assert (String.get line (String.length line - 1) = '\n');
        Soup.append_child a n;
        a, stack) [] lines
  in
  let code = Soup.create_element "code" in
  List.iter (Soup.append_child code) a's;
  let pre = Soup.create_element "pre" in
  Soup.append_child pre code;
  pre
