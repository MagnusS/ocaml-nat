open OUnit2
open Ipaddr
open Rewrite

let zero_cstruct cs =
  let zero c = Cstruct.set_char c 0 '\000' in
  let i = Cstruct.iter (fun c -> Some 1) zero cs in
  Cstruct.fold (fun b a -> b) i cs

let ip_and_above_of_frame frame =
  match (Wire_structs.get_ethernet_ethertype frame) with
  | 0x0800 | 0x86dd -> Cstruct.shift frame Wire_structs.sizeof_ethernet
  | _ -> assert_failure "tried to get ip layer of non-ip frame"

let transport_and_above_of_ip ip = 
  let hlen_version = Wire_structs.get_ipv4_hlen_version ip in
  match ((hlen_version land 0xf0) lsr 4) with
  | 4 -> (* length (in words, not bytes) is in the other half of hlen_version *)
    Cstruct.shift ip ((hlen_version land 0x0f) * 4)
  | 6 -> (* ipv6 is a constant length *)
    Cstruct.shift ip Wire_structs.Ipv6_wire.sizeof_ipv6
  | n -> 
    let err = 
      (Printf.sprintf 
         "tried to get transport layer of a non-ip frame (hlen/vers %x) " n)
    in
    assert_failure err

let basic_ipv4_frame ?(frame_size=1024) proto src dst ttl smac_addr =
  let ethernet_frame = zero_cstruct (Cstruct.create frame_size) in (* altered *)
  let ethernet_frame = Cstruct.set_len ethernet_frame 
      (Wire_structs.sizeof_ethernet + Wire_structs.sizeof_ipv4) in
  let smac = Macaddr.to_bytes smac_addr in (* altered *)
  Wire_structs.set_ethernet_src smac 0 ethernet_frame;
  Wire_structs.set_ethernet_ethertype ethernet_frame 0x0800;
  let buf = ip_and_above_of_frame ethernet_frame in
  (* Write the constant IPv4 header fields *)
  Wire_structs.set_ipv4_hlen_version buf ((4 lsl 4) + (5)); 
  Wire_structs.set_ipv4_tos buf 0;
  Wire_structs.set_ipv4_off buf 0; 
  Wire_structs.set_ipv4_ttl buf ttl; 
  Wire_structs.set_ipv4_proto buf proto;
  Wire_structs.set_ipv4_src buf (Ipaddr.V4.to_int32 src); (* altered *)
  Wire_structs.set_ipv4_dst buf (Ipaddr.V4.to_int32 dst);
  Wire_structs.set_ipv4_id buf 0x4142;
  let len = Wire_structs.sizeof_ethernet + Wire_structs.sizeof_ipv4 in
  (ethernet_frame, len)

let basic_ipv6_frame proto src dst ttl smac_addr =
  let ethernet_frame = zero_cstruct (Cstruct.create
                                       (Wire_structs.sizeof_ethernet +
                                        Wire_structs.Ipv6_wire.sizeof_ipv6)) in
  let smac = Macaddr.to_bytes smac_addr in 
  Wire_structs.set_ethernet_src smac 0 ethernet_frame;
  Wire_structs.set_ethernet_ethertype ethernet_frame 0x86dd;
  let ip_layer = ip_and_above_of_frame ethernet_frame in
  Wire_structs.Ipv6_wire.set_ipv6_version_flow ip_layer 0x60000000l;
  Wire_structs.Ipv6_wire.set_ipv6_src (Ipaddr.V6.to_bytes src) 0 ip_layer;
  Wire_structs.Ipv6_wire.set_ipv6_dst (Ipaddr.V6.to_bytes dst) 0 ip_layer;
  Wire_structs.Ipv6_wire.set_ipv6_nhdr ip_layer proto;
  Wire_structs.Ipv6_wire.set_ipv6_hlim ip_layer ttl;
  let len = Wire_structs.sizeof_ethernet + Wire_structs.Ipv6_wire.sizeof_ipv6 in
  (ethernet_frame, len)

