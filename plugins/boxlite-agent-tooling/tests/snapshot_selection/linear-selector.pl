# Reference selector from cba08ca75cc3a4dc991f238d3a036f0df2b8ae7a.
# Spliced into a temporary copy of the production reader; keep this scan unchanged.
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
