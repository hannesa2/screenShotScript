#!/bin/zsh

diffFiles=./screenshotDiffs
mkdir $diffFiles
# set -x
./git-diff-image/install.sh
GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles git diff-image

pwd
source $(dirname $0)/lib.sh

PR=$(echo "$GITHUB_REF_NAME" | sed "s/\// /" | awk '{print $1}')
echo PR=$PR

OS="`uname`"
case $OS in
  'Linux')
    ;;
  'FreeBSD')
    ;;
  'WindowsNT')
    ;;
  'Darwin')
    brew install jq
    ;;
  'SunOS')
    ;;
  'AIX') ;;
  *) ;;
esac

if [ -z "${CLASSIC_TOKEN-}" ]; then
   echo "!! You must provide CLASSIC_TOKEN environment variable. Otherwise screenshot compare doesn't work properly"
fi

echo "==> Delete all old comments, starting with 'Screenshot differs:"

oldComments=$(curl_gh -X GET https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/"$PR"/comments | jq '.[] | (.id |tostring) + "|" + (.body | test("Screenshot differs:.*") | tostring)' | grep "|true" | tr -d "\"" | cut -f1 -d"|")
echo "oldComments=$oldComments"
echo "$oldComments" | while read comment; do
  if [ -z "$comment" ]
  then
    # comment is empty
    echo "==> old comment is empty, there is nothing to do"
  else
    # comment is not empty
    echo "==> delete comment=$comment"
    curl_gh -X DELETE https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/comments/"$comment"
  fi
done

pushd $diffFiles
pwd
body=""
COUNTER=0
ls -la

echo "==> Loop on *.png and ignore an error, when no files where found https://unix.stackexchange.com/a/723909/201876"
setopt no_nomatch
for f in *.png; do
  if [[ ${f} == "*.png" ]]
  then
    echo "nothing found"
  else
    (( COUNTER++ ))

    newName="${f}"
    # mv "${f}" "$newName"
    echo "==> Uploaded screenshot $newName"
    curl -i -F "file=@$newName" https://www.mxtracks.info/github
    echo "==> Add screenshot comment $PR"
    body="$body ${f}![screenshot](https://www.mxtracks.info/github/uploads/$newName) <br/><br/>"
  fi
done

echo "==> Search for error screenshots in $(pwd)"
find .. -name "view-op-error-*.png" | while IFS= read -r f; do
  if [[ ${f} == "../view-op-error-*.png" ]]
  then
    echo "no error png found"
  else
    echo "Found $f"
    (( COUNTER++ ))

    newName="$(date +%s).png"
    mv "${f}" "$newName"
    echo "==> Uploaded screenshot $newName"
    curl -i -F "file=@$newName" https://www.mxtracks.info/github
    echo "==> Add error screenshot comment $PR"
    body="$body <br/>${f}<br/>![screenshot](https://www.mxtracks.info/github/uploads/$newName) <br/><br/>"
  fi
done

if [ ! "$body" == "" ]; then
  echo "==> Post comment to $PR"
  echo "==> body=$body"
  if [ -z "${CLASSIC_TOKEN-}" ]; then
     echo "!! You must provide a CLASSIC_TOKEN environment variable. Exiting...."
     exit 1
  fi
  curl_gh -X POST https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/$PR/comments -d "{ \"body\" : \"Screenshot differs: emulatorApi=$emulatorApi with $COUNTER screenshot(s)<br/><br/> $body \" }"
fi

popd 1>/dev/null

# set error when diffs are there
echo ""
[ "$(ls -A $diffFiles)" ] && echo "==> Force error on diff files exists" && exit 1 || echo "==> all is fine" && exit 0
