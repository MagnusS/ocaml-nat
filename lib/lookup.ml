open Lwt

(* TODO: what are the actual data types on these?  no explicit
types in tcpip/lib/ipv4.ml, just matches on the number
straight from the struct, so we'll do that too although we
   should instead restrict to tcp or udp *) 

(* TODO: types should actually be more complex and allow for entries mapping
  networks and port ranges (with internal logic disallowing many:many mappings)
*)

type protocol = int
type port = int (* TODO: should probably formalize that this is uint16 *)
type state = 
  | Waiting of unit Lwt.t (* sleeper thread that, on wake, will remove this entry *)
  | Active (* currently, nothing will time this thread out *)

type xl_mode = 
  | OneToMany
  | OneToOne

type t = (protocol * (Ipaddr.t * port) * (Ipaddr.t * port), (Ipaddr.t * port) *
                                                            state) Hashtbl.t

let entry_timeout = (60.0 (* * 60.0 *)) (* timeout for connections in seconds *)

let string_of_t (table : t) =
  (* TODO: output state info *)
  let print_pair (addr, port) =
    Printf.sprintf "addr %s , port %d (%x) " (Ipaddr.to_string addr) port port
  in
  Hashtbl.fold (
    fun (proto, left, right) (answer, state) str -> 
      Printf.sprintf "%s proto %d (%x): %s, %s -> %s\n" str
        proto proto (print_pair left) (print_pair right) (print_pair answer)
  ) table ""

let update_timeout table proto left right translate new_timeout =
  let open Hashtbl in
  let internal_lookup = (proto, left, right) in
  let external_lookup = (proto, right, translate) in
  match (Hashtbl.mem table internal_lookup, Hashtbl.mem table external_lookup) with
  | true, true ->
    let (left_ip, left_timeout) = Hashtbl.find table (proto, left, right) in
    let (right_ip, right_timeout) = Hashtbl.find table (proto, right, translate) in
    (* cancel the timeout thread, so this connection won't be prematurely removed
    *)
    Lwt.cancel left_timeout;
    Lwt.cancel right_timeout; (* TODO: this will probably generate an exception *)
    Hashtbl.replace table (proto, left, right)  (translate, new_timeout);
    Hashtbl.replace table (proto, right, translate) (left, new_timeout);
    Some table
  | _, _ -> None

let lookup table proto left right =
  match Hashtbl.mem table (proto, left, right) with
  | false -> None
  | true -> 
    Some (fst (Hashtbl.find table (proto, left, right))) (* don't
                                                                   include state
of the connection in the response *)

(* cases that should result in a valid mapping: 
   neither side is already mapped
   both sides are already mapped to each other (currently this would be a noop,
but there may in the future be more state associated with these entries that
  then should be updated) *)
let insert ?(mode=OneToMany) table proto left right translate timeout =
  let open Hashtbl in
  let internal_lookup, external_lookup = 
    match mode with
    | OneToMany -> (proto, left, right), (proto, right, translate)
    | OneToOne -> (proto, translate, right), (proto, left, translate)
  in
  (* TODO: this is subject to race conditions *)
  (* needs Lwt.join *)
  match (mem table internal_lookup, mem table external_lookup, mode) with
  | false, false, OneToMany ->
    add table internal_lookup (translate, timeout);
    add table external_lookup (left, timeout);
    Some table
  | false, false, OneToOne ->
    add table internal_lookup (left, timeout);
    add table external_lookup (right, timeout);
    Some table
  | _, _, _ -> None (* there's already a table entry *)

let delete table proto (left_ip, left_port) (right_ip, right_port)
    (translate_ip, translate_port) =
  let internal_lookup = (proto, (left_ip, left_port), (right_ip, right_port)) in
  let external_lookup = (proto, (right_ip, right_port), (translate_ip,
                                                          translate_port)) in
  (* TODO: this is subject to race conditions *)
  (* needs Lwt.join *)
  (* TODO: under what circumstances does this return None? *)
  Hashtbl.remove table internal_lookup;
  Hashtbl.remove table external_lookup;
  Some table

(* TODO: if we do continue with this structure, this number should almost
  certainly be bigger *)
let empty () = Hashtbl.create 200
  
