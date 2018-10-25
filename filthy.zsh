#!/usr/bin/env zsh

# Filthy
# by James Dinsdale
# https://github.com/molovo/filthy
# MIT License

# Largely based on Pure by Sindre Sorhus <https://github.com/sindresorhus/pure>

# For my own and others sanity
# git:
# %b => current branch
# %a => current action (rebase/merge)
# prompt:
# %F => color dict
# %f => reset color
# %~ => current path
# %* => time
# %n => username
# %m => shortname host
# %(?..) => prompt conditional - %(condition.true.false)

prompt_filthy_nice_exit_code() {
  local exit_status="${1:-$(print -P %?)}";
  # nothing to do here
  [[ ${FILTHY_SHOW_EXIT_CODE:=0} != 1 || -z $exit_status || $exit_status == 0 ]] && return;

  local sig_name;

  # is this a signal name (error code = signal + 128) ?
  case $exit_status in
    129)  sig_name=HUP  ;;
    130)  sig_name=INT  ;;
    131)  sig_name=QUIT ;;
    132)  sig_name=ILL  ;;
    134)  sig_name=ABRT ;;
    136)  sig_name=FPE  ;;
    137)  sig_name=KILL ;;
    139)  sig_name=SEGV ;;
    141)  sig_name=PIPE ;;
    143)  sig_name=TERM ;;
  esac

  # usual exit codes
  case $exit_status in
    -1)   sig_name=FATAL         ;;
    1)    sig_name=WARN          ;; # Miscellaneous errors, such as "divide by zero"
    2)    sig_name=BUILTINMISUSE ;; # misuse of shell builtins (pretty rare)
    126)  sig_name=CCANNOTINVOKE ;; # cannot invoke requested command (ex : source script_with_syntax_error)
    127)  sig_name=CNOTFOUND     ;; # command not found (ex : source script_not_existing)
  esac

  # assuming we are on an x86 system here
  # this MIGHT get annoying since those are in a range of exit codes
  # programs sometimes use.... we'll see.
  case $exit_status in
    19)  sig_name=STOP ;;
    20)  sig_name=TSTP ;;
    21)  sig_name=TTIN ;;
    22)  sig_name=TTOU ;;
  esac

  echo "$ZSH_PROMPT_EXIT_SIGNAL_PREFIX${exit_status}:${sig_name:-$exit_status}$ZSH_PROMPT_EXIT_SIGNAL_SUFFIX ";
}

# turns seconds into human readable time
# 165392 => 1d 21h 56m 32s
prompt_filthy_human_time() {
  local tmp=$(( $1 / 1000 ))
  local days=$(( tmp / 60 / 60 / 24 ))
  local hours=$(( tmp / 60 / 60 % 24 ))
  local minutes=$(( tmp / 60 % 60 ))
  local seconds=$(( tmp % 60 ))
  (( $days > 0 ))    && print -n "${days}d "
  (( $hours > 0 ))   && print -n "${hours}h "
  (( $minutes > 0 )) && print -n "${minutes}m "
  (( $seconds > 5 )) && print -n "${seconds}s "
  (( $tmp <= 5 ))    && print -n "${1}ms"
}

# displays the exec time of the last command if set threshold was exceeded
prompt_filthy_cmd_exec_time() {
  local stop=$(( EPOCHREALTIME * 1000 ))
  local start=${cmd_timestamp:-$stop}
  integer elapsed=$stop-$start
  (( $elapsed > ${FILTHY_CMD_MAX_EXEC_TIME:=500} )) && prompt_filthy_human_time $elapsed
}

prompt_filthy_preexec() {
  cmd_timestamp=$(( EPOCHREALTIME * 1000 ))

  # shows the current dir and executed command in the title when a process is active
  print -Pn "\e]0;"
  echo -nE "$PWD:t: $2"
  print -Pn "\a"
}

