(* TODO: types should be more complex and allow for entries mapping
   networks and port ranges (with logic disallowing many:many mappings), e.g.
   type One = port
   type Many = port list
   type mapping = [ One * One, One * Many, Many * One ]

   Doing this will cause us to need a real parser.
*)
open Mirage_nat

module Storage(Clock : Mirage_clock_lwt.MCLOCK)(Time: TIME) = struct

  type t = {
    store: ((protocol * mapping), (int64 * mapping)) Hashtbl.t;
    clock: Clock.t;
  }

  let reset t =
    Hashtbl.reset t.store;
    Lwt.return_unit

  let empty clock =
    (* initial size is completely arbitrary *)
    Lwt.return { store = Hashtbl.create 21; clock }

  let lookup t proto ~source ~destination =
    MProf.Trace.label "Mirage_nat_hashtable.lookup.read";
    match Hashtbl.mem t.store (proto, (source, destination)) with
    | false -> Lwt.return None
    | true ->
      Lwt.return (Some (Hashtbl.find t.store (proto, (source, destination))))

  (* cases that should result in a valid mapping:
     neither side is already mapped *)
  let insert t expiry_interval proto mappings =
    MProf.Trace.label "Mirage_nat_hashtable.insert";
    let check store proto pair =
      Hashtbl.mem store (proto, pair)
    in
    let internal_mem = check t.store proto mappings.internal_lookup in
    let external_mem = check t.store proto mappings.external_lookup in
    match internal_mem, external_mem with
    | true, true (* TODO: this is not quite right, because it's possible that
                        the lookups are part of differing pairs -- this
                        situation is pathological, but possible *)
    | false, false ->
      let expiration = Int64.add (Clock.elapsed_ns t.clock) expiry_interval in
      Hashtbl.add t.store (proto, mappings.internal_lookup) (expiration, mappings.internal_mapping);
      Hashtbl.add t.store (proto, mappings.external_lookup) (expiration, mappings.external_mapping);
      Lwt.return (Ok ())
    | _, _ -> Lwt.return (Error `Overlap)

  let delete t proto ~internal_lookup ~external_lookup =
    Hashtbl.remove t.store (proto, internal_lookup);
    Hashtbl.remove t.store (proto, external_lookup);
    Lwt.return_unit

end

module Make(Clock: CLOCK) (Time: TIME) = struct
  module Table = Storage(Clock)(Time)
  include Nat_rewrite.Make(Table)

  let empty = Table.empty
  let reset = Table.reset
end
