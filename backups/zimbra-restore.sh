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
        accounts
          Do not restore any accounts at all
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
        log_info "The account <${_restoring_account}> has been removed"
      fi
    fi

    _restoring_account=
  fi
}

# Check if the settings file of the account backup is ready to be used
# Useful for backups to check if zimbraBackupAccountSettings has been already
# called to create the file
function checkAccountSettingsFile() {
  local email="${1}"
  local backup_file="${_backups_path}/accounts/${email}/settings"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "File <${backup_file}> is missing, is not a regular file or is not readable"
    exit 1
  fi
}

# Extract the value of a setting from the settings file available in the backup
# Should be secured with a call to checkAccountSettingsFile before using it
function extractFromAccountSettingsFile() {
  local email="${1}"
  local field="${2}"
  local backup_file="${_backups_path}/accounts/${email}/settings"
  local value=$( (sed -n -e '/^'$field':/,/^[a-zA-Z0-9]*:/ p' ${backup_file} || true) | sed '$ d' | sed -e 's/^'$field': //g')

  printf '%s' "${value}"
}

# Return the size in human-readable bytes of a data.tar file
function getAccountDataFileSize() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tar"

  printf "%s" "$(du -sh "${backup_file}" | awk '{ print $1 }')B"
}


#############
## RESTORE ##
#############

# Create the domains written in a list available in the backup
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
      log_debug "Skip domain <$domain> creation (install domain)"
    fi
  done < "${backup_file}"
}

# Create DKIM keys for the domains that are supposed to use one,
# according to the list of backuped DKIM keys
function zimbraRestoreDomainsDkim() {
  local backup_path="${_backups_path}/admin/domains_dkim"
  local domains=$(ls "${backup_path}")

  for domain in ${domains}; do
    local backup_file="${backup_path}/${domain}"

    if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
      log_err "File <${backup_file}> is not a regular file or is not readable"
      exit 1
    fi

    # Unfortunately there is no way in Zimbra to restore an already existing private key
    log_info "Generating new DKIM keys for <${domain}>"
    local dkim_pubkey=$(zimbraCreateDkim "${domain}")

    log_info "${dkim_pubkey}"
    _generated_dkim_keys["${domain}"]="${dkim_pubkey}"
  done
}

# Create mailing lists registred in the backup, and associate all their members
function zimbraRestoreLists() {
  local backup_path="${_backups_path}/lists"
  local lists=$(ls "${backup_path}")

  for list_email in ${lists}; do
    local backup_list_path="${backup_path}/${list_email}"

    if [ ! -d "${backup_list_path}" -o ! -x "${backup_list_path}" -o ! -r "${backup_list_path}" ]; then
      log_err "Directory <$backup_list_path> is not a directory or is not readable"
      exit 1
    fi

    local backup_file_members="${backup_list_path}/members"

    if [ ! -f "${backup_file_members}" -o ! -r "${backup_file_members}" ]; then
      log_err "File <${backup_file_members}> is not a regular file or is not readable"
      exit 1
    fi

    local backup_file_aliases="${backup_list_path}/aliases"

    if [ ! -f "${backup_file_aliases}" -o ! -r "${backup_file_aliases}" ]; then
      log_err "File <${backup_file_aliases}> is not a regular file or is not readable"
      exit 1
    fi

    log_debug "Creating mailing list <${list_email}>"
    zimbraCreateList "${list_email}"

    log_debug "Importing mailing list <${list_email}> members"
    while read member_email; do
      log_debug "${list_email}: Add <${member_email}> as a member"
      zimbraSetListMember "${list_email}" "${member_email}"
    done < "${backup_file_members}"

    log_debug "Importing mailing list <${list_email}> aliases"
    while read alias_email; do
      log_debug "${list_email}: Add <${alias_email}> as an alias"
      zimbraSetListAlias "${list_email}" "${alias_email}"
    done < "${backup_file_aliases}"

  done
}

