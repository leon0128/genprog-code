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
open Global
open Elf

let incoming_pop_file = ref "" 
let search_strategy = ref "brute" 
let representation = ref ""
let skip_sanity = ref false
let network_test = ref false
let time_at_start = Unix.gettimeofday () 

let _ =
  options := !options @
  [
    "--multi-file", Arg.Set Rep.multi_file, "X program has multiple source files.  Will use separate subdirs."	;
    "--incoming-pop", Arg.Set_string incoming_pop_file, "X X contains a list of variants for the first generation" ;
    "--search", Arg.Set_string search_strategy, "X use strategy X (brute, ga) [comma-separated]";
    "--no-rep-cache", Arg.Set Rep.no_rep_cache, " do not load representation (parsing) .cache file" ;
    "--no-test-cache", Arg.Set Rep.no_test_cache, " do not load testing .cache file" ;
	"--no-cache", Arg.Unit (fun () -> Rep.no_rep_cache := true; Rep.no_test_cache := true), " do not load either cache file.";
	"--skip-sanity", Arg.Set skip_sanity, " skip sanity checking";
    "--nht-server", Arg.Set_string Rep.nht_server, "X connect to network test cache server X" ; 
    "--nht-port", Arg.Set_int Rep.nht_port, "X connect to network test cache server on port X" ;
    "--nht-id", Arg.Set_string Rep.nht_id, "X this repair scenario's NHT identifier" ; 
    "--rep", Arg.Set_string representation, "X use representation X (c,txt,java)" ;
    "--networktest", Arg.Set network_test, " Debug: Test to see if the network works" ;
    "-help", Arg.Unit (fun () -> raise (Arg.Bad "")),   " Display this list of options" ;
    "--help", Arg.Unit (fun () -> raise (Arg.Bad "")),   " Display this list of options" ;
  ] 


(***********************************************************************
 * Conduct a repair on a representation
 ***********************************************************************)
