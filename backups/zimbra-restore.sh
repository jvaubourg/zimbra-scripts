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

source /usr/share/zimbra-scripts/backups/zimbra-common.inc.sh

# Help function
function exit_usage() {
  local status="${1}"

  cat <<USAGE

  ACCOUNTS
    Already existing accounts in Zimbra will be skipped with a warning,
    except when restoring only data (see -i)

    -m email
      Email of an account to include in the restore
      Cannot be used with -x at the same time
      [Default] All accounts
      [Example] -m foo@example.com -m bar@example.org
      [Example] -m 'foo@example.com bar@example.org'

    -x email
      Email of an account to exclude of the restore
      Cannot be used with -m at the same time
      [Default] No exclusion
      [Example] -x foo@example.com -x bar@example.org
      [Example] -x 'foo@example.com bar@example.org'

    -f
      Force users to change their password next time they connect after the restore

    -r
      Reset passwords of the restored accounts
      Automatically implies -f option

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

  PARTIAL BACKUPS

    -i ASSET
      Do a partial restore by selecting groups of settings/data
      [Default] Everything available in the backup is restored

      [Example] Restore full server without user data:
        -i server_settings -i accounts_settings
      [Example] Restore accounts on an already configured server:
        -i accounts_settings -i accounts_data

      ASSET can be:
        server_settings
          Restore server-side settings (ie. domains, mailing lists, admins list, etc)
        accounts_settings
          Restore accounts settings (ie. identity, password, aliases, signatures, filters, etc)
        accounts_data
          Restore accounts data (ie. folders, mails, contacts, calendars, briefcase, tasks, etc)

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

  EXAMPLES

    (1) Restore everything from the backups saved in /tmp/mybackups/
          zimbra-restore.sh -b /tmp/mybackups/

    (2) Restore everything to the server, but only with the accounts of jdoe@example.com and jfoo@example.org
          zimbra-restore.sh -b /tmp/mybackups/ -m jdoe@example.com -m jfoo@example.org

    (3) Restore only the stuff related to the account of jdoe@example.com and nothing else
        (the domain example.com has to already exist, but not the account jdoe@example.com)
          zimbra-restore.sh -b /tmp/mybackups/ -i accounts_settings -i accounts_data -m jdoe@example.com

USAGE

  # Show help with -h
  if [ "${status}" -eq 0 ]; then
    trap - EXIT
  fi

  exit "${status}"
}


####################
## CORE FUNCTIONS ##
####################

# Called by the main trap if an error occured and the script stops
# Remove the incomplete account if the error occured during its restoration
function cleanFailedProcess() {
  log_debug "Cleaning after fail"

  if [ -n "${_restoring_account}" ]; then
    local ask_remove=y

    if [ "${_debug_mode}" -gt 0 ]; then
      read -p "Remove incomplete account <${_restoring_account}> (default: Y)? " ask_remove
    fi

    if [ -z "${ask_remove}" -o "${ask_remove}" = Y -o "${ask_remove}" = y ]; then
      if zimbraRemoveAccount "${_restoring_account}"; then
        log_info "${_restoring_account}: Incomplete account has been removed"
      fi
    fi

    _restoring_account=
  fi
}

# Return the size in human-readable bytes of the archive containing
# the backuped data of the account
function getAccountDataFileSize() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/data"
  local backup_file="${backup_path}/data.tar"

  printf "%s" "$(du -sh "${backup_file}" | awk '{ print $1 }')B"
}

# Throw an error if the directory exists but is not usable
function checkBackupedDirectoryAccess() {
  local backup_path="${1}"

  if [ -d "${backup_path}" -a \( ! -x "${backup_path}" -o ! -r "${backup_path}" \) ]; then
    log_err "Directory <${backup_path}> exists but is not readable"
    exit 1
  fi
}

# Throw an error if the file (or its parent directory) exists but is not usable
function checkBackupedFileAccess() {
  local backup_file="${1}"
  local backup_path=$(dirname "${backup_file}")

  checkBackupedDirectoryAccess "${backup_path}"

  if [ -f "${backup_file}" -a ! -r "${backup_file}" ]; then
    log_err "File <${backup_file}> exists but is not readable"
    exit 1
  fi
}


#############
## RESTORE ##
#############

# Create domains corresponding to the folders saved in server/domains/
function zimbraRestoreDomains() {
  local backup_path="${_backups_path}/server/domains"

  checkBackupedDirectoryAccess "${backup_path}"
  local domains=$(find "${backup_path}" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2> /dev/null || true)

  if [ -n "${domains}" ]; then
    for domain in ${domains}; do
      if [ "${domain}" != "${_zimbra_install_domain}" ]; then
        log_debug "Server/Settings: Create domain <${domain}>"
        zimbraCreateDomain "${domain}"
      else
        log_debug "Server/Settings: Domain <${domain}> has been skipped because created when installating the server"
      fi
    done
  else
    log_warn "Server/Settings: No backuped domain found"
  fi
}

