#!/usr/bin/env bash
# Builds the vendored Maven repository from pom.xml. Runs once, at image
# build time, with network access; the result is a plain file:// Maven
# repository that the image's global settings.xml points Maven at.
#
#   build-repo.sh <maven-vendor-dir> <out-repo> [--update-checksums]
#
# 1. Builds the project in <maven-vendor-dir> (`mvn package`) online, with
#    an empty local repository and strict checksums, so every artifact is
#    checked against Maven Central's published .sha1 as it downloads.
# 2. Copies what that downloaded into <out-repo> in the standard layout,
#    without the local-repository bookkeeping (_remote.repositories,
#    *.lastUpdated, maven-metadata-central.xml...), and writes a .sha1 and
#    .md5 beside every file, as a remote repository has.
# 3. Writes group metadata for the vendored plugins, so plugin prefixes
#    (`mvn protobuf:compile`, `mvn antrun:run`) resolve offline.
# 4. Checks every file against checksums.sha256 (SHA-256, pinned in git):
#    a changed or extra artifact fails the build. --update-checksums
#    rewrites checksums.sha256 instead, after changing pom.xml.
# 5. Builds the project again with a fresh local repository and every
#    repository mirrored to <out-repo>, so nothing can come from the
#    network: the build fails unless the whole set resolves offline.
set -euo pipefail

vendor_dir="${1:?usage: build-repo.sh <maven-vendor-dir> <out-repo> [--update-checksums]}"
out="${2:?usage: build-repo.sh <maven-vendor-dir> <out-repo> [--update-checksums]}"
update=0
[[ "${3:-}" == "--update-checksums" ]] && update=1
vendor_dir="$(cd "$vendor_dir" && pwd)"
manifest="$vendor_dir/checksums.sha256"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A copy of the project, so target/ never lands in <maven-vendor-dir>.
copy_project() {
    rm -rf "$work/project"
    mkdir -p "$work/project"
    cp -r "$vendor_dir/pom.xml" "$vendor_dir/src" "$work/project/"
}

# Global settings with nothing but Central (step 1), or with everything
# mirrored to <out-repo> (step 5). -gs keeps the image's own settings.xml,
# which may already point at <out-repo>, out of it.
cat > "$work/settings-online.xml" <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"/>
EOF
cat > "$work/settings-offline.xml" <<EOF
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">
  <mirrors>
    <mirror>
      <id>vendored-only</id>
      <mirrorOf>*</mirrorOf>
      <url>file://$out</url>
    </mirror>
  </mirrors>
</settings>
EOF

mvn_build() {  # <settings> <local-repo>
    copy_project
    mvn -B -ntp --strict-checksums \
        -gs "$1" -s "$1" -Dmaven.repo.local="$2" \
        -f "$work/project/pom.xml" package
}

echo "==> Resolving the vendored set online"
mvn_build "$work/settings-online.xml" "$work/stage"

echo "==> Writing $out"
rm -rf "$out"
mkdir -p "$out"
(
    cd "$work/stage"
    find . -type f \
        ! -name _remote.repositories ! -name '*.lastUpdated' \
        ! -name resolver-status.properties ! -name 'maven-metadata-*.xml' \
        ! -name '*.sha1' ! -name '*.md5' \
        ! -path './rhel9dev/vendor/*' \
        -printf '%P\n' |
    while read -r f; do
        mkdir -p "$out/$(dirname "$f")"
        cp "$f" "$out/$f"
    done
)

# Group metadata (<group>/maven-metadata.xml) listing each vendored plugin's
# goal prefix, read from its plugin descriptor.
declare -A group_plugins=()
while read -r jar; do
    rel="${jar#"$out"/}"                         # g/r/o/u/p/artifact/version/artifact-version.jar
    vdir="$(dirname "$rel")"; adir="$(dirname "$vdir")"; gdir="$(dirname "$adir")"
    artifact="$(basename "$adir")"
    [[ "$(basename "$rel")" == "$artifact-$(basename "$vdir").jar" ]] || continue
    grep -q '<packaging>maven-plugin</packaging>' "${jar%.jar}.pom" 2>/dev/null || continue
    descriptor="$(unzip -p "$jar" META-INF/maven/plugin.xml 2>/dev/null)" || continue
    prefix="$(sed -n 's:.*<goalPrefix>\(.*\)</goalPrefix>.*:\1:p' <<<"$descriptor" | head -n1)"
    name="$(sed -n 's:^  <name>\(.*\)</name>.*:\1:p' <<<"$descriptor" | head -n1)"
    [[ -n "$prefix" ]] || continue
    group_plugins["$gdir"]+="    <plugin><name>${name:-$artifact}</name><prefix>$prefix</prefix><artifactId>$artifact</artifactId></plugin>"$'\n'
done < <(find "$out" -name '*.jar' | sort)
for gdir in "${!group_plugins[@]}"; do
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<metadata>'
        echo '  <plugins>'
        printf '%s' "${group_plugins[$gdir]}" | sort -u
        echo '  </plugins>'
        echo '</metadata>'
    } > "$out/$gdir/maven-metadata.xml"
done

echo "==> Checking against $manifest"
actual="$work/checksums.sha256"
(cd "$out" && find . -type f -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$actual"
if [[ "$update" -eq 1 ]]; then
    cp "$actual" "$manifest"
    echo "Wrote $manifest ($(wc -l < "$manifest") files)"
elif ! diff -u "$manifest" "$actual"; then
    echo "error: the resolved artifacts don't match checksums.sha256 (lines with - are pinned," >&2
    echo "       + are what was downloaded). If pom.xml changed on purpose, run" >&2
    echo "       build-repo.sh with --update-checksums and commit the new checksums.sha256." >&2
    exit 1
fi

# Remote-repository checksum files, for Maven's own verification.
find "$out" -type f ! -name '*.sha1' ! -name '*.md5' -print0 |
while IFS= read -r -d '' f; do
    sha1sum < "$f" | cut -d' ' -f1 > "$f.sha1"
    md5sum  < "$f" | cut -d' ' -f1 > "$f.md5"
done

echo "==> Building again from $out alone"
mvn_build "$work/settings-offline.xml" "$work/offline"

chmod -R a+rX "$out"
echo "==> $out: $(find "$out" -type f ! -name '*.sha1' ! -name '*.md5' | wc -l) files, $(du -sh "$out" | cut -f1)"
