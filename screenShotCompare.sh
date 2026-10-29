#!/bin/zsh
set -eo pipefail # automatic. fails on any error

# Optional parameter: forceFail (default: true)
# Usage: ./screenShotCompare.sh [true|false]
forceFail="${1:-true}"

# Percentage of ImageMagick fuzz applied to every screenshot comparison, not just JPEGs
# (which git-diff-image defaults to 5% on its own). Screenshots are PNGs and otherwise get 0% fuzz, so harmless per-run
# rendering noise is flagged as a difference just as loudly as a real regression.
# Override by exporting SCREENSHOT_COMPARE_FUZZ before calling this script.
screenshotCompareFuzz="${SCREENSHOT_COMPARE_FUZZ:-5}"

OS="`uname`"
case $OS in
  'Linux')
    echo "Fix display on Linux"
    export DISPLAY=:99
    sudo Xvfb -ac :99 -screen 0 1280x1024x24 > /dev/null 2>&1 &
    ;;
  'FreeBSD')
    ;;
  'WindowsNT')
    ;;
  'Darwin')
    #brew install jq | echo "Nothing to do with brew"
    ;;
  'SunOS')
    ;;
  'AIX') ;;
  *) ;;
esac

diffFiles=./screenshotDiffs
rm -rf $diffFiles || echo "Nothing to do with rm -rf $diffFiles"
mkdir $diffFiles

./git-diff-image/install.sh
echo "==> Run git diff-image with output dir $diffFiles and fuzz $screenshotCompareFuzz%"
if [ -n "$DEBUG_INFO" ]; then
  set -x
  GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles GIT_DIFF_IMAGE_FUZZ=$screenshotCompareFuzz git diff-image
  set +x
else
  GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles GIT_DIFF_IMAGE_FUZZ=$screenshotCompareFuzz git diff-image
fi

pwd
source $(dirname $0)/lib.sh

echo "GITHUB_REF_NAME=$GITHUB_REF_NAME"
echo $(echo "$GITHUB_REF_NAME" | sed "s/\// /")
PR=$(echo "$GITHUB_REF_NAME" | sed "s/\// /" | awk '{print $1}')
echo "PR=$PR GITHUB_REF_NAME=$GITHUB_REF_NAME"

if [ -z "${GITHUB_TOKEN}" ]; then
   echo "\e[31m!! You must provide GITHUB_TOKEN environment variable.\e[0m Otherwise screenshot compare doesn't work properly"
fi

# Screenshots are hosted by committing them to a dedicated, history-less
# branch (default: screenshot-assets) and embedding the resulting
# https://raw.githubusercontent.com/... URL. Unlike the
# uploads.github.com/user-attachments/assets API (which rejects the
# Actions-provided GITHUB_TOKEN, a GitHub App installation token, with a 404),
# a plain `git push` only cares whether the token is allowed to write, so the
# default GITHUB_TOKEN works fine here and no classic PAT is needed any more.
assetsBranch="${SCREENSHOT_ASSETS_BRANCH:-screenshot-assets}"
assetsWorkDir=""
assetsReady=false
assetsChanged=false

# Clones (or creates) the assets branch into a scratch worktree, isolated
# from the actual checkout this script runs in. Called lazily on the first
# screenshot so a run with nothing to upload never touches the branch.
init_assets_branch() {
  assetsWorkDir=$(mktemp -d)
  git -C "$assetsWorkDir" init --quiet
  git -C "$assetsWorkDir" remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git -C "$assetsWorkDir" config user.name "github-actions[bot]"
  git -C "$assetsWorkDir" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  if git -C "$assetsWorkDir" fetch --quiet --depth 1 origin "$assetsBranch" 2>/dev/null; then
    git -C "$assetsWorkDir" checkout --quiet -b "$assetsBranch" FETCH_HEAD
  else
    echo "==> Branch $assetsBranch does not exist yet on origin, creating it"
    git -C "$assetsWorkDir" checkout --quiet --orphan "$assetsBranch"
  fi
  # Each run replaces the previous screenshots for this PR, so the branch
  # doesn't grow unbounded while a PR gets pushed to repeatedly.
  rm -rf "${assetsWorkDir:?}/pr-$PR"
  assetsReady=true
}

