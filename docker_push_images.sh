#!/bin/sh

docker -H tcp://127.0.0.1:2375 images | \
    grep -v ^REP | \
    sort -k1 -k2 | \
    grep ^frans | \
    while read line; do
	set -- $(echo "${line}")
	docker -H tcp://127.0.0.1:2375 push docker.io/${1}:${2}
    done
