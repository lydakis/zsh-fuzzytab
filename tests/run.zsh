#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit nounset pipe_fail

ROOT_DIR="${0:A:h:h}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fuzzy-tab-tests.XXXXXX")"
typeset -gi TEST_COUNT=0

cleanup() {
  command rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat >"$TMP_DIR/fzf-stub" <<'EOF'
#!/usr/bin/env zsh
emulate -L zsh

local query=""

while (( $# > 0 )); do
  case "$1" in
    --filter)
      query="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

fuzzy_match() {
  local needle="${1:l}"
  local haystack="${2:l}"
  local i=1
  local char

  [[ -z "$needle" ]] && return 0

  for (( ; i <= ${#needle}; i++ )); do
    char="${needle[i]}"
    if [[ "$haystack" != *"$char"* ]]; then
      return 1
    fi
    haystack="${haystack#*${char}}"
  done

  return 0
}

while IFS= read -r line; do
  if fuzzy_match "$query" "$line"; then
    print -r -- "$line"
  fi
done
EOF
chmod +x "$TMP_DIR/fzf-stub"

source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
FUZZY_TAB_FZF_BIN="$TMP_DIR/fzf-stub"

reset_test_state() {
  unfunction fc 2>/dev/null || true
  unfunction zle 2>/dev/null || true
  unfunction bindkey 2>/dev/null || true

  BUFFER=""
  LBUFFER=""
  RBUFFER=""
  CURSOR=0
  typeset -g TEST_FALLBACK_CALL=""
  typeset -ga TEST_BINDKEY_CALLS=()
  typeset -g TEST_ZLE_REGISTRATION=""
  typeset -g _FUZZY_TAB_ACTIVE_BINDKEY=""
  typeset -gA _FUZZY_TAB_BOUND_KEYS=()
  typeset -gA _FUZZY_TAB_PREVIOUS_WIDGETS=()
  typeset -ga _FUZZY_TAB_LAST_MATCHES=()
  typeset -g _FUZZY_TAB_LAST_QUERY=""
  typeset -g _FUZZY_TAB_LAST_SUFFIX=""
  typeset -g _FUZZY_TAB_LAST_SELECTED_LEFT=""
  typeset -g _FUZZY_TAB_LAST_SELECTED_BUFFER=""
  typeset -gi _FUZZY_TAB_LAST_INDEX=-1
  typeset -gA _FUZZY_TAB_LEARNED=()
  typeset -gi _FUZZY_TAB_LEARNED_LOADED=0
  FUZZY_TAB_LEARNING_FILE="$TMP_DIR/learned.tsv"
  command rm -f "$FUZZY_TAB_LEARNING_FILE"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  TEST_COUNT+=1

  if [[ "$expected" != "$actual" ]]; then
    print -u2 -- "FAIL: $message"
    print -u2 -- "  expected: $expected"
    print -u2 -- "  actual:   $actual"
    exit 1
  fi
}

test_history_matches_return_newest_unique_match() {
  reset_test_state

  function fc() {
    print -r -- "  44 git status"
    print -r -- "  43 git stash"
    print -r -- "  42 git status"
    print -r -- "  41 npm test"
  }

  local matches=("${(@f)$(_fuzzy_tab_history_matches "git st")}")
  assert_eq "git status|git stash" "${(j:|:)matches}" "history matches should dedupe and keep newest-first results"
}

test_rank_matches_prefers_learned_selection() {
  reset_test_state

  _FUZZY_TAB_LEARNED[$(_fuzzy_tab_query_key "bfmt")]="bb format"
  _FUZZY_TAB_LEARNED_LOADED=1

  local ranked=("${(@f)$(_fuzzy_tab_rank_matches "BFMT" "buffer format" "bb format" "build fmt")}")
  assert_eq "bb format|buffer format|build fmt" "${(j:|:)ranked}" "ranker should move the learned selection to the front for the same query"
}

test_expand_updates_buffer_and_cursor() {
  reset_test_state

  function fc() {
    print -r -- "  88 docker logs api"
    print -r -- "  87 docker compose up"
  }

  function zle() {
    TEST_FALLBACK_CALL="$*"
  }

  LBUFFER="docker lo"
  _fuzzy_tab_expand

  assert_eq "docker logs api" "$BUFFER" "widget should replace the buffer with the selected history entry"
  assert_eq "15" "$CURSOR" "cursor should move to the end of the selected command"
  assert_eq "" "$TEST_FALLBACK_CALL" "fallback widget should not run when a fuzzy match exists"
}

test_repeated_tab_cycles_through_matches() {
  reset_test_state

  function fc() {
    print -r -- "  30 bb format"
    print -r -- "  29 buffer format"
    print -r -- "  28 build fmt"
  }

  function zle() {
    TEST_FALLBACK_CALL="$*"
  }

  LBUFFER="bfmt"
  _fuzzy_tab_expand
  assert_eq "bb format" "$BUFFER" "first tab should still use the top-ranked match"

  _fuzzy_tab_expand
  assert_eq "buffer format" "$BUFFER" "second tab should cycle to the next fuzzy match"

  _fuzzy_tab_expand
  assert_eq "build fmt" "$BUFFER" "third tab should cycle through the remaining fuzzy matches"

  _fuzzy_tab_expand
  assert_eq "bb format" "$BUFFER" "cycling should wrap around after the final match"
  assert_eq "" "$TEST_FALLBACK_CALL" "cycling should not fall back while matches are available"
}

test_expand_preserves_right_buffer_on_match() {
  reset_test_state

  function fc() {
    print -r -- "  88 git status"
    print -r -- "  87 git switch main"
  }

  function zle() {
    TEST_FALLBACK_CALL="$*"
  }

  BUFFER="git --short"
  LBUFFER="git"
  RBUFFER=" --short"
  CURSOR=3
  _fuzzy_tab_expand

  assert_eq "git status --short" "$BUFFER" "widget should only replace the text to the left of the cursor"
  assert_eq "git status" "$LBUFFER" "left buffer should be replaced by the selected history entry"
  assert_eq " --short" "$RBUFFER" "right buffer should be preserved"
  assert_eq "10" "$CURSOR" "cursor should move to the end of the inserted history entry"
  assert_eq "" "$TEST_FALLBACK_CALL" "fallback widget should not run when a fuzzy match exists"
}

test_expand_does_not_duplicate_existing_suffix() {
  reset_test_state

  function fc() {
    print -r -- "  88 git status --short"
    print -r -- "  87 git switch main"
  }

  function zle() {
    TEST_FALLBACK_CALL="$*"
  }

  BUFFER="git --short"
  LBUFFER="git"
  RBUFFER=" --short"
  CURSOR=3
  _fuzzy_tab_expand

  assert_eq "git status --short" "$BUFFER" "widget should not duplicate suffix text already present in the selected history entry"
  assert_eq "git status" "$LBUFFER" "left buffer should stop before the preserved right-hand suffix"
  assert_eq " --short" "$RBUFFER" "right buffer should remain intact when the selected history entry already ends with it"
  assert_eq "10" "$CURSOR" "cursor should stay before the preserved right-hand suffix"
  assert_eq "" "$TEST_FALLBACK_CALL" "fallback widget should not run when a fuzzy match exists"
}

test_expand_falls_back_on_empty_query() {
  reset_test_state

  function zle() {
    TEST_FALLBACK_CALL="$*"
  }

  LBUFFER=""
  _fuzzy_tab_expand

  assert_eq "expand-or-complete" "$TEST_FALLBACK_CALL" "empty input should keep normal completion behavior"
}

test_expand_falls_back_when_no_match_exists() {
  reset_test_state

  function fc() {
    print -r -- "  12 git status"
    print -r -- "  11 npm test"
  }

  function zle() {
    TEST_FALLBACK_CALL="$*"
  }

  LBUFFER="kubectl"
  _fuzzy_tab_expand

  assert_eq "expand-or-complete" "$TEST_FALLBACK_CALL" "no fuzzy match should fall back to the configured completion widget"
}

test_commit_learning_persists_last_selected_match() {
  reset_test_state

  _FUZZY_TAB_LAST_QUERY="bfmt"
  BUFFER="bb format"
  _fuzzy_tab_commit_learning

  assert_eq "bb format" "$(_fuzzy_tab_preferred_match "BFMT")" "accepting a cycled selection should persist it as the preferred future match"
  assert_eq "" "$_FUZZY_TAB_LAST_QUERY" "committing learning should clear the active cycle state"
}

test_expand_falls_back_to_existing_widget_binding() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      bindkey -M main "^I" menu-complete
      bindkey -M emacs "^I" menu-complete
      bindkey -M viins "^I" menu-complete
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      function zle() { print -r -- "$*"; }
      LBUFFER=""
      _fuzzy_tab_expand
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq "menu-complete" "$output" "fallback should preserve the preexisting widget bound to the key"
}

test_expand_with_empty_history_stays_quiet() {
  reset_test_state

  local stderr
  stderr="$(
    zsh -f -c '
      ROOT_DIR="$1"
      FZF_BIN="$2"
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      FUZZY_TAB_FZF_BIN="$FZF_BIN"
      function zle() { :; }
      BUFFER="git"
      LBUFFER="git"
      _fuzzy_tab_expand
    ' test-shim "$ROOT_DIR" "$TMP_DIR/fzf-stub" 2>&1 >/dev/null
  )"

  assert_eq "" "$stderr" "empty history should not print errors when fuzzy expansion falls back"
}

test_bind_registers_widget_and_key() {
  reset_test_state

  function zle() {
    TEST_ZLE_REGISTRATION="$*"
  }

  function bindkey() {
    TEST_BINDKEY_CALLS+=("$*")
  }

  fuzzy_tab_bind '^G'

  assert_eq "-N fuzzy-tab-expand _fuzzy_tab_expand" "$TEST_ZLE_REGISTRATION" "bind helper should register the zle widget"
  assert_eq "-M main ^G fuzzy-tab-expand|-M emacs ^G fuzzy-tab-expand|-M viins ^G fuzzy-tab-expand" "${(j:|:)TEST_BINDKEY_CALLS}" "bind helper should wire the requested key across the supported editing keymaps"
}

test_manual_bind_preserves_existing_widget_on_fallback() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      FUZZY_TAB_DISABLE_AUTO_BIND=1
      bindkey -M main "^G" list-expand
      bindkey -M emacs "^G" list-expand
      bindkey -M viins "^G" list-expand
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      fuzzy_tab_bind "^G"
      function zle() { print -r -- "$*"; }
      LBUFFER=""
      _fuzzy_tab_expand
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq "list-expand" "$output" "manual binds should preserve the existing widget for empty-query fallback"
}

test_auto_bind_survives_switching_edit_modes() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      bindkey -v
      bindkey -M viins "^I"
      bindkey -e
      bindkey -M emacs "^I"
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq $'"^I" fuzzy-tab-expand\n"^I" fuzzy-tab-expand' "$output" "auto-bind should keep fuzzy tab active after switching between vi and emacs modes"
}

test_unbind_restores_original_widget_binding() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      bindkey -M main "^I" menu-complete
      bindkey -M emacs "^I" menu-complete
      bindkey -M viins "^I" menu-complete
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      fuzzy_tab_unbind
      bindkey -M main "^I"
      bindkey -M emacs "^I"
      bindkey -M viins "^I"
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq $'"^I" menu-complete\n"^I" menu-complete\n"^I" menu-complete' "$output" "unbind should restore the widget that was bound before fuzzy tab took over"
}

