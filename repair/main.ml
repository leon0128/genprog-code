(* 
 * Program Repair Prototype (v2) 
 *
 * This is the main driver: it reads in options, loads the
 * program-to-be-repaired (using the given representation),
 * calls for its fault localization information, and then
 * applies a search technique to the problem. 
 *
 * Still TODO: parallelism (e.g., work queues)
 *)
open Printf
open Cil
open Utils
open Global

(* Global(ish) variables needed for distributed computing results *)
let listevals = ref (Array.make_matrix 1 1 0)
let exchange_iters = ref 0 
let gens_used = ref 1

let search_strategy = ref "brute" 
let representation = ref ""

let _ =
  options := !options @
  [
    "--multi-file", Arg.Set Rep.multi_file, "X program has multiple source files.  Will use separate subdirs."	;
    "--incoming-pop", Arg.Set_string Search.incoming_pop, "X X contains a list of variants for the first generation" ;
    "--search", Arg.Set_string search_strategy, "X use strategy X (brute, ga) [comma-separated]";
    "--no-rep-cache", Arg.Set Rep.no_rep_cache, " do not load representation (parsing) .cache file" ;
    "--no-test-cache", Arg.Set Rep.no_test_cache, " do not load testing .cache file" ;
    "--rep", Arg.Set_string representation, "X use representation X (c,txt,java)" ;
  ] 


(***********************************************************************
 * Conduct a repair on a representation
 ***********************************************************************)
