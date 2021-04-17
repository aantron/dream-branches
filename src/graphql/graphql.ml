(* This file is part of Dream, released under the MIT license. See
   LICENSE.md for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)



module Dream = Dream__pure.Inmost



(* This GraphQL handler supports two transports, i.e. two GraphQL "wire"
   protocols:

   - HTTP requests/responses for queries and mutations. See

       https://github.com/graphql/graphql-over-http/blob/main/spec/GraphQLOverHTTP.md

   - WebSockets for queries, mutations, and subscriptions. See

       https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md
       https://github.com/apollographql/subscriptions-transport-ws/blob/master/src/message-types.ts *)

let log =
  Dream__middleware.Log.sub_log "dream.graphql"



(* Shared between HTTP and WebSocket transport. *)

(* TODO Variables enum support? *)
let run_query make_context schema request json =
  let module Y = Yojson.Basic.Util in

  let query =          json |> Y.member "query" |> Y.to_string_option
  and operation_name = json |> Y.member "operationName" |> Y.to_string_option
  and variables =      json |> Y.member "variables" |> Option.some in

  match query with
  | None ->
    log.warning (fun log -> log ~request "No query");
    Lwt.return_none
  | Some query ->

  (* TODO Parse errors should likely be returned to the client. *)
  match Graphql_parser.parse query with
  | Error message ->
    log.warning (fun log -> log ~request "Query parser: %s" message);
    Lwt.return_none
  | Ok query ->

  (* TODO Consider being more strict here, allowing only `Assoc and `Null. *)
  let variables =
    match variables with
    | Some (`Assoc _ as json) ->
      (Yojson.Basic.Util.to_assoc json :>
        (string * Graphql_parser.const_value) list)
      |> Option.some
    | _ ->
      None
  in

  (* TODO Consider passing the variables and operation name to the
     context-maker. *)
  let%lwt context = make_context request in
  let%lwt result =
    Graphql_lwt.Schema.execute
      ?variables ?operation_name schema context query in
  Lwt.return (Some result)



(* WebSocket transport. *)

let operation_id json =
  Yojson.Basic.Util.(json |> member "id" |> to_string_option)

let close_and_clean subscriptions websocket =
  match%lwt Dream.close_websocket websocket with
  | _ ->
    Hashtbl.iter (fun _ close -> close ()) subscriptions;
    Lwt.return_unit
  | exception _ ->
    Hashtbl.iter (fun _ close -> close ()) subscriptions;
    Lwt.return_unit

let connection_message type_ =
  `Assoc [
    "type", `String type_;
  ]
  |> Yojson.Basic.to_string

let data_message type_ id payload =
  `Assoc [
    "type", `String type_;
    "id", `String id;
    "payload", payload
  ]
  |> Yojson.Basic.to_string

(* TODO What should be passed for creating the context for WebSocket
   transport? *)
(* TODO May need to do some actual validation of the client, etc. *)
(* TODO Once WebSocket streaming is properly supported, outgoing messages must
   be split into frames. Also, should there be a limit on incoming message
   size? *)
(* TODO Handle errors gracefully. *)
(* TODO Maybe message buffering should be built into Dream.send? Actually,
   writing this code as if concurrent writing already is supported. See
     https://github.com/aantron/dream/issues/34 *)
(* TODO Add Dream.any; use it in examples. *)
let handle_over_websocket make_context schema subscriptions request websocket =
  let rec loop () =
    match%lwt Dream.receive websocket with
    | None ->
      log.info (fun log -> log ~request "GraphQL WebSocket closed by client");
      close_and_clean subscriptions websocket
    | Some message ->

    (* TODO Avoid using exceptions here. *)
    match Yojson.Basic.from_string message with
    | exception _ ->
      log.warning (fun log -> log ~request "GraphQL message is not JSON");
      close_and_clean subscriptions websocket
    | json ->

    match Yojson.Basic.Util.(json |> member "type" |> to_string_option) with
    | None ->
      log.warning (fun log -> log  ~request "GraphQL message lacks a type");
      close_and_clean subscriptions websocket
    | Some message_type ->

    (* https://github.com/apollographql/subscriptions-transport-ws/blob/master/src/message-types.ts *)
    (* https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md#client---server *)
    match message_type with
    | "connection_init" ->
      let%lwt () = Dream.send (connection_message "connection_ack") websocket in
      loop ()

    | "connection_terminate" ->
      log.info (fun log ->
        log ~request "GraphQL WebSocket close requested by client");
      close_and_clean subscriptions websocket

    | "stop" ->
      begin match operation_id json with
      | None ->
        log.warning (fun log -> log ~request "GQL_STOP: operation id missing");
        close_and_clean subscriptions websocket
      | Some id ->
        begin match Hashtbl.find_opt subscriptions id with
        | None -> ()
        | Some close -> close ()
        end;
        loop ()
      end

    | "start" ->
      begin match operation_id json with
      | None ->
        log.warning (fun log -> log ~request "GQL_START: operation id missing");
        close_and_clean subscriptions websocket
      | Some id ->

        let payload = json |> Yojson.Basic.Util.member "payload" in

        Lwt.async begin fun () ->
          match%lwt run_query make_context schema request payload with
          | None ->
            close_and_clean subscriptions websocket

          | Some (Error _json) ->
            (* TODO Figure out the exact error representation, and report it to
               the client. *)
            close_and_clean subscriptions websocket

          | Some (Ok (`Response json)) ->
            let%lwt () = Dream.send (data_message "data" id json) websocket in
            loop ()

          | Some (Ok (`Stream (stream, close))) ->
            (* TODO Not sure if the pre-existing subscription with the same id
               should be just closed. Is that normal usage? *)
            match Hashtbl.mem subscriptions id with
            | true ->
              log.warning (fun log ->
                log ~request "GQL_START: duplicate operation id");
              close_and_clean subscriptions websocket
            | false ->

            Hashtbl.add subscriptions id close;

            (* TODO Error handling. *)
            let%lwt () =
              stream |> Lwt_stream.iter_s (function
                | Ok json ->
                  Dream.send (data_message "data" id json) websocket
                | Error _json ->
                  failwith "Not implemented")
            in

            (* TODO Need to send the actual id! *)
            Dream.send (connection_message "complete") websocket
        end;

        loop ()
      end

    | message_type ->
      log.warning (fun log ->
        log ~request "Unknown WebSocket message type '%s'" message_type);
      loop ()
  in

  loop ()



(* HTTP transport.

   Supports either POST requests carrying a GraphQL query, or GET requests
   carrying WebSocket upgrade headers. *)

(* TODO How to do some kind of client verification for WebSocket requests, given
   that the method is GET? *)
(* TODO A lot of Bad_Request responses should become Not_Found to leak less
   info. Or 200 OK? *)
let graphql make_context schema = fun request ->
  match Dream.method_ request with
  | `GET ->
    begin match Dream.header "Upgrade" request with
    | Some "websocket" ->
      Dream.websocket
        (handle_over_websocket make_context schema (Hashtbl.create 16) request)
    | _ ->
      log.warning (fun log -> log ~request "Upgrade: websocket header missing");
      Dream.empty `Bad_Request
    end

  | `POST ->
    begin match Dream.header "Content-Type" request with
    | Some "application/json" ->
      let%lwt body = Dream.body request in
      (* TODO This almost certainly raises exceptions... *)
      let json = Yojson.Basic.from_string body in

      begin match%lwt run_query make_context schema request json with
      | Some (Ok (`Response json)) ->
        Yojson.Basic.to_string json
        |> Dream.respond ~headers:["Content-Type", "application/json"]

      | _ ->
        (* TODO *)
        assert false
      end



(* TODO May want to escape the endpoint string. *)
let graphiql graphql_endpoint =
  let html =
    lazy begin
      Dream__graphiql.content
      |> Str.(global_replace (regexp (quote "%%ENDPOINT%%")) graphql_endpoint)
    end
  in

  fun _request ->
    Dream.respond (Lazy.force html)
