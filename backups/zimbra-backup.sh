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
    Accounts with an already existing backup folder will be skipped with a warning.

    -m email
      Email of an account to include in the backup
      Cannot be used with -x at the same time
      [Default] All accounts
      [Example] -m foo@example.com -m bar@example.org
      [Example] -m 'foo@example.com bar@example.org'

    -x email
      Email of an account to exclude of the backup
      Cannot be used with -m at the same time
      [Default] No exclusion
      [Example] -x foo@example.com -x bar@example.org
      [Example] -x 'foo@example.com bar@example.org'

    -s path
      Path of a folder to skip when backuping data from accounts
      (can be a POSIX BRE regex for grep between ^ and $)
      [Default] No exclusion
      [Example] -s /Briefcase/movies -s '/Inbox/list-.*' -s '.*/nobackup'

    -l
      Lock the accounts just before starting to backup them
      Locks are NOT removed after the backup: useful when reinstalling the server
      [Default] Not locked

  ENVIRONMENT

    -b path
      Where to save the backups
      [Default] ${_backups_path}

    -p path
      Main path of the Zimbra installation
      [Default] ${_zimbra_main_path}

    -u user
      Zimbra UNIX user
      [Default] ${_zimbra_user}

    -g group
      Zimbra UNIX group
      [Default] ${_zimbra_group}

  PARTIAL BACKUPS

    -i ASSET
      Do a partial backup by selecting groups of settings/data
      [Default] Everything is backuped

      [Example] Backup full server configuration without user data:
        -i server_settings -i accounts_settings
      [Example] Backup accounts but not the configuration of the server itself:
        -i accounts_settings -i accounts_data

      ASSET can be:
        server_settings
          Backup server-side settings (ie. domains, mailing lists, admins list, etc)
        accounts_settings
          Backup accounts settings (ie. identity, password, aliases, signatures, filters, etc)
        accounts_data
          Backup accounts data (ie. folders, mails, contacts, calendars, briefcase, tasks, etc)

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

    (1) Backup everything in /tmp/mybackups/
          zimbra-backup.sh -b /tmp/mybackups/

    (2) When backuping the mailboxes, the data inside every folder named "nobackup" will be ignored.
        Ask to your users to create an IMAP folder named "nobackup" and to put inside all their
        non-important emails (even in subfolders). Ask for the same thing but with their files in the
        Briefcase. Involve them in the issues raised by the cost of the space allocated for the backups!
          zimbra-backup.sh -b /tmp/mybackups/ -s '.*/nobackup'

    (3) Backup everything from the server, but only with the accounts of jdoe@example.com and jfoo@example.org
          zimbra-backup.sh -b /tmp/mybackups/ -m jdoe@example.com -m jfoo@example.org

    (4) Backup only the stuff related to the account of jdoe@example.com and nothing else
          zimbra-backup.sh -b /tmp/mybackups/ -i accounts_settings -i accounts_data -m jdoe@example.com

USAGE

  # Show help with -h
  if [ "${status}" -eq 0 ]; then
    trap - EXIT
  fi

  exit "${status}"
}

function removeFileIfEmpty() {
  local file="${1}"

  if [ -f "${file}" -a ! -s "${file}" ]; then
    rm -f "${file}"
  fi
}


####################
## CORE FUNCTIONS ##
####################

# Called by the main trap if an error occured and the script stops
# Remove the incomplete account backup if the error occured during its creation
function cleanFailedProcess() {
  log_debug "Cleaning after fail"

  if [ -n "${_backuping_account}" -a -d "${_backups_path}/accounts/${_backuping_account}" ]; then
    local ask_remove=y

    if [ "${_debug_mode}" -gt 0 ]; then
      read -p "Remove failed account backup <${_backups_path}/accounts/${_backuping_account}> (default: Y)? " ask_remove
    fi

    if [ -z "${ask_remove}" -o "${ask_remove}" = Y -o "${ask_remove}" = y ]; then
      if rm -rf "${_backups_path}/accounts/${_backuping_account}"; then
        log_info "${email}: Failed backup has been removed"
      fi
    fi

    _backuping_account=
  fi
}

