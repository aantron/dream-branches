// This file is part of Dream, released under the MIT license. See LICENSE.md
// for details, or visit https://github.com/aantron/dream.
//
// Copyright 2021 Anton Bachin *)



var editor = document.querySelector("#textarea");
var button = document.querySelector("button");
var iframe = document.querySelector("iframe");
var pre = document.querySelector("pre");

var codemirror = CodeMirror(editor, {
  lineNumbers: true
});

var socket = new WebSocket("ws://" + window.location.host + "/socket");

socket.onopen = function () {
  socket.send(JSON.stringify(
    {"kind": "attach", "payload": window.location.pathname}));
};

socket.onmessage = function (e) {
  var message = JSON.parse(e.data);
  switch (message.kind) {
    case "content":
      codemirror.setValue(message.payload);
      break;
    case "log":
      pre.textContent += message.payload;
      break;
    case "started":
      // TODO Use a forced reload once there is proxying and the origin for
      // the iframe is the same.
      if (!iframe.src)
        iframe.src = window.location.href + "/";
      else
        iframe.src = iframe.src;
      break;
  }
};

button.onclick = function () {
  socket.send(JSON.stringify(
    {"kind": "run", "payload": codemirror.getValue()}));
};
