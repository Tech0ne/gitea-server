#!/bin/bash

while [[ ! -e /shared/runner-token ]]; do
    sleep 1
done

export GITEA_RUNNER_REGISTRATION_TOKEN=$(cat /shared/runner-token)

# /usr/local/bin/dockerd-entrypoint.sh

# /opt/act/rootless.sh

/usr/bin/supervisord -c /etc/supervisord.conf
# su - rootless -c "/usr/bin/supervisord -c /etc/supervisord.conf"
