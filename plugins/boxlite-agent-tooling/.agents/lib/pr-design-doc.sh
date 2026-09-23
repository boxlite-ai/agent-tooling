#!/usr/bin/env bash
# PR document-link facade over literal argv already validated by the shell scanner.
# Requires design-doc.sh, git, gh, jq and perl; prints a denial reason on failure.

pr_design_doc_check() { # root, create|edit|ready, validated gh PR arguments
  local root="$1" operation="$2" token body="" count=0 selector="" url response
  shift 2
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --body|-b)
        (( $# )) || return 1
        body="$1"; shift; count=$((count+1)) ;;
      --body=*|-b=*) body="${token#*=}"; count=$((count+1)) ;;
      -b?*) body="${token#-b}"; count=$((count+1)) ;;
      --title|-t|--base|-B|--head|-H|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|--add-assignee|--add-label|--add-project|--add-reviewer|--remove-assignee|--remove-label|--remove-project|--remove-reviewer)
        (( $# )) || return 1
        shift ;;
      --draft|-d|--draft=true|-d=true|--dry-run|--no-maintainer-edit|--remove-milestone|--undo) ;;
      --title=*|--base=*|--head=*|--assignee=*|--label=*|--milestone=*|--project=*|--reviewer=*|--add-*=*|--remove-*=*|-t?*|-B?*|-H?*|-a?*|-l?*|-m?*|-p?*|-r?*) ;;
      -*) printf 'The design doc check requires literal inline PR text.'; return 1 ;;
      *) [[ "$operation" != create && -z "$selector" ]] || return 1; selector="$token" ;;
    esac
  done
  if (( count > 1 )) || [[ "$operation" == create && "$count" == 0 ]]; then
    printf 'Supply one PR body containing the registered design doc link.'; return 1
  fi
  url="$(design_doc_binding check "$root")" || {
    printf 'Cannot verify the registered design doc; register a readable document before publishing.'; return 1;
  }
  if (( count == 0 )); then
    # cli/cli pkg/cmd/pr/view/view.go:45-51,78: explicit selectors and JSON fields.
    response="$(perl -e 'alarm 20; exec @ARGV' gh pr view \
      "${selector:-$(git -C "$root" branch --show-current)}" \
      --json body,headRefName,headRefOid | head -c 65537)" || return 1
    (( ${#response} <= 65536 )) || return 1
    body="$(jq -er --arg branch "$(git -C "$root" branch --show-current)" \
      --arg head "$(git -C "$root" rev-parse HEAD)" \
      'select(.headRefName == $branch and .headRefOid == $head) | .body | strings' \
      <<<"$response")" || {
      printf 'Cannot bind the published design doc link to this branch and HEAD.'; return 1;
    }
  fi
  # GitHub owns Markdown semantics; inspect its sanitized HTML, not source tokens.
  # API contract: https://docs.github.com/en/rest/markdown/markdown#render-a-markdown-document
  response="$(perl -e 'alarm 20; exec @ARGV' gh api --hostname github.com markdown \
    -f mode=gfm -f "text=$body" | head -c 65537 | \
    perl -0777 -ne 'length($_) <= 65536 or exit 1; print')" || {
    printf 'Cannot render the PR body to verify its design doc link.'; return 1;
  }
  if ! printf '%s' "$response" | perl -0777 -e '
    my $html = <STDIN> // "";
    my %depth = (pre => 0, code => 0);
    # Preserve nesting and quoted attributes when scanning GitHub-sanitized tags.
    while ($html =~ m{<(/?)([a-z][a-z0-9-]*)\b(?:[^>"\x27]|"[^"]*"|\x27[^\x27]*\x27)*>}g) {
      my ($closing, $name, $tag) = ($1, $2, $&);
      if (exists $depth{$name}) {
        $depth{$name}++ unless $closing;
        $depth{$name}-- if $closing && $depth{$name};
        next;
      }
      next if $closing || $name ne "a" || $depth{pre} || $depth{code};
      exit 0 if $tag =~ /\shref="\Q$ARGV[0]\E"(?=[\s>])/;
    }
    exit 1;
  ' "$url"; then
    printf 'PR must link the registered design doc: %s' "$url"; return 1
  fi
}
