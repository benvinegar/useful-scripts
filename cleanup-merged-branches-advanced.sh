#!/bin/bash

# Advanced script to clean up deprecated branches using multiple criteria
# This script will identify deprecated branches based on:
# 1. Branches merged into main
# 2. Branches with no recent activity (stale)
# 3. Branches whose remote has been deleted
# 4. Branches that are behind main by many commits
# 5. Branches with squash-merged commits

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${GREEN}Advanced Git Branch Cleanup Tool${NC}"
echo "================================="
echo ""

# Configuration
STALE_DAYS=${STALE_DAYS:-90}  # Branches older than this are considered stale
BEHIND_THRESHOLD=${BEHIND_THRESHOLD:-50}  # Branches behind by more than this many commits
FORCE_DELETE=false  # Force delete branches with unmerged changes

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --unsafe)
            FORCE_DELETE=true
            shift
            ;;
        --stale-days)
            STALE_DAYS="$2"
            shift 2
            ;;
        --behind-threshold)
            BEHIND_THRESHOLD="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --unsafe              Force delete branches even with unmerged changes"
            echo "  --stale-days N        Consider branches stale after N days (default: 90)"
            echo "  --behind-threshold N  Consider branches deprecated if N commits behind (default: 50)"
            echo "  --help                Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Ensure we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: Not in a git repository${NC}"
    exit 1
fi

# Get the main branch name
MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

# If MAIN_BRANCH is empty, try to detect it
if [ -z "$MAIN_BRANCH" ]; then
    if git show-ref --verify --quiet refs/heads/main; then
        MAIN_BRANCH="main"
    elif git show-ref --verify --quiet refs/heads/master; then
        MAIN_BRANCH="master"
    else
        echo -e "${RED}Error: Cannot determine main branch${NC}"
        echo "Please set it with: git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main"
        exit 1
    fi
fi

echo -e "Using ${YELLOW}$MAIN_BRANCH${NC} as the main branch"
echo -e "Stale threshold: ${YELLOW}$STALE_DAYS days${NC}"
echo -e "Behind threshold: ${YELLOW}$BEHIND_THRESHOLD commits${NC}"
if [ "$FORCE_DELETE" = "true" ]; then
    echo -e "${RED}UNSAFE MODE: Force deleting branches with unmerged changes${NC}"
fi
echo ""

# Fetch latest changes
echo "Fetching latest changes from remote..."
git fetch --prune

# Switch to main branch and pull latest
echo "Switching to $MAIN_BRANCH and pulling latest..."
git checkout $MAIN_BRANCH >/dev/null 2>&1
git pull >/dev/null 2>&1

echo ""
echo "Analyzing branches..."
echo ""

# Create temporary files to store branch information
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Files to store different types of branches
DEPRECATED_BRANCHES="$TEMP_DIR/deprecated.txt"
STALE_BRANCHES="$TEMP_DIR/stale.txt"
BRANCH_INFO="$TEMP_DIR/info.txt"

# Clear files
> "$DEPRECATED_BRANCHES"
> "$STALE_BRANCHES"
> "$BRANCH_INFO"

# Function to check if a branch might have been squash-merged
is_likely_squash_merged() {
    local branch=$1
    
    # Get the commit messages from the branch
    local branch_commits=$(git log $MAIN_BRANCH..$branch --pretty=format:"%s" 2>/dev/null)
    
    if [ -z "$branch_commits" ]; then
        # No commits unique to this branch - might be merged
        return 0
    fi
    
    # Check if any of the branch's commits appear in main (possibly squashed)
    while IFS= read -r commit_msg; do
        if [ -n "$commit_msg" ]; then
            # Search for similar commit message in main (could be prefixed with PR info)
            if git log $MAIN_BRANCH --grep="$commit_msg" --pretty=format:"%s" | grep -q .; then
                return 0
            fi
        fi
    done <<< "$branch_commits"
    
    return 1
}

# Get all local branches (excluding current)
ALL_BRANCHES=$(git branch | grep -v "^\*" | sed 's/^[[:space:]]*//')

