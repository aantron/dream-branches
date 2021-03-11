(* This file is part of Dream, released under the MIT license. See
   LICENSE.md for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)



let show_tokens route =
  try
    Dream_middleware.Router.parse route
    |> List.map (function
      | Dream_middleware.Router.Literal s -> Printf.sprintf "%S" s
      | Dream_middleware.Router.Variable s -> Printf.sprintf ":%S" s)
    |> String.concat "; "
    |> print_endline
  with Failure message ->
    print_endline message

let%expect_test _ =
  show_tokens "";
  show_tokens "abc";
  show_tokens "/";
  show_tokens "/abc";
  show_tokens "/abc/";
  show_tokens "/abc/def/";
  show_tokens "/abc//def/";
  show_tokens "//abc/def/";
  show_tokens "/abc/def//";
  show_tokens "/abc/:def/";
  show_tokens "/abc/:def";
  show_tokens "/:";
  show_tokens "/abc/:";
  show_tokens "/abc/:/";
  show_tokens "/abc/de:f/";
  [%expect {|
    Expected '/'
    Expected '/'
    ""
    "abc"
    "abc"; ""
    "abc"; "def"; ""
    Invalid route
    Invalid route
    Invalid route
    "abc"; :"def"; ""
    "abc"; :"def"
    Invalid route
    Invalid route
    Invalid route
    "abc"; "de:f"; "" |}]



let show ?(prefix = "/") ?(method_ = `GET) target router =
  try
    Dream.request ~method_ ~target ""
    |> Dream.test ~prefix
      (router @@ fun _ -> Dream.respond ~status:`Not_found "")
    |> fun response ->
      let status = Dream.status response
      and body = Lwt_main.run (Dream.body response)
      in
      Printf.printf "Response: %i %s\n"
        (Dream.status_to_int status) (Dream.status_to_string status);
      if body <> "" then
        Printf.printf "%s\n" body
      else
        ()
  with Failure message ->
    print_endline message

(* Basic router tests. *)

let%expect_test _ =
  show "/" @@ Dream.router [];
  [%expect {| Response: 404 Not Found |}]

