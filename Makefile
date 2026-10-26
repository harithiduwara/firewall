# Home Firewall — developer tasks.
.PHONY: all lint test install check

all: lint test

lint:
	shellcheck -x scripts/fw-apply scripts/install.sh tests/*.sh
	python3 -m py_compile tests/probe.py tests/traceability.py
	unshare -n nft -I src -c -f src/nftables.conf
	unshare -n nft -I src -c -f src/home-firewall/lockdown.nft

test:
	tests/run.sh

check:
	/usr/local/sbin/fw-apply --check /etc/nftables.conf

install:
	scripts/install.sh
