#!/usr/bin/env bash
# Shared lock-state transformations for the verdict runner and its prompt hook.
# Source this file; it performs no work on load.

# One protocol, consumed by both the runner and Stop gate. The runner reserves the
# final minute for group teardown, so its configured model timeout must fit below this
# full lease ceiling rather than publishing a deadline the gate will reject.
# shellcheck disable=SC2034 # Public constants for scripts that source this library.
verdict_audit_lock_max_seconds=3600
# shellcheck disable=SC2034 # Public constants for scripts that source this library.
verdict_audit_deadline_slack_seconds=60

# Persisted decimal fields are untrusted. Keep them below 10^18 so Bash 3's signed
# integer arithmetic cannot wrap a huge value into the live deadline window. The caller
# still enforces its much tighter semantic bound relative to the current epoch.
verdict_audit_epoch_is_bounded() {
  [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 18 ]]
}

# Snapshot workspace state without letting a FIFO, symlink, or replacement pathname
# choose what gets parsed. `record` mode validates the bytes before command substitution
# can erase trailing LFs. `json` mode prefixes the selected inode's mtime, keeping
# freshness and content in one snapshot. Raw NUL cannot be transported through Bash.
verdict_audit_read_regular_state() {  # path max-bytes record|json [device:inode]
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT -e '
    my ($path, $max, $mode, $expected) = @ARGV;
    exit 1 unless $max =~ /^[1-9][0-9]*$/
      && ($mode eq "record" || $mode eq "record_snapshot" || $mode eq "json");
    exit 1 unless $expected eq "" || $expected =~ /\A[0-9]+:[0-9]+\z/;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    exit 1 if $expected ne ""
      && ($opened[0] . ":" . $opened[1]) ne $expected;
    my $body = "";
    while (length($body) <= $max) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, $max + 1 - length($body));
      exit 1 unless defined $count;
      last if $count == 0;
      $body .= $chunk;
    }
    exit 1 if length($body) > $max;
    my @named_after = lstat($path);
    exit 1 unless @named_after
      && $opened[0] == $named_after[0] && $opened[1] == $named_after[1];
    alarm 0;
    exit 1 if $body =~ /\0/;
    if ($mode eq "record" || $mode eq "record_snapshot") {
      exit 1 if $body =~ /\r/;
      $body =~ s/\n\z//;
      exit 1 if $body eq "" || index($body, "\n") >= 0;
      print $opened[9], "\n" if $mode eq "record_snapshot";
      print $body;
    } else {
      print $opened[9], "\n", $body;
    }
  ' "$1" "$2" "$3" "${4:-}"
}

# Writers use one final LF; legacy records without it remain readable, while CR, an
# embedded LF, or a second blank record fails.
verdict_audit_read_single_record() {  # record-path
  verdict_audit_read_regular_state "$1" 4096 record
}

verdict_audit_read_single_record_snapshot() {  # record-path
  verdict_audit_read_regular_state "$1" 4096 record_snapshot
}

# JSON dossiers may be formatted across lines. The caller parses the returned
# "mtime LF body" snapshot from memory and never opens the shared pathname with jq.
verdict_audit_read_json_snapshot() {  # dossier-path
  verdict_audit_read_regular_state "$1" 1048576 json
}

# Size of a path that must still be the plain file the caller created. Ordinary `<`
# redirection cannot be used for this: a path swapped for a FIFO parks the open forever
# and hangs the caller instead of failing it. Same guards as
# verdict_audit_read_regular_state — O_NONBLOCK, O_NOFOLLOW, an lstat before and an
# fstat identity match after, and a one-second alarm — but it reports the size rather
# than the body, so a multi-megabyte file can be measured without being read.
verdict_audit_regular_file_bytes() {  # path -> byte count; non-zero when unsafe
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT -e '
    my ($path) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    alarm 0;
    print $opened[7];
  ' "$1"
}

# Why a completed agent's two output files are unusable, or empty when both are fine:
# `output-state` when either stopped being the plain file the caller created,
# `output-limit` when either reached its ceiling.
#
# A live poller cannot answer this on its own. Its loop ends the moment a status record
# exists, so an agent that crosses a ceiling and exits inside one poll interval is
# never measured, and the ceiling would hold only for writers slow enough to be caught.
# This runs once the process is reaped, when both files are final.
#
# Split out of the caller rather than inlined so it can be tested against a FIFO
# directly. Reached through the caller it is racy to exercise — a poller watching the
# same paths may report first — and that race is a property of the poller, not of this
# decision, which has none.
verdict_audit_output_reason() {  # result-path result-max stderr-path stderr-max
  local result_path="$1" result_max="$2" stderr_path="$3" stderr_max="$4"
  local result_bytes stderr_bytes
  if ! result_bytes="$(verdict_audit_regular_file_bytes "$result_path")" \
     || ! stderr_bytes="$(verdict_audit_regular_file_bytes "$stderr_path")"; then
    printf 'output-state'
    return 0
  fi
  if (( result_bytes >= result_max || stderr_bytes >= stderr_max )); then
    printf 'output-limit'
  fi
}

# Copy one exact regular source inode into a new private regular file. This is the
# binary-safe companion to verdict_audit_read_regular_state: large diffs stay out of
# shell variables, FIFOs/symlinks fail without blocking, and a source changed in place
# or replaced during either verification pass is rejected. The destination must not
# already exist; an incomplete file is removed only while it is still the inode created
# by this call.
verdict_audit_copy_regular_state() {  # source destination max-bytes
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT -MDigest::SHA -e '
    my ($source, $destination, $max) = @ARGV;
    exit 1 unless $max =~ /^[1-9][0-9]*$/;
    $SIG{ALRM} = sub { exit 1 };
    alarm 15;

    exit 1 if lstat($source) && -l _;
    my $read_flags = O_RDONLY | O_NONBLOCK;
    $read_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $input, $source, $read_flags) or exit 1;
    my @source_before = stat($input);
    my @source_named = lstat($source);
    exit 1 unless @source_before && @source_named && -f $input
      && $source_before[0] == $source_named[0]
      && $source_before[1] == $source_named[1]
      && $source_before[7] <= $max;
    my $source_identity = join(":", @source_before[0,1,7,9,10]);

    my $write_flags = O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK;
    $write_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $output, $destination, $write_flags, 0600) or exit 1;
    my @destination_opened = stat($output);
    my @destination_named = lstat($destination);
    my $destination_owned = @destination_opened && @destination_named
      && -f $output
      && $destination_opened[0] == $destination_named[0]
      && $destination_opened[1] == $destination_named[1];
    my $complete = 0;
    END {
      if (!$complete && $destination_owned) {
        my @current = lstat($destination);
        unlink($destination) if @current
          && $current[0] == $destination_opened[0]
          && $current[1] == $destination_opened[1];
      }
    }
    exit 1 unless $destination_owned;
    binmode($input);
    binmode($output);

    my $first_digest = Digest::SHA->new(256);
    my $total = 0;
    while (1) {
      my $chunk = "";
      my $count = sysread($input, $chunk, 65536);
      exit 1 unless defined $count;
      last if $count == 0;
      $total += $count;
      exit 1 if $total > $max;
      $first_digest->add($chunk);
      my $offset = 0;
      while ($offset < $count) {
        my $written = syswrite($output, $chunk, $count - $offset, $offset);
        exit 1 unless defined $written && $written > 0;
        $offset += $written;
      }
    }
    my $first_hash = $first_digest->hexdigest;
    my @source_after = stat($input);
    my @source_named_after = lstat($source);
    exit 1 unless @source_after && @source_named_after
      && join(":", @source_after[0,1,7,9,10]) eq $source_identity
      && $source_after[0] == $source_named_after[0]
      && $source_after[1] == $source_named_after[1]
      && $total == $source_before[7];

    sysseek($input, 0, 0) or exit 1;
    my $verify_digest = Digest::SHA->new(256);
    my $verify_total = 0;
    while (1) {
      my $chunk = "";
      my $count = sysread($input, $chunk, 65536);
      exit 1 unless defined $count;
      last if $count == 0;
      $verify_total += $count;
      exit 1 if $verify_total > $max;
      $verify_digest->add($chunk);
    }
    @source_after = stat($input);
    @source_named_after = lstat($source);
    exit 1 unless @source_after && @source_named_after
      && join(":", @source_after[0,1,7,9,10]) eq $source_identity
      && $source_after[0] == $source_named_after[0]
      && $source_after[1] == $source_named_after[1]
      && $verify_total == $total
      && $verify_digest->hexdigest eq $first_hash;

    close($input) or exit 1;
    close($output) or exit 1;
    @destination_named = lstat($destination);
    exit 1 unless @destination_named
      && $destination_opened[0] == $destination_named[0]
      && $destination_opened[1] == $destination_named[1]
      && $destination_named[7] == $total;
    $complete = 1;
    alarm 0;
  ' "$1" "$2" "$3"
}

