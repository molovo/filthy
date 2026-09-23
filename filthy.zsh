#!/usr/bin/env zsh

# Filthy
# by James Dinsdale
# https://github.com/molovo/filthy
# MIT License

# Largely based on Pure by Sindre Sorhus <https://github.com/sindresorhus/pure>
#
# Live git updates adapted from Cobalt Spark by Andrey Zhuchkov (MIT)
# <https://github.com/azhuchkov/cobalt-spark>

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

# Dynamic file descriptor syntax ({fd}) has to be parsed with IGNORE_BRACES off.
# Remember the caller's setting; it's restored at the bottom of this file.
typeset -g __filthy_restore_ignorebraces=${options[ignorebraces]}
unsetopt ignorebraces

# The git segment is rendered by a background worker and cached here, so prompt
# expansion never waits on git. Guarded so re-sourcing the prompt doesn't blank
# the current value or lose track of a running worker.
if (( ! ${+__filthy_rprompt} )); then
  typeset -g  __filthy_rprompt=
  typeset -gi __filthy_async_fd=-1
  typeset -gi __filthy_async_pending=0
fi

# Last fetch time, keyed by git common dir. Kept in memory rather than in a file
# so that throttling a fetch can't itself write inside .git.
typeset -gA __filthy_last_fetch

# Every git call the prompt makes is read only, but git still refreshes the
# index opportunistically, and that takes .git/index.lock. A rebase writes to
# .git constantly, so the file watcher fires mid-rebase and the two race for the
# lock, which aborts the rebase. GIT_OPTIONAL_LOCKS=0 tells git to skip anything
# needing a lock; the tradeoff is that a stat-dirty file may briefly read as
# modified, which is the right way round.
prompt_filthy_git() {
  GIT_OPTIONAL_LOCKS=0 command git "$@"
}

# True while a rebase, merge, cherry-pick, revert or bisect is in progress
prompt_filthy_git_in_progress() {
  local git_dir=$1

  [[ -d "${git_dir}/rebase-merge" || -d "${git_dir}/rebase-apply" ]] && return 0
  [[ -f "${git_dir}/MERGE_HEAD" ]] && return 0
  [[ -f "${git_dir}/CHERRY_PICK_HEAD" ]] && return 0
  [[ -f "${git_dir}/REVERT_HEAD" ]] && return 0
  [[ -f "${git_dir}/BISECT_LOG" ]] && return 0

  return 1
}

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
  local prompt_filthy_preprompt git_root current_path

  # Ensure prompt starts on a new line
  prompt_filthy_preprompt="\n"

  # Print connection info
  prompt_filthy_preprompt+="$(prompt_filthy_connection_info)"

  # check if we're in a git repo, and show git info if we are
  if [[ FILTHY_ALWAYS_SHOW_FULL_PATH -ne 1 ]] && prompt_filthy_git rev-parse --is-inside-work-tree &>/dev/null; then
    # Print the name of the repository
    git_root=$(prompt_filthy_git rev-parse --show-toplevel)
    prompt_filthy_preprompt+="%B%F{yellow}$(basename ${git_root})%b%f"

    # Print the current_path relative to the git root
    current_path=$(prompt_filthy_git rev-parse --show-prefix)
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

  # Kick off a fetch and a fresh render of the git segment. Both belong here
  # rather than in the render itself: a fetch writes inside .git, and firing one
  # from a watcher-triggered redraw would loop.
  prompt_filthy_maybe_fetch
  prompt_filthy_async_start

  # reset value since `preexec` isn't always triggered
  unset cmd_timestamp
}

prompt_filthy_node_version() {
  if builtin type node &>/dev/null; then
    echo -n "  %F{242} %F{yellow}$(node -v)%f"
  fi
}

prompt_filthy_zsh_version() {
  echo -n "  %F{242}ZSH %F{yellow}${ZSH_VERSION}%f"
}

