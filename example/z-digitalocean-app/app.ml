let () =
  Dream.run ~interface:"0.0.0.0"
  @@ Dream.logger
  @@ fun _ -> Dream.html "Good morning, world!"