# Save the list of folders to exclude from the backup of this account, based on the option passed to the script
# The excluded_data_paths file will contain the top folders to exclude (and so the subfolders will be excluded in the same time)
# The excluded_data_paths_full will contain a full list of the excluded folders, to be able to restore them (empty) with all
# of their subfolders (they can be implied in the Sieve filters defined for the account)
function selectAccountDataPathsToExclude() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/data"
  local backup_file="${backup_path}/excluded_data_paths"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  if [ "${#_backups_exclude_data_regexes[@]}" -gt 0 ]; then
    local folders=$(zimbraGetAccountFoldersList "${email}" || true)

    for regex in "${_backups_exclude_data_regexes[@]}"; do
      local selected_folders=$(printf '%s' "${folders}" | (grep -- "^${regex}\\(\$\\|/.*\\)" || true))

      if [ -n "${selected_folders}" ]; then
        log_debug "${email}/Data: Raw list of the folders selected to be excluded: $(echo -En ${selected_folders})"

        # Will be used to restore the (empty) folders and subfolders
        printf '%s\n' "${selected_folders}" > "${backup_file}_full"

        if [ "$(printf '%s\n' "${selected_folders}" | wc -l)" -gt 1 ]; then

          # We need to be sure that some selected folders are not included in other ones
          while [ -n "${selected_folders}" ]; do
            local first=$(printf '%s' "${selected_folders}" | head -n 1)
            local first_escaped=$(escapeGrepStringRegexChars "${first}" || true)

            # The list of folders is sorted by Zimbra so the first path cannot be included in another one
            log_debug "${email}/Data: Folder <${first}> will be excluded"
            printf '%s\n' "${first}" >> "${backup_file}"

            # Remove the saved folder and all of its subfolders from the selection and start again with the parent loop
            selected_folders=$(printf '%s' "${selected_folders}" | (grep -v -- "^${first_escaped}\\(\$\\|/\\)" || true))
          done
        else
          log_debug "${email}/Data: Folder <$(echo -En ${selected_folders})> will be excluded"
          printf '%s\n' "${selected_folders}" > "${backup_file}"
        fi
      fi
    done
  fi
}

# Return the total size in human-readable bytes of the excluded folders
# Used for the logging, to show who really uses the "excluded folders" feature and how many bytes
# are saved in the backups
function getAccountExcludeDataSize() {
  local email="${1}"
  local exclude_paths="${2}"
  local total_size_bytes=0
  local total_size_human=

  for path in ${exclude_paths}; do
    local size_attributes=$(zimbraGetFolderAttributes "${email}" "${path}" | grep '^\s\+"size":' || true)
    local size_bytes=$(printf '%s' "${size_attributes}" | sed 's/^.*:\s\+\([0-9]\+\).*$/\1/' | paste -sd+ | bc)
    total_size_bytes=$(( total_size_bytes + size_bytes ))
  done

  total_size_human=$(numfmt --to=iec --suffix=B "${total_size_bytes}")

  printf '%s' "${total_size_human}"
}

# Return the total size in human-readable bytes of the data to backup for the account, excluding the size
# of the folders to exclude
function getAccountIncludeDataSize() {
  local email="${1}"
  local exclude_size_human="${2}"

  local exclude_size_bytes=$(numfmt --from=iec --suffix=B "${exclude_size_human}" | tr -d B)
  local data_size_bytes=$(zimbraGetAccountDataSize "${email}" | numfmt --from=iec --suffix=B | tr -d B || true)
  local include_size_human=$(numfmt --to=iec --suffix=B "$(( data_size_bytes - exclude_size_bytes ))")

  printf '%s' "${include_size_human}"
}

# Lock the account to be sure that nothing happens during the backup process
# The accounts will be locked "forever", because it probably means that the server will be reinstalled
# with a restoration
function zimbraAccountLock() {
  local email="${1}"

  zimbraSetAccountLock "${email}" true
}


#############
## BACKUPS ##
#############

