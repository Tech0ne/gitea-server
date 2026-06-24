alias r := run
alias c := clean

set dotenv-filename := "configs/settings.env"
set dotenv-required := true

[doc("Choose one available receipe")]
default:
    @{{ just_executable() }} --choose

[arg("detach", long="detach", short="d", value="--detach", help="runs the docker network in detach mode, in the \"background\"")]
[doc("run the software, after checking that all required configs have been done correctly")]
run detach="":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ "$RUNNER_REGISTRATION_TOKEN" = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]; then
        (
            echo "{{ style("error") }}error{{ NORMAL }}: \$RUNNER_REGISTRATION_TOKEN env variable has it's default value"
            echo "       this is a serious security concern and should not be ignored"
            echo "       you can edit it on the {{ style("command") }}configs/settings.env{{NORMAL}} file. you can use the following command to generate a random value"
            echo "       {{ style("command") }}python3 -c 'import hashlib,os;print(hashlib.sha256(os.urandom(64)).hexdigest()[:40])'{{ NORMAL }}"
        ) >&2
        exit 1
    fi

    if [ "$GITEA_ADMIN_PASSWORD" = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]; then
        (
            echo "{{ style("error") }}error{{ NORMAL }}: \$GITEA_ADMIN_PASSWORD env variable has it's default value"
            echo "       this is a serious security concern and should not be ignored"
            echo "       you can edit it on the {{ style("command") }}configs/settings.env{{NORMAL}} file. you can use the following command to generate a random value"
            echo "       {{ style("command") }}python3 -c 'import hashlib,os;print(hashlib.md5(os.urandom(64)).hexdigest())'{{ NORMAL }}"
        ) >&2
        exit 1
    fi

    if [ "$POSTGRES_PASSWORD" = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]; then
        (
            echo "{{ style("error") }}error{{ NORMAL }}: \$GITEA_ADMIN_PASSWORD env variable has it's default value"
            echo "       this is a serious security concern and should not be ignored"
            echo "       you can edit it on the {{ style("command") }}configs/settings.env{{NORMAL}} file. you can use the following command to generate a random value"
            echo "       {{ style("command") }}python3 -c 'import hashlib,os;print(hashlib.md5(os.urandom(64)).hexdigest())'{{ NORMAL }}"
        ) >&2
        exit 1
    fi
    
    if [ "${#RUNNER_REGISTRATION_TOKEN}" -ne 40 ]; then
        (
            echo "{{ style("error") }}error{{ NORMAL }}: \$RUNNER_REGISTRATION_TOKEN must be exactly 40 characters (got ${#RUNNER_REGISTRATION_TOKEN})."
            echo "       this is a fatal error which cannot be recovered"
            echo "       you can edit it on the {{ style("command") }}configs/settings.env{{NORMAL}} file. you can use the following command to generate a random value"
            echo "       {{ style("command") }}python3 -c 'import hashlib,os;print(hashlib.sha256(os.urandom(64)).hexdigest()[:40])'{{ NORMAL }}"
        ) >&2
        exit 1
    fi

    [[ ! -r /var/run/docker.sock ]] && { exec sudo {{ just_executable() }} {{ recipe_name() }} {{ detach }}; }
    docker compose down -t3 --rmi local -v
    set +e
    docker compose up {{ detach }}
    set -e
    if [ -z "{{ detach }}" ]; then
        docker compose down -t3 --rmi local -v
    fi

[doc("Remove any running instance of the software")]
clean:
    #!/usr/bin/env bash
    set -euo pipefail

    [[ ! -r /var/run/docker.sock ]] && { exec sudo {{ just_executable() }} {{ recipe_name() }}; }
    docker compose down -t3 --rmi local -v
