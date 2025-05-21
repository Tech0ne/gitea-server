#!/bin/bash

cp /etc/app.ini /data/gitea/conf/app.ini
chown git:git /data/gitea/conf/app.ini

generate_runner_token () {
    echo "[+] Waiting until gitea server is online"

    until curl -s "http://localhost:3000/api/v1/version"; do
        sleep 2
    done

    if [[ -e /shared/runner-token ]]; then
        echo "[!] Runner token found. Ignoring"
        return 0
    fi

    echo "[+] Gitea server found online. Generating runner token"

    su - git -c "/usr/local/bin/gitea --config /data/gitea/conf/app.ini actions generate-runner-token > /tmp/runner-token"

    cp /tmp/runner-token /shared/runner-token
    rm /tmp/runner-token

    echo "[+] Adding admin user"

        su - git -c "/usr/local/bin/gitea --config /data/gitea/conf/app.ini admin user create --username \"${GITEA_ADMIN_UNAME}\" --password \"${GITEA_ADMIN_PWORD}\" --email \"${GITEA_ADMIN_EMAIL}\" --admin"
}

generate_runner_token &

/usr/bin/s6-svscan /etc/s6
