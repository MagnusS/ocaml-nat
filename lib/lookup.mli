type protocol = int
type port = int
type t 
type state = (* logic for timing out table entries *)
  | Waiting of unit Lwt.t (* sleeper thread that, on wake, will remove this entry *)
  | Active (* currently, nothing will time this thread out *)

(* TODO: I'm not in love with these names. *)
type xl_mode = 
  | OneToMany
  | OneToOne

(* also should track some subset of tcp/udp state -- timer thread for UDP,
  state/timer for TCP (since we can't be sure everything *we* see is seen by the
   remote end) *)

(* state unfortunately is per bidirectional entry (or to put it differently, per
connection).  adding this exacerbates the "two things representing one
  underlying idea" problem, since we don't really want to time out two sides of
the thing separately (or worse, time out one side then get a packet renewing the
connection before we clear the other side). *)

val lookup : t -> protocol -> (Ipaddr.t * port) -> (Ipaddr.t * port) -> (Ipaddr.t * port) option

val insert : ?mode:xl_mode -> t -> 
  protocol -> (Ipaddr.t * port) -> (Ipaddr.t * port) -> (Ipaddr.t * port) 
  -> state -> t option

val delete : t -> protocol -> (Ipaddr.t * port) -> (Ipaddr.t * port) -> (Ipaddr.t * port ) ->
  t option

val string_of_t : t -> string

val empty : unit -> t
