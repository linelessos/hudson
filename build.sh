#!/usr/bin/env bash

function check_result {
  if [ "0" -ne "$?" ]
  then
    local err_message=${1:-""}
    local exit_die=${2:-"true"}
    local rm_roomservice=${3:-"true"}
    (repo forall -c "git reset --hard; git clean -fdx") >/dev/null
    rm -f .repo/local_manifests/dyn-*.xml
    if [ "$rm_roomservice" = "true" ]
    then
      rm -f .repo/local_manifests/roomservice.xml
    fi
    echo $err_message
    if [ "$exit_die" = "true" ]
    then
      exit 1
    fi
  fi
}

if [ -z "$HOME" ]
then
  echo HOME not in environment, guessing...
  export HOME=$(awk -F: -v v="$USER" '{if ($1==v) print $6}' /etc/passwd)
fi

if [ -z "$WORKSPACE" ]
then
  echo WORKSPACE not specified
  exit 1
fi

if [ -z "$REPO_BRANCH" ]
then
  echo REPO_BRANCH not specified
  exit 1
fi

if [ -z "$CLEAN" ]
then
  echo CLEAN not specified
  exit 1
fi

if [ -z "$LINEAGE_BUILDTYPE" ]
then
  export LINEAGE_BUILDTYPE="UNOFFICIAL"
fi

if [ -z "$SYNC_PROTO" ]
then
  SYNC_PROTO=git
fi

cd $WORKSPACE
rm -rf archive
mkdir -p archive
export BUILD_NO=$BUILD_NUMBER
unset BUILD_NUMBER

#export PATH=~/bin:$PATH
export BUILD_WITH_COLORS=1

if [[ "$LINEAGE_BUILDTYPE" == "RELEASE" ]]
then
  export USE_CCACHE=0
else
  export USE_CCACHE=1
fi

REPO=$(which repo)
if [ -z "$REPO" ]
then
  mkdir -p ~/bin
  curl https://dl-ssl.google.com/dl/googlesource/git-repo/repo > ~/bin/repo
  chmod a+x ~/bin/repo
fi

JENKINS_BUILD_DIR=carbon

mkdir -p $JENKINS_BUILD_DIR
cd $JENKINS_BUILD_DIR

# always force a fresh repo init since we can build off different branches
# and the "default" upstream branch can get stuck on whatever was init first.
if [ -z "$CORE_BRANCH" ]
then
  CORE_BRANCH=$REPO_BRANCH
fi

if [ ! -z "$RELEASE_MANIFEST" ]
then
  MANIFEST="-m $RELEASE_MANIFEST"
else
  RELEASE_MANIFEST=""
  MANIFEST=""
fi

# remove manifests
rm -rf .repo/manifests*
rm -f .repo/local_manifests/dyn-*.xml
rm -f .repo/local_manifest.xml
repo init -u https://github.com/linelessos/platform_manifest_twrp_omni.git -b twrp-9.0
check_result "repo init failed."

if [ $USE_CCACHE -eq 1 ]
then
  # make sure ccache is in PATH
  export PATH="$PATH:/opt/local/bin/:$PWD/prebuilts/misc/$(uname|awk '{print tolower($0)}')-x86/ccache"
  export CCACHE_DIR=/home/build/ccache/$REPO_BRANCH
  mkdir -p $CCACHE_DIR
fi

mkdir -p .repo/local_manifests
rm -f .repo/local_manifest.xml

echo "Core Manifest:"
cat .repo/manifest.xml

if [[ "$SYNC_REPOS" == "no" ]]
then
  echo Skip syncing... Starting build
else
  echo Syncing...
  # if sync fails:
  # clean repos (uncommitted changes are present), don't delete roomservice.xml, don't exit
  rm -rf vendor

  mkdir -p .repo/local_manifests
  cp  ../local.xml .repo/local_manifests/
  #Delete current tree
  #rm -rf *

  repo sync --force-sync -d -c -j24
  check_result "repo sync failed.", false, false

  # SUCCESS
  echo Sync complete.
fi

export OUT_DIR=/mnt/build/jenkins/lineless
rm -rf $OUT_DIR
mkdir -p $OUT_DIR
. build/envsetup.sh
breakfast $DEVICE
check_result "lunch failed."

rm -f $OUT/*.zip*

UNAME=$(uname)

echo "Start building for $BUILD_USER_ID"

if [ ! -z "$GERRIT_CHANGE_NUMBER" ]
then
  export GERRIT_CHANGES=$GERRIT_CHANGE_NUMBER
fi

if [ ! -z "$GERRIT_TOPICS" ]
then
  IS_HTTP=$(echo $GERRIT_TOPICS | grep http)
  if [ -z "$IS_HTTP" ]
  then
    python $WORKSPACE/$JENKINS_BUILD_DIR/vendor/lineage/build/tools/repopick.py -t $GERRIT_TOPICS
    check_result "gerrit picks failed."
  else
    python $WORKSPACE/$JENKINS_BUILD_DIR/vendor/lineage/build/tools/repopick.py -t $(curl $GERRIT_TOPICS)
    check_result "gerrit picks failed."
  fi
fi
if [ ! -z "$GERRIT_CHANGES" ]
then
  export LINEAGE_BUILDTYPE="EXPERIMENTAL"
  IS_HTTP=$(echo $GERRIT_CHANGES | grep http)
  if [ -z "$IS_HTTP" ]
  then
    python $WORKSPACE/$JENKINS_BUILD_DIR/vendor/lineage/build/tools/repopick.py $GERRIT_CHANGES
    check_result "gerrit picks failed."
  else
    python $WORKSPACE/$JENKINS_BUILD_DIR/vendor/lineage/build/tools/repopick.py $(curl $GERRIT_CHANGES)
    check_result "gerrit picks failed."
  fi
fi

if [ $USE_CCACHE -eq 1 ]
then
  if [ ! "$(ccache -s|grep -E 'max cache size'|awk '{print $4}')" = "64.0" ]
  then
    ccache -M 64G
  fi
  echo "============================================"
  ccache -s
  echo "============================================"
fi

echo "Cleaning!"
make clobber

if [[ "$MAKE_BLOB" == "brunch" ]]
then
	time $MAKE_BLOB $DEVICE
	check_result "Build failed."
else
	make -j$(nproc --all) $MAKE_BLOB
	check_result "Build failed."
fi

if [ $USE_CCACHE -eq 1 ]
then
  echo "============================================"
  ccache -V
  echo "============================================"
  ccache -s
  echo "============================================"
fi

# /archive
cp $OUT/*lineage*.zip* $WORKSPACE/archive/

if [ -f $OUT/recovery.img ]
then
  cp $OUT/recovery.img $WORKSPACE/archive/$DEVICE-recovery.img
fi
if [ -f $OUT/boot.img ]
then
  cp $OUT/boot.img $WORKSPACE/archive/$DEVICE-boot.img
fi

# chmod the files in case UMASK blocks permissions
chmod -R ugo+r $WORKSPACE/archive