# Create DKIM keys for the domains that are supposed to use one,
# according to the server/domains/<domain>/dkim_info files
function zimbraRestoreDomainsDkim() {
  local backup_path="${_backups_path}/server/domains"

  checkBackupedDirectoryAccess "${backup_path}"
  local domains=$(find "${backup_path}" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2> /dev/null || true)

  if [ -n "${domains}" ]; then
    for domain in ${domains}; do
      local backup_file="${backup_path}/${domain}/dkim_info"

      if [ -f "${backup_file}" ]; then
        checkBackupedFileAccess "${backup_file}"

        # Unfortunately there is no way in Zimbra to restore an already existing private key
        # so for now, we just generate a new one
        log_info "Server/Settings: Generating new DKIM keys for domain <${domain}>"
        local dkim_pubkey=$(zimbraCreateDkim "${domain}" || true)

        log_info "${dkim_pubkey}"
        _generated_dkim_keys["${domain}"]="${dkim_pubkey}"
      fi
    done
  else
    log_warn "Server/Settings: No backuped domain found"
  fi
}

# Create mailing lists registred in the backup, with aliases and list of members
function zimbraRestoreLists() {
  local backup_path="${_backups_path}/server/lists"

  checkBackupedDirectoryAccess "${backup_path}"
  local lists=$(find "${backup_path}" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2> /dev/null || true)

  if [ -n "${lists}" ]; then
    for list_email in ${lists}; do
      local backup_path_list="${backup_path}/${list_email}"
      local backup_file_members="${backup_path_list}/members"
      local backup_file_aliases="${backup_path_list}/aliases"

      log_debug "Server/Settings: Create mailing list <${list_email}>"
      zimbraCreateList "${list_email}"

      # List aliases
      if [ -f "${backup_file_aliases}" -a -s "${backup_file_aliases}" ]; then
        checkBackupedFileAccess "${backup_file_aliases}"
        log_debug "Server/Settings: Restore aliases of list <${list_email}>"

        while read alias_email; do
          log_debug "Server/Settings: Add <${alias_email}> as an alias of list <${list_email}>"
          zimbraSetListAlias "${list_email}" "${alias_email}"
        done < "${backup_file_aliases}"
      else
        log_debug "Server/Settings: No backuped aliases found for list <${list_email}>"
      fi

      # List members
      if [ -f "${backup_file_members}" -a -s "${backup_file_members}" ]; then
        checkBackupedFileAccess "${backup_file_members}"
        log_debug "Server/Settings: Restore members of list <${list_email}>"

        while read member_email; do
          log_debug "Server/Settings: Add <${member_email}> as a member of list <${list_email}>"
          zimbraSetListMember "${list_email}" "${member_email}"
        done < "${backup_file_members}"
      else
        log_debug "Server/Settings: No backuped list of members found for list <${list_email}>"
      fi
    done
  else
    log_debug "Server/Settings: No backuped mailing lists found"
  fi
}

# Create an email account based on the information available in the identity-related settings
# The default password is a generated one (it's not possible to directly pass an hash)
function zimbraRestoreAccount() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings/identity"

  declare -A fields
  fields=([cn]= [givenName]= [displayName]=)

  checkBackupedDirectoryAccess "${backup_path}"

  for field in "${!fields[@]}"; do
    local backup_file="${backup_path}/${field}"
    checkBackupedFileAccess "${backup_file}"

    if [ -f "${backup_file}" -a -s "${backup_file}" ]; then
      fields[$field]=$(< "${backup_file}")
    fi
  done

  log_debug "${email}: cn=<${fields[cn]}>, givenName=<${fields[givenName]}>, displayName=<${fields[displayName]}>"

  # The hash of the SSL private key is used as a salt
  local generated_password=$(printf '%s' "$(sha256sum ${_zimbra_main_path}/ssl/zimbra/ca/ca.key)${RANDOM}" | sha256sum | cut -c 1-20)

  zimbraCreateAccount "${email}" "${fields[cn]}" "${fields[givenName]}" "${fields[displayName]}" "${generated_password}"
  _generated_account_passwords["${email}"]="${generated_password}"
}

# Update an account password, providing the hash saved in the backup
function zimbraRestoreAccountPassword() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings/identity"
  local backup_file="${backup_path}/userPassword"

  checkBackupedFileAccess "${backup_file}"

  if [ -f "${backup_file}" -a -s "${backup_file}" ]; then
    local userPassword=$(< "${backup_file}")

    zimbraUpdateAccountPassword "${email}" "${userPassword}"
    unset _generated_account_passwords["${email}"]
  else
    log_warn "${email}: No backuped password found"
    log_warn "${email}: You can still use the generated one <${_generated_account_passwords["${email}"]}>"
  fi
}

