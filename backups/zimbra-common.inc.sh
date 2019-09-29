# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts


########################
### GLOBAL VARIABLES ###
########################

# Default values (can be changed with parent script options)
_log_id=UNKNOWN
_backups_path=/tmp/zimbra_backups
_zimbra_main_path=/opt/zimbra
_zimbra_user=zimbra
_zimbra_group=zimbra
_existing_accounts=
_process_timer=
_debug_mode=0

# Fastprompt processes
_disable_fastprompts=false
_fastprompt_zmprov_tmp=
_fastprompt_zmprov_pid=
_fastprompt_zmmailbox_tmp=
_fastprompt_zmmailbox_pid=
_fastprompt_zmmailbox_email=

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

  if [ -n "${_fastprompt_zmprov_pid}" ]; then
    log_debug "Close the fast zmprov prompt"

    echo exit > "${_fastprompt_zmprov_tmp}/cmd"
    wait "${_fastprompt_zmprov_pid}"
    rm -rf "${_fastprompt_zmprov_tmp}"
    _fastprompt_zmprov_pid=
  fi

  if [ -n "${_fastprompt_zmmailbox_pid}" ]; then
    log_debug "Close the fast zmmailbox prompt"

    echo exit > "${_fastprompt_zmmailbox_tmp}/cmd"
    wait "${_fastprompt_zmmailbox_pid}"
    rm -rf "${_fastprompt_zmmailbox_tmp}"
    _fastprompt_zmmailbox_pid=
  fi

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

# Every Zimbra CLI command (zmprov, zmmailbox, etc) can be used with a prompt
# Opening these prompts and feeding them with subcommands is way way faster
# than executing the commands each time (only one Java VM instantiated)
function execFastPrompt() {
  local cmd_pipe="${1}"
  local out_file="${2}"
  local prompt_delimiter=$(echo "${RANDOM}" | sha256sum | awk '{ print $1 }')

  :> "${out_file}"

  # Submit the subcommand with an additional fake one
  # Sed is used because Zimbra prompts don't support $'...' POSIX syntax
  printf '%q ' "${cmd[@]:1}" | sed "s/ \\$'/ '/g" > "${cmd_pipe}"
  printf '\n%s\n' "${prompt_delimiter}" > "${cmd_pipe}"

  # Wait to see the fake subcommand, meaning that the processing of the real
  # real one is terminated
  while read out_line; do
    if [ -z "${prompt_delimiter}" ]; then
      break
    elif [[ "${out_line}" =~ "${prompt_delimiter}" ]]; then
      prompt_delimiter=
    fi
  done < <(tail -f "${out_file}" 2> /dev/null || true)

  # Display the result of the subcommand
  # We really hope here that nobody uses ERROR: at the beginning of a line in a signature or anything else
  if grep '^ERROR: ' "${out_file}" | grep -v "${prompt_delimiter}" >&2; then
    false
  else
    head -n -3 "${out_file}" | tail -n +2
  fi
}

# Switch from an account to another one in the prompt of zmmailbox
function zmmailboxSelectMailbox() {
  local email="${1}"

  if ! ${_disable_fastprompts} && [ "${_fastprompt_zmmailbox_email}" != "${email}" ]; then
    local cmd=(fastzmmailbox selectMailbox "${email}")
    execZimbraCmd cmd > /dev/null
  fi

  _fastprompt_zmmailbox_email="${email}"
}

# Start the Java VM of the prompts we will have to use
function initFastPrompts() {
  if ! ${_disable_fastprompts}; then
    local path="PATH=/sbin:/bin:/usr/sbin:/usr/bin:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec"

    # fastzmprov
    if [ -z "${_fastprompt_zmprov_tmp}" ]; then
      _fastprompt_zmprov_tmp=$(mktemp -d)
      mkfifo "${_fastprompt_zmprov_tmp}/cmd"
      sudo -u "${_zimbra_user}" env "${path}" stdbuf -o0 -e0 zmprov --ldap < <(tail -f "${_fastprompt_zmprov_tmp}/cmd" || true) &>> "${_fastprompt_zmprov_tmp}/out" &
      _fastprompt_zmprov_pid="${!}"
    fi

    # fastzmmailbox
    if [ -z "${_fastprompt_zmmailbox_tmp}" ]; then
      _fastprompt_zmmailbox_tmp=$(mktemp -d)
      mkfifo "${_fastprompt_zmmailbox_tmp}/cmd"
      sudo -u "${_zimbra_user}" env "${path}" stdbuf -o0 -e0 zmmailbox --zadmin < <(tail -f "${_fastprompt_zmmailbox_tmp}/cmd" || true) &>> "${_fastprompt_zmmailbox_tmp}/out" &
      _fastprompt_zmmailbox_pid="${!}"
    fi
  fi
}

