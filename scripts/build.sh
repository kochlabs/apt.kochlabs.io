#!/usr/bin/env bash
# Builds the Kochlabs apt repository into public/.
#
# For each line of sources.conf it downloads the newest releases' .deb files
# from GitHub, checks them against the release's SHA256SUMS and its build
# attestation (made by that repository's release workflow), then writes the
# apt index for suite "stable", component "main", and signs it.
#
# Environment:
#   APT_SIGNING_KEY         the signing subkey (armored, from gpg --export-secret-subkeys)
#   APT_SIGNING_PASSPHRASE  its passphrase, if it has one
#   GH_TOKEN                for the GitHub API (any token; the sources are public)
#
#   scripts/build.sh                 build from GitHub releases
#   scripts/build.sh --local DIR     build from the .deb files in DIR, skipping
#                                    downloads and attestations (for testing)
set -euo pipefail
cd "$(dirname "$0")/.."

SUITE=stable
COMPONENT=main
ARCHES=amd64
PUBLIC_KEY=keys/kochlabs-apt.asc
OUT=public
WORK=work

LOCAL=
if [[ ${1:-} == --local ]]; then
  LOCAL=${2:?usage: $0 --local DIR}
fi

die() { echo "build.sh: $*" >&2; exit 1; }

[[ -s $PUBLIC_KEY ]] || die "$PUBLIC_KEY is missing: commit the repository's public key first"
[[ -n ${APT_SIGNING_KEY:-} ]] || die "APT_SIGNING_KEY is not set"

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK/downloads"

# ---- signing key, in a throwaway keyring ----
export GNUPGHOME=$PWD/$WORK/gnupg
install -d -m 700 "$GNUPGHOME"
gpg --batch --quiet --import <<< "$APT_SIGNING_KEY"
gpg --batch --quiet --import "$PUBLIC_KEY"
FPR=$(gpg --batch --with-colons --show-keys "$PUBLIC_KEY" | awk -F: '$1 == "fpr" { print $10; exit }')
[[ -n $FPR ]] || die "no key in $PUBLIC_KEY"
# The signing key must belong to the published key, or nobody could verify.
gpg --batch --list-secret-keys "$FPR" >/dev/null 2>&1 || die "APT_SIGNING_KEY is not a key of $FPR"
sign() { # sign <gpg options...>
  local pass=()
  [[ -n ${APT_SIGNING_PASSPHRASE:-} ]] && pass=(--pinentry-mode loopback --passphrase-fd 3)
  gpg --batch --yes --digest-algo SHA512 --local-user "$FPR" "${pass[@]}" "$@" 3<<< "${APT_SIGNING_PASSPHRASE:-}"
}

# ---- packages ----
add_deb() { # add_deb <file> <expected package name>
  local f=$1 want=$2 name arch
  name=$(dpkg-deb -f "$f" Package)
  arch=$(dpkg-deb -f "$f" Architecture)
  [[ $name == "$want" ]] || die "$(basename "$f") is package '$name', expected '$want'"
  [[ " $ARCHES all " == *" $arch "* ]] || die "$(basename "$f") is for $arch"
  install -D -m 644 "$f" "$OUT/pool/$COMPONENT/${name:0:1}/$name/$(basename "$f")"
  echo "  + $(basename "$f")"
}

