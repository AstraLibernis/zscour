#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Mutation check: apply one textual break, run the tests with a timeout,
# restore the file. "SURVIVED" means no test noticed the break.
# usage: mutate.sh <file> <old> <new> <label>   — run from repo root
f=$1; bak=$(mktemp); cp "$f" "$bak"
python3 -I -c "import sys;p,o,n=sys.argv[1:];s=open(p).read();assert o in s;open(p,'w').write(s.replace(o,n,1))" "$f" "$2" "$3" || { echo "SETUP FAIL: $4"; rm "$bak"; exit; }
timeout 30 zig build test >/dev/null 2>&1; rc=$?
cp "$bak" "$f"; rm "$bak"
case $rc in 0) echo "SURVIVED: $4";; 124) echo "killed (timeout): $4";; *) echo "killed:   $4";; esac
