FILES=/tmp/zimbra_scripts/install/files
HOSTNAME=mail
MAIN_DOMAIN=example.com
WIRED_DEV=eth0
IPV6_ADDR=2001:db8::42
IPV6_CIDR=128
IPV4_ADDR=203.0.113.42
IPV4_CIDR=24
IPV4_GW=203.0.113.1
NET_UUID=213e29fb-73fc-5e4f-ab10-efde6c3518f8 # Inside default /etc/sysconfig/network-scripts/ifcfg-eth0
ZIMBRA_PATH=/opt/zimbra

function create_users() {
  # create_user jdoe
}

function set_admin_firewall() {
  # firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address="<ipv6>/128" port port="7071" protocol="tcp" accept'
  # firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<ipv4>/32" port port="7071" protocol="tcp" accept'
}
