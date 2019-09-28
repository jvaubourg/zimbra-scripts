#!/bin/bash

set -xeu

# Variables and functions with confidential information
# You have to fill it with real data
source ./secrets.conf.sh

borg_server="${BACKUPSERVER_USER}@${BACKUPSERVER_DOMAIN}"

# Install Borg client
yum -y install epel-release
yum -y install borgbackup

# Create SSH key pair to connect to the backup server
if [ ! -f "${MAILSERVER_BORG_FOLDER}/ssh/ssh_key" ]; then
  install -b -m 0700 -o root -g root -d "${MAILSERVER_BORG_FOLDER}/ssh"
  ssh-keygen -b 4096 -t rsa -f "${MAILSERVER_BORG_FOLDER}/ssh/ssh_key" -q -N ''

  ( set +x
    echo "1) EXEC NOW backupserver_borg-install.sh ON THE BACKUP SERVER WITH THE PUB KEY IN secrets.conf.sh/BACKUPSERVER_SSH_AUTHORIZEDKEY"
    echo "2) EXEC ssh -p ${BACKUPSERVER_SSH_PORT} ${borg_server} HERE JUST TO ACCEPT THE FINGERPRINT"
    echo "3) EXEC AGAIN THIS SCRIPT HERE TO FINISH THE INSTALL"
  )

  cat "${MAILSERVER_BORG_FOLDER}/ssh/ssh_key.pub"

  exit 0
fi

# Create main repo
export BORG_PASSPHRASE=$(openssl rand -base64 32)
export BORG_RSH="ssh -oBatchMode=yes -i ${MAILSERVER_BORG_FOLDER}/ssh/ssh_key -p ${BACKUPSERVER_SSH_PORT}"
borg init -e repokey "${borg_server}:main"

# Save main passphrase for next scripts
printf '%s' "${BORG_PASSPHRASE}" > "${MAILSERVER_BORG_FOLDER}/main_repo_passphrase"

exit 0
