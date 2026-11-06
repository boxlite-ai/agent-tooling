# Shell reference sources

## TL;DR

Complete licensed snapshots support selective shell guidance; original licenses, source links, revisions, and hashes accompany every copied file.

## Use

Read [Google](google/shellguide.md) for Bash or the shell section of
[Git](git/CodingGuidelines) for portable `sh`; load other sources by topic.
Repository requirements and supported runtimes override incompatible upstream conventions.

These are complete source files, not excerpts; prose, examples, and links are unchanged.
Git's full document also contains other languages; only its shell guidance applies here.
Tool copies cover the README and manual, not the entire tool repository or wiki.
Relative links retain their upstream meaning and may need network access; use the
pinned source links below to follow them in their original context.

## Copies and attribution

Retrieved 2026-11-06; each upstream work retains its own terms, separate from the repository's MIT license.

| Source and authors | Complete local files | Terms |
| --- | --- | --- |
| Google, Google Style Guides contributors | [Guide](google/shellguide.md), [README](google/README.md) | [CC BY 3.0](google/LICENSE); examples [Apache 2.0](google/APACHE-2.0.txt), as stated in the README |
| Git contributors | [CodingGuidelines](git/CodingGuidelines) | [COPYING](git/COPYING), GPL v2 unless otherwise stated |
| bash-completion contributors | [Style guide](bash-completion/styleguide.md) | [COPYING](bash-completion/COPYING), GPL v2 text |
| ChromiumOS / The Chromium Authors | [Shell guidelines](chromiumos/shell.md) | [CC BY 2.5 notice](chromiumos/LICENSE.md); examples [BSD](chromiumos/BSD-LICENSE) |
| Vidar Holen and ShellCheck contributors | [README](shellcheck/README.md), [manual](shellcheck/shellcheck.1.md) | [GPL v3 text](shellcheck/LICENSE); manual permits v3 or later |
| Daniel Martí and mvdan/sh contributors | [README](shfmt/README.md), [manual](shfmt/shfmt.1.scd) | [BSD 3-Clause](shfmt/LICENSE) |

| Upstream | Pinned source |
| --- | --- |
| Google | [0917409e4ed99f65d535f00f08342dc66a4d735e](https://github.com/google/styleguide/blob/0917409e4ed99f65d535f00f08342dc66a4d735e/shellguide.md) |
| Git | [0ffa3e35c7c82ab8d0de226149fb03b3f7674d05](https://github.com/git/git/blob/0ffa3e35c7c82ab8d0de226149fb03b3f7674d05/Documentation/CodingGuidelines) |
| bash-completion | [5ffa3d71c7f1f77f44dd9b37abf71570a61583ed](https://github.com/scop/bash-completion/blob/5ffa3d71c7f1f77f44dd9b37abf71570a61583ed/doc/styleguide.md) |
| Chromium website | [d8303f620f61ba5c155466d46501d1c3e096c699](https://chromium.googlesource.com/website/+/d8303f620f61ba5c155466d46501d1c3e096c699/site/chromium-os/developer-library/reference/style-guides/shell/index.md) |
| ShellCheck | [e11f964f6f2cb0009dd259ec33d563c45aa3453d](https://github.com/koalaman/shellcheck/tree/e11f964f6f2cb0009dd259ec33d563c45aa3453d) |
| shfmt | [5943e49d40d22467e60056a0f39ba58fb8fc767a](https://github.com/mvdan/sh/tree/5943e49d40d22467e60056a0f39ba58fb8fc767a) |

[sources.json](sources.json) records per-file origin, revision, encoding, byte count,
and SHA-256, including the separately pinned Chromium BSD license and Apache license text.

## Apply selectively

- Google assumes Bash availability; establish the interpreter/version and deployment environment before adopting its conventions.
- Git uses tabs and conservative shell constructs; reuse portability reasoning without imposing its style on existing Bash projects.
- bash-completion targets interactive completion; its helpers and shell-option assumptions are not general script requirements.
- ChromiumOS requires POSIX syntax under `#!/bin/sh`, yet some examples use `[[ … ]]` and `local`; validate against the declared interpreter.
- ChromiumOS' SDK-specific `shflags` dependency and `eval` examples do not authorize adding dependencies or weakening this skill's `eval` restriction.
- ShellCheck checks diagnostics; shfmt checks formatting; neither certifies runtime behavior or platform compatibility.

## External references

| Reference | Use and copying status |
| --- | --- |
| [UNSW shell guide](https://cgi.cse.unsw.edu.au/~cs2041/26T2/resources/shell_style_guide.html) | POSIX teaching examples; attributes Google's CC BY 3.0 material without establishing blanket permission for the complete adaptation, so no full copy is included. |
| [Wooledge BashPitfalls](https://mywiki.wooledge.org/BashPitfalls) | Common failure explanations; [the wiki](https://mywiki.wooledge.org/EnglishFrontPage) explicitly identifies missing contributor licenses, so no full copy is included. |
| [Wooledge BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105) | Context-dependent `set -e` behavior; external for the same licensing reason. |
| [GNU Bash manual](https://www.gnu.org/software/bash/manual/bash.html) | Authoritative Bash behavior; retained external reference from the original skill. |

UNSW's `dash` execution proxy is not proof of POSIX conformance or cross-platform compatibility.
Add complete UNSW or Wooledge copies only after obtaining applicable redistribution permission.

## Refresh and verify

1. Choose immutable upstream revisions; inspect source-specific licenses and notices before copying.
2. Download complete source files and licenses; decode Gitiles' base64 transport without changing the resulting bytes.
3. Update the attribution, revisions, and each manifest record; keep local application guidance outside upstream snapshots.
4. Compare local byte counts and SHA-256 digests with the manifest and original downloads; check index and skill links.
5. Run skill validation, writing ownership, host parity, architecture, guidance sync, and diff checks from the repository root.
