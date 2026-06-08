@echo off
zig c++ -target x86_64-windows-gnu -fno-sanitize=undefined %*