# Save a list of the accounts marked as admin
function zimbraBackupServerAdmins() {
  local backup_path="${_backups_path}/server"
  local backup_file="${backup_path}/admin_accounts"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAdminAccounts > "${backup_file}"
  removeFileIfEmpty "${backup_file}"
}

# Save a list of the registred domains
function zimbraBackupServerDomains() {
  local backup_path="${_backups_path}/server/domains"

  for domain in $(zimbraGetDomains || true); do
    install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}/${domain}"
  done
}

# Save the DKIM info for domains using this feature
# Usable only after calling zimbraBackupServerDomains
function zimbraBackupServerDomainsDkim() {
  local backup_path="${_backups_path}/server/domains"
  local domains=$(find "${backup_path}" -mindepth 1 -maxdepth 1 -type d -printf '%f ')

  for domain in ${domains}; do
    local backup_path_dkim="${backup_path}/${domain}"
    local backup_file="${backup_path_dkim}/dkim_info"

    install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path_dkim}"

    zimbraGetDkimInfo "${domain}" | (grep -v 'No DKIM Information' || true) > "${backup_file}"
    removeFileIfEmpty "${backup_file}"
  done
}

# Save all existing mailing lists with their aliases and a list of their members
function zimbraBackupServerLists() {
  for list_email in $(zimbraGetLists || true); do
    local backup_path="${_backups_path}/server/lists/${list_email}"
    local backup_file=

    install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

    log_debug "Server/Settings: Backup members of list <${list_email}>"
    backup_file="${backup_path}/members"
    zimbraGetListMembers "${list_email}" | (grep -F @ | grep -v '^#' || true) > "${backup_file}"
    removeFileIfEmpty "${backup_file}"

    log_debug "Server/Settings: Backup aliases of list <${list_email}>"
    backup_file="${backup_path}/aliases"
    zimbraGetListAliases "${list_email}" | (grep -F @ | grep -v '^#' | grep -v "^${list_email}\$" || true) > "${backup_file}"
    removeFileIfEmpty "${backup_file}"
  done
}

# Save the raw list of settings generated by Zimbra for an account
# The list doesn't look really reliable (eg. Sieve filters are truncated when too big),
# and pieces of information are missing
function zimbraBackupAccountSettingsFile() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings"
  local backup_file="${backup_path}/all_settings"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAccountSettingsFile "${email}" > "${backup_file}"
}

# Save account identity-related settings
function zimbraBackupAccountIdentitySettings() {
  local email="${1}"
  local fields="cn givenName displayName userPassword"
  local backup_path="${_backups_path}/accounts/${email}/settings/identity"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  for field in ${fields}; do
    local backup_file="${backup_path}/${field}"

    log_debug "${email}/Settings: Backup setting <${field}>"
    zimbraGetAccountSetting "${email}" "${field}" > "${backup_file}"
    removeFileIfEmpty "${backup_file}"
  done
}

# Save (most) user-defined settings for the account
# Has to be called after zimbraBackupAccountSettingsFile
function zimbraBackupAccountPrefSettings() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings/pref"
  local settings_file="${_backups_path}/accounts/${email}/settings/all_settings"
  local fields=$(grep '^zimbraPref' "${settings_file}" | sed 's/^\([^:]\+\).*/\1/' | sort)

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  for field in ${fields}; do
    if [[ ! "${field}" =~ Signature ]]; then
      local backup_file="${backup_path}/${field}"

      log_debug "${email}/Settings: Backup setting <${field}>"

      # Best effort on the pref settings
      if zimbraGetAccountSetting "${email}" "${field}" > "${backup_file}" 2> /dev/null; then
        removeFileIfEmpty "${backup_file}"
      else
        log_warn "${email}/Settings: Unable to save value of <${field}>"
        rm -f "${backup_file}"
      fi
    fi
  done
}

