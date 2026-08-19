#!/bin/bash
# ダブルクリックで実行される入口。中身は scripts/setup.sh にある。
printf '\033]0;AI秘書\007'
cd "$(dirname "$0")" || exit 1
exec /bin/bash "./scripts/setup.sh"
