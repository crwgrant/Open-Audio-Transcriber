@echo off
zig cc -target x86_64-windows-gnu -fno-sanitize=undefined %*
