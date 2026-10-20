# Kochlabs apt repository

The apt repository at **https://apt.kochlabs.io**, serving Debian and Ubuntu
packages for Kochlabs projects. Setup instructions for users are on that page
(`site/index.html`).

## How it works

Nothing is stored in this repository but the build: `scripts/build.sh` creates
the whole apt repository from scratch on every run, and the `Publish` workflow
deploys it to GitHub Pages.

For each line of `sources.conf`, the build takes the newest non-pre-release
GitHub releases of that project and, for each package file:

1. checks it against the release's `SHA256SUMS`;
2. verifies its GitHub build attestation: it must have been built by the
   project's own `.github/workflows/release.yml` from that release's tag;
3. checks the package name and architecture.

It then writes the index (suite `stable`, component `main`, SHA-256/SHA-512
checksums), signs it as `InRelease` and `Release.gpg`, and verifies the
signatures with `gpgv` and `sqv` (apt 3's verifier) against
`keys/kochlabs-apt.asc`, so a mismatched key never gets published.

The workflow runs when a project's release workflow sends a `release`
repository dispatch, daily as a backstop, on pushes to `main`, and by hand
(Actions → Publish → Run workflow).

## Signing key

The OpenPGP key has a certification-only primary key, kept offline, and a
signing subkey, which is the only part the workflow has:

| Secret | Contents |
|---|---|
| `APT_SIGNING_KEY` | `gpg --armor --export-secret-subkeys <fingerprint>` |
| `APT_SIGNING_PASSPHRASE` | the key's passphrase (omit if it has none) |

`keys/kochlabs-apt.asc` is the public key that users install; its fingerprint
is printed on the site.

**Renewing the subkey** (it expires after 2 years): with the primary key,
`gpg --quick-set-expire <fingerprint> 2y '*'`, then update
`keys/kochlabs-apt.asc` and the `APT_SIGNING_KEY` secret. Users must fetch the
updated public key; renew well before expiry and say so on the site.

**If the signing subkey leaks:** with the primary key, revoke it
(`gpg --edit-key <fingerprint>`, `key 1`, `revkey`), add a new signing subkey
(`gpg --quick-add-key <fingerprint> ed25519 sign 2y`), update
`keys/kochlabs-apt.asc` and the secret, and publish. Users keep trusting the
same primary key; they just fetch the updated public key.

## Adding a package

The project needs a release workflow at `.github/workflows/release.yml` that
attaches `.deb` files, a `SHA256SUMS` and build attestations to its GitHub
releases (as Tributary's does). Add a line to `sources.conf`, add the package
to the preferences example in `site/index.html`, and push.

## Testing locally

```bash
APT_SIGNING_KEY="$(cat test-subkey.asc)" scripts/build.sh --local path/to/debs/
python3 -m http.server -d public 8099
```

`--local` takes `.deb` files from a directory and skips downloads and
attestation checks; it still needs a signing key matching
`keys/kochlabs-apt.asc`.
