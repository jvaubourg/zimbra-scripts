#!/bin/bash
# https://blog.karolak.fr/2017/05/05/monter-un-serveur-de-sauvegardes-avec-borgbackup/

backups_path="/home/${BACKUPSERVER_USER}/${BACKUPSERVER_FOLDER}"
ssh_authorized_cmd="command='cd ${backups_path}; borg serve --restrict-to-path ${backups_path}',no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc"

# Install Borg server
yum install epel-release
yum install borgbackup
useradd -rUm "${BACKUPSERVER_USER}"

# Create backups storage folder
install -b -m 0700 -o "${BACKUPSERVER_USER}" -g "${BACKUPSERVER_USER}" -d "${backups_path}"

# Allow the mailserver to access to the backup server
install -b -m 0700 -o "${BACKUPSERVER_USER}" -g "${BACKUPSERVER_USER}" -d "/home/${BACKUPSERVER_USER}/.ssh"
printf '%s\n' "${ssh_authorized_cmd} ${BACKUPSERVER_SSH_AUTHORIZEDKEY}" > "/home/${BACKUPSERVER_USER}/.ssh/authorized_keys"
chown "${BACKUPSERVER_USER}:" "/home/${BACKUPSERVER_USER}/.ssh/authorized_keys"
chmod 0600 "/home/${BACKUPSERVER_USER}/.ssh/authorized_keys"

exit 0