test_manual_unbind_defaults_to_last_bound_key() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      FUZZY_TAB_DISABLE_AUTO_BIND=1
      bindkey -M main "^G" list-expand
      bindkey -M emacs "^G" list-expand
      bindkey -M viins "^G" list-expand
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      fuzzy_tab_bind "^G"
      fuzzy_tab_unbind
      bindkey -M main "^G"
      bindkey -M emacs "^G"
      bindkey -M viins "^G"
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq $'"^G" list-expand\n"^G" list-expand\n"^G" list-expand' "$output" "manual unbind should restore the key that was most recently bound"
}

test_unbind_without_owned_key_is_noop() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      FUZZY_TAB_DISABLE_AUTO_BIND=1
      bindkey -M main "^I" menu-complete
      bindkey -M emacs "^I" menu-complete
      bindkey -M viins "^I" menu-complete
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      fuzzy_tab_unbind
      bindkey -M main "^I"
      bindkey -M emacs "^I"
      bindkey -M viins "^I"
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq $'"^I" menu-complete\n"^I" menu-complete\n"^I" menu-complete' "$output" "unbind should leave unrelated bindings alone when fuzzy tab does not own the key"
}

test_rebind_restores_previous_active_key() {
  reset_test_state

  local output
  output="$(
    zsh -f -ic '
      ROOT_DIR="$1"
      bindkey -M main "^I" menu-complete
      bindkey -M emacs "^I" menu-complete
      bindkey -M viins "^I" menu-complete
      source "$ROOT_DIR/fuzzy-tab.plugin.zsh"
      fuzzy_tab_bind "^G"
      bindkey -M main "^I"
      bindkey -M emacs "^I"
      bindkey -M viins "^I"
      bindkey -M main "^G"
      bindkey -M emacs "^G"
      bindkey -M viins "^G"
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq $'"^I" menu-complete\n"^I" menu-complete\n"^I" menu-complete\n"^G" fuzzy-tab-expand\n"^G" fuzzy-tab-expand\n"^G" fuzzy-tab-expand' "$output" "rebinding should restore the previously active key before taking over the new one"
}

