MAILSERVER_FILES=/tmp/zimbra_scripts/install/mailserver_files
MAILSERVER_HOSTNAME=mail
MAILSERVER_MAIN_DOMAIN=example.com
declare -A MAILSERVER_USERS=(
  [jdoe]='ssh-rsa ...'
  [dsmith]='ssh-rsa ...'
)
MAILSERVER_WIRED_DEV=eth0
MAILSERVER_IPV6_ADDR=2001:db8::42
MAILSERVER_IPV6_CIDR=128
MAILSERVER_IPV4_ADDR=203.0.113.42
MAILSERVER_IPV4_CIDR=24
MAILSERVER_IPV4_GW=203.0.113.1
MAILSERVER_NET_UUID=213e29fb-73fc-5e4f-ab10-efde6c3518f8 # /etc/sysconfig/network-scripts/ifcfg-eth0
MAILSERVER_ZIMBRA_PATH=/opt/zimbra
MAILSERVER_BACKUP_OPTIONS="-s '.*/nobackup'" # Except -[azktr]
MAILSERVER_BORG_FOLDER=/opt/zimbra_borgbackup

function mailserver_set_admin_firewall() {
  # firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address="<ipv6>/128" port port="7071" protocol="tcp" accept'
  # firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<ipv4>/32" port port="7071" protocol="tcp" accept'
}

BACKUPSERVER_DOMAIN=backups.example.com
BACKUPSERVER_SSH_PORT=2222
BACKUPSERVER_USER=borg
BACKUPSERVER_FOLDER=zimbra_backups
BACKUPSERVER_SSH_AUTHORIZEDKEY='ssh-rsa ...'