# Copies $1 into the assets worktree under pr-$PR/$2 and sets $stagedUrl to
# the raw URL it will be reachable at once pushed. The actual commit+push
# happens once, after every screenshot of this run has been staged (see
# below), so a single push failure is reported once instead of once per
# file. Must be called directly (not via `$(...)`) so assetsWorkDir and
# friends, set as a side effect, stay visible in the caller's shell instead
# of being thrown away with a subshell.
stage_screenshot() {
  local file="$1"
  local name="$2"
  if [ "$assetsReady" != "true" ]; then
    init_assets_branch
  fi
  mkdir -p "$assetsWorkDir/pr-$PR"
  cp "$file" "$assetsWorkDir/pr-$PR/$name"
  assetsChanged=true
  stagedUrl="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${assetsBranch}/pr-${PR}/${name}"
}

# Commits and pushes everything staged by stage_screenshot. On a push
# conflict (e.g. a concurrent run for the same PR) it fetches and rebases
# once before giving up, since the assets branch is otherwise only ever
# fast-forwarded.
push_assets_branch() {
  git -C "$assetsWorkDir" add -A
  git -C "$assetsWorkDir" commit --quiet -m "Screenshots for PR #$PR ($emulatorApi)"
  if git -C "$assetsWorkDir" push --quiet origin "HEAD:$assetsBranch" 2>/dev/null; then
    return 0
  fi
  echo "==> Push to $assetsBranch rejected, fetching and rebasing once before retrying" >&2
  git -C "$assetsWorkDir" fetch --quiet origin "$assetsBranch" \
    && git -C "$assetsWorkDir" rebase --quiet "origin/$assetsBranch" \
    && git -C "$assetsWorkDir" push --quiet origin "HEAD:$assetsBranch"
}

echo "==> Delete all old comments, starting with 'Screenshot differs:"
oldCommentsJson=$(curl_gh -X GET https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/"$PR"/comments)
if [ -n "$DEBUG_INFO" ]; then
  echo "DEBUG_INFO is set and not empty"
  printf '%s\n' "$oldCommentsJson"
else
  echo "DEBUG_INFO is unset or empty"
fi

if [ "$PR" = "master" ]; then
  echo "PR is master, nothing to upload"
  oldCommentsList=""
