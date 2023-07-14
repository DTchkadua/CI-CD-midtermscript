#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
  set -o xtrace
fi

# Check if GITHUB_PERSONAL_ACCESS_TOKEN is set
: "${GITHUB_PERSONAL_ACCESS_TOKEN:?GITHUB_PERSONAL_ACCESS_TOKEN environment variable is missing}"

# Check the number of arguments provided
if [[ $# -ne 4 ]]; then
  echo "The script was not provided with four arguments."
  echo "Usage: ./mid-term.sh CODE_REPO_URL CODE_BRANCH_NAME REPORT_REPO_URL REPORT_BRANCH_NAME"
  exit 1
fi

CODE_REPO_URL="$1"
CODE_BRANCH_NAME="$2"
REPORT_REPO_URL="$3"
REPORT_BRANCH_NAME="$4"

REPOSITORY_NAME_CODE=$(basename "$CODE_REPO_URL" .git)
REPOSITORY_OWNER=$(echo "$CODE_REPO_URL" | awk -F':' '{print $2}' | awk -F'/' '{print $1}')
REPOSITORY_NAME_REPORT=$(basename "$REPORT_REPO_URL" .git)
REPOSITORY_PATH_CODE=$(mktemp --directory)
REPOSITORY_PATH_REPORT=$(mktemp --directory)

PYTEST_RESULT=0
BLACK_RESULT=0

# Function to cleanup temporary files and directories
cleanup() {
  echo "Cleaning up..."
  rm -rf "$REPOSITORY_PATH_CODE" "$REPOSITORY_PATH_REPORT" "$PYTEST_REPORT_PATH" "$BLACK_REPORT_PATH" "$BLACK_OUTPUT_PATH"
}

trap cleanup INT EXIT ERR SIGINT SIGTERM

# Helper function to make a GET request to GitHub API
github_api_get_request() {
  curl --request GET \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --output "$2" \
    --silent \
    "$1"
}

# Helper function to make a POST request to GitHub API
github_post_request() {
  curl --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --header "Content-Type: application/json" \
    --silent \
    --output "$3" \
    --data-binary "@$2" \
    "$1"
}

# Helper function to update JSON using jq
jq_update() {
  local IO_PATH="$1"
  local TEMP_PATH=$(mktemp)
  shift
  jq "$@" "$IO_PATH" > "$TEMP_PATH" && mv "$TEMP_PATH" "$IO_PATH"
}

# Validate code repository existence and branch
validate_repository_branch() {
  local repo_url="$1"
  local branch_name="$2"

  if ! git ls-remote --exit-code "$repo_url" &> /dev/null; then
    echo "Repository does not exist: $repo_url"
    exit 1
  fi

  if ! git ls-remote --exit-code --heads "$repo_url" "$branch_name" &> /dev/null; then
    echo "Branch '$branch_name' does not exist in repository: $repo_url"
    exit 1
  fi
}

# Check if required commands are installed
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

if ! command_exists pytest; then
  echo "pytest is not installed"
  exit 1
fi

if ! command_exists black; then
  echo "black is not installed"
  exit 1
fi

# Clone code repository and initialize Git repository
git clone "$CODE_REPO_URL" "$REPOSITORY_PATH_CODE"
cd "$REPOSITORY_PATH_CODE"
git init
git switch "$CODE_BRANCH_NAME"

LAST_COMMIT=""
PYTEST_REPORT_PATH=""
BLACK_OUTPUT_PATH=""
BLACK_REPORT_PATH=""

# Loop continuously to monitor for new commits
while true; do
  git fetch "$CODE_REPO_URL" "$CODE_BRANCH_NAME" > /dev/null 2>&1
  CHECK_COMMIT=$(git rev-parse FETCH_HEAD)

  if [[ "$CHECK_COMMIT" != "$LAST_COMMIT" ]]; then
    COMMITS=$(git log --pretty=format:"%H" --reverse "$LAST_COMMIT".."$CHECK_COMMIT")
    LAST_COMMIT=$CHECK_COMMIT

    for COMMIT in $COMMITS; do
      PYTEST_REPORT_PATH=$(mktemp)
      BLACK_OUTPUT_PATH=$(mktemp)
      BLACK_REPORT_PATH=$(mktemp)

      git checkout "$COMMIT"
      AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)

      if pytest --verbose --html="$REPOSITORY_PATH_CODE/$PYTEST_REPORT_PATH" --self-contained-html; then
        PYTEST_RESULT=$?
        echo "PYTEST SUCCEEDED $PYTEST_RESULT"
      else
        PYTEST_RESULT=$?
        echo "PYTEST FAILED $PYTEST_RESULT"
      fi

      echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"

      if black --check --diff . > "$REPOSITORY_PATH_CODE/$BLACK_OUTPUT_PATH"; then
        BLACK_RESULT=$?
        echo "BLACK SUCCEEDED $BLACK_RESULT"
      else
        BLACK_RESULT=$?
        echo "BLACK FAILED $BLACK_RESULT"
        cat "$REPOSITORY_PATH_CODE/$BLACK_OUTPUT_PATH" | pygmentize -l diff -f html -O full,style=solarized-light -o "$REPOSITORY_PATH_CODE/$BLACK_REPORT_PATH"
      fi

      echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"
      if  [ "$(ls -A "$REPOSITORY_PATH_REPORT")" ]; then
                echo "Directory $REPOSITORY_PATH_REPORT exists and is not empty. Skipping cloning."
            else
                git clone "$REPORT_REPO_URL" "$REPOSITORY_PATH_REPORT"
            fi

      pushd "$REPOSITORY_PATH_REPORT"
      git switch "$REPORT_BRANCH_NAME"
      REPORT_PATH="${COMMIT}-$(date +%s)"
      mkdir -p "$REPORT_PATH"
      cp "$REPOSITORY_PATH_CODE/$PYTEST_REPORT_PATH" "$REPORT_PATH/pytest.html"

      if [[ -s "$REPOSITORY_PATH_CODE/$BLACK_REPORT_PATH" ]]; then
        cp "$REPOSITORY_PATH_CODE/$BLACK_REPORT_PATH" "$REPORT_PATH/black.html"
      fi

      git add "$REPORT_PATH"
      git commit -m "$COMMIT report."
      git push
      popd

      if ((PYTEST_RESULT != 0 || BLACK_RESULT != 0)); then
        AUTHOR_USERNAME=""
        RESPONSE_PATH=$(mktemp)
        github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" "$RESPONSE_PATH"

        TOTAL_USER_COUNT=$(jq -r '.total_count' "$RESPONSE_PATH")

        if [[ $TOTAL_USER_COUNT == 1 ]]; then
          USER_JSON=$(jq '.items[0]' "$RESPONSE_PATH")
          AUTHOR_USERNAME=$(jq -r '.items[0].login' "$RESPONSE_PATH")
        fi

        REQUEST_PATH=$(mktemp)
        RESPONSE_PATH=$(mktemp)
        echo "{}" > "$REQUEST_PATH"

        BODY+="Automatically generated message
"

        if ((PYTEST_RESULT != 0)); then
          if ((BLACK_RESULT != 0)); then
            if [[ "$PYTEST_RESULT" -eq "5" ]]; then
              TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test failed."
              BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test failed.
"
            else
              TITLE="${COMMIT::7} failed unit and formatting tests."
              BODY+="${COMMIT} failed unit and formatting tests.
"
              jq_update "$REQUEST_PATH" '.labels = ["ci-pytest", "ci-black"]'
            fi
          else
            if [[ "$PYTEST_RESULT" -eq "5" ]]; then
              TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test passed."
              BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test passed.
"
            else
              TITLE="${COMMIT::7} failed unit tests."
              BODY+="${COMMIT} failed unit tests.
"
              jq_update "$REQUEST_PATH" '.labels = ["ci-pytest"]'
            fi
          fi
        else
          TITLE="${COMMIT::7} failed formatting test."
          BODY+="${COMMIT} failed formatting test.
"
          jq_update "$REQUEST_PATH" '.labels = ["ci-black"]'
        fi

        BODY+="Pytest report: https://${REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/pytest.html
"

        if [[ -s "$REPOSITORY_PATH_CODE/$BLACK_REPORT_PATH" ]]; then
          BODY+="Black report: https://${REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/black.html
"
        fi

        jq_update "$REQUEST_PATH" --arg title "$TITLE" '.title = $title'
        jq_update "$REQUEST_PATH" --arg body "$BODY" '.body = $body'

        if [[ -n $AUTHOR_USERNAME ]]; then
          jq_update "$REQUEST_PATH" --arg username "$AUTHOR_USERNAME" '.assignees = [$username]'
        fi

        github_post_request "https://api.github.com/repos/${REPOSITORY_OWNER}/${REPOSITORY_NAME_CODE}/issues" "$REQUEST_PATH" "$RESPONSE_PATH"

        cat "$RESPONSE_PATH" | jq -r ".html_url"
        rm "$RESPONSE_PATH" "$REQUEST_PATH"
        BODY=""

        rm -rf "$PYTEST_REPORT_PATH" "$BLACK_OUTPUT_PATH" "$BLACK_REPORT_PATH" "$REPORT_PATH"
      else
        REMOTE_NAME=$(git remote)
        git tag --force "${CODE_BRANCH_NAME}-ci-success" "$COMMIT"
        git push --force "$REMOTE_NAME" --tags
      fi
    done
  fi

  sleep 15
done