# Force the user of the account to change their password next time they log in
function zimbraRestoreAccountForcePasswordChanging() {
  local email="${1}"

  zimbraSetPasswordMustChange "${email}"
}

# Lock or unlock an account, to be able to backup or restore it without
# any external change during the process
function zimbraRestoreAccountLock() {
  local email="${1}"

  zimbraSetAccountLock "${email}" true
}

function zimbraRestoreAccountUnlock() {
  local email="${1}"

  zimbraSetAccountLock "${email}" false
}

# Set all the email aliases associated to the account in the backup
function zimbraRestoreAccountAliases() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings"
  local backup_file="${backup_path}/aliases"

  checkBackupedFileAccess "${backup_file}"

  if [ -f "${backup_file}" -a -s "${backup_file}" ]; then
    while read alias; do
      if [ "${alias}" != "root@${_zimbra_install_domain}" -a "${alias}" != "postmaster@${_zimbra_install_domain}" ]; then
        log_debug "${email}/Settings: Create alias <${alias}>"
        zimbraSetAccountAlias "${email}" "${alias}"
      else
        log_debug "${email}/Settings: Alias <${alias}> has been skipped because created during the server installation"
      fi
    done < "${backup_file}"
  else
    log_debug "${email}/Settings: No backuped aliases found"
  fi
}

# Create all the signatures saved in the backup for this account
function zimbraRestoreAccountSignatures() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings/signatures"

  checkBackupedDirectoryAccess "${backup_path}"
  local signatures=$(find "${backup_path}" -mindepth 1 -maxdepth 1 -type f -printf '%f ' 2> /dev/null || true)

  if [ -n "${signatures}" ]; then
    find "${backup_path}" -mindepth 1 | while read backup_file; do
      checkBackupedFileAccess "${backup_file}"

      # The name is stored in the first line of the file
      local name=$(head -n 1 "${backup_file}")
      local content=$(tail -n +2 "${backup_file}")
      local type=txt

      if [[ "${backup_file}" =~ \.html$ ]]; then
        type=html
      fi

      log_debug "${email}/Settings: Create a signature type ${type} named <${name}>"
      zimbraSetAccountSignature "${email}" "${name}" "${type}" "${content}"
    done
  else
    log_debug "${email}/Settings: No backuped signatures found"
  fi
}

function zimbraRestoreAccountOtherSettings() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings/others"

  checkBackupedDirectoryAccess "${backup_path}"
  local settings=$(find "${backup_path}" -mindepth 1 -maxdepth 1 -type f -name '[0-9][0-9]*-zimbra*' -printf '%f ' 2> /dev/null || true)

  if [ -n "${settings}" ]; then
    for setting in ${settings}; do
      local backup_file="${backup_path}/${setting}"
      checkBackupedFileAccess "${backup_file}"

      local value=$(< "${backup_file}")
      local field=${setting#*-}

      zimbraSetAccountSetting "${email}" "${field}" "${value}" > /dev/null
    done
  else
    log_debug "${email}/Settings: No other backuped settings found"
  fi
}

# Restore all the data for the account, with folders/mails/tasks/calendar/etc
function zimbraRestoreAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/data"
  local backup_file="${backup_path}/data.tar"

  checkBackupedFileAccess "${backup_file}"

  if [ -f "${backup_file}" -a -s "${backup_file}" ]; then
    zimbraSetAccountData "${email}" "${backup_file}"
  else
    log_warn "${email}/Data: No backuped data found"
  fi
}

# Create all the folders which were excluded during the backup of the account
# Obviously, the folders are now empty but ready to be used again with the Siever filters
function zimbraRestoreAccountDataExcludedPaths() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/data"
  local backup_file="${backup_path}/excluded_data_paths_full"

  checkBackupedFileAccess "${backup_file}"

  if [ -f "${backup_file}" -a -s "${backup_file}" ]; then
    while read path; do
      zimbraCreateDataFolder "${email}" "${path}"
    done < "${backup_file}"
  else
    log_debug "${email}/Data: No list of excluded data paths found"
  fi
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=ZIMBRA-RESTORE
_backups_include_accounts=
_backups_exclude_accounts=
_option_force_change_passwords=false
_option_reset_passwords=false
_include_all=true
_include_server_settings=false
_include_accounts_settings=false
_include_accounts_data=false
_accounts_to_restore=
_restoring_account=

# Will be changed by zimbraRestoreAccount and zimbraRestoreAccountPassword
declare -A _generated_account_passwords

# Up to date by zimbraRestoreDomainsDkim
declare -A _generated_dkim_keys

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