let process base ext (rep : 'a Rep.representation) = begin
  let population : 'a Rep.representation list = if !incoming_pop_file <> "" then begin
    let lines = file_to_lines !incoming_pop_file in
    List.flatten
      (List.map (fun filename ->
        debug "process: incoming population: %s\n" filename ; 
        try [
          let rep2 = rep#copy () in
          rep2#from_source filename ;
          rep2#compute_localization () ;
          rep2
        ] 
        with _ -> [] 
      ) lines)
  end else [] in 

  (* Perform sanity checks on the file and compute fault localization
   * information. Optionally, if we have that information cached, 
   * load the cached values. *) 
  begin
    try begin 
      (if !Rep.no_rep_cache then failwith "skip this") ; 
      rep#load_binary (base^".cache") ;
    end with _ -> begin 
      rep#from_source !program_to_repair ; 
      if not !skip_sanity then
        rep#sanity_check () ; 
      rep#compute_localization () ;
      rep#save_binary (base^".cache") 
    end 
  end ;
  rep#debug_info () ; 

  let comma = Str.regexp "," in 
      
	(* Apply the requested search strategies in order. Typically there
	 * is only one, but they can be chained. *) 
  let what_to_do = Str.split comma !search_strategy in
	try
	  ignore(
		List.fold_left 
		  (fun pop ->
			fun strategy ->
				match strategy with
				| "dist-seq" | "seq" | "ds" ->
				  Network.distributed_sequential rep pop
				| "dist" | "distributed" | "dist-net" | "net" | "dn" ->
				  Network.distributed_client rep pop
				| "brute" | "brute_force" | "bf" -> 
				  Search.brute_force_1 rep pop
				| "ga" | "gp" | "genetic" -> 
				  Search.genetic_algorithm rep pop
				| "multiopt" | "ngsa_ii" -> 
				  Multiopt.ngsa_ii rep pop
				| x -> failwith x
		  ) population what_to_do);
	(* If we had found a repair, we could have noted it earlier and 
	 * thrown an exception. *)
	  debug "\nNo repair found.\n"  
	with Fitness.Found_repair(rep) -> ()
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
  Arg.current := 0;
  Arg.parse aligned handleArg usageMsg ; 
  let debug_str = sprintf "repair.debug.%d" !random_seed in 
  debug_out := open_out debug_str ; 

  if !network_test then begin
    Network.networktest();
    exit 1
  end;

  (* For debugging and reproducibility purposes, print out the values of
   * all command-line argument-settable global variables. *)
  List.iter (fun (name,arg,_) ->
    if name = "-help" or name = "--help" then () 
    else
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

  (* (\* Cloud-computing debugging: print out machine informaiton. *\) *)
  (* List.iter (fun cmd ->  *)
  (*   try *)
  (*     let uname_output = Unix.open_process_in cmd in  *)
  (*     let line = input_line uname_output in *)
  (*     debug "%s: %s\n" cmd line ;  *)
  (*     ignore (Unix.close_process_in uname_output)  *)
  (*   with e ->  *)
  (*     debug "%s: %s\n" cmd (Printexc.to_string e)  *)
  (* ) [ "uname -a" ; "date" ; "id" ; "cat /etc/redhat-release" ] ;  *)

  (* the network server spins exits on its own; no need to load the rep
     cache or anything.  Should probably be its own program but whaver *)
  if !Network.server then Network.i_am_the_server ();

  if !program_to_repair = "" then begin 
    abort "main: no program to repair (try --help)\n" ;
  end ; 

  (* Bookkeeping information to print out whenever we're done ... *) 
  at_exit (fun () -> 
    let tc = (Rep.num_test_evals_ignore_cache ()) in 
    debug "\nVariant Test Case Queries: %d\n" tc ;
    debug "\"Test Suite Evaluations\": %g\n\n" 
      ((float tc) /. (float (!pos_tests + !neg_tests))) ;
    
    debug "Compile Failures: %d\n" !Rep.compile_failures ; 
    debug "Wall-Clock Seconds Elapsed: %g\n" 
      ((Unix.gettimeofday ()) -. time_at_start) ;
    Stats2.print !debug_out "Program Repair Prototype (v2)" ; 
    close_out !debug_out ;
    debug_out := stdout ; 
    Stats2.print stdout "Program Repair Prototype (v2)" ; 
  ) ; 



  Cil.initCIL () ; 
  Random.init !random_seed ; 


  if not !Rep.no_test_cache then begin 
    Rep.test_cache_load () ;
    at_exit (fun () -> 
      debug "Rep: saving test cache\n" ; 
      Rep.test_cache_save () ;
    ) 
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
	  if !(Rep.multi_file) then (Rep.use_subdirs := true; Rep.use_full_paths := true);
    process base real_ext (((new Cilrep.cilRep) :> 'a Rep.representation))

  | "cilpatch" -> 
	  if !(Rep.multi_file) then (Rep.use_subdirs := true; Rep.use_full_paths := true);
    process base real_ext (((new Cilpatchrep.cilPatchRep) :> 'a Rep.representation))

  | "s" | "asm" ->
    process base real_ext 
    ((new Asmrep.asmRep) :> 'b Rep.representation)

  | "txt" | "string" ->
    process base real_ext 
    (((new Stringrep.stringRep) :> 'b Rep.representation))

  | "java" -> 
    process base real_ext 
    ((new Javarep.javaRep) :> 'c Rep.representation)

  | "" | "exe" | "elf" ->
      begin
        start_elf();
        process base real_ext 
          ((new Elfrep.elfRep) :> 'b Rep.representation);
        stop_elf();
      end

  | other -> begin 
    List.iter (fun (ext,myfun) ->
      if ext = other then myfun () 
    ) !Rep.global_filetypes ; 
    debug "%s: unknown file type to repair" !program_to_repair ;
    exit 1 
  end 
end ;;

try 
  main ()  
with 
  (* as per Mike's request, try to echo system errors to the debug file *) 
  | Unix.Unix_error(e,s1,s2) as exc -> begin 
    let msg = Unix.error_message e in 
    debug "%s aborting: Unix error: %S %S %S\n" 
      Sys.argv.(0) msg s1 s2 ;
    raise exc 
  end 
  | e -> begin 
    debug "%s aborting: %s\n" Sys.argv.(0) (Printexc.to_string e) ;
    raise e 
  end 