# Create an email account based on the information available in the settings file
# The default password is a generated one (it's not possible to directly pass an hash)
function zimbraRestoreAccount() {
  local email="${1}"

  checkAccountSettingsFile "${email}"

  local cn=$(extractFromAccountSettingsFile "${email}" cn)
  local givenName=$(extractFromAccountSettingsFile "${email}" givenName)
  local displayName=$(extractFromAccountSettingsFile "${email}" displayName)

  # The hash of the SSL private key is used as a salt
  local generated_password=$(printf '%s' "$(sha256sum ${_zimbra_main_path}/ssl/zimbra/ca/ca.key)${RANDOM}" | sha256sum | cut -c 1-20)

  zimbraCreateAccount "${email}" "${cn}" "${givenName}" "${displayName}" "${generated_password}"
  _generated_account_passwords["${email}"]="${generated_password}"
}

# Update the password on an account with a hash, to restore the password
# stored in the settings file
function zimbraRestoreAccountPassword() {
  local email="${1}"

  checkAccountSettingsFile "${email}"
  local userPassword=$(extractFromAccountSettingsFile "${email}" userPassword)

  zimbraUpdateAccountPassword "${email}" "${userPassword}"
  unset _generated_account_passwords["${email}"]
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

# Set the CatchAllAddress of an account if a domain to catch was backuped
# A CatchAll enables an account to receive all the mails sent to non-existing
# email addresses for that domain
function zimbraRestoreAccountCatchAll() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/catch_all"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Catch-all will *NOT* be restored"
    return
  fi

  local at_domain=$(head -n1 "${backup_file}")

  if [ -n "${at_domain}" ]; then
    log_debug "${email}: Is a CatchAll for <${at_domain}>"
    zimbraSetAccountCatchAll "${email}" "${at_domain}"
  fi
}

function zimbraRestoreAccountForwarding() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/forwarding"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Forwarding setting will *NOT* be restored"
    return
  fi

  local to_email=$(sed -n 1p "${backup_file}")

  if [ -n "${to_email}" ]; then
    local keep_copies=$(sed -n 2p "${backup_file}")

    if [ "${keep_copies}" = 'TRUE' ]; then
      keep_copies=true
      log_debug "${email}: Forwards to <${to_email}> (with copies)"
    else
      keep_copies=false
      log_debug "${email}: Forwards to <${to_email}> (with no copies)"
    fi

    zimbraSetAccountForwarding "${email}" "${to_email}" "${keep_copies}"
  fi
}

# Set all the email aliases registred for an account in the backup
function zimbraRestoreAccountAliases() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/aliases"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Aliases will *NOT* be restored"
    return
  fi

  while read alias; do
    if [ "${alias}" != "root@${_zimbra_install_domain}" -a "${alias}" != "postmaster@${_zimbra_install_domain}" ]; then
      zimbraSetAccountAlias "${email}" "${alias}"
    else
      log_debug "${email}: Skip alias <${alias}> creation (install alias)"
    fi
  done < "${backup_file}"
}

# Create all the signatures saved in the backup for that email account
function zimbraRestoreAccountSignatures() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/signatures"

  if [ ! -d "${backup_path}" -o ! -r "${backup_path}" ]; then
    log_err "${email}: Path <${backup_path}> is missing, is not a directory or is not readable"
    log_err "${email}: Signatures will *NOT* be restored"
    return
  fi

  find "${backup_path}" -mindepth 1 | while read backup_file
  do
    if [ ! -f "${backup_file}" -a -r "${backup_file}" ]; then
      log_err "${email}: File <${backup_file}> is not a regular file or is not readable"
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

# Create all the Sieve filters defined by the user to automatically redirect input emails
# to custom folders of the account
function zimbraRestoreAccountFilters() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/filters"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Filters will *NOT* be restored"
    return
  fi

  zimbraSetAccountFilters "${email}" "${backup_file}"
}

# Restore Out Of Office settings for the account
function zimbraRestoreAccountOOO() {
  local ooo_settings="zimbraFeatureOutOfOfficeReplyEnabled
                      zimbraPrefOutOfOfficeCacheDuration
                      zimbraPrefOutOfOfficeExternalReply
                      zimbraPrefOutOfOfficeExternalReplyEnabled
                      zimbraPrefOutOfOfficeFromDate
                      zimbraPrefOutOfOfficeReply
                      zimbraPrefOutOfOfficeReplyEnabled
                      zimbraPrefOutOfOfficeStatusAlertOnLogin
                      zimbraPrefOutOfOfficeUntilDate"

  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/settings"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Account Out Of Office settings will *NOT* be restored"
    return
  fi

  for field in $ooo_settings; do
     local value=$(extractFromAccountSettingsFile $email $field)
     zimbraSetAccount "${email}" "${field}" "${value}"
  done

}

