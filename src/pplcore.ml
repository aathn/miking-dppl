(** The entrypoint for the pplcore executable. Handles command line argument
    parsing, and lexing/parsing. *)

open Eval
open Cps
open Ast
open Const
open Printf
open Utils
open Debug

(** Mapping between predefined variable names and builtin constants *)
let builtin_const = [
  "not",          CNot;
  "and",          CAnd(None);
  "or",           COr(None);

  "mod",          CMod(None);
  "sll",          CSll(None);
  "srl",          CSrl(None);
  "sra",          CSra(None);

  "inf",          CFloat(infinity);
  "log",          CLog;

  "add",          CAdd(None);
  "sub",          CSub(None);
  "mul",          CMul(None);
  "div",          CDiv(None);
  "neg",          CNeg;
  "lt",           CLt(None);
  "leq",          CLeq(None);
  "gt",           CGt(None);
  "geq",          CGeq(None);

  "eq",           CEq(None);
  "neq",          CNeq(None);

  "normal",       CNormal(None, None);
  "uniform",      CUniform(None, None);
  "gamma",        CGamma(None, None);
  "exponential",  CExp(None);
  "bernoulli",    CBern(None);
]

(** Mapping between predefined variable names and terms *)
let builtin = [
  "logpdf",       TmLogPdf(na,None);
  "sample",       TmSample(na);
  "weight",       TmWeight(na);
] @ List.map (fun (x, y) -> x, tm_of_const y) builtin_const

(** Add a slash at the end of a path if not already available *)
let add_slash s =
  if String.length s = 0 || (String.sub s (String.length s - 1) 1) <> "/"
  then s ^ "/" else s

(** Expand a list of files and folders into a list of file names *)
let files_of_folders lst = List.fold_left (fun a v ->
    if Sys.is_directory v then
      (Sys.readdir v
       |> Array.to_list
       |> List.filter (fun x ->
           not (String.length x >= 1 && String.get x 0 = '.'))
       |> List.map (fun x -> (add_slash v) ^ x)
       |> List.filter (fun x -> not (Sys.is_directory x))
      ) @ a
    else v::a
  ) [] lst

(** Function for lexing and parsing a file. *)
let parse par filename =
  let file = open_in filename in
  let lexbuf = Lexing.from_channel file in
  begin try
      lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = filename };
      let tm = par lexbuf in
      close_in file; tm
    with | Parsing.Parse_error ->
      if !utest then (
        printf "\n ** Parse error at %s"
          (string_of_position (lexbuf.lex_curr_p));
        utest_fail := !utest_fail + 1;
        utest_fail_local := !utest_fail_local + 1;
        nop)
      else
        failwith (sprintf "Parse error at %s"
                    (string_of_position (lexbuf.lex_curr_p)))
  end

(** Function for executing a file. *)
let exec filename =
  if !utest then printf "%s: " filename;
  utest_fail_local := 0;

  let tm = match Filename.extension filename with
    | ".ppl"  -> parse (Parser.main Lexer.main) filename
    | ".tppl" -> parse (Tpplparser.main Tppllexer.main) filename
    | s       -> failwith ("Unsupported file type: " ^ s) in

  debug (debug_cps || debug_lift_apps) "Input term"
    (fun () -> string_of_tm tm);

  (* If chosen inference is aligned SMC, perform static analysis *)
  let tm = if !Analysis.align
    then begin
      (* Label program and builtins in preparation for static analysis *)
      let tm,bmap,nl = Analysis.label (builtin |> List.split |> fst) tm in

      debug debug_sanalysis "After labeling" (fun () -> string_of_tm tm);

      (* Perform static analysis, returning all dynamic labels *)
      let dyn = Analysis.analyze bmap tm nl in

      (* By using the above analysis results, transform all dynamic
         checkpoints. This information will be handled by the inference
         algorithm. *)
      Analysis.align_weight bmap dyn tm
    end else tm in

  debug debug_sanalysis "After SMC alignment" (fun () -> string_of_tm tm);

  let builtin =
    builtin

    (* Transform builtins to CPS. Required since we need to wrap constant
       functions in CPS forms *)
    |> List.map (fun (x, y) -> (x, (cps_atomic y)))

    (* Debruijn transform builtins (since they have now been
       CPS transformed) *)
    |> List.map (fun (x, y) -> (x, debruijn [] y)) in

  debug debug_cps_builtin "CPS builtin"
     (fun () -> String.concat "\n"
        (List.map
           (fun (x, y) -> sprintf "%s = %s" x
               (string_of_tm ~margin:1000 y)) builtin));

  (* Perform CPS transformation of main program *)
  let tm = cps tm in

  debug debug_cps "Post CPS" (fun () -> string_of_tm ~pretty:false tm);

  (* Evaluate CPS form of main program *)
  let _w,res = (* TODO *)
    tm |> debruijn (builtin |> List.split |> fst)
    |> eval (builtin |> List.split |> snd) 0.0 in

  debug debug_cps "Post CPS eval" (fun () -> string_of_tm res);

  if !utest && !utest_fail_local = 0 then printf " OK\n" else printf "\n"

(** Main function. Parses command line arguments *)
let main =
  let speclist = [

    "--test",
    Arg.Unit(fun _ -> utest := true),
    " Enable unit tests.";

    "--align-weight",
    Arg.Unit(fun _ -> Analysis.align := true),
    " Enable program alignment using static analysis.";

    "--inference",
    Arg.String(fun s -> match s with
        | "is"  -> inference := Importance
        | "smc" -> inference := SMC
        | _     -> failwith "Incorrect inference algorithm"
      ),
    " Specifies inference method. Options are: is, smc.";

    "--samples",
    Arg.Int(fun i -> match i with
        | i when i < 1 -> failwith "Number of samples must be positive"
        | i            -> particles := i),
    " Specifies the number of samples in affected inference algorithms.";

  ] in

  let speclist = Arg.align speclist in
  let lst = ref [] in
  let anon_fun arg = lst := arg :: !lst in
  let usage_msg = "" in

  Arg.parse speclist anon_fun usage_msg;

  List.iter exec (files_of_folders !lst);

  Debug.utest_print ();
