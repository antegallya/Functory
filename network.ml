(**************************************************************************)
(*                                                                        *)
(*  Functory: a distributed computing library for Ocaml                   *)
(*  Copyright (C) 2010 Jean-Christophe Filliatre and Kalyan Krishnamani   *)
(*                                                                        *)
(*  This software is free software; you can redistribute it and/or        *)
(*  modify it under the terms of the GNU Library General Public           *)
(*  License version 2.1, with the special exception on linking            *)
(*  described in file LICENSE.                                            *)
(*                                                                        *)
(*  This software is distributed in the hope that it will be useful,      *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.                  *)
(*                                                                        *)
(**************************************************************************)

open Format
open Unix
open Control

(* let () = set_debug true *)

let default_port_number = ref 51000

let set_default_port_number p = default_port_number := p

let pong_timeout = ref 5.

let set_pong_timeout t = pong_timeout := t

let ping_interval = ref 10.

let set_ping_interval t = ping_interval := t

let is_worker = 
  try ignore (Sys.getenv "WORKER"); true with Not_found -> false 

let encode_string_pair (s1, s2) =
  let buf = Buffer.create 1024 in
  Binary.buf_string buf s1;
  Binary.buf_string buf s2;
  Buffer.contents buf
    
let decode_string_pair s =
  let s1, pos = Binary.get_string s 0 in 
  let s2, _ = Binary.get_string s pos in 
  s1, s2

module Worker = struct

  let computations : (string, (string -> string)) Hashtbl.t = Hashtbl.create 17

  let register_computation = Hashtbl.add computations
    
  let register_computation2 n f =
    register_computation n
      (fun s -> let x, y = decode_string_pair s in f x y)

  type running_task = {
    pid : int;
    file : file_descr;
  }

  open Protocol

  exception ExitOnStop of string