# Stream one selected JSONL transcript inode and retain only records after the last real
# user message. Historical turns and harness envelopes never enter the model-visible
# snapshot. Assistant claims stay whole; large tool events become bounded previews plus
# size/hash metadata. Claim truncation is fail-closed. Summarized evidence remains usable
# only when the auditor can independently reproduce what a claim depends on.
_verdict_audit_snapshot_final_turn() {  # source destination source-max snapshot-max emit-identity
  local source="$1" destination="$2" max_source_bytes="$3" max_snapshot_bytes="$4"
  local emit_identity="$5" source_identity snapshot_identity="" snapshot_bytes
  [[ "$max_source_bytes" =~ ^[1-9][0-9]*$ \
     && "$max_snapshot_bytes" =~ ^[1-9][0-9]*$ \
     && ( "$emit_identity" == 0 || "$emit_identity" == 1 ) ]] || return 1
  source_identity="$(perl -MFcntl=:DEFAULT -e '
    my ($path, $max) = @ARGV;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && $opened[7] <= $max;
    print join(":", @opened[0,1,7,9,10]);
  ' "$source" "$max_source_bytes" 2>/dev/null)" || return 1

  if ! snapshot_identity="$(
    (
    set -o pipefail
    perl -MFcntl=:DEFAULT -MJSON::PP -MDigest::SHA -MEncode=encode_utf8 -MScalar::Util=refaddr -e '
    my ($path, $max_source, $max_snapshot, $expected) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 15;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @before = stat($fh);
    my @named = lstat($path);
    exit 1 unless @before && @named && -f $fh
      && join(":", @before[0,1,7,9,10]) eq $expected
      && $before[0] == $named[0] && $before[1] == $named[1]
      && $before[7] <= $max_source;
    binmode($fh);
    my $decoder = JSON::PP->new->utf8->allow_nonref;
    my $encoder = JSON::PP->new->canonical->allow_nonref;
    my @assistant_records;
    my @tool_entries;
    my $claim_bytes = 0;
    my $final_turn_bytes = 0;
    my %omitted = (system => 0, progress => 0, metadata => 0, other => 0);
    my %omitted_bytes = (system => 0, progress => 0, metadata => 0, other => 0);
    my $sequence = 0;
    my $source_digest = Digest::SHA->new(256);

    sub direct_text_content {
      my ($content) = @_;
      return 1 if defined($content) && !ref($content);
      return 0 unless ref($content) eq "ARRAY";
      for my $block (@$content) {
        return 1 if ref($block) eq "HASH"
          && (($block->{type} // "") =~ /text/i);
      }
      return 0;
    }
    sub is_tool_type {
      my ($type) = @_;
      return $type =~ /^(?:tool_(?:use|result)|function_call(?:_output)?|custom_tool_(?:call|call_output)|mcp_.*(?:call|result))$/i;
    }
    sub recognized_role_objects {
      my ($record) = @_;
      return () unless ref($record) eq "HASH";
      return () if is_tool_type($record->{type} // "");
      my (@objects, %seen);
      my $push = sub {
        my ($object) = @_;
        return unless ref($object) eq "HASH";
        return if is_tool_type($object->{type} // "");
        my $address = refaddr($object);
        push @objects, $object unless $seen{$address}++;
      };
      $push->($record);
      $push->($record->{message});
      if (ref($record->{payload}) eq "HASH"
          && !is_tool_type($record->{payload}->{type} // "")) {
        $push->($record->{payload});
        $push->($record->{payload}->{message});
      }
      $push->($record->{actor});
      return @objects;
    }
    sub role_object_content {
      my ($record, $object) = @_;
      return $object->{content} if exists($object->{content});
      if (refaddr($object) == refaddr($record)
          && ref($record->{message}) eq "HASH") {
        return $record->{message}->{content};
      }
      if (ref($record->{actor}) eq "HASH"
          && refaddr($object) == refaddr($record->{actor})
          && ref($record->{output}) eq "HASH") {
        return $record->{output}->{parts} // $record->{output}->{content};
      }
      return undef;
    }
    sub is_real_user {
      my ($record) = @_;
      for my $object (recognized_role_objects($record)) {
        next unless (($object->{type} // "") eq "user"
          || ($object->{role} // "") eq "user");
        return 1 if direct_text_content(role_object_content($record, $object));
      }
      return 0;
    }
    sub tool_objects {
      my ($record) = @_;
      my @tools;
      my %seen;
      my $collect;
      $collect = sub {
        my ($value) = @_;
        if (ref($value) eq "HASH") {
          my $type = $value->{type} // "";
          if (is_tool_type($type)) {
            my $address = refaddr($value);
            push @tools, $value unless $seen{$address}++;
            return;
          }
          for my $key (keys %$value) {
            next if $key =~ /^(?:toolUseResult|thinking|signature|encrypted_content)$/;
            $collect->($value->{$key});
          }
        } elsif (ref($value) eq "ARRAY") {
          $collect->($_) for @$value;
        }
      };
      $collect->($record);
      return @tools;
    }
    sub assistant_texts {
      my ($record) = @_;
      my (@targets, @texts);
      my (%seen_target, %seen_text);
      for my $object (recognized_role_objects($record)) {
        next unless (($object->{role} // "") eq "assistant"
          || ($object->{type} // "") eq "assistant");
        my $target = $object;
        if (ref($record->{actor}) eq "HASH"
            && refaddr($object) == refaddr($record->{actor})
            && ref($record->{output}) eq "HASH") {
          $target = $record->{output};
        }
        my $address = refaddr($target);
        push @targets, $target unless $seen_target{$address}++;
      }
      return () unless @targets;
      my $collect;
      $collect = sub {
        my ($value) = @_;
        if (ref($value) eq "HASH") {
          my $type = $value->{type} // "";
          return if is_tool_type($type)
            || $type =~ /^(?:thinking|redacted_thinking|signature)$/i;
          if ($type =~ /text/i && exists($value->{text})
              && defined($value->{text}) && !ref($value->{text})) {
            my $address = refaddr($value);
            push @texts, $value->{text} unless $seen_text{$address}++;
            return;
          }
          for my $key (keys %$value) {
            next if $key =~ /^(?:toolUseResult|thinking|signature|encrypted_content)$/;
            $collect->($value->{$key});
          }
        } elsif (ref($value) eq "ARRAY") {
          $collect->($_) for @$value;
        }
      };
      $collect->($_) for @targets;
      # Future harnesses sometimes put role metadata and output in sibling fields.
      # Use that record-level fallback only when the assistant object itself had no text.
      $collect->($record) unless @texts;
      return @texts;
    }
    sub bounded_scalar {
      my ($value, $limit) = @_;
      return "" if !defined($value) || ref($value);
      return length($value) <= $limit ? $value : substr($value, 0, $limit);
    }
    sub tool_entry {
      my ($tool, $record_sequence, $event_index) = @_;
      my $text = $encoder->encode($tool);
      my $bytes = encode_utf8($text);
      my $type = $tool->{type} // "unknown";
      my $raw_name = $tool->{name} // $tool->{tool_name} // "";
      my $raw_id = $tool->{id} // $tool->{tool_use_id}
        // $tool->{call_id} // $tool->{tool_call_id} // "";
      my $raw_error = $tool->{error} // $tool->{is_error} // "";
      return {
        sequence => $record_sequence, event_index => $event_index,
        event_kind => ($type =~ /result|output/i ? "result" : "call"),
        type => bounded_scalar($type, 128),
        name => bounded_scalar($raw_name, 256),
        id => bounded_scalar($raw_id, 256),
        error => bounded_scalar($raw_error, 512),
        metadata_truncated => (length("$type") > 128 || length("$raw_name") > 256
          || length("$raw_id") > 256 || length("$raw_error") > 512)
          ? JSON::PP::true : JSON::PP::false,
        text => $text, bytes => length($bytes),
        sha256 => Digest::SHA::sha256_hex($bytes),
      };
    }
    sub public_tool {
      my ($entry, $result_preview, $call_preview) = @_;
      my $summary = {
        event_kind => $entry->{event_kind}, type => $entry->{type},
        name => $entry->{name}, id => $entry->{id}, error => $entry->{error},
        metadata_truncated => $entry->{metadata_truncated},
        payload_bytes => $entry->{bytes}, payload_sha256 => $entry->{sha256},
      };
      if ($entry->{bytes} <= 2048) {
        $summary->{content_truncated} = JSON::PP::false;
        $summary->{content} = $entry->{text};
      } else {
        my $limit = $entry->{event_kind} eq "result" ? $result_preview : $call_preview;
        $summary->{content_truncated} = JSON::PP::true;
        $summary->{head} = substr($entry->{text}, 0, $limit);
        $summary->{tail} = substr($entry->{text}, -$limit);
      }
      return $summary;
    }
    sub omitted_kind {
      my ($record) = @_;
      my $kind = "other";
      if (ref($record) eq "HASH") {
        $kind = $record->{type} // $record->{kind}
          // (ref($record->{payload}) eq "HASH" ? $record->{payload}->{type} : undef)
          // "other";
      }
      return "progress" if $kind =~ /progress|status/i;
      return "system" if $kind =~ /system/i;
      return "metadata" if $kind =~ /metadata|snapshot|queue|history/i;
      return "other";
    }
    sub reset_turn {
      @assistant_records = ();
      @tool_entries = ();
      $claim_bytes = 0;
      $final_turn_bytes = 0;
      %omitted = (system => 0, progress => 0, metadata => 0, other => 0);
      %omitted_bytes = (system => 0, progress => 0, metadata => 0, other => 0);
      $sequence = 0;
    }

    my $total = 0;
    while (defined(my $line = <$fh>)) {
      $total += length($line);
      exit 1 if $total > $max_source || index($line, "\0") >= 0;
      $source_digest->add($line);
      next if $line =~ /^\s*$/;
      my $record = eval { $decoder->decode($line) };
      exit 1 if $@;
      # A pre-normalized snapshot is accepted only by the bounded schema path.
      # path. Never reinterpret an oversized or malformed snapshot as raw history.
      exit 1 if ref($record) eq "HASH"
        && ($record->{type} // "") eq "verdict_final_turn_snapshot";
      if (is_real_user($record)) {
        reset_turn();
        next;
      }
      $sequence++;
      my @tools = tool_objects($record);
      my @texts = assistant_texts($record);
      my $record_bytes = length(encode_utf8($encoder->encode($record))) + 1;
      if (@texts || @tools) {
        $final_turn_bytes += $record_bytes;
        if (@texts) {
          $claim_bytes += length(encode_utf8($_)) for @texts;
          push @assistant_records, {
            kind => "assistant", sequence => $sequence, texts => \@texts,
          };
        }
        my $event_index = 0;
        push @tool_entries, tool_entry($_, $sequence, ++$event_index) for @tools;
      } else {
        my $kind = omitted_kind($record);
        $omitted{$kind}++;
        $omitted_bytes{$kind} += $record_bytes;
      }
    }
    my $first_digest = $source_digest->hexdigest;
    my @after = stat($fh);
    my @named_after = lstat($path);
    exit 1 unless @after && @named_after
      && join(":", @after[0,1,7,9,10]) eq $expected
      && $after[0] == $named_after[0] && $after[1] == $named_after[1];
    sysseek($fh, 0, 0) or exit 1;
    my $verify_digest = Digest::SHA->new(256);
    my $verified_bytes = 0;
    while (1) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, 65536);
      exit 1 unless defined $count;
      last if $count == 0;
      $verified_bytes += $count;
      exit 1 if $verified_bytes > $max_source;
      $verify_digest->add($chunk);
    }
    my @verified = stat($fh);
    my @verified_named = lstat($path);
    exit 1 unless @verified && @verified_named
      && join(":", @verified[0,1,7,9,10]) eq $expected
      && $verified_bytes == $before[7]
      && $verify_digest->hexdigest eq $first_digest
      && $verified[0] == $verified_named[0] && $verified[1] == $verified_named[1];

    my $build_manifest = sub {
      my ($claims_truncated, $keep_tools, $result_preview, $call_preview) = @_;
      my @records = $claims_truncated ? () : @assistant_records;
      my ($previewed, $previewed_bytes, $omitted_count, $omitted_evidence_bytes) = (0, 0, 0, 0);
      if (!$claims_truncated) {
        for my $index (0 .. $#tool_entries) {
          my $entry = $tool_entries[$index];
          if ($index < $keep_tools) {
            my $summary = public_tool($entry, $result_preview, $call_preview);
            if ($summary->{content_truncated}) {
              $previewed++;
              my $preview_bytes = length(encode_utf8($summary->{head}))
                + length(encode_utf8($summary->{tail}));
              $previewed_bytes += $entry->{bytes} - $preview_bytes
                if $entry->{bytes} > $preview_bytes;
            }
            push @records, {
              kind => "tool", sequence => $entry->{sequence},
              event_index => $entry->{event_index}, tools => [$summary],
            };
          } else {
            $omitted_count++;
            $omitted_evidence_bytes += $entry->{bytes};
          }
        }
        @records = sort {
          $a->{sequence} <=> $b->{sequence}
            || (($a->{kind} eq "assistant" ? 0 : 1)
                <=> ($b->{kind} eq "assistant" ? 0 : 1))
            || (($a->{event_index} // 0) <=> ($b->{event_index} // 0))
        } @records;
      } else {
        $omitted_count = scalar @tool_entries;
        $omitted_evidence_bytes += $_->{bytes} for @tool_entries;
      }
      my $retained_bytes = length(encode_utf8($encoder->encode(\@records)));
      return {
        type => "verdict_final_turn_snapshot", version => 1,
        truncated => $claims_truncated ? JSON::PP::true : JSON::PP::false,
        evidence_truncated => ($previewed || $omitted_count)
          ? JSON::PP::true : JSON::PP::false,
        source_bytes => $before[7], source_sha256 => $first_digest,
        final_turn_bytes => $final_turn_bytes, claim_bytes => $claim_bytes,
        max_snapshot_bytes => 0 + $max_snapshot, retained_bytes => $retained_bytes,
        omitted_kind_counts => \%omitted, omitted_kind_bytes => \%omitted_bytes,
        evidence_summary => {
          seen => scalar @tool_entries, retained => $keep_tools,
          previewed => $previewed, previewed_bytes => $previewed_bytes,
          omitted => $omitted_count, omitted_bytes => $omitted_evidence_bytes,
        },
        records => \@records,
      };
    };
    my $keep_tools = scalar @tool_entries;
    my ($result_preview, $call_preview) = (768, 768);
    my $manifest = $build_manifest->(0, $keep_tools, $result_preview, $call_preview);
    my $output = encode_utf8($encoder->encode($manifest));
    if (length($output) + 1 > $max_snapshot) {
      $result_preview = 512;
      $manifest = $build_manifest->(0, $keep_tools, $result_preview, $call_preview);
      $output = encode_utf8($encoder->encode($manifest));
    }
    if (length($output) + 1 > $max_snapshot) {
      $call_preview = 256;
      $manifest = $build_manifest->(0, $keep_tools, $result_preview, $call_preview);
      $output = encode_utf8($encoder->encode($manifest));
    }
    while (length($output) + 1 > $max_snapshot && $keep_tools > 0) {
      $keep_tools--;
      $manifest = $build_manifest->(0, $keep_tools, $result_preview, $call_preview);
      $output = encode_utf8($encoder->encode($manifest));
    }
    if (length($output) + 1 > $max_snapshot) {
      $manifest = $build_manifest->(1, 0, $result_preview, $call_preview);
      $output = encode_utf8($encoder->encode($manifest));
    }
    exit 1 if length($output) + 1 > $max_snapshot;
    alarm 0;
    print STDOUT $output, "\n" or exit 1;
    ' "$source" "$max_source_bytes" "$max_snapshot_bytes" "$source_identity" \
      | verdict_audit_write_exclusive_regular_identity "$destination"
    )
  )"; then
    [[ "$snapshot_identity" =~ ^[0-9]+:[0-9]+$ ]] \
      && verdict_audit_unlink_if_identity \
          "$destination" "$snapshot_identity" 2>/dev/null || true
    return 1
  fi
  if [[ ! "$snapshot_identity" =~ ^[0-9]+:[0-9]+$ ]] \
     || ! snapshot_bytes="$(verdict_audit_regular_size_if_identity \
          "$destination" "$snapshot_identity" 2>/dev/null)" \
     || [[ ! "$snapshot_bytes" =~ ^[0-9]+$ \
     || "$snapshot_bytes" -gt "$max_snapshot_bytes" ]]; then
    [[ "$snapshot_identity" =~ ^[0-9]+:[0-9]+$ ]] \
      && verdict_audit_unlink_if_identity \
          "$destination" "$snapshot_identity" 2>/dev/null || true
    return 1
  fi
  if [[ "$emit_identity" == 1 ]] \
     && ! perl -e '
          $SIG{PIPE} = "IGNORE";
          print STDOUT $ARGV[0] or exit 1;
          close(STDOUT) or exit 1;
        ' "$snapshot_identity"; then
    verdict_audit_unlink_if_identity \
      "$destination" "$snapshot_identity" 2>/dev/null || true
    return 1
  fi
}

verdict_audit_snapshot_final_turn() {  # source destination max-source-bytes max-snapshot-bytes
  _verdict_audit_snapshot_final_turn "$1" "$2" "$3" "$4" 0
}

verdict_audit_snapshot_final_turn_identity() {  # source destination source-max snapshot-max -> device:inode
  _verdict_audit_snapshot_final_turn "$1" "$2" "$3" "$4" 1
}

# Build the same wire record when Codex supplies Stop.last_assistant_message instead of
# a transcript path. The message crosses stdin once; no caller hand-assembles a sibling
# schema that the headless route would later reinterpret as raw transcript JSONL.
verdict_audit_message_snapshot() {  # max-snapshot-bytes; message on stdin
  local max_snapshot_bytes="$1"
  [[ "$max_snapshot_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  perl -MJSON::PP -MDigest::SHA=sha256_hex -MEncode=encode_utf8,decode_utf8 -e '
    my $max = shift;
    binmode(STDIN);
    local $/;
    my $raw_text = <STDIN> // "";
    my $text = decode_utf8($raw_text, 1);
    my $encoder = JSON::PP->new->canonical->allow_nonref;
    my $bytes = $raw_text;
    my $record = {kind => "assistant", sequence => 1, texts => [$text]};
    my $records = [$record];
    my $manifest = {
      type => "verdict_final_turn_snapshot", version => 1,
      truncated => JSON::PP::false, evidence_truncated => JSON::PP::false,
      source_bytes => length($bytes), source_sha256 => sha256_hex($bytes),
      final_turn_bytes => length($bytes), claim_bytes => length($bytes),
      max_snapshot_bytes => 0 + $max,
      retained_bytes => length(encode_utf8($encoder->encode($records))),
      omitted_kind_counts => {system => 0, progress => 0, metadata => 0, other => 0},
      omitted_kind_bytes => {system => 0, progress => 0, metadata => 0, other => 0},
      evidence_summary => {seen => 0, retained => 0, previewed => 0,
        previewed_bytes => 0, omitted => 0, omitted_bytes => 0},
      records => $records,
    };
    my $output = encode_utf8($encoder->encode($manifest));
    if (length($output) + 1 > $max) {
      $manifest->{truncated} = JSON::PP::true;
      $manifest->{retained_bytes} = 2;
      $manifest->{records} = [];
      $output = encode_utf8($encoder->encode($manifest));
    }
    exit 1 if length($output) + 1 > $max;
    print STDOUT $output, "\n" or exit 1;
  ' "$max_snapshot_bytes"
}

verdict_audit_failed_turn_snapshot() {  # max-snapshot-bytes
  local max_snapshot_bytes="$1"
  [[ "$max_snapshot_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  jq -nc --argjson max "$max_snapshot_bytes" '
    {type:"verdict_final_turn_snapshot",version:1,truncated:true,
     evidence_truncated:true,source_bytes:0,
     source_sha256:"0000000000000000000000000000000000000000000000000000000000000000",
     final_turn_bytes:0,claim_bytes:0,max_snapshot_bytes:$max,retained_bytes:2,
     omitted_kind_counts:{system:0,progress:0,metadata:0,other:0},
     omitted_kind_bytes:{system:0,progress:0,metadata:0,other:0},
     evidence_summary:{seen:0,retained:0,previewed:0,previewed_bytes:0,
                       omitted:0,omitted_bytes:0},records:[]}
  '
}

verdict_audit_failed_prior_snapshot() {
  jq -nc '
    {type:"verdict_prior_dossier_snapshot",version:1,truncated:true,
     reason:"prior dossier was unreadable, malformed, or exceeded 65536 bytes"}
  '
}

verdict_audit_absent_prior_snapshot() {
  jq -nc '
    {type:"verdict_prior_dossier_snapshot",version:1,truncated:false,absent:true}
  '
}

verdict_audit_normalize_turn_snapshot() {  # max-allowed-bytes; snapshot JSON on stdin
  local max_allowed_bytes="${1:-262144}"
  [[ "$max_allowed_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  jq -ecs --argjson max_allowed "$max_allowed_bytes" '
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    def count: type == "number" and . >= 0 and floor == .;
    if length == 1
       and (.[0] | type) == "object"
       and (.[0] | exact_keys([
         "type", "version", "truncated", "evidence_truncated", "source_bytes",
         "source_sha256", "final_turn_bytes", "claim_bytes", "max_snapshot_bytes",
         "retained_bytes", "omitted_kind_counts", "omitted_kind_bytes",
         "evidence_summary", "records"
       ]))
       and .[0].type == "verdict_final_turn_snapshot"
       and .[0].version == 1
       and (.[0].truncated | type) == "boolean"
       and (.[0].evidence_truncated | type) == "boolean"
       and (.[0].source_bytes | count)
       and (.[0].source_sha256 | type) == "string"
       and (.[0].source_sha256 | test("^[0-9a-f]{64}$"))
       and (.[0].final_turn_bytes | count)
       and (.[0].claim_bytes | count)
       and (.[0].max_snapshot_bytes | count)
       and .[0].max_snapshot_bytes > 0
       and .[0].max_snapshot_bytes <= $max_allowed
       and (.[0].retained_bytes | count)
       and .[0].retained_bytes <= .[0].max_snapshot_bytes
       and .[0].retained_bytes == (.[0].records | tojson | utf8bytelength)
       and (.[0].omitted_kind_counts | type) == "object"
       and (.[0].omitted_kind_counts
            | exact_keys(["system", "progress", "metadata", "other"]))
       and all(.[0].omitted_kind_counts[]; count)
       and (.[0].omitted_kind_bytes | type) == "object"
       and (.[0].omitted_kind_bytes
            | exact_keys(["system", "progress", "metadata", "other"]))
       and all(.[0].omitted_kind_bytes[]; count)
       and (.[0].evidence_summary | type) == "object"
       and (.[0].evidence_summary
            | exact_keys(["seen", "retained", "previewed", "previewed_bytes", "omitted", "omitted_bytes"]))
       and all(.[0].evidence_summary[]; count)
       and .[0].evidence_summary.retained <= .[0].evidence_summary.seen
       and .[0].evidence_summary.previewed <= .[0].evidence_summary.retained
       and .[0].evidence_summary.omitted == (.[0].evidence_summary.seen - .[0].evidence_summary.retained)
       and (.[0].records | type) == "array"
    then .[0] else empty end
  '
}

# Normalize exactly one verdict dossier only when it matches the published wire contract.
# Legacy/manual dossiers may omit `generation`; a present generation is always a string.
# Keeping this policy in one function prevents the runner and Stop gate from drifting on
# which JSON has authority.
verdict_audit_normalize_dossier() {  # JSON on stdin
  jq -ecs '
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    def nonempty_line:
      type == "string" and length > 0
      and (explode | all(. != 0 and . != 10 and . != 13));
    def nonempty_text:
      type == "string" and length > 0 and (explode | all(. != 0));
    def valid_proof:
      type == "object"
      and exact_keys(["claim", "kind", "evidence", "method", "status", "blocker"])
      and (.claim | nonempty_line)
      and (.kind == "fix-works" or .kind == "tests-pass"
           or .kind == "root-cause" or .kind == "removal-safe"
           or .kind == "finding" or .kind == "factual" or .kind == "other")
      and (.evidence | nonempty_text)
      and (.method == "structural" or .method == "transcript"
           or .method == "rerun" or .method == "two-side")
      and (.status == "verified" or .status == "blocked")
      and (if .status == "verified"
           then .blocker == null
           else (.blocker | nonempty_line)
           end);
    if length == 1
       and (.[0] | type) == "object"
       and ((.[0] | exact_keys(["branch", "head", "tree_hash", "verdict", "proof", "findings"]))
            or (.[0] | exact_keys(["branch", "head", "tree_hash", "generation", "verdict", "proof", "findings"])))
       and (.[0].branch | type) == "string"
       and (.[0].head | type) == "string"
       and (.[0].tree_hash | type) == "string"
       and ((.[0] | has("generation") | not) or (.[0].generation | type) == "string")
       and (.[0].verdict == "PASS" or .[0].verdict == "FAIL"
            or .[0].verdict == "IN_PROGRESS")
       and (.[0].proof | type) == "array"
       and all(.[0].proof[]; valid_proof)
       and (.[0].findings | type) == "array"
       and all(.[0].findings[]; nonempty_line)
       and (if .[0].verdict == "PASS"
            then (.[0].findings | length) == 0
            else (.[0].findings | length) > 0
            end)
    then .[0]
    else empty
    end
  '
}

# Perl's syscalls keep source and destination exact. BSD `mv file directory` and
# `ln file directory` reinterpret the destination as a container, which can hide the
# selected state object under an attacker-created directory.
verdict_audit_rename_exact() {  # source destination
  perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

# Move one pathname without ever replacing a destination entry. Darwin and Linux
# expose this as different syscalls; keeping the small portability table here avoids
# `mv -n` implementations that emulate no-clobber with a check/rename race. Unsupported
# architectures fail closed rather than silently falling back to overwriting rename(2).
verdict_audit_rename_no_clobber_exact() {  # source destination
  perl -MConfig -e '
    my ($source, $destination) = @ARGV;
    my $os = $Config{osname} // "";
    my $arch = $Config{archname} // "";
    my ($call, $cwd, $flag);
    if ($os eq "darwin") {
      # renameatx_np(2): SYS_renameatx_np=488, AT_FDCWD=-2, RENAME_EXCL=4.
      ($call, $cwd, $flag) = (488, -2, 4);
    } elsif ($os eq "linux") {
      # renameat2(2): AT_FDCWD=-100, RENAME_NOREPLACE=1.
      $cwd = -100;
      $flag = 1;
      if ($arch =~ /\A(?:x86_64|amd64)/) { $call = 316 }
      elsif ($arch =~ /\A(?:aarch64|arm64|riscv64|loongarch64)/) { $call = 276 }
      elsif ($arch =~ /\Ai[3-6]86/) { $call = 353 }
      elsif ($arch =~ /\Aarm/) { $call = 382 }
      elsif ($arch =~ /\Appc64/) { $call = 357 }
      elsif ($arch =~ /\As390x/) { $call = 347 }
      else { exit 1 }
    } else {
      exit 1;
    }
    exit(syscall($call, $cwd, $source, $cwd, $destination, $flag) == 0 ? 0 : 1);
  ' "$1" "$2"
}

# Atomically swap two existing pathnames without losing either object. Atomic state
# replacement uses this only after binding both names to expected regular-file identities;
# unsupported kernels fail closed instead of falling back to two lossy renames.
verdict_audit_exchange_exact() {  # first-path second-path
  perl -MConfig -e '
    my ($first, $second) = @ARGV;
    my $os = $Config{osname} // "";
    my $arch = $Config{archname} // "";
    my ($call, $cwd, $flag);
    if ($os eq "darwin") {
      # renameatx_np(2): SYS_renameatx_np=488, AT_FDCWD=-2, RENAME_SWAP=2.
      ($call, $cwd, $flag) = (488, -2, 2);
    } elsif ($os eq "linux") {
      # renameat2(2): AT_FDCWD=-100, RENAME_EXCHANGE=2.
      $cwd = -100;
      $flag = 2;
      if ($arch =~ /\A(?:x86_64|amd64)/) { $call = 316 }
      elsif ($arch =~ /\A(?:aarch64|arm64|riscv64|loongarch64)/) { $call = 276 }
      elsif ($arch =~ /\Ai[3-6]86/) { $call = 353 }
      elsif ($arch =~ /\Aarm/) { $call = 382 }
      elsif ($arch =~ /\Appc64/) { $call = 357 }
      elsif ($arch =~ /\As390x/) { $call = 347 }
      else { exit 1 }
    } else {
      exit 1;
    }
    exit(syscall($call, $cwd, $first, $cwd, $second, $flag) == 0 ? 0 : 1);
  ' "$1" "$2"
}

verdict_audit_restore_no_clobber() {  # quarantined-path stable-path
  verdict_audit_rename_no_clobber_exact "$1" "$2"
}

# Two-phase restore for callers that must revalidate external authority after publishing
# the stable name. Retaining the quarantine hardlink preserves an exact inode identity;
# if authority changes, only that same published inode can be retracted.
verdict_audit_link_no_clobber_identity() {  # quarantined-path stable-path
  perl -e '
    my ($source, $destination) = @ARGV;
    my @source_before = lstat($source);
    exit 1 unless @source_before && -f _;
    link($source, $destination) or exit 1;
    my @source_after = lstat($source);
    my @destination = lstat($destination);
    my $linked = @destination
      && $destination[0] == $source_before[0]
      && $destination[1] == $source_before[1];
    if (!@source_after || !$linked
        || $source_after[0] != $source_before[0]
        || $source_after[1] != $source_before[1]) {
      if ($linked) {
        my @current = lstat($destination);
        unlink($destination) if @current
          && $current[0] == $source_before[0]
          && $current[1] == $source_before[1];
      }
      exit 1;
    }
    print $source_before[0], ":", $source_before[1];
  ' "$1" "$2"
}

verdict_audit_link_no_clobber() {  # quarantined-path stable-path
  verdict_audit_link_no_clobber_identity "$1" "$2" >/dev/null
}

verdict_audit_unlink_selected_identity() {  # selected-path expected-device:inode
  local selected_path="$1" expected_identity="$2"
  local retirement_path="${1}.retire-$$-${RANDOM:-0}" retirement_status
  # A second no-clobber rename is the deletion selection edge. If the checked name was
  # replaced after its preceding validation, that replacement is moved—not removed—
  # and the descriptor-bound check below rejects it. Restore keeps every object type.
  verdict_audit_rename_no_clobber_exact \
    "$selected_path" "$retirement_path" 2>/dev/null || return 2
  perl -MConfig -MFcntl=:DEFAULT -MFile::Basename=dirname,basename -e '
    my ($path, $expected) = @ARGV;
    exit 1 unless $expected =~ /\A[0-9]+:[0-9]+\z/;
    my $parent = dirname($path);
    my $leaf = basename($path);
    exit 1 if $leaf eq "" || $leaf eq "." || $leaf eq "..";
    my $directory_flags = O_RDONLY | O_NONBLOCK;
    $directory_flags |= Fcntl::O_DIRECTORY() if defined &Fcntl::O_DIRECTORY;
    $directory_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $directory, $parent, $directory_flags) or exit 1;
    chdir($directory) or exit 1;
    my $file_flags = O_RDONLY | O_NONBLOCK;
    $file_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $owned, $leaf, $file_flags) or exit 1;
    my @opened = stat($owned);
    my @named = lstat($leaf);
    exit 1 unless @opened && @named && (-f $owned || -p $owned)
      && ($opened[0] . ":" . $opened[1]) eq $expected
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $os = $Config{osname} // "";
    my $arch = $Config{archname} // "";
    my $unlinkat_call;
    if ($os eq "darwin") { $unlinkat_call = 472 }
    elsif ($os eq "linux") {
      if ($arch =~ /\A(?:x86_64|amd64)/) { $unlinkat_call = 263 }
      elsif ($arch =~ /\A(?:aarch64|arm64|riscv64|loongarch64)/) { $unlinkat_call = 35 }
      elsif ($arch =~ /\Ai[3-6]86/) { $unlinkat_call = 301 }
      elsif ($arch =~ /\Aarm/) { $unlinkat_call = 328 }
      elsif ($arch =~ /\Appc64/) { $unlinkat_call = 292 }
      elsif ($arch =~ /\As390x/) { $unlinkat_call = 294 }
      else { exit 1 }
    } else { exit 1 }
    my $links_before = $opened[3];
    syscall($unlinkat_call, fileno($directory), $leaf, 0) == 0 or exit 1;
    my @after = stat($owned);
    exit 1 unless @after && $links_before > 0 && $after[3] + 1 == $links_before;
  ' "$retirement_path" "$expected_identity" 2>/dev/null
  retirement_status=$?
  if (( retirement_status == 0 )); then
    return 0
  fi
  verdict_audit_restore_no_clobber \
    "$retirement_path" "$selected_path" 2>/dev/null || return 3
  return 1
}

verdict_audit_unlink_if_identity() {  # stable-path expected-device:inode
  local stable_path="$1" expected_identity="$2"
  local selected_path="${1}.unlink-$$-${RANDOM:-0}" retirement_status
  [[ "$expected_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  # Selection itself is atomic and no-clobber. A replacement already at the stable
  # name is moved to quarantine, identified as foreign, and restored unchanged.
  verdict_audit_rename_no_clobber_exact \
    "$stable_path" "$selected_path" 2>/dev/null || return 2
  if ! verdict_audit_selected_identity_matches \
      "$selected_path" "$expected_identity" 2>/dev/null; then
    verdict_audit_restore_no_clobber \
      "$selected_path" "$stable_path" 2>/dev/null || return 3
    return 1
  fi
  verdict_audit_unlink_selected_identity \
    "$selected_path" "$expected_identity" 2>/dev/null
  retirement_status=$?
  if (( retirement_status == 0 )); then
    return 0
  fi
  verdict_audit_restore_no_clobber \
    "$selected_path" "$stable_path" 2>/dev/null || true
  return "$retirement_status"
}

verdict_audit_unlink_if_same_inode() {  # stable-path quarantined-path
  local owned_identity
  owned_identity="$(verdict_audit_path_identity "$2" 2>/dev/null)" || return 1
  verdict_audit_unlink_if_identity "$1" "$owned_identity"
}

# Capture and compare lstat identity around a rename. This lets callers distinguish the
# object they observed before an epoch check from a replacement that appeared afterward,
# without trusting pathname contents or timestamps.
verdict_audit_path_identity() {  # path
  perl -e '
    my @selected = lstat($ARGV[0]);
    exit 1 unless @selected;
    print $selected[0], ":", $selected[1];
  ' "$1"
}

verdict_audit_selected_identity_matches() {  # selected-path device:inode
  perl -e '
    my ($path, $expected) = @ARGV;
    exit 1 unless $expected =~ /\A[0-9]+:[0-9]+\z/;
    my @selected = lstat($path);
    exit 1 unless @selected;
    exit(($selected[0] . ":" . $selected[1]) eq $expected ? 0 : 1);
  ' "$1" "$2"
}

# Read metadata only through the exact regular inode a caller already owns. This is
# the bounded post-write check used before publishing or retiring private snapshots;
# a pathname replacement can neither supply the size nor authorize cleanup.
verdict_audit_regular_size_if_identity() {  # selected-path device:inode
  perl -MFcntl=:DEFAULT -e '
    my ($path, $expected) = @ARGV;
    exit 1 unless $expected =~ /\A[0-9]+:[0-9]+\z/;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && ($opened[0] . ":" . $opened[1]) eq $expected
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    print $opened[7];
  ' "$1" "$2"
}

# A PID is only an observation; pair it with the process start instant before trusting
# persisted metadata across crashes. ps(1) exposes the same portable lstart field on the
# macOS and Linux hosts supported by this plugin, and cksum makes it one record token.
verdict_audit_process_start_token() {  # pid
  local started checksum bytes extra
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  started="$(ps -p "$1" -o lstart= 2>/dev/null)" || return 1
  [[ -n "$started" ]] || return 1
  read -r checksum bytes extra <<< "$(printf '%s' "$started" | cksum)"
  [[ "$checksum" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && -z "$extra" ]] || return 1
  printf 'cksum-%s-%s' "$checksum" "$bytes"
}

# A repository handoff may be read by every process in that checkout. Bind it to the
# long-lived harness process that launched the originating hook, then require later git
# hooks to descend from that same live process. The start token closes PID-reuse races.
verdict_audit_process_has_ancestor() {  # ancestor-pid ancestor-start-token [start-pid]
  local expected_pid="$1" expected_token="$2" current_pid="${3:-$$}" parent_pid token
  local depth=0
  [[ "$expected_pid" =~ ^[1-9][0-9]*$ \
     && "$expected_token" =~ ^cksum-[0-9]+-[0-9]+$ \
     && "$current_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  while (( depth < 64 )); do
    if [[ "$current_pid" == "$expected_pid" ]]; then
      token="$(verdict_audit_process_start_token "$current_pid" 2>/dev/null)" || return 1
      [[ "$token" == "$expected_token" ]]
      return $?
    fi
    parent_pid="$(ps -p "$current_pid" -o ppid= 2>/dev/null)" || return 1
    parent_pid="${parent_pid//[[:space:]]/}"
    [[ "$parent_pid" =~ ^[1-9][0-9]*$ && "$parent_pid" != "$current_pid" ]] || return 1
    current_pid="$parent_pid"
    depth=$((depth + 1))
  done
  return 1
}

# Write stdin only when the exact destination path does not already exist. O_EXCL and
# O_NONBLOCK make a pre-created FIFO/symlink/directory a fast error; inode checks prove
# the opened descriptor is the regular file now named at that path.
_verdict_audit_write_exclusive_regular() {  # destination-path emit-identity
  perl -MConfig -MFcntl=:DEFAULT -e '
    my ($path, $emit_identity) = @ARGV;
    exit 1 unless $emit_identity eq "0" || $emit_identity eq "1";
    my $flags = O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    my $retire_owned = sub {
      my @current = lstat($path);
      return unless @current
        && $opened[0] == $current[0] && $opened[1] == $current[1];
      my $retired = $path . ".failed-" . $$ . "-" . int(rand(2_147_483_647));
      my $os = $Config{osname} // "";
      my $arch = $Config{archname} // "";
      my ($call, $cwd, $flag);
      if ($os eq "darwin") { ($call, $cwd, $flag) = (488, -2, 4) }
      elsif ($os eq "linux") {
        $cwd = -100;
        $flag = 1;
        if ($arch =~ /\A(?:x86_64|amd64)/) { $call = 316 }
        elsif ($arch =~ /\A(?:aarch64|arm64|riscv64|loongarch64)/) { $call = 276 }
        elsif ($arch =~ /\Ai[3-6]86/) { $call = 353 }
        elsif ($arch =~ /\Aarm/) { $call = 382 }
        elsif ($arch =~ /\Appc64/) { $call = 357 }
        elsif ($arch =~ /\As390x/) { $call = 347 }
        else { return }
      } else { return }
      return unless syscall($call, $cwd, $path, $cwd, $retired, $flag) == 0;
      my @selected = lstat($retired);
      return if @selected
        && $opened[0] == $selected[0] && $opened[1] == $selected[1];
      syscall($call, $cwd, $retired, $cwd, $path, $flag);
    };
    if (!@opened || !@named || !-f $fh
        || $opened[0] != $named[0] || $opened[1] != $named[1]) {
      $retire_owned->() if @opened;
      exit 1;
    }
    binmode(STDIN);
    binmode($fh);
    while (1) {
      my $chunk = "";
      my $read = sysread(STDIN, $chunk, 65536);
      if (!defined $read) { $retire_owned->(); exit 1 }
      last if $read == 0;
      my $offset = 0;
      while ($offset < length($chunk)) {
        my $written = syswrite($fh, $chunk, length($chunk) - $offset, $offset);
        if (!defined $written || $written == 0) { $retire_owned->(); exit 1 }
        $offset += $written;
      }
    }
    close($fh) or do { $retire_owned->(); exit 1 };
    if ($emit_identity eq "1") {
      my @current = lstat($path);
      exit 1 unless @current
        && $opened[0] == $current[0] && $opened[1] == $current[1];
      $SIG{PIPE} = "IGNORE";
      if (!print(STDOUT $opened[0], ":", $opened[1]) || !close(STDOUT)) {
        $retire_owned->();
        exit 1;
      }
    }
  ' "$1" "$2"
}

verdict_audit_write_exclusive_regular() {  # destination-path
  _verdict_audit_write_exclusive_regular "$1" 0
}

# The identity-returning form lets a caller later retire only the inode selected by
# this exact O_EXCL write. A pathname replacement after close is never authorized.
verdict_audit_write_exclusive_regular_identity() {  # destination-path -> device:inode
  _verdict_audit_write_exclusive_regular "$1" 1
}

# Atomic replacement for small state records. The identity-returning form lets a
# producer later retract only its own publication without deleting a newer writer's
# replacement. The caller supplies bytes on stdin.
_verdict_audit_write_atomic_identity_locked() {  # destination-path -> device:inode
  local destination="$1" temporary="${1}.tmp.$$-${RANDOM:-0}"
  local identity prior_identity=""
  identity="$(verdict_audit_write_exclusive_regular_identity "$temporary")" || {
    return 1
  }
  # The identity comes from the writer's open descriptor, before close. A later
  # pathname replacement is foreign and is preserved rather than authenticated.
  if ! verdict_audit_selected_identity_matches \
      "$temporary" "$identity" 2>/dev/null; then
    verdict_audit_unlink_if_identity \
      "$temporary" "$identity" 2>/dev/null || true
    return 1
  fi

  # Identity delivery precedes the publication commit. If the caller cannot receive
  # it, no stable pathname has changed and the prior record remains authoritative.
  # Ignore SIGPIPE only in this emission subshell. A closed pipeline reader then makes
  # printf report EPIPE as a normal nonzero status, while the caller's signal behavior
  # remains untouched and this function retains control of exact temp retirement.
  if ! ( trap '' PIPE; printf '%s' "$identity" ) 2>/dev/null; then
    verdict_audit_unlink_if_identity \
      "$temporary" "$identity" 2>/dev/null || true
    return 1
  fi

  if prior_identity="$(verdict_audit_path_identity \
      "$destination" 2>/dev/null)"; then
    # The exchange is the single irreversible commit point. The per-destination flock
    # excludes another helper writer until every validation and private cleanup ends.
    if [[ -d "$destination" && ! -L "$destination" ]] \
       || ! verdict_audit_exchange_exact \
        "$temporary" "$destination" 2>/dev/null; then
      verdict_audit_unlink_if_identity \
        "$temporary" "$identity" 2>/dev/null || true
      return 1
    fi
    if ! verdict_audit_selected_identity_matches \
        "$destination" "$identity" 2>/dev/null \
       || ! verdict_audit_selected_identity_matches \
        "$temporary" "$prior_identity" 2>/dev/null; then
      # Never roll back a stable pathname after commit. An unexpected external swap is
      # preserved for the next exact reader; private ambiguous state is left in place.
      return 1
    fi
    # Retirement is private bookkeeping after commit. A collision leaks at most this
    # invocation's bounded temp record and cannot revoke the stable publication.
    verdict_audit_unlink_if_identity \
      "$temporary" "$prior_identity" 2>/dev/null || true
  else
    # No-clobber publication preserves a destination that appears after the absence
    # check. Post-publication validation catches a temp-name swap at the syscall edge.
    if [[ -e "$destination" || -L "$destination" ]] \
       || ! verdict_audit_rename_no_clobber_exact \
        "$temporary" "$destination" 2>/dev/null; then
      verdict_audit_unlink_if_identity \
        "$temporary" "$identity" 2>/dev/null || true
      return 1
    fi
    if ! verdict_audit_selected_identity_matches \
        "$destination" "$identity" 2>/dev/null; then
      # Publication already committed. Preserve the stable object even when an
      # uncoordinated actor changed it at the syscall edge.
      return 1
    fi
  fi
  return 0
}

# Serialize the entire state transition on the destination directory vnode. A separate
# lock pathname can be renamed after validation and replaced with a second flock inode;
# the already-open parent directory is the stable kernel anchor shared by every writer
# that can publish a name there. Perl retains that flock across the inner Bash exec, so
# macOS Bash 3 needs no flock utility or dynamic descriptor support. The kernel releases
# the inherited descriptor on every normal, error, or signal exit.
verdict_audit_write_atomic_identity() {  # destination-path -> device:inode
  local destination="$1" state_lib_dir state_lib
  state_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  state_lib="$state_lib_dir/$(basename "${BASH_SOURCE[0]}")"
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -e '
    my ($state_lib, $destination) = @ARGV;
    my $anchor_path = dirname($destination);
    $SIG{ALRM} = sub {
      print STDERR "verdict-audit-state: timed out acquiring atomic state anchor\n";
      exit 1;
    };
    alarm 10;
    $^F = 255;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_DIRECTORY() if defined &Fcntl::O_DIRECTORY;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $anchor, $anchor_path, $flags) or do {
      print STDERR "verdict-audit-state: atomic state directory is unavailable\n";
      exit 1;
    };
    my @opened = stat($anchor);
    my @named = lstat($anchor_path);
    exit 1 unless @opened && @named && -d $anchor
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($anchor, LOCK_EX) or exit 1;
    @opened = stat($anchor);
    @named = lstat($anchor_path);
    exit 1 unless @opened && @named && -d $anchor
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    alarm 0;
    exec "/bin/bash", "-c",
      q{source "$1"; _verdict_audit_write_atomic_identity_locked "$2"},
      "verdict-atomic-writer", $state_lib, $destination;
    print STDERR "verdict-audit-state: could not launch atomic state writer\n";
    exit 1;
  ' "$state_lib" "$destination"
}

verdict_audit_write_atomic() {  # destination-path
  verdict_audit_write_atomic_identity "$1" >/dev/null
}

# Remove only the exact record body the caller previously authorized. Renaming first
# selects one inode; a replacement written before selection is restored, and one written
# afterward remains untouched at the stable path.
verdict_audit_remove_record_if_matches() {  # record-path expected-body
  local record_path="$1" expected_body="$2"
  local quarantine="${1}.retire.$$-${RANDOM:-0}" actual_body record_identity
  record_identity="$(verdict_audit_path_identity "$record_path" 2>/dev/null)" \
    || return 1
  verdict_audit_rename_no_clobber_exact \
    "$record_path" "$quarantine" 2>/dev/null || return 1
  if ! verdict_audit_selected_identity_matches \
      "$quarantine" "$record_identity" 2>/dev/null; then
    verdict_audit_restore_no_clobber \
      "$quarantine" "$record_path" 2>/dev/null || return 2
    return 1
  fi
  if actual_body="$(verdict_audit_read_single_record "$quarantine" 2>/dev/null)" \
     && [[ "$actual_body" == "$expected_body" ]]; then
    verdict_audit_unlink_if_identity \
      "$quarantine" "$record_identity" 2>/dev/null
    return $?
  fi
  verdict_audit_restore_no_clobber "$quarantine" "$record_path" 2>/dev/null || return 2
  return 1
}

# Last-resort revocation when the containing directory cannot accept a rename or sibling
# tombstone. Mutate only the already-authorized regular inode after an exclusive lock and
# two pathname-identity checks. The replacement text is deliberately outside the request
# grammar, so a later Stop cannot reload the canceled generation.
verdict_audit_invalidate_record_if_matches() {  # record-path expected-body
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($path, $expected) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    flock($fh, LOCK_EX) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $body = "";
    while (length($body) <= 4096) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, 4097 - length($body));
      exit 1 unless defined $count;
      last if $count == 0;
      $body .= $chunk;
    }
    exit 1 if length($body) > 4096 || $body =~ /[\0\r]/;
    $body =~ s/\n\z//;
    exit 1 unless $body eq $expected;
    @named = lstat($path);
    exit 1 unless @named
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    truncate($fh, 0) or exit 1;
    seek($fh, 0, 0) or exit 1;
    print {$fh} "revoked\n" or exit 1;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2"
}

# Best-effort bounded decision logging on one selected regular inode. Unsafe path types
# are rejected without opening, and an oversized/corrupt history is replaced by the new
# line rather than read without bound.
verdict_audit_append_log_line() {  # log-path line-without-LF
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($path, $line) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if $line =~ /[\0\r\n]/;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    @opened = stat($fh);
    @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my @lines = ();
    if ($opened[7] <= 1048576) {
      seek($fh, 0, 0) or exit 1;
      local $/;
      my $body = <$fh> // "";
      @lines = split(/\n/, $body);
    }
    push @lines, $line;
    @lines = @lines[-500 .. -1] if @lines > 1000;
    truncate($fh, 0) or exit 1;
    seek($fh, 0, 0) or exit 1;
    print {$fh} join("\n", @lines), "\n" or exit 1;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2"
}

# Hash an untrusted harness session id into one whitespace-free lock field. Empty is a
# deliberate legacy/manual scope. Git is already required by both callers and supports
# SHA-1 and SHA-256 repositories, so accept either output length at the read boundary.
verdict_audit_scope_identity() {  # raw-session-id git-repo
  [[ -n "$1" ]] || { printf '-'; return; }
  local object_id
  object_id="$(printf '%s' "$1" | git -C "$2" hash-object --stdin)" || return 1
  [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf 'git-%s' "$object_id"
}

# Hook payloads can carry control characters that shell command substitution cannot
# preserve at the end of a string. Stream the JSON value straight into Git instead of
# round-tripping it through a shell variable; the resulting hash stays identical to the
# raw-argument helper above for every byte sequence.
verdict_audit_scope_from_hook_payload() {  # hook-payload git-repo
  local object_id
  object_id="$(printf '%s' "$1" | jq -j -e '
    if (.session_id | type) == "string" and (.session_id | length) > 0
    then .session_id
    else error("missing session id")
    end
  ' | git -C "$2" hash-object --stdin)" || return 1
  [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf 'git-%s' "$object_id"
}

# Keep legacy/manual invocations on their established path. Harness sessions get one
# opaque suffix shared by request, lock, dossier, and gate bookkeeping, so tasks using
# the same worktree cannot consume or cancel each other's runtime state.
verdict_audit_state_path() {  # base-path session-scope
  if [[ "$2" == "-" ]]; then
    printf '%s' "$1"
  else
    printf '%s.%s' "$1" "$2"
  fi
}

# INT/TERM has no UserPromptSubmit hook to revoke a session request. A generation-named
# tombstone gives the Stop gate an atomic, pathname-local way to reject late output from
# exactly that canceled run without racing a newer generation's request or dossier.
verdict_audit_cancellation_path() {  # state-dir session-scope generation
  printf '%s.%s' "$(verdict_audit_state_path "$1/verdict-canceled" "$2")" "$3"
}

# Cancellation is fail-closed. The canonical generation pathname itself (of any type)
# revokes authority, and a runner that cannot publish there may use one unpredictable
# fallback sibling. Literal directory scanning avoids shell-glob metacharacters in roots.
verdict_audit_cancellation_exists() {  # canonical-cancellation-path
  [[ -e "$1" || -L "$1" ]] && return 0
  perl -e '
    my $path = shift;
    my $slash = rindex($path, "/");
    exit 1 if $slash < 0;
    my $directory = substr($path, 0, $slash);
    my $prefix = substr($path, $slash + 1) . ".fallback-";
    opendir(my $dir, $directory) or exit 1;
    while (defined(my $entry = readdir($dir))) {
      if (index($entry, $prefix) == 0) { closedir($dir); exit 0 }
    }
    closedir($dir);
    exit 1;
  ' "$1"
}

verdict_audit_clear_cancellation_records() {  # canonical-cancellation-path
  perl -e '
    my $path = shift;
    unlink($path);
    my $slash = rindex($path, "/");
    exit 0 if $slash < 0;
    my $directory = substr($path, 0, $slash);
    my $prefix = substr($path, $slash + 1) . ".fallback-";
    if (opendir(my $dir, $directory)) {
      while (defined(my $entry = readdir($dir))) {
        unlink($directory . "/" . $entry) if index($entry, $prefix) == 0;
      }
      closedir($dir);
    }
  ' "$1"
}
