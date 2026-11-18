# Vendored Maven artifacts

Projects are built where there is no Maven repository, so the Maven
artifacts they need that their own repository doesn't carry are vendored
into the image, as a plain read-only Maven repository at `/opt/maven-repo`.
The image's global `settings.xml` puts it ahead of Maven Central for
dependencies and plugins, so these resolve offline with no project changes.

| File | What it is |
| --- | --- |
| `pom.xml` | A project that uses every vendored artifact, at pinned versions: what gets vendored is what building it downloads |
| `src/main/proto/` | The `.proto` it compiles, to exercise protoc and protobuf-java |
| `checksums.sha256` | SHA-256 of every file in `/opt/maven-repo` (286 files), pinned |
| `build-repo.sh` | Image build step: resolves `pom.xml` online, writes `/opt/maven-repo`, checks it against `checksums.sha256`, and rebuilds the project from it alone |
| `settings.xml` | The image's `/etc/maven/settings.xml`: adds `/opt/maven-repo` as repository `rhel9-dev-vendored` |

## What's vendored

| Artifact | Version | For |
| --- | --- | --- |
| `com.google.protobuf:protobuf-java` | 4.36.2 | The protobuf 4.x Java runtime |
| `com.google.protobuf:protoc:exe:linux-x86_64` | 4.36.2 | The matching protoc, as protobuf-maven-plugin fetches it |
| `org.xolstice.maven.plugins:protobuf-maven-plugin` | 0.6.1 | pom-driven protobuf code generation |
| `kr.motd.maven:os-maven-plugin` | 1.7.1 | The build extension that sets `${os.detected.classifier}` |
| `org.apache.maven.plugins:maven-antrun-plugin` | 3.1.0 | antrun-driven codegen, with Ant 1.10.12 (`ant`, `ant-launcher`), plexus-utils 3.4.1 and the rest of its dependencies |
| maven-resources/compiler/surefire/jar plugins | 3.3.1 / 3.13.0 / 3.5.3 / 3.4.2 | Maven's default lifecycle for a jar project |

plus every parent POM, BOM and dependency these need. The system `protoc`
(3.15.6, `/usr/local/bin/protoc`) is separate and unchanged.

## Using it in a project

```xml
<dependency>
  <groupId>com.google.protobuf</groupId>
  <artifactId>protobuf-java</artifactId>
  <version>4.36.2</version>
</dependency>
...
<build>
  <extensions>
    <extension>
      <groupId>kr.motd.maven</groupId>
      <artifactId>os-maven-plugin</artifactId>
      <version>1.7.1</version>
    </extension>
  </extensions>
  <plugins>
    <plugin>
      <groupId>org.xolstice.maven.plugins</groupId>
      <artifactId>protobuf-maven-plugin</artifactId>
      <version>0.6.1</version>
      <configuration>
        <protocArtifact>com.google.protobuf:protoc:4.36.2:exe:${os.detected.classifier}</protocArtifact>
      </configuration>
      <executions><execution><goals><goal>compile</goal></goals></execution></executions>
    </plugin>
  </plugins>
</build>
```

`pom.xml` here is a complete working example.

- Use exactly these versions: the repository holds only them, and Maven
  goes to Central (and fails, offline) for any other.
- Maven copies what it resolves from `/opt/maven-repo` into the local
  repository as usual (`~/.m2/repository`, or wherever the project points
  `maven.repo.local`).
- `-s <file>` and `~/.m2/settings.xml` merge with the image's settings and
  keep this repository. A mirror of everything (`<mirrorOf>*</mirrorOf>`)
  redirects it too: make that `*,!rhel9-dev-vendored`. To list the
  repository explicitly instead (e.g. in a project's own settings), its URL
  is `file:///opt/maven-repo`.
- To copy artifacts out of the image into another repository, e.g. a
  git-tracked one, copy them from `/opt/maven-repo` (standard layout, with
  `.sha1` and `.md5` beside each file).

## Adding or updating artifacts

On a connected machine, in the container:

1. Change `pom.xml`: add the dependency or plugin, used in the build so
   that Maven really resolves it (a plugin needs an execution).
2. Rewrite the checksums:
   `maven-vendor/build-repo.sh maven-vendor /tmp/maven-repo --update-checksums`
3. Review the `checksums.sha256` diff, commit both, and rebuild the image.

Every download is checked against Central's published SHA-1
(`--strict-checksums`), and every build of the image against
`checksums.sha256`, so a changed upstream artifact fails the build rather
than slipping in.
