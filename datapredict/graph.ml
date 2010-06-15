open List
open String
open Hashtbl
open Cil
open Globals
open Invariant
open State

module type Graph =
sig

  type transitionsT
  type stateT 
  type t

  val build_graph : (string * string) list -> t
  val new_graph : unit -> t

  val states : t -> stateT list

  val start_state : t -> stateT

  val add_state : t -> stateT -> t
  val add_transition : t -> stateT -> stateT -> int -> t
    
  val next_state : t -> int -> int -> Globals.IntSet.t
    (* next_state takes a state and a run number and returns the new state that
       that run moves to from the passed in state *)
  val next_states : t -> int -> stateT list
    (* next_states returns a list of all states reachable by all runs
       from the given state. Good for building *)

  val states_where_true : t -> predicate -> stateT list 

  val get_end_states : t -> predicate -> stateT list
  val get_seqs : t -> stateT list -> stateSeq list list
  val split_seqs : t -> stateSeq list -> stateT -> predicate -> stateSeq list * stateSeq list

  val print_graph : t -> unit
   
end

module Graph =
  functor (S : State ) ->
struct 

  (* do we need to define these exceptions in the signature? *)
  exception EmptyGraph

  type stateT = S.t
  
  module StateSet = Set.Make(struct 
			       type t = S.t
			       let compare = S.compare
			     end)

  (* state id -> run -> state id *)
  type transitionsT = (int, (int, IntSet.t) Hashtbl.t) Hashtbl.t 

  type t = {
    states : StateSet.t ;
    forward_transitions : transitionsT ;
    backward_transitions : transitionsT ;
    start_state : stateT;
    pass_final_state : stateT;
    fail_final_state : stateT;
  }
  let site_to_state : (int, S.t) Hashtbl.t = Hashtbl.create 100

  let new_graph () = 
    let start_state = S.new_state (-1) in
    let pass_final_state = S.final_state true in
    let fail_final_state = S.final_state false in 
    let initial_set = 
      let add = StateSet.add in
	(add start_state (add pass_final_state (add fail_final_state
						  StateSet.empty)))
    in
    let states = 
      StateSet.fold
	(fun state ->
	   fun set ->
	     Hashtbl.add site_to_state (S.state_id state) state;
	     StateSet.add state set) StateSet.empty
	initial_set
    in
    { states = states;
      forward_transitions = Hashtbl.create 100;
      backward_transitions = Hashtbl.create 100;
      (* fixme: add start state to hashtable *)
      start_state = start_state;
      pass_final_state = pass_final_state;
      fail_final_state = fail_final_state;
    }

  let states graph = StateSet.elements graph.states
  let start_state graph = graph.start_state

  let final_state graph gorb = 
    if ((get (capitalize gorb) 0) == 'P') 
    then graph.pass_final_state 
    else graph.fail_final_state