# Analyze each branch
while IFS= read -r branch; do
    if [ "$branch" = "$MAIN_BRANCH" ]; then
        continue
    fi
    
    reasons=""
    status="active"
    
    # 1. Check if merged
    if git branch --merged $MAIN_BRANCH | grep -q "^[[:space:]]*$branch$"; then
        reasons="merged into $MAIN_BRANCH"
        status="deprecated"
    fi
    
    # 2. Check if remote branch was deleted
    if ! git ls-remote --heads origin "$branch" | grep -q .; then
        if git config --get branch.$branch.remote >/dev/null 2>&1; then
            if [ -n "$reasons" ]; then
                reasons="$reasons, remote branch deleted"
            else
                reasons="remote branch deleted"
            fi
            status="deprecated"
        fi
    fi
    
    # 3. Check if stale (no commits in X days)
    last_commit_date=$(git log -1 --format="%at" "$branch" 2>/dev/null || echo "0")
    current_date=$(date +%s)
    days_old=$(( (current_date - last_commit_date) / 86400 ))
    
    if [ $days_old -gt $STALE_DAYS ]; then
        if [ -n "$reasons" ]; then
            reasons="$reasons, no activity for $days_old days"
        else
            reasons="no activity for $days_old days"
        fi
        if [ "$status" != "deprecated" ]; then
            status="stale"
        fi
    fi
    
    # 4. Check how far behind main
    behind_count=$(git rev-list --count $branch..$MAIN_BRANCH 2>/dev/null || echo "0")
    ahead_count=$(git rev-list --count $MAIN_BRANCH..$branch 2>/dev/null || echo "0")
    
    if [ $behind_count -gt $BEHIND_THRESHOLD ] && [ $ahead_count -eq 0 ]; then
        if [ -n "$reasons" ]; then
            reasons="$reasons, $behind_count commits behind $MAIN_BRANCH with no new commits"
        else
            reasons="$behind_count commits behind $MAIN_BRANCH with no new commits"
        fi
        if [ "$status" != "deprecated" ]; then
            status="stale"
        fi
    fi
    
    # 5. Check if likely squash-merged
    if [ "$status" != "deprecated" ] && [ $ahead_count -gt 0 ]; then
        if is_likely_squash_merged "$branch"; then
            if [ -n "$reasons" ]; then
                reasons="$reasons, likely squash-merged"
            else
                reasons="likely squash-merged"
            fi
            status="deprecated"
        fi
    fi
    
    # Store branch info
    if [ -n "$reasons" ]; then
        last_commit=$(git log -1 --pretty=format:"%h %s (%cr by %an)" "$branch" 2>/dev/null || echo "unknown")
        echo "$branch|$reasons|$last_commit" >> "$BRANCH_INFO"
        
        if [ "$status" = "deprecated" ]; then
            echo "$branch" >> "$DEPRECATED_BRANCHES"
        elif [ "$status" = "stale" ]; then
            echo "$branch" >> "$STALE_BRANCHES"
        fi
    fi
    
done <<< "$ALL_BRANCHES"

# Display results
deprecated_count=$(wc -l < "$DEPRECATED_BRANCHES" | tr -d ' ')
stale_count=$(wc -l < "$STALE_BRANCHES" | tr -d ' ')

echo -e "${RED}DEPRECATED BRANCHES:${NC} (safe to delete)"
echo "----------------------------------------"
if [ -s "$DEPRECATED_BRANCHES" ]; then
    while IFS= read -r branch; do
        info=$(grep "^$branch|" "$BRANCH_INFO" | head -1)
        reasons=$(echo "$info" | cut -d'|' -f2)
        last_commit=$(echo "$info" | cut -d'|' -f3)
        echo -e "${YELLOW}$branch${NC}"
        echo -e "  Reasons: $reasons"
        echo -e "  Last commit: $last_commit"
        echo ""
    done < "$DEPRECATED_BRANCHES"
else
    echo -e "${GREEN}No deprecated branches found!${NC}"
    echo ""
fi

echo -e "${BLUE}STALE BRANCHES:${NC} (review before deleting)"
echo "----------------------------------------"
if [ -s "$STALE_BRANCHES" ]; then
    while IFS= read -r branch; do
        info=$(grep "^$branch|" "$BRANCH_INFO" | head -1)
        reasons=$(echo "$info" | cut -d'|' -f2)
        last_commit=$(echo "$info" | cut -d'|' -f3)
        echo -e "${CYAN}$branch${NC}"
        echo -e "  Reasons: $reasons"
        echo -e "  Last commit: $last_commit"
        echo ""
    done < "$STALE_BRANCHES"
else
    echo -e "${GREEN}No stale branches found!${NC}"
    echo ""
fi

# If no branches to clean up, exit
if [ $deprecated_count -eq 0 ] && [ $stale_count -eq 0 ]; then
    exit 0
fi

# Options menu
echo ""
echo -e "${YELLOW}Options:${NC}"
echo "  1 - Delete all DEPRECATED branches (safe)"
echo "  2 - Delete all STALE branches (review recommended)"
echo "  3 - Delete ALL deprecated and stale branches"
echo "  4 - Interactive mode (choose each branch)"
echo "  5 - Dry run (show what would be deleted)"
echo "  q - Quit without deleting"
echo ""

read -p "Choose an option: " choice

