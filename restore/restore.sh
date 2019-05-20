#!/bin/bash
# Julien Vaubourg <ju.vg> (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

while getopts 'm:p:u:d:b:e:h' opt; do
function show_usage() {
  cat <<USAGE
  MAILBOXES
    -m email
      Email of the account to restore
      Default: All accounts

  ENVIRONMENT
    -b path
      Where the backups are
      Default: ${_backups_path}
    -p path
      Main path of the Zimbra installation
      Default: ${_zimbra_main_path}
    -u user
      Zimbra UNIX user
      Default: ${_zimbra_user}

  EXCLUSIONS
    -e TYPE
      Do a partial restoration, by excluding some settings/data.

      TYPE can be:
        aliases
          Do not backup email aliases
        domains
          Do not backup domains
        lists
          Do not backup mailing lists
        data
          Do not backup contents of the mailboxes
        filters
          Do not backup sieve filters
        settings
          Do not backup personal settings
        signatures
          Do not backup registred signatures

  OTHERS
    -h
      Show this help
USAGE

  exit 1
}

function log() { echo "$(date +'%F %R'): ${1}" }
function log_debug() { log "[DEBUG] ${1}" }
function log_info() { log "[INFO] ${1}" }
function log_warn() { log "[WARN] ${1}" }
function log_err() { log "[ERR] ${1}" }

function trap_exit_error() {
  log_err "There was an error on line ${1}"
  log_err "Restoration aborted"

  trap_cleaning
  exit 1
}

function trap_cleaning() {
  trap - ERR INT

  if [ ! -z "${_restoring_account}" -a -e "${_restoring_account}" ]
    log_debug "Removing incomplete account <${_restoring_account}>"
    zimbraDeleteAccount "${_restoring_account}"
  fi
}

function execZimbraCmd() {
  local cmd="${1:-}"
  export PATH="${PATH}:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec/"
  su "${_zimbra_user}" -c "${cmd}"
}

function extractFromSettings() {
  local backup_path="${1:-}"
  local field="${2:-}"
  local value=$((grep '^${field}:' "${backup_path}/settings" || true) | sed "s/^${field}: //")

  echo -n "${value}"
}


######################
## ZIMBRA CLI & API ##
######################

function zimbraGetMainDomain() {
  execZimbraCmd "zmprov gcf zimbraDefaultDomainName" | sed "s/^zimbraDefaultDomainName: //"
}

function zimbraAddDomain() {
  local domain="${1:-}"
  execZimbraCmd "zmprov createDomain '${domain}' zimbraAuthMech zimbra"
}

function zimbraAddList() {
  local list_email="${1:-}"
  execZimbraCmd "zmprov createDistributionList '${list_email}'"
}

function zimbraAddListMember() {
  local list_email="${1:-}"
  local member_email="${2:-}"
  execZimbraCmd "zmprov addDistributionListMember '${list_email}' '${member_email}'"
}

function zimbraAddAlias() {
  local email="${1:-}"
  local alias="${2:-}"
  execZimbraCmd "zmprov addAccountAlias '${email}' '${alias}'"
}

function zimbraSetFilters() {
  local email="${1:-}"
  local filters_path="${2:-}"
  local filters=$(sed "s/'//g" "${filters_path}")
  execZimbraCmd "zmprov modifyAccount '${email}' zimbraMailSieveScript '${filters}'"
}

function zimbraAddAccount() {
  local email="${1:-}"
  local cn="${2:-}"
  local givenName="${3:-}"
  local displayName="${4:-}"
  local hash_password="${5:-}"
  local tmp_password="${RANDOM}${RANDOM}"
  execZimbraCmd "zmprov createAccount '${email}' '${tmp_password}' cn '${cn}' displayName '${displayName}' givenName '${givenName}' zimbraPrefFromDisplay '${displayName}'"
  execZimbraCmd "zmprov modifyAccount '${email}' userPassword '${hash_password}'"
}

function zimbraDeleteAccount() {
  local email="${1:-}"
  execZimbraCmd "zmprov deleteAccount '${email}'"
}


#############
## RESTORE ##
#############

function zimbraRestoreDomains() {
  local backup_path="${_backups_path}/admin"

  while read domain; do
    if [ "${domain}" != "${_zimbra_install_domain}" ]; then
      log_debug "Creating domain <${domain}>"
      execZimbraCmd "zmprov createDomain '${domain}' zimbraAuthMech zimbra"
    fi
  done < "${backup_path}/domains"
}

