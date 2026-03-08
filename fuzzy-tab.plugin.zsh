if [[ -n ${_FUZZY_TAB_PLUGIN_LOADED:-} ]]; then
  return 0
fi

typeset -g _FUZZY_TAB_PLUGIN_LOADED=1

: "${FUZZY_TAB_BINDKEY:=^I}"
: "${FUZZY_TAB_REVERSE_BINDKEY:=^[[Z}"
: "${FUZZY_TAB_SEARCH_BINDKEY:=^R}"
: "${FUZZY_TAB_COMPLETION_WIDGET:=expand-or-complete}"
: "${FUZZY_TAB_DISABLE_AUTO_BIND:=0}"
: "${FUZZY_TAB_FZF_BIN:=fzf}"
: "${FUZZY_TAB_LEARNING_ENABLED:=1}"
: "${FUZZY_TAB_LEARNING_FILE:=${XDG_STATE_HOME:-$HOME/.local/state}/zsh-fuzzytab/selections.tsv}"
typeset -ga FUZZY_TAB_FZF_OPTS
typeset -ga _FUZZY_TAB_KEYMAPS=(main emacs viins)
typeset -g _FUZZY_TAB_ACTIVE_BINDKEY=""
typeset -g _FUZZY_TAB_ACTIVE_REVERSE_BINDKEY=""
typeset -g _FUZZY_TAB_ACTIVE_SEARCH_BINDKEY=""
typeset -g _FUZZY_TAB_CURRENT_WIDGET_KEY=""
typeset -gA _FUZZY_TAB_BOUND_KEYS
typeset -gA _FUZZY_TAB_PREVIOUS_WIDGETS
typeset -ga _FUZZY_TAB_LAST_MATCHES=()
typeset -g _FUZZY_TAB_LAST_QUERY=""
typeset -g _FUZZY_TAB_LAST_SUFFIX=""
typeset -g _FUZZY_TAB_LAST_SELECTED_LEFT=""
typeset -g _FUZZY_TAB_LAST_SELECTED_BUFFER=""
typeset -gi _FUZZY_TAB_LAST_INDEX=-1
typeset -gA _FUZZY_TAB_LEARNED
typeset -gi _FUZZY_TAB_LEARNED_LOADED=0

_fuzzy_tab_reset_state() {
  _FUZZY_TAB_LAST_MATCHES=()
  _FUZZY_TAB_LAST_QUERY=""
  _FUZZY_TAB_LAST_SUFFIX=""
  _FUZZY_TAB_LAST_SELECTED_LEFT=""
  _FUZZY_TAB_LAST_SELECTED_BUFFER=""
  _FUZZY_TAB_LAST_INDEX=-1
}

_fuzzy_tab_query_key() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query="${1-}"
  query="${query//$'\n'/ }"
  query="${query//$'\r'/ }"
  query="${query//$'\t'/ }"

  print -r -- "${query:l}"
}

_fuzzy_tab_load_learning() {
  emulate -L zsh
  setopt localoptions no_aliases

  local line
  local key
  local command

  (( _FUZZY_TAB_LEARNED_LOADED )) && return 0
  _FUZZY_TAB_LEARNED_LOADED=1

  [[ "${FUZZY_TAB_LEARNING_ENABLED:-1}" == "1" ]] || return 0
  [[ -r "${FUZZY_TAB_LEARNING_FILE:-}" ]] || return 0

  while IFS=$'\t' read -r key command; do
    [[ -n "$key" && -n "$command" ]] || continue
    _FUZZY_TAB_LEARNED[$key]="$command"
  done < "$FUZZY_TAB_LEARNING_FILE"
}

_fuzzy_tab_write_learning() {
  emulate -L zsh
  setopt localoptions no_aliases pipe_fail

  local file="${FUZZY_TAB_LEARNING_FILE:-}"
  local dir="${file:h}"
  local key

  [[ "${FUZZY_TAB_LEARNING_ENABLED:-1}" == "1" ]] || return 0
  [[ -n "$file" ]] || return 0

  command mkdir -p "$dir" || return 1
  : >| "$file" || return 1

  for key in "${(@k)_FUZZY_TAB_LEARNED}"; do
    print -r -- "${key}"$'\t'"${_FUZZY_TAB_LEARNED[$key]}" >>| "$file" || return 1
  done
}

_fuzzy_tab_remember_selection() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query_key
  local command="${2-}"

  [[ "${FUZZY_TAB_LEARNING_ENABLED:-1}" == "1" ]] || return 0
  query_key="$(_fuzzy_tab_query_key "${1-}")"
  [[ -n "$query_key" && -n "$command" ]] || return 0

  _fuzzy_tab_load_learning
  _FUZZY_TAB_LEARNED[$query_key]="$command"
  _fuzzy_tab_write_learning
}

