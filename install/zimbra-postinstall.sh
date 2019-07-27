#!/bin/bash
# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -xeu

# Variables and functions with confidential information
# You have to fill it with real data
source ./zimbra-install_secrets.conf.sh

# Firewall
systemctl start firewalld

# Zimbra scripts
yum -y install git
pushd /usr/share/
  git clone https://github.com/jvaubourg/zimbra-scripts.git
popd
source /usr/share/zimbra-scripts/backups/zimbra-common.inc.sh

ln -s /usr/share/zimbra-scripts/backups/zimbra-backup.sh /usr/local/bin/
ln -s /usr/share/zimbra-scripts/backups/zimbra-restore.sh /usr/local/bin/

# Enable IPv6
cmd=(zmprov modifyServer "${HOSTNAME}.${MAIN_DOMAIN}" zimbraIPMode both)
execZimbraCmd cmd
cmd=("${ZIMBRA_PATH}/libexec/zmiptool")
execZimbraCmd cmd

# Logrotate
sed 's|/var/log/zimbra.log {|&\n    rotate 2|m' -i /etc/logrotate.d/zimbra
sed 's|sharedscripts|rotate 2\n    daily\n    &|m' -i /etc/logrotate.d/syslog

# Daily Reports without mail addresses
# (+ see https://bugzilla.zimbra.com/show_bug.cgi?id=107463)
cmd=(zmlocalconfig -e zimbra_mtareport_max_users=0)
execZimbraCmd cmd
cmd=(zmlocalconfig -e zimbra_mtareport_max_hosts=0)
execZimbraCmd cmd

# No service start/stop mails
sed '/Service status change/ { s/^/#/; n; s/^/#/ }' -i "${ZIMBRA_PATH}/conf/swatchrc.in"

# Redirect HTTP to HTTPS
cmd=(zmprov modifyServer "${HOSTNAME}.${MAIN_DOMAIN}" zimbraReverseProxyMailMode redirect)
execZimbraCmd cmd

# Cipher suites
# https://wiki.zimbra.com/wiki/How_to_obtain_an_A%2B_in_the_Qualys_SSL_Labs_Security_Test (add of !3DES)
#cmd=(zmdhparam set -new 4096)
cmd=(zmprov modifyConfig zimbraReverseProxySSLCiphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128:AES256:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4:!3DES')
execZimbraCmd cmd
cmd=(zmprov modifyConfig +zimbraResponseHeader 'Strict-Transport-Security: max-age=31536000')
execZimbraCmd cmd

# Mails max size (42 Mo)
max_size=$(( 42*1024*1024 ))
cmd=(zmprov modifyConfig zimbraFileUploadMaxSize "${max_size}")
execZimbraCmd cmd
cmd=(zmprov modifyConfig zimbraMailContentMaxSize "${max_size}")
execZimbraCmd cmd
cmd=(zmprov modifyConfig zimbraMtaMaxMessageSize "${max_size}")
execZimbraCmd cmd

# Do not block encrypted archives
cmd=(zmprov modifyConfig zimbraVirusBlockEncryptedArchive FALSE)
execZimbraCmd cmd

# Reboot
echo "You should now reboot the system"

exit 0
