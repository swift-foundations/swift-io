#!/bin/sh
# Build the container and run the experiment.
# --privileged is needed so io_uring_setup syscalls are permitted.
set -e
cd "$(dirname "$0")"
docker build -t proactor-buffer-ownership .
docker run --rm --privileged proactor-buffer-ownership
