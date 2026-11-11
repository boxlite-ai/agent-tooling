## TL;DR

Prepare the assigned design-worker runtime in independently tested layers.

## Runtime preparation

| Layer | Contract |
| --- | --- |
| Broker and streams | Read tracked snapshots and approved public research; bound worker input, output, and collection time. |
| Process ownership | Own worker and broker lifetimes; serialize explicit design transactions across a clone. |
| Launch inputs | Preserve exact snapshot bytes and construct restricted host profiles from installed policy. |
| Publication | Assign a task, collect its result, and serialize publication with human decisions. |
| Gate activation | Route normal host hooks through the assigned worker and reject public recorder submissions. |

The private coordinator CLI launches assigned workers; normal edit hooks retain native dispatch during integration.

Controllers signal their own process groups; the parent signals only its owned child processes.