# string length ignoring ansi escapes
prompt_filthy_string_length() {
  print ${#${(S%%)1//(\%([KF1]|)\{*\}|\%[Bbkf])}}
}

prompt_filthy_precmd() {
  local prompt_filthy_preprompt git_root current_path branch repo_status

  # Ensure prompt starts on a new line
  prompt_filthy_preprompt="\n"

  # Print connection info
  prompt_filthy_preprompt+="$(prompt_filthy_connection_info)"

  # check if we're in a git repo, and show git info if we are
  if [[ FILTHY_ALWAYS_SHOW_FULL_PATH -ne 1 ]] && command git rev-parse --is-inside-work-tree &>/dev/null; then
    # Print the name of the repository
    git_root=$(git rev-parse --show-toplevel)
    prompt_filthy_preprompt+="%B%F{yellow}$(basename ${git_root})%b%f"

    # Print the current_path relative to the git root
    current_path=$(git rev-parse --show-prefix)
    prompt_filthy_preprompt+=" %F{blue}${${current_path%/}:-"/"}%f"
  else
    # We're not in a repository, so just print the current path
    prompt_filthy_preprompt+="%F{blue}%~%f"
  fi

  # Print everything so far in the title
  # print -Pn '\e]0;${prompt_filthy_preprompt}\a'

  # Echo command exec time
  prompt_filthy_preprompt+=" %F{yellow}$(prompt_filthy_cmd_exec_time)%f"

  if [[ -f "${ZDOTDIR:-$HOME}/.promptmsg" ]]; then
    # Echo any stored messages after the pre-prompt
    prompt_filthy_preprompt+=" $(cat ${ZDOTDIR:-$HOME}/.promptmsg)"
  fi

  # We've already added any messages to our prompt, so let's reset them
  cat /dev/null >! "${ZDOTDIR:-$HOME}/.promptmsg"

  print -P $prompt_filthy_preprompt

  # reset value since `preexec` isn't always triggered
  unset cmd_timestamp
}

prompt_filthy_rprompt() {
  # check if we're in a git repo, and show git info if we are
  if command git rev-parse --is-inside-work-tree &>/dev/null; then
    # Print the repository status
    branch=$(prompt_filthy_git_branch)
    repo_status=$(prompt_filthy_git_repo_status)
    ci_status=$(prompt_filthy_ci_status)
  fi

  echo -n "${branch}${repo_status}${ci_status}"

  if [[ $FILTHY_SHOW_ZSH_VERSION -eq 1 ]]; then
    echo -n "%F{yellow} ${ZSH_VERSION}%f"
  fi
}

prompt_filthy_ci_status() {
  local state git_dir_local state_file

  [[ $FILTHY_SHOW_CI_STATUS -eq 0 ]] && return

  builtin type hub >/dev/null 2>&1 || return

  git_dir_local="$(git rev-parse --git-dir)"
  state_file="${git_dir_local}/ci-status"

  function _retrieve_ci_status() {
    # Delay the asynchronous process, otherwise the status file
    # will be empty when we read it
    sleep 1

    state=$(hub ci-status 2>&1)
    cat /dev/null >! "${state_file}" 2>/dev/null
    case $state in
      success )
        print '%F{green}●%f' >> "${state_file}"
        ;;
      pending )
        print '%F{yellow}○%f' >> "${state_file}"
        ;;
      failure )
        print '%F{red}●%f' >> "${state_file}"
        ;;
      error )
        print '%F{red}‼%f' >> "${state_file}"
        ;;
      'no status' )
        print '%F{242}○%f' >> "${state_file}"
        ;;
    esac
  }

  _retrieve_ci_status >/dev/null 2>&1 &!

  state=$(cat "${state_file}" 2>/dev/null)

  [[ -n $state ]] && print " $state"
}