let process base ext (rep : 'a Rep.representation) = begin
  let population = if !Search.incoming_pop <> "" then begin
    let lines = file_to_lines !Search.incoming_pop in
    List.flatten
      (List.map (fun filename ->
        debug "process: incoming population: %s\n" filename ; 
        try [
          let rep2 = rep#copy () in
          rep2#from_source filename ;
          rep2#compute_localization () ;
          (rep2, 0.0)
        ] 
        with _ -> [] 
      ) lines)
  end else [] in 

  (* Perform sanity checks on the file and compute fault localization
   * information. Optionally, if we have that information cached, 
   * load the cached values. *) 
  begin
    try 
      (if !Rep.no_rep_cache then failwith "skip this") ; 
      rep#load_binary (base^".cache") 
    with _ -> 
      rep#from_source !program_to_repair ; 
      rep#sanity_check () ; 
      rep#compute_localization () ;
      rep#save_binary (base^".cache") 
  end ;
  rep#debug_info () ; 
  
  let startalg comps population = 
    let comma = Str.regexp "," in 
      
  (* Apply the requested search strategies in order. Typically there
   * is only one, but they can be chained. *) 
    let what_to_do = Str.split comma !search_strategy in

    (List.fold_left (fun population strategy ->
      let pop = List.map fst population in
	  match strategy with
	  | "brute" | "brute_force" | "bf" -> 
	    Search.brute_force_1 rep pop
	  | "ga" | "gp" | "genetic" -> 
	    Search.genetic_algorithm rep pop ~comp:comps
	  | "multiopt" | "ngsa_ii" -> 
	    Multiopt.ngsa_ii rep pop
	  | x -> failwith x
     ) population what_to_do)
  in
    
  (* Adds distributed computation, currently just done on the same computer sequentially.  *)
    
  if !Search.distributed then begin
    (* Some Exception cases *)
    if (!Search.gen_per_exchange >= !Search.generations) then begin
      debug "\nIf you don't want more generations in total than generations before exchanges, you probably shouldn't enable the distributed computing option.\n";
      exit 1
    end;
    if (!Search.num_comps < 2) then begin
      debug "\nIf you want to have fewer than 2 computers simulated, you probably shouldn't enable the distributed computing option.\n";
      exit 1
    end;
    if (!Search.variants_exchanged > !Search.popsize) then begin
      debug "\nYou can't exchange more variants than exist in a population. \n";
      exit 1
    end;

    (* Main function Setup *)
    let totgen = !Search.generations in
    let in_pop = ref [] in
    Search.generations := !Search.gen_per_exchange;
    exchange_iters := totgen / !Search.gen_per_exchange;
    let currentevals = ref 0 in
    (* Sets the original value of in_pop to be the incoming_population for all computers *)
    for comps = 0 to (!Search.num_comps - 1) do
      in_pop := population :: !in_pop;
    done; 
      
    (* Main function Start *)
    (* Starts loop for the runs where exchange takes place*)
    listevals := Array.make_matrix !Search.num_comps (!exchange_iters + 1) 0;
    let rec all_iterations gen population =
      let rec one_iteration comps =
	if comps < !Search.num_comps then begin
	  debug "Computer %d:\n" (comps+1);
	  let returnval = startalg comps (List.nth population comps) in
	    !listevals.(comps).(gen) <- Rep.num_test_evals_ignore_cache () - !currentevals;
	    currentevals := Rep.num_test_evals_ignore_cache ();
	    returnval :: (one_iteration (comps + 1))
	end else []
      in
	if gen < !exchange_iters then 
 	  let returnval = one_iteration 0 in
	    gens_used := 1 + !gens_used;
	    all_iterations (gen + 1) (Search.exchange rep returnval)
	else if (totgen mod !Search.gen_per_exchange) <> 0 then begin
	  (* Goes through the rest of the generations requested*)
	  Search.generations := (totgen mod !Search.gen_per_exchange);
	  ignore(one_iteration 0);
	  gens_used := 1 + !gens_used
	end
    in
      all_iterations 0 !in_pop
  end else
    (*Runs it like it normally would if the distributed option isn't enabled *)
    ignore(startalg 1 population);

  (* If we had found a repair, we could have noted it earlier and 
   * exited. *)
    debug "\nNo repair found.\n"  
end 

(***********************************************************************
 * Parse Command Line Arguments, etc. 
 ***********************************************************************)
let main () = begin
  Random.self_init () ; 
  (* By default we use and note a new random seed each time, but the user
   * can override that if desired for reproducibility. *) 
  random_seed := (Random.bits ()) ;  
  Rep.port := 800 + (Random.int 800) ;  

  let to_parse_later = ref [] in 
  let handleArg str = begin
    to_parse_later := !to_parse_later @ [str] 
  end 
  in 
  let aligned = Arg.align !options in 
  Arg.parse aligned handleArg usageMsg ; 
  List.iter parse_options_in_file !to_parse_later ;  
  (* now parse the command-line arguments again, so that they win
   * out over "./configuration" or whatnot *) 
  (* CLG: interestingly, prior to 6/24/11, this could never have worked 
	 properly; you need to reset the Arg counter to get it to reparse! *)
  Arg.current := 0;
  Arg.parse aligned handleArg usageMsg ; 
  if !program_to_repair = "" then exit 1 ;
  (* Bookkeeping information to print out whenever we're done ... *) 
  at_exit (fun () -> 
    let tc = (Rep.num_test_evals_ignore_cache ()) in 
    debug "\nVariant Test Case Queries: %d\n" tc ;
    debug "\"Test Suite Evaluations\": %g\n\n" 
      ((float tc) /. (float (!pos_tests + !neg_tests))) ;

    (* Test evaluations per computer for Distributed algorithm *)
    if !Search.distributed then begin
      Array.iteri 
	(fun comps ->
	  fun _ -> debug "Computer %d:\t" comps) !listevals;
      debug "\n";
      
      for gen=0 to !gens_used do
	for comps=0 to !Search.num_comps-1 do
	  debug "%d\t\t" !listevals.(comps).(gen) 
	done;
	debug "\n"
      done;
      
      debug "\nTotal = \n";
      Array.iteri 
	(fun comps ->
	  fun listevals ->
	    let total = 
	      Array.fold_left 
		(fun total ->
		  fun eval ->
		    total + eval) 0 listevals
	    in
	      debug "%d\t\t" total
	) !listevals;
      debug "\n\n";
      debug "Total generations run = %d\n\n" (!gens_used * !Search.gen_per_exchange)
    end;

    debug "Compile Failures: %d\n" !Rep.compile_failures ; 
    Stats2.print !debug_out "Program Repair Prototype (v2)" ; 
    close_out !debug_out ;
    Stats2.print stdout "Program Repair Prototype (v2)" ; 
  ) ; 


  let debug_str = sprintf "repair.debug.%d" !random_seed in 
  debug_out := open_out debug_str ; 

  Cil.initCIL () ; 
  Random.init !random_seed ; 

  (* For debugging and reproducibility purposes, print out the values of
   * all command-line argument-settable global variables. *)
  List.iter (fun (name,arg,_) ->
    debug "%s %s\n" name 
    (match arg with
    | Arg.Set br 
    | Arg.Clear br 
    -> sprintf "%b" !br 
    | Arg.Set_string sr
    -> sprintf "%S" !sr
    | Arg.Set_int ir
    -> sprintf "%d" !ir
    | Arg.Set_float fr
    -> sprintf "%g" !fr
    | _ -> "?") 
  ) (List.sort (fun (a,_,_) (a',_,_) -> compare a a') (!options)) ; 

  if not !Rep.no_test_cache then begin 
    Rep.test_cache_load () ;
    at_exit Rep.test_cache_save ;
  end ;


  (* Read in the input file to be repaired and convert it to 
   * our internal representation. *) 
  let base, real_ext = split_ext !program_to_repair in
  let filetype = 
    if !representation = "" then 
      real_ext
    else 
      !representation
  in 
  Global.extension := filetype ; 

	match String.lowercase filetype with 
	| "c" | "i" -> 
    process base real_ext (
      if !Rep.multi_file then begin
        Rep.use_subdirs := true;
        ((new Cilrep.multiCilRep) :> 'a Rep.representation)
      end else 
        ((new Cilrep.cilRep) :> 'a Rep.representation) 
    )

  | "txt" | "string" ->
    process base real_ext 
    (((new Stringrep.stringRep) :> 'b Rep.representation))

  | "java" -> 
    process base real_ext 
    ((new Javarep.javaRep) :> 'c Rep.representation)

  | other -> begin 
    List.iter (fun (ext,myfun) ->
      if ext = other then myfun () 
    ) !Rep.global_filetypes ; 
    debug "%s: unknown file type to repair" !program_to_repair ;
    exit 1 
  end 
end ;;

main () ;; 
