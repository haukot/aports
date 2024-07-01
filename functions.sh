# shellcheck disable=SC3043

:

# shellcheck disable=SC3040
set -eu -o pipefail

changed_repos() {
	: "${APORTSDIR?APORTSDIR missing}"
	: "${BASEBRANCH?BASEBRANCH missing}"

	cd "$APORTSDIR"
	for repo in $REPOS; do
		git diff --diff-filter=ACMR --exit-code "$BASEBRANCH"...HEAD -- "$repo" >/dev/null \
			|| echo "$repo"
	done
}

changed_aports() {
	: "${APORTSDIR?APORTSDIR missing}"
	: "${BASEBRANCH?BASEBRANCH missing}"

	cd "$APORTSDIR"
	local repo="$1"
	local aports

	aports=$(git diff --name-only --diff-filter=ACMR --relative="$repo" \
		"$BASEBRANCH"...HEAD -- "*/APKBUILD" | xargs -rn1 dirname)

	# shellcheck disable=2086
	ap builddirs -d "$APORTSDIR/$repo" $aports 2>/dev/null | xargs -rn1 basename
}

section_start() {
	name=${1?arg 1 name missing}
	header=${2?arg 2 header missing}
	collapsed=$2
	timestamp=$(date +%s)

	options=""
	case $collapsed in
		yes|on|collapsed|true) options="[collapsed=true]";;
	esac

	printf "\e[0Ksection_start:%d:%s%s\r\e[0K%s\n" "$timestamp" "$name" "$options" "$header"
}

section_end() {
	name=$1
	timestamp=$(date +%s)

	printf "\e[0Ksection_end:%d:%s\r\e[0K" "$timestamp" "$name"
}
