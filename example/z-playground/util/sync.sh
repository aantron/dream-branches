#!/bin/bash

HOST=$1

rm -rf sandbox
rsync -rlv . $HOST:playground
# ssh $HOST chmod a-x 'playground/*' 'playground/.*'
# ssh $HOST opam exec -- dune build playground/playground.exe
