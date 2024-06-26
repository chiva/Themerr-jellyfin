# syntax=docker/dockerfile:1.4
# artifacts: false
# platforms: linux/amd64
# Linuxserver.io docker mods are not multiplatform, so no point in enabling "linux/arm64/v8"
# cannot enable "linux/arm/v7" due to issue with dotnet
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

FROM base as buildstage

# build args
ARG BUILD_VERSION
ARG COMMIT
ARG GITHUB_SHA=$COMMIT
# note: BUILD_VERSION may be blank, COMMIT is also available

ENV VIRTUAL_ENV=/opt/venv

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# install dependencies
# dotnet deps: https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu#dependencies
RUN <<_DEPS
#!/bin/bash
apt-get update -y
apt-get install -y --no-install-recommends \
  libc6 \
  libgcc-s1 \
  libgssapi-krb5-2 \
  libicu74 \
  liblttng-ust1 \
  libssl3 \
  libstdc++6 \
  libunwind8 \
  python3 \
  python3-pip \
  python3-venv \
  unzip \
  wget \
  zlib1g
apt-get clean
rm -rf /var/lib/apt/lists/*
_DEPS

# install dotnet-sdk
WORKDIR /tmp
RUN <<_DOTNET
#!/bin/bash
url="https://dot.net/v1/dotnet-install.sh"
wget --quiet "$url" -O dotnet-install.sh
chmod +x ./dotnet-install.sh
./dotnet-install.sh --channel 8.0
_DOTNET

# create venv
RUN <<_VENV
#!/bin/bash
# create and source the virtual environment
python3 -m venv ${VIRTUAL_ENV}
_VENV

# add dotnet and venv to path
ENV PATH="/root/.dotnet:${VIRTUAL_ENV}/bin:${PATH}"

# create build dir and copy GitHub repo there
COPY --link . /build

# set build dir
WORKDIR /build

# update pip
RUN <<_PIP
#!/bin/bash
python3 -m pip install --no-cache-dir --upgrade \
  pip setuptools wheel
python3 -m pip install --no-cache-dir -r requirements-dev.txt
_PIP

# build
RUN <<_BUILD
#!/bin/bash
# force the workflow to fail if any command fails
set -e
# jprm fails if output directory does not exist, so create it
mkdir -p ./artifacts
# check if build version is empty or "v" (v may be supplied with no version for PR events)
if [[ -z "${BUILD_VERSION}" || "${BUILD_VERSION}" == "v" ]]; then
  BUILD_VERSION="0.0.0.0"
else
  # remove the v prefix from the version
  BUILD_VERSION="${BUILD_VERSION#v}"
fi
python3 -m jprm --verbosity=debug plugin build "./" --version="${BUILD_VERSION}" --output="./artifacts"
mkdir -p /artifacts
unzip ./artifacts/*.zip -d /artifacts
_BUILD

# apply permissions to s6 run script
RUN chmod +x ./dockermod_root/etc/s6-overlay/s6-rc.d/init-mod-jellyfin-themerr-config/run

FROM scratch AS layer_stage

# variables
ARG PLUGIN_NAME="themerr-jellyfin"
ARG PLUGIN_DIR="/root-layer/config/data/plugins"

# add files from buildstage
# trailing slash on artifacts directory copies the contents of the directory, instead of the directory itself
COPY --link --from=buildstage /artifacts/ $PLUGIN_DIR/$PLUGIN_NAME

# copy s6 initialization files
COPY --link --from=buildstage /build/dockermod_root/ /root-layer

FROM scratch AS deploy

# Linuxserver.io docker mods require that mods be fully contained in a single layer

# copy s6 initialization files
COPY --link --from=layer_stage /root-layer/ /
