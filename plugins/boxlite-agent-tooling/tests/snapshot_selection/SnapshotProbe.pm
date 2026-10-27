package SnapshotProbe;
use strict;
use warnings;
use JSON::PP;
use Encode qw(encode_utf8);

# Observe real encodings without changing the arguments, result, or selection.
my $encode = \&JSON::PP::encode;
{
    no warnings 'redefine';
    *JSON::PP::encode = sub {
        my $output = $encode->(@_);
        my $value = $_[1];
        if (ref($value) eq 'HASH'
            && ($value->{type} // '') eq 'verdict_final_turn_snapshot') {
            open my $log, '>>', $ENV{SNAPSHOT_PROBE_LOG} or die $!;
            print {$log} join(' ', $value->{evidence_summary}{retained},
                $value->{truncated} ? 1 : 0, length(encode_utf8($output)) + 1), "\n";
            close $log or die $!;
        }
        return $output;
    };
}
1;