# Save misc settings for the account
function zimbraBackupAccountMiscSettings() {
  local email="${1}"
  local fields="${2}"
  local backup_path="${_backups_path}/accounts/${email}/settings/misc"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  for field in ${fields}; do

    # Backup files start with a number to be able to restore them in the same order
    local backup_file_id=$(printf '%03d' "${_backups_settings_current_id}")
    local backup_file="${backup_path}/${backup_file_id}-${field}"

    log_debug "${email}/Settings: Backup setting <${field}>"

    # Best effort on the misc settings
    if zimbraGetAccountSetting "${email}" "${field}" > "${backup_file}" 2> /dev/null; then
      removeFileIfEmpty "${backup_file}"
    else
      log_warn "${email}/Settings: Unable to save value of <${field}>"
      rm -f "${backup_file}"
    fi

    if [ -f "${backup_file}" ]; then
      (( _backups_settings_current_id++ ))
    fi
  done
}

# Save all the email aliases associated to the account
function zimbraBackupAccountSettingAliases() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}"
  local backup_file="${backup_path}/settings/aliases"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  zimbraGetAccountAliases "${email}" | (grep -v "^${email}\$" || true) > "${backup_file}"
  removeFileIfEmpty "${backup_file}"
}

# Save all signatures created for the account
# Signatures can be TXT or HTML and have a name
function zimbraBackupAccountSettingSignatures() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/settings/signatures"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  # Save signatures individually in files 1, 2, 3, etc
  zimbraGetAccountSignatures "${email}" | awk "/^# name / { file=\"${backup_path}/\"++i; next } { print > file }"

  # Every signature file has to be parsed to reorganize the information inside
  find "${backup_path}" -mindepth 1 | while read tmp_backup_file; do
    local extension='txt'

    # Save the name of the signature from the Zimbra field
    local name=$((grep '^zimbraSignatureName: ' "${tmp_backup_file}" || true) | sed 's/^zimbraSignatureName: //')

    # A signature with no name is possible with older versions of Zimbra
    if [ -z "${name}" ]; then
      log_warn "${email}/Settings: One signature not saved (no name)"
    else

      # A field zimbraPrefMailSignatureHTML instead of zimbraPrefMailSignature means an HTML signature
      if grep -Fq zimbraPrefMailSignatureHTML "${tmp_backup_file}"; then
        extension=html
      fi

      # Remove the field name prefixing the signature
      sed 's/zimbraPrefMailSignature\(HTML\)\?: //' -i "${tmp_backup_file}"

      # Save the name of the signature in the first line
      # Rename the file to indicate if the signature is html or plain text
      local backup_file="${tmp_backup_file}.${extension}"
      printf '%s\n' "${name}" > "${backup_file}"

      # Remove every line corresponding to a Zimbra field and not the signature content itself
      (grep -iv '^zimbra[a-z]\+: ' "${tmp_backup_file}" || true) >> "${backup_file}"

      # Remove the last empty line
      sed '${ /^$/d }' -i "${backup_file}"
    fi

    rm -f "${tmp_backup_file}"
  done

  # Remove signature/ folder if no signature was found (ie. empty folder)
  find "${backup_path}" -maxdepth 0 -type d -empty -exec rmdir '{}' \;
}

# Save all the data for the account, with folders/mails/tasks/calendar/etc
# A TAR file is created and the size of the data to backup and to not backup are shown in logs
function zimbraBackupAccountData() {
  local email="${1}"
  local backup_path="${_backups_path}/accounts/${email}/data"
  local backup_file="${backup_path}/data.tar"
  local backup_data_size=0B
  local filter_query=

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  # Create an excluded_data_paths containing the list of folders to not backup in the data
  # (based on -s options given to the script)
  selectAccountDataPathsToExclude "${email}"

  # If there are folders to exclude, the size of the data to backup is not the size of the account
  # and a query filter has to be created to ask Zimbra to not select them for the data export
  if [ -s "${backup_path}/excluded_data_paths" ]; then
    log_debug "${email}/Data: Calculate sizes of what is going to be backuped or excluded"

    local exclude_paths=$(< "${backup_path}/excluded_data_paths")
    local exclude_paths_count=$(wc -l "${backup_path}/excluded_data_paths" | awk '{ print $1 }')
    local exclude_data_size=$(getAccountExcludeDataSize "${email}" "${exclude_paths}" || true)
    backup_data_size=$(getAccountIncludeDataSize "${email}" "${exclude_data_size}" || true)

    # Creating the filter query to exclude folders during the data export
    while read path; do
      local escaped_path="${path//\"/\\\"}"
      filter_query="${filter_query} and not under:\"${escaped_path}\""
    done < "${backup_path}/excluded_data_paths"

    log_info "${email}/Data: ${exclude_data_size} will be excluded (${exclude_paths_count} folders)"

  # No folder to exclude
  else
    log_debug "${email}/Data: Calculate total size (nothing to exclude)"
    backup_data_size=$(zimbraGetAccountDataSize "${email}" || true)
  fi

  if [ -n "${filter_query}" ]; then
    filter_query="&query=${filter_query/ and /}"
    log_debug "${email}/Data: Filter query is <${filter_query}>"
  fi

  log_info "${email}/Data: ${backup_data_size} are going to be backuped"
  zimbraGetAccountData "${email}" "${filter_query}" > "${backup_file}"
}