(* add_state both adds and replaces states; there will never be duplicates
   because it's a set *)
  let add_state graph state = 
    let states = 
      if StateSet.mem state graph.states then
	StateSet.remove state graph.states
      else graph.states
    in
      {graph with states = StateSet.add state states }

  (* only add a transition once *)
  let add_transition graph (previous : S.t) (next : S.t) run = 
    let inner_trans ht from to2 =
      let innerT = 
	ht_find ht (S.state_id from) (fun x -> Hashtbl.create 100) 
      in
      let destset = 
	let d = 
	try Hashtbl.find innerT run 
	with _ -> IntSet.empty
	in IntSet.add (S.state_id to2) d
      in
	Hashtbl.replace innerT run destset;
	Hashtbl.replace ht (S.state_id from) innerT
    in
      inner_trans graph.forward_transitions previous next;
      inner_trans graph.backward_transitions next previous;
      graph

  let get_trans state trans = 
    let innerT : (int, Globals.IntSet.t) Hashtbl.t = 
      ht_find trans state (fun x -> Hashtbl.create 100) in
      Hashtbl.fold
	(fun (run : int) ->
	   fun (runs_dests : Globals.IntSet.t) ->
	     fun (all_dests : StateSet.t) ->
	       IntSet.fold
		 (fun (dest : int)  ->
		    fun (all_dests : StateSet.t) ->
		      StateSet.add
			(Hashtbl.find site_to_state dest) all_dests)
		 runs_dests all_dests)
	innerT StateSet.empty

  let next_states graph state = 
    StateSet.elements (get_trans state graph.forward_transitions)

  let previous_states graph state = get_trans state graph.backward_transitions
		
(* this throws a Not_found if there is no next state for the given state on the
   given run. This is officially Your Problem *)
  let next_state graph state run =
    let nexts = Hashtbl.find graph.forward_transitions state in
      Hashtbl.find nexts run
	
  let states_where_true graph pred = 
    StateSet.elements (StateSet.filter (fun s -> S.is_true s pred) graph.states)
    
  (* between here and "build_graph" are utility functions *)
  let get_and_split_line fin =
    let split = Str.split comma_regexp (input_line fin) in
    let site_num,info = int_of_string (hd split), tl split in
    let (loc,typ,stmt_id,exp) as site_info = Hashtbl.find !site_ht site_num in
      (site_num,info,site_info)
	
  let run_num = ref 0

  let get_run_number fname gorb = begin
    let good = if (get (capitalize gorb) 0) == 'P' then 0 else 1 in 
      if not (Hashtbl.mem !fname_to_run_num fname) then begin
	(add !fname_to_run_num fname !run_num);
	(add !run_num_to_fname_and_good !run_num (fname, good));
	incr run_num
      end;
      Hashtbl.find !fname_to_run_num fname
  end

  let get_name_mval dyn_data = (hd dyn_data), (mval_of_string (hd (tl dyn_data)))
	
  exception EndOfFile of stateT
  exception NewSite of stateT * int* (location * string * int * exp)
    * string list
	
  (* handling this with exceptions is kind of ghetto of me but whatever it
     works *) 
    
  let fold_a_graph graph (fname, gorb) = 
    let fin = open_in fname in 
    let run = get_run_number fname gorb in
      
    let rec add_states graph previous =

      let rec add_sp_site graph previous site_num site_info dyn_data = 
	(* name of the variable being assigned to, and its value *)
	let lname,lval = get_name_mval dyn_data in

	(* every site gets its own state, I think *)
	(* thought: how to deal with visits by a run to a site with different values for
	   the stuff tracked at the site? *)
	let state =
	  try Hashtbl.find site_to_state site_num 
	  with Not_found -> begin
	    let new_state = S.add_run (S.new_state site_num) run in
	      Hashtbl.add site_to_state site_num new_state;
	      new_state
	  end
	in

	let rec inner_site state = 
	  let finalize () =
	    let graph' = add_state graph state in
	    let graph'' = add_transition graph' previous state run in 
	      graph'',state
	  in

	    (* CHECK: I think "dyn_data" is the same as "rest" in the original
	       code *)
	    try
	      let (site_num',dyn_data',site_info') = get_and_split_line fin in

		if not (site_num == site_num') then begin
		  let graph',state' = finalize() in
		  let add_func = get_func site_info' in
		    add_func graph' state' site_num' site_info' dyn_data'
		end


		else begin (* same site, so continue adding to this state memory *)
		  let rname,rval = get_name_mval dyn_data' in
		  let state' = S.add_to_memory state run rname rval in
		    
		  (* add predicates to state *)
		  let actual_op = 
		    if lval > rval then Gt else if lval < rval then Lt else Eq in
		    
		  let comp_exps = 
		    List.map 
		      (fun op -> 
			 let value = op == actual_op in
			 let comp_exp =
			   BinOp(op, (Const(CStr(lname))), (Const(CStr(rname))),
				 (TInt(IInt,[]))) in
			   (comp_exp, value)) [Gt;Lt;Eq] 
		      (*		 let exp_str = Pretty.sprint 80 (d_exp () comp_exp) in
					 let loc_str = Pretty.sprint 80 (d_loc () loc) in
					 ("scalar-pairs"^exp_str^loc_str),value)*)
		      (* FIXME: this was once strings, now we want exps; do I want a string producing
			 something somewhere? *)
		  in
		  let state'' = 
		    List.fold_left
		      (fun state ->
			 (fun (pred_exp,value) -> 
			    S.add_predicate state run pred_exp value))
		      state' comp_exps
		  in 
		    inner_site state''
		end
	    with End_of_file -> finalize()
	in
	  inner_site state 

      (* this is going to be slightly tricky because we want to guard
	 states internal to an if statement/conditional, which is hard to
	 tell b/c we get the value of the conditional b/f we enter it. *)

      and add_cf_site graph previous site_num (loc,typ,stmt_id,exp) dyn_data =
	let value = int_of_string (List.hd dyn_data) in 
	let state =
	  try Hashtbl.find site_to_state site_num 
	  with Not_found -> begin
	    let new_state = S.add_run (S.new_state site_num) run in
	      Hashtbl.add site_to_state site_num new_state;
	      new_state
	  end
	in
	let torf = not (value == 0) in
	let state' = S.add_predicate state run exp torf in 
	let graph' = add_transition graph previous state run in
	let graph'' = add_state graph' state' in
	  graph'', state'

      and get_func (loc,typ,stmt_id,exp) = 
	if typ = "scalar-pairs" 
	then add_sp_site 
	else add_cf_site
      in


	try 
	  let site_num,dyn_data,site_info = get_and_split_line fin in 
	  let add_func = get_func site_info in
	  let graph',previous' = add_func graph previous site_num site_info dyn_data in
	    add_states graph' previous' 
	with End_of_file -> 
	  begin
	    close_in fin;
	    let graph' = 
	      add_transition graph previous (final_state graph gorb) run in
	      graph', previous
	  end
    in 
    let graph',previous' = add_states graph (start_state graph)  in
      graph'

  let build_graph (filenames : (string * string) list) : t = 
    fold_left fold_a_graph (new_graph ()) filenames


  (* the following methods encompass various ways to get subsets of graph
   * states/runs *)

  let get_end_states graph inv = 
    match inv with
      RunFailed -> [graph.pass_final_state;graph.fail_final_state]
    | RunSucceeded -> [graph.fail_final_state;graph.pass_final_state]
    | _ -> failwith "Not implemented" 

  (* get seqs returns sequences of states that lead to the end states in the
     passed-in set *)

  let get_seqs graph states = 
    (* OK. Runs contain each state at most once, no matter how many times this run
     * visited it. 
     * And, for now, stateSeqs only start at the start state. The definition is
     * more general than this in case I change my mind later, like for
     * "windows" *)
    (* one run returns a list of runs, since loops can make one state come
       from more than one other possible state *)
    let rec one_run (s_id : int) (run : int) (seq : IntSet.t) 
	: (Globals.IntSet.elt * int * Globals.IntSet.t) list = 
      if s_id == (-1) then [(s_id,run,(IntSet.add s_id seq))]
      else 
	begin
	  let state_ht = Hashtbl.find graph.backward_transitions s_id
	  in
	  let prevs = IntSet.elements (Hashtbl.find state_ht run) in
	  let seq' = IntSet.add s_id seq in 
	    flatten (map (fun prev -> one_run prev run seq') prevs)
	end
    in
    let one_state state = 
      let state_runs = S.runs state in
      let s_id = S.state_id state in
	flatten (map (fun run -> one_run s_id run (IntSet.empty)) state_runs)
    in
      map one_state states

  (* split_seqs takes a set of sequences and a state and splits them into the
     runs on which the predicate was ever observed to be true and the runs on
     which the predicate was ever observed to be false. These sets can overlap *)
  let split_seqs graph seqs state pred = 
    (* fixme: throw an exception if this state isn't in this sequence? No, that
       makes no sense. Hm. *)
    let eval = 
      map (fun (run,start,set) -> 
	     (run,start,set), 
	     (S.overall_pred_on_run state run pred)) 
	seqs in
      fold_left
	(fun (ever_true,ever_false) ->
	   (fun (seq, (num_true, num_false)) ->
	      if num_true > 0 then
		if num_false > 0 then
		  (seq :: ever_true, seq :: ever_false)
		else
		  (seq :: ever_true, ever_false)
	      else
		if num_false > 0 then
		  (ever_true, seq :: ever_false) 
		else
		  (ever_true, ever_false)
	   )) ([],[]) eval
	
  let print_graph graph =
    pprintf "Graph has %d states\n" (StateSet.cardinal graph.states);
    pprintf "Graph has %d forward transitions.\n" (Hashtbl.length graph.forward_transitions);
    pprintf "Graph has %d backward transitions.\n" (Hashtbl.length graph.backward_transitions);
    pprintf "Pass final state id: %d\n" (S.state_id graph.pass_final_state);
    pprintf "Fail final state id: %d\n" (S.state_id graph.fail_final_state);
    liter 
      (fun (prnt,hash) ->
	 prnt();
	 hiter 
	   (fun source ->
	      fun innerT ->
		pprintf "  transitions for state %d:\n" source;
		hiter
		  (fun run ->
		     fun destset ->
		       liter 
			 (fun dest ->
			    pprintf "     run %d goes to state %d\n" run dest
			 ) (IntSet.elements destset)
		  ) innerT
	   ) hash)
      [((fun x -> pprintf "FORWARD \n"; flush stdout), graph.forward_transitions);
       ((fun x -> pprintf "BACKWARD \n"; flush stdout), graph.backward_transitions)];
    flush stdout;
end

module DynamicExecGraph = Graph(DynamicState)
