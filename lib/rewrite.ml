open Ipaddr

(* this is temporary -- waiting on merge of nojb's pr for cstruct in ipaddr,
 * see https://github.com/mirage/ocaml-ipaddr/pull/36 
 * unfortunately tcpip/lib/ipv6.ml is in this position as well *)
module V4 = struct
  type t = Ipaddr.V4.t

  let make a b c d =
    let (~|) = Int32.of_int in
    let (&&&) x y = Int32.logand x y in
    let (|||) x y = Int32.logor x y in
    let (<|<) x y = Int32.shift_left x y in
    let (<!)  x y = (x &&& 0xFF_l) <|< y in

    ((~| a <! 24) ||| (~| b <! 16)) ||| ((~| c <! 8) ||| (~| d <! 0))

  (* Cstruct conversion *)
  let of_cstruct_raw cs o =
    make 
      (Char.code (Cstruct.get_char cs (0 + o)))
      (Char.code (Cstruct.get_char cs (1 + o)))
      (Char.code (Cstruct.get_char cs (2 + o)))
      (Char.code (Cstruct.get_char cs (3 + o)))

  let of_cstruct_exn cs =
    let len = Cstruct.len cs in
    if len < 4 then raise (Invalid_argument (Cstruct.to_string cs));
    if len > 4 then raise (Invalid_argument (Cstruct.to_string cs));
    of_cstruct_raw cs 0

  let to_cstruct_raw i cs o =
    let (>|>) x y = Int32.shift_right_logical x y in
    let (&&&) x y = Int32.logand x y in
    let (>!)  x y = (x >|> y) &&& 0xFF_l in
    Cstruct.set_char cs (0 + o) (Char.chr (Int32.to_int (i >! 24)));
    Cstruct.set_char cs (1 + o) (Char.chr (Int32.to_int (i >! 16)));
    Cstruct.set_char cs (2 + o) (Char.chr (Int32.to_int (i >!  8)));
    Cstruct.set_char cs (3 + o) (Char.chr (Int32.to_int (i >!  0)))

  let to_cstruct i =
    let cs = Cstruct.create 4 in
    to_cstruct_raw i cs 0;
    cs
end

module V6 = struct
  let of_cstruct_raw cs o =
    let hihi = V4.of_cstruct_raw cs (o + 0) in
    let hilo = V4.of_cstruct_raw cs (o + 4) in
    let lohi = V4.of_cstruct_raw cs (o + 8) in
    let lolo = V4.of_cstruct_raw cs (o + 12) in
    Ipaddr.V6.of_int32 (hihi, hilo, lohi, lolo)

  let of_cstruct_exn cs =
    let len = Cstruct.len cs in
    if len > 16 then raise (Invalid_argument (Cstruct.to_string cs));
    if len < 16 then raise (Invalid_argument (Cstruct.to_string cs));
    of_cstruct_raw cs 0

  let to_cstruct_raw (a,b,c,d) cs o =
    V4.to_cstruct_raw a cs (0+0);
    V4.to_cstruct_raw b cs (0+4);
    V4.to_cstruct_raw c cs (0+8);
    V4.to_cstruct_raw d cs (0+12)

  let to_cstruct i =
    let cs = Cstruct.create 16 in
    to_cstruct_raw i cs 0;
    cs
end

type direction = Source | Destination
type insert_result = 
  | Ok of Lookup.t
  | Overlap
  | Unparseable

(* reproduced from ipv4.checksum *)
let checksum =
  let pbuf = Cstruct.create 4 in
  Cstruct.set_uint8 pbuf 0 0;
  fun frame bufs ->
    let frame = Cstruct.shift frame Wire_structs.sizeof_ethernet in
    Cstruct.set_uint8 pbuf 1 (Wire_structs.get_ipv4_proto frame);
    Cstruct.BE.set_uint16 pbuf 2 (Cstruct.lenv bufs);
    let src_dst = Cstruct.sub frame 12 (2 * 4) in
    Tcpip_checksum.ones_complement_list (src_dst :: pbuf :: bufs)

(* TODO: it's not clear where this function should be, but it probably shouldn't
   be here in the long run. *)
let retrieve_ips frame = 
  let ip_type = Wire_structs.get_ethernet_ethertype frame in
  let ip_packet = Cstruct.shift frame Wire_structs.sizeof_ethernet in
  match ip_type with
  | 0x0800 -> (* ipv4 *) 
    Some 
    (Ipaddr.V4 (Ipaddr.V4.of_int32 (Wire_structs.get_ipv4_src ip_packet)), 
     Ipaddr.V4 (Ipaddr.V4.of_int32 (Wire_structs.get_ipv4_dst ip_packet)))
  | 0x86dd -> (* ipv6 *)
    Some 
    (Ipaddr.V6 (V6.of_cstruct_exn (Wire_structs.Ipv6_wire.get_ipv6_src ip_packet)), 
     Ipaddr.V6 (V6.of_cstruct_exn (Wire_structs.Ipv6_wire.get_ipv6_dst ip_packet)))
  | _ -> None

let retrieve_ports tx_layer = 
  (* Cstruct.uint16, Cstruct.uint16 *)
  if (Cstruct.len tx_layer < (Wire_structs.sizeof_udp)) then None else Some
  ((Wire_structs.get_udp_source_port tx_layer : int), 
   (Wire_structs.get_udp_dest_port tx_layer : int))

