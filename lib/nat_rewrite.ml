open Ipaddr

let src = Logs.Src.create "nat-rewrite" ~doc:"Mirage NAT packet rewriter"
module Log = (val Logs.src_log src : Logs.LOG)

open Lwt.Infix

let (>>!=) = Rresult.R.bind

let rewrite_icmp ~id icmp =
  match icmp.Icmpv4_packet.subheader with
  | Icmpv4_packet.Id_and_seq (_, seq) ->
    Ok {icmp with Icmpv4_packet.subheader = Icmpv4_packet.Id_and_seq (id, seq)}
  | _ ->
    Error `Untranslated

let rewrite_ip ~src ~dst ip =
  match ip.Ipv4_packet.ttl with
  | 0 -> Error `TTL_exceeded    (* TODO: send ICMP reply *)
  | n -> Ok {ip with Ipv4_packet.ttl = n - 1; src; dst}

let rewrite_ports_packet packet ~src:(src, src_port) ~dst:(dst,dst_port) =
  let `IPv4 (ip, transport) = packet in
  rewrite_ip ~src ~dst ip >>!= fun new_ip_header ->
  match transport with
  | `UDP (_udp_header, udp_payload) ->
    let new_transport_header = { Udp_packet.src_port; dst_port } in
    Logs.debug (fun f -> f "UDP header rewritten to: %a" Udp_packet.pp new_transport_header);
    Ok (`IPv4 (new_ip_header, `UDP (new_transport_header, udp_payload)))
  | `TCP (tcp_header, tcp_payload) ->
    let new_transport_header = { tcp_header with Tcp.Tcp_packet.src_port; dst_port } in
    Logs.debug (fun f -> f "TCP header rewritten to: %a" Tcp.Tcp_packet.pp new_transport_header);
    Ok (`IPv4 (new_ip_header, `TCP (new_transport_header, tcp_payload)))

let map_nat ~left ~right ~translate_left =
  let internal_lookup = (left, right) in
  let external_lookup = (right, translate_left) in
  let internal_mapping = (translate_left, right) in
  let external_mapping = (right, left) in
  let request_mapping = internal_lookup, internal_mapping in
  let response_mapping = external_lookup, external_mapping in
  [request_mapping; response_mapping]

let map_redirect ~left ~right ~translate_left ~translate_right =
  let internal_lookup = (left, translate_left) in
  let external_lookup = (right, translate_right) in
  let internal_mapping = (translate_right, right) in
  let external_mapping = (translate_left, left) in
  let request_mapping = internal_lookup, internal_mapping in
  let response_mapping = external_lookup, external_mapping in
  [request_mapping; response_mapping]

let ports_of_ip = function
  | `TCP (x, _) -> Tcp.Tcp_packet.(x.src_port, x.dst_port)
  | `UDP (x, _) -> Udp_packet.(x.src_port, x.dst_port)

let make_ports_entry mode transport (other_xl_ip, other_xl_port) ~src ~dst =
  let src_port, dst_port = ports_of_ip transport in
  match mode with
  | `NAT ->
    map_nat
      ~left:(src, src_port)
      ~right:(dst, dst_port)
      ~translate_left:(other_xl_ip, other_xl_port)
  | `Redirect final_endpoint ->
    map_redirect
      ~left:(src, src_port)
      ~right:final_endpoint
      ~translate_left:(dst, dst_port)
      ~translate_right:(other_xl_ip, other_xl_port)

let make_id_entry mode transport (other_xl_ip, other_xl_port) ~src ~dst =
  match mode, transport with
  | `NAT, `ICMP ({Icmpv4_packet.subheader = Icmpv4_packet.Id_and_seq (id, _); _}, _) ->
    begin
      let flip (x, y, id) = (y, x, id) in
      let left_channel = (src, dst, id) in
      let right_channel = (other_xl_ip, dst, other_xl_port) in
      let request_mapping = left_channel, right_channel in
      let response_mapping = flip right_channel, flip left_channel in
      Ok [request_mapping; response_mapping]
    end
  | _, `ICMP _ -> Error `Cannot_NAT

let result_map fn = function
  | Ok x -> fn x
  | Error _ as e -> Lwt.return e

module Icmp_payload = struct
  let get_ports ip payload =
    if Cstruct.len payload < 8 then Error `Untranslated
    else match Ipv4_packet.Unmarshal.int_to_protocol ip.Ipv4_packet.proto with
      | Some `UDP -> Ok (`UDP, Udp_wire.get_udp_source_port payload, Udp_wire.get_udp_dest_port payload)
      | Some `TCP -> Ok (`TCP, Tcp.Tcp_wire.get_tcp_src_port payload, Tcp.Tcp_wire.get_tcp_dst_port payload)
      | _ -> Error `Untranslated

  let dup src =
    let len = Cstruct.len src in
    let copy = Cstruct.create_unsafe len in
    Cstruct.blit src 0 copy 0 len;
    copy

  let with_ports payload (sport, dport) proto =
    let payload = dup payload in
    begin match proto with
      | `UDP ->
        Udp_wire.set_udp_source_port payload sport;
        Udp_wire.set_udp_dest_port payload dport
      | `TCP ->
        Tcp.Tcp_wire.set_tcp_src_port payload sport;
        Tcp.Tcp_wire.set_tcp_dst_port payload dport
    end;
    payload
end

module Make(N : Mirage_nat.TABLE) = struct

  type t = N.t

  let reset = N.reset

  let translate_ports table packet (sport, dport) =
    let `IPv4 (ip, transport) = packet in
    let src = V4 ip.Ipv4_packet.src in
    let dst = V4 ip.Ipv4_packet.dst in
    begin
      match transport with
      | `TCP _ -> N.TCP.lookup table ((src, sport), (dst, dport))
      | `UDP _ -> N.UDP.lookup table ((src, sport), (dst, dport))
    end >|= function
    | Some (_expiry, ((V4 new_src, new_sport), (V4 new_dst, new_dport))) ->
      rewrite_ports_packet packet ~src:(new_src, new_sport) ~dst:(new_dst, new_dport)
    | _ ->
      Error `Untranslated

  let translate_id table packet id =
    let `IPv4 (ip, `ICMP (icmp_header, payload)) = packet in
    N.ICMP.lookup table ((V4 ip.Ipv4_packet.src), (V4 ip.Ipv4_packet.dst), id) >|= function
    | Some (_expiry, (V4 new_src, V4 new_dst, new_id)) ->
      rewrite_ip ~src:new_src ~dst:new_dst ip >>!= fun new_ip_header ->
      rewrite_icmp ~id:new_id icmp_header >>!= fun new_icmp ->
      Logs.debug (fun f -> f "ICMP header rewritten to: %a" Icmpv4_packet.pp new_icmp);
      Ok (`IPv4 (new_ip_header, `ICMP (new_icmp, payload)))
    | _ ->
      Error `Untranslated

  let translate table (packet:Nat_packet.t) =
    MProf.Trace.label "Nat_rewrite.translate";
    match packet with
    | `IPv4 (_, `TCP (x, _)) as packet -> translate_ports table packet Tcp.Tcp_packet.(x.src_port, x.dst_port)
    | `IPv4 (_, `UDP (x, _)) as packet -> translate_ports table packet Udp_packet.(x.src_port, x.dst_port)
    | `IPv4 (_, `ICMP (x, `Query _)) as packet ->
      begin match x.Icmpv4_packet.subheader with
      | Icmpv4_packet.Id_and_seq (id, _) -> translate_id table packet id
      | _ -> Lwt.return (Error `Untranslated)
      end
    | `IPv4 (ip, `ICMP (icmp, `Error (orig_ip_pub, payload, payload_len))) ->
      match Icmp_payload.get_ports orig_ip_pub payload with
      | Error _ as e -> Lwt.return e
      | Ok (proto, src_port, dst_port) ->
        Log.debug (fun f -> f "ICMP error is for %a src_port=%d dst_port=%d"
                     Ipv4_packet.pp orig_ip_pub src_port dst_port
                 );
        (* Reverse src and dst because we want to treat this the same way we would
           have treated a normal response. *)
        let source = Ipaddr.V4 orig_ip_pub.Ipv4_packet.dst, dst_port in
        let destination = Ipaddr.V4 orig_ip_pub.Ipv4_packet.src, src_port in
        let channel = source, destination in
        begin
          match proto with
          | `TCP -> N.TCP.lookup table channel
          | `UDP -> N.UDP.lookup table channel
        end >|= function
        | Some (_expiry, ((V4 new_src, new_sport), (V4 new_dst, new_dport))) ->
          rewrite_ip ~src:new_src ~dst:new_dst ip >>!= fun ip ->
          let orig_ip_priv = { orig_ip_pub with Ipv4_packet.dst = new_src; src = new_dst } in
          let payload = Icmp_payload.with_ports payload (new_dport, new_sport) proto in
          let error_priv = `Error (orig_ip_priv, payload, payload_len) in
          Ok (`IPv4 (ip, `ICMP (icmp, error_priv)))
        | _ ->
          Error `Untranslated

  let add table ~now packet xl_endpoint mode =
    let `IPv4 (ip_header, transport) = packet in
    let check_scope ip =
      match Ipaddr.scope ip with
      | Global | Organization -> true
      | _ -> false
    in
    let (src, dst) = Ipv4_packet.(V4 ip_header.src, V4 ip_header.dst) in
    match check_scope src, check_scope dst with
    | false, _ | _, false -> Lwt.return (Error `Cannot_NAT)
    | true, true ->
      let expiration_window =
        (* TODO: this is silly in the case of TCP *)
        match transport with
        | `UDP _ -> Int64.of_int 60 (* UDP gets 60 seconds *)
        | `TCP _ -> Int64.of_int (60*60*24) (* TCP gets a day *)
        | `ICMP _ -> 120L (* RFC 5508: An ICMP Query session timer MUST NOT expire in less than 60 seconds *)
      in
      let expiry = Int64.add now expiration_window in
      match transport with
      | `TCP _ as transport -> make_ports_entry mode transport xl_endpoint ~src ~dst |> N.TCP.insert table ~expiry
      | `UDP _ as transport -> make_ports_entry mode transport xl_endpoint ~src ~dst |> N.UDP.insert table ~expiry
      | `ICMP _ as transport -> make_id_entry   mode transport xl_endpoint ~src ~dst |> result_map (N.ICMP.insert table ~expiry)

end