let add_tcp (frame, len) source_port dest_port =
  let frame = Cstruct.set_len frame (len + Wire_structs.Tcp_wire.sizeof_tcp) in
  let tcp_buf = Cstruct.shift frame len in
  Wire_structs.Tcp_wire.set_tcp_src_port tcp_buf source_port;
  Wire_structs.Tcp_wire.set_tcp_dst_port tcp_buf dest_port;
  (* for now, all tcp packets have syn set & have a consistent seq # *)
  (* they also don't have options *)
  Wire_structs.Tcp_wire.set_tcp_sequence tcp_buf (Int32.of_int 0x432af310);
  Wire_structs.Tcp_wire.set_tcp_ack_number tcp_buf Int32.zero;
  Wire_structs.Tcp_wire.set_tcp_dataoff tcp_buf 5;
  Wire_structs.Tcp_wire.set_tcp_flags tcp_buf 2; (* syn *)
  Wire_structs.Tcp_wire.set_tcp_window tcp_buf 536; (* default_mss from tcp/window.ml *)
  (* leave checksum and urgent pointer unset *)
  (frame, len + Wire_structs.Tcp_wire.sizeof_tcp)

let add_udp (frame, len) source_port dest_port =
  (* also cribbed from mirage-tcpip *)
  let frame = Cstruct.set_len frame (len + Wire_structs.sizeof_udp) in
  let udp_buf = Cstruct.shift frame len in
  Wire_structs.set_udp_source_port udp_buf source_port;
  Wire_structs.set_udp_dest_port udp_buf dest_port;
  Wire_structs.set_udp_length udp_buf (Wire_structs.sizeof_udp (* + Cstruct.lenv
                                                                 bufs *));
  (* bufs is payload, which in our case is empty *)
  (* let csum = Ip.checksum frame (udp_buf (* :: bufs *) ) in 
  Wire_structs.set_udp_checksum udp_buf csum; *)
  (frame, len + Wire_structs.sizeof_udp)

let test_ipv4_rewriting exp_src exp_dst exp_proto exp_ttl xl_frame =
  (* should still be an ipv4 frame *)
  let printer a = Ipaddr.V4.to_string (Ipaddr.V4.of_int32 a) in
  let ipv4 = ip_and_above_of_frame xl_frame in

  (* should still be an ipv4 packet *)
  assert_equal 0x0800 (Wire_structs.get_ethernet_ethertype xl_frame);

  assert_equal ~printer (Ipaddr.V4.to_int32 (exp_src)) (Wire_structs.get_ipv4_src ipv4);
  assert_equal ~printer (Ipaddr.V4.to_int32 (exp_dst)) (Wire_structs.get_ipv4_dst ipv4);
  assert_equal ~printer:string_of_int exp_proto (Wire_structs.get_ipv4_proto ipv4);

  (* TTL should be the expected value, which the caller sets to k-1 *)
  assert_equal ~printer:string_of_int exp_ttl (Wire_structs.get_ipv4_ttl ipv4)

  (* don't do checksum checking for now *)

let basic_tcpv4 (direction : Rewrite.direction) proto ttl src dst xl sport dport xlport =
  let smac_addr = Macaddr.of_string_exn "00:16:3e:ff:00:ff" in
  let (frame, len) = 
    match direction with
    (* given that src is the "internal" ip, 
       dst is some "external" host,
       and xl is the nat IP that faces the "external" host,
       construct a packet for which the default table would have matches in the
      appropriate direction.
      if Rewrite.translate should be overwriting the Destination field, 
      the packet should look like it's coming from an external host, 
      destined for the xl ip, so Rewrite can replace xl with src. *)
    | Destination -> basic_ipv4_frame proto dst xl ttl smac_addr 
    (* if Rewrite.translate should be overwriting the Source field, 
       the packet should look like it's coming from an internal host, going to
       a public ip like dst, so Rewrite.translate can replace src with xl. *)
    | Source -> basic_ipv4_frame proto src dst ttl smac_addr
  in
  let frame, _ = 
    match direction with
    (* situation where you want to rewrite destination:
     * inbound packet from something that already has a table entry
     * (s/dst/xl/)
     *)
    | Destination -> add_tcp (frame, len) dport xlport
    (* rewrite source for outbound packets (s/src/xl/) *)
    | Source -> add_tcp (frame, len) sport dport
  in
  let table = 
    match Lookup.insert (Lookup.empty ()) proto
            ((V4 src), sport) ((V4 dst), dport) ((V4 xl), xlport) Active
    with
    | Some t -> t
    | None -> assert_failure "Failed to insert test data into table structure"
  in
  frame, table

let test_tcp_ipv4_oto context =
  let ttl = 4 in
  let proto = 6 in
  let src = (Ipaddr.V4.of_string_exn "192.168.108.26") in
  let dst = (Ipaddr.V4.of_string_exn "4.141.2.6") in 
  let xl = (Ipaddr.V4.of_string_exn "128.104.108.1") in
  let sport, dport, xlport = 255, 1024, 45454 in
  let smac_addr = Macaddr.of_string_exn "00:16:3e:ff:ff:ff" in
  let frame, len = basic_ipv4_frame proto src xl ttl smac_addr in
  let frame, len = add_tcp (frame, len) sport xlport in
  let table = 
    match Lookup.insert ~mode:OneToOne (Lookup.empty ()) proto
            ((V4 src), sport) ((V4 dst), dport) ((V4 xl), xlport) Active
    with
    | Some t -> t
    | None -> assert_failure "Failed to insert test data into table structure"
  in
  match Rewrite.translate ~mode:OneToOne table Destination frame with
  | None -> assert_failure "one-to-one translation failed for a reasonable
  frame"
  | Some xl_frame ->
    test_ipv4_rewriting xl dst proto (ttl - 1) xl_frame;
    (* TODO: test ports too *)
    ()

let test_tcp_ipv4_dst context = 
  let ttl = 4 in
  let proto = 6 in
  let src = (Ipaddr.V4.of_string_exn "192.168.108.26") in
  let dst = (Ipaddr.V4.of_string_exn "4.141.2.6") in 
  let xl = (Ipaddr.V4.of_string_exn "128.104.108.1") in
  let sport, dport, xlport = 255, 1024, 45454 in
  let frame, table = basic_tcpv4 Destination proto ttl src dst xl sport dport xlport in
  (* basic_tcpv4 should return a frame that needs destination rewriting -- 
   * i.e., one from 4.141.2.6 (dst) to 128.104.108.1 (xl), which needs to have
    * 128.104.108.1 (xl) rewritten to 192.168.108.26 (src) *)
  test_ipv4_rewriting dst xl proto (ttl) frame;

  let translated_frame = Rewrite.translate table Destination frame in
  match translated_frame with
  | None -> assert_failure "Expected translateable frame wasn't rewritten"
  | Some xl_frame ->
    (* check basic ipv4 stuff *)
    test_ipv4_rewriting dst src proto (ttl - 1) xl_frame;

    let xl_ipv4 = ip_and_above_of_frame xl_frame in
    let xl_tcp = transport_and_above_of_ip xl_ipv4 in
    let payload = Cstruct.shift xl_tcp (Wire_structs.Tcp_wire.sizeof_tcp) in

    (* check that src port is the same *)
    assert_equal ~printer:string_of_int dport 
      (Wire_structs.Tcp_wire.get_tcp_src_port xl_tcp);
    (* dst port should have been rewritten *)
    assert_equal ~printer:string_of_int sport 
      (Wire_structs.Tcp_wire.get_tcp_dst_port xl_tcp);

    (* payload should be the same *)
    (* TODO: TCP is a variable-length header; this shift will fail if options
       are set *)
    assert_equal (Cstruct.shift xl_tcp Wire_structs.Tcp_wire.sizeof_tcp)
      payload

let test_tcp_ipv4_src context = 
  let ttl = 4 in
  let proto = 6 in
  let src = (Ipaddr.V4.of_string_exn "10.231.50.254") in
  let dst = (Ipaddr.V4.of_string_exn "215.231.0.1") in 
  let xl = (Ipaddr.V4.of_string_exn "4.4.4.4") in
  let sport, dport, xlport = 40192,1024,45454 in
  let frame, table = basic_tcpv4 Source proto ttl src dst xl sport dport xlport in
  test_ipv4_rewriting src dst proto ttl frame;
  (* make sure things are set right in initial frame *)
  assert_equal ~printer:string_of_int dport 
    (Wire_structs.Tcp_wire.get_tcp_dst_port (transport_and_above_of_ip 
                                               (ip_and_above_of_frame frame)));
  let translated_frame = Rewrite.translate table Source frame in
    match translated_frame with
    | None -> assert_failure "Expected translateable frame wasn't rewritten"
    | Some xl_frame -> 
      (* check basic ipv4 stuff *)
      test_ipv4_rewriting xl dst proto (ttl - 1) xl_frame;

      let xl_ipv4 = ip_and_above_of_frame xl_frame in
      let xl_tcp = transport_and_above_of_ip xl_ipv4 in
      let payload = Cstruct.shift xl_tcp (Wire_structs.Tcp_wire.sizeof_tcp) in

      (* src port should have been rewritten from sport to xlport *)
      assert_equal ~printer:string_of_int xlport 
        (Wire_structs.Tcp_wire.get_tcp_src_port xl_tcp);

      (* check that dst port is the same *)
      assert_equal ~printer:string_of_int dport 
        (Wire_structs.Tcp_wire.get_tcp_dst_port xl_tcp);

      (* payload should be the same *)
      let original_payload = 
        Cstruct.shift (transport_and_above_of_ip (ip_and_above_of_frame frame))
          Wire_structs.Tcp_wire.sizeof_tcp in
      assert_equal original_payload payload

    (* TODO: no checksum checking right now, since we leave that for the actual
sender to take care of *)

let test_udp_ipv4 context =
  let proto = 17 in
  let src = (Ipaddr.V4.of_string_exn "192.168.108.26") in
  let dst = (Ipaddr.V4.of_string_exn "4.141.2.6") in 
  let xl = (Ipaddr.V4.of_string_exn "128.104.108.1") in
  let smac_addr = Macaddr.of_string_exn "00:16:3e:ff:00:ff" in
  let ttl = 38 in
  let (frame, len) = basic_ipv4_frame proto src dst ttl smac_addr in
  let (frame, len) = add_udp (frame, len) 255 1024 in
  let table = 
    match Lookup.insert (Lookup.empty ()) 17 
            ((V4 src), 255) ((V4 dst), 1024) ((V4 xl), 45454) Active
    with
    | Some t -> t
    | None -> assert_failure "Failed to insert test data into table structure"
  in
  let translated_frame = Rewrite.translate table Destination frame in
  match translated_frame with
  | None -> assert_failure "Expected translateable frame wasn't rewritten"
  | Some xl_frame ->
    (* check to see whether ipv4-level translation happened as expected *)
    test_ipv4_rewriting src xl proto (ttl - 1) xl_frame;

    let xl_ipv4 = ip_and_above_of_frame xl_frame in
    let xl_udp = transport_and_above_of_ip xl_ipv4 in

    (* UDP destination port should have changed *)
    assert_equal ~printer:string_of_int 45454 (Wire_structs.get_udp_dest_port
                                                 xl_udp);

    (* payload should be unaltered *)
    let xl_payload = Cstruct.shift xl_udp (Wire_structs.sizeof_udp) in
      let original_payload = 
        Cstruct.shift (transport_and_above_of_ip (ip_and_above_of_frame frame))
          Wire_structs.sizeof_udp in
    assert_equal ~printer:Cstruct.to_string xl_payload original_payload
    (* TODO: checksum checks *)

let test_udp_ipv6 context =
  let proto = 17 in
  let interior_v6 = (Ipaddr.V6.of_string_exn "3333:aaa:bbbb:ccc::dd:ee") in
  let exterior_v6 = (Ipaddr.V6.of_string_exn "2a01:e35:2e8a:1e0::42:10") in
  let translate_v6 = (Ipaddr.V6.of_string_exn
                        "2604:3400:dc1:43:216:3eff:fe85:23c5") in
  let smac = Macaddr.of_string_exn "00:16:3e:c0:ff:ee" in
  let (frame, len) = basic_ipv6_frame proto interior_v6 exterior_v6 40 smac in
  let table =
    match Lookup.insert (Lookup.empty ()) proto 
            ((V6 interior_v6), 255) 
            ((V6 exterior_v6), 1024) 
            ((V6 translate_v6), 45454) Active
    with
    | Some t -> t
    | None -> assert_failure "Failed to insert test data into table structure"
  in
  match Rewrite.translate table Destination frame with
  | None -> todo "Couldn't translate an IPv6 UDP frame"
  | Some xl_frame -> todo "Sanity checks for IPv6 UDP frame translation not
  implemented yet :("

let test_make_entry_valid_pkt context =
  let proto = 17 in
  let src = Ipaddr.V4.of_string_exn "172.16.2.30" in
  let dst = Ipaddr.V4.of_string_exn "1.2.3.4" in
  let sport = 18787 in
  let dport = 80 in
  let xl_ip = Ipaddr.V4.of_string_exn "172.16.0.1" in
  let xl_port = 10201 in
  let smac_addr = Macaddr.of_string_exn "00:16:3e:65:65:65" in
  let table = Lookup.empty () in
  let (frame, len) = basic_ipv4_frame proto src dst 52 smac_addr in
  let (frame, len) = add_udp (frame, len) sport dport in
  match Rewrite.make_entry table frame (Ipaddr.V4 xl_ip) xl_port Active with
  | Overlap -> assert_failure "make_entry claimed overlap when inserting into an
                 empty table"
  | Unparseable -> 
    Printf.printf "Allegedly unparseable frame follows:\n";
    Cstruct.hexdump frame;
    assert_failure "make_entry claimed that a reference packet was unparseable"
  | Ok t ->
    (* make sure table actually has the entries we expect *)
    let check_entries (src_lookup : (Ipaddr.t * int) option) dst_lookup = 
      (* TODO: rewrite this; assert_equal and a printer function would be
         clearer *)
      match src_lookup, dst_lookup with
      | Some (q_ip, q_port), Some (r_ip, r_port) when 
          (q_ip, q_port, r_ip, r_port) = (V4 xl_ip, xl_port, V4 src, sport) -> ()
      | Some (q_ip, q_port), Some (r_ip, r_port) -> 
        let err = Printf.sprintf "Bad entry from make_entry: %s, %d; %s, %d\n" 
            (Ipaddr.to_string q_ip) q_port 
            (Ipaddr.to_string r_ip) r_port in
        assert_failure err
      | _, None | None, _ -> assert_failure 
        "make_entry claimed success, but was missing expected entries entirely"
    in
    let src_lookup = Lookup.lookup t proto (V4 src, sport) (V4 dst, dport) in
    let dst_lookup = Lookup.lookup t proto (V4 dst, dport) (V4 xl_ip, xl_port) in
    check_entries src_lookup dst_lookup;
    (* trying the same operation again should give us an Overlap failure *)
    match Rewrite.make_entry t frame (Ipaddr.V4 xl_ip) xl_port Active with
    | Overlap -> ()
    | Unparseable -> 
      Printf.printf "Allegedly unparseable frame follows:\n";
      Cstruct.hexdump frame;
      assert_failure "make_entry claimed that a reference packet was unparseable"
    | Ok t -> assert_failure "make_entry allowed a duplicate entry"

let test_make_entry_nonsense context =
  (* sorts of bad packets: broadcast packets,
     non-tcp/udp/icmp packets *)
  let proto = 17 in
  let src = Ipaddr.V4.of_string_exn "172.16.2.30" in
  let dst = Ipaddr.V4.of_string_exn "1.2.3.4" in
  let xl_ip = Ipaddr.V4.of_string_exn "172.16.0.1" in
  let xl_port = 10201 in
  let smac_addr = Macaddr.of_string_exn "00:16:3e:65:65:65" in
  let frame_size = (Wire_structs.sizeof_ethernet + Wire_structs.sizeof_ipv4) in
  let mangled_looking, _ = basic_ipv4_frame ~frame_size proto src dst 60 smac_addr in
  match (Rewrite.make_entry (Lookup.empty ()) mangled_looking
           (Ipaddr.V4 xl_ip) xl_port) Active with
  | Overlap -> assert_failure "make_entry claimed a mangled packet was already
  in the table"
  | Ok t -> assert_failure "make_entry happily took a mangled packet"
  | Unparseable -> 
    let broadcast_dst = Ipaddr.V4.of_string_exn "255.255.255.255" in
    let sport = 45454 in
    let dport = 80 in
    let broadcast, _ = add_tcp (basic_ipv4_frame 6 src broadcast_dst 30 smac_addr)
        sport dport in
    match (Rewrite.make_entry (Lookup.empty ()) broadcast (Ipaddr.V4 xl_ip)
             xl_port) Active with
    | Ok _ | Overlap -> assert_failure "make_entry happily took a broadcast
    packet"
    | Unparseable -> 
      (* try just an ethernet frame *)
      let e = zero_cstruct (Cstruct.create Wire_structs.sizeof_ethernet) in
      match (Rewrite.make_entry (Lookup.empty ()) e (Ipaddr.V4 xl_ip) xl_port
               Active)
      with
      | Ok _ | Overlap -> assert_failure "make_entry claims to have succeeded
      with a bare ethernet frame"
      | Unparseable -> ()

let test_make_entry_one_to_one context =
  let proto = 17 in
  let src = Ipaddr.V4.of_string_exn "5.121.8.4" in
  let dst = Ipaddr.V4.of_string_exn "107.32.111.12" in
  let sport = 18787 in
  let dport = 80 in
  let xl_ip = Ipaddr.V4.of_string_exn "66.22.15.26" in
  let xl_port = 10201 in
  let smac_addr = Macaddr.of_string_exn "00:16:3e:65:65:65" in
  let table = Lookup.empty () in
  let (frame, len) = basic_ipv4_frame proto src dst 52 smac_addr in
  let (frame, len) = add_udp (frame, len) sport dport in
  match Rewrite.make_entry ~mode:OneToOne table frame (Ipaddr.V4 xl_ip) xl_port Active with
  | Overlap -> assert_failure "make_entry claimed overlap when inserting into an
                 empty table"
  | Unparseable -> 
    Printf.printf "Allegedly unparseable frame follows:\n";
    Cstruct.hexdump frame;
    assert_failure "make_entry claimed that a reference packet was unparseable"
  | Ok t ->
    (* make sure table actually has the entries we expect *)
    let check_entries (src_lookup : (Ipaddr.t * int) option) dst_lookup = 
      (* TODO: rewrite this; assert_equal and a printer function would be
         clearer *)
      match src_lookup, dst_lookup with
      | Some (q_ip, q_port), Some (r_ip, r_port) when 
          (q_ip, q_port, r_ip, r_port) = (V4 src, sport, V4 dst, dport) -> ()
      | Some (q_ip, q_port), Some (r_ip, r_port) -> 
        let err = Printf.sprintf "Bad entry from make_entry: %s, %d; %s, %d\n" 
            (Ipaddr.to_string q_ip) q_port 
            (Ipaddr.to_string r_ip) r_port in
        assert_failure err
      | _, None | None, _ -> assert_failure 
        "make_entry claimed success, but was missing expected entries entirely"
    in
    let src_lookup = Lookup.lookup t proto (V4 dst, dport) (V4 xl_ip, xl_port) in
    let dst_lookup = Lookup.lookup t proto (V4 src, sport) (V4 xl_ip, xl_port) in
    check_entries src_lookup dst_lookup;
    (* trying the same operation again should give us an Overlap failure *)
    match Rewrite.make_entry ~mode:OneToOne table frame (Ipaddr.V4 xl_ip) xl_port Active with
    | Overlap -> ()
    | Unparseable -> 
      Printf.printf "Allegedly unparseable frame follows:\n";
      Cstruct.hexdump frame;
      assert_failure "make_entry claimed that a reference packet was unparseable"
    | Ok t -> assert_failure "make_entry allowed a duplicate entry"

let test_detect_direction_ipv4 context =
  let printer = function
    | None -> "none"
    | Some Source -> "source"
    | Some Destination -> "destination"
  in
  let proto = 17 in
  let src = Ipaddr.V4.of_string_exn "5.121.8.4" in
  let dst = Ipaddr.V4.of_string_exn "107.32.111.12" in
  let xl = Ipaddr.V4.of_string_exn "66.22.15.26" in
  let sport, dport, xlport = 18787, 80, 10201 in
  let smac_addr = Macaddr.of_string_exn "00:16:3e:65:65:65" in
  let table = Lookup.empty () in
  let (frame, len) = basic_ipv4_frame proto xl dst 52 smac_addr in
  let (frame, len) = add_udp (frame, len) xlport dport in
  assert_equal ~printer (Some Source) (detect_direction frame (V4 xl));
  assert_equal ~printer (Some Destination) (detect_direction frame (V4 dst));
  assert_equal ~printer (None) (detect_direction frame (V4 src));
  let (frame, len) = basic_ipv4_frame proto src xl 52 smac_addr in
  let (frame, len) = add_udp (frame, len) sport xlport in
  assert_equal ~printer (Some Source) (detect_direction frame (V4 src));
  assert_equal ~printer (Some Destination) (detect_direction frame (V4 xl));
  assert_equal ~printer (None) (detect_direction frame (V4 dst))

let test_detect_direction_ipv6 context =
  todo "Test not implemented :("

let test_tcp_ipv6 context =
  todo "Test not implemented :("

let test_extractors context =
  let ttl = 4 in
  let proto = 6 in
  let src = (Ipaddr.V4.of_string_exn "192.168.108.26") in
  let dst = (Ipaddr.V4.of_string_exn "4.141.2.6") in 
  let xl = (Ipaddr.V4.of_string_exn "128.104.108.1") in
  let sport, dport, xlport = 255, 1024, 45454 in
  let frame, table = basic_tcpv4 Source proto ttl src dst xl sport dport xlport in
  let printer = function
    | None -> "none"
    | Some (p, q) -> Printf.sprintf ("%s, %s\n") (Ipaddr.to_string p)
                       (Ipaddr.to_string q)
  in
  assert_equal ~printer (ips_of_frame frame) (Some ((V4 src), (V4 dst)));
  assert_equal (proto_of_frame frame) (Some proto);
  assert_equal (ports_of_frame frame) (Some (sport, dport));
  let frame = Cstruct.set_len frame (Wire_structs.sizeof_ethernet +
                                     Wire_structs.sizeof_ipv4) in
  assert_equal ~printer (ips_of_frame frame) (Some ((V4 src), (V4 dst)));
  assert_equal (proto_of_frame frame) (Some proto);
  assert_equal (ports_of_frame frame) None;
  let frame = Cstruct.set_len frame (Wire_structs.sizeof_ethernet) in
  assert_equal ~printer (ips_of_frame frame) None;
  assert_equal (proto_of_frame frame) None;
  assert_equal (ports_of_frame frame) None

let suite = "test-rewrite" >:::
            [

              "[ips,proto,ports]_of_frame" >:: test_extractors;
              "Direction checking gives correct results" >::
              test_detect_direction_ipv4;
              "UDP IPv4 rewriting works" >:: test_udp_ipv4;
              (* TODO UDP IPv4 source rewriting test *)
              "TCP IPv4 destination rewriting works" >:: test_tcp_ipv4_dst ;
              "TCP IPv4 source rewriting works" >:: test_tcp_ipv4_src ;
              "TCP IPv4 one-to-one rewriting works" >:: test_tcp_ipv4_oto;
              "UDP IPv6 rewriting works" >:: test_udp_ipv6;
              "TCP IPv6 rewriting works" >:: test_tcp_ipv6; 
              (* TODO: 4-to-6, 6-to-4 tests *)
              "make_entry makes entries" >:: test_make_entry_valid_pkt;
              (* TODO: test make_entry in non-ipv4 contexts *)
              "make_entry refuses nonsense frames" >:: test_make_entry_nonsense;
              "make_entry makes OneToOne entries properly" >::
              test_make_entry_one_to_one
            ]

let () = 
  run_test_tt_main suite