(*     if Hashtbl.mem computations f then begin *)
(* 	      let f = Hashtbl.find computations f in *)

  let server_fun compute cin cout =
    dprintf "new connection@.";
    let fdin = descr_of_in_channel cin in
    let fdout = descr_of_out_channel cout in
    let pids = Hashtbl.create 17 in (* ID -> running_task *)
    let handle_message_from_master _ = 
      let m = Master.receive fdin in
      dprintf "received: %a@." Master.print m;
      match m with
	| Master.Assign (id, f, a) ->
	    let fin, fout = pipe () in
	    begin match fork () with
	      | 0 -> 
		  begin try
		    (* FIXME: catch exceptions here *)
		    close fin;
		    (* perform computation *)
		    dprintf "  id %d: computation is running...@." id;
		    let r : string = compute f a in
		    let c = out_channel_of_descr fout in
		    output_value c r;
		    dprintf "  id %d: computation done@." id;
		    exit 0
		  with e ->
		    dprintf "cannot execute job %d (%s)@." 
		      id (Printexc.to_string e);
		    exit 1
		  end
	      | pid -> 
		  close fout;
		  let t = { pid = pid; file = fin } in
		  Hashtbl.add pids id t
	    end
	| Master.Kill id ->
	    begin 
	      try
		let t = Hashtbl.find pids id in
		kill t.pid Sys.sigkill;
		Hashtbl.remove pids id
	      with Not_found ->
		() (* ignored Kill *)
	    end
	| Master.Stop r ->
	    raise (ExitOnStop r)
	| Master.Ping ->
	    Worker.send fdout Worker.Pong
    in
    let wait_for_completed_task id t =
      match waitpid [WNOHANG] t.pid with
	| 0, _ -> (* not yet completed *)
	    ()
	| _, WEXITED 0 -> 
	    Hashtbl.remove pids id;
	    let c = in_channel_of_descr t.file in
	    let r : string = input_value c in
	    close_in c;
	    Worker.send fdout (Worker.Completed (id, r))
	| _ -> (* failure *)
	    Hashtbl.remove pids id;
	    Worker.send fdout (Worker.Aborted id)
    in
    try 
      while true do    
	let l,_,_ = select [fdin] [] [] 1. in
	List.iter handle_message_from_master l;
	Hashtbl.iter wait_for_completed_task pids
      done;
      assert false
    with 
      | End_of_file -> 
	  dprintf "master disconnected@."; 
	  Hashtbl.iter (fun _ t -> kill t.pid Sys.sigkill) pids;
	  exit 0 
      | ExitOnStop r ->
	  r
      | e -> 
	  let s = match e with
	    | Unix_error (e, f, x) -> 
		sprintf "%s (%s, %s)" (error_message e) f x
	    | e -> 
		Printexc.to_string e
	  in
	  eprintf "anomaly: %s@." s; 
	  exit 1

  (* sockets are allocated lazily; this table maps port numbers to sockets *)
  let sockets = Hashtbl.create 17

  let get_socket port =
    try
      Hashtbl.find sockets port
    with Not_found ->
      let sock = socket PF_INET SOCK_STREAM 0 in
      let sockaddr = Unix.ADDR_INET (inet_addr_any, port) in
      setsockopt sock SO_REUSEADDR true;
      setsockopt sock SO_KEEPALIVE true;
      bind sock sockaddr;
      listen sock 3;
      Hashtbl.add sockets port sock;
      sock

  let sockets_fd = Hashtbl.create 17

  let get_socket_fd port =
    let sock = get_socket port in
    try
      Hashtbl.find sockets_fd port
    with Not_found -> 
      let s,_ = Unix.accept sock in
      Hashtbl.add sockets_fd port s;
      s

  let compute compute ?(stop=false) ?(port = !default_port_number) () = 
    dprintf "port = %d@." port;
    if stop then begin
      let s = get_socket_fd port in
      let inchan = Unix.in_channel_of_descr s 
      and outchan = Unix.out_channel_of_descr s in 
      server_fun compute inchan outchan 
    end else begin
      let sock = get_socket port in
      while true do
	let s, _ = Unix.accept sock in 
	match Unix.fork() with
	  | 0 -> 
	      if Unix.fork() <> 0 then exit 0; 
              let inchan = Unix.in_channel_of_descr s 
              and outchan = Unix.out_channel_of_descr s in 
	      ignore (server_fun compute inchan outchan);
              close_in inchan;
              close_out outchan;
              exit 0
	  | id -> 
	      Unix.close s;
	      ignore (Unix.waitpid [] id)
      done;
      assert false
    end

end

(** Master *)

module IntSet = 
  Set.Make(struct type t = int let compare = Pervasives.compare end)

type worker_state =
  | Disconnected
  | Ok     of float (* time since last pong (or initial connection time) *)
  | Pinged of float (* last time we pinged *)
  | Error  of float (* last time we pinged *)

type worker = { 
  worker_id : int;
  sockaddr : sockaddr;
  mutable state : worker_state;
  mutable fdin : file_descr;
  mutable fdout : file_descr;
  ncores : int;
  mutable idle_cores : int;
  mutable jobs : IntSet.t;
}

type 'a task = {
  task : 'a;
  mutable task_done : bool;
  mutable task_workers : (int * worker) list; (* job id / worker *)
}

let print_task fmt t=
  fprintf fmt "@[done=%b, workers={" t.task_done;
  List.iter (fun (jid, w) -> fprintf fmt "%d (on worker %d), " jid w.worker_id)
    t.task_workers;
  fprintf fmt "}@]"

let print_sockaddr fmt = function
  | ADDR_UNIX s -> fprintf fmt "%s" s
  | ADDR_INET (ia, port) -> fprintf fmt "%s:%d" (string_of_inet_addr ia) port

let print_worker fmt w = 
  fprintf fmt "@[%d @[(%a,@ %d cores, %d idle cores, %d jobs)@]@]" 
    w.worker_id print_sockaddr w.sockaddr 
    w.ncores w.idle_cores (IntSet.cardinal w.jobs)

module WorkerSet : sig
  type t
  val create : unit -> t
  val add : t -> worker -> unit
  val mem : t -> worker -> bool
  val remove : t -> worker -> unit
  val is_empty : t -> bool
  val choose : t -> worker (* does not remove it *)
  val cardinal : t -> int
