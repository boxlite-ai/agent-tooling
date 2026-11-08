# Release agent-tooling

## TL;DR

Prepare a versioned snapshot of `dev`, promote it through a reviewed PR to `main`, and publish its GitHub Release manually.

## Prepare

Feature PRs target `dev` after cutover. Use `gh pr create --base dev` or select that base in GitHub.

From a clean release branch, fetch both upstream refs and stage the candidate:

```bash
git fetch origin main dev
git switch -c release/next origin/main
bash .github/release/release.sh prepare
```

`prepare` prints the next version and source SHA, separated by a tab. Use `prepare minor` or `prepare major` for a different bump. Pass a full source SHA after the bump type to select an earlier eligible `dev` snapshot.

Review the staged diff and commit it as one commit. The helper stages the selected source, seven version fields, and `.github/release-source`. Open a release PR to `main` with release notes and obtain the author acknowledgment and separate maintainer approval.

The helper refuses to overwrite an ignored local file when staging the source or writing its receipt.

```bash
bash .github/release/release.sh verify origin/main origin/dev HEAD
make test:release test:parity
```

The required workflow runs the verifier from the stable base. It reads candidate Git objects, checks their parent and source ancestry, and compares their expected contents. If `main` moves, prepare a fresh candidate and review its new head.

Provenance checks use original Git objects and refuse local ancestry grafts.

## Publish manually

Squash the reviewed PR. Consumers following `main` can adopt that commit as soon as it lands. Before tagging, fetch the refs, select the exact merged SHA, and recheck it:

```bash
git fetch origin main dev
promoted="$(git rev-parse origin/main)"
bash .github/release/release.sh verify "$promoted^" origin/dev "$promoted"
```

Use the version returned by the check as `vX.Y.Z`. Check the remote tag and its peeled commit before creating it or reusing it. If it is absent, create it on the reviewed SHA and push the tag without force.

```bash
tag=v0.1.54 # Use the version returned by verify.
git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}"
git tag "$tag" "$promoted"
git push origin "refs/tags/$tag"
```

Recheck the remote tag, then publish the reviewed notes with `gh release create "$tag" --verify-tag --notes-file <file>`. Confirm the release is immutable and its tag still resolves to `promoted`.

After an interruption, reread the release and tag. Retry a transient or unknown error at the same version and commit.

A protected tag at the wrong SHA or a name reserved after immutable release deletion can make publication impossible. Record evidence of the permanent error and leave the old tag untouched. A release maintainer may approve syncing the reviewed `main` commit and publishing the next version, with the stalled version and commit in its notes. [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

## Sync development

After publication or approved recovery, use a clean branch at current `origin/dev`. Fetch both refs before staging, then run `sync` with the reviewed promoted SHA:

```bash
git fetch origin main dev
git switch -c sync-release origin/dev
bash .github/release/release.sh sync "$promoted"
```

The helper stages a merge with stable `main` as the second parent. It applies the release metadata and preserves later `dev` work. Review and test the staged changes, commit, then fetch and compare both upstream refs before a designated maintainer pushes `HEAD:dev` without force.

If either ref moved, prepare the sync again from the current refs. A delayed sync rejects an older promoted commit. An already synced branch reports its version and requires no merge.

Finish sync before preparing another release.

## Cutover

Keep `main` as the default branch so the write-enabled author-review job loads stable code.

1. Land the `0.1.52` release first. Freeze ordinary merges to `main`, then land this tooling with the `0.1.53` bump. Record its commit and version, then create `dev` from that commit. [0.1.52 release PR](https://github.com/boxlite-ai/agent-tooling/pull/435)
2. Require the approved SHA of `.github/workflows/release-candidate.yml` through an organization workflow ruleset on `main`. Require current base, squash merges, author acknowledgment, and separate maintainer review. Block direct updates outside that route.
3. Protect both branches from force pushes and deletion. Require maintainer review for workflow changes on both branches. Use a separate `dev` PR rule with an exemption for designated sync maintainers.
4. Enable immutable releases and restrict creation of version tags to release maintainers. Protect existing tags from updates and deletion in a rule without that exemption. Tag the initial reviewed release.
5. Complete the hosted and native-host rehearsals before retargeting feature PRs. Confirm that a normal feature PR opened with `--base dev` lands on the intended branch.

In a disposable GitHub repository, reject a forged candidate that edits the verifier and check that author review loads the stable copy on a `dev` PR. Test both permanent tag conflicts and a retry at the same SHA. For recovery, confirm the old tag stays intact and the next immutable release points to its reviewed SHA with the recovery note.

On fresh and existing Claude Code and Codex installs, compare installed hook and prompt hashes. A `dev` change should leave stable bytes intact. Promotion should deliver the reviewed bytes on macOS, Linux, and Windows.