# Restore all the data for the account, with folders/mails/tasks/calendar/etc
function zimbraRestoreAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/data.tar"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Account data will *NOT* be restored"
    return
  fi

  zimbraSetAccountData "${email}" "${backup_file}"
}

# Create all the folders which were excluded during the backup of the account
# Obviously, the folders are now empty but ready to be used again with the Siever filters
function zimbraRestoreAccountDataExcludedPaths() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/excluded_data_paths_full"

  if [ ! -f "${backup_file}" -o ! -r "${backup_file}" ]; then
    log_err "${email}: File <${backup_file}> is missing, is not a regular file or is not readable"
    log_err "${email}: Excluded folders in the data will *NOT* be recreated"
    return
  fi

  while read path; do
    zimbraCreateDataFolder "${email}" "${path}"
  done < "${backup_file}"
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=ZIMBRA-RESTORE
_backups_include_accounts=
_backups_exclude_accounts=
_option_force_change_passwords=false
_option_reset_passwords=false
_exclude_domains=false
_exclude_lists=false
_exclude_settings=false
_exclude_aliases=false
_exclude_signatures=false
_exclude_filters=false
_exclude_accounts=false
_exclude_data=false
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

while getopts 'm:x:frb:p:u:e:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -E ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -E ${_backups_exclude_accounts} ${OPTARG}) ;;
    f) _option_force_change_passwords=true ;;
    r) _option_reset_passwords=true
       _option_force_change_passwords=true ;;
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
           accounts) _exclude_accounts=true ;;
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

if [ -n "${_backups_include_accounts}" -a -n "${_backups_exclude_accounts}" ]; then
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

  log_info "Restoring DKIM keys"
  zimbraRestoreDomainsDkim
}

${_exclude_lists} || {
  log_info "Restoring mailing lists"
  zimbraRestoreLists
}

${_exclude_accounts} || {
  _accounts_to_restore=$(selectAccountsToRestore "${_backups_include_accounts}" "${_backups_exclude_accounts}")
  
  if [ -z "${_accounts_to_restore}" ]; then
    log_debug "No account to restore"
  else
    log_debug "Accounts to restore: ${_accounts_to_restore}"
  
    # Restore accounts
    for email in ${_accounts_to_restore}; do
      if zimbraIsAccountExisting "${email}"; then
        log_warn "Skip account <${email}> (already exists in Zimbra)"
      else
        resetAccountProcessDuration
  
        # Create account
        if zimbraIsInstallUser "${email}"; then
          log_debug "Skip account <${email}> creation (install user)"
        else
          log_info "Creating account <${email}>"
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
  
        # Restore other settings and data
        log_info "Restoring account <${email}>"
  
        log_info "${email}: Locking the account"
        zimbraRestoreAccountLock "${email}"
  
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
  
        ${_exclude_settings} || {
          log_info "${email}: Restoring settings"
  
          log_debug "${email}: Restore CatchAll setting"
          zimbraRestoreAccountCatchAll "${email}"
  
          log_debug "${email}: Restore Forwarding setting"
          zimbraRestoreAccountForwarding "${email}"

          log_debug "${email}: Restore OutOfOffice settings"
          zimbraRestoreAccountOOO "${email}"
        }
    
        ${_exclude_data} || {
          log_info "${email}: Restoring data ($(getAccountDataFileSize "${email}") compressed)"
          zimbraRestoreAccountData "${email}"
  
          log_debug "${email}: Restore excluded paths as empty folders"
          zimbraRestoreAccountDataExcludedPaths "${email}"
        }
  
        log_info "${email}: Unlocking the account"
        zimbraRestoreAccountUnlock "${email}"
    
        showAccountProcessDuration
        _restoring_account=
      fi
    done
  fi
}

showFullProcessDuration

exit 0
