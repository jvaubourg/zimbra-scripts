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

function exit_usage() {
  local status="${1}"

  cat <<USAGE

  MAILBOXES

    -m email
      Email of an account to include in the restoration
      Repeat this option as many times as necessary to restore more than only one account
      Cannot be used with -x at the same time
      [Default] All accounts
      [Example] -m foo@example.com -m bar@example.org

    -x email
      Email of an account to exclude of the restoration
      Repeat this option as many times as necessary to restore more than only one account
      Cannot be used with -m at the same time
      [Default] No exclusion
      [Example] -x foo@example.com -x bar@example.org

  ENVIRONMENT

    -b path
      Where the backups are
      [Default] ${_backups_path}

    -p path
      Main path of the Zimbra installation
      [Default] ${_zimbra_main_path}

    -u user
      Zimbra UNIX user
      [Default] ${_zimbra_user}

  EXCLUSIONS

    -e ASSET
      Do a partial restoration, by excluding some settings/data
      Repeat this option as many times as necessary to exclude more than only one asset
      [Default] Everything is restored
      [Example] -e domains -e data

      ASSET can be:
        domains
          Do not restore domains
        lists
          Do not restore mailing lists
        aliases
          Do not restore email aliases
        signatures
          Do not restore registred signatures
        filters
          Do not restore sieve filters
        data
          Do not restore contents of the mailboxes
        all_except_accounts
          Only restore the accounts and the related users' settings
        all_except_data
          Only restore the data of the mailboxes

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

function log() { echo "$(date +'%F %R'): ${1}"; }
function log_debug() { [ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" >&2; }
function log_info() { log "[INFO] ${1}"; }
function log_warn() { log "[WARN] ${1}" >&2; }
function log_err() { log "[ERR] ${1}" >&2; }

function trap_exit() {
  local status="${?}"
  local line="${1}"

  trap - EXIT TERM ERR INT

  if [ "${status}" -ne 0 ]; then
    if [ "${line}" -gt 1 ]; then
      log_err "There was an unexpected interruption on line ${line}"
    fi

    log_err "Restoration aborted"
    cleanFailedRestoration
  else
    log_info "Restoration done"
  fi

  exit "${status}"
}

function cleanFailedRestoration() {
  if ! [ -z "${_restoring_account}" ]; then
    log_debug "Trying to clean the incomplete account <${_restoring_account}>"

    if [ "${_debug_mode}" -gt 0 ]; then
      local ask_delete=
      read -p "Delete <${_restoring_account}> account (default: Y)? " ask_delete

      if [ -z "${ask_delete}" -o "${ask_delete}" = Y -o "${ask_delete}" = y ]; then
        zimbraDeleteAccount "${_restoring_account}"
        log_debug "Incomplete <${_restoring_account}> account deleted"
      else
        log_debug "Incomplete <${_restoring_account}> account was NOT deleted"
      fi
    fi
  fi
}

function initDuration() {
  SECONDS=0
  SECONDS_step=0
}

function showStepDuration {
  local duration_secs=$(( SECONDS - SECONDS_step ))
  local duration_fancy=$(date -ud "0 ${duration_secs} seconds" +%H:%M:%S)

  log_info "Time duration of the last step: ${duration_fancy}"
  SECONDS_step="${SECONDS}"
}

function showScriptDuration {
  local duration_fancy=$(date -ud "0 ${SECONDS} seconds" +%H:%M:%S)
  log_info "Time duration of the whole process: ${duration_fancy}"
}

function execZimbraCmd() {
  local cmd="${1}"
  export PATH="${PATH}:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec/"

  if [ "${_debug_mode}" -ge 2 ]; then
    log_debug "CMD: ${cmd}"
  fi

  su "${_zimbra_user}" -c "${cmd}"
}

function checkAccountSettingsFile() {
  local email="${1}"
  local backup_file="${_backups_path}/accounts/${email}/settings"

  if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
    log_err "File <${backup_file}> doesn't exist, is not a regular file or is not readable or reachable"
    exit 1
  fi
}

# Should be secured with a call to checkAccountSettingsFile before using
function extractFromAccountSettingsFile() {
  local email="${1}"
  local field="${2}"
  local backup_file="${_backups_path}/accounts/${email}/settings"
  local value=$((grep '^${field}:' "${backup_file}" || true) | sed "s/^${field}: //")

  echo -n "${value}"
}


######################
## ZIMBRA CLI & API ##
######################

function zimbraGetMainDomain() {
  execZimbraCmd "zmprov gcf zimbraDefaultDomainName" | sed "s/^zimbraDefaultDomainName: //"
}

function zimbraCreateDomain() {
  local domain="${1}"
  execZimbraCmd "zmprov createDomain '${domain}' zimbraAuthMech zimbra"
}

function zimbraCreateList() {
  local list_email="${1}"
  execZimbraCmd "zmprov createDistributionList '${list_email}'"
}

function zimbraSetListMember() {
  local list_email="${1}"
  local member_email="${2}"

  execZimbraCmd "zmprov addDistributionListMember '${list_email}' '${member_email}'"
}

function zimbraGetAccounts() {
  execZimbraCmd 'zmprov --ldap getAllAccounts' | (grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])' || true)
}

function zimbraCreateAccount() {
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

function zimbraSetAccountAlias() {
  local email="${1}"
  local alias="${2}"

  execZimbraCmd "zmprov addAccountAlias '${email}' '${alias}'"
}

function zimbraSetAccountSignature() {
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

function zimbraSetAccountFilters() {
  local email="${1}"
  local filters_path="${2}"
  local filters=$(cat "${filters_path}")

  execZimbraCmd "zmprov modifyAccount '${email}' zimbraMailSieveScript \"${filters}\""
}

function zimbraSetAccountData() {
  local email="${1}"
  local backup_file="${2}"

  execZimbraCmd "zmmailbox --zadmin --mailbox '${email}' -t 0 postRestURL --url https://localhost:8443 '/?fmt=tgz&resolve=reset' '${backup_file}'"
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
      log_debug "Create domain <${domain}>"
      zimbraCreateDomain "${domain}"
    else
      log_debug "Skip domain <$domain> creation"
    fi
  done < "${backup_file}"
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
    zimbraCreateList "${list_email}"

    while read member_email; do
      log_debug "${list_email}: Add <${member_email}> as a member"
      zimbraSetListMember "${list_email}" "${member_email}"
    done < "${backup_file}"
  done
}

function zimbraRestoreAccount() {
  local email="${1}"

  checkAccountSettingsFile "${email}"

  local cn=$(extractFromAccountSettingsFile "${email}" cn)
  local givenName=$(extractFromAccountSettingsFile "${email}" givenName)
  local displayName=$(extractFromAccountSettingsFile "${email}" displayName)
  local userPassword=$(extractFromAccountSettingsFile "${email}" userPassword)

  if [ "${email}" != "admin@${_zimbra_install_domain}" ]; then
    zimbraCreateAccount "${email}" "${cn}" "${givenName}" "${displayName}" "${userPassword}"
  else
    log_debug "Skip account <${email}> creation"
  fi
}

function zimbraRestoreAccountAliases() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/aliases"

  while read alias; do
    if [ "${alias}" != "root@${_zimbra_install_domain}" -a "${alias}" != "postmaster@${_zimbra_install_domain}" ]; then
      zimbraSetAccountAlias "${email}" "${alias}"
    else
      log_debug "${email}: Skip alias <${alias}> creation"
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

    if [[ "${backup_file}" =~ \.html$ ]]; then
      type=html
    fi

    log_debug "${email}: Create signature type <${type}> named <${name}>"
    zimbraSetAccountSignature "${email}" "${name}" "${type}" "${content}"
  done
}

function zimbraRestoreAccountFilters() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/filters"

  if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
    log_err "File <${backup_file}> doesn't exist, is not a regular file or is not regular or reachable"
    exit 1
  fi

  zimbraSetAccountFilters "${email}" "${backup_path}"
}

function zimbraRestoreAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tgz"

  if ! [ -f "${backup_file}" -a -r "${backup_file}" ]; then
    log_err "File <${backup_file}> doesn't exist, is not a regular file or is not regular or reachable"
    exit 1
  fi

  zimbraSetAccountData "${email}" "${backup_file}"
}


########################
### GLOBAL VARIABLES ###
########################

_backups_include_accounts=
_backups_exclude_accounts=
_backups_path='/tmp/backups'
_zimbra_main_path='/opt/zimbra'
_zimbra_user='zimbra'
_exclude_domains=false
_exclude_lists=false
_exclude_settings=false
_exclude_aliases=false
_exclude_signatures=false
_exclude_filters=false
_exclude_data=false
_debug_mode=0
_zimbra_install_domain=
_accounts_to_restore=
_existing_accounts=
_restoring_account=
SECONDS_step=


###############
### OPTIONS ###
###############

trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT

while getopts 'm:p:u:b:e:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo ${_backups_exclude_accounts} ${OPTARG}) ;;
    b) _backups_path="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    e) for subopt in ${OPTARG}; do
         case "${subopt}" in
           domains) _exclude_domains=true ;;
           lists) _exclude_lists=true ;;
           aliases) _exclude_aliases=true ;;
           signatures) _exclude_signatures=true ;;
           filters) _exclude_filters=true ;;
           data) _exclude_data=true ;;
           all_except_accounts)
             _exclude_domains=true
             _exclude_lists=true ;;
           all_except_data)
             _exclude_domains=true
             _exclude_lists=true
             _exclude_settings=true
             _exclude_aliases=true
             _exclude_signatures=true
             _exclude_filters=true ;;
           *) log_err "Value <${OPTARG}> not supported by option -e"; exit_usage 1 ;;
         esac
       done ;;
    d) _debug_mode="${OPTARG}" ;;
    h) exit_usage 0 ;;
    \?) exit_usage 1 ;;
  esac
