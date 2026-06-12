#!/usr/bin/env sh
exec zig cc -fno-sanitize=undefined -fopenmp "$@"