while getopts 'm:x:frb:p:u:i:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -E ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -E ${_backups_exclude_accounts} ${OPTARG}) ;;
    f) _option_force_change_passwords=true ;;
    r) _option_reset_passwords=true
       _option_force_change_passwords=true ;;
    b) _backups_path="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    i) _include_all=false
       for subopt in ${OPTARG}; do
         case "${subopt}" in
           server_settings) _include_server_settings=true ;;
           accounts_settings) _include_accounts_settings=true ;;
           accounts_data) _include_accounts_data=true ;;
           *) log_err "Value <${subopt}> not supported by option -i"; exit 1 ;;
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

if [ -d "${FASTZMPROV_TMP-}" ]; then
  _fastprompt_zmprov_tmp="${FASTZMPROV_TMP}"
fi

if [ -d "${FASTZMMAILBOX_TMP-}" ]; then
  _fastprompt_zmmailbox_tmp="${FASTZMMAILBOX_TMP}"
fi

if [ -n "${_backups_include_accounts}" -a -n "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not compatible"
  exit 1
fi

if ! "${_include_all}" && ! "${_include_accounts_settings}" && "${_option_force_change_passwords}" ; then
  log_err "Options -f and -r are usable only when restoring accounts settings and/or data"
  exit 1
fi

if ! ${_include_all} && ! ${_include_accounts_settings} && ! ${_include_accounts_data} &&\
  [ -n "${_backups_include_accounts}" -o -n "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not usable when no account settings and/or data are intended to be restored (see -i)"
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

initFastPrompts

log_info "Getting Zimbra main domain"
_zimbra_install_domain=$(zimbraGetMainDomain || true)
log_debug "Zimbra main domain is <${_zimbra_install_domain}>"

(${_include_all} || ${_include_server_settings}) && {
  log_info "Server/Settings: Restoring domains"
  zimbraRestoreDomains

  log_info "Server/Settings: Restoring DKIM keys"
  zimbraRestoreDomainsDkim

  log_info "Server/Settings: Restoring mailing lists"
  zimbraRestoreLists
}

(${_include_all} || ${_include_accounts_settings} || ${_include_accounts_data}) && {
  _accounts_to_restore=$(selectAccountsToRestore "${_backups_include_accounts}" "${_backups_exclude_accounts}" || true)

  if [ -z "${_accounts_to_restore}" ]; then
    log_debug "No account to restore"
  else
    log_debug "Accounts to restore: ${_accounts_to_restore}"

    # Restore accounts
    for email in ${_accounts_to_restore}; do

      # Skip the account if already existing, except if only the data has to be restored
      if zimbraIsAccountExisting "${email}" && (${_include_accounts_settings} || ! ${_include_accounts_data}); then
        log_warn "${email}: Has been skipped because already existing in Zimbra"
      else
        resetAccountProcessDuration

        # Create account
        (${_include_all} || ${_include_accounts_settings}) && {
          if zimbraIsInstallUser "${email}"; then
            log_debug "${email}: Creation has been skipped because it's the user used for installing the server"
          else
            # Create account with the identity-related settings
            log_info "${email}: Creating account"
            zimbraRestoreAccount "${email}"

            _restoring_account="${email}"

            # Restore the password or keep the generated one
            if ${_option_reset_passwords}; then
              log_info "${email}: New password is ${_generated_account_passwords["${email}"]}"
            else
              log_info "${email}: Restoring former password"
              zimbraRestoreAccountPassword "${email}"
            fi

            # Force password changing
            if ${_option_force_change_passwords}; then
              log_info "${email}: Force user to change the password next time they log in"
              zimbraRestoreAccountForcePasswordChanging "${email}"
            fi
          fi
        }

        log_info "${email}: Restoring account"

        log_info "${email}: Locking for the time of the restoration"
        zimbraRestoreAccountLock "${email}"

        # Restore other settings
        (${_include_all} || ${_include_accounts_settings}) && {
          log_info "${email}: Restoring settings"

          log_info "${email}/Settings: Restoring aliases"
          zimbraRestoreAccountAliases "${email}"

          log_info "${email}/Settings: Restoring signatures"
          zimbraRestoreAccountSignatures "${email}"

          log_info "${email}/Settings: Restoring other settings"
          zimbraRestoreAccountOtherSettings "${email}"
        }

        # Restore data
        (${_include_all} || ${_include_accounts_data}) && {
          log_info "${email}: Restoring data ($(getAccountDataFileSize "${email}" || true) compressed)"
          zimbraRestoreAccountData "${email}"

          log_debug "${email}/Data: Restore excluded paths as empty folders"
          zimbraRestoreAccountDataExcludedPaths "${email}"
        }

        log_info "${email}: Unlocking"
        zimbraRestoreAccountUnlock "${email}"

        showAccountProcessDuration
        _restoring_account=
      fi
    done
  fi
}

showFullProcessDuration

exit 0
