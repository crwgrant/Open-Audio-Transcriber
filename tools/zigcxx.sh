#!/usr/bin/env sh
exec zig c++ -fno-sanitize=undefined -fopenmp "$@"