end = struct
  module S = 
    Set.Make(struct 
	       type t = worker 
	       let compare w1 w2 = Pervasives.compare w1.worker_id w2.worker_id
	     end)
  type t = S.t ref
  let create () = ref S.empty
  let add h w = h := S.add w !h
  let mem h w = S.mem w !h
  let remove h w = h := S.remove w !h
  let is_empty h = S.is_empty !h
  let choose h = assert (not (S.is_empty !h)); S.choose !h
  let cardinal h = S.cardinal !h
end

let workers = ref []

let () =
  at_exit 
    (fun () ->
       if not is_worker then
	 let shutdown_worker w = Unix.shutdown w.fdin Unix.SHUTDOWN_SEND in
	 List.iter 
	   (fun w -> if w.state <> Disconnected then shutdown_worker w)
	   !workers)

let create_sock_addr name port =
  let addr = 
    try  
      inet_addr_of_string name
    with Failure "inet_addr_of_string" -> 
      try 
	(gethostbyname name).h_addr_list.(0) 
      with Not_found ->
	eprintf "%s : Unknown server@." name ;
	exit 1
  in
  ADDR_INET (addr, port) 

let declare_workers =
  let r = ref 0 in
  fun ?(port = !default_port_number) ?(n=1) s ->
    incr r;
    let a = create_sock_addr s port in
    let w = { 
      worker_id = !r;
      sockaddr = a; 
      state = Disconnected;
      fdin = stdin; 
      fdout = stdout;
      ncores = n;
      idle_cores = n;
      jobs = IntSet.empty;
    } 
    in
    workers := w :: !workers

let worker_fd = Hashtbl.create 17

let connect_worker w =
  if w.state = Disconnected then begin
    let ic,oc = open_connection w.sockaddr in
    let fdin = descr_of_in_channel ic in
    let fdout = descr_of_out_channel oc in
    w.state <- Ok (Unix.time ());
    Hashtbl.remove worker_fd w.fdin;
    w.fdin <- fdin;
    Hashtbl.add worker_fd w.fdin w;
    w.fdout <- fdout;
  end

let create_task t =
  { task = t;
    task_done = false;
    task_workers = []; }

let job_id = let r = ref 0 in fun () -> incr r; !r

