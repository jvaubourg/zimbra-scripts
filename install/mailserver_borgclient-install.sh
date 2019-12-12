#!/bin/bash

set -xeu

# Variables and functions with confidential information
# You have to fill it with real data
source ./secrets.conf.sh

borg_server="${BACKUPSERVER_USER}@${BACKUPSERVER_DOMAIN}"

# Borg client
yum -y install epel-release
yum -y install lzma borgbackup

# SSH key pair to connect to the backup server
file="${MAILSERVER_BORG_FOLDER}/ssh/ssh_key"

if [ ! -f "${file}" ]; then
  install -b -m 0700 -o root -g root -d "${MAILSERVER_BORG_FOLDER}/ssh"
  ssh-keygen -b 4096 -t rsa -f "${file}" -q -N ''

  ( set +x
    echo
    echo "1) EXEC NOW backupserver_borg-install.sh ON THE BACKUP SERVER WITH THE PUB KEY IN secrets.conf.sh/BACKUPSERVER_SSH_AUTHORIZEDKEY"
    echo
    echo "2) COME BACK HERE AND EXEC AGAIN THIS SCRIPT TO FINISH THE INSTALL"
    echo
  )

  cat "${file}.pub"

  exit 0
fi

# SSH connection doing nothing but here to force the admin to accept the remote fingerprint
ssh -i "${MAILSERVER_BORG_FOLDER}/ssh/ssh_key" -p "${BACKUPSERVER_SSH_PORT}" "${borg_server}" 'borg info -h' > /dev/null

# Main repo creation
export BORG_PASSPHRASE=$(openssl rand -base64 32)
export BORG_RSH="ssh -oBatchMode=yes -i ${MAILSERVER_BORG_FOLDER}/ssh/ssh_key -p ${BACKUPSERVER_SSH_PORT}"
borg init -e repokey "${borg_server}:main"

# Passphrase of the main repo
install -b -m 0700 -o root -g root -d "${MAILSERVER_BORG_FOLDER}/secrets"
printf '%s' "${BORG_PASSPHRASE}" > "${MAILSERVER_BORG_FOLDER}/secrets/main_repo_passphrase"

# Save secrets conf file
install -b -m 0600 -o root -g root ./secrets.conf.sh "${MAILSERVER_BORG_FOLDER}/secrets/"

# Script to execute to run a full remote backup
file="${MAILSERVER_BORG_FOLDER}/bin/run_backup.sh"

install -b -m 0700 -o root -g root -d "${MAILSERVER_BORG_FOLDER}/bin"

cat << EOF > "${file}"
#!/bin/bash

set -xeu
source "${MAILSERVER_BORG_FOLDER}/secrets/secrets.conf.sh"

zimbra-borg-backup.sh\\
  -a "\${BACKUPSERVER_USER}@\${BACKUPSERVER_DOMAIN}:main"\\
  -z "\$(cat "${MAILSERVER_BORG_FOLDER}/secrets/main_repo_passphrase")"\\
  -k "${MAILSERVER_BORG_FOLDER}/ssh/ssh_key"\\
  -t "\${BACKUPSERVER_SSH_PORT}"\\
  -r "\${BACKUPSERVER_USER}@\${BACKUPSERVER_DOMAIN}:"\\
  \${MAILSERVER_BACKUP_OPTIONS}
EOF

chmod 0700 "${file}"
ln -s "${file}" /usr/local/bin/run-zimbra-borg-backup.sh

# Script to execute to restore everything on a *fresh* Zimbra
file="${MAILSERVER_BORG_FOLDER}/bin/run_restore.sh"

cat << EOF > "${file}"
#!/bin/bash

set -xeu
source "${MAILSERVER_BORG_FOLDER}/secrets/secrets.conf.sh"

zimbra-borg-restore.sh\\
  -a "\${BACKUPSERVER_USER}@\${BACKUPSERVER_DOMAIN}:main"\\
  -z "\$(cat "${MAILSERVER_BORG_FOLDER}/secrets/main_repo_passphrase")"\\
  -k "${MAILSERVER_BORG_FOLDER}/ssh/ssh_key"\\
  -t "\${BACKUPSERVER_SSH_PORT}"
EOF

chmod 0700 "${file}"
ln -s "${file}" /usr/local/bin/run-zimbra-borg-restore.sh

exit 0