done

if [ "${_debug_mode}" -ge 3 ]; then
  set -o xtrace
fi

if [ ! -z "${_backups_include_accounts}" -a ! -z "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not compatible"
  exit 1
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

initDuration

_zimbra_install_domain=$(zimbraGetMainDomain)
log_debug "Zimbra main domain is <${_zimbra_install_domain}>"

${_exclude_domains} || {
  log_info "Restoring domains"
  zimbraRestoreDomains
  showStepDuration
}

${_exclude_lists} || {
  log_info "Restoring mailing lists"
  zimbraRestoreLists
  showStepDuration
}

_accounts_to_restore="${_backups_include_accounts}"

# Restore either accounts provided with -m, either all accounts,
# either all accounts minus the ones provided with -x
if [ -z "${_accounts_to_restore}" ]; then
  _accounts_to_restore=$(ls "${_backups_path}/accounts")

  if ! [ -z "${_backups_exclude_accounts}" ]; then
    accounts=

    for email in ${_accounts_to_restore}; do
      if ! [[ "${_backups_exclude_accounts}" =~ (^| )"${email}"($| ) ]]; then
        accounts=$(echo ${accounts} ${email})
      fi
    done

    _accounts_to_restore="${accounts}"
  fi
fi

if [ -z "${_accounts_to_backup}" ]; then
  log_debug "No account to restore"
else
  log_debug "Accounts to restore: ${_accounts_to_restore}"

  log_info "Getting list of already existing accounts"
  _existing_accounts=$(zimbraGetAccounts)
  log_debug "Already existing accounts: ${_existing_accounts}"
  showStepDuration

  # Restore accounts
  for email in ${_accounts_to_restore}; do
    if [[ "${_existing_accounts}" =~ (^| )"${email}"($| ) ]]; then
      log_warn "Skip <${email}> account (already exists in Zimbra)"
    else
      ${_exclude_settings} || {
        log_info "Creating <${email}> account"
        zimbraRestoreAccount "${email}"
      }

      _restoring_account="${email}"
      log_info "Restoring <${email}> account"
  
      ${_exclude_aliases} || {
        log_info "${email}: Restoring aliases"
        zimbraRestoreAccountAliases "${email}"
      }
  
      ${_exclude_signatures} || {
        log_info "${email}: Restoring signatures"
        zimbraRestoreAccountSignatures "${email}"
      }
  
      ${_exclude_filters} || {
        log_info "${email}: Restoring filters"
        zimbraRestoreAccountFilters "${email}"
      }
  
      ${_exclude_data} || {
        log_info "${email}: Restoring mailbox data"
        zimbraRestoreAccountData "${email}"
      }
  
      showStepDuration
      _restoring_account=
    fi
  done
fi

showScriptDuration

exit 0
