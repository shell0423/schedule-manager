#!/bin/bash
# ダブルクリックで実行される入口。中身は scripts/test_notify.sh にある。
printf '\033]0;AI秘書\007'
cd "$(dirname "$0")" || exit 1
exec /bin/bash "./scripts/test_notify.sh"
