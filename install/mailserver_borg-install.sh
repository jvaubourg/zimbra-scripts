#!/bin/bash

set -xeu

# Variables and functions with confidential information
# You have to fill it with real data
source ./secrets.conf.sh

borg_server="${BACKUPSERVER_USER}@${BACKUPSERVER_DOMAIN}"

# Borg client
yum -y install epel-release
yum -y install borgbackup

# SSH key pair to connect to the backup server
file="${MAILSERVER_BORG_FOLDER}/ssh/ssh_key"

if [ ! -f "${file}" ]; then
  install -b -m 0700 -o root -g root -d "${MAILSERVER_BORG_FOLDER}/ssh"
  ssh-keygen -b 4096 -t rsa -f "${file}" -q -N ''

  ( set +x
    echo "1) EXEC NOW backupserver_borg-install.sh ON THE BACKUP SERVER WITH THE PUB KEY IN secrets.conf.sh/BACKUPSERVER_SSH_AUTHORIZEDKEY"
    echo "2) EXEC ssh -p ${BACKUPSERVER_SSH_PORT} ${borg_server} HERE JUST TO ACCEPT THE FINGERPRINT"
    echo "3) EXEC AGAIN THIS SCRIPT HERE TO FINISH THE INSTALL"
  )

  cat "${file}.pub"

  exit 0
fi

# Main repo creation
export BORG_PASSPHRASE=$(openssl rand -base64 32)
export BORG_RSH="ssh -oBatchMode=yes -i ${MAILSERVER_BORG_FOLDER}/ssh/ssh_key -p ${BACKUPSERVER_SSH_PORT}"
borg init -e repokey "${borg_server}:main"

# Passphrase of the main repo
printf '%s' "${BORG_PASSPHRASE}" > "${MAILSERVER_BORG_FOLDER}/main_repo_passphrase"

# Script to execute to run a full remote backup
file="${MAILSERVER_BORG_FOLDER}/run_backup.sh"

cat << EOF > "${file}"
#!/bin/bash

zimbra-borg-backup.sh\\
  -a ${borg_server}:main\\
  -z \$(cat ${MAILSERVER_BORG_FOLDER}/main_repo_passphrase)\\
  -k ${MAILSERVER_BORG_FOLDER}/ssh/ssh_key\\
  -t ${BACKUPSERVER_SSH_PORT}\\
  -r ${borg_server}:\\
  ${MAILSERVER_BACKUP_OPTIONS}
EOF

chmod +x "${file}"
ln -s "${file}" /usr/local/bin/run-zimbra-borg-backup.sh

# Save secrets in future backups
install -b -m 0700 -o root -g root -d "${MAILSERVER_BORG_FOLDER}/misc"
install -b -m 0600 -o root -g root ./secrets.conf.sh "${MAILSERVER_BORG_FOLDER}/misc"

exit 0
