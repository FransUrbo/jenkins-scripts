#!/bin/sh

# Remove old Docker containers
docker -H tcp://127.0.0.1:2375 ps -a | \
       egrep 'Dead|Exited' | \
       sed 's@ .*@@' | \
       xargs --no-run-if-empty docker -H tcp://127.0.0.1:2375 rm

# Kill old gpg-agents
killall -9 gpg-agent

# Remove old Docker build directories
rm -Rf /tmp/docker_build-* /tmp/gpg-*
