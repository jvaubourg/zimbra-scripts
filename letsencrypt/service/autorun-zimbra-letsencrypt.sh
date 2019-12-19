#!/bin/bash

set -eu

run_script=/usr/local/bin/zimbra-letsencrypt.sh

if [ -x "${run_script}" ]; then
  "${run_script}" &> /var/log/autorun-zimbra-letsencrypt.log
fi

exit 0
