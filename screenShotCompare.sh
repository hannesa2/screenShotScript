#!/bin/zsh
set -eo pipefail # automatic. fails on any error

# Optional parameter: forceFail (default: true)
# Usage: ./screenShotCompare.sh [true|false]
# Paparazzi mode: ./screenShotCompare.sh --paparazzi <build-dir> <snapshots-dir> [forceFail]
# iOS mode: ./screenShotCompare.sh --ios <screenshots-dir> [forceFail]
# Combined mode: ./screenShotCompare.sh --combined <build-dir> <snapshots-dir> <ios-dir> [forceFail]
paparazziMode=false
iosMode=false
if [[ "${1:-}" == "--combined" ]]; then
  paparazziMode=true
  iosMode=true
  paparazziBuildDir="${2:?Missing Paparazzi build directory}"
  paparazziSnapshotsDir="${3:?Missing Paparazzi snapshots directory}"
  iosScreenshotsDir="${4:?Missing iOS screenshot directory}"
  forceFail="${5:-false}"
  screenshotCompareLabel="Android and iOS"
  screenshotPlatform="all"
  screenshotCompareTag="combined"
elif [[ "${1:-}" == "--paparazzi" ]]; then
  paparazziMode=true
  paparazziBuildDir="${2:?Usage: screenShotCompare.sh --paparazzi <build-dir> <snapshots-dir> [forceFail]}"
  paparazziSnapshotsDir="${3:?Usage: screenShotCompare.sh --paparazzi <build-dir> <snapshots-dir> [forceFail]}"
  forceFail="${4:-false}"
  screenshotCompareLabel="Paparazzi"
  screenshotPlatform="android"
  screenshotCompareTag="paparazzi"
elif [[ "${1:-}" == "--ios" ]]; then
  iosMode=true
  iosScreenshotsDir="${2:?Usage: screenShotCompare.sh --ios <screenshots-dir> [forceFail]}"
  forceFail="${3:-false}"
  screenshotCompareLabel="iOS"
  screenshotPlatform="ios"
  screenshotCompareTag="ios"
else
  forceFail="${1:-true}"
  screenshotCompareLabel="emulatorApi=$emulatorApi"
  screenshotPlatform="android"
  screenshotCompareTag="$emulatorApi"
fi
screenshotCommentMarker="<!-- screenshot-compare:$screenshotPlatform -->"

# Percentage of ImageMagick fuzz applied to every screenshot comparison, not just JPEGs
# (which git-diff-image defaults to 5% on its own). Screenshots are PNGs and otherwise get 0% fuzz, so harmless per-run
# rendering noise is flagged as a difference just as loudly as a real regression.
# Override by exporting SCREENSHOT_COMPARE_FUZZ before calling this script.
screenshotCompareFuzz="${SCREENSHOT_COMPARE_FUZZ:-5}"

OS="`uname`"
case $OS in
  'Linux')
    if [[ "$paparazziMode" == false && "$iosMode" == false ]]; then
      echo "Fix display on Linux"
      export DISPLAY=:99
      sudo Xvfb -ac :99 -screen 0 1280x1024x24 > /dev/null 2>&1 &
    fi
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

if [[ "$paparazziMode" == true ]]; then
  setopt no_nomatch
  failuresDir="$paparazziBuildDir/paparazzi/failures"
  echo "==> Collect Paparazzi failures from $failuresDir"
  if [[ -d "$failuresDir" ]]; then
    for diff in "$failuresDir"/delta-*.png; do
      [[ -f "$diff" ]] || continue
      fqcn="${diff:t}"
      fqcn="${fqcn#delta-}"
      fqcn="${fqcn%.png}"
      actual="$failuresDir/$fqcn.png"
      [[ -f "$actual" ]] || continue

      cp "$actual" "$diffFiles/$fqcn-actual.png"
      cp "$diff" "$diffFiles/$fqcn-diff.png"
      expected="$paparazziSnapshotsDir/images/$fqcn.png"
      if [[ -f "$expected" ]]; then
        cp "$expected" "$diffFiles/$fqcn-expected.png"
      fi
    done
  fi
fi
if [[ "$iosMode" == true ]]; then
  resultFile="$iosScreenshotsDir/result.json"
  echo "==> Collect iOS screenshot failures from $resultFile"
  if [[ "$screenshotPlatform" == "all" && ! -f "$resultFile" ]]; then
    echo "!! Missing iOS screenshot results; preserving previous reports." >&2
    exit 1
  fi
  if [[ -f "$resultFile" ]]; then
    iosFailures=$(jq -r '.failures | if type == "array" then .[] else error("Expected failures array") end' "$resultFile")
    while IFS= read -r failure; do
      screen="${failure%%:*}"
      screen="${screen## }"
      screen="${screen%% }"
      [[ -n "$screen" ]] || continue
      for suffix in expected actual diff; do
        if [[ "$suffix" == "expected" ]]; then
          sourceFile="$iosScreenshotsDir/$screen-expected.png"
        elif [[ "$suffix" == "actual" ]]; then
          sourceFile="$iosScreenshotsDir/$screen.png"
        fi
        if [[ "$paparazziMode" == false && "$iosMode" == false ]]; then
          sourceFile="$iosScreenshotsDir/$screen-diff.png"
        fi
        [[ -f "$sourceFile" ]] && cp "$sourceFile" "$diffFiles/$screen-$suffix.png"
      done
    done <<< "$iosFailures"
  fi
