#!/bin/bash
# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -xeu

# Variables and functions with confidential information
# You have to fill it with real data
source ./secrets.conf.sh

# Firewall
systemctl start firewalld

# Zimbra scripts
yum -y install git
pushd /usr/share/
  git clone https://github.com/jvaubourg/zimbra-scripts.git
popd

source /usr/share/zimbra-scripts/lib/zimbra-common.inc.sh
source /usr/share/zimbra-scripts/lib/zimbra-exec.inc.sh

ln -s /usr/share/zimbra-scripts/backups/zimbra-backup.sh /usr/local/bin/
ln -s /usr/share/zimbra-scripts/backups/zimbra-restore.sh /usr/local/bin/
ln -s /usr/share/zimbra-scripts/borgbackup/zimbra-borg-backup.sh /usr/local/bin/
ln -s /usr/share/zimbra-scripts/borgbackup/zimbra-borg-restore.sh /usr/local/bin/

# Change Service Port
# https://wiki.zimbra.com/wiki/Steps_to_fix_port_redirection_problem_with_password_change_request_on_webclient
cmd=(zmprov modifyConfig zimbraPublicServiceHostname "${MAILSERVER_MAIN_DOMAIN}")
execZimbraCmd cmd
cmd=(zmprov modifyConfig zimbraPublicServiceProtocol https)
execZimbraCmd cmd
cmd=(zmprov modifyConfig zimbraPublicServicePort 443)
execZimbraCmd cmd

# Enable IPv6
cmd=(zmprov modifyServer "${MAILSERVER_HOSTNAME}.${MAILSERVER_MAIN_DOMAIN}" zimbraIPMode both)
execZimbraCmd cmd
cmd=("${MAILSERVER_ZIMBRA_PATH}/libexec/zmiptool")
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

# Disable Daily Reports
sed '/zmdailyreport/{s/^/#/}' -i /var/spool/cron/zimbra

# No service start/stop mails
sed '/Service status change/ { s/^/#/; n; s/^/#/ }' -i "${MAILSERVER_ZIMBRA_PATH}/conf/swatchrc.in"

# Redirect HTTP to HTTPS
cmd=(zmprov modifyServer "${MAILSERVER_HOSTNAME}.${MAILSERVER_MAIN_DOMAIN}" zimbraReverseProxyMailMode redirect)
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

# Default theme
cmd=(zmprov modifyCos Default zimbraFeatureSkinChangeEnabled FALSE)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraPrefSkin carbon)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraAvailableSkin carbon)
execZimbraCmd cmd

# Disable GAL
cmd=(zmprov modifyCos Default zimbraFeatureGalEnabled FALSE)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraFeatureGalAutoCompleteEnabled FALSE)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraFeatureGalSyncEnabled FALSE)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraGalSyncAccountBasedAutoCompleteEnabled FALSE)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraPrefGalAutoCompleteEnabled FALSE)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraPrefGalSearchEnabled FALSE)

# Authorize to send mails later
cmd=(zmprov modifyCos Default zimbraFeatureMailSendLaterEnabled TRUE)
execZimbraCmd cmd

# Time Zone
cmd=(zmprov modifyCos Default zimbraPrefTimeZoneId 'Europe/Brussels')
execZimbraCmd cmd

# Calendar config
cmd=(zmprov modifyCos Default zimbraPrefCalendarFirstDayOfWeek 1)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraPrefCalendarInitialView week)
execZimbraCmd cmd
cmd=(zmprov modifyCos Default zimbraPrefCalendarApptVisibility private)
execZimbraCmd cmd

# Disable Zimlets
cmd=(zmprov modifyCos Default zimbraFeatureManageZimlets FALSE)
execZimbraCmd cmd
cmd=(zmzimletctl disable com_zimbra_webex)
execZimbraCmd cmd
cmd=(zmzimletctl disable com_zimbra_ymemoticons)
execZimbraCmd cmd

# Do not send with Ctrl+Enter
cmd=(zmprov modifyCos Default zimbraPrefUseSendMsgShortcut FALSE)
execZimbraCmd cmd

# Do not block encrypted archives
cmd=(zmprov modifyConfig zimbraVirusBlockEncryptedArchive FALSE)
execZimbraCmd cmd

# Disable virus notifications to root
cmd=(zmprov modifyConfig zimbraVirusWarnAdmin FALSE)
execZimbraCmd cmd

# Restrict max number of recipients for 1 email (TO+CC+BCC)
cmd=(postconf -e 'smtpd_recipient_limit = 100')

# Zimbra-Borg-Backup scripts (do nothing if not installed)
service=autorun-zimbra-borg-backup

ln -s "/usr/share/zimbra-scripts/borgbackup/service/${service}.sh" /usr/local/bin/
ln -s "/usr/share/zimbra-scripts/borgbackup/service/${service}.service" /etc/systemd/system/
ln -s "/usr/share/zimbra-scripts/borgbackup/service/${service}.timer" /etc/systemd/system/

systemctl enable "${service}.timer"
systemctl start "${service}.timer"

# Reboot
echo "You should now reboot the system"

exit 0