# Execute a Zimbra command with a shell or with a fast prompt
function execZimbraCmd() {
  # References (namerefs) are not supported by Bash prior to 4.4 (CentOS currently uses 4.3)
  # For now we expect that the parent function defined a cmd variable
  # local -n command="${1}"

  if ${_disable_fastprompts}; then
    if [ "${cmd[0]}" = fastzmprov ]; then
      cmd=(zmprov --ldap "${cmd[@]:1}")
    elif [ "${cmd[0]}" = fastzmmailbox ]; then
      cmd=(zmmailbox --zadmin --mailbox "${_fastprompt_zmmailbox_email}" "${cmd[@]:1}")
    fi
  fi

  if [ "${_debug_mode}" -ge 2 ]; then
    log_debug "CMD: ${cmd[*]}"
  fi

  if [ "${cmd[0]}" = fastzmprov ]; then
    execFastPrompt "${_fastprompt_zmprov_tmp}/cmd" "${_fastprompt_zmprov_tmp}/out"
  elif [ "${cmd[0]}" = fastzmmailbox ]; then
    execFastPrompt "${_fastprompt_zmmailbox_tmp}/cmd" "${_fastprompt_zmmailbox_tmp}/out"
  else
    # Using sudo instead of su -c and an array instead of a string prevent code injection
    local path="PATH=/sbin:/bin:/usr/sbin:/usr/bin:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec"
    sudo -u "${_zimbra_user}" env "${path}" "${cmd[@]}"
  fi
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
    accounts_to_backup=$(zimbraGetAccounts || true)
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
  local cmd=(fastzmprov getConfig zimbraDefaultDomainName)

  execZimbraCmd cmd | sed 's/^zimbraDefaultDomainName: //'
}

function zimbraGetAdminAccounts() {
  local cmd=(fastzmprov getAllAdminAccounts)

  execZimbraCmd cmd
}

function zimbraGetDomains() {
  local cmd=(fastzmprov getAllDomains)

  execZimbraCmd cmd
}

function zimbraGetDkimInfo() {
  local domain="${1}"
  local cmd=("${_zimbra_main_path}/libexec/zmdkimkeyutil" -q -d "${domain}")

  execZimbraCmd cmd 2> /dev/null || true
}

function zimbraGetLists() {
  local cmd=(fastzmprov getAllDistributionLists)

  execZimbraCmd cmd
}

function zimbraGetListMembers() {
  local list_email="${1}"
  local cmd=(fastzmprov getDistributionListMembership "${list_email}")

  execZimbraCmd cmd
}

function zimbraGetListAliases() {
  local list_email="${1}"
  local cmd=(fastzmprov getDistributionList "${list_email}" zimbraMailAlias)

  execZimbraCmd cmd | awk '/^zimbraMailAlias:/ { print $2 }'
}

function zimbraGetAccounts() {
  local cmd=(fastzmprov getAllAccounts)

  # echo is used to remove return chars
  echo -En $(execZimbraCmd cmd | (grep -vE '^(spam\.|ham\.|virus-quarantine\.|galsync[.@])' || true))
}

function zimbraGetAccountSetting() {
  local email="${1}"
  local field="${2}"
  local cmd=(fastzmprov getAccount "${email}" "${field}")

  execZimbraCmd cmd | sed "1d;\$d;s/^${field}: //"
}

function zimbraGetAccountAliases() {
  local email="${1}"

  zimbraGetAccountSetting "${email}" zimbraMailAlias
}

