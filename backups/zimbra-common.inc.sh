# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts


########################
### GLOBAL VARIABLES ###
########################

# Default values (can be changed with parent script options)
_log_id=UNKNOWN
_backups_path='/tmp/zimbra_backups'
_zimbra_main_path='/opt/zimbra'
_zimbra_user='zimbra'
_zimbra_group='zimbra'
_existing_accounts=
_process_timer=
_debug_mode=0

# Will be filled by zimbraGetMainDomain
_zimbra_install_domain=


#############
## GENERAL ##
#############

function log() { printf '%s| [%s]%s\n' "$(date +'%F %T')" "${_log_id}" "${1}"; }
function log_debug() { ([ "${_debug_mode}" -ge 1 ] && log "[DEBUG] ${1}" >&2) || true; }
function log_info() { log "[INFO] ${1}"; }
function log_warn() { log "[WARN] ${1}" >&2; }
function log_err() { log "[ERR] ${1}" >&2; }

# Warning: traps can be thrown inside command substitutions $(...) and don't stop the main process in this case
function trap_exit() {
  local status="${?}"
  local line="${1}"

  trap - EXIT TERM ERR INT

  if [ "${status}" -ne 0 ]; then
    if [ "${line}" -gt 1 ]; then
      log_err "There was an unexpected interruption on line ${line}"
    fi

    log_err "Process aborted"
    cleanFailedProcess
  else
    log_debug "Process done"
  fi

  exit "${status}"
}

function resetAccountProcessDuration() {
  _process_timer="${SECONDS}"
}

function showAccountProcessDuration {
  local duration_secs=$(( SECONDS - _process_timer ))
  local duration_fancy=$(date -ud "0 ${duration_secs} seconds" +%T)

  log_info "Time used for processing this account: ${duration_fancy}"
}

function showFullProcessDuration {
  local duration_fancy=$(date -ud "0 ${SECONDS} seconds" +%T)

  log_info "Time used for processing everything: ${duration_fancy}"
}

function escapeGrepStringRegexChars() {
  local search="${1}"
  printf '%s' "$(printf '%s' "${search}" | sed 's/[.[\*^$]/\\&/g')"
}

