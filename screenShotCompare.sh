#!/bin/zsh

diffFiles=./screenshotDiffs
mkdir $diffFiles
set -x
./git-diff-image/install.sh
GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles git diff-image

pwd
source $(dirname $0)/lib.sh

PR=$(echo "$GITHUB_REF_NAME" | sed "s/\// /" | awk '{print $1}')
echo pr=$PR

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
   echo "Must provide CLASSIC_TOKEN environment variable. Exiting...."
   exit 1
fi

echo "=> delete all old comments, starting with Screenshot differs:$emulatorApi"

oldComments=$(curl_gh -X GET https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/"$PR"/comments | jq '.[] | (.id |tostring) + "|" + (.body | test("Screenshot differs:'$emulatorApi'.*") | tostring)' | grep "|true" | tr -d "\"" | cut -f1 -d"|")
echo "comments=$comments"
echo "$oldComments" | while read comment; do
  echo "delete comment=$comment"
  curl_gh -X DELETE https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/comments/"$comment"
done

pushd $diffFiles
pwd
body=""
COUNTER=0
ls -la

echo "=> ignore an error, when no files where found https://unix.stackexchange.com/a/723909/201876"
setopt no_nomatch
for f in *.png; do
  if [[ ${f} == "*.png" ]]
  then
    echo "nothing found"
  else
    (( COUNTER++ ))

    newName="${f}"
    mv "${f}" "$newName"
    echo "==> Uploaded screenshot $newName"
    curl -i -F "file=@$newName" https://www.mxtracks.info/github
    echo "==> Add screenshot comment $PR"
    body="$body ${f}![screenshot](https://www.mxtracks.info/github/uploads/$newName) <br/><br/>"
  fi
done

if [ ! "$body" == "" ]; then
  curl_gh -X POST https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/$PR/comments -d "{ \"body\" : \"Screenshot differs:$emulatorApi $COUNTER <br/><br/> $body \" }"
fi

popd 1>/dev/null

# set error when diffs are there
[ "$(ls -A $diffFiles)" ] && exit 1 || exit 0
