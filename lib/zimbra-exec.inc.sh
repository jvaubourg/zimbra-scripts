# Julien Vaubourg <ju.vg>
# CC-BY-SA (2019)
# https://github.com/jvaubourg/zimbra-scripts


########################
### GLOBAL VARIABLES ###
########################

_fastprompts_enabled=false

_fastprompt_zmprov_tmp=
_fastprompt_zmprov_pid=
_fastprompt_zmmailbox_tmp=
_fastprompt_zmmailbox_pid=
_fastprompt_zmmailbox_email=


##################
## FAST PROMPTS ##
##################

# Every Zimbra CLI command (zmprov, zmmailbox, etc) can be used with a prompt
# Opening these prompts and feeding them with subcommands is way way faster
# than executing the commands each time (only one Java VM instantiated)
function initFastPrompts() {
  local path="PATH=/sbin:/bin:/usr/sbin:/usr/bin:${_zimbra_main_path}/bin:${_zimbra_main_path}/libexec"
  _fastprompts_enabled=true

  # fastzmprov
  if [ -z "${_fastprompt_zmprov_tmp}" ]; then
    log_debug "Open the fast zmprov prompt"

    _fastprompt_zmprov_tmp=$(mktemp -d)
    mkfifo "${_fastprompt_zmprov_tmp}/cmd"
    exec sudo -u "${_zimbra_user}" env "${path}" stdbuf -o0 -e0 zmprov --ldap < <(tail -f --pid=$$ "${_fastprompt_zmprov_tmp}/cmd" 2> /dev/null || true) &>> "${_fastprompt_zmprov_tmp}/out" &
    _fastprompt_zmprov_pid="${!}"
  fi

  # fastzmmailbox
  if [ -z "${_fastprompt_zmmailbox_tmp}" ]; then
    log_debug "Open the fast zmmailbox prompt"

    _fastprompt_zmmailbox_tmp=$(mktemp -d)
    mkfifo "${_fastprompt_zmmailbox_tmp}/cmd"
    exec sudo -u "${_zimbra_user}" env "${path}" stdbuf -o0 -e0 zmmailbox --zadmin < <(tail -f --pid=$$ "${_fastprompt_zmmailbox_tmp}/cmd" 2> /dev/null || true) &>> "${_fastprompt_zmmailbox_tmp}/out" &
    _fastprompt_zmmailbox_pid="${!}"
  fi
}

# Close fast prompts if opened
function closeFastPrompts() {
  _fastprompts_enabled=false

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
}

# Execute a Zimbra command with a fast prompt
function execFastPrompt() {
  local cmd_pipe="${1}"
  local out_file="${2}"
  local prompt_delimiter=$(echo "${RANDOM}" | sha256sum | awk '{ print $1 }')
  local delimiter_has_been_executed=false

  :> "${out_file}"

  # Submit the subcommand with an additional fake one
  # Sed is used because Zimbra prompts don't support $'...' POSIX syntax
  printf '%q ' "${cmd[@]:1}" | sed "s/ \\$'/ '/g" > "${cmd_pipe}"
  printf '\n%s\n' "${prompt_delimiter}" > "${cmd_pipe}"

  # Wait to see the fake subcommand, meaning that the processing of the
  # real one is terminated
  while read out_line; do
    if ${delimiter_has_been_executed}; then
      break
    elif [[ "${out_line}" =~ "${prompt_delimiter}" ]]; then
      delimiter_has_been_executed=true
    fi
  done < <(tail -f --pid=$$ "${out_file}" 2> /dev/null || true)

  # Display the result of the subcommand
  # We really hope here that nobody uses ERROR: at the beginning of a line in a signature or anything else
  if grep '^ERROR: ' "${out_file}" | grep -v "${prompt_delimiter}" >&2; then
    false
  else
    head -n -3 "${out_file}" | tail -n +2
  fi

  # Ensure that the while's tail gets at least an EOL even if the EOF was truncated
  printf '\n' > "${cmd_pipe}"
}

# Switch from an account to another one in the prompt of zmmailbox
function zmmailboxSelectMailbox() {
  local email="${1}"

  if ${_fastprompts_enabled} && [ "${_fastprompt_zmmailbox_email}" != "${email}" ]; then
    local cmd=(fastzmmailbox selectMailbox "${email}")
    execZimbraCmd cmd > /dev/null
  fi

  _fastprompt_zmmailbox_email="${email}"
}


##################
## EXEC COMMAND ##
##################

# Execute a Zimbra command with a shell or with a fast prompt
function execZimbraCmd() {
  # References (namerefs) are not supported by Bash prior to 4.4 (CentOS currently uses 4.3)
  # For now we expect that the parent function defined a cmd variable
  # local -n command="${1}"

  if ! ${_fastprompts_enabled}; then
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