prompt_filthy_git_repo_status() {
  # Do a fetch asynchronously
  git fetch > /dev/null 2>&1 &!

  local clean
  local rtn=""
  local count
  local up
  local down

  dirty="$(git diff --ignore-submodules=all HEAD 2>/dev/null)"
  [[ $dirty != "" ]] && rtn+=" %F{242}…%f"

  staged="$(git diff --staged HEAD 2>/dev/null)"
  [[ $staged != "" ]] && rtn+=" %F{242}*%f"

  # check if there is an upstream configured for this branch
  # exit if there isn't, as we can't check for remote changes
  if command git rev-parse --abbrev-ref @'{u}' &>/dev/null; then
    # if there is, check git left and right arrow_status
    count="$(command git rev-list --left-right --count HEAD...@'{u}' 2>/dev/null)"

    # Get the push and pull counts
    up="$count[(w)1]"
    down="$count[(w)2]"

    # Check if either push or pull is needed
    [[ $up -gt 0 || $down -gt 0 ]] && rtn+=" "

    # Push is needed, show up arrow
    [[ $up -gt 0 ]] && rtn+="%F{yellow}⇡$up%f"

    # Pull is needed, show down arrow
    [[ $down -gt 0 ]] && rtn+="%F{yellow}⇣$down%f"
  fi

  print $rtn
}

prompt_filthy_git_branch() {
  # get the current git status
  local branch git_dir_local rtn

  branch=$(git status --short --branch -uno --ignore-submodules=all | head -1 | awk '{print $2}' 2>/dev/null)
  git_dir_local=$(git rev-parse --git-dir)

  # remove reference to any remote tracking branch
  branch=${branch%...*}

  # check if HEAD is detached
  if [[ -d "${git_dir_local}/rebase-merge" ]]; then
    branch=$(git status | head -5 | tail -1 | awk '{print $6}')
    rtn="%F{red}rebasing interactively%f%F{242} → ${branch//([[:space:]]|\')/}%f"
  elif [[ -d "${git_dir_local}/rebase-apply" ]]; then
    branch=$(git status | head -2 | tail -1 | awk '{print $6}')
    rtn="%F{red}rebasing%f%F{242} → ${branch//([[:space:]]|\')/}%f"
  elif [[ -f "${git_dir_local}/MERGE_HEAD" ]]; then
    branch=$(git status | head -1 | awk '{print $3}')
    rtn="%F{red}merging%f%F{242} → ${branch//([[:space:]]|\')/}%f"
  elif [[ "$branch" = "HEAD" ]]; then
    commit=$(git status HEAD -uno --ignore-submodules=all | head -1 | awk '{print $4}' 2>/dev/null)

    if [[ "$commit" = "on" ]]; then
      rtn="%F{yellow}no branch%f"
    else
      rtn="%F{242}detached@%f"
      rtn+="%F{yellow}"
      rtn+="$commit"
      rtn+="%f"
    fi
  else
    rtn="%F{242}$branch%f"
  fi

  print "$rtn"
}

prompt_filthy_connection_info() {
  # show username@host if logged in through SSH
  if [[ "x$SSH_CONNECTION" != "x" ]]; then
    echo '%(!.%B%F{red}%n%f%b.%F{242}%n%f)%F{242}@%m%f '
  else
    echo '%(!.%B%F{red}%n%f%b%F{242}@%m%f .)'
  fi
}

prompt_filthy_prompt_char() {
  case $KEYMAP in
    vicmd) echo "%(?.%F{blue}.%F{red}$(prompt_filthy_nice_exit_code))${PROMPT_FILTHY_VICMD_CHAR:-●}%f"   ;;
    *)     echo "%(?.%F{green}.%F{red}$(prompt_filthy_nice_exit_code))${PROMPT_FILTHY_PROMPT_CHAR:-❯}%f" ;;
  esac
}

prompt_filthy_setup() {
  # prevent percentage showing up
  # if output doesn't end with a newline
  export PROMPT_EOL_MARK=''

  prompt_opts=(cr subst percent)

  zmodload zsh/datetime
  autoload -Uz add-zsh-hook

  add-zsh-hook precmd prompt_filthy_precmd
  add-zsh-hook preexec prompt_filthy_preexec

  # prompt turns red if the previous command didn't exit with 0
  PROMPT='$(prompt_filthy_prompt_char) '

  RPROMPT='$(prompt_filthy_rprompt)'
}

prompt_filthy_setup "$@"
