(* This file is part of Dream, released under the MIT license. See
   LICENSE.md for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)



(* Sandbox files. *)

let (//) = Filename.concat

let sandbox_root = "sandbox"

let starter_server_eml_ml = {|let () =
  Dream.run ~interface:"0.0.0.0"
  @@ Dream.logger
  @@ fun _ -> Dream.html "Good morning, world!"
|}

let sandbox_dune_project = {|(lang dune 2.0)
|}

let sandbox_dune = {|(executable
 (name server)
 (libraries dream)
 (preprocess (pps lwt_ppx)))

(rule
 (targets server.ml)
 (deps server.eml.ml)
 (action (run dream_eml %{deps} --workspace %{workspace_root})))
|}

let sandbox_dockerfile = {|FROM ubuntu:focal-20210416
RUN apt update && apt install -y openssl libev4
COPY _build/default/server.exe /server.exe
ENTRYPOINT /server.exe
|}

let write_file id file content =
  Lwt_io.(with_file ~mode:Output (sandbox_root // id // file) (fun channel ->
    write channel content))

let check_or_create id =
  let path = sandbox_root // id in
  if%lwt Lwt_unix.file_exists path then
    Lwt.return_unit
  else
    let%lwt () =
      match%lwt Lwt_unix.mkdir sandbox_root 0o755 with
      | () -> Lwt.return_unit
      | exception Unix.(Unix_error (EEXIST, _, _)) -> Lwt.return_unit
    in
    let%lwt () = Lwt_unix.mkdir path 0o755 in
    let%lwt () = write_file id "dune-project" sandbox_dune_project in
    let%lwt () = write_file id "dune" sandbox_dune in
    let%lwt () = write_file id "server.eml.ml" starter_server_eml_ml in
    let%lwt () = write_file id "Dockerfile" sandbox_dockerfile in
    Lwt.return_unit



(* Sandbox state transitions. *)

type container = {
  port : int;
}

type sandbox = {
  mutable id : string option;
  mutable container : container option;
  socket : Dream.websocket;
}

let sandbox_by_port =
  Hashtbl.create 256

let sandbox_by_id =
  Hashtbl.create 256

let min_port = 9000
let max_port = 9999

let next_port =
  ref min_port

(* This can fail if there is a huge number of sandboxes, or very large spikes in
   sandbox creation. However, the failure is not catastrophic. *)
let rec allocate_port () =
  let port = !next_port in
  incr next_port;
  let%lwt () =
    if !next_port > max_port then begin
      next_port := min_port;
      Lwt.pause ()
    end
    else
      Lwt.return_unit
  in
  if Hashtbl.mem sandbox_by_port port then
    allocate_port ()
  else
    Lwt.return port

let read sandbox =
  match sandbox.id with
  | None -> Lwt.return ""
  | Some id ->
    Lwt_io.(with_file ~mode:Input (sandbox_root // id // "server.eml.ml") read)

let validate_id id =
  String.length id = 12 && Dream.from_base64url id <> None

let build id =
  let command =
    Printf.ksprintf Lwt_process.shell
      "cd %s && opam exec -- dune build --root . ./server.exe 2>&1"
      (sandbox_root // id) in
  Lwt_process.pread command

let image id =
  let command =
    Printf.ksprintf Lwt_process.shell
      "cd %s && docker build -t sandbox:%s . 2>&1" (sandbox_root // id) id in
  Lwt_process.pread command

let forward ?(add_newline = false) sandbox message =
  let message =
    if add_newline then message ^ "\n"
    else message
  in
  `Assoc ["kind", `String "log"; "payload", `String message]
  |> Yojson.Basic.to_string
  |> fun message -> Dream.send message sandbox.socket

let started sandbox id =
  `Assoc ["kind", `String "started"; "payload", `String id]
  |> Yojson.Basic.to_string
  |> fun message -> Dream.send message sandbox.socket

let run sandbox id =
  let%lwt port = allocate_port () in
  Hashtbl.replace sandbox_by_port port sandbox;
  Hashtbl.replace sandbox_by_id id sandbox;
  sandbox.container <- Some {port};
  Lwt.async begin fun () ->
    Printf.ksprintf Lwt_process.shell
      "docker run -p 127.0.0.1:%i:8080 --name s-%s --rm sandbox:%s 2>&1"
      port id id
    |> Lwt_process.pread_lines
    |> Lwt_stream.iter_s (forward ~add_newline:true sandbox)
  end;
  Lwt.return_unit

let stop_container sandbox =
  match sandbox.id, sandbox.container with
  | Some id, Some container ->
    Printf.ksprintf Sys.command "docker kill s-%s" id |> ignore;
    Hashtbl.remove sandbox_by_port container.port;
    Hashtbl.remove sandbox_by_id id;
    Lwt.return_unit
  | _ -> Lwt.return_unit

(* TODO Forcibly stop after one second. *)
let stop sandbox =
  let%lwt () = stop_container sandbox in
  Dream.close_websocket sandbox.socket



(* Main loop for each connected client WebSocket. *)

(* TODO Mind concurrency issues with client messages coming during transitions.
   OTOH this code waits during those transitions anyway, so maybe it is not an
   issue. *)
let rec communicate sandbox =
  match%lwt Dream.receive sandbox.socket with
  | None -> stop sandbox
  | Some message ->
    let values =
      (* TODO Raises. *)
      match Yojson.Basic.from_string message with
      | `Assoc ["kind", `String kind; "payload", `String payload] ->
        Some (kind, payload)
      | _ ->
        None
    in
    match values with
    | None -> stop sandbox
    | Some (kind, payload) ->
      match kind, sandbox with

      | "attach", _ ->
        let payload = String.sub payload 1 (String.length payload - 1) in
        if not (validate_id payload) then stop sandbox
        else
          let id = payload in
          let%lwt () = check_or_create id in
          sandbox.id <- Some id;
          let%lwt content = read sandbox in
          let%lwt () =
            `Assoc ["kind", `String "content"; "payload", `String content]
            |> Yojson.Basic.to_string
            |> fun s -> Dream.send s sandbox.socket
          in
          communicate sandbox

      | "run", {id = Some id; _} ->
        let%lwt () = stop_container sandbox in
        let%lwt () = write_file id "server.eml.ml" payload in
        let%lwt output = build id in
        let%lwt () = forward sandbox output in
        let%lwt output = image id in
        (* let%lwt () = forward sandbox output in *)
        ignore output;
        let%lwt () = run sandbox id in
        let%lwt () = Lwt_unix.sleep 0.25 in
        let%lwt () = started sandbox id in
        communicate sandbox

      | _ -> stop sandbox



(* Ugly code for forwarding requests. Should be replaced by a Dream-like client
   abstraction. *)

let forward_request id request =
  match Hashtbl.find_opt sandbox_by_id id with
  | None -> Dream.empty `Not_Found
  | Some sandbox ->

  match sandbox.container with
  | None -> Dream.empty `Not_Found
  | Some container ->

  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  let%lwt () =
    Lwt_unix.connect
      socket Unix.(ADDR_INET (inet_addr_loopback, container.port)) in
  let%lwt connection = Httpaf_lwt_unix.Client.create_connection socket in

  let httpaf_request = Httpaf.Request.{
    meth =
      Dream.method_ request
      |> Dream.method_to_string
      |> Httpaf.Method.of_string;
    target = String.concat "/" (""::(Dream.path request));
    version = {major = 1; minor = 1};
    headers =
      Dream.all_headers request
      |> Httpaf.Headers.of_list;
  } in

  let response, respond = Lwt.wait () in

  (* TODO Better error handling. *)
  (* TODO Flow control, or make sure it exists upstream in Dream. *)
  let error_handler _ =
    Dream.response
      ~status:`Bad_Gateway
      ~headers:["Content-Type", "text/plain"]
      "HTTP error while forwarding to sandbox"
    |> Lwt.wakeup_later respond in

  let response_handler (httpaf_response : Httpaf.Response.t) body =
    let status =
      httpaf_response.status
      |> Httpaf.Status.to_code
      |> Dream.int_to_status
    in
    let headers = Httpaf.Headers.to_list httpaf_response.headers in
    let response =
      Dream.response ~status ~headers ""
      |> Dream.with_stream
    in
    Lwt.wakeup_later respond response;

    let rec forward_response_body () : unit =
      Httpaf.Body.schedule_read body
        ~on_eof:(fun () ->
          ignore @@
            (let%lwt () = Dream.close_stream response in
            let%lwt () = Httpaf_lwt_unix.Client.shutdown connection in
            Lwt.return_unit))
        ~on_read:(fun buffer ~off ~len ->
          ignore @@
            (let%lwt () = Dream.write_bigstring buffer off len response in
            forward_response_body ();
            Lwt.return_unit))
    in
    forward_response_body ()
  in

  let request_body =
    Httpaf_lwt_unix.Client.request
      connection httpaf_request ~error_handler ~response_handler in

  let rec forward_request_body () =
    match%lwt Dream.read request with
    | None ->
      Httpaf.Body.close_writer request_body;
      Lwt.return_unit
    | Some chunk ->
      Httpaf.Body.write_string request_body chunk;
      forward_request_body ()
  in
  let%lwt () = forward_request_body () in

  response



(* The Web server proper. *)

let () =
  Dream.run ~interface:"0.0.0.0" ~port:80 ~adjust_terminal:false
  @@ Dream.logger
  @@ Dream.router [

    (* Generate a fresh valid id for new visitors, and redirect. *)
    Dream.get "/" (fun _ ->
      Dream.random 9
      |> Dream.to_base64url
      |> (^) "/"
      |> Dream.redirect);

    (* Apply function communicate to WebSocket connections. *)
    Dream.get "/socket" (fun _ ->
      Dream.websocket (fun socket -> communicate {
        id = None;
        container = None;
        socket;
      }));

    (* For sandbox ids, respond with the sandbox page. *)
    Dream.get "/:id" (fun request ->
      if not (validate_id (Dream.param "id" request)) then
        Dream.empty `Not_Found
      else
        let%lwt response =
          Dream__middleware.Static.default_loader
            "static" "index.html" request in
        let response : Dream.response = Obj.magic response in
        Dream.with_header "Content-Type" "text/html; charset=utf-8" response
        |> Lwt.return);

    (* Forward requests to sandboxes. *)
    Dream.any "/:id/**" (fun request ->
      let id = Dream.param "id" request in
      if not (validate_id id) then
        Dream.empty `Not_Found
      else
        forward_request id request);

  ]
  @@ Dream.not_found
