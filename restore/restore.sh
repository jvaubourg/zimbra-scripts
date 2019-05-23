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

  ACCOUNTS
    Already existing accounts in Zimbra will be skipped with a warning.

    -m email
      Email of an account to include in the restore
      Repeat this option as many times as necessary to restore more than only one account
      Cannot be used with -x at the same time
      [Default] All accounts
      [Example] -m foo@example.com -m bar@example.org

    -x email
      Email of an account to exclude of the restore
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
      Do a partial restore, by excluding some settings/data
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
          Do not restore contents of the mailboxes (ie. folders/emails/contacts/calendar/briefcase/tasks)
        all_except_accounts
          Only restore the accounts (ie. users' settings and contents of the mailboxes)

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

function log() { printf '%s# %s\n' "$(date +'%F %T')" "${1}"; }
function log_debug() { ([ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" >&2) || true; }
function log_info() { log "[INFO] ${1}"; }
function log_warn() { log "[WARN] ${1}" >&2; }
function log_err() { log "[ERR] ${1}" >&2; }

function resetAccountRestoreDuration() {
  _restore_timer="${SECONDS}"
}

function showAccountRestoreDuration() {
  local duration_secs=$(( SECONDS - _restore_timer ))
  local duration_fancy=$(date -ud "0 ${duration_secs} seconds" +%T)

  log_info "Time used for restoring this account: ${duration_fancy}"
}

function showFullRestoreDuration {
  local duration_fancy=$(date -ud "0 ${SECONDS} seconds" +%T)

  log_info "Time used for restoring everything: ${duration_fancy}"
}

# Warning: traps can be thrown inside command substitutions $(...) and don't stop the main process in this case
function trap_exit() {
  local status="${?}"
  local line="${1}"

  trap - EXIT TERM ERR INT

  if [ "${status}" -ne 0 ]; then
    if [ "${line}" -gt 1 ]; then
      log_err "There was an unexpected interruption on line ${line}"
    fi

    log_err "Restore aborted"
    cleanFailedRestore
  else
    log_info "Restore done"
  fi

  exit "${status}"
}

function execZimbraCmd() {
  # References (namerefs) are not supported by Bash prior to 4.4 (CentOS currently uses 4.3)
  # For now we expect that the parent function defined a cmd variable
  # local -n command="${1}"

  local path="PATH=/sbin:/bin:/usr/sbin:/usr/bin:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec"
  
  if [ "${_debug_mode}" -ge 2 ]; then
    log_debug "CMD: ${cmd[*]}"
  fi

  # Using sudo instead of su -c and an array instead of a string prevent code injections
  sudo -u "${_zimbra_user}" env "${path}" "${cmd[@]}"
}


####################
## CORE FUNCTIONS ##
####################

function cleanFailedRestore() {
  log_debug "Cleaning after fail"

  if [ ! -z "${_restoring_account}" ]; then
    local ask_remove=y

    if [ "${_debug_mode}" -gt 0 ]; then
      read -p "Remove incomplete account <${_restoring_account}> (default: Y)? " ask_remove
    fi

    if [ -z "${ask_remove}" -o "${ask_remove}" = Y -o "${ask_remove}" = y ]; then
      if zimbraRemoveAccount "${_restoring_account}"; then
        log_info "The account <${_restoring_account}> has been removed"
      fi
    fi

    _restoring_account=
  fi
}

function checkAccountSettingsFile() {
  local email="${1}"
  local backup_file="${_backups_path}/accounts/${email}/settings"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "File <${backup_file}> is missing, is not a regular file or is not readable"
    exit 1
  fi
}

# Should be secured with a call to checkAccountSettingsFile before using
function extractFromAccountSettingsFile() {
  local email="${1}"
  local field="${2}"
  local backup_file="${_backups_path}/accounts/${email}/settings"
  local value=$((grep "^${field}:" "${backup_file}" || true) | sed "s/^${field}: //")

  printf '%s' "${value}"
}

function selectAccountsToRestore() {
  local include_accounts="${1}"
  local exclude_accounts="${2}"
  local accounts_to_restore="${include_accounts}"
  
  # Restore either accounts provided with -m, either all accounts,
  # either all accounts minus the ones provided with -x
  if [ -z "${accounts_to_restore}" ]; then
    accounts_to_restore=$(ls "${_backups_path}/accounts")
  
    if [ ! -z "${exclude_accounts}" ]; then
      accounts=
  
      for email in ${accounts_to_restore}; do
        if [[ ! "${exclude_accounts}" =~ (^| )"${email}"($| ) ]]; then
          accounts="${accounts} ${email}"
        fi
      done
  
      accounts_to_restore="${accounts}"
    fi
  fi

  # echo is used to remove extra spaces
  echo -En ${accounts_to_restore}
}

function getAccountDataFileSize() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tgz"

  printf "%s" "$(du -sh "${backup_file}" | awk '{ print $1 }')B"
}


######################
## ZIMBRA CLI & API ##
######################

function zimbraGetMainDomain() {
  local cmd=(zmprov getConfig zimbraDefaultDomainName)

  execZimbraCmd cmd | sed "s/^zimbraDefaultDomainName: //"
}

function zimbraCreateDomain() {
  local domain="${1}"
  local cmd=(zmprov createDomain "${domain}" zimbraAuthMech zimbra)

  execZimbraCmd cmd
}

function zimbraCreateList() {
  local list_email="${1}"
  local cmd=(zmprov createDistributionList "${list_email}")

  execZimbraCmd cmd
}

function zimbraSetListMember() {
  local list_email="${1}"
  local member_email="${2}"
  local cmd=(zmprov addDistributionListMember "${list_email}" "${member_email}")

  execZimbraCmd cmd
}

function zimbraGetAccounts() {
  local cmd=(zmprov --ldap getAllAccounts)

  # echo is used to remove return chars
  echo -En $(execZimbraCmd cmd | (grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])' || true))
}

function zimbraCreateAccount() {
  local email="${1}"
  local cn="${2}"
  local givenName="${3}"
  local displayName="${4}"
  local hash_password="${5}"
  local tmp_password="${RANDOM}${RANDOM}"
  local cmd=

  # grep hides returned id (and Zimbra sometimes displays errors in stdout)
  cmd=(zmprov createAccount "${email}" "${tmp_password}" cn "${cn}" displayName "${displayName}" givenName "${givenName}" zimbraPrefFromDisplay "${displayName}")
  execZimbraCmd cmd | (grep -v '^\([[:alnum:]]\+-\)\{4\}[[:alnum:]]\+$' || true)

  cmd=(zmprov modifyAccount "${email}" userPassword "${hash_password}")
  execZimbraCmd cmd
}

function zimbraRemoveAccount() {
  local email="${1}"
  local cmd=(zmprov deleteAccount "${email}")

  execZimbraCmd cmd
}

function zimbraSetAccountAlias() {
  local email="${1}"
  local alias="${2}"
  local cmd=(zmprov addAccountAlias "${email}" "${alias}")

  execZimbraCmd cmd
}

function zimbraSetAccountSignature() {
  local email="${1}"
  local name="${2}"
  local type="${3}"
  local content="${4}"
  local field=zimbraPrefMailSignature
  local cmd=

  if [ "${type}" = html ]; then
    field=zimbraPrefMailSignatureHTML
  fi

  # grep hides returned id (and Zimbra sometimes displays errors in stdout)
  cmd=(zmprov createSignature "${email}" "${name}" "${field}" "${content}")
  execZimbraCmd cmd | (grep -v '^\([[:alnum:]]\+-\)\{4\}[[:alnum:]]\+$' || true)
}

function zimbraSetAccountFilters() {
  local email="${1}"
  local filters_path="${2}"
  local filters=$(cat "${filters_path}")
  local cmd=(zmprov modifyAccount "${email}" zimbraMailSieveScript "${filters}")

  execZimbraCmd cmd
}

function zimbraSetAccountData() {
  local email="${1}"
  local backup_file="${2}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" -t 0 postRestURL --url https://localhost:8443 '/?fmt=tgz&resolve=reset' "${backup_file}")

  execZimbraCmd cmd
}


#############
## RESTORE ##
#############

function zimbraRestoreDomains() {
  local backup_path="${_backups_path}/admin"
  local backup_file="${backup_path}/domains"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "File <${backup_file}> is missing, is not a regular file or is not readable"
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

    if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
      log_err "File <${backup_file}> is not a regular file or is not readable"
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

  if [ ! -d "${backup_path}" -o ! -r "${backup_path}" ]; then
    log_err "Path <${backup_path}> is missing, is not a directory or is not readable"
    exit 1
  fi

  find "${backup_path}" -mindepth 1 | while read backup_file
  do
    if [ ! -f "${backup_file}" -a -r "${backup_file}" ]; then
      log_err "File <${backup_file}> is not a regular file or is not readable"
      exit 1
    fi

    # The name is stored in the first line of the file
    local name=$(head -n 1 "${backup_file}")
    local content=$(tail -n +2 "${backup_file}")
    local type=txt

    if [[ "${backup_file}" =~ \.html$ ]]; then
      type=html
    fi

    log_debug "${email}: Create signature type ${type} named <${name}>"
    zimbraSetAccountSignature "${email}" "${name}" "${type}" "${content}"
  done
}

function zimbraRestoreAccountFilters() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/filters"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "File <${backup_file}> is missing, is not a regular file or is not readable"
    exit 1
  fi

  zimbraSetAccountFilters "${email}" "${backup_file}"
}

function zimbraRestoreAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tgz"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "File <${backup_file}> is missing, is not a regular file or is not readable"
    exit 1
  fi

  zimbraSetAccountData "${email}" "${backup_file}"
}


########################
### GLOBAL VARIABLES ###
########################

_backups_include_accounts=
_backups_exclude_accounts=
_backups_path='/tmp/zimbra_backups'
_zimbra_main_path='/opt/zimbra'
_zimbra_user='zimbra'
_exclude_domains=false
_exclude_lists=false
_exclude_aliases=false
_exclude_signatures=false
_exclude_filters=false
_exclude_data=false
_debug_mode=0
_zimbra_install_domain=
_accounts_to_restore=
_existing_accounts=
_restoring_account=
_restore_timer=


###############
### OPTIONS ###
###############

trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT

while getopts 'm:p:u:b:e:d:h' opt; do
  case "${opt}" in
       # echos are used to remove extra spaces
    m) _backups_include_accounts=$(echo -E ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -E ${_backups_exclude_accounts} ${OPTARG}) ;;
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

