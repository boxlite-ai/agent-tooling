---
name: pr-author-review
used-by: .agents/lib/pr-author-review.sh
placeholders: result, author, sha, review_question
description: GitHub author-review comment for the current PR head.
---

## TL;DR

The PR author must acknowledge the current diff and description before requesting review.

### Author review acknowledgment

{{result}}

@{{author}}: read the current diff and description, then check:

{{review_question}}

Use the form best suited to the change. Check drafts too, and repeat this review
after description edits. Post this as a new PR comment:

```text
/reviewed {{sha}}
```

Unacknowledged PRs are converted to draft. After this check passes, click **Ready for review** when you want reviews.
Only a new, unedited comment from the PR author counts. A new commit requires a new acknowledgment.
This records the author's acknowledgment of the commit, not an automated judgment of the description; maintainer approval is separate.
