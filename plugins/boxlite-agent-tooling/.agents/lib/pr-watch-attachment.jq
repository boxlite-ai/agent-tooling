# Pre-push attachment manifest schema, shared by the post-write hook and the
# attach consumer. Callers keep their own creation windows and bindings.

# Lifecycle fields: owner, prompt epoch, and a creation time within $window seconds.
def pr_watch_attachment_lifecycle($now; $window):
  type == "object" and .schema == 1
  and (keys | sort) == ["command_hash","created_at","entries","omitted_refs",
                        "owner","prompt_epoch","schema","session_scope"]
  and (.command_hash | type == "string" and test("^[0-9a-f]{64}$"))
  and (.session_scope | type == "string"
       and test("^git-[0-9a-f]{40}([0-9a-f]{24})?$"))
  and (.prompt_epoch | type == "string"
       and test("^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$"))
  and (.created_at | type == "number" and floor == .
       and . <= $now and . >= ($now - $window))
  and (.owner | type == "object" and (keys | sort) == ["pid","start_token"])
  and (.owner.pid | type == "number" and . > 0 and floor == .)
  and (.owner.start_token | type == "string" and test("^cksum-[0-9]+-[0-9]+$"));

# One to four pushed refs, each bound to its watch generation and event log.
def pr_watch_attachment_entries:
  type == "object" and .schema == 1
  and (.entries | type == "array" and length > 0 and length <= 4)
  and (.omitted_refs | type == "number" and . >= 0 and . <= 1000000 and floor == .)
  and all(.entries[];
    (keys | sort) == ["branch","event_log","remote_ref","watch_id"]
    and (.remote_ref | type == "string" and startswith("refs/heads/"))
    and (.branch | type == "string" and length > 0)
    and .remote_ref == ("refs/heads/" + .branch)
    and (.watch_id | type == "string" and test("^watch-[0-9a-f]{24}$"))
    and (.event_log | type == "string" and startswith("/") and endswith(".jsonl")));