_fuzzy_tab_preferred_match() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query_key

  [[ "${FUZZY_TAB_LEARNING_ENABLED:-1}" == "1" ]] || return 1
  query_key="$(_fuzzy_tab_query_key "${1-}")"
  [[ -n "$query_key" ]] || return 1

  _fuzzy_tab_load_learning
  [[ -n "${_FUZZY_TAB_LEARNED[$query_key]-}" ]] || return 1
  print -r -- "${_FUZZY_TAB_LEARNED[$query_key]}"
}

_fuzzy_tab_binding_key() {
  print -r -- "${1}:${2}"
}

_fuzzy_tab_current_key() {
  emulate -L zsh
  setopt localoptions no_aliases

  if [[ -n "${KEYS-}" ]]; then
    print -r -- "$KEYS"
    return 0
  fi

  if [[ -n "${_FUZZY_TAB_CURRENT_WIDGET_KEY-}" ]]; then
    print -r -- "$_FUZZY_TAB_CURRENT_WIDGET_KEY"
    return 0
  fi

  if [[ -n "${_FUZZY_TAB_ACTIVE_BINDKEY-}" ]]; then
    print -r -- "$_FUZZY_TAB_ACTIVE_BINDKEY"
    return 0
  fi

  print -r -- "${FUZZY_TAB_BINDKEY:-^I}"
}