function zimbraGetAccountSignatures() {
  local email="${1}"
  local cmd=(fastzmprov getSignatures "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountSettingsFile() {
  local email="${1}"
  local cmd=(fastzmprov getAccount "${email}")

  execZimbraCmd cmd
}

function zimbraGetAccountFoldersList() {
  local email="${1}"
  zmmailboxSelectMailbox "${email}"

  local cmd=(fastzmmailbox getAllFolders)
  execZimbraCmd cmd | awk '/\// { print $5 }'
}

function zimbraGetAccountDataSize() {
  local email="${1}"
  zmmailboxSelectMailbox "${email}"

  local cmd=(fastzmmailbox getMailboxSize)
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
  zmmailboxSelectMailbox "${email}"

  local path="${2}"
  local cmd=(fastzmmailbox getFolder "${path}")
  execZimbraCmd cmd
}

function zimbraIsInstallUser() {
  local email="${1}"
  [ "${email}" = "admin@${_zimbra_install_domain}" ]
}

function zimbraIsAccountExisting() {
  local email="${1}"

  if [ -z "${_existing_accounts}" ]; then
    _existing_accounts=$(zimbraGetAccounts || true)
    log_debug "Already existing accounts: ${_existing_accounts}"
  fi

  [[ "${_existing_accounts}" =~ (^| )"${email}"($| ) ]]
}

function zimbraGetVersion() {
  local cmd=(zmcontrol -v)

  execZimbraCmd cmd
}


##
## ZIMBRA SETTERS
##

function zimbraCreateDomain() {
  local domain="${1}"
  local cmd=(fastzmprov createDomain "${domain}" zimbraAuthMech zimbra)

  execZimbraCmd cmd | hideReturnedId
}

function zimbraCreateDkim() {
  local domain="${1}"
  local cmd=("${_zimbra_main_path}/libexec/zmdkimkeyutil" -a -d "${domain}")

  execZimbraCmd cmd | (grep -v '^\(DKIM Data added\|Public signature to\)' || true)
}

function zimbraCreateList() {
  local list_email="${1}"
  local cmd=(fastzmprov createDistributionList "${list_email}")

  execZimbraCmd cmd | hideReturnedId
}

function zimbraSetListMember() {
  local list_email="${1}"
  local member_email="${2}"
  local cmd=(fastzmprov addDistributionListMember "${list_email}" "${member_email}")

  execZimbraCmd cmd
}

function zimbraSetListAlias() {
  local list_email="${1}"
  local alias_email="${2}"
  local cmd=(fastzmprov addDistributionListAlias "${list_email}" "${alias_email}")

  execZimbraCmd cmd
}

function zimbraCreateAccount() {
  local email="${1}"
  local cn="${2}"
  local givenName="${3:-${cn}}"
  local displayName="${4:-${cn}}"
  local password="${5}"
  local cmd=(fastzmprov createAccount "${email}" "${password}" cn "${cn}" displayName "${displayName}" givenName "${givenName}" zimbraPrefFromDisplay "${displayName}")

  execZimbraCmd cmd | hideReturnedId
}

function zimbraUpdateAccountPassword() {
  local email="${1}"
  local hash_password="${2}"
  local cmd=(fastzmprov modifyAccount "${email}" userPassword "${hash_password}")

  execZimbraCmd cmd
}

function zimbraSetPasswordMustChange() {
  local email="${1}"
  local cmd=(fastzmprov modifyAccount "${email}" zimbraPasswordMustChange TRUE)

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

  cmd=(fastzmprov modifyAccount "${email}" zimbraAccountStatus "${status}")
  execZimbraCmd cmd
}

function zimbraSetAccountAlias() {
  local email="${1}"
  local alias="${2}"
  local cmd=(fastzmprov addAccountAlias "${email}" "${alias}")

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

  cmd=(fastzmprov createSignature "${email}" "${name}" "${field}" "${content}")
  execZimbraCmd cmd | hideReturnedId
}

function zimbraSetAccountSetting() {
  local email="${1}"
  local field="${2}"
  local value="${3}"
  local cmd=(fastzmprov modifyAccount "${email}" "${field}" "${value}")

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
  zmmailboxSelectMailbox "${email}"

  local folder="${2}"
  local cmd=(fastzmmailbox createFolder "${folder}")
  execZimbraCmd cmd | hideReturnedId
}

function shellQuietPopd() {
  command popd > /dev/null
}

function shellQuietPushd() {
  command pushd "$@" > /dev/null
}
