#!/bin/bash
set -e

# use builtkit
export DOCKER_BUILDKIT=0

# params
self=$0
container="anticheat"
all=$*

# sanitize
if [[ "$container" == "" ]]; then
  echo "Syntax: ${self} [--push] [--force]"
  exit 1
fi

# last build version
function last_build_version() {
  # config
  file=".last-build-version"

  # read version
  if [[ -f $file ]]; then
    version=$(cat $file)
  fi

  # check if we need to force update the build
  if [[ "$all" == *"--force"* ]]; then
    version=""
  fi

  # create new version tag
  if [[ "$version" == "" ]]; then
    version=$(date +"%Y%m%d.%H%M%S")
  fi

  # write version tag
  echo $version >$file

  # return version tag
  echo $version
}

# build container
function build_container() {
  # params
  container=$1
  prefix="mithrand0/reactive-drop"
  name="${prefix}-anticheat"
  version=$(last_build_version)
  target="Dockerfile"

  # check the release target
  if [[ "$all" == *"--testing"* ]]; then
    tag="testing"
  else
    tag="latest"
  fi    

  # check the release target
  if [[ "$all" == *"--quiet"* ]]; then
    quiet="--quiet"
  else
    quiet=""
  fi    

  # build
  docker build \
    --build-arg build=$version \
    -t $name:$version \
    -t $name:$tag \
    -f $target $quiet .

  # check if we need to push it
  if [[ "$all" == *"--push"* ]]; then
    docker push $name:$version
    docker push $name:$tag
  fi
}

build_container $container

echo "Finished"