function zimbraRestoreAccount() {
  local email="${1:-}"
  local backup_path="${_backups_path}/accounts/${email}"
  local cn=$(extractFromSettings "${backup_path}" cn)
  local givenName=$(extractFromSettings "${backup_path}" givenName)
  local displayName=$(extractFromSettings "${backup_path}" displayName)
  local userPassword=$(extractFromSettings "${backup_path}" userPassword)

  if [ "${email}" != "admin@${_zimbra_install_domain}" ]; then
    zimbraAddAccount "${email}" "${cn}" "${givenName}" "${displayName}" "${userPassword}"
  else
    log_debug "Skip account creation for <${email}>"
  fi
}

function zimbraRestoreAccountData() {
  local email="${1:-}"
  local backup_path="${_backups_path}/accounts/${email}"

  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' -t 0 postRestURL --url https://localhost:8443 '/?fmt=tgz&resolve=reset' '${backup_path}/data.tgz'"
}

function zimbraRestoreAccountFilters() {
  local email="${1:-}"
  local backup_path="${_backups_path}/accounts/${email}"

  zimbraSetFilters "${email}" "${backup_path}/filters"
}

function zimbraRestoreLists() {
  local backup_path="${_backups_path}/lists"
  local lists=$(ls "${backup_path}")
  
  for list in ${lists}; do
    log_debug "Create mailing list <${list}>"
    zimbraAddList "${list}"

    log_debug "Add members to the list <${list}>"
    while read member; do
      zimbraAddListMember "${list}" "${member}"
    done < "${backup_path}/${list}"
  done
}

function zimbraRestoreAccountAliases() {
  local email="${1:-}"
  local backup_path="${_backups_path}/accounts/${email}"
  local aliases=$(extractFromSettings "${backup_path}" zimbraMailAlias)

  for alias in ${aliases}; do
    if [ "${alias}" != "root@${_zimbra_install_domain}" -a "${alias}" != "postmaster@${_zimbra_install_domain}" ]; then
      zimbraAddAlias "${email}" "${alias}"
    else
      log_debug "Skip alias creation for <${email}>"
    fi
  done
}


########################
### GLOBAL VARIABLES ###
########################

_zimbra_user='zimbra'
_zimbra_main_path='/opt/zimbra'
_zimbra_install_domain='choca.pics'
_backups_path='/tmp/backups'
_account_to_restore=
_exclude_aliases=false
_exclude_domains=false
_exclude_lists=false
_exclude_data=false
_exclude_filters=false
_exclude_settings=false
_exclude_signatures=false


###############
### OPTIONS ###
###############

while getopts 'm:p:u:b:e:h' opt; do
  case "${opt}" in
    m) _account_to_restore="${OPTARG}" ;;
    p) _zimbra_main_path="${OPTARG}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    b) _backups_path="${OPTARG}" ;;
    e) case "${OPTARG}" in
         aliases) _exclude_aliases=true ;;
         domains) _exclude_domains=true ;;
         lists) _exclude_lists=true ;;
         data) _exclude_data=true ;;
         filters) _exclude_filters=true ;;
         settings) _exclude_settings=true ;;
         signatures) _exclude_signatures=true ;;
         *) log_err "Value <${OPTARG}> not supported by option -e"; show_usage ;;
       esac ;;
    h) show_usage ;;
    \?) exit_usage ;;
  esac
done

if ! [ -r "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist or is not readable"
  exit 1
fi

if ! [ -r "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist or is not readable"
  exit 1
fi


##############
### SCRIPT ###
##############

trap 'trap_exit_error $LINENO' ERR
trap trap_cleaning INT

_zimbra_install_domain=$(zimbraGetMainDomain)
log_debug "Zimbra main domain is <${_zimbra_install_domain}>"

accounts="${_account_to_restore}"

if [ -z "${accounts}" ]; then
  accounts=$(ls "${_backups_path}/accounts")
fi

${_exclude_domains} || {
  log_info "Restoring domains"
  zimbraRestoreDomains
}

for email in ${accounts}; do
  _restoring_account="${email}"

  log_info "Creating account <${email}>"
  zimbraRestoreAccount "${email}"

  ${_exclude_aliases} || {
    log_info "Restoring aliases to <${email}>"
    zimbraRestoreAccountAliases "${email}"
  }

  ${_exclude_filters} || {
    log_info "Restoring filters to <${email}>"
    zimbraRestoreAccountFilters "${email}"
  }

  ${_exclude_data} || {
    log_info "Restoring data to <${email}>"
    zimbraRestoreAccountData "${email}"
  }

  _restoring_account=
done

${_exclude_lists} || {
  log_info "Restoring mailing lists"
  zimbraRestoreLists
}

exit 0
