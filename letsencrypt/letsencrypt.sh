#!/bin/bash

# https://letsencrypt.org/how-it-works/
# https://certbot.eff.org/#centosrhel7-other
# https://wiki.zimbra.com/wiki/Installing_a_LetsEncrypt_SSL_Certificate

set -e

## TEST A LA MAIN: systemctl stop zimbra

# Demande & recuperation du certif (+ generation des cles d'auth la premiere fois)
certbot certonly -n -m admin@choca.pics --rsa-key-size 4096 --standalone --agree-tos --preferred-challenges http -d mail.choca.pics -d choca.pics

# Si le certif n'a pas change c'est qu'il n'etait pas a renew (moins de 30j)
if cmp -s /etc/letsencrypt/live/mail.choca.pics/privkey.pem /opt/zimbra/ssl/zimbra/commercial/commercial.key; then
  exit 0
fi

## TEST A LA MAIN: Certificat apparu dans /etc/letsencrypt/live/mail.choca.pics/
## TEST A LA MAIN: certbot certificates

# Copie en dehors du repertoire live du certbot
mkdir -p /opt/zimbra/ssl/letsencrypt/
cp /etc/letsencrypt/live/mail.choca.pics/*.pem /opt/zimbra/ssl/letsencrypt/
chown zimbra: /opt/zimbra/ssl/letsencrypt/*.pem

# https://www.identrust.com/certificates/trustid/root-download-x3.html
cat << EOF > /opt/zimbra/ssl/letsencrypt/properchain.pem
-----BEGIN CERTIFICATE-----
MIIDSjCCAjKgAwIBAgIQRK+wgNajJ7qJMDmGLvhAazANBgkqhkiG9w0BAQUFADA/
MSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT
DkRTVCBSb290IENBIFgzMB4XDTAwMDkzMDIxMTIxOVoXDTIxMDkzMDE0MDExNVow
PzEkMCIGA1UEChMbRGlnaXRhbCBTaWduYXR1cmUgVHJ1c3QgQ28uMRcwFQYDVQQD
Ew5EU1QgUm9vdCBDQSBYMzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
AN+v6ZdQCINXtMxiZfaQguzH0yxrMMpb7NnDfcdAwRgUi+DoM3ZJKuM/IUmTrE4O
rz5Iy2Xu/NMhD2XSKtkyj4zl93ewEnu1lcCJo6m67XMuegwGMoOifooUMM0RoOEq
OLl5CjH9UL2AZd+3UWODyOKIYepLYYHsUmu5ouJLGiifSKOeDNoJjj4XLh7dIN9b
xiqKqy69cK3FCxolkHRyxXtqqzTWMIn/5WgTe1QLyNau7Fqckh49ZLOMxt+/yUFw
7BZy1SbsOFU5Q9D8/RhcQPGX69Wam40dutolucbY38EVAjqr2m7xPi71XAicPNaD
aeQQmxkqtilX4+U9m5/wAl0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNV
HQ8BAf8EBAMCAQYwHQYDVR0OBBYEFMSnsaR7LHH62+FLkHX/xBVghYkQMA0GCSqG
SIb3DQEBBQUAA4IBAQCjGiybFwBcqR7uKGY3Or+Dxz9LwwmglSBd49lZRNI+DT69
ikugdB/OEIKcdBodfpga3csTS7MgROSR6cz8faXbauX+5v3gTt23ADq1cEmv8uXr
AvHRAosZy5Q6XkjEGB5YGV8eAlrwDPGxrancWYaLbumR9YbK+rlmM6pZW87ipxZz
R8srzJmwN0jP41ZL9c8PDHIyh8bwRLtTcm1D9SZImlJnt1ir/md2cXjbDaJWFBM5
JDGFoqgCWjBH4d1QB7wCCZAA62RjYJsWvIjJEubSfZGL+T0yjWW06XyxV3bqxbYo
Ob8VZRzI9neWagqNdwvYkQsEjgfbKbYK7p2CNTUQ
-----END CERTIFICATE-----
EOF

cat /opt/zimbra/ssl/letsencrypt/chain.pem >> /opt/zimbra/ssl/letsencrypt/properchain.pem

## TEST A LA MAIN: su zimbra -c '/opt/zimbra/bin/zmcertmgr verifycrt comm /opt/zimbra/ssl/letsencrypt/privkey.pem /opt/zimbra/ssl/letsencrypt/cert.pem /opt/zimbra/ssl/letsencrypt/properchain.pem'

# Deploiement dans zimbra
cp -a /opt/zimbra/ssl/zimbra/ "/opt/zimbra/ssl/zimbra.letsencrypt-$(date "+%Y%m%d%H%M%S")/"
cp /opt/zimbra/ssl/letsencrypt/privkey.pem /opt/zimbra/ssl/zimbra/commercial/commercial.key
chown zimbra: /opt/zimbra/ssl/zimbra/commercial/commercial.key
su zimbra -c '/opt/zimbra/bin/zmcertmgr deploycrt comm /opt/zimbra/ssl/letsencrypt/cert.pem /opt/zimbra/ssl/letsencrypt/properchain.pem'

## TEST A LA MAIN: systemctl start zimbra
