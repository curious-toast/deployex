#!/bin/bash
#
# Installs the Erlang and Elixir versions in a .tool-versions file, on a build host that has
# no prebuilt Erlang from erlef/setup-beam, such as Amazon Linux 2023. Erlang builds from
# source. Elixir is the prebuilt zip for the Erlang major version. Both are checked against
# the checksums their projects publish.
#
# Usage: setup-beam.sh [tool_versions_file] [prefix]
#
# On Amazon Linux 2023, install the build tools first:
#   dnf install -y git tar gzip unzip findutils gcc gcc-c++ make perl ncurses-devel openssl-devel libcap-devel
#
set -euo pipefail

TOOL_VERSIONS=${1:-.tool-versions}
PREFIX=${2:-/usr/local}

erlang=$(awk '$1 == "erlang" {print $2}' "${TOOL_VERSIONS}")
elixir=$(awk '$1 == "elixir" {print $2}' "${TOOL_VERSIONS}")
if [[ -z "${erlang}" || "${elixir}" != *-otp-* ]]; then
  echo "Error: ${TOOL_VERSIONS} needs an erlang line and an elixir <version>-otp-<major> line" >&2
  exit 1
fi
elixir_version=${elixir%-otp-*}
elixir_otp=${elixir##*-otp-}

otp_url="https://github.com/erlang/otp/releases/download/OTP-${erlang}"
elixir_url="https://github.com/elixir-lang/elixir/releases/download/v${elixir_version}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
cd "${work}"

echo "# Building Erlang ${erlang} from source"
curl -fsSL --retry 3 --connect-timeout 30 --max-time 900 -O "${otp_url}/otp_src_${erlang}.tar.gz" -O "${otp_url}/SHA256.txt"
grep " otp_src_${erlang}.tar.gz$" SHA256.txt | sha256sum -c -
tar -xzf "otp_src_${erlang}.tar.gz"
(
  cd "otp_src_${erlang}"
  ./configure --prefix="${PREFIX}" --without-javac --without-odbc --without-wx
  make -j"$(nproc)"
  make install
)

echo "# Installing Elixir ${elixir_version} for OTP ${elixir_otp}"
curl -fsSL --retry 3 --connect-timeout 30 --max-time 900 -O "${elixir_url}/elixir-otp-${elixir_otp}.zip" -O "${elixir_url}/elixir-otp-${elixir_otp}.zip.sha256sum"
sha256sum -c "elixir-otp-${elixir_otp}.zip.sha256sum"
rm -rf "${PREFIX}/elixir"
unzip -q "elixir-otp-${elixir_otp}.zip" -d "${PREFIX}/elixir"
for bin in elixir elixirc iex mix; do
  ln -sf "${PREFIX}/elixir/bin/${bin}" "${PREFIX}/bin/${bin}"
done

mix local.hex --force
mix local.rebar --force
erl -noshell -eval 'io:format("Erlang ~s~n", [erlang:system_info(otp_release)]), halt().'
elixir --version | tail -1
