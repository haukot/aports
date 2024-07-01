#!/bin/sh

for tree in distro-modules distro-modules-common; do
	luarocks-admin-5.4 make-manifest --local-tree --tree=$tree >/dev/null 2>&1
done

exit 0
