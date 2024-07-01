#!/bin/sh
# shellcheck disable=SC3043

. /usr/local/lib/functions.sh

# shellcheck disable=SC3040
set -eu -o pipefail

readonly APORTSDIR=$CI_PROJECT_DIR
readonly REPOS="main community testing non-free"
readonly ARCH=$(apk --print-arch)
# gitlab variables
readonly BASEBRANCH=$CI_MERGE_REQUEST_TARGET_BRANCH_NAME

: "${REPODEST:=$HOME/packages}"
: "${MIRROR:=https://dl-cdn.alpinelinux.org/alpine}"
: "${MAX_ARTIFACT_SIZE:=300000000}" #300M
: "${CI_DEBUG_BUILD:=}"

: "${CI_ALPINE_BUILD_OFFSET:=0}"
: "${CI_ALPINE_BUILD_LIMIT:=9999}"

msg() {
	local color=${2:-green}
	case "$color" in
		red) color="31";;
		green) color="32";;
		yellow) color="33";;
		blue) color="34";;
		*) color="32";;
	esac
	printf "\033[1;%sm>>>\033[1;0m %s\n" "$color" "$1" | xargs >&2
}

verbose() {
	echo "> " "$@"
	# shellcheck disable=SC2068
	$@
}

debugging() {
	[ -n "$CI_DEBUG_BUILD" ]
}

debug() {
	if debugging; then
		verbose "$@"
	fi
}

die() {
	msg "$1" red
	exit 1
}

capture_stderr() {
	"$@" 2>&1
}

report() {
	report=$1

	reportsdir=$APORTSDIR/logs/
	mkdir -p "$reportsdir"

	tee -a "$reportsdir/$report.log"
}

get_release() {
	case $BASEBRANCH in
		*-stable) echo v"${BASEBRANCH%-*}";;
		master) echo edge;;
		*) die "Branch \"$BASEBRANCH\" not supported!"
	esac
}

build_aport() {
	local repo="$1" aport="$2"
	cd "$APORTSDIR/$repo/$aport"
	if abuild -r 2>&1 | report "build-$aport"; then
		checkapk 2>&1 | report "checkapk-$aport" || true
		aport_ok="$aport_ok $repo/$aport"
	else
		aport_ng="$aport_ng $repo/$aport"
	fi
}

check_aport() {
	return 0

	local repo="$1" aport="$2"
	cd "$APORTSDIR/$repo/$aport"
	if ! abuild check_arch 2>/dev/null; then
		aport_na="$aport_na $repo/$aport"
		return 1
	fi
}

set_repositories_for() {
	local target_repo="$1" repos='' repo=''
	local release

	release=$(get_release)
	for repo in $REPOS; do
		[ "$repo" = "non-free" ] && continue
		[ "$release" != "edge" ] && [ "$repo" == "testing" ] && continue
		repos="$repos $MIRROR/$release/$repo $REPODEST/$repo"
		[ "$repo" = "$target_repo" ] && break
	done
	doas sh -c "printf '%s\n' $repos > /etc/apk/repositories"
	doas apk update
}

apply_offset_limit() {
	start=$1
	limit=$2
	end=$((start+limit))

	sed -n "$((start+1)),${end}p"
}

setup_system() {
	doas sh -c "echo $MIRROR/$(get_release)/main > /etc/apk/repositories"
	doas apk -U upgrade -a || apk fix || die "Failed to up/downgrade system"
	abuild-keygen -ain
	doas sed -i -E 's/export JOBS=[0-9]+$/export JOBS=$(nproc)/' /etc/abuild.conf
	( . /etc/abuild.conf && echo "Building with $JOBS jobs" )
	mkdir -p "$REPODEST"
	git config --global init.defaultBranch master
}

sysinfo() {
	printf ">>> Host system information (arch: %s, release: %s) <<<\n" "$ARCH" "$(get_release)"
	printf "- Number of Cores: %s\n" "$(nproc)"
	printf "- Memory: %s Gb\n" "$(awk '/^MemTotal/ {print ($2/1024/1024)}' /proc/meminfo)"
	printf "- Free space: %s\n" "$(df -hP / | awk '/\/$/ {print $4}')"
}

copy_artifacts() {
	cd "$APORTSDIR"

	packages_size="$(du -sk "$REPODEST" | awk '{print $1 * 1024}')"
	if [ -z "$packages_size" ]; then
		return
	fi

	echo "Artifact size: $packages_size bytes"

	mkdir -p keys/ packages/

	if [ "$packages_size" -lt $MAX_ARTIFACT_SIZE ]; then
		msg "Copying packages for artifact upload"
		cp -ar "$REPODEST"/* packages/ 2>/dev/null
		cp ~/.abuild/*.rsa.pub keys/
	else
		msg "Artifact size $packages_size larger than max ($MAX_ARTIFACT_SIZE), skipping uploading them" yellow
	fi
}

section_start setup "Setting up the system" collapse

if debugging; then
	set -x
fi

aport_ok=
aport_na=
aport_ng=
failed=

sysinfo || true
setup_system || die "Failed to setup system"

# git no longer allows to execute in repositories owned by different users
doas chown -R buildozer: .

fetch_flags="-qn"
debugging && fetch_flags="-v"

git fetch $fetch_flags "$CI_MERGE_REQUEST_PROJECT_URL" \
	"+refs/heads/$BASEBRANCH:refs/heads/$BASEBRANCH"

if debugging; then
	merge_base=$(git merge-base "$BASEBRANCH" HEAD) || echo "Could not determine merge-base"
	echo "Merge base: $merge_base"
	git --version
	git config -l
	[ -n "$merge_base" ] && git tag -f merge-base "$merge_base"
	git --no-pager log -200 --oneline --graph --decorate --all
fi

section_end setup

build_start=$CI_ALPINE_BUILD_OFFSET
build_limit=$CI_ALPINE_BUILD_LIMIT

for repo in $(changed_repos); do
	set_repositories_for "$repo"
	built_aports=0
	changed_aports_in_repo=ruby
	changed_aports_in_repo_count=$(echo "$changed_aports_in_repo" | wc -l)
	changed_aports_to_build=$(echo "$changed_aports_in_repo" | apply_offset_limit "$build_start" "$build_limit")

	msg "Changed aports in $repo:"
	# shellcheck disable=SC2086 # Splitting is expected here
	printf " - %s\n" $changed_aports_to_build
	for pkgname in $changed_aports_to_build; do
		section_start "build_$pkgname" "Building package $pkgname"
		built_aports=$((built_aports+1))
		if check_aport "$repo" "$pkgname"; then
			build_aport "$repo" "$pkgname"
		fi
		section_end "build_$pkgname"
	done

	build_start=$((build_start-(changed_aports_in_repo_count-built_aports)))
	build_limit=$((build_limit-built_aports))

	if [ $build_limit -le 0 ]; then
		msg "Limit reached, breaking"
		break
	fi
done

section_start artifacts "Handeling artifacts" collapse
copy_artifacts || true
section_end artifacts

section_start summary "Build summary"

echo "### Build summary ###"

for ok in $aport_ok; do
	msg "$ok: build succesfully"
done

for na in $aport_na; do
	msg "$na: disabled for $ARCH" yellow
done

for ng in $aport_ng; do
	msg "$ng: build failed" red
	failed=true
done
section_end summary

if [ "$failed" = true ]; then
	exit 1
elif [ -z "$aport_ok" ]; then
	msg "No packages found to be built." yellow
fi