function setZimbraPermissions() {
  local folder="${1}"

  chown -R "${_zimbra_user}:${_zimbra_group}" "${folder}"
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

# During a backup: only usable after calling zimbraBackupAccountSettings
function extractFromAccountSettingsFile() {
  local email="${1}"
  local field="${2}"
  local settings_file="${_backups_path}/accounts/${email}/settings"
  local value=$((grep "^${field}:" "${settings_file}" || true) | sed "s/^${field}: //")

  printf '%s' "${value}"
}

# Hides IDs returned by Zimbra when creating an object
# (Zimbra sometimes displays errors directly to stdout)
function hideReturnedId() {
  grep -v '^[a-f0-9-]\+$' || true
}

# Return a list of email accounts to backup, depending on the include/exclude lists
function selectAccountsToBackup() {
  local include_accounts="${1}"
  local exclude_accounts="${2}"
  local accounts_to_backup="${include_accounts}"

  # Backup either accounts provided with -m, either all accounts,
  # either all accounts minus the ones provided with -x
  if [ -z "${accounts_to_backup}" ]; then
    accounts_to_backup=$(zimbraGetAccounts)
    log_debug "Existing accounts: ${accounts_to_backup}"
  
    if [ -n "${exclude_accounts}" ]; then
      accounts=
  
      for email in ${accounts_to_backup}; do
        if [[ ! "${exclude_accounts}" =~ (^| )"${email}"($| ) ]]; then
          accounts="${accounts} ${email}"
        fi
      done
  
      accounts_to_backup="${accounts}"
    fi
  fi

  # echo is used to remove extra spaces
  echo -En ${accounts_to_backup}
}

# Return a list of email accounts to restore, depending on the include/exclude lists
function selectAccountsToRestore() {
  local include_accounts="${1}"
  local exclude_accounts="${2}"
  local accounts_to_restore="${include_accounts}"
  
  # Restore either accounts provided with -m, either all accounts,
  # either all accounts minus the ones provided with -x
  if [ -z "${accounts_to_restore}" ]; then
    accounts_to_restore=$(ls "${_backups_path}/accounts")
  
    if [ -n "${exclude_accounts}" ]; then
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


######################
## ZIMBRA CLI & API ##
######################

##
## ZIMBRA GETTERS
##

function zimbraGetMainDomain() {
  local cmd=(zmprov getConfig zimbraDefaultDomainName)

  execZimbraCmd cmd | sed "s/^zimbraDefaultDomainName: //"
}

function zimbraGetAdminAccounts() {
  local cmd=(zmprov --ldap getAllAdminAccounts)

  execZimbraCmd cmd
}

function zimbraGetDomains() {
  local cmd=(zmprov --ldap getAllDomains)

  execZimbraCmd cmd
}

function zimbraGetDkimInfo() {
  local domain="${1}"
  local cmd=("${_zimbra_main_path}/libexec/zmdkimkeyutil" -q -d "${domain}")

  execZimbraCmd cmd 2> /dev/null || true
}

function zimbraGetLists() {
  local cmd=(zmprov --ldap getAllDistributionLists)

  execZimbraCmd cmd
}

function zimbraGetListMembers() {
  local list_email="${1}"
  local cmd=(zmprov --ldap getDistributionListMembership "${list_email}")

  execZimbraCmd cmd
}

function zimbraGetListAliases() {
  local list_email="${1}"
  local cmd=(zmprov --ldap getDistributionList "${list_email}")

  execZimbraCmd cmd | awk ' /^zimbraMailAlias:/ { print $2 } '
}

function zimbraGetAccounts() {
  local cmd=(zmprov --ldap getAllAccounts)

  # echo is used to remove return chars
  echo -En $(execZimbraCmd cmd | (grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])' || true))
}

function zimbraGetAccountSettings() {
  local email="${1}"
  local cmd=(zmprov --ldap getAccount "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountCatchAll() {
  local email="${1}"

  extractFromAccountSettingsFile "${email}" zimbraMailCatchAllAddress
}

function zimbraGetAccountForwarding() {
  local email="${1}"
  local to_email=$(extractFromAccountSettingsFile "${email}" zimbraPrefMailForwardingAddress)

  if [ -n "${to_email}" ]; then
    local keep_copies=$(extractFromAccountSettingsFile "${email}" zimbraPrefMailLocalDeliveryDisabled)

    if [ -n "${keep_copies}" ]; then
      keep_copies=FALSE
    fi

    printf '%s\n%s' "${to_email}" "${keep_copies}"
  fi
}

function zimbraGetAccountAliases() {
  local email="${1}"

  extractFromAccountSettingsFile "${email}" zimbraMailAlias
}

function zimbraGetAccountSignatures() {
  local email="${1}"
  local cmd=(zmprov getSignatures "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountFilters() {
  local email="${1}"
  local cmd=(zmprov getAccount "${email}" zimbraMailSieveScript)

  # 1d removes the comment on the first line
  execZimbraCmd cmd | sed '1d;s/^zimbraMailSieveScript: //'
}

function zimbraGetAccountFoldersList() {
  local email="${1}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getAllFolders)

  execZimbraCmd cmd | awk '/\// { print $5 }'
}

function zimbraGetAccountDataSize() {
  local email="${1}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getMailboxSize)

  execZimbraCmd cmd | tr -d ' '
}

function zimbraGetAccountData() {
  local email="${1}"
  local filter_query="${2}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getRestURL "//?fmt=tar${filter_query}")

  execZimbraCmd cmd
}

function zimbraGetFolderAttributes() {
  local email="${1}"
  local path="${2}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" getFolder "${path}")

  execZimbraCmd cmd
}

function zimbraIsInstallUser() {
  local email="${1}"
  [ "${email}" = "admin@${_zimbra_install_domain}" ]
}

function zimbraIsAccountExisting() {
  local email="${1}"

  if [ -z "${_existing_accounts}" ]; then
    _existing_accounts=$(zimbraGetAccounts)
    log_debug "Already existing accounts: ${_existing_accounts}"
  fi

  [[ "${_existing_accounts}" =~ (^| )"${email}"($| ) ]]
}


##
## ZIMBRA SETTERS
##

function zimbraCreateDomain() {
  local domain="${1}"
  local cmd=(zmprov createDomain "${domain}" zimbraAuthMech zimbra)

  execZimbraCmd cmd | hideReturnedId
}

function zimbraCreateDkim() {
  local domain="${1}"
  local cmd=("${_zimbra_main_path}/libexec/zmdkimkeyutil" -a -d "${domain}")

  execZimbraCmd cmd | (grep -v '^\(DKIM Data added\|Public signature to\)' || true)
}

function zimbraCreateList() {
  local list_email="${1}"
  local cmd=(zmprov createDistributionList "${list_email}")

  execZimbraCmd cmd | hideReturnedId
}

function zimbraSetListMember() {
  local list_email="${1}"
  local member_email="${2}"
  local cmd=(zmprov addDistributionListMember "${list_email}" "${member_email}")

  execZimbraCmd cmd
}

function zimbraSetListAlias() {
  local list_email="${1}"
  local alias_email="${2}"
  local cmd=(zmprov addDistributionListAlias "${list_email}" "${alias_email}")

  execZimbraCmd cmd
}

function zimbraCreateAccount() {
  local email="${1}"
  local cn="${2}"
  local givenName="${3}"
  local displayName="${4}"
  local password="${5}"
  local cmd=(zmprov createAccount "${email}" "${password}" cn "${cn}" displayName "${displayName}" givenName "${givenName}" zimbraPrefFromDisplay "${displayName}")

  execZimbraCmd cmd | hideReturnedId
}

function zimbraUpdateAccountPassword() {
  local email="${1}"
  local hash_password="${2}"
  local cmd=(zmprov modifyAccount "${email}" userPassword "${hash_password}")

  execZimbraCmd cmd
}

function zimbraSetPasswordMustChange() {
  local email="${1}"
  local cmd=(zmprov modifyAccount "${email}" zimbraPasswordMustChange TRUE)

  execZimbraCmd cmd
}

function zimbraRemoveAccount() {
  local email="${1}"
  local cmd=(zmprov deleteAccount "${email}")

  execZimbraCmd cmd
}

function zimbraSetAccountLock() {
  local email="${1}"
  local lock="${2}"
  local status=active
  local cmd=

  if ${lock}; then
    status=pending
  fi

  cmd=(zmprov modifyAccount "${email}" zimbraAccountStatus "${status}")
  execZimbraCmd cmd
}

function zimbraSetAccount() {
  local email="${1}"
  local field="${2}"
  local value="${3}"

  cmd=(zmprov modifyAccount "${email}" "${field}" "${value}")

  execZimbraCmd cmd
}


function zimbraSetAccountCatchAll() {
  local email="${1}"
  local at_domain="${2}"
  local cmd=(zmprov modifyAccount "${email}" zimbraMailCatchAllAddress "${at_domain}")

  execZimbraCmd cmd
}

function zimbraSetAccountForwarding() {
  local email="${1}"
  local to_email="${2}"
  local keep_copies="${3}"

  local cmd=(zmprov modifyAccount "${email}" zimbraPrefMailForwardingAddress "${to_email}")
  execZimbraCmd cmd

  if ! ${keep_copies}; then
    local cmd=(zmprov modifyAccount "${email}" zimbraPrefMailLocalDeliveryDisabled TRUE)
    execZimbraCmd cmd
  fi
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

  cmd=(zmprov createSignature "${email}" "${name}" "${field}" "${content}")
  execZimbraCmd cmd | hideReturnedId
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
  local cmd=(zmmailbox --zadmin --mailbox "${email}" -t 0 postRestURL --url https://localhost:8443 '/?fmt=tar&resolve=reset' "${backup_file}")

  execZimbraCmd cmd
}

function zimbraCreateDataFolder() {
  local email="${1}"
  local folder="${2}"
  local cmd=(zmmailbox --zadmin --mailbox "${email}" createFolder "${folder}")

  execZimbraCmd cmd | hideReturnedId
}
