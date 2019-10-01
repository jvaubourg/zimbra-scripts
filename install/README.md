# Install Zimbra backup and restore scripts

To execute the scripts, you have to be inside the _install/_ folder of your clone.

## Install Zimbra itself

Pre and post install scripts for Zimbra are a bit beyond the backup and restore purpose, the most related part is the git clone in post-installation.

On your mail server:

1. Fill out settings in _secrets.conf.sh_.

2. Execute _mailserver_zimbra-preinstall.sh_.

3. Install Zimbra from its tarball.

4. Execute _mailserver_zimbra-postinstall.sh_.

## Install local backup and restore scripts

Zimbra has to be installed before (see above).

On your mail server:

1. Execute _mailserver_borg-install.sh_.

2. Backup _/opt/zimbra_borgbackup/main_repo_passphrase_ now on your own laptop.

## Install remote backup and restore scripts

Local backup and restore scripts have to be installed before (see above).

On your mail server (Borg client):

1. Execute _mailserver_borg-install.sh_.

On your backup server (Borg server):

1. Execute _backupserver_borg-install.sh_.
