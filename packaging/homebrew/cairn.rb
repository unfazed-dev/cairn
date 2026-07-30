# Homebrew formula template for the `cairn` CLI.
#
# Tap flow (deliberately manual, not CI-pushed — matches the plan's
# "don't over-automate" call on the pub.dev/manifest side too):
#   1. Operator creates a `unfazed-dev/homebrew-cairn` tap repo
#      (https://github.com/unfazed-dev/homebrew-cairn), containing a
#      `Formula/cairn.rb` copied from this template.
#   2. After each `.github/workflows/release.yml` run, an operator (or,
#      later, a follow-up CI job once the tap repo exists and a push
#      credential is provisioned for it) fills in the `url`/`sha256`
#      placeholders below from that tag's release assets and commits to the
#      tap repo directly — Homebrew taps don't have a PR-review convention
#      the way this repo does, and formula updates are small/mechanical
#      enough that automating that *last* step later is low-risk. What's
#      NOT wanted is `release.yml` reaching into a *different* repo's git
#      history on every tag before a human has looked at a single release.
#   3. Users then: `brew tap unfazed-dev/cairn && brew install cairn`.
#
# Archive naming/hash source: .github/workflows/release.yml's
# cli-server-macos and cli-server-linux jobs, which publish
# `cairn-<target-triple>.tar.gz` + a `.sha256` sidecar per target. Each
# archive contains both `cairn` and `cairn-server`; this formula only
# installs `cairn` (the CLI) — `cairn-server` is the fan-out server binary,
# out of scope for a developer-machine CLI install.
class Cairn < Formula
  desc "Local-first sync engine CLI — init/dev/doctor/deploy for a Postgres + Supabase sync backend"
  homepage "https://github.com/unfazed-dev/cairn"
  version "0.1.0" # bump alongside workspace.package.version in the root Cargo.toml
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/unfazed-dev/cairn/releases/download/v0.1.0/cairn-aarch64-apple-darwin.tar.gz"
      sha256 "REPLACE_WITH_aarch64-apple-darwin_TAR_GZ_SHA256"
    end
    on_intel do
      url "https://github.com/unfazed-dev/cairn/releases/download/v0.1.0/cairn-x86_64-apple-darwin.tar.gz"
      sha256 "REPLACE_WITH_x86_64-apple-darwin_TAR_GZ_SHA256"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/unfazed-dev/cairn/releases/download/v0.1.0/cairn-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "REPLACE_WITH_x86_64-unknown-linux-gnu_TAR_GZ_SHA256"
    end
  end

  def install
    # Each archive unpacks to a `cairn-<target-triple>/` directory (see
    # release.yml's Package step) containing both binaries; only the CLI
    # ships in this formula.
    bin.install Dir["cairn-*/cairn"].first => "cairn"
  end

  test do
    assert_match "cairn", shell_output("#{bin}/cairn --version")
  end
end
