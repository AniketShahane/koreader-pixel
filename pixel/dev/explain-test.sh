#!/bin/bash
# Dev: long-press a point, wait for Claude, print the answer, save a screenshot.
#   explain-test.sh X Y out.png
K="$(dirname "$0")/ko"
$K lua 'local U=require("ui/uimanager"); for i=#U._window_stack,2,-1 do U:close(U._window_stack[i].widget) end return 1' >/dev/null
sleep 0.7
$K hold "$1" "$2" >/dev/null
sleep 1.5
for i in $(seq 1 40); do
  st=$($K lua 'local U=require("ui/uimanager"); return tostring(U._window_stack[#U._window_stack].widget.state)')
  case "$st" in *loading*) sleep 1;; *) break;; esac
done
$K lua 'local U=require("ui/uimanager"); local d=U._window_stack[#U._window_stack].widget; local r=d.result or {}; return "["..tostring(d.state).."] "..tostring(d.error or "").." "..tostring(r.headword).." | "..tostring(r.kind).."\n  M: "..tostring(r.meaning).."\n  H: "..tostring(r.here).."\n  D: "..tostring(r.deeper).."\n  R: "..table.concat(r.related or {},", ")'
sleep 0.5
$K shot "$3" >/dev/null