# Save info about how was done the backup and in which environment
function backupInfo() {
  local backup_path="${_backups_path}/backup_info"

  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"

  # Substitution ${var@Q} is not available in Bash 4
  printf '%q ' "${@}" > "${backup_path}/command_line"
  echo >> "${backup_path}/command_line"
  date > "${backup_path}/date"
  zimbraGetVersion > "${backup_path}/zimbra_version"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" /etc/redhat-release "${backup_path}/centos_version"

  # Current backup/restore scripts are saved to be sure to be able to restore the backup, even if the
  # expected structure changes over the time
  backup_path="${backup_path}/scripts"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" -d "${backup_path}"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" /usr/share/zimbra-scripts/backups/zimbra-backup.sh "${backup_path}"
  install -o "${_zimbra_user}" -g "${_zimbra_group}" /usr/share/zimbra-scripts/backups/zimbra-restore.sh "${backup_path}"
}


########################
### GLOBAL VARIABLES ###
########################

_log_id=ZIMBRA-BACKUP
_backups_include_accounts=
_backups_exclude_accounts=
_backups_lock_accounts=false
_backups_exclude_data_regexes=()
_backups_settings_current_id=1
_include_all=true
_include_server_settings=false
_include_accounts_settings=false
_include_accounts_data=false
_accounts_to_backup=
_backuping_account=

# Traps
trap 'trap_exit $LINENO' EXIT TERM ERR
trap 'exit 1' INT


###############
### OPTIONS ###
###############

while getopts 'm:x:s:lb:p:u:g:i:d:h' opt; do
  case "${opt}" in
    m) _backups_include_accounts=$(echo -En ${_backups_include_accounts} ${OPTARG}) ;;
    x) _backups_exclude_accounts=$(echo -En ${_backups_exclude_accounts} ${OPTARG}) ;;
    s) _backups_exclude_data_regexes+=("${OPTARG%/}") ;;
    l) _backups_lock_accounts=true ;;
    b) _backups_path="${OPTARG%/}" ;;
    p) _zimbra_main_path="${OPTARG%/}" ;;
    u) _zimbra_user="${OPTARG}" ;;
    g) _zimbra_group="${OPTARG}" ;;
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

if ! ${_include_all} && ! ${_include_accounts_settings} && ! ${_include_accounts_data} &&\
  [ -n "${_backups_include_accounts}" -o -n "${_backups_exclude_accounts}" ]; then
  log_err "Options -m and -x are not usable when no account settings and/or data are intended to be backuped (see -i)"
  exit 1
fi

if ! ${_include_all} && ! ${_include_accounts_data} && [ "${#_backups_exclude_data_regexes[@]}" -gt 0 ]; then
  log_err "Option -s is not usable when the data of the accounts is not intended to be backuped (see -i)"
  exit 1
fi

if [ ! -d "${_zimbra_main_path}" -o ! -x "${_zimbra_main_path}" ]; then
  log_err "Zimbra path <${_zimbra_main_path}> doesn't exist, is not a directory or is not executable"
  exit 1
