#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Interactive Commit Script
#
# Checks all repos in workspace, shows changes, and lets user choose to commit.
# Usage: ./commit-interactive.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Show help by default, toggle with h/?
SHOW_HELP=true

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
# shellcheck disable=SC2317  # Available as utility function
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header() { echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"; }

# Get display name for repo (handles meta repo ".")
display_name() {
    local repo="$1"
    if [[ "$repo" == "." ]]; then
        echo "(meta)"
    else
        echo "$repo"
    fi
}

# Find all git repos
find_repos() {
    local repos=()

    # Check if workspace root is a git repo (meta repo)
    if [[ -d "$WORKSPACE/.git" ]]; then
        repos+=(".")
    fi

    # Check subdirectories
    for dir in "$WORKSPACE"/*/; do
        if [[ -d "${dir}.git" ]]; then
            repos+=("$(basename "$dir")")
        fi
    done
    echo "${repos[@]}"
}

# Check if repo has changes
has_changes() {
    local repo_dir="$1"
    cd "$repo_dir" || return 1
    # Check for staged, unstaged, or untracked files
    if ! git diff --quiet 2>/dev/null || \
       ! git diff --cached --quiet 2>/dev/null || \
       [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        return 0
    fi
    return 1
}

# Show repo status
show_status() {
    local repo_dir="$1"
    local repo_name="$2"

    cd "$repo_dir" || return 1

    echo -e "${CYAN}Status:${NC}"
    git status -sb

    # Show brief diff summary
    local staged
    staged=$(git diff --cached --stat 2>/dev/null | tail -1)
    local unstaged
    unstaged=$(git diff --stat 2>/dev/null | tail -1)

    if [[ -n "$staged" ]]; then
        echo -e "\n${GREEN}Staged changes:${NC}"
        git diff --cached --stat | head -20
    fi

    if [[ -n "$unstaged" ]]; then
        echo -e "\n${YELLOW}Unstaged changes:${NC}"
        git diff --stat | head -20
    fi

    # Show untracked files
    local untracked
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
    if [[ -n "$untracked" ]]; then
        echo -e "\n${RED}Untracked files:${NC}"
        echo "$untracked" | head -10
        local count
        count=$(echo "$untracked" | wc -l)
        if [[ $count -gt 10 ]]; then
            echo "  ... and $((count - 10)) more"
        fi
    fi
}

# Show help box
show_help_box() {
    local repo_name="$1"
    echo -e "${YELLOW}┌─────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC} ${BOLD}Actions for ${CYAN}$repo_name${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  ${GREEN}a${NC} = Add all & commit                   ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${GREEN}s${NC} = Stage interactively (git add -p)   ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}d${NC} = Show full diff                     ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}c${NC} = Commit staged only                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${RED}r${NC} = Reset/discard changes              ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${NC}n${NC} = Skip, ${NC}q${NC} = Quit, ${NC}?${NC} = Toggle help  ${YELLOW}│${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────┘${NC}"
}

# Prompt for action (sets global CHOICE variable)
prompt_action() {
    local repo_name="$1"
    echo ""
    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help_box "$repo_name"
        echo ""
        read -rp "Choice [a/s/d/c/r/n/q/?]: " -n 1 CHOICE
    else
        read -rp "${repo_name} [a/s/d/c/r/n/q/?]: " -n 1 CHOICE
    fi
    echo ""
}

# Handle commit
do_commit() {
    local repo_dir="$1"
    local repo_name="$2"

    cd "$repo_dir" || return 1

    # Check if there's anything staged
    if git diff --cached --quiet 2>/dev/null; then
        warn "Nothing staged to commit"
        return 1
    fi

    echo ""
    read -rp "Commit message: " message

    if [[ -z "$message" ]]; then
        warn "Empty message, skipping commit"
        return 1
    fi

    git commit -m "$message"
    info "Committed to $repo_name"
}

# Main
main() {
    echo -e "${YELLOW}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}${BOLD}║     Interactive Commit Tool            ║${NC}"
    echo -e "${YELLOW}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Workspace: $WORKSPACE"

    # Find repos with changes
    local repos_with_changes=()

    # shellcheck disable=SC2046
    for repo in $(find_repos); do
        local repo_dir="$WORKSPACE/$repo"
        if has_changes "$repo_dir"; then
            repos_with_changes+=("$repo")
        fi
    done

    if [[ ${#repos_with_changes[@]} -eq 0 ]]; then
        info "No repos have uncommitted changes"
        exit 0
    fi

    echo ""
    # Build display list
    local display_list=""
    for repo in "${repos_with_changes[@]}"; do
        display_list+="$(display_name "$repo") "
    done
    info "Repos with changes: $display_list"

    # Process each repo
    for repo in "${repos_with_changes[@]}"; do
        local repo_dir="$WORKSPACE/$repo"
        local name
        name=$(display_name "$repo")

        header "$name"
        show_status "$repo_dir" "$name"

        while true; do
            prompt_action "$name"

            case "$CHOICE" in
                a|A)
                    cd "$repo_dir" || break
                    git add -A
                    info "Staged all changes"
                    do_commit "$repo_dir" "$name" || true
                    break
                    ;;
                s|S)
                    cd "$repo_dir" || break
                    git add -p
                    if ! git diff --cached --quiet 2>/dev/null; then
                        do_commit "$repo_dir" "$name" || true
                    fi
                    break
                    ;;
                d|D)
                    cd "$repo_dir" || break
                    echo ""
                    git diff --color | head -100
                    echo -e "\n${YELLOW}(showing first 100 lines)${NC}"
                    ;;
                c|C)
                    if ! git diff --cached --quiet 2>/dev/null; then
                        do_commit "$repo_dir" "$name" || true
                    else
                        warn "Nothing staged. Use 'a' to add all or 's' to stage interactively"
                    fi
                    break
                    ;;
                r|R)
                    echo ""
                    read -rp "Are you sure you want to discard all changes? [y/N] " confirm
                    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                        cd "$repo_dir" || break
                        git checkout -- .
                        git clean -fd
                        info "Changes discarded"
                    fi
                    break
                    ;;
                n|N)
                    info "Skipping $name"
                    break
                    ;;
                q|Q)
                    info "Quitting"
                    exit 0
                    ;;
                h|H|\?)
                    if [[ "$SHOW_HELP" == "true" ]]; then
                        SHOW_HELP=false
                        info "Help hidden (press ? to show)"
                    else
                        SHOW_HELP=true
                    fi
                    ;;
                *)
                    warn "Unknown option: $CHOICE (press ? for help)"
                    ;;
            esac
        done
    done

    echo ""
    info "Done!"

    # Show final summary
    header "Summary"
    for repo in "${repos_with_changes[@]}"; do
        local repo_dir="$WORKSPACE/$repo"
        local name
        name=$(display_name "$repo")
        cd "$repo_dir" || continue
        local status=""
        if has_changes "$repo_dir"; then
            status="${YELLOW}has uncommitted changes${NC}"
        else
            status="${GREEN}clean${NC}"
        fi
        echo -e "  $name: $status"
    done
}

main "$@"