let detect_direction frame ip =
  (* this would be a horrible bug if we were concerned with anything except
    unicast traffic, but luckily we're OK *)
  match retrieve_ips frame with
  | Some (src, dst) when (Ipaddr.compare src ip = 0) -> Some Source
  | Some (src, dst) when (Ipaddr.compare dst ip = 0) -> Some Destination
  | Some _ | None -> None

let translate ?(mode=(OneToMany : Lookup.xl_mode)) table direction frame =
  (* note that ethif.input doesn't have the same register-listeners-then-input
     format that tcp/udp do, so we could use it for the outer layer of parsing *)
  let ip_size is_ipv6 = match is_ipv6 with 
    | false -> Wire_structs.sizeof_ipv4
    | true -> Wire_structs.Ipv6_wire.sizeof_ipv6
  in
  (* TODO: this is not the right set of parameters for a function that might
     have to do 6-to-4 translation *)
  (* also, TODO all of the 6-to-4/4-to-6 thoughts and code.  nbd. *)
  let rewrite_ip is_ipv6 (packet : Cstruct.t) direction i =
    match (is_ipv6, direction, i) with
    | false, Source, Ipaddr.V4 new_ip -> 
      Wire_structs.set_ipv4_src packet (Ipaddr.V4.to_int32 new_ip)
    | false, Destination, Ipaddr.V4 new_ip ->
      Wire_structs.set_ipv4_dst packet (Ipaddr.V4.to_int32 new_ip)
    (* TODO: every other case *)
    | _, _, _ -> raise (Failure "ipv4-ipv4 is the only implemented case")
  in
  let rewrite_port (txlayer : Cstruct.t) direction port =
    match direction with
    | Source -> Wire_structs.set_udp_source_port txlayer port
    | Destination -> Wire_structs.set_udp_dest_port txlayer port
  in
  let decrement_ttl ip_layer =
    Wire_structs.set_ipv4_ttl ip_layer 
      ((Wire_structs.get_ipv4_ttl ip_layer) - 1)
  in
  (* TODO: this is not correct for IPv6 *)
  (* TODO: it's not clear to me whether we need to do this, since most users
    will be sending packets via IP.write, which itself calculates and inserts
    the proper checksum before sending the packet. *)
  let recalculate_ip_checksum ip_layer =
    Wire_structs.set_ipv4_csum ip_layer 0;
    let just_ipv4 = Cstruct.sub ip_layer 0 (Wire_structs.sizeof_ipv4) in
    let new_csum = Tcpip_checksum.ones_complement just_ipv4 in
    Wire_structs.set_ipv4_csum ip_layer new_csum
  in
  let ip_packet = Cstruct.shift frame Wire_structs.sizeof_ethernet in
  match (retrieve_ips frame) with
  | Some (V4 src, V4 dst) -> (* ipv4 *) (
      let proto = Wire_structs.get_ipv4_proto ip_packet in
      match proto with
      | 6 | 17 -> (
          let higherproto_packet = Cstruct.shift ip_packet (ip_size false) in
          match retrieve_ports higherproto_packet with
          | Some (sport, dport) -> (
            (* got everything; do the lookup *)
            let result = Lookup.lookup table proto ((V4 src), sport) ((V4 dst), dport)
            in
            match result with 
              | Some (V4 new_ip, new_port) ->
                (* TODO: we should probably refuse to pass TTL = 0 and instead send an
                   ICMP message back to the sender *)
                (match mode with 
                | OneToOne ->
                  (* flip IPs *)
                  rewrite_ip false ip_packet Source (V4 dst);
                  rewrite_ip false ip_packet Destination (V4 src);
                  (* flip ports *)
                  rewrite_port higherproto_packet Source dport;
                  rewrite_port higherproto_packet Destination sport
                | OneToMany -> ()
                )
                  ;
                rewrite_ip false ip_packet direction (V4 new_ip);
                rewrite_port higherproto_packet direction new_port;
                decrement_ttl ip_packet;
                recalculate_ip_checksum ip_packet;
                Some frame 
              | Some (V6 new_ip, new_port) -> None (* TODO: 4-to-6 logic *)
              | None -> None (* don't autocreate new entries *)
            )
          | None -> None (* udp/tcp but couldn't get ports; drop it *)
        )
      | _ -> None (* TODO: don't just drop all non-udp, non-tcp packets *)
    )
  | Some (V6 src, V6 dst) -> None (* TODO, obviously *) (* ipv6 *)
  | _ -> None (* don't forward arp or other types *)

let make_entry ?(mode=(OneToMany : Lookup.xl_mode)) table frame xl_ip xl_port timeout =
  (* basic sanity check; nothing smaller than this will be nat-able *)
  if (Cstruct.len frame) < (Wire_structs.sizeof_ethernet +
                          Wire_structs.sizeof_ipv4 + Wire_structs.sizeof_udp) 
  then 
    Unparseable
  else 
    let ip_layer = Cstruct.shift frame (Wire_structs.sizeof_ethernet) in
    let tx_layer = Cstruct.shift ip_layer (Wire_structs.sizeof_ipv4) in
    let proto = Wire_structs.get_ipv4_proto ip_layer in
    let check_scope ip =
      match Ipaddr.scope ip with
      | Global | Organization -> true
      | _ -> false
    in
    match (retrieve_ips frame), (retrieve_ports tx_layer) with
    | Some (src, dst), Some (sport, dport) -> begin
        (* only Organization and Global scope IPs get routed *)
        match check_scope src, check_scope dst with
        | true, true -> (
            match Lookup.insert ~mode table proto 
                    (src, sport) (dst, dport) (xl_ip, xl_port) timeout
            with
            | Some t -> Ok t
            | None -> Overlap 
          )
        | _, _ -> Unparseable
      end

| _, _ -> Unparseable