test_repo_named_plugin_entrypoint_loads_primary_plugin() {
  reset_test_state

  local output
  output="$(
    zsh -f -c '
      ROOT_DIR="$1"
      source "$ROOT_DIR/zsh-fuzzytab.plugin.zsh"
      whence -w fuzzy_tab_bind
      print -- ${_FUZZY_TAB_PLUGIN_LOADED:-missing}
    ' test-shim "$ROOT_DIR"
  )"

  assert_eq $'fuzzy_tab_bind: function\n1' "$output" "repo-named plugin entrypoint should source the main plugin file"
}

test_history_matches_return_newest_unique_match
test_rank_matches_prefers_learned_selection
test_expand_updates_buffer_and_cursor
test_repeated_tab_cycles_through_matches
test_expand_preserves_right_buffer_on_match
test_expand_does_not_duplicate_existing_suffix
test_expand_falls_back_on_empty_query
test_expand_falls_back_when_no_match_exists
test_commit_learning_persists_last_selected_match
test_expand_falls_back_to_existing_widget_binding
test_expand_with_empty_history_stays_quiet
test_bind_registers_widget_and_key
test_manual_bind_preserves_existing_widget_on_fallback
test_auto_bind_survives_switching_edit_modes
test_unbind_restores_original_widget_binding
test_manual_unbind_defaults_to_last_bound_key
test_unbind_without_owned_key_is_noop
test_rebind_restores_previous_active_key
test_repo_named_plugin_entrypoint_loads_primary_plugin

print -- "ok $TEST_COUNT"
