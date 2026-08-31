# Contributing

## Commit and PR messages

Use Conventional-Commit subjects no longer than 72 characters. Every pull
request description starts with `## Call graph` as its first non-blank content
and puts the changed end-to-end Before/After graph in one column-one `text`
fence. Bug fixes mark the faulty Before hop and put `Fixes #<n>` as the first
non-blank line after that fence.

````markdown
## Call graph

```text
Before
  exec_box            (BoxHandle · src/boxlite/src/portal/exec.rs:88)
    └─ open_console   (Jailer · src/boxlite/src/jailer/console.rs:41)  ← BUG: returns before the socket binds
         └─ attach_stdio (Guest · src/guest/src/io.rs:12)              — never reached

After
  exec_box            (BoxHandle · src/boxlite/src/portal/exec.rs:88)
    └─ open_console   (Jailer · src/boxlite/src/jailer/console.rs:41)  — awaits the bind future
         └─ attach_stdio (Guest · src/guest/src/io.rs:12)
```

Fixes #1042
````
