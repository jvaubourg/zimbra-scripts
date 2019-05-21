#!/bin/bash
# Julien Vaubourg <ju.vg> (2019)
# https://github.com/jvaubourg/zimbra-scripts

set -o errtrace
set -o pipefail
set -o nounset


#############
## HELPERS ##
#############

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
    -e ASSET
      Do a partial restoration, by excluding some settings/data.
      Repeat this option as many times as necessary to exclude more than only one asset.
      Default: None
      Example: -e domains -e data

      ASSET can be:
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
    -d LEVEL
      Debug mode
      Default: Disabled

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

  exit 1
}

function log() { echo "$(date +'%F %R'): ${1}" }
function log_debug() { [ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" }
function log_info() { log "[INFO] ${1}" }
function log_warn() { log "[WARN] ${1}" }
function log_err() { log "[ERR] ${1}" }

function trap_exit() {
  local status=$?
  local error=${1}

  trap - EXIT ERR INT

  if [ "${status}" -ne 0 ]; then
    log_err "There was an error on line ${1}"
    log_err "Restoration aborted"

    cleanFailedRestoration
  else
    log_info "Restoration done"
  fi

  exit "${status}"
}

function cleanFailedRestoration() {
  if ! [ -z "${_restoring_account}" ]; then
    log_debug "Removing incomplete account <${_restoring_account}>"
    zimbraDeleteAccount "${_restoring_account}"
  fi
}

function execZimbraCmd() {
  local cmd="${1}"
  export PATH="${PATH}:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec/"

  if [ "${_debug_mode}" -ge 2 ]; then
    log_debug "CMD: ${cmd}"
  fi

  su "${_zimbra_user}" -c "${cmd}"
}

function extractFromSettings() {
  local email="${1}"
  local field="${2}"
  local settings_file="${_backups_path}/accounts/${email}/settings"

  if ! [ -f "${settings_file}" -a -r "${settings_file}" ]; then
    log_err "File <${settings_file}> doesn't exist, is not a regular file or is not readable or reachable"
    exit 1
  fi

  local value=$((grep '^${field}:' "${settings_file}" || true) | sed "s/^${field}: //")

  echo -n "${value}"
}


######################
## ZIMBRA CLI & API ##
######################

function zimbraGetMainDomain() {
  execZimbraCmd "zmprov gcf zimbraDefaultDomainName" | sed "s/^zimbraDefaultDomainName: //"
}

function zimbraAddDomain() {
  local domain="${1}"
  execZimbraCmd "zmprov createDomain '${domain}' zimbraAuthMech zimbra"
}

function zimbraAddList() {
  local list_email="${1}"
  execZimbraCmd "zmprov createDistributionList '${list_email}'"
}

function zimbraAddListMember() {
  local list_email="${1}"
  local member_email="${2}"

  execZimbraCmd "zmprov addDistributionListMember '${list_email}' '${member_email}'"
}

function zimbraAddAlias() {
  local email="${1}"
  local alias="${2}"

  execZimbraCmd "zmprov addAccountAlias '${email}' '${alias}'"
}

function zimbraSetFilters() {
  local email="${1}"
  local filters_path="${2}"
  local filters=$(cat "${filters_path}")

  execZimbraCmd "zmprov modifyAccount '${email}' zimbraMailSieveScript \"${filters}\""
}

function zimbraAddAccount() {
  local email="${1}"
  local cn="${2}"
  local givenName="${3}"
  local displayName="${4}"
  local hash_password="${5}"
  local tmp_password="${RANDOM}"

  execZimbraCmd "zmprov createAccount '${email}' '${tmp_password}' cn '${cn}' displayName '${displayName}' givenName '${givenName}' zimbraPrefFromDisplay '${displayName}'"
  execZimbraCmd "zmprov modifyAccount '${email}' userPassword '${hash_password}'"
}

function zimbraDeleteAccount() {
  local email="${1}"
  execZimbraCmd "zmprov deleteAccount '${email}'"
}

function zimbraCreateSignature() {
  local email="${1}"
  local name="${2}"
  local type="${3}"
  local content="${4}"
  local field=zimbraPrefMailSignature

  if [ "${type}" = html ]; then
    field=zimbraPrefMailSignatureHTML
  fi

  execZimbraCmd "zmprov createSignature '${email}' '${name}' ${field} \"${content}\""
}


#############
## RESTORE ##
#############

function zimbraRestoreDomains() {
  local backup_path="${_backups_path}/admin"
  local backup_file="${backup_path}/domains"

  if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
    log_err "File <${backup_file}> doesn't exist, is not a regular file or is not readable or reachable"
    exit 1
  fi

  while read domain; do
    if [ "${domain}" != "${_zimbra_install_domain}" ]; then
      log_debug "Creating domain <${domain}>"
      execZimbraCmd "zmprov createDomain '${domain}' zimbraAuthMech zimbra"
    else
      log_debug "Skip domain creation for <$domain>"
    fi
  done < "${backup_file}"
}

function zimbraRestoreAccount() {
  local email="${1}"
  local cn=$(extractFromSettings "${email}" cn)
  local givenName=$(extractFromSettings "${email}" givenName)
  local displayName=$(extractFromSettings "${email}" displayName)
  local userPassword=$(extractFromSettings "${email}" userPassword)

  if [ "${email}" != "admin@${_zimbra_install_domain}" ]; then
    zimbraAddAccount "${email}" "${cn}" "${givenName}" "${displayName}" "${userPassword}"
  else
    log_debug "Skip account creation for <${email}>"
  fi
}

function zimbraRestoreAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tgz"

  if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
    log_err "File <${backup_file}> doesn't exist, is not a regular file or is not regular or reachable"
    exit 1
  fi

  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' -t 0 postRestURL --url https://localhost:8443 '/?fmt=tgz&resolve=reset' '${backup_path}'"
}

function zimbraRestoreAccountFilters() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/filters"

  if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
    log_err "File <${backup_file}> doesn't exist, is not a regular file or is not regular or reachable"
    exit 1
  fi

  zimbraSetFilters "${email}" "${backup_path}"
}

