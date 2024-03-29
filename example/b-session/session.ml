let () =
  Dream.run
  @@ Dream.logger
  @@ Dream.memory_sessions
  @@ fun request ->

    match Dream.session "user" request with
    | None ->
      let%lwt () = Dream.invalidate_session request in
      let%lwt () = Dream.put_session "user" "alice" request in
      Dream.html "You weren't logged in; but now you are!"

    | Some username ->
      Printf.ksprintf
        Dream.html "Welcome back, %s!" (Dream.html_escape username)
