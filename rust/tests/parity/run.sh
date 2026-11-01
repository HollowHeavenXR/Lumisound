#!/bin/sh
# run.sh <cases.json>: run cmp.py inside the isolated test network.
H=$(cd "$(dirname "$0")" && pwd)
exec docker run --rm --network lumi-test -v "$H":/w python:3.12-slim python -I /w/cmp.py "/w/$1"
