#!/bin/bash

# Script to clean up local branches that have been merged into main
# This script will:
# 1. Fetch latest changes from remote
# 2. List branches that have been merged into main
# 3. Prompt for confirmation before deleting
# 4. Delete the selected branches

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Git Branch Cleanup Tool${NC}"
echo "========================"
echo ""

# Ensure we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: Not in a git repository${NC}"
    exit 1
fi

# Get the main branch name (could be 'main' or 'master')
MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

echo -e "Using ${YELLOW}$MAIN_BRANCH${NC} as the main branch"
echo ""

# Fetch latest changes
echo "Fetching latest changes from remote..."
git fetch --prune

# Switch to main branch and pull latest
echo "Switching to $MAIN_BRANCH and pulling latest..."
git checkout $MAIN_BRANCH
git pull

echo ""
echo "Finding merged branches..."
echo ""

# Get list of branches that have been merged into main (excluding main itself)
MERGED_BRANCHES=$(git branch --merged $MAIN_BRANCH | grep -v "^\*" | grep -v " $MAIN_BRANCH$" | sed 's/^[[:space:]]*//')

if [ -z "$MERGED_BRANCHES" ]; then
    echo -e "${GREEN}No merged branches found to clean up!${NC}"
    exit 0
fi

# Count branches
BRANCH_COUNT=$(echo "$MERGED_BRANCHES" | wc -l | tr -d ' ')

echo -e "Found ${YELLOW}$BRANCH_COUNT${NC} branches that have been merged into $MAIN_BRANCH:"
echo ""

# Display branches with numbers
i=1
while IFS= read -r branch; do
    # Check if branch exists on remote
    if git ls-remote --heads origin "$branch" | grep -q .; then
        echo -e "  $i. $branch ${YELLOW}(still on remote)${NC}"
    else
        echo -e "  $i. $branch ${GREEN}(local only)${NC}"
    fi
    ((i++))
done <<< "$MERGED_BRANCHES"

echo ""
echo -e "${YELLOW}Options:${NC}"
echo "  a - Delete ALL merged branches"
echo "  s - Select specific branches to delete"
echo "  l - List branches with their last commit info"
echo "  q - Quit without deleting"
echo ""

read -p "Choose an option: " choice

case $choice in
    a|A)
        echo ""
        echo -e "${RED}WARNING: This will delete all $BRANCH_COUNT merged branches listed above.${NC}"
        read -p "Are you sure? (yes/no): " confirm
        
        if [ "$confirm" = "yes" ]; then
            echo ""
            while IFS= read -r branch; do
                echo -e "Deleting branch: ${YELLOW}$branch${NC}"
                git branch -d "$branch"
            done <<< "$MERGED_BRANCHES"
            echo ""
            echo -e "${GREEN}Successfully deleted $BRANCH_COUNT branches!${NC}"
        else
            echo "Cancelled."
        fi
        ;;
        
    s|S)
        echo ""
        echo "Enter the numbers of branches to delete (space-separated), or 'c' to cancel:"
        read -p "> " selections
        
        if [ "$selections" = "c" ]; then
            echo "Cancelled."
            exit 0
        fi
        
        # Convert branch list to array
        branches=()
        while IFS= read -r branch; do
            branches+=("$branch")
        done <<< "$MERGED_BRANCHES"
        
        # Delete selected branches
        deleted=0
        for num in $selections; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#branches[@]}" ]; then
                branch="${branches[$((num-1))]}"
                echo -e "Deleting branch: ${YELLOW}$branch${NC}"
                git branch -d "$branch"
                ((deleted++))
            else
                echo -e "${RED}Invalid selection: $num${NC}"
            fi
        done
        
        if [ $deleted -gt 0 ]; then
            echo ""
            echo -e "${GREEN}Successfully deleted $deleted branches!${NC}"
        fi
        ;;
        
    l|L)
        echo ""
        echo "Detailed branch information:"
        echo ""
        while IFS= read -r branch; do
            last_commit=$(git log -1 --pretty=format:"%h %s (%cr by %an)" "$branch")
            echo -e "${YELLOW}$branch${NC}"
            echo "  Last commit: $last_commit"
            echo ""
        done <<< "$MERGED_BRANCHES"
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
git branch | grep -v "^\*" | sed 's/^[[:space:]]*/  /'