prompt_filthy_php_version() {
  if builtin type php &>/dev/null; then
    echo -n "  %F{242} %F{yellow}$(php -v | head -1 | awk '{print $2}')%f"
  fi
}

prompt_filthy_ruby_version() {
  if builtin type ruby &>/dev/null; then
    echo -n "  %F{242} %F{yellow}$(ruby -v | awk '{print $2}')%f"
  fi
}

prompt_filthy_python_version() {
  if builtin type python &>/dev/null; then
    echo -n "  %F{242} %F{yellow}$(python -V 2>&1 | awk '{print $2}')%f"
  elif builtin type python3 &>/dev/null; then
    echo -n "  %F{242} %F{yellow}$(python3 -V 2>&1 | awk '{print $2}')%f"
  fi
}

prompt_filthy_versions() {
  local version

  # Split on whitespace whatever the caller's $IFS is, and without turning
  # SH_WORD_SPLIT off in their shell on the way back out
  local IFS=$' \t\n'

  for version in ${=FILTHY_SHOW_VERSIONS}; do
    case $version in
      node)   prompt_filthy_node_version   ;;
      zsh)    prompt_filthy_zsh_version    ;;
      php)    prompt_filthy_php_version    ;;
      ruby)   prompt_filthy_ruby_version   ;;
      python) prompt_filthy_python_version ;;
    esac
  done
}

# Renders the right hand prompt. Always runs in a background worker, so it is
# free to be as slow as git is.
prompt_filthy_rprompt() {
  local branch repo_status ci_status rtn

  # check if we're in a git repo, and show git info if we are
  if prompt_filthy_git rev-parse --is-inside-work-tree &>/dev/null; then
    # Print the repository status
    branch=$(prompt_filthy_git_branch)
    repo_status=$(prompt_filthy_git_repo_status)
    ci_status=$(prompt_filthy_ci_status)
  fi


  rtn="${branch}${repo_status}${ci_status}$(prompt_filthy_versions)"

  # A single newline terminated line, so the reader gets a complete record
  print -r -- "$rtn"
}

# Turns a path into something safe and bounded to use as a filename
prompt_filthy_path_key() {
  local str=$1 char
  integer hash=0

  for char in ${(s::)str}; do
    (( hash = (hash * 31 + #char) % 4294967291 ))
  done

  print -r -- "${${str:t}//[^[:alnum:]._-]/_}-${hash}"
}

prompt_filthy_ci_status() {
  local state git_dir_local state_file interval
  local -a stat_result

  [[ $FILTHY_SHOW_CI_STATUS -eq 0 ]] && return

  builtin type hub >/dev/null 2>&1 || return

  git_dir_local="$(prompt_filthy_git rev-parse --git-common-dir 2>/dev/null)" || return
  [[ -z $git_dir_local ]] && return
  git_dir_local=${git_dir_local:A}

  # Keep the state file outside .git. Written inside, every refresh would wake
  # the file watcher, which would trigger another refresh, and so on.
  state_file="${TMPDIR:-/tmp}/filthy-ci-status-$(prompt_filthy_path_key $git_dir_local)"

  function _retrieve_ci_status() {
    # Delay the asynchronous process, otherwise the status file
    # will be empty when we read it
    sleep 1

    state=$(GIT_OPTIONAL_LOCKS=0 hub ci-status 2>&1)
    cat /dev/null >! "${state_file}.new" 2>/dev/null
    case $state in
      success )
        print '%F{green}●%f' >> "${state_file}.new"
        ;;
      pending )
        print '%F{yellow}○%f' >> "${state_file}.new"
        ;;
      failure )
        print '%F{red}●%f' >> "${state_file}.new"
        ;;
      error )
        print '%F{red}‼%f' >> "${state_file}.new"
        ;;
      'no status' )
        print '%F{242}○%f' >> "${state_file}.new"
        ;;
    esac

    # Swap it in whole, so a concurrent read never sees a half written file
    command mv -f "${state_file}.new" "${state_file}" 2>/dev/null
  }

  # Ask hub at most once every $FILTHY_CI_STATUS_INTERVAL seconds. The state
  # file's mtime is the throttle: this runs in a worker subshell, so a variable
  # wouldn't survive to the next call.
  interval=${FILTHY_CI_STATUS_INTERVAL:-30}
  if ! zstat -A stat_result +mtime "$state_file" 2>/dev/null ||
      (( EPOCHSECONDS - stat_result[1] >= interval )); then
    # Claim the slot before backgrounding. `hub` sleeps for a second before it
    # writes, and without this every refresh in that window would spawn another.
    command touch "$state_file" 2>/dev/null
    _retrieve_ci_status >/dev/null 2>&1 &!
  fi

  state=$(cat "${state_file}" 2>/dev/null)

  [[ -n $state ]] && print " $state"
}

