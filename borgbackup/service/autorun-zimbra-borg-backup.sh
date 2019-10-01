#!/bin/bash

set -xeu

run_script=/usr/local/bin/run-zimbra-borg-backup.sh

if [ -x "${run_script}" ]; then
  "${run_script}" &> /var/log/autorun-zimbra-borg-backup.log
fi

exit 0
