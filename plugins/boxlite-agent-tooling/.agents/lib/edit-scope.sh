#!/usr/bin/env bash
# Edit-target scope for the pre-edit design gate. Requires perl. Source only.

edit_scope_outside_repositories() { # absolute working directory, newline-separated targets
  # 0 only when every target lies outside every repository, both where it is named
  # and where its links lead: writing follows a link, while deleting or moving one
  # changes the link itself. A dangling last link is judged by its target. A relative
  # working directory, ~ paths, dot segments, a dangling link above the last name and
  # nested .git names return 1 so the caller keeps its gate: a host may expand ~ or
  # resolve dot segments by text, while the kernel follows links first.
  [[ -n "${2:-}" ]] || return 1
  perl -e '
    use strict;
    use warnings;
    use Cwd qw(abs_path);
    use File::Basename qw(basename dirname);
    my ($cwd, $targets) = @ARGV;
    exit 1 unless $cwd =~ m{\A/};
    # A work tree holds .git; a bare or common Git directory holds HEAD, objects and refs.
    sub in_repository {
      for (my $dir = shift; ; $dir = dirname($dir)) {
        return 1 if -e "$dir/.git" || (-f "$dir/HEAD" && -d "$dir/objects" && -d "$dir/refs");
        return 0 if $dir eq dirname($dir);
      }
    }
    # True when the nearest existing directory at or above the path is outside every
    # repository. Absolute paths always reach /, so the walk ends.
    sub outside {
      my $anchor = shift;
      until (-d $anchor) {
        return 0 if -l $anchor || basename($anchor) eq ".git";
        $anchor = dirname($anchor);
      }
      my $real = abs_path($anchor);
      return defined $real && !in_repository($real);
    }
    for my $target (split /\n/, $targets) {
      exit 1 if $target =~ m{\A~};
      $target = "$cwd/$target" unless $target =~ m{\A/};
      for (my $hops = 0; ; $hops++) {
        exit 1 if $hops > 40 || $target =~ m{(?:\A|/)\.\.?(?:/|\z)};
        last unless -l $target;
        exit 1 unless outside(dirname($target));
        defined(my $link = readlink $target) or exit 1;
        $target = $link =~ m{\A/} ? $link : dirname($target) . "/$link";
      }
      exit 1 unless outside($target);
    }
    exit 0;
  ' -- "$1" "$2"
}
