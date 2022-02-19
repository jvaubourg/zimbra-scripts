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

  LETSENCRYPT

    -m email
      Email address to pass to the Let's Encrypt service
      [Default] First Zimbra admin account

    -k keysize
      RSA key size for generated certificates
      [Default] ${_certbot_keysize}

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
  local remaining_days=$(( (epoch_expiration - epoch_now) / (24 * 3600) ))

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
  certbot certonly -n -m "${_certbot_email}" --rsa-key-size "${_certbot_keysize}" --standalone --agree-tos\
    --preferred-challenges http -d "${_server_hostname}" -d "${_zimbra_main_domain}"

  # Copy new certificates aside
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${_zimbra_letsencrypt_path}"
  find "${newcerts_path}" -name '*.pem' -exec cp --dereference {} "${_zimbra_letsencrypt_path}" \;
}

# Create a Let's Encrupt CA Bundle that will be accepted by Zimbra
function letsencryptCreateCaBundle() {

  # Build the proper Intermediate CA plus Root CA, (CA Bundle)
  # https://wiki.zimbra.com/wiki/Installing_a_LetsEncrypt_SSL_Certificate
  # https://www.identrust.com/certificates/trustid/root-download-x3.html
  # https://letsencrypt.org/certificates/
  #   https://letsencrypt.org/certs/isrgrootx1.pem
  cat << EOF > "${_zimbra_letsencrypt_path}/ca_bundle.pem"
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
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

_log_id=Z-LETSENCRYPT
_zimbra_main_domain=
_zimbra_letsencrypt_path=
_zimbra_stopped=false
_server_hostname=
_certbot_path=/etc/letsencrypt/live/
_certbot_keysize=4096
_certbot_email=
_max_number_of_days_before_expiration=27
_debug_ask_stopping=yes

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

# Some default values are located in zimbra-common
while getopts 'm:k:p:u:g:d:h' opt; do
  case "${opt}" in
    m) _certbot_email="${OPTARG%/}" ;;
    k) _certbot_keysize="${OPTARG%/}" ;;
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

  log_info "Getting Zimbra main domain"
  _zimbra_main_domain=$(zimbraGetMainDomain || true)
  _server_hostname=$(hostname --fqdn || true)
  log_debug "Zimbra main domain is <${_zimbra_main_domain}>"
  log_debug "Server hostname is <${_server_hostname}>"

  if [ -z "${_certbot_email}" ]; then
    log_info "Getting first Zimbra admin email account"
    _certbot_email=$(zimbraGetAdminAccounts | head -n 1 || true)
    log_info "Email address <${_certbot_email}> will be passed to the Let's Encrypt service"
  fi

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
    zimbraLetsencryptDeploy || true
  else
    log_debug "Canceled"
  fi

else
  log_info "Zimbra doesn't have to get a fresh Let's Encrypt certificate"

  exit 2
fi

if letsencryptHasToBeRenewed; then
  exit 1
fi

showFullProcessDuration

exit 0
