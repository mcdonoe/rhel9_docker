#!/usr/bin/env bash
# Entrypoint of the rhel9-runtime image: starts one Java application whose
# jars are mounted from the host (see install-shared.sh --app).
#
#   run-app MAIN_CLASS [ARGS...]
#   run-app --version          the Java runtime's version
#
# Environment:
#   APP_CLASSPATH   colon-separated folders (every *.jar in each goes on the
#                   classpath, in order) and/or individual .jar files, e.g.
#                   /OUTPUT/web/output_libs:/OUTPUT/web/cots_libs
#   JAVA_OPTS       JVM options, split on spaces, e.g. "-Xmx2g -Dfoo=bar"
set -euo pipefail

die() { echo "run-app: $*" >&2; exit 1; }

if [[ "${1:-}" == --version ]]; then
    exec java -version
fi
[[ $# -ge 1 ]] || die "usage: run-app MAIN_CLASS [ARGS...] (with APP_CLASSPATH set)"
[[ -n "${APP_CLASSPATH:-}" ]] || die "APP_CLASSPATH is not set: the application's jar folders, colon-separated"

cp=""
IFS=: read -ra entries <<<"$APP_CLASSPATH"
for e in "${entries[@]}"; do
    [[ -n "$e" ]] || continue
    if [[ -d "$e" ]]; then
        compgen -G "$e/*.jar" >/dev/null || die "no .jar files in $e"
        cp+="${cp:+:}$e/*"
    elif [[ -f "$e" && "$e" == *.jar ]]; then
        cp+="${cp:+:}$e"
    else
        die "$e doesn't exist in the container: is it mounted, and readable by uid $(id -u)?"
    fi
done
[[ -n "$cp" ]] || die "APP_CLASSPATH has no entries"

echo "run-app: java -cp $cp $*" >&2
# JAVA_OPTS is split on spaces on purpose: it holds several options.
# shellcheck disable=SC2086
exec java ${JAVA_OPTS:-} -cp "$cp" "$@"
