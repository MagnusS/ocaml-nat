(* should the source IP and port be overwritten, 
   or the destination IP and port?  *)
type direction = Source | Destination 

type insert_result = 
  | Ok of Lookup.t
  | Overlap
  | Unparseable

(** given a lookup table, rewrite direction, and an ip-level frame, 
  * perform any translation indicated by presence in the table
  * on the Cstruct.t .  If the packet should be forwarded, return Some packet,
  * else return None.  (TODO: this doesn't really make sense in the context of a
  * library function; separate out this logic.) 
  * This function is zero-copy and mutates values in the given Cstruct.  
  * if mode is OnetoMany, just rewrite the Source or Destination per Direction;
  * if mode is OneToOne, also flip the directionality of source/direction before 
  * translating (e.g., a rather than 
  1.2.3.4 -> 192.168.3.80 => 1.2.3.4 -> 108.104.111.111, 
  1.2.3.4 -> 192.168.3.80 => 192.168.3.80 -> 108.104.111.111
  *)
val translate : ?mode:Lookup.xl_mode -> Lookup.t -> direction -> Cstruct.t -> Cstruct.t option

(* given an IP and a frame, return whether the Source or Destination matches (or
neither *)
val detect_direction : Cstruct.t -> Ipaddr.t -> direction option

(** given a table, a frame, and a translation IP and port, 
  * put relevant entries for the (src_ip, src_port), (dst_ip, dst_port) from the
  * frame and given (xl_ip, xl_port), depending on the mode argument.
  * if mode is OneToMany (i.e., the mode we want with two ifaces), 
    ((src_ip, src_port), (dst_ip, dst_port)) to (xl_ip, xl_port) and 
    ((dst_ip, dst_port), (xl_ip, xl_port)) to (src_ip, src_port) .
  * If mode is OneToOne, (i.e., we're accepting traffic on behalf of another IP
    and doing 1:1 NAT translation), entries will look like:
    ((src_ip, src_port), (xl_ip, xl_port)) to (dst_ip, dst_port) and
    ((xl_ip, xl_port), (dst_ip, dst_port)) to (src_ip, src_port).
  * if insertion succeeded, return the new table;
  * otherwise, return an error type indicating the problem. *)
val make_entry : ?mode:Lookup.xl_mode -> Lookup.t 
  -> Cstruct.t -> Ipaddr.t -> int -> Lookup.state -> insert_result

