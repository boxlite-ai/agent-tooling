#!/usr/bin/env bash
# Repository gate: current generated guidance and one authoring source for writing.
set -euo pipefail
[[ $# -le 1 ]] || { printf 'usage: check-writing-ownership.sh [repo-root]\n' >&2; exit 2; }
for dependency in git perl; do
  command -v "$dependency" >/dev/null || { printf 'writing ownership: missing %s\n' "$dependency" >&2; exit 2; }
done
repo_root="$(git -C "${1:-.}" rev-parse --show-toplevel)"
plugin_root="$repo_root/plugins/boxlite-agent-tooling"
source_relative='plugins/boxlite-agent-tooling/.agents/prompts/concise-writing.md'
bash "$plugin_root/scripts/sync-guidance.sh" --check-current "$repo_root"
inventory="$(mktemp)"
trap 'rm -f -- "$inventory"' EXIT
# Include untracked Markdown locally; CI scans the same tracked source tree.
git -C "$repo_root" ls-files --cached --others --exclude-standard -z > "$inventory"
perl -CSDA - "$repo_root" "$source_relative" "$inventory" <<'PERL'
use strict;
use warnings;
use open qw(:std :encoding(UTF-8));
my ($root, $owner, $inventory) = @ARGV;
sub read_text {
    open my $file, '<', $_[0] or die "writing ownership: cannot read $_[0]: $!\n";
    local $/;
    return <$file> // '';
}
sub words { return lc($_[0]) =~ /[\p{L}\p{N}_]+/g; }
my $policy = read_text("$root/$owner");
$policy =~ s/\A---\r?\n.*?\r?\n---\r?\n//s;
my @words = words($policy);
my %phrases;
for (my $i = 0; $i + 8 <= @words; $i++) {
    $phrases{join ' ', @words[$i .. $i + 7]} = 1;
}
# Short complete rules also matter; isolated headings and tiny phrases do not.
for my $sentence (split /[.!?](?:\s|\z)|\n/, $policy) {
    my @tokens = words($sentence);
    $phrases{join ' ', @tokens} = 1 if @tokens >= 5 && @tokens < 8;
}
die "writing ownership: canonical source contains no checkable passages\n" unless %phrases;
my $failed = 0;
FILE: for my $path (sort split /\0/, read_text($inventory)) {
    next unless $path =~ /\.md\z/i && $path ne $owner;
    next unless -e "$root/$path";
    my $text = read_text("$root/$path");
    # sync-guidance intentionally skips CLAUDE bridges, so their blocks are unverified.
    my $managed = $path eq 'AGENTS.md' ||
        ($path eq 'CLAUDE.md' && $text !~ /^\@AGENTS\.md(?:\s|$)/m);
    my (@window, @lines);
    my ($fence, $generated, $line_number) = ('', 0, 0);
    for my $line (split /\n/, $text) {
        $line_number++;
        # Only the root instruction files have verified generated-block exemptions.
        if ($managed) {
            $generated = 1 if $line =~ /^<!-- agent-tooling:guidance:begin /;
            if ($generated) {
                $generated = 0 if $line eq '<!-- agent-tooling:guidance:end -->';
                @window = (); @lines = ();
                next;
            }
        }
        if (length $fence) {
            my $marker = substr $fence, 0, 1;
            $fence = '' if $line =~ /^ {0,3}\Q$fence\E\Q$marker\E*\s*$/;
            next;
        }
        if ($line =~ /^ {0,3}(`{3,}|~{3,})/) {
            $fence = $1; @window = (); @lines = (); next;
        }
        for my $word (words($line)) {
            push @window, $word; push @lines, $line_number;
            if (@window > 8) { shift @window; shift @lines; }
            for my $length (5 .. scalar @window) {
                my $start = @window - $length;
                next unless $phrases{join ' ', @window[$start .. $#window]};
                print STDERR "$path:$lines[$start]: copied writing policy; compose or reference $owner\n";
                $failed = 1;
                next FILE;
            }
        }
    }
}
exit $failed;
PERL