# Function to delete a branch
delete_branch() {
    local branch=$1
    local force=$2
    
    # If global FORCE_DELETE is true, always force delete
    if [ "$FORCE_DELETE" = "true" ] || [ "$force" = "true" ]; then
        git branch -D "$branch"
    else
        git branch -d "$branch" 2>/dev/null || {
            echo -e "${YELLOW}Warning: Branch $branch has unmerged changes.${NC}"
            read -p "Force delete? (y/n): " force_delete
            if [ "$force_delete" = "y" ]; then
                git branch -D "$branch"
            else
                echo "Skipped $branch"
                return 1
            fi
        }
    fi
    return 0
}

case $choice in
    1)
        echo ""
        deleted=0
        if [ -s "$DEPRECATED_BRANCHES" ]; then
            while IFS= read -r branch; do
                echo -e "Deleting branch: ${YELLOW}$branch${NC}"
                if delete_branch "$branch" false; then
                    ((deleted++))
                fi
            done < "$DEPRECATED_BRANCHES"
        fi
        echo -e "${GREEN}Deleted $deleted deprecated branches!${NC}"
        ;;
        
    2)
        echo ""
        echo -e "${YELLOW}Review stale branches before deleting:${NC}"
        deleted=0
        if [ -s "$STALE_BRANCHES" ]; then
            while IFS= read -r branch; do
                info=$(grep "^$branch|" "$BRANCH_INFO" | head -1)
                reasons=$(echo "$info" | cut -d'|' -f2)
                last_commit=$(echo "$info" | cut -d'|' -f3)
                
                echo ""
                echo -e "Branch: ${CYAN}$branch${NC}"
                echo -e "Reasons: $reasons"
                echo -e "Last commit: $last_commit"
                read -p "Delete this branch? (y/n/q): " confirm
                
                if [ "$confirm" = "q" ]; then
                    break
                elif [ "$confirm" = "y" ]; then
                    if delete_branch "$branch" false; then
                        ((deleted++))
                    fi
                fi
            done < "$STALE_BRANCHES"
        fi
        echo -e "${GREEN}Deleted $deleted stale branches!${NC}"
        ;;
        
    3)
        echo ""
        echo -e "${RED}WARNING: This will delete all deprecated and stale branches.${NC}"
        read -p "Are you sure? (yes/no): " confirm
        
        if [ "$confirm" = "yes" ]; then
            deleted=0
            cat "$DEPRECATED_BRANCHES" "$STALE_BRANCHES" | while IFS= read -r branch; do
                echo -e "Deleting branch: ${YELLOW}$branch${NC}"
                if delete_branch "$branch" false; then
                    ((deleted++))
                fi
            done
            echo -e "${GREEN}Deleted $deleted branches!${NC}"
        else
            echo "Cancelled."
        fi
        ;;
        
    4)
        echo ""
        deleted=0
        cat "$DEPRECATED_BRANCHES" "$STALE_BRANCHES" | while IFS= read -r branch; do
            info=$(grep "^$branch|" "$BRANCH_INFO" | head -1)
            reasons=$(echo "$info" | cut -d'|' -f2)
            last_commit=$(echo "$info" | cut -d'|' -f3)
            
            # Determine status
            if grep -q "^$branch$" "$DEPRECATED_BRANCHES"; then
                status="deprecated"
            else
                status="stale"
            fi
            
            echo ""
            echo -e "Branch: ${YELLOW}$branch${NC} ($status)"
            echo -e "Reasons: $reasons"
            echo -e "Last commit: $last_commit"
            read -p "Delete this branch? (y/n/q): " confirm
            
            if [ "$confirm" = "q" ]; then
                break
            elif [ "$confirm" = "y" ]; then
                if delete_branch "$branch" false; then
                    ((deleted++))
                fi
            fi
        done
        echo -e "${GREEN}Deleted $deleted branches!${NC}"
        ;;
        
    5)
        echo ""
        echo -e "${MAGENTA}DRY RUN - No branches will be deleted${NC}"
        echo ""
        echo "Would delete the following branches:"
        cat "$DEPRECATED_BRANCHES" "$STALE_BRANCHES" | while IFS= read -r branch; do
            info=$(grep "^$branch|" "$BRANCH_INFO" | head -1)
            reasons=$(echo "$info" | cut -d'|' -f2)
            
            # Determine status
            if grep -q "^$branch$" "$DEPRECATED_BRANCHES"; then
                status="deprecated"
            else
                status="stale"
            fi
            
            echo -e "  ${YELLOW}$branch${NC} ($status)"
            echo -e "    $reasons"
        done
        ;;
        
    q|Q)
        echo "Exiting without changes."
        exit 0
        ;;
        
    *)
        echo -e "${RED}Invalid option. Exiting.${NC}"
        exit 1
        ;;
esac

# Show remaining branches
echo ""
echo "Remaining local branches:"
git branch | sed 's/^[[:space:]]*/  /'