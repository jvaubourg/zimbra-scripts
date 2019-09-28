#!/bin/bash

borg_server="${BACKUPSERVER_USER}@${BACKUPSERVER_DOMAIN}:${BACKUPSERVER_FOLDER}"
borg_folder="${MAILSERVER_ZIMBRA_PATH}_borg"

# Install Borg client
yum install epel-release
yum install borgbackup

# Create SSH key pair to connect to the backup server
install -b -m 0700 -o root -g root -d "${borg_folder}"
ssh-keygen -b 4096 -t rsa -f "${borg_folder}/ssh_key" -q -N ''

# Create main repo
export BORG_PASSPHRASE=$(openssl rand -base64 32)
export BORG_RSH="ssh -oBatchMode=yes -i ${borg_folder}/ssh_key -p ${BACKUPSERVER_SSH_PORT}"
borg init -e repokey "${borg_server}/main"

# Save main passphrase for future scripts and display SSH pub key
printf '%s' "${BORG_PASSPHRASE}" > "${borg_folder}/main_passphrase"

echo "SSH PUBLIC KEY TO PUT IN THE AUTHORIZED_KEYS FILE OF THE BACKUP SERVER"
echo "(VARIABLE {BACKUPSERVER_SSH_AUTHORIZEDKEY} OF SECRETS.CONF.SH)"
cat "${borg_folder}/ssh_key.pub"

exit 1