let main_master 
    ~(assign_job : 'a -> string * string)
    ~(master : 'a * 'c -> string -> ('a * 'c) list) 
    (tasks : ('a * 'c) list)
    =
  (* the tasks still to be done *)
  let todo = Queue.create () in
  let push_new_task t = Queue.add (create_task t) todo in
  List.iter push_new_task tasks;
  (* idle workers *)
  let idle_workers = WorkerSet.create () in
  List.iter 
    (fun w -> match w.state with
       | Ok _ | Pinged _ -> 
	   if w.idle_cores > 0 then WorkerSet.add idle_workers w
       | Disconnected | Error _ -> 
	   ())
    !workers;
  (* running tasks (job id -> task) *)
  let running_tasks = Hashtbl.create 17 in
  let send_ping w = 
    Protocol.Master.send w.fdout Protocol.Master.Ping;
  in
  let create_job w t =
    assert (not t.task_done);
    dprintf "@[<hov 2>create_job: worker=%a,@ task=%a@]@." 
      print_worker w print_task t;
    connect_worker w;
    let id = job_id () in
    let f, a = assign_job (fst t.task) in
    Protocol.Master.send w.fdout (Protocol.Master.Assign (id, f, a));
    send_ping w;
    w.state <- Pinged (Unix.time ());
    t.task_workers <- (id, w)  :: t.task_workers;
    Hashtbl.replace running_tasks id t;
    w.jobs <- IntSet.add id w.jobs;
    assert (w.idle_cores > 0);
    w.idle_cores <- w.idle_cores - 1;
    if w.idle_cores = 0 then WorkerSet.remove idle_workers w
  in
  let reschedule_tasks ~remove w = 
    IntSet.iter 
      (fun jid -> 
	 assert (Hashtbl.mem running_tasks jid);
	 let t = Hashtbl.find running_tasks jid in
	 if remove then begin
	   Hashtbl.remove running_tasks jid;
	   t.task_workers <- List.filter (fun (_,w') -> w' != w) t.task_workers
	 end;
	 Queue.add t todo)
      w.jobs
  in
  let manage_disconnection w =
    w.state <- Disconnected;
    WorkerSet.remove idle_workers w;
    reschedule_tasks ~remove:true w
  in
  let increase_idle_cores w =
    w.idle_cores <- w.idle_cores + 1;
    if w.idle_cores > 0 then WorkerSet.add idle_workers w
  in
  (* kill job jid on worker w *)
  let kill w jid =
    dprintf "kill job id %d on worker %d@." jid w.worker_id;
    Hashtbl.remove running_tasks jid;
    if w.state <> Disconnected then begin
      Protocol.Master.send w.fdout (Protocol.Master.Kill jid);
      w.jobs <- IntSet.remove jid w.jobs;
      increase_idle_cores w
    end
  in
  (* kill jobs different from jid *)
  let kill_jobs jid l =
    List.iter (fun (jid', w) -> if jid' <> jid then kill w jid') l
  in
  let listen_for_worker w =
    let m = Protocol.Worker.receive w.fdin in
    dprintf "received from %a: %a@." print_worker w Protocol.Worker.print m;
    w.state <- Ok (Unix.time ());
    match m with
      | Protocol.Worker.Pong ->
	  if w.idle_cores > 0 then WorkerSet.add idle_workers w
      | Protocol.Worker.Completed (id, r) ->
	  increase_idle_cores w;
	  let t = Hashtbl.find running_tasks id in
	  dprintf "completed task: job id=%d, %a@." id print_task t;
	  Hashtbl.remove running_tasks id;
	  w.jobs <- IntSet.remove id w.jobs;
	  if not t.task_done then begin
	    t.task_done <- true;
	    kill_jobs id t.task_workers;
	    List.iter push_new_task (master t.task r)
	  end 
      | Protocol.Worker.Aborted id ->
	  increase_idle_cores w;
	  let t = Hashtbl.find running_tasks id in
	  Hashtbl.remove running_tasks id;
	  w.jobs <- IntSet.remove id w.jobs;
	  push_new_task t.task
  in
  let last_printed_state = ref (0,0,0) in
  let print_state () =
    let n1 = Queue.length todo in
    let n2 = WorkerSet.cardinal idle_workers in
    let n3 = Hashtbl.length running_tasks in
    let st = (n1, n2, n3) in 
    if st <> !last_printed_state then begin
      last_printed_state := st;
      dprintf "***@.";
      dprintf "  %d tasks todo@." n1;
      dprintf "  %d idle workers@." n2;
      dprintf "  %d running tasks (" n3;
      Hashtbl.iter (fun jid _ -> dprintf "%d, " jid) running_tasks;
      dprintf ")@.";
      dprintf "***@.";
    end
  in
  (* main loop *)
  while not (Queue.is_empty todo) || (Hashtbl.length running_tasks > 0) do

    print_state ();

    (* 1. try to connect if not already connected *)
    let current = Unix.time () in
    List.iter 
      (fun w -> match w.state with
	 | Disconnected ->
	     begin try 
	       connect_worker w;
	       dprintf "new connection to %a@." print_worker w;
	       WorkerSet.add idle_workers w;
	       w.idle_cores <- w.ncores; (* we assume all cores are back *)
	       w.jobs <- IntSet.empty;
	     with e ->
	       ()
	     end
	 | Pinged t ->
	     if current > t +. !pong_timeout then begin
	       dprintf "worker %a timed out@." print_worker w;
	       w.state <- Error current;
	       WorkerSet.remove idle_workers w;
	       reschedule_tasks ~remove:false w
	     end
	 | Ok t when current > t +. !ping_interval ->
	     send_ping w;
	     w.state <- Pinged current
	 | Error t when current > t +. !ping_interval ->
	     send_ping w;
	     w.state <- Error current
	 | Ok _ | Error _ ->
	     ())
      !workers;

    print_state ();

    (* 2. if possible, start new jobs *)
    while not (WorkerSet.is_empty idle_workers) && not (Queue.is_empty todo) do
      let t = Queue.pop todo in
      if not t.task_done then
	let w = WorkerSet.choose idle_workers in
	create_job w t
    done;

    print_state ();

    (* 3. if not, listen for workers *)
    let fds = 
      let wl = List.filter (fun w -> w.state <> Disconnected) !workers in
      List.map (fun w -> w.fdin) wl
    in
    let l,_,_ = select fds [] [] 0.1 in
    List.iter 
      (fun fd -> 
	 let w = Hashtbl.find worker_fd fd in
	 try  listen_for_worker w
	 with End_of_file -> manage_disconnection w)
      l;

  done;
  assert (Queue.is_empty todo && Hashtbl.length running_tasks = 0);
  ()

type worker_type = ?stop:bool -> ?port:int -> unit -> unit

module Mono = struct

  module Master = struct

    let compute ~master tl =
      main_master ~assign_job:(fun x -> "f", x) ~master tl
	
  end

  module Worker = struct
    let compute f ?stop ?port () = 
      ignore (Worker.compute (fun _ x -> f x) ?stop ?port ())
  end

end

module Poly = struct

  module Master = struct

    let compute ~master tl =
      main_master 
	~assign_job:(fun x -> "f", Marshal.to_string x []) 
	~master:(fun t s -> let r = Marshal.from_string s 0 in master t r)
	tl
	
    include Map_fold.Make
	(struct
	   let compute ~worker = compute
	 end)
    let map l = 
      map ~f:(fun _ -> assert false) l
    let map_local_fold ~fold acc l = 
      map_local_fold
	~map:(fun _ -> assert false) ~fold acc l
    let map_remote_fold acc l = 
      map_remote_fold
	~map:(fun _ -> assert false) ~fold:(fun _ _ -> assert false) acc l
    let map_fold_ac acc l = 
      map_fold_ac
	~map:(fun _ -> assert false) ~fold:(fun _ _ -> assert false) acc l
    let map_fold_a acc l = 
      map_fold_a
	~map:(fun _ -> assert false) ~fold:(fun _ _ -> assert false) acc l

  end

  module Worker = struct
    let unpoly f s = 
      let x = Marshal.from_string s 0 in
      let r = f x in
      Marshal.to_string r []

    let compute f ?stop ?port () = 
      ignore (Worker.compute (fun _ -> unpoly f) ?stop ?port ())

    let map ~f = 
      compute f
    let map_local_fold ~map = 
      compute map
    let map_remote_fold ~map ~fold = 
      compute (Map_fold.map_fold_wrapper map fold)
    let map_fold_ac ~map ~fold = 
      compute (Map_fold.map_fold_wrapper2 map fold)
    let map_fold_a ~map ~fold = 
      compute (Map_fold.map_fold_wrapper2 map fold)
  end

end

module Same = struct

  module Worker = struct 

    let compute ?stop ?port () =
      let compute f x = 
	let f = (Marshal.from_string f 0 : 'a -> 'b) in
	let x = (Marshal.from_string x 0 : 'a) in
	Marshal.to_string (f x) []
      in
      ignore (Worker.compute compute ?stop ?port ())

  end

  let () = 
    if is_worker then begin
      dprintf "starting worker loop...@.";
      Worker.compute ~stop:false ()
    end
      
  let compute
      ~(worker : 'a -> 'b) 
      ~(master : 'a * 'c -> 'b -> ('a * 'c) list) 
      tasks
  =
    let worker_closure = Marshal.to_string worker [Marshal.Closures] in
    let assign_job x = worker_closure, Marshal.to_string x [] in
    let master ac r = master ac (Marshal.from_string r 0) in
    main_master ~assign_job ~master tasks
      
  include Map_fold.Make(struct let compute = compute end)

 end

(*******

type 'a marshaller = {
  marshal_to : 'a -> string;
  marshal_from : string -> 'a;
}

let poly_marshaller = {
  marshal_to = (fun x -> Marshal.to_string x []);
  marshal_from = (fun s -> Marshal.from_string s 0);
}

let run_worker mres =
  let r = Worker.compute ~stop:true () in
  dprintf "worker: result is %S@." r;
  mres.marshal_from r

(* marshal and send result to all workers *)
let send_result mres r =
  let res = mres.marshal_to r in
  List.iter
    (fun w -> Protocol.Master.send w.fdout (Protocol.Master.Stop res))
    !workers;
  r

let marshal_wrapper ma mb f s =
  let x : 'a = ma.marshal_from s in
  mb.marshal_to (f x)

let marshal_wrapper2 ma mb mc f s1 s2 =
  let x : 'a = ma.marshal_from s1 in
  let y : 'b = mb.marshal_from s2 in
  mc.marshal_to (f x y)

(** Polymorphic functions. *)

let generic_map
  (ma : 'a marshaller) (mb : 'b marshaller) (mres : 'b list marshaller)
  ~(f : 'a -> 'b) (l : 'a list) : 'b list 
=
  if is_worker then begin
    Worker.register_computation "f" (marshal_wrapper ma mb f);
    (run_worker mres : 'b list)
  end else begin
    let tasks = 
      let i = ref 0 in 
      List.map (fun x -> incr i; !i, "f", ma.marshal_to x) l 
    in
    let results = Hashtbl.create 17 in (* index -> 'b *)
    master 
      ~handle:(fun (i,_,_) r -> 
		 let r = mb.marshal_from r in Hashtbl.add results i r; [])
      tasks;
    let r = List.map (fun (i,_,_) -> Hashtbl.find results i) tasks in
    send_result mres r
  end

let map ~f l = generic_map poly_marshaller poly_marshaller poly_marshaller ~f l

let generic_map_local_fold 
  (ma : 'a marshaller) (mb : 'b marshaller) (mc : 'c marshaller)
  ~(map : 'a -> 'b) ~(fold : 'c -> 'b -> 'c) acc l 
=
  if is_worker then begin
    Worker.register_computation "map" (marshal_wrapper ma mb map);
    (run_worker mc : 'c)
  end else begin
    let acc = ref acc in
    master 
      ~handle:(fun _ r -> 
		 let r = mb.marshal_from r in acc := fold !acc r; [])
      (List.map (fun x -> (), "map", ma.marshal_to x) l);
    send_result mc !acc 
  end

let map_local_fold ~map ~fold acc l = 
  generic_map_local_fold poly_marshaller poly_marshaller poly_marshaller 
    ~map ~fold acc l

let uncurry f (x,y) = f x y

let generic_map_remote_fold 
  (ma : 'a marshaller) (mb : 'b marshaller) (mc : 'c marshaller)
  ~(map : 'a -> 'b) ~(fold : 'c -> 'b -> 'c) acc l 
=
  if is_worker then begin
    Worker.register_computation "map" (marshal_wrapper ma mb map);
    Worker.register_computation2 "fold" (marshal_wrapper2 mc mb mc fold);
    (run_worker mc : 'c)
  end else begin
    let acc = ref (Some (mc.marshal_to acc)) in
    let pending = Stack.create () in
    master 
      ~handle:(fun x r -> match x with
		 | _,"map",_ -> begin match !acc with
		     | None -> Stack.push r pending; []
		     | Some v -> 
			 acc := None; 
			 [(), "fold", encode_string_pair (v, r)]
		   end
		 | _,"fold",_ -> 
		     assert (!acc = None);
		     if not (Stack.is_empty pending) then
		       [(), "fold", 
			encode_string_pair (r, Stack.pop pending)]
		     else begin
		       acc := Some r;
		       []
		     end
		 | _ -> 
		     assert false)
      (List.map (fun x -> (), "map", ma.marshal_to x) l);
    (* we are done; the accumulator must exist *)
    match !acc with
      | Some r -> send_result mc (mc.marshal_from r)
      | None -> assert false
  end

let map_remote_fold ~map ~fold acc l = 
  generic_map_remote_fold poly_marshaller poly_marshaller poly_marshaller 
    ~map ~fold acc l

let generic_map_fold_ac 
  (ma : 'a marshaller) (mb : 'b marshaller)
  ~(map : 'a -> 'b) ~(fold : 'b -> 'b -> 'b) acc l 
=
  if is_worker then begin
    Worker.register_computation "map" (marshal_wrapper ma mb map);
    Worker.register_computation2 "fold" (marshal_wrapper2 mb mb mb fold);
    (run_worker mb : 'b)
  end else begin
    let acc = ref (Some (mb.marshal_to acc)) in
    master 
      ~handle:(fun x r -> 
		 match !acc with
		 | None -> 
		     acc := Some r; []
		 | Some v -> 
		     acc := None; 
		     [(), "fold", encode_string_pair (v, r)])
      (List.map (fun x -> (), "map", ma.marshal_to x) l);
    (* we are done; the accumulator must exist *)
    match !acc with
      | Some r -> send_result mb (mb.marshal_from r)
      | None -> assert false
  end

let map_fold_ac ~map ~fold acc l = 
  generic_map_fold_ac poly_marshaller poly_marshaller 
    ~map ~fold acc l

let generic_map_fold_a 
  (ma : 'a marshaller) (mb : 'b marshaller)
  ~(map : 'a -> 'b) ~(fold : 'b -> 'b -> 'b) acc l 
=
  if is_worker then begin
    Worker.register_computation "map" (marshal_wrapper ma mb map);
    Worker.register_computation2 "fold" (marshal_wrapper2 mb mb mb fold);
    (run_worker mb : 'b)
  end else begin
    let tasks = 
      let i = ref 0 in 
      List.map (fun x -> incr i; (!i, !i), "map", ma.marshal_to x) l 
    in
    (* results maps i and j to (i,j,r) for each completed reduction of
       the interval i..j with result r *)
    let results = Hashtbl.create 17 in 
    let merge i j r = 
      if Hashtbl.mem results (i-1) then begin
	let l, h, x = Hashtbl.find results (i-1) in
	assert (h = i-1);
	Hashtbl.remove results l; 
	Hashtbl.remove results h;
	[(l, j), "fold", encode_string_pair (x, r)]
      end else if Hashtbl.mem results (j+1) then begin
	let l, h, x = Hashtbl.find results (j+1) in
	assert (l = j+1);
	Hashtbl.remove results h; 
	Hashtbl.remove results l;
	[(i, h), "fold", encode_string_pair (r, x)]
      end else begin
	Hashtbl.add results i (i,j,r);
	Hashtbl.add results j (i,j,r);
	[]
      end
    in
    master 
      ~handle:(fun x r -> match x with
		 | (i, _), "map", _ -> merge i i r
		 | (i, j), "fold", _ -> merge i j r
		 | _ -> assert false)
      tasks;
    (* we are done; results must contain 2 mappings only, for 1 and n *)
    let res = 
      try let _,_,r = Hashtbl.find results 1 in mb.marshal_from r 
      with Not_found -> acc
    in
    send_result mb res
  end

let map_fold_a ~map ~fold acc l = 
  generic_map_fold_a poly_marshaller poly_marshaller 
    ~map ~fold acc l

(** Monomorphic functions. *)

let id_marshaller = {
  marshal_to = (fun x -> x);
  marshal_from = (fun x -> x);
}

module Str = struct

  let encode_string_list l =
    let buf = Buffer.create 1024 in
    Binary.buf_string_list buf l;
    Buffer.contents buf

  let decode_string_list s =
    let l, _ = Binary.get_string_list s 0 in 
    l

  let string_list_marshaller = {
    marshal_to = encode_string_list;
    marshal_from = decode_string_list;
  }

  let map ~f l = 
    generic_map id_marshaller id_marshaller string_list_marshaller ~f l

  let encode_string s =
    let buf = Buffer.create 1024 in
    Binary.buf_string buf s;
    Buffer.contents buf

  let decode_string s =
    let s, _ = Binary.get_string s 0 in 
    s

  let string_marshaller = {
    marshal_to = encode_string;
    marshal_from = decode_string;
  }

  let map_local_fold ~map ~fold acc l =
    generic_map_local_fold id_marshaller id_marshaller string_marshaller
      ~map ~fold acc l

  let map_remote_fold ~map ~fold acc l =
    generic_map_remote_fold 
      string_marshaller string_marshaller string_marshaller
      ~map ~fold acc l

  let map_fold_ac ~map ~fold acc l =
    generic_map_fold_ac
      string_marshaller string_marshaller
      ~map ~fold acc l

  let map_fold_a ~map ~fold acc l =
    generic_map_fold_a string_marshaller string_marshaller
      ~map ~fold acc l

end

(** Master *)

module Master = struct

  let map (l : string list) : string list =
    let tasks = let i = ref 0 in List.map (fun x -> incr i; !i, "f", x) l in
    let results = Hashtbl.create 17 in (* index -> 'b *)
    master 
      ~handle:(fun (i,_,_) r -> Hashtbl.add results i r; [])
      tasks;
    List.map (fun (i,_,_) -> Hashtbl.find results i) tasks

  let map_local_fold ~(fold : 'c -> 'b -> 'c) acc l =
    let acc = ref acc in
    master 
      ~handle:(fun _ r -> acc := fold !acc r; [])
      (List.map (fun x -> (), "map", x) l);
    !acc 

  let map_remote_fold acc l =
    let acc = ref (Some acc) in
    let pending = Stack.create () in
    master 
      ~handle:(fun (_,f,_) r -> match f with
		 | "map" -> begin match !acc with
		     | None -> Stack.push r pending; []
		     | Some v -> 
			 acc := None; 
			 [(), "fold", encode_string_pair (v, r)]
		   end
		 | "fold" -> begin match !acc with
		     | None -> 
			 if not (Stack.is_empty pending) then
			   [(), "fold", 
			    encode_string_pair (r, Stack.pop pending)]
			 else begin
			   acc := Some r;
			   []
			 end
		     | Some _ -> 
			 assert false
		   end
		 | _ ->
		     assert false)
      (List.map (fun x -> (), "map", x) l);
    (* we are done; the accumulator must exist *)
    match !acc with
      | Some r -> r
      | None -> assert false

  let map_fold_ac acc l =
    let acc = ref (Some acc) in
    master 
      ~handle:(fun _ r -> match !acc with
		 | None -> 
		     acc := Some r; []
		 | Some v -> 
		     acc := None; 
		     [(), "fold", encode_string_pair (v, r)])
      (List.map (fun x -> (), "map", x) l);
    (* we are done; the accumulator must exist *)
    match !acc with
      | Some r -> r
      | None -> assert false

  let map_fold_a acc l =
    let tasks = let i = ref 0 in List.map (fun x -> incr i; !i,x) l in
    (* results maps i and j to (i,j,r) for each completed reduction of
       the interval i..j with result r *)
    let results = Hashtbl.create 17 in 
    let merge i j r = 
      if Hashtbl.mem results (i-1) then begin
	let l, h, x = Hashtbl.find results (i-1) in
	assert (h = i-1);
	Hashtbl.remove results l; 
	Hashtbl.remove results h;
	[(l, i), "fold", encode_string_pair (x, r)]
      end else if Hashtbl.mem results (j+1) then begin
	let l, h, x = Hashtbl.find results (j+1) in
	assert (l = j+1);
	Hashtbl.remove results h; 
	Hashtbl.remove results l;
	[(i, h), "fold", encode_string_pair (r, x)]
      end else begin
	Hashtbl.add results i (i,j,r);
	Hashtbl.add results j (i,j,r);
	[]
      end
    in
    master 
      ~handle:(fun x r -> match x with
		 | (i, _), "map", _ -> merge i i r
		 | (i, j), "fold", _ -> merge i j r
		 | _ -> assert false)
      (List.map (fun (i,x) -> (i,i), "map", x) tasks);
    (* we are done; results must contain 2 mappings only, for 1 and n *)
  try let _,_,r = Hashtbl.find results 1 in r with Not_found -> acc

end

*********)