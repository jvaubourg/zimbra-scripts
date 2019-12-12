#!/bin/bash
# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -xeu

# Variables and functions with confidential information
# You have to fill it with real data
source ./secrets.conf.sh

function replace_placeholders() {
  local file="${1}"

  sed "s/<TPL:MAILSERVER_HOSTNAME>/${MAILSERVER_HOSTNAME}/g" -i "$file"
  sed "s/<TPL:MAILSERVER_MAIN_DOMAIN>/${MAILSERVER_MAIN_DOMAIN}/g" -i "$file"
  sed "s/<TPL:MAILSERVER_WIRED_DEV>/${MAILSERVER_WIRED_DEV}/g" -i "${file}"
  sed "s/<TPL:MAILSERVER_IPV6_ADDR>/${MAILSERVER_IPV6_ADDR}/g" -i "${file}"
  sed "s/<TPL:MAILSERVER_IPV6_CIDR>/${MAILSERVER_IPV6_CIDR}/g" -i "${file}"
  sed "s/<TPL:MAILSERVER_IPV4_ADDR>/${MAILSERVER_IPV4_ADDR}/g" -i "${file}"
  sed "s/<TPL:MAILSERVER_IPV4_CIDR>/${MAILSERVER_IPV4_CIDR}/g" -i "${file}"
  sed "s/<TPL:MAILSERVER_IPV4_GW>/${MAILSERVER_IPV4_GW}/g" -i "${file}"
  sed "s/<TPL:MAILSERVER_NET_UUID>/${MAILSERVER_NET_UUID}/g" -i "${file}"
}

function create_user() {
  local user="${1}"
  local user_pubkey="${MAILSERVER_USERS[$user]}"

  useradd "${user}" || true
  install -b -m 0700 -o "${user}" -g "${user}" -d "/home/${user}/.ssh"

  echo "${user_pubkey}" > "/home/${user}/.ssh/authorized_keys"
  chown "${user}:" "/home/${user}/.ssh/authorized_keys"
  chmod 0600 "/home/${user}/.ssh/authorized_keys"
}

# Users
for user in "${!MAILSERVER_USERS[@]}"; do
  create_user "${user}"
done

# Bash
file=/root/.bashrc
yum -y install screen
install -b -m 0644 -o root -g root "${MAILSERVER_FILES}${file}" "${file}"

# Hostname
file=/etc/hosts
install -b -m 0644 -o root -g root "${MAILSERVER_FILES}${file}" "${file}"
replace_placeholders "${file}"

hostnamectl --static set-hostname "${MAILSERVER_HOSTNAME}"
hostnamectl --pretty set-hostname "Mail ${MAILSERVER_MAIN_DOMAIN}"
# % hostname => mail
# % hostname -f => mail.example.com

# Network
file="/etc/sysconfig/network-scripts/ifcfg-${MAILSERVER_WIRED_DEV}"
install -b -m 0644 -o root -g root "${MAILSERVER_FILES}/etc/sysconfig/network-scripts/ifcfg-eth0" "${file}"
replace_placeholders "${file}"

# SSH
file=/etc/ssh/sshd_config
install -b -m 0600 -o root -g root "${MAILSERVER_FILES}${file}" "${file}"
systemctl restart sshd

# Firewall
yum -y install firewalld
systemctl enable firewalld
systemctl start firewalld

firewall-cmd --zone=public --add-service=https --permanent
firewall-cmd --zone=public --add-service=http --permanent
firewall-cmd --zone=public --add-port=465/tcp --permanent
firewall-cmd --zone=public --add-port=587/tcp --permanent
firewall-cmd --zone=public --add-service=smtp --permanent
firewall-cmd --zone=public --add-service=imaps --permanent
firewall-cmd --zone=public --add-port=2222/tcp --permanent
firewall-cmd --zone=public --remove-service=ssh --permanent

mailserver_set_admin_firewall # From _secrets
firewall-cmd --reload

# Automatic updates
yum -y install yum-cron

file=/etc/yum/yum-cron.conf
install -b -m 0600 -o root -g root "${MAILSERVER_FILES}${file}" "${file}"
replace_placeholders "${file}"

systemctl enable yum-cron
systemctl start yum-cron

# Prepare Zimbra install
yum -y install sudo libidn gmp perl perl-core nc htop
yum -y remove postfix
systemctl stop firewalld

# Root password
echo "New password for root:"
passwd root

# Install Zimbra
echo "You should now install Zimbra"

# https://zimbra.org/download/zimbra-collaboration
# LAST: https://files.zimbra.com/downloads/8.8.15_GA/zcs-8.8.15_GA_3869.RHEL7_64.20190918004220.tgz
#
# screen
# <zimbradir>/install.sh
#
# Use Zimbra's package repository [Y] Y
# Install zimbra-ldap [Y] Y
# Install zimbra-logger [Y] Y
# Install zimbra-mta [Y] Y
# Install zimbra-dnscache [Y] Y
# Install zimbra-snmp [Y] Y
# Install zimbra-store [Y] Y
# Install zimbra-apache [Y] Y
# Install zimbra-spell [Y] Y
# Install zimbra-memcached [Y] Y
# Install zimbra-proxy [Y] Y
# Install zimbra-drive [Y] N
# Install zimbra-imapd (BETA - for evaluation only) [N] N
# Install zimbra-chat [Y] N
#
# DNS ERROR resolving MX for mail.example.com
#  It is suggested that the domain name have an MX record configured in DNS
#  Change domain name? [Yes] Yes
#  Create domain: [mail.example.com] example.com
#
# tailf /tmp/install.log.*
#
# MENU: 7 > 4 > Change Admin Password > r > a
# tailf /tmp/zmsetup.*.log

exit 0