else
  # the last echo fixes a merge to master, because then no such comments exists
  oldCommentsList=$(printf '%s' "$oldCommentsJson" | jq '.[] | (.id |tostring) + "|" + (.body | test("Screenshot differs:.*") | tostring)' || echo "")
  echo "oldCommentsList=$oldCommentsList"
  oldCommentsList=$(echo $oldCommentsList | grep true || echo "") # filter lines containing true
  echo "oldCommentsList=$oldCommentsList"
  if [ -z "$oldCommentsList" ]
  then
    echo "==> oldCommentsList is empty, there is nothing to do"
  else
    oldCommentsFiltered=$(echo $oldCommentsList | grep "|true" | tr -d "\"" | cut -f1 -d"|")
    echo "oldCommentsFiltered=$oldCommentsFiltered"
    echo "$oldCommentsFiltered" | while read commentLine; do
      if [ -z "$commentLine" ]
      then
        # commentLine is empty
        echo "==> old commentLine is empty, there is nothing to do"
      else
        # commentLine is not empty
        echo "==> delete commentLine=$commentLine"
        curl_gh -X DELETE https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/comments/"$commentLine"
      fi
    done
  fi

  pushd $diffFiles
  pwd
  body=""
  COUNTER=0
  pendingSuccess=()
  pendingFailure=()
  ls -la

  # https://unix.stackexchange.com/a/723909/201876
  echo "==> Loop on *.png and ignore an error, when no files where found"
  setopt no_nomatch
  for f in *.png; do
    if [[ ${f} == "*.png" ]]
    then
      echo "nothing found"
    else
      (( COUNTER++ )) || echo "Nothing to do with COUNTER++ it's now $COUNTER"

      newName="${GITHUB_REPOSITORY//\//-}-pr${PR}-${emulatorApi}-${f}"
      mv "${f}" "$newName"
      echo "==> Staging #$COUNTER screenshot=$newName"
      if ! stage_screenshot "$newName" "$newName"; then
        body="$body ${f} Upload failed <br/><br/>"
        continue
      fi
      pendingSuccess+=("${f}![screenshot]($stagedUrl) <br/><br/>")
      pendingFailure+=("${f} Upload failed <br/><br/>")
    fi
  done

  echo "==> Search for new untracked screenshots in $(pwd)"
  newFilesList=$(git -C .. ls-files --others --exclude-standard \
    -- 'scripts/*Screenshots*/**/*.png' 'scripts/*Screenshots*/*.png' \
       'scripts/*screenshots*/**/*.png' 'scripts/*screenshots*/*.png' \
       'screenshots*/**/*.png' 'screenshots*/*.png' \
       'Screenshots*/**/*.png' 'Screenshots*/*.png' \
       ":!${diffFiles#./}/**" ':!*baseline-screenshots*/**' ':!*view-op-error*' 2>/dev/null || true)
  if [ -n "$newFilesList" ]; then
    while IFS= read -r relPath; do
      if [ -z "$relPath" ]; then
        continue
      fi
      safeName="${relPath//\//-}"
      echo "Found new screenshot '$relPath'"
      (( COUNTER++ )) || echo "Nothing to do with COUNTER++ it's now $COUNTER"

      newName="${GITHUB_REPOSITORY//\//-}-pr${PR}-${emulatorApi}-${safeName}"
      cp "../$relPath" "$newName"
      echo "==> Staging #$COUNTER new screenshot=$newName"
      if ! stage_screenshot "$newName" "$newName"; then
        body="$body ${relPath} (new) Upload failed <br/><br/>"
        continue
      fi
      pendingSuccess+=("${relPath} (new screenshot)<br/>![screenshot]($stagedUrl) <br/><br/>")
      pendingFailure+=("${relPath} (new) Upload failed <br/><br/>")
    done <<< "$newFilesList"
  else
    echo "no new untracked screenshots found"
  fi

  echo "==> Search for error screenshots in $(pwd)"
  errorFiles=$(find .. -name "view-op-error-*.png" 2>/dev/null || true)
  if [ -n "$errorFiles" ]; then
    while IFS= read -r f; do
      if [ -z "$f" ]; then
        continue
      fi
      echo "Found '$f'"
      (( COUNTER++ )) || echo "Nothing to do with COUNTER++ it's now $COUNTER"

      newName="$(date +%s).png"
      mv "${f}" "$newName"
      echo "==> Staging #$COUNTER screenshot=$newName"
      if ! stage_screenshot "$newName" "$newName"; then
        body="$body ${f} (error) Upload failed <br/><br/>"
        continue
      fi
      pendingSuccess+=("<br/>${f}<br/>![screenshot]($stagedUrl) <br/><br/>")
      pendingFailure+=("${f} (error) Upload failed <br/><br/>")
    done <<< "$errorFiles"
  else
    echo "no error png found"
  fi

  if [ "$assetsChanged" = "true" ]; then
    echo "==> Pushing screenshots to $assetsBranch"
    if push_assets_branch; then
      echo "==> Pushed screenshots to $assetsBranch"
      for entry in "${pendingSuccess[@]}"; do
        body="$body $entry"
      done
    else
      echo "!! Failed to push screenshots to $assetsBranch" >&2
      for entry in "${pendingFailure[@]}"; do
        body="$body $entry"
      done
    fi
    rm -rf "$assetsWorkDir"
  fi

  if [ ! "$body" == "" ]; then
    echo "==> Post commentLine to $PR"
    echo "==> body=$body"
    if [ -z "${GITHUB_TOKEN}" ]; then
       echo "!! You must provide a \e[31mGITHUB_TOKEN\e[0m environment variable. Exiting...."
       exit 1
    fi
    curl_gh -X POST https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/$PR/comments -d "{ \"body\" : \"Screenshot differs: emulatorApi=$emulatorApi with $COUNTER screenshot(s)<br/><br/>setpoint (old) | diff | actual screenshot (new)<br/><br/> $body \" }"
  fi

  popd 1>/dev/null
fi

# set error when diffs are there
echo ""
if [ "$(ls -A $diffFiles)" ]; then
  echo "==> Diff files exist"
  if [ "$forceFail" = "true" ]; then
    echo "==> Force error on diff files exists (forceFail=$forceFail)"
    exit 1
  else
    echo "==> Not forcing error (forceFail=$forceFail)"
    exit 0
  fi
else
  echo "==> all is fine"
  exit 0
fi