prompt_filthy_git_repo_status() {
  local clean
  local rtn=""
  local count
  local -a counts
  local up
  local down
  local stashes
  local dirty
  local staged

  stashes="$(prompt_filthy_git stash list 2>/dev/null)"
  [[ $stashes != "" ]] && rtn+=" %F{yellow}≡%f"

  dirty="$(prompt_filthy_git diff --ignore-submodules=all HEAD 2>/dev/null)"
  [[ $dirty != "" ]] && rtn+=" %F{242}…%f"

  staged="$(prompt_filthy_git diff --staged HEAD 2>/dev/null)"
  [[ $staged != "" ]] && rtn+=" %F{242}*%f"

  # check if there is an upstream configured for this branch
  # exit if there isn't, as we can't check for remote changes
  if prompt_filthy_git rev-parse --abbrev-ref @'{u}' &>/dev/null; then
    # if there is, check git left and right arrow_status
    count="$(prompt_filthy_git rev-list --left-right --count HEAD...@'{u}' 2>/dev/null)"

    # Get the push and pull counts. git separates them with a tab, so split on
    # whitespace whatever the caller's $IFS is; a `(w)` subscript would use
    # $IFS instead, and leave both counts in $up
    local IFS=$' \t\n'
    counts=(${=count})
    up=${counts[1]:-0}
    down=${counts[2]:-0}

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

  branch=$(prompt_filthy_git status --short --branch -uno --ignore-submodules=all | head -1 | awk '{print $2}' 2>/dev/null)
  git_dir_local=$(prompt_filthy_git rev-parse --git-dir)

  # remove reference to any remote tracking branch
  branch=${branch%...*}

  # check if HEAD is detached
  if [[ -d "${git_dir_local}/rebase-merge" ]]; then
    branch=${${$(prompt_filthy_git status | head -5 | tail -1 | awk '{print $6}')//([[:space:]]|\')/}//\%/%%}
    rtn="%F{red}rebasing interactively%f%F{242} → ${branch}%f"
  elif [[ -d "${git_dir_local}/rebase-apply" ]]; then
    branch=${${$(prompt_filthy_git status | head -2 | tail -1 | awk '{print $6}')//([[:space:]]|\')/}//\%/%%}
    rtn="%F{red}rebasing%f%F{242} → ${branch}%f"
  elif [[ -f "${git_dir_local}/MERGE_HEAD" ]]; then
    branch=${${$(prompt_filthy_git status | head -1 | awk '{print $3}')//([[:space:]]|\')/}//\%/%%}
    rtn="%F{red}merging%f%F{242} → ${branch}%f"
  elif [[ "$branch" = "HEAD" ]]; then
    commit=$(prompt_filthy_git status HEAD -uno --ignore-submodules=all | head -1 | awk '{print $4}' 2>/dev/null)

    if [[ "$commit" = "on" ]]; then
      rtn="%F{yellow}no branch%f"
    else
      rtn="%F{242}detached@%f"
      rtn+="%F{yellow}"
      rtn+="${commit//\%/%%}"
      rtn+="%f"
    fi
  else
    rtn="%F{242}${branch//\%/%%}%f"
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

# Fetch from the remote in the background, at most once every
# $FILTHY_FETCH_INTERVAL seconds. Set the interval to 0 to never fetch.
prompt_filthy_maybe_fetch() {
  local key interval

  interval=${FILTHY_FETCH_INTERVAL:-180}
  (( interval <= 0 )) && return

  key="$(prompt_filthy_git rev-parse --git-common-dir 2>/dev/null)" || return
  [[ -z $key ]] && return
  key=${key:A}

  # Don't touch the repository mid rebase, merge or bisect
  prompt_filthy_git_in_progress "$key" && return

  (( EPOCHSECONDS - ${__filthy_last_fetch[$key]:-0} < interval )) && return

  __filthy_last_fetch[$key]=$EPOCHSECONDS
  prompt_filthy_git fetch >/dev/null 2>&1 &!
}

# Render the right hand prompt in a background worker. The result arrives on a
# file descriptor watched by `zle -F`, which fires while the line editor is idle.
prompt_filthy_async_start() {
  local fd

  # A worker is already in flight. Note that its result will be stale and let
  # the callback start a fresh one, rather than piling up processes.
  if (( __filthy_async_fd >= 0 )); then
    __filthy_async_pending=1
    return
  fi

  # No redirections beyond the fd itself: `exec` without a command makes any
  # extra redirection permanent for the whole shell.
  exec {fd}< <(prompt_filthy_rprompt)

  if ! zle -F $fd prompt_filthy_async_callback 2>/dev/null; then
    exec {fd}<&-
    return
  fi

  __filthy_async_fd=$fd
}

prompt_filthy_async_callback() {
  emulate -L zsh

  local fd=$1

  # Keep the read from leaking a REPLY into the user's session
  local REPLY

  # Anything short of a complete line means the worker died; keep whatever we
  # last rendered rather than blanking the prompt.
  if IFS= read -r -u $fd; then
    __filthy_rprompt=$REPLY
  fi

  zle -F $fd 2>/dev/null
  exec {fd}<&-
  __filthy_async_fd=-1

  # `zle -F` callbacks run as widgets, but this can still be reached with the
  # line editor inactive
  zle .reset-prompt 2>/dev/null

  if (( __filthy_async_pending )); then
    __filthy_async_pending=0
    prompt_filthy_async_start
  fi
}

# Live git updates
#
# When fswatch is available, watch the repository and refresh the git segment
# while the prompt sits idle, so changes made in another terminal show up
# without having to press a key. Without fswatch this all quietly no-ops and the
# prompt updates on each new prompt as before.
#
# Adapted from Cobalt Spark by Andrey Zhuchkov (MIT)

if (( ! ${+__filthy_live_git_events_fd} )); then
  typeset -gi __filthy_live_git_events_fd=-1
  typeset -gi __filthy_live_git_supervisor_fd=-1
  typeset -g  __filthy_live_git_root=
fi

prompt_filthy_live_git_shutdown() {
  emulate -L zsh

  if (( __filthy_live_git_events_fd >= 0 )); then
    zle -F $__filthy_live_git_events_fd 2>/dev/null
    exec {__filthy_live_git_events_fd}<&-
    __filthy_live_git_events_fd=-1
  fi

  if (( __filthy_live_git_supervisor_fd >= 0 )); then
    print -r -u $__filthy_live_git_supervisor_fd -- shutdown 2>/dev/null
    exec {__filthy_live_git_supervisor_fd}>&-
    __filthy_live_git_supervisor_fd=-1
  fi

  __filthy_live_git_root=
}

# Escape regex metacharacters, so repository and $TMPDIR paths can be dropped
# into fswatch's extended regex filters verbatim
prompt_filthy_live_git_quote_ere() {
  emulate -L zsh
  setopt localoptions extended_glob

  local MATCH MBEGIN MEND
  local pattern='(#m)[\[.^$*+?(){}|\\]'

  REPLY=${1//$~pattern/\\$MATCH}
}

prompt_filthy_live_git_on_event() {
  emulate -L zsh

  local fd=$1
  local error=${2-}

  # Keep the read from leaking a REPLY into the user's session
  local REPLY

  # EOF, or the watcher died
  if [[ -n $error ]] || ! IFS= read -r -u $fd; then
    prompt_filthy_live_git_shutdown
    return
  fi

  # Drain any batches already queued up behind this one
  while IFS= read -r -t -u $fd; do
    :
  done

  # Re-render off the line editor's thread, so typing never stalls on git
  prompt_filthy_async_start
}

prompt_filthy_live_git_bootstrap() {
  emulate -L zsh
  setopt localoptions nobgnice

  local root=$1
  local git_dir=$2
  local common_dir=$3
  shift 3

  local -a paths=("$@")
  local -a filters
  local dir
  local REPLY

  # Ignore the paths git churns on its own. Without these, an ordinary fetch or
  # commit would wake the watcher, which would redraw, which would wake it again.
  for dir in "$git_dir" ${${common_dir:#$git_dir}:+"$common_dir"}; do
    prompt_filthy_live_git_quote_ere "$dir"
    filters+=(
      -e "^${REPLY}/objects(/.*)?$"
      -e "^${REPLY}/logs(/.*)?$"
      -e "^${REPLY}/fsmonitor--daemon(/.*)?$"
      -e "^${REPLY}/fsmonitor--daemon\\.ipc$"
      -e "^${REPLY}/.*\\.lock$"
      -e "^${REPLY}/COMMIT_EDITMSG$"
      -e "^${REPLY}/FETCH_HEAD$"
    )
  done

  local tmpdir=${TMPDIR:-/tmp}
  local fifo_dir
  fifo_dir=$(command mktemp -d "${tmpdir%/}/filthy-fswatch.XXXXXX") || return 1

  local events_fifo="$fifo_dir/events"
  local supervisor_fifo="$fifo_dir/supervisor"

  prompt_filthy_live_git_fs_cleanup() {
    command rm -f -- "$events_fifo" "$supervisor_fifo"
    command rmdir -- "$fifo_dir" 2>/dev/null
  }

  command mkfifo "$events_fifo" "$supervisor_fifo" || {
    prompt_filthy_live_git_fs_cleanup
    return 1
  }

  # Exclude the FIFO directory, in case $TMPDIR sits inside a watched path
  prompt_filthy_live_git_quote_ere "${fifo_dir:A}"
  filters+=(-e "^${REPLY}(/.*)?$")

  # O_RDWR opens the FIFO without blocking for a peer
  local supervisor_fd
  sysopen -r -w -o cloexec -u supervisor_fd "$supervisor_fifo" || {
    prompt_filthy_live_git_fs_cleanup
    return 1
  }

  # The outer subshell keeps the detached supervisor from clobbering our $!
  (
    # The inner one owns fswatch, and stops it when we shut down or exec
    (
      emulate -L zsh
      setopt localoptions nobgnice

      # Reopen read-only, so closing the writer shows up here as EOF
      exec {supervisor_fd}>&-
      sysopen -r -u supervisor_fd "$supervisor_fifo" || {
        # Open and close the events FIFO, so the parent sees EOF and tears down
        : >"$events_fifo"
        exit 1
      }

      command fswatch --recursive --one-per-batch \
        --latency "${FILTHY_LIVE_GIT_LATENCY:-0.5}" \
        --monitor-property darwin.eventStream.noDefer=true \
        --extended --allow-overflow \
        "${filters[@]}" -- "${paths[@]}" >"$events_fifo" \
        2> >(while IFS= read -r line; do
          print -u2 -r -- "filthy fswatch: $line"
        done) &

      local fswatch_pid=$!

      # Block until we're told to stop, or the writer goes away
      IFS= read -r -u "$supervisor_fd"

      kill "$fswatch_pid" 2>/dev/null
      wait "$fswatch_pid" 2>/dev/null

      exec {supervisor_fd}<&-

      prompt_filthy_live_git_fs_cleanup
    ) &!
  )

  local events_fd
  sysopen -r -o cloexec -u events_fd "$events_fifo" || {
    exec {supervisor_fd}>&-
    return 1
  }

  __filthy_live_git_root=$root
  __filthy_live_git_events_fd=$events_fd
  __filthy_live_git_supervisor_fd=$supervisor_fd

  if ! zle -F $events_fd prompt_filthy_live_git_on_event; then
    prompt_filthy_live_git_shutdown
    return 1
  fi
}

prompt_filthy_live_git_check_pwd() {
  emulate -L zsh

  if [[ -n $FILTHY_LIVE_GIT_OFF ]]; then
    prompt_filthy_live_git_shutdown
    return 0
  fi

  # Nothing to do if live updates aren't available. A watcher may already be
  # running from before fswatch left $PATH, so still tear down.
  if ! zmodload zsh/system 2>/dev/null || ! whence -p fswatch >/dev/null 2>&1; then
    prompt_filthy_live_git_shutdown
    return 0
  fi

  local -a git_dirs
  git_dirs=("${(@f)$(prompt_filthy_git rev-parse \
    --show-toplevel \
    --git-dir \
    --git-common-dir \
    2>/dev/null)}") || git_dirs=()

  # Not inside a work tree
  if (( ${#git_dirs} != 3 )); then
    prompt_filthy_live_git_shutdown
    return 0
  fi

  local root=${git_dirs[1]:A}
  local git_dir=${git_dirs[2]:A}
  local common_dir=${git_dirs[3]:A}

  # Moving around inside the same repository needs no action
  [[ $root == $__filthy_live_git_root ]] && return 0

  prompt_filthy_live_git_shutdown

  local -a paths=("$root")

  # Linked worktrees and external git dirs live outside the work tree
  [[ $git_dir != $root/* ]] && paths+=("$git_dir")
  [[ $common_dir != $root/* && $common_dir != $git_dir ]] && paths+=("$common_dir")

  prompt_filthy_live_git_bootstrap \
    "$root" "$git_dir" "$common_dir" "${paths[@]}" || return 0
}

# Clean up a watcher left behind by a previous sourcing of the prompt
prompt_filthy_live_git_shutdown

prompt_filthy_setup() {
  # prevent percentage showing up
  # if output doesn't end with a newline
  export PROMPT_EOL_MARK=''

  prompt_opts=(cr subst percent)

  zmodload zsh/datetime
  zmodload -F zsh/stat b:zstat 2>/dev/null
  autoload -Uz add-zsh-hook

  # Drop any hooks left behind by a previous sourcing of the prompt
  add-zsh-hook -d precmd prompt_filthy_precmd
  add-zsh-hook -d preexec prompt_filthy_preexec
  add-zsh-hook -d precmd prompt_filthy_live_git_check_pwd
  add-zsh-hook -d zshexit prompt_filthy_live_git_shutdown

  add-zsh-hook precmd prompt_filthy_live_git_check_pwd
  add-zsh-hook precmd prompt_filthy_precmd
  add-zsh-hook preexec prompt_filthy_preexec
  add-zsh-hook zshexit prompt_filthy_live_git_shutdown

  # prompt turns red if the previous command didn't exit with 0
  PROMPT='$(prompt_filthy_prompt_char) '

  # Rendered asynchronously, and refreshed live while the prompt is idle
  RPROMPT='${__filthy_rprompt}'
}

prompt_filthy_setup "$@"

# Restore the caller's IGNORE_BRACES setting
[[ $__filthy_restore_ignorebraces == on ]] && setopt ignorebraces
unset __filthy_restore_ignorebraces
