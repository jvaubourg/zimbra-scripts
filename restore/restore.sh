#!/bin/bash
# Julien Vaubourg <ju.vg> (2019)

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

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

  if [ ! -z "${_backuping_account}" -a -e "${_backuping_account}" ]
    log_debug "Removing failed account backup <${_backuping_account}>"
    rm -ir "${_backups_path}/accounts/${_backuping_account}"
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


#############
## RESTORE ##
#############

function zimbraRestoreDomains() {
  local backup_path="${_backups_path}/admin"

  while read domain; do
    if [ "${domain}" != "${_zimbra_install_domain}" ]; then
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
  fi

  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' -t 0 postRestURL --url https://localhost:8443 '/?fmt=tgz&resolve=reset' '${backup_path}/data.tgz'"
}

function zimbraRestoreFilters() {
  local email="${1:-}"
  local backup_path="${_backups_path}/accounts/${email}"

  zimbraSetFilters "${email}" "${backup_path}/filters"
}

function zimbraRestoreLists() {
  local backup_path="${_backups_path}/lists"
  local lists=$(ls "${backup_path}")
  
  for list in ${lists}; do
    zimbraAddList "${list}"

    while read member; do
      zimbraAddListMember "${list}" "${member}"
    done < "${backup_path}/${list}"
  done
}

function zimbraRestoreAliases() {
  local email="${1:-}"
  local backup_path="${_backups_path}/accounts/${email}"
  local aliases=$(extractFromSettings "${backup_path}" zimbraMailAlias)

  for alias in ${aliases}; do
    if [ "${alias}" != "root@${_zimbra_install_domain}" -a "${alias}" != "postmaster@${_zimbra_install_domain}" ]; then
      zimbraAddAlias "${email}" "${alias}"
    fi
  done
}


########################
### GLOBAL VARIABLES ###
########################

_exit_status=0
_zimbra_user='zimbra'
_zimbra_main_path='/opt/zimbra'
_backups_path='/tmp/backups'
_zimbra_install_domain='choca.pics'


##############
### SCRIPT ###
##############

trap 'trap_exit_error $LINENO' ERR

local accounts=$(ls "${_backups_path}/accounts")

zimbraRestoreDomains

for account in ${accounts}; do
  zimbraRestoreAccount "${account}"
  zimbraRestoreAliases "${account}"
  zimbraRestoreFilters "${account}"
done

zimbraRestoreLists

exit 0