_fuzzy_tab_active_cycle() {
  [[ -n "${_FUZZY_TAB_LAST_QUERY-}" \
    && "${LBUFFER:-}" == "${_FUZZY_TAB_LAST_SELECTED_LEFT-}" \
    && "${RBUFFER-}" == "${_FUZZY_TAB_LAST_SUFFIX-}" \
    && ${#_FUZZY_TAB_LAST_MATCHES[@]} -gt 0 ]]
}

_fuzzy_tab_bound_widget() {
  emulate -L zsh
  setopt localoptions no_aliases

  local keymap="$1"
  local key="$2"
  local binding

  binding="$(bindkey -M "$keymap" "$key" 2>/dev/null)" || return 1
  [[ -n "$binding" ]] || return 1
  print -r -- "${binding##* }"
}

_fuzzy_tab_remember_bindings() {
  emulate -L zsh
  setopt localoptions no_aliases

  local key="$1"
  local keymap
  local binding_key
  local widget

  for keymap in "${_FUZZY_TAB_KEYMAPS[@]}"; do
    widget="$(_fuzzy_tab_bound_widget "$keymap" "$key")" || continue
    case "$widget" in
      fuzzy-tab-expand|fuzzy-tab-reverse|fuzzy-tab-search)
        continue
        ;;
    esac
    binding_key="$(_fuzzy_tab_binding_key "$keymap" "$key")"
    _FUZZY_TAB_PREVIOUS_WIDGETS[$binding_key]="$widget"
  done
}

_fuzzy_tab_fallback_widget() {
  emulate -L zsh
  setopt localoptions no_aliases

  local key="$(_fuzzy_tab_current_key)"
  local keymap="${KEYMAP:-main}"
  local binding_key="$(_fuzzy_tab_binding_key "$keymap" "$key")"
  local widget="${_FUZZY_TAB_PREVIOUS_WIDGETS[$binding_key]-}"

  if [[ -z "$widget" && "$keymap" != "main" ]]; then
    binding_key="$(_fuzzy_tab_binding_key "main" "$key")"
    widget="${_FUZZY_TAB_PREVIOUS_WIDGETS[$binding_key]-}"
  fi

  print -r -- "${widget:-${FUZZY_TAB_COMPLETION_WIDGET:-expand-or-complete}}"
}

_fuzzy_tab_fallback() {
  local widget="$(_fuzzy_tab_fallback_widget)"
  zle "$widget"
}

_fuzzy_tab_has_fzf() {
  local fzf_bin="${FUZZY_TAB_FZF_BIN:-fzf}"

  if [[ "$fzf_bin" == */* ]]; then
    [[ -x "$fzf_bin" ]]
    return
  fi

  (( ${+commands[$fzf_bin]} ))
}

_fuzzy_tab_history_entries() {
  emulate -L zsh
  setopt localoptions pipe_fail no_aliases

  fc -l -1 >/dev/null 2>&1 || return 1

  fc -rl 1 \
    | command sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*//' \
    | command awk '!seen[$0]++'
}

_fuzzy_tab_history_matches() {
  emulate -L zsh
  setopt localoptions pipe_fail no_aliases

  local query="${1-}"
  local fzf_bin="${FUZZY_TAB_FZF_BIN:-fzf}"
  local -a fzf_opts

  [[ -n "${query//[[:space:]]/}" ]] || return 1
  _fuzzy_tab_has_fzf || return 1
  fc -l -1 >/dev/null 2>&1 || return 1

  if (( ${+FUZZY_TAB_FZF_OPTS} )); then
    fzf_opts=("${FUZZY_TAB_FZF_OPTS[@]}")
  fi

  _fuzzy_tab_history_entries \
    | "$fzf_bin" --scheme=history "${fzf_opts[@]}" --filter "$query" 2>/dev/null
}

_fuzzy_tab_rank_matches() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query="${1-}"
  shift

  local preferred
  local match
  local -a matches ranked

  matches=("$@")
  preferred="$(_fuzzy_tab_preferred_match "$query")" || true

  if [[ -n "$preferred" ]]; then
    for match in "${matches[@]}"; do
      [[ "$match" == "$preferred" ]] || continue
      ranked+=("$match")
      break
    done
  fi

  for match in "${matches[@]}"; do
    [[ "$match" == "$preferred" ]] && continue
    ranked+=("$match")
  done

  print -r -- "${(@F)ranked}"
}

_fuzzy_tab_apply_match() {
  emulate -L zsh
  setopt localoptions no_aliases

  local selected="${1-}"
  local suffix="${2-}"
  local selected_left="$selected"

  if [[ -n "$suffix" && "$selected" == *"$suffix" ]]; then
    selected_left="${selected[1,$(( ${#selected} - ${#suffix} ))]}"
  fi

  BUFFER="${selected_left}${suffix}"
  LBUFFER="$selected_left"
  RBUFFER="$suffix"
  CURSOR=${#selected_left}
  _FUZZY_TAB_LAST_SELECTED_LEFT="$selected_left"
  _FUZZY_TAB_LAST_SELECTED_BUFFER="$BUFFER"
}

_fuzzy_tab_cycle_existing_match() {
  emulate -L zsh
  setopt localoptions no_aliases

  local direction="${1:-1}"
  local selected
  local match_count=${#_FUZZY_TAB_LAST_MATCHES[@]}

  (( match_count > 0 )) || return 1

  _FUZZY_TAB_LAST_INDEX=$(( (_FUZZY_TAB_LAST_INDEX + direction + match_count) % match_count ))
  selected="${_FUZZY_TAB_LAST_MATCHES[_FUZZY_TAB_LAST_INDEX + 1]}"
  _fuzzy_tab_apply_match "$selected" "${_FUZZY_TAB_LAST_SUFFIX-}"
}

_fuzzy_tab_set_active_matches() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query="${1-}"
  local selected="${2-}"
  local suffix="${3-}"
  local ranked_matches
  local match
  local index=0
  local -a matches

  matches=("${(@f)$(_fuzzy_tab_history_matches "$query")}")
  matches=("${(@)matches:#}")
  if (( ${#matches[@]} )); then
    ranked_matches=("$(_fuzzy_tab_rank_matches "$query" "${matches[@]}")")
    matches=("${(@f)ranked_matches}")
    matches=("${(@)matches:#}")
  fi

  if (( ! ${#matches[@]} )); then
    _fuzzy_tab_reset_state
    return 1
  fi

  for match in "${matches[@]}"; do
    if [[ "$match" == "$selected" ]]; then
      _FUZZY_TAB_LAST_MATCHES=("${matches[@]}")
      _FUZZY_TAB_LAST_QUERY="$query"
      _FUZZY_TAB_LAST_SUFFIX="$suffix"
      _FUZZY_TAB_LAST_INDEX="$index"
      return 0
    fi
    index=$(( index + 1 ))
  done

  _fuzzy_tab_reset_state
  return 1
}

_fuzzy_tab_commit_learning() {
  emulate -L zsh
  setopt localoptions no_aliases

  [[ -n "${_FUZZY_TAB_LAST_QUERY-}" ]] || return 0
  [[ -n "${BUFFER-}" ]] || return 0

  _fuzzy_tab_remember_selection "$_FUZZY_TAB_LAST_QUERY" "$BUFFER"
  _fuzzy_tab_reset_state
}

_fuzzy_tab_line_finish() {
  _fuzzy_tab_commit_learning
}

_fuzzy_tab_expand() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query="${LBUFFER:-}"
  local suffix="${RBUFFER-}"
  local selected
  local ranked_matches
  local previous_widget_key="${_FUZZY_TAB_CURRENT_WIDGET_KEY-}"
  local -a matches

  _FUZZY_TAB_CURRENT_WIDGET_KEY="${KEYS:-${_FUZZY_TAB_ACTIVE_BINDKEY:-${FUZZY_TAB_BINDKEY:-^I}}}"

  if [[ -z "${query//[[:space:]]/}" ]]; then
    _fuzzy_tab_reset_state
    _fuzzy_tab_fallback
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  if _fuzzy_tab_active_cycle; then
    _fuzzy_tab_cycle_existing_match 1
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  matches=("${(@f)$(_fuzzy_tab_history_matches "$query")}")
  matches=("${(@)matches:#}")
  if (( ${#matches[@]} )); then
    ranked_matches=("$(_fuzzy_tab_rank_matches "$query" "${matches[@]}")")
    matches=("${(@f)ranked_matches}")
    matches=("${(@)matches:#}")
  fi

  if (( ${#matches[@]} )); then
    selected="${matches[1]}"
    _FUZZY_TAB_LAST_MATCHES=("${matches[@]}")
    _FUZZY_TAB_LAST_QUERY="$query"
    _FUZZY_TAB_LAST_SUFFIX="$suffix"
    _FUZZY_TAB_LAST_INDEX=0
    _fuzzy_tab_apply_match "$selected" "$suffix"
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  _fuzzy_tab_reset_state
  _fuzzy_tab_fallback
  _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
}

_fuzzy_tab_reverse() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query="${LBUFFER:-}"
  local previous_widget_key="${_FUZZY_TAB_CURRENT_WIDGET_KEY-}"

  _FUZZY_TAB_CURRENT_WIDGET_KEY="${KEYS:-${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY:-${FUZZY_TAB_REVERSE_BINDKEY:-^[[Z}}}"

  if [[ -z "${query//[[:space:]]/}" ]]; then
    _fuzzy_tab_reset_state
    _fuzzy_tab_fallback
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  if _fuzzy_tab_active_cycle; then
    _fuzzy_tab_cycle_existing_match -1
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  _fuzzy_tab_fallback
  _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
}

_fuzzy_tab_search() {
  emulate -L zsh
  setopt localoptions no_aliases pipe_fail

  local suffix="${RBUFFER-}"
  local query="${_FUZZY_TAB_LAST_QUERY-}"
  local fzf_bin="${FUZZY_TAB_FZF_BIN:-fzf}"
  local previous_widget_key="${_FUZZY_TAB_CURRENT_WIDGET_KEY-}"
  local final_query
  local selected
  local -a fzf_opts
  local -a search_output

  _FUZZY_TAB_CURRENT_WIDGET_KEY="${KEYS:-${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY:-${FUZZY_TAB_SEARCH_BINDKEY:-^R}}}"

  if ! _fuzzy_tab_active_cycle; then
    _fuzzy_tab_fallback
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  [[ -n "${query//[[:space:]]/}" ]] || query="${LBUFFER:-}"
  if [[ -z "${query//[[:space:]]/}" ]] || ! _fuzzy_tab_has_fzf; then
    _fuzzy_tab_fallback
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  if (( ${+FUZZY_TAB_FZF_OPTS} )); then
    fzf_opts=("${FUZZY_TAB_FZF_OPTS[@]}")
  fi

  search_output=("${(@f)$(
    _fuzzy_tab_history_entries \
      | "$fzf_bin" --scheme=history "${fzf_opts[@]}" --query "$query" --print-query 2>/dev/null
  )}")
  final_query="${search_output[1]-}"
  selected="${search_output[2]-}"

  if [[ -z "$selected" ]]; then
    _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
    return 0
  fi

  final_query="${final_query:-$query}"
  _fuzzy_tab_apply_match "$selected" "$suffix"
  _fuzzy_tab_set_active_matches "$final_query" "$selected" "$suffix" || true
  _FUZZY_TAB_CURRENT_WIDGET_KEY="$previous_widget_key"
}

_fuzzy_tab_bind_widget() {
  emulate -L zsh
  setopt localoptions no_aliases

  local key="$1"
  local widget="$2"
  local keymap

  [[ -n "$key" ]] || return 0

  _fuzzy_tab_remember_bindings "$key"
  _FUZZY_TAB_BOUND_KEYS[$key]=1
  for keymap in "${_FUZZY_TAB_KEYMAPS[@]}"; do
    bindkey -M "$keymap" "$key" "$widget"
  done
}

_fuzzy_tab_unbind_key() {
  emulate -L zsh
  setopt localoptions no_aliases

  local key="$1"
  local keymap
  local binding_key
  local widget

  [[ -n "${_FUZZY_TAB_BOUND_KEYS[$key]-}" ]] || return 0

  for keymap in "${_FUZZY_TAB_KEYMAPS[@]}"; do
    binding_key="$(_fuzzy_tab_binding_key "$keymap" "$key")"
    widget="${_FUZZY_TAB_PREVIOUS_WIDGETS[$binding_key]-}"

    if [[ -n "$widget" ]]; then
      bindkey -M "$keymap" "$key" "$widget"
      continue
    fi

    bindkey -M "$keymap" -r "$key"
  done

  if [[ "${_FUZZY_TAB_ACTIVE_BINDKEY-}" == "$key" ]]; then
    _FUZZY_TAB_ACTIVE_BINDKEY=""
  fi

  if [[ "${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY-}" == "$key" ]]; then
    _FUZZY_TAB_ACTIVE_REVERSE_BINDKEY=""
  fi

  if [[ "${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY-}" == "$key" ]]; then
    _FUZZY_TAB_ACTIVE_SEARCH_BINDKEY=""
  fi

  unset "_FUZZY_TAB_BOUND_KEYS[$key]"
}

fuzzy_tab_bind() {
  local key="${1:-${FUZZY_TAB_BINDKEY:-^I}}"
  local reverse_key="${FUZZY_TAB_REVERSE_BINDKEY:-}"
  local search_key="${FUZZY_TAB_SEARCH_BINDKEY:-}"
  local previous_key="${_FUZZY_TAB_ACTIVE_BINDKEY-}"
  local previous_reverse_key="${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY-}"
  local previous_search_key="${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY-}"

  if [[ -n "$previous_key" && "$previous_key" != "$key" ]]; then
    fuzzy_tab_unbind "$previous_key"
  fi

  if [[ -n "$previous_reverse_key" && "$previous_reverse_key" != "$reverse_key" && "$previous_reverse_key" != "$key" ]]; then
    fuzzy_tab_unbind "$previous_reverse_key"
  fi

  if [[ -n "$previous_search_key" && "$previous_search_key" != "$search_key" && "$previous_search_key" != "$key" && "$previous_search_key" != "$reverse_key" ]]; then
    fuzzy_tab_unbind "$previous_search_key"
  fi

  _FUZZY_TAB_ACTIVE_BINDKEY="$key"
  zle -N fuzzy-tab-expand _fuzzy_tab_expand
  zle -N fuzzy-tab-reverse _fuzzy_tab_reverse
  zle -N fuzzy-tab-search _fuzzy_tab_search
  _fuzzy_tab_bind_widget "$key" fuzzy-tab-expand

  if [[ -n "$reverse_key" && "$reverse_key" != "$key" ]]; then
    _FUZZY_TAB_ACTIVE_REVERSE_BINDKEY="$reverse_key"
    _fuzzy_tab_bind_widget "$reverse_key" fuzzy-tab-reverse
  else
    _FUZZY_TAB_ACTIVE_REVERSE_BINDKEY=""
  fi

  if [[ -n "$search_key" && "$search_key" != "$key" && "$search_key" != "$reverse_key" ]]; then
    _FUZZY_TAB_ACTIVE_SEARCH_BINDKEY="$search_key"
    _fuzzy_tab_bind_widget "$search_key" fuzzy-tab-search
  else
    _FUZZY_TAB_ACTIVE_SEARCH_BINDKEY=""
  fi
}

fuzzy_tab_unbind() {
  local key="${1-}"

  if [[ -n "$key" ]]; then
    _fuzzy_tab_unbind_key "$key"
    return 0
  fi

  _fuzzy_tab_unbind_key "${_FUZZY_TAB_ACTIVE_BINDKEY-}"
  if [[ -n "${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY-}" && "${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY-}" != "${_FUZZY_TAB_ACTIVE_BINDKEY-}" ]]; then
    _fuzzy_tab_unbind_key "${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY-}"
  fi
  if [[ -n "${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY-}" \
    && "${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY-}" != "${_FUZZY_TAB_ACTIVE_BINDKEY-}" \
    && "${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY-}" != "${_FUZZY_TAB_ACTIVE_REVERSE_BINDKEY-}" ]]; then
    _fuzzy_tab_unbind_key "${_FUZZY_TAB_ACTIVE_SEARCH_BINDKEY-}"
  fi
}

if [[ -o interactive && "${FUZZY_TAB_DISABLE_AUTO_BIND:-0}" != "1" ]]; then
  autoload -Uz add-zle-hook-widget 2>/dev/null || true
  if whence -w add-zle-hook-widget >/dev/null 2>&1; then
    add-zle-hook-widget line-finish _fuzzy_tab_line_finish
  fi
  fuzzy_tab_bind
fi
