if [[ -n ${_FUZZY_TAB_PLUGIN_LOADED:-} ]]; then
  return 0
fi

typeset -g _FUZZY_TAB_PLUGIN_LOADED=1

: "${FUZZY_TAB_BINDKEY:=^I}"
: "${FUZZY_TAB_COMPLETION_WIDGET:=expand-or-complete}"
: "${FUZZY_TAB_DISABLE_AUTO_BIND:=0}"
: "${FUZZY_TAB_FZF_BIN:=fzf}"
typeset -ga FUZZY_TAB_FZF_OPTS
typeset -ga _FUZZY_TAB_KEYMAPS=(main emacs viins)
typeset -g _FUZZY_TAB_ACTIVE_BINDKEY=""
typeset -gA _FUZZY_TAB_BOUND_KEYS
typeset -gA _FUZZY_TAB_PREVIOUS_WIDGETS

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

  if [[ -n "${_FUZZY_TAB_ACTIVE_BINDKEY-}" ]]; then
    print -r -- "$_FUZZY_TAB_ACTIVE_BINDKEY"
    return 0
  fi

  print -r -- "${FUZZY_TAB_BINDKEY:-^I}"
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
    [[ "$widget" == "fuzzy-tab-expand" ]] && continue
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

_fuzzy_tab_history_selection() {
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

  fc -rl 1 \
    | command sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*//' \
    | command awk '!seen[$0]++' \
    | "$fzf_bin" --scheme=history "${fzf_opts[@]}" --filter "$query" 2>/dev/null \
    | command sed -n '1p'
}

_fuzzy_tab_expand() {
  emulate -L zsh
  setopt localoptions no_aliases

  local query="${LBUFFER:-}"
  local selected
  local selected_left
  local suffix="${RBUFFER-}"

  if [[ -z "${query//[[:space:]]/}" ]]; then
    _fuzzy_tab_fallback
    return 0
  fi

  selected="$(_fuzzy_tab_history_selection "$query")"

  if [[ -n "$selected" ]]; then
    selected_left="$selected"

    if [[ -n "$suffix" && "$selected" == *"$suffix" ]]; then
      selected_left="${selected[1,$(( ${#selected} - ${#suffix} ))]}"
    fi

    BUFFER="${selected_left}${suffix}"
    LBUFFER="$selected_left"
    RBUFFER="$suffix"
    CURSOR=${#selected_left}
    return 0
  fi

  _fuzzy_tab_fallback
}

fuzzy_tab_bind() {
  local key="${1:-${FUZZY_TAB_BINDKEY:-^I}}"
  local previous_key="${_FUZZY_TAB_ACTIVE_BINDKEY-}"
  local keymap

  if [[ -n "$previous_key" && "$previous_key" != "$key" ]]; then
    fuzzy_tab_unbind "$previous_key"
  fi

  _fuzzy_tab_remember_bindings "$key"
  _FUZZY_TAB_ACTIVE_BINDKEY="$key"
  _FUZZY_TAB_BOUND_KEYS[$key]=1
  zle -N fuzzy-tab-expand _fuzzy_tab_expand
  for keymap in "${_FUZZY_TAB_KEYMAPS[@]}"; do
    bindkey -M "$keymap" "$key" fuzzy-tab-expand
  done
}

fuzzy_tab_unbind() {
  local key="${1:-$(_fuzzy_tab_current_key)}"
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

  unset "_FUZZY_TAB_BOUND_KEYS[$key]"
}

if [[ -o interactive && "${FUZZY_TAB_DISABLE_AUTO_BIND:-0}" != "1" ]]; then
  fuzzy_tab_bind
fi
