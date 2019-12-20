#!/bin/bash
# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

source /usr/share/zimbra-scripts/lib/zimbra-common.inc.sh
source /usr/share/zimbra-scripts/lib/zimbra-api.inc.sh

# Help function
function exit_usage() {
  local status="${1}"

  cat <<USAGE

  ENVIRONMENT

    -p path
      Main path of the Zimbra installation
      [Default] ${_zimbra_main_path}

    -u user
      Zimbra UNIX user
      [Default] ${_zimbra_user}

    -g group
      Zimbra UNIX group
      [Default] ${_zimbra_group}

  OTHERS

    -d LEVEL
      Enable debug mode
      [Default] Disabled

      LEVEL can be:
        1
          Show debug messages
        2
          Show level 1 information plus Zimbra commands
        3
          Show level 2 information plus Bash commands (xtrace)

    -h
      Show this help
USAGE

  # Show help with -h
  if [ "${status}" -eq 0 ]; then
    trap - EXIT
  fi

  exit "${status}"
}

function getDaysBeforeZimbraCertExpiration() {
  local public_cert_path="${_zimbra_main_path}/ssl/zimbra/commercial/commercial.crt"
  local date_expiration=$(cat "${public_cert_path}" | openssl x509 -noout -enddate | cut -d= -f2 || true)
  local epoch_expiration=$(date -d "${date_expiration}" '+%s' || true)
  local epoch_now=$(date '+%s')
  local remaining_days=$(( (date_cert - date_today) / (24 * 3600) ))

  printf '%d' "${remaining_days}"
}

function zimbraStop() {
  systemctl stop zimbra
  _zimbra_stopped=true
}

function zimbraStart() {
  systemctl start zimbra
}


####################
## CORE FUNCTIONS ##
####################

# Called when the script quits
function trap_exit() {
  local status="${?}"
  local line="${1}"

  trap - EXIT TERM ERR INT

  if ${_zimbra_stopped}; then
    log_info "Starting Zimbra"
    zimbraStart
  else
    closeFastPrompts
  fi

  trap_common_exit "${status}" "${line}"
}

# Called by the common_exit trap when an error occured
function cleanFailedProcess() {
  log_debug "Cleaning after fail"
}

# Return true when the Let's Encrypt certificate has to be renewed
function letsencryptHasToBeRenewed() {
  local has_to_be_renewed=true

  if [ -d "${_zimbra_letsencrypt_path}" ]; then
    local remaining_days=$(getDaysBeforeZimbraCertExpiration || true)

    log_debug "The current Zimbra certificate expires in <${remaining_days}> days (max. is ${_max_number_of_days_before_expiration})"

    if [ "${remaining_days}" -ge "${_max_number_of_days_before_expiration}" ]; then
      has_to_be_renewed=false
    fi
  else
    log_debug "Zimbra Let's Encrypt path <${_zimbra_letsencrypt_path}> doesn't exist yet"
  fi

  ${has_to_be_renewed}
}

# Renew Let's Encrypt certificates and put them aside
function letsencryptRenew() {
  local newcerts_path="${_certbot_path}/${_server_hostname}"

  # Renew certificates
  certbot certonly -n -m "${_zimbra_admin_account}" --rsa-key-size "${_certbot_keysize}" --standalone --agree-tos\
    --preferred-challenges http -d "${_server_hostname}" -d "${_zimbra_main_domain}"

  # Copy new certificates aside
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_zimbra_letsencrypt_path}"
  find "${newcerts_path}" -name '*.pem$' -exec cp -a {} "${_zimbra_letsencrypt_path}" \;
}

# Create a Let's Encrupt CA Bundle that will be accepted by Zimbra
function letsencryptCreateCaBundle() {

  # Build the proper Intermediate CA plus Root CA, (CA Bundle)
  # https://wiki.zimbra.com/wiki/Installing_a_LetsEncrypt_SSL_Certificate
  # https://www.identrust.com/certificates/trustid/root-download-x3.html
  cat << EOF > "${_zimbra_letsencrypt_path}/ca_bundle.pem"
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

  cat "${_zimbra_letsencrypt_path}/chain.pem" >> "${_zimbra_letsencrypt_path}/ca_bundle.pem"
}

# Deploy Let's Encrypt certificates into Zimbra
function zimbraLetsencryptDeploy() {
  zimbraDeployCertificates\
    "${_zimbra_letsencrypt_path}/privkey.pem"\
    "${_zimbra_letsencrypt_path}/cert.pem"\
    "${_zimbra_letsencrypt_path}/ca_bundle.pem"
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=ZIMBRA-LETSENCRYPT
_zimbra_main_domain=
_zimbra_admin_account=
_zimbra_letsencrypt_path=
_zimbra_stopped=false
_server_hostname=
_certbot_path=/etc/letsencrypt/live/
_certbot_keysize=4096
_max_number_of_days_before_expiration=27
_debug_ask_stopping=yes

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

# Some default values are located in zimbra-common
while getopts 'p:u:g:d:h' opt; do
  case "${opt}" in
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
    d) _debug_mode="${OPTARG}" ;;
    h) exit_usage 0 ;;
    \?) exit_usage 1 ;;
  esac
done

_zimbra_letsencrypt_path="${_zimbra_main_path}/ssl/letsencrypt"

if [ "${_debug_mode}" -ge 3 ]; then
  set -o xtrace
fi


###################
### MAIN SCRIPT ###
###################

initFastPrompts

log_debug "Check expiration date of the current certificate"

if letsencryptHasToBeRenewed; then
  log_info "Zimbra has to get a fresh new Let's Encrypt certificate"
  log_info "Getting Zimbra main domain and admin email address"

  _zimbra_main_domain=$(zimbraGetMainDomain || true)
  _server_hostname=$(hostname --fqdn || true)
  log_debug "Zimbra main domain is <${_zimbra_main_domain}>"
  log_debug "Server hostname is <${_server_hostname}>"

  _zimbra_admin_account=$(zimbraGetAdminAccounts | head -n 1 || true)
  log_debug "Zimbra admin email address is <${_zimbra_admin_account}>"

  if [ "${_debug_mode}" -gt 0 ]; then
    _debug_ask_stopping=no
    read -p "Stop Zimbra (default: N)? " _debug_ask_stopping
    printf '\n'
  fi

  if [[ "${_debug_ask_stopping^^}" =~ ^Y(ES)?$ ]]; then
    log_info "Stopping Zimbra"
    closeFastPrompts
    zimbraStop

    log_info "Downloading of a new Let's Encrypt certificate"
    printf -- '---------------------------------------------------\n'
    letsencryptRenew
    printf -- '---------------------------------------------------\n'

    log_debug "Create a new CA bundle"
    letsencryptCreateCaBundle

    log_info "Deploying the new Let's Encrypt certificate into Zimbra"
    zimbraLetsencryptDeploy
  else
    log_debug "Canceled"
  fi
else
  log_info "Zimbra doesn't have to get a fresh Let's Encrypt certificate"
fi

showFullProcessDuration

exit 0