else
  ./git-diff-image/install.sh
  echo "==> Run git diff-image with output dir $diffFiles and fuzz $screenshotCompareFuzz%"
  if [ -n "$SCREENSHOT_DEBUG" ]; then
    set -x
    GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles GIT_DIFF_IMAGE_FUZZ=$screenshotCompareFuzz git diff-image
    set +x
  else
    GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles GIT_DIFF_IMAGE_FUZZ=$screenshotCompareFuzz git diff-image
  fi
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

  # A 0-byte (or otherwise unreadable) file means the image that was supposed
  # to be uploaded was never actually produced - e.g. git-diff-image's
  # compare/montage (ImageMagick) crashing on the runner, such as a missing
  # system dylib (dyld abort). Uploading that garbage would just get GitHub's
  # attachment endpoint to reject it with a confusing "size ... big file"
  # 422, which looks identical to the real >=10MB case but has nothing to do
  # with file size. Fail fast here with a clearer diagnostic instead.
  if [ ! -s "$file" ]; then
    echo "!! $file is empty or missing, skipping upload (likely a failed image comparison/render on the runner, not an actual file size issue)" >&2
    return 1
  fi

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
if [ -n "$SCREENSHOT_DEBUG" ]; then
  echo "SCREENSHOT_DEBUG is set and not empty"
  printf '%s\n' "$oldCommentsJson"
else
  echo "SCREENSHOT_DEBUG is unset or empty"
fi

if [ "$PR" = "master" ]; then
  echo "PR is master, nothing to upload"
else
  if [[ -z "$CLASSIC_TOKEN" ]]; then
    echo "!! CLASSIC_TOKEN is required to report screenshot differences." >&2
    exit 1
  fi
  repoId=$(curl_gh -X GET https://api.github.com/repos/"$GITHUB_REPOSITORY" | jq -r .id)
  echo "repoId=$repoId"

  legacyCommentMarker="<!-- screenshot-diff:$screenshotPlatform -->"
  existingCommentIds=()
  page=1
  while true; do
    oldCommentsJson=$(curl_gh -X GET "https://api.github.com/repos/$GITHUB_REPOSITORY/issues/$PR/comments?per_page=100&page=$page")
    matchingIds=$(printf '%s' "$oldCommentsJson" | jq -r \
      --arg marker "$screenshotCommentMarker" --arg legacy "$legacyCommentMarker" \
      --arg platform "$screenshotPlatform" \
      '.[] | select(
        (.body | contains($marker)) or (.body | contains($legacy)) or
        ($platform == "all" and (
          (.body | contains("<!-- screenshot-compare:")) or
          (.body | contains("<!-- screenshot-diff:")) or
          (.body | startswith("Screenshot differs:"))
        ))
      ) | .id')
    if [[ -n "$matchingIds" ]]; then
      existingCommentIds+=("${(@f)matchingIds}")
    fi
    [[ $(printf '%s' "$oldCommentsJson" | jq 'length') -lt 100 ]] && break
    (( page++ ))
  done

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

      newName="${GITHUB_REPOSITORY//\//-}-pr${PR}-${screenshotCompareTag}-${f}"
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

      newName="${GITHUB_REPOSITORY//\//-}-pr${PR}-${screenshotCompareTag}-${safeName}"
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

      newName="${GITHUB_REPOSITORY//\//-}-pr${PR}-${screenshotCompareTag}-$(date +%s).png"
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
    if [ -z "${CLASSIC_TOKEN}" ]; then
       echo "!! You must provide a \e[31mCLASSIC_TOKEN\e[0m environment variable. Exiting...."
       exit 1
    fi
    commentBody="$screenshotCommentMarker"$'\n\n'"Screenshot differs: $screenshotCompareLabel with $COUNTER screenshot(s)"$'\n\n'"setpoint (old) | diff | actual screenshot (new)"$'\n\n'"$body"
    newline=$'\n'
    commentBody="${commentBody//<br\/>/$newline}"
    commentJson=$(jq -n --arg body "$commentBody" '{body: $body}')
    curl_gh -X POST https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/$PR/comments -d "$commentJson"
  fi
  for existingCommentId in "${existingCommentIds[@]}"; do
    echo "==> Remove previous screenshot comment $existingCommentId"
    curl_gh -X DELETE https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/comments/"$existingCommentId"
  done

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
