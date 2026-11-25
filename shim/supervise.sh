#!/bin/bash
# /opt/gh-shim/supervise.sh <name> <command...>
# command が終了しても 1 秒後に起動し直す。出力は /var/log/gh-shim-<name>.log へ。
# ensure.sh が `pgrep -f "supervise.sh <name> "` で動いているか確かめる。
name=$1
shift
while :; do
  "$@" >>"/var/log/gh-shim-$name.log" 2>&1 </dev/null
  sleep 1
done
