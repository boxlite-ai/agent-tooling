## TL;DR

Prepare assigned design review through independently usable runtime layers.

## Runtime preparation

The POSIX controller ends its own process group when either its supervisor channel closes or its leader dies.
The group launcher requires descriptor3 and waits for controller readiness before executing the worker.

For example, a dead leader with a still-open supervisor channel triggers descendant cleanup.
Native Linux and Windows qualification remains pending.

See the registered [design](https://github.com/boxlite-ai/agent-tooling/issues/354) for the complete gate contract.