if [[ -n $LOCAL ]]; then
  echo "==> using local packages from $LOCAL (no attestation checks)"
  for f in "$LOCAL"/*.deb; do
    [[ -e $f ]] || die "no .deb files in $LOCAL"
    add_deb "$f" "$(dpkg-deb -f "$f" Package)"
  done
else
  command -v gh >/dev/null || die "needs the GitHub CLI (gh)"
  while read -r repo pkg keep; do
    [[ -z $repo || $repo == \#* ]] && continue
    echo "==> $repo ($pkg, newest $keep releases)"
    mapfile -t tags < <(gh release list --repo "$repo" --exclude-drafts --exclude-pre-releases --limit 100 \
      --json tagName,publishedAt --jq 'sort_by(.publishedAt) | reverse | .[].tagName' | head -n "$keep")
    (( ${#tags[@]} )) || { echo "  (no releases yet)"; continue; }
    for tag in "${tags[@]}"; do
      d=$WORK/downloads/$repo/$tag
      mkdir -p "$d"
      gh release download "$tag" --repo "$repo" --dir "$d" --pattern '*.deb' --pattern SHA256SUMS
      (cd "$d" && sha256sum --quiet -c SHA256SUMS --ignore-missing) || die "$repo $tag: checksum mismatch"
      for f in "$d"/*.deb; do
        # Only accept files built by the source repository's release workflow
        # from this tag.
        gh attestation verify "$f" --repo "$repo" \
          --signer-workflow "$repo/.github/workflows/release.yml" \
          --source-ref "refs/tags/$tag" >/dev/null ||
          die "$repo $tag: $(basename "$f") has no valid build attestation"
        add_deb "$f" "$pkg"
      done
    done
  done < sources.conf
fi

# ---- index ----
echo "==> writing the index"
# apt only trusts SHA-256 and stronger; leave out MD5 and SHA-1.
NOWEAK=(-o APT::FTPArchive::MD5=false -o APT::FTPArchive::SHA1=false)
dist=$OUT/dists/$SUITE
for arch in $ARCHES; do
  bin=$dist/$COMPONENT/binary-$arch
  mkdir -p "$bin"
  (cd "$OUT" && apt-ftparchive "${NOWEAK[@]}" --arch "$arch" packages "pool/$COMPONENT") > "$bin/Packages"
  gzip -9nk "$bin/Packages"
  xz -9k "$bin/Packages"
done
(cd "$dist" && apt-ftparchive "${NOWEAK[@]}" \
  -o APT::FTPArchive::Release::Origin=Kochlabs \
  -o APT::FTPArchive::Release::Label=Kochlabs \
  -o APT::FTPArchive::Release::Suite="$SUITE" \
  -o APT::FTPArchive::Release::Codename="$SUITE" \
  -o APT::FTPArchive::Release::Architectures="$ARCHES" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="Kochlabs packages" \
  release .) > "$WORK/Release"
mv "$WORK/Release" "$dist/Release"
sign --clearsign --output "$dist/InRelease" "$dist/Release"
sign --armor --detach-sign --output "$dist/Release.gpg" "$dist/Release"

# Check the signatures the way apt will: against the published key only.
gpg --batch --dearmor < "$PUBLIC_KEY" > "$OUT/kochlabs.gpg"
gpgv --keyring "$OUT/kochlabs.gpg" "$dist/InRelease" 2>/dev/null || die "InRelease does not verify against $PUBLIC_KEY"
gpgv --keyring "$OUT/kochlabs.gpg" "$dist/Release.gpg" "$dist/Release" 2>/dev/null || die "Release.gpg does not verify"
if command -v sqv >/dev/null; then # apt 3's verifier, stricter about algorithms
  sqv --keyring "$OUT/kochlabs.gpg" --cleartext --output "$WORK/InRelease.verified" "$dist/InRelease" >/dev/null || die "InRelease is rejected by sqv"
  sqv --keyring "$OUT/kochlabs.gpg" --signature-file "$dist/Release.gpg" "$dist/Release" >/dev/null || die "Release.gpg is rejected by sqv"
fi

# ---- site ----
cp "$PUBLIC_KEY" "$OUT/kochlabs.asc"
FPR_SPACED=$(sed -E 's/(.{4})/\1 /g; s/ $//' <<< "$FPR")
sed -e "s|@FINGERPRINT@|$FPR_SPACED|g" site/index.html > "$OUT/index.html"
cp site/style.css "$OUT/"
touch "$OUT/.nojekyll"

echo "==> done: $(find "$OUT/pool" -name '*.deb' | wc -l) packages, signed by $FPR"
