# Vendored npm packages

The console UI is developed where there is no npm registry, so every npm
package it may use is vendored into the image. In the container, `npm` and
`pnpm` talk to a small registry that serves only these packages, so they
install offline exactly as they would online, and anything not vendored
fails at once with a 404 that says so.

| File | What it is |
| --- | --- |
| `package.json` | The vendored packages, at exact versions: the catalog projects pick from |
| `pnpm-lock.yaml` | Their whole dependency tree, pinned (917 package versions) |
| `pnpm-workspace.yaml` | `minimumReleaseAge`: only versions at least 14 days old get vendored |
| `build-registry.mjs` | Image build step: fetches every package's registry entry and tarball, checks each against the lockfile's hash, writes `/opt/npm-registry` |
| `serve.mjs` | Serves `/opt/npm-registry` on `127.0.0.1`; the entrypoint starts it |

## What's vendored

The packages that the *Java WebSocket Bridge — Design Proposal* calls for,
plus what they need to build and test:

- **UI runtime:** react, react-dom, @mantine/core, hooks and notifications,
  dockview, @bufbuild/protobuf, @dnd-kit (core, sortable, utilities),
  d3-scale, @tanstack/react-table and react-virtual, ajv (+ ajv-formats),
  zustand, regl, uplot, deck.gl as its separate packages (core, layers,
  react, mapbox for MapLibre, geo-layers, aggregation-layers), maplibre-gl,
  react-map-gl, pmtiles, three, @tabler/icons-react, lucide-react, and the
  Inter font (@fontsource-variable/inter).
- **Build and test:** typescript, vite, @vitejs/plugin-react, vitest
  (+ coverage), jsdom, Testing Library, storybook with @storybook/react-vite
  (+ docs, a11y), @playwright/test **1.64.1** (the version whose browsers
  are in the image), @bufbuild/buf and protoc-gen-es, CycloneDX for npm, a
  license checker, eslint with typescript-eslint and the React plugins,
  prettier, postcss with Mantine's presets, and @types for react, node,
  d3-scale and three.

The `deck.gl` all-in-one package is left out on purpose: it pulls in Esri's
`@arcgis/core` and amCharts, which this project doesn't use. Import from the
`@deck.gl/*` packages instead.

## Using it in a project

Use the versions in `package.json` here (also at
`/opt/npm-vendor/package.json` in the container). Ranges work too, since the
registry only offers vendored versions, so `pnpm add zustand` picks the
vendored one. Commit your project's `pnpm-lock.yaml` as usual.

- Only linux x64 builds of packages with native binaries (esbuild,
  rollup, buf...) are vendored, because the container is where builds run.
- A project `.npmrc` that sets `registry=` overrides the vendored registry;
  leave it out.
- On a connected machine, use the public registry instead by starting the
  container with `-e npm_config_registry=https://registry.npmjs.org/`.

## Adding or updating packages

On a connected machine, in the container, with the public registry:

```
cd npm-vendor
export pnpm_config_registry=https://registry.npmjs.org/
pnpm add --save-exact --ignore-scripts <package>          # or -D for build tools
pnpm update --save-exact --ignore-scripts <package>@<ver> # to update one
```

Then rebuild the image. Keep `@playwright/test` at the image's
`PLAYWRIGHT_VERSION`. The image build fails if anything in the lockfile
can't be fetched or doesn't match its hash, and it ends by installing the
whole set through the vendored registry alone, so a successful build means
everything here installs offline.
