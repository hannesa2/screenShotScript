#!/bin/zsh
set -eo pipefail # automatic. fails on any error

diffFiles=./screenshotDiffs
mkdir $diffFiles
# set -x
./git-diff-image/install.sh
GIT_DIFF_IMAGE_OUTPUT_DIR=$diffFiles git diff-image

pwd
source $(dirname $0)/lib.sh

echo "GITHUB_REF_NAME=$GITHUB_REF_NAME"
echo $(echo "$GITHUB_REF_NAME" | sed "s/\// /")
PR=$(echo "$GITHUB_REF_NAME" | sed "s/\// /" | awk '{print $1}')
echo "PR=$PR GITHUB_REF_NAME=$GITHUB_REF_NAME"

OS="`uname`"
case $OS in
  'Linux')
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

if [ -z "${CLASSIC_TOKEN}" ]; then
   echo "\e[31m!! You must provide CLASSIC_TOKEN environment variable.\e[0m Otherwise screenshot compare doesn't work properly"
fi
if [ -z "${SCREENSHOT_USER}" ]; then
   echo "\e[31m!! You must provide SCREENSHOT_USER environment variable.\e[0m Otherwise screenshot compare doesn't work properly"
fi
if [ -z "${SCREENSHOT_PASSWORD}" ]; then
   echo "\e[31m!! You must provide SCREENSHOT_PASSWORD environment variable.\e[0m Otherwise screenshot compare doesn't work properly"
fi

echo "==> Delete all old comments, starting with 'Screenshot differs:"
oldCommentsJson=$(curl_gh -X GET https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/"$PR"/comments)
if [ -n "$DEBUG_INFO" ]; then
  echo "DEBUG_INFO is set and not empty"
  echo $oldCommentsJson
else
  echo "DEBUG_INFO is unset or empty"
fi

# the last echo fixes a merge to master, because then no such comments exists
oldCommentsList=$(echo $oldCommentsJson | jq '.[] | (.id |tostring) + "|" + (.body | test("Screenshot differs:.*") | tostring)' || echo "")
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
    echo "before COUNTER=$COUNTER"
    (( COUNTER++ )) || echo "Nothing to do with COUNTER++"
    echo "after COUNTER=$COUNTER"

    newName="${f}"
    # mv "${f}" "$newName"
    echo "==> Uploaded screenshot $newName"
    request_cmd="curl -i -F \"file=@$newName\" https://www.mxtracks.info/github -u $SCREENSHOT_USER:$SCREENSHOT_PASSWORD"
    request_result="$(eval "$request_cmd")"
    http_status=$(echo "$request_result" | grep HTTP |  awk '{print $2}')
    echo "request_cmd=$request_cmd"
    if [ "$http_status" != "200" ] && [ "$http_status" != "302" ]; then
      echo "!! Screenshot upload failed for $newName \e[31m$http_status\e[0m"
      body="$body ${f} Upload http_status=<strong>$http_status</strong> <br/><br/>"
      continue
    else :
      echo "==> Screenshot upload successful for $newName with http_status=\e[32m$http_status\e[0m"
    fi
    echo "==> Add screenshot commentLine $PR"
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
    echo "before COUNTER=$COUNTER"
    (( COUNTER++ )) || echo "Nothing to do with COUNTER++"
    echo "after COUNTER=$COUNTER"

    newName="$(date +%s).png"
    mv "${f}" "$newName"
    echo "==> Uploaded screenshot $newName"
    curl -i -F "file=@$newName" https://www.mxtracks.info/github
    echo "==> Add error screenshot commentLine $PR"
    body="$body <br/>${f}<br/>![screenshot](https://www.mxtracks.info/github/uploads/$newName) <br/><br/>"
  fi
done

if [ ! "$body" == "" ]; then
  echo "==> Post commentLine to $PR"
  echo "==> body=$body"
  if [ -z "${CLASSIC_TOKEN}" ]; then
     echo "!! You must provide a \e[31mCLASSIC_TOKEN\e[0m environment variable. Exiting...."
     exit 1
  fi
  curl_gh -X POST https://api.github.com/repos/"$GITHUB_REPOSITORY"/issues/$PR/comments -d "{ \"body\" : \"Screenshot differs: emulatorApi=$emulatorApi with $COUNTER screenshot(s)<br/><br/>setpoint|diff|actual screenshot<br/><br/> $body \" }"
fi

popd 1>/dev/null

# set error when diffs are there
echo ""
[ "$(ls -A $diffFiles)" ] && echo "==> Force error on diff files exists" && exit 1 || echo "==> all is fine" && exit 0