let%expect_test _ =
  show "/" @@ Dream.router [
    Dream.get "/" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show "/abc" @@ Dream.router [
    Dream.get "/" (fun _ -> Dream.respond "foo");
  ];
  [%expect {| Response: 404 Not Found |}]

let%expect_test _ =
  show "/abc" @@ Dream.router [
    Dream.get "/abc" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show "/abc/" @@ Dream.router [
    Dream.get "/abc/" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show "/abc" @@ Dream.router [
    Dream.get "/abc" (fun _ -> Dream.respond "foo");
    Dream.get "/def" (fun _ -> Dream.respond "bar");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show "/def" @@ Dream.router [
    Dream.get "/abc" (fun _ -> Dream.respond "foo");
    Dream.get "/def" (fun _ -> Dream.respond "bar");
  ];
  [%expect {|
    Response: 200 OK
    bar |}]

(* Router matches long paths, does not match prefixes, etc. *)

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.get "/abc/def" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show "/abc" @@ Dream.router [
    Dream.get "/abc/def" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

(* Router distinguishes resources and directories. *)

let%expect_test _ =
  show "/abc" @@ Dream.router [
    Dream.get "/abc/" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

let%expect_test _ =
  show "/abc/" @@ Dream.router [
    Dream.get "/abc" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

(* Router respects methods. *)

let%expect_test _ =
  show ~method_:`POST "/abc" @@ Dream.router [
    Dream.post "/abc" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show ~method_:`POST "/abc" @@ Dream.router [
    Dream.get "/abc" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

let%expect_test _ =
  show "/abc" @@ Dream.router [
    Dream.post "/abc" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

(* Router matches and sets variables. *)

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.get "/abc/:x" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

let%expect_test _ =
  show "/abc/" @@ Dream.router [
    Dream.get "/abc/:x" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.get "/abc/:x" (fun request ->
      Dream.respond (Dream.crumb "x" request));
  ];
  [%expect {|
    Response: 200 OK
    def |}]

let%expect_test _ =
  show "/abc/def/ghi" @@ Dream.router [
    Dream.get "/abc/:x/:y" (fun request ->
      Dream.respond (Dream.crumb "x" request ^ Dream.crumb "y" request));
  ];
  [%expect {|
    Response: 200 OK
    defghi |}]

let%expect_test _ =
  show "/abc/def/ghi" @@ Dream.router [
    Dream.get "/abc/:x" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 404 Not Found |}]

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.get "/abc/def" (fun request ->
      Dream.respond (Dream.crumb "x" request));
  ];
  [%expect {|
    Invalid path parameter 'x' |}]

(* Router applies middlewares. *)

let%expect_test _ =

  let pipeline = Dream.pipeline [
    (fun next_handler request -> print_endline "foo"; next_handler request);
    (fun next_handler request -> print_endline "bar"; next_handler request);
  ] in

  show "/abc" @@ Dream.router [
    Dream.scope "/" [pipeline] [
      Dream.get "/abc" (fun _ -> Dream.respond "baz");
    ];
  ];
  [%expect {|
    foo
    bar
    Response: 200 OK
    baz |}]

let%expect_test _ =
  show "/" @@ Dream.router [
    Dream.scope "/" [
      (fun next_handler request -> print_endline "foo"; next_handler request);
      (fun next_handler request -> print_endline "bar"; next_handler request);
    ] [
      Dream.get "/abc" (fun _ -> Dream.respond "baz");
    ];
  ];
  [%expect {|
    Response: 404 Not Found |}]

(* Router respects site prefix. *)

let%expect_test _ =
  show ~prefix:"/abc" "/abc/def" @@ Dream.router [
    Dream.get "/def" (fun _ -> Dream.respond "foo");
  ];
  [%expect {|
    Response: 200 OK
    foo |}]

(* Subsites work. *)

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.scope "/abc" [] [
      Dream.get "/def" (fun request ->
        Dream.respond (Dream.prefix request ^ " " ^ Dream.path request));
    ];
  ];
  [%expect {|
    Response: 200 OK
    /abc /def |}]

let%expect_test _ =
  show "/def/abc" @@ Dream.router [
    Dream.scope "/abc" [] [
      Dream.get "/def" (fun request ->
        Dream.respond (Dream.prefix request ^ " " ^ Dream.path request));
    ];
  ];
  [%expect {|
    Response: 404 Not Found |}]

let%expect_test _ =
  show "/abc/ghi" @@ Dream.router [
    Dream.scope "/abc" [] [
      Dream.get "/def" (fun request ->
        Dream.respond (Dream.prefix request ^ " " ^ Dream.path request));
    ];
    Dream.get "/abc/ghi" (fun request ->
      Dream.respond (Dream.prefix request ^ " " ^ Dream.path request));
  ];
  [%expect {|
    Response: 200 OK
    / /abc/ghi |}]

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.scope "/:x" [] [
      Dream.get "/def" (fun request ->
        Dream.respond (Dream.crumb "x" request));
    ];
  ];
  [%expect {|
    Response: 200 OK
    abc |}]

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.scope "/:x" [] [
      Dream.get "/:x" (fun request ->
        Dream.respond (Dream.crumb "x" request));
    ];
  ];
  [%expect {|
    Response: 200 OK
    def |}]

let%expect_test _ =
  show "/abc/def" @@ Dream.router [
    Dream.scope "/abc" [
      (fun next_handler request -> print_endline "foo"; next_handler request);
      (fun next_handler request -> print_endline "bar"; next_handler request);
    ] [
      Dream.get "/def" (fun request ->
        Dream.respond (Dream.prefix request ^ " " ^ Dream.path request));
    ];
  ];
  [%expect {|
    foo
    bar
    Response: 200 OK
    /abc /def |}]

(* TODO Indirect nesting works. *)
(* TODO Try sequence of routers. *)