function zimbraRestoreLists() {
  local backup_path="${_backups_path}/lists"
  local lists=$(ls "${backup_path}")

  for list_email in ${lists}; do
    local backup_file="${backup_path}/${list_email}"

    if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
      log_err "File <${backup_file}> doesn't exist, is not a regular file or is not readable or reachable"
      exit 1
    fi

    log_debug "Create mailing list <${list_email}>"
    zimbraAddList "${list_email}"

    while read member_email; do
      log_debug "Add <${member_email}> to the list <${list_email}>"
      zimbraAddListMember "${list_email}" "${member_email}"
    done < "${backup_file}"
  done
}

function zimbraRestoreAccountAliases() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/aliases"

  while read alias; do
    if [ "${alias}" != "root@${_zimbra_install_domain}" -a "${alias}" != "postmaster@${_zimbra_install_domain}" ]; then
      zimbraAddAlias "${email}" "${alias}"
    else
      log_debug "Skip alias creation for <${email}>"
    fi
  done < "${backup_file}"
}

function zimbraRestoreAccountSignatures() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/signatures"

  if ! [ -d "${backup_path}" -a -r "${backup_path}" ]; then
    log_err "Path <${backup_path}> doesn't exist, is not a directory or is not readable"
    exit 1
  fi

  local signature_files=$(ls "${backup_path}")

  for backup_file in "${signature_files}"; do
    if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
      log_err "File <${backup_file}> doesn't exist, is not a regular file or is not readable"
      exit 1
    fi

    local name=$(head -n 1 "${backup_file}")
    local content=$(sed 's/"/\\"/g' "${backup_file}")
    local type=txt

    if [[ "${backup_file}" =~ '\.html$' ]]; then
      type=html
    fi

    log_debug "Create signature named <${name}> (<${type}>) for <${email}>"
    zimbraCreateSignature "${email}" "${name}" "${type}" "${content}"
  done
}


########################
### GLOBAL VARIABLES ###
########################

_debug_mode=0
_zimbra_user='zimbra'
_zimbra_main_path='/opt/zimbra'
_zimbra_install_domain=
_backups_path='/tmp/backups'
_restoring_account=
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

while getopts 'm:p:u:b:e:d:h' opt; do
  case "${opt}" in
    m) _account_to_restore="${OPTARG}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    b) _backups_path="${OPTARG%/}" ;;
    e) for subopt in ${OPTARG}; do
         case "${subopt}" in
           aliases) _exclude_aliases=true ;;
           domains) _exclude_domains=true ;;
           lists) _exclude_lists=true ;;
           data) _exclude_data=true ;;
           filters) _exclude_filters=true ;;
           settings) _exclude_settings=true ;;
           signatures) _exclude_signatures=true ;;
           *) log_err "Value <${OPTARG}> not supported by option -e"; show_usage ;;
         esac ;;
       done
    h) show_usage ;;
    d) _debug_mode="${OPTARG}" ;;
    \?) exit_usage ;;
  esac
done

if [ "${_debug_mode}" -ge 3 ]; then
  set -o xtrace
fi

if ! [ -d "${_zimbra_main_path}" -a -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi

if ! [ -d "${_backups_path}" -a -x "${_backups_path}" -a -r "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist, is not a directory or is not executable and readable"
  exit 1
fi


##############
### SCRIPT ###
##############

trap 'trap_exit $LINENO' EXIT ERR
trap 'exit 1' INT

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
  log_info "Creating account <${email}>"
  zimbraRestoreAccount "${email}"

  _restoring_account="${email}"

  ${_exclude_aliases} || {
    log_info "Restoring aliases to <${email}>"
    zimbraRestoreAccountAliases "${email}"
  }

  ${_exclude_filters} || {
    log_info "Restoring filters to <${email}>"
    zimbraRestoreAccountFilters "${email}"
  }

  ${_exclude_signatures} || {
    log_info "Restoring signatures to <${email}>"
    zimbraRestoreAccountSignatures "${email}"
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
