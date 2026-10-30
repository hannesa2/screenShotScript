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

if [ -z "${CLASSIC_TOKEN}" ]; then
   echo "\e[31m!! You must provide CLASSIC_TOKEN environment variable.\e[0m Otherwise screenshot compare doesn't work properly"
fi

# Uploads $1 to GitHub's own attachment hosting (the same endpoint the web UI
# uses to host images dropped into issue/PR comments) and echoes the resulting
# https://github.com/user-attachments/... URL on success. This needs CLASSIC_TOKEN
# (a classic PAT): the Actions-provided GITHUB_TOKEN (a GitHub App installation
# token) gets a plain 404 from this endpoint, so a privately-run upload server
# is no longer needed, but a PAT still is.
# The HTTP status is appended on its own trailing line (-w) instead of
# relying on curl's exit code, so a failure response - whose body is GitHub's
# actual error message - gets logged instead of silently discarded.
# Query parameters are URL-encoded and appended to the URL manually (via jq's
# @uri filter) instead of using curl's --url-query, which needs curl >= 7.87.
# This keeps the script working on older runners (e.g. Ubuntu 22.04 ships
# curl 7.81.0) since this script is reused across repos/pipelines we don't
# control the runner image for.
upload_to_github() {
  local file="$1"
  local name="$2"
  local response http_status body url uploadFile uploadName contentType fileSize maxUploadBytes
  local encodedName encodedContentType encodedRepoId tempFile tempImage converter scale
  uploadFile="$file"
  uploadName="$name"
  contentType="image/png"
  maxUploadBytes=9500000

  # GitHub's attachment endpoint rejects anything >= 10MB. git-diff-image's
  # triptych (old | diff | new) comparison images can exceed that, even
  # though the individual screenshots never do. Re-encode oversized images as
  # JPEG (shrinking further if needed) only for the upload; the original PNG
  # used for the diff comparison and archived artifacts is left untouched.
  fileSize=$(wc -c < "$file" | tr -d '[:space:]')
  if [ "$fileSize" -ge "$maxUploadBytes" ]; then
    if command -v magick >/dev/null 2>&1; then
      converter=magick
    elif command -v convert >/dev/null 2>&1; then
      converter=convert
    else
      echo "!! ImageMagick is required to compress screenshots larger than 9.5 MB" >&2
      return 1
    fi

    if ! tempFile=$(mktemp "${TMPDIR:-/tmp}/raspicar-screenshot.XXXXXX"); then
      echo "!! Could not create a temporary file to compress $file" >&2
      return 1
    fi
    tempImage="${tempFile}.jpg"
    scale=100
    while [ "$scale" -ge 10 ]; do
      if ! "$converter" "$file" -background white -alpha remove -alpha off \
        -strip -resize "${scale}%" -quality 85 "$tempImage"; then
        rm -f "$tempFile" "$tempImage"
        echo "!! Failed to compress screenshot $file" >&2
        return 1
      fi
      fileSize=$(wc -c < "$tempImage" | tr -d '[:space:]')
      if [ "$fileSize" -lt "$maxUploadBytes" ]; then
        break
      fi
      scale=$((scale - 10))
    done
    if [ "$fileSize" -ge "$maxUploadBytes" ]; then
      rm -f "$tempFile" "$tempImage"
      echo "!! Compressed screenshot is still too large to upload: $fileSize bytes" >&2
      return 1
    fi

    uploadFile="$tempImage"
    uploadName="${name%.*}.jpg"
    contentType="image/jpeg"
    echo "==> Compressed $name from $(wc -c < "$file" | tr -d '[:space:]') to $fileSize bytes" >&2
  fi

  encodedName=$(jq -rn --arg v "$uploadName" '$v|@uri')
  encodedContentType=$(jq -rn --arg v "$contentType" '$v|@uri')
  encodedRepoId=$(jq -rn --arg v "$repoId" '$v|@uri')
  if ! response=$(curl -sS -w '\n%{http_code}' -X POST \
    "https://uploads.github.com/user-attachments/assets?name=${encodedName}&content_type=${encodedContentType}&repository_id=${encodedRepoId}" \
    -H "Content-Type: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: token $CLASSIC_TOKEN" \
    --data-binary "@$uploadFile"); then
    if [ -n "$tempImage" ]; then
      rm -f "$tempFile" "$tempImage"
    fi
    echo "!! GitHub screenshot upload request failed for $uploadName" >&2
    return 1
  fi
  if [ -n "$tempImage" ]; then
    rm -f "$tempFile" "$tempImage"
  fi
  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$http_status" != "200" ] && [ "$http_status" != "201" ]; then
    echo "!! upload failed for $file: http_status=$http_status" >&2
    echo "$body" >&2
    return 1
  fi
  url=$(printf '%s' "$body" | jq -r .url)
  case "$url" in
    https://*) printf '%s' "$url" ;;
    *) echo "!! upload failed for $file: unexpected response body: $body" >&2; return 1 ;;
  esac
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
  repoId=$(curl_gh -X GET https://api.github.com/repos/"$GITHUB_REPOSITORY" | jq -r .id)
  echo "repoId=$repoId"

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
      echo "==> Uploading #$COUNTER screenshot=$newName"
      if ! uploadUrl=$(upload_to_github "$newName" "$newName"); then
        body="$body ${f} Upload failed <br/><br/>"
        continue
      fi
      echo "==> Screenshot upload successful for $newName -> $uploadUrl"
      echo "==> Add screenshot commentLine PR=$PR"
      body="$body ${f}![screenshot]($uploadUrl) <br/><br/>"
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
      echo "==> Uploading #$COUNTER new screenshot=$newName"
      if ! uploadUrl=$(upload_to_github "$newName" "$newName"); then
        body="$body ${relPath} (new) Upload failed <br/><br/>"
        continue
      fi
      echo "==> New screenshot upload successful for $newName -> $uploadUrl"
      echo "==> Add new screenshot commentLine PR=$PR"
      body="$body ${relPath} (new screenshot)<br/>![screenshot]($uploadUrl) <br/><br/>"
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
      echo "==> Uploading #$COUNTER screenshot=$newName"
      if ! uploadUrl=$(upload_to_github "$newName" "$newName"); then
        body="$body ${f} (error) Upload failed <br/><br/>"
        continue
      fi
      echo "==> Add error screenshot commentLine PR=$PR"
      body="$body <br/>${f}<br/>![screenshot]($uploadUrl) <br/><br/>"
    done <<< "$errorFiles"
  else
    echo "no error png found"
  fi

  if [ ! "$body" == "" ]; then
    echo "==> Post commentLine to $PR"
    echo "==> body=$body"
    if [ -z "${CLASSIC_TOKEN}" ]; then
       echo "!! You must provide a \e[31mCLASSIC_TOKEN\e[0m environment variable. Exiting...."
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
