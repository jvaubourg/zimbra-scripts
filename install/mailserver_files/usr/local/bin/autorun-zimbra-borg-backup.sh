#!/bin/bash

set -xeu

if [ -x /usr/local/bin/run-zimbra-borg-backup.sh ]; then
  /usr/local/bin/run-zimbra-borg-backup.sh &> /var/log/autorun-zimbra-borg-backup.log
fi

exit 0
