#!/bin/bash

until docker exec -u git ${GITEA_SERVER_NAME} gitea --config /data/gitea/conf/app.ini actions generate-runner-token >/dev/null 2>&1; do
    sleep 5
done

export GITEA_RUNNER_REGISTRATION_TOKEN=`docker exec -u git ${GITEA_SERVER_NAME} gitea --config /data/gitea/conf/app.ini actions generate-runner-token`

/opt/act/run.sh