if [ ! -d "${_zimbra_main_path}" -o ! -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi

if [ ! -d "${_backups_path}" -o ! -x "${_backups_path}" -o ! -r "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist, is not a directory or is not executable and readable"
  exit 1
fi


###################
### MAIN SCRIPT ###
###################

log_info "Getting Zimbra main domain"
_zimbra_install_domain=$(zimbraGetMainDomain)
log_debug "Zimbra main domain is <${_zimbra_install_domain}>"

${_exclude_domains} || {
  log_info "Restoring domains"
  zimbraRestoreDomains
}

${_exclude_lists} || {
  log_info "Restoring mailing lists"
  zimbraRestoreLists
}

_accounts_to_restore=$(selectAccountsToRestore "${_backups_include_accounts}" "${_backups_exclude_accounts}")

if [ -z "${_accounts_to_restore}" ]; then
  log_debug "No account to restore"
else
  log_debug "Accounts to restore: ${_accounts_to_restore}"

  _existing_accounts=$(zimbraGetAccounts)
  log_debug "Already existing accounts: ${_existing_accounts}"

  # Restore accounts
  for email in ${_accounts_to_restore}; do
    if [[ "${_existing_accounts}" =~ (^| )"${email}"($| ) ]]; then
      log_warn "Skip account <${email}> (already exists in Zimbra)"
    else
      resetAccountRestoreDuration

      log_info "Creating account <${email}>"
      zimbraRestoreAccount "${email}"

      _restoring_account="${email}"
      log_info "Restoring account <${email}>"
  
      ${_exclude_aliases} || {
        log_info "${email}: Restoring aliases"
        zimbraRestoreAccountAliases "${email}"
      }
  
      ${_exclude_signatures} || {
        log_info "${email}: Restoring signatures"
        zimbraRestoreAccountSignatures "${email}"
      }
  
      ${_exclude_filters} || {
        log_info "${email}: Restoring filters"
        zimbraRestoreAccountFilters "${email}"
      }
  
      ${_exclude_data} || {
        log_info "${email}: Restoring data ($(getAccountDataFileSize "${email}") compressed)"
        zimbraRestoreAccountData "${email}"
      }
  
      showAccountRestoreDuration
      _restoring_account=
    fi
  done
fi

showFullRestoreDuration

exit 0
