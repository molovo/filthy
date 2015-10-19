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

# turns seconds into human readable time
# 165392 => 1d 21h 56m 32s
prompt_filthy_human_time() {
  local tmp=$(( $1 / 1000 ))
  local days=$(( tmp / 60 / 60 / 24 ))
  local hours=$(( tmp / 60 / 60 % 24 ))
  local minutes=$(( tmp / 60 % 60 ))
  local seconds=$(( tmp % 60 ))
  (( $days > 0 )) && print -n "${days}d "
  (( $hours > 0 )) && print -n "${hours}h "
  (( $minutes > 0 )) && print -n "${minutes}m "
  (( $seconds > 0 )) && print -n "${seconds}s"
  (( $seconds < 1 )) && print -n "${1}ms"
}

# displays the exec time of the last command if set threshold was exceeded
prompt_filthy_cmd_exec_time() {
  local stop=$((EPOCHREALTIME*1000))
  local start=${cmd_timestamp:-$stop}
  integer elapsed=$stop-$start
  (($elapsed > ${FILTHY_CMD_MAX_EXEC_TIME:=5000})) && prompt_filthy_human_time $elapsed
}

prompt_filthy_preexec() {
  cmd_timestamp=$((EPOCHREALTIME*1000))

  # shows the current dir and executed command in the title when a process is active
  print -Pn "\e]0;"
  print -nE "$PWD:t: $2"
  print -Pn "\a"
}

# string length ignoring ansi escapes
prompt_filthy_string_length() {
  print ${#${(S%%)1//(\%([KF1]|)\{*\}|\%[Bbkf])}}
}

prompt_filthy_precmd() {
  # shows the full path in the title
  print -Pn '\e]0;%~\a'

  # git info
  git-info

  # Echo current path
  local prompt_filthy_preprompt="\n%F{blue}%~%f"

	# check if we're in a git repo, and show git info if we are
	command git rev-parse --is-inside-work-tree &>/dev/null && \
  prompt_filthy_preprompt+=" %F{242}(%f$(prompt_filthy_git_branch)$(prompt_filthy_git_repo_status)%s%F{242})%f"

  # Echo command exec time
  prompt_filthy_preprompt+=" %F{yellow}$(prompt_filthy_cmd_exec_time)%f"

  # Echo any stored messages after the pre-prompt
  prompt_filthy_preprompt+=" $(cat ${ZDOTDIR:-$HOME}/.promptmsg.tmp)"

  # We've already added any messages to our prompt, so let's reset them
  cat /dev/null >! "${ZDOTDIR:-$HOME}/.promptmsg.tmp"

  print -P $prompt_filthy_preprompt

  # reset value since `preexec` isn't always triggered
  unset cmd_timestamp
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
  [[ $dirty != "" ]] && rtn+=" %F{red}x%f"

  # check if there is an upstream configured for this branch
  # exit if there isn't, as we can't check for remote changes
  if command git rev-parse --abbrev-ref @'{u}' &>/dev/null; then
    # if there is, check git left and right arrow_status
    count="$(command git rev-list --left-right --count HEAD...@'{u}' 2>/dev/null)"

    # Get the push and pull counts
    up="$count[(w)1]"
    down="$count[(w)2]"

    # Check if either push or pull is needed
    [[ $up > 0 || $down > 0 ]] && rtn+=" "

    # Push is needed, show up arrow
    [[ $up > 0 ]] && rtn+="%F{yellow}⇡%f"

    # Pull is needed, show down arrow
    [[ $down > 0 ]] && rtn+="%F{yellow}⇣%f"
  fi

  print $rtn
}

prompt_filthy_git_branch() {
  # get the current git status
  local branch=$(git status --short --branch -uno --ignore-submodules=all | head -1 | awk '{print $2}' 2>/dev/null)
  local rtn

  # remove reference to any remote tracking branch
  branch=${branch%...*}

  # check if HEAD is detached
  if [[ "$branch" = "HEAD" ]]; then
    rtn="%F{242}detached@%f"
    rtn+="%F{yellow}"
    rtn+=$(git status HEAD -uno --ignore-submodules=all | head -1 | awk '{print $4}' 2>/dev/null)
    rtn+="%f"
  else
    rtn="%F{242}$branch%f"
  fi

  print $rtn
}

prompt_filthy_setup() {
  # prevent percentage showing up
  # if output doesn't end with a newline
  export PROMPT_EOL_MARK=''

  prompt_opts=(cr subst percent)

  zmodload zsh/datetime
  autoload -Uz add-zsh-hook
  # autoload -Uz git-info

  add-zsh-hook precmd prompt_filthy_precmd
  add-zsh-hook preexec prompt_filthy_preexec

  # # Set git-info parameters.
  # zstyle ':prezto:module:git:info' verbose 'yes'
  # zstyle ':prezto:module:git:ignore' submodule 'all'
  # #zstyle ':prezto:module:git:info:branch' format '%F{242}%b%f'
  # #zstyle ':prezto:module:git:info:action' format '%F{242}|%f%F{red}%a%f'
  # zstyle ':prezto:module:git:info:clean' format '%F{green}✔%f'
  # zstyle ':prezto:module:git:info:dirty' format '%F{red}✗%f'
  # zstyle ':prezto:module:git:info:keys' format \
  #   'prompt' '' \
  #   'rprompt' '%C%D'

  # Define prompts.

  # show username@host if logged in through SSH
  # username turns red if user is privileged
  RPROMPT='%(!.%F{red}%n%f%F{242}.%F{green}%n%f%F{242})@%m%f'

  # prompt turns red if the previous command didn't exit with 0
  PROMPT='%(?.%F{green}.%F{red})❯%f '
}

prompt_filthy_setup "$@"
