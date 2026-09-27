# Input: GitHub comparison JSON. Output: validated {base, head, lines} snapshot.
# Filename -> boolean: true excludes a recognized non-code file from the cap.
def non_code:
  ascii_downcase | split("/")[-1] |
  if test("\\A(cmakelists\\.txt|(requirements|constraints).*\\.txt)\\z") then false
  else
  test("\\.(md|markdown|rst|adoc|asciidoc|txt|textile|org|tex|bib|rtf)\\z")
  or test("\\.(csv|tsv|jsonl|ndjson|log|snap|svg|png|jpe?g|gif|webp|ico|avif|bmp|tiff?|pdf)\\z")
  or test("\\.(woff2?|ttf|otf|eot|mp3|mp4|wav|ogg|webm|zip|gz|tar|7z|lock|lockb)\\z")
  or test("\\A(readme|license|licence|copying|notice|authors|contributors|changelog)\\z")
  or test("\\A(package-lock\\.json|npm-shrinkwrap\\.json|pnpm-lock\\.yaml|go\\.sum)\\z")
  end;

def count: type == "number" and . >= 0 and . <= 1000000000 and floor == .;
def path: type == "string" and length > 0 and (test("[\u0000\r\n]") | not);

# Validate before excluding files: filtering must not hide malformed evidence.
if (.files | type) != "array" or (.files | length) >= 300
  or any(.files[];
    (.filename | path | not) or (.additions | count | not) or (.deletions | count | not)
    or (has("previous_filename") and (.previous_filename | path | not))
    or (.status == "renamed" and (has("previous_filename") | not)))
  or (($base | test("^[0-9a-f]{40}$")) and .base_commit.sha != $base)
then error("incomplete comparison")
else {
  base: .base_commit.sha, head: $head,
  lines: ([.files[] | select(
    (.filename | non_code | not)
    or (has("previous_filename") and (.previous_filename | non_code | not)))
    | .additions + .deletions] | add // 0)
} end