fi

if [ ! -d "${_backups_path}" -o ! -x "${_backups_path}" -o ! -w "${_backups_path}" ]; then
  log_err "Backups path <${_backups_path}> doesn't exist, is not a directory or is not writable"
  exit 1
fi


###################
### MAIN SCRIPT ###
###################

initFastPrompts

(${_include_all} || ${_include_server_settings}) && {
  log_info "Server/Settings: Backuping admins list"
  zimbraBackupServerAdmins

  log_info "Server/Settings: Backuping domains"
  zimbraBackupServerDomains

  log_info "Server/Settings: Backuping DKIM keys"
  zimbraBackupServerDomainsDkim

  log_info "Server/Settings: Backuping mailing lists"
  zimbraBackupServerLists
}

(${_include_all} || ${_include_accounts_settings} || ${_include_accounts_data}) && {
  if [ -z "${_backups_include_accounts}" ]; then
    log_info "Preparing for accounts backuping"
  fi

  _accounts_to_backup=$(selectAccountsToBackup "${_backups_include_accounts}" "${_backups_exclude_accounts}" || true)

  if [ -z "${_accounts_to_backup}" ]; then
    log_debug "No account to backup"
  else
    log_debug "Accounts to backup: ${_accounts_to_backup}"

    # Backup accounts
    for email in ${_accounts_to_backup}; do
      if [ -e "${_backups_path}/accounts/${email}" ]; then
        log_warn "${email}: Has been skipped because <${_backups_path}/accounts/${email}/> already exists"
      else
        resetAccountProcessDuration

        _backuping_account="${email}"

        ${_backups_lock_accounts} && {
          log_info "${email}: Locking forever"
          zimbraAccountLock "${email}"
        }

        (${_include_all} || ${_include_accounts_settings}) && {
          log_info "${email}: Backuping settings"

          log_info "${email}/Settings: Backuping raw settings file"
          zimbraBackupAccountSettingsFile "${email}"

          log_info "${email}/Settings: Backuping identity-related settings"
          zimbraBackupAccountIdentitySettings "${email}"

          log_info "${email}/Settings: Backuping aliases"
          zimbraBackupAccountSettingAliases "${email}"

          log_info "${email}/Settings: Backuping signatures"
          zimbraBackupAccountSettingSignatures "${email}"

          log_info "${email}/Settings: Backuping pref settings"
          zimbraBackupAccountPrefSettings "${email}"

          # If you find other important settings to backup, please do a PR on Github to add them in the list below
          # Most of them are from <https://wiki.zimbra.com/wiki/Create_a_COS_for_Standard,_Professional,_BusinessPlus_and_Business_licenses>

          log_info "${email}/Settings: Backuping misc settings"
          zimbraBackupAccountMiscSettings "${email}" "
            zimbraFeatureMAPIConnectorEnabled
            zimbraFeatureMobileSyncEnabled
            zimbraArchiveEnabled
            zimbraFeatureConversationsEnabled
            zimbraFeatureTaggingEnabled
            zimbraAttachmentsIndexingEnabled
            zimbraFeatureViewInHtmlEnabled
            zimbraFeatureGroupCalendarEnabled
            zimbraFeatureSharingEnabled
            zimbraFeatureTasksEnabled
            zimbraFeatureBriefcasesEnabled
            zimbraFeatureSMIMEEnabled
            zimbraFeatureVoiceEnabled
            zimbraFeatureManageZimlets
            zimbraFeatureCalendarEnabled
            zimbraFeatureGalEnabled
            zimbraMailSieveScript
            zimbraMailCatchAllAddress
            zimbraFeatureOutOfOfficeReplyEnabled
          "
        }

        (${_include_all} || ${_include_accounts_data}) && {
          log_info "${email}: Backuping data"
          zimbraBackupAccountData "${email}"
        }

        showAccountProcessDuration
        _backuping_account=
      fi
    done
  fi
}

backupInfo "${0}" "${@}"
setZimbraPermissions "${_backups_path}"
showFullProcessDuration

exit 0
