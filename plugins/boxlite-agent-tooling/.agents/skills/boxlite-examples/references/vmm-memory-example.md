# VMM memory: whole layout, mapping records, and one byte

**12 KiB RAM: 4 KiB program + 8 KiB data.** Linux/KVM, 4 KiB host pages.
Illustrative addresses, contents, and slots; not a live dump or bootable Linux.
At BoxLite `566f07eb`, the contract exists; the native backend remains a
[skeleton](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/README.md#L15-L29).

## Whole memory layout after registration

```text
Guest physical addresses                Host virtual addresses
                                        BoxLite-owned allocations

0x0000 +---------------------+
       | Unmapped            |
0x0FFF +---------------------+

0x1000 +---------------------+           +---------------------+ 0x70000000
       | Program             |  slot 0   | Program bytes       |
       | 4 KiB               | <=======> | 4 KiB allocation    |
0x1FFF +---------------------+           +---------------------+ 0x70000FFF

0x2000 +---------------------+           +---------------------+ 0x90000000
       | Data                |           |                     |
0x2010 | One byte: 00        |  slot 1   | Same byte: 00       | 0x90000010
       |                     | <=======> | 8 KiB allocation    |
       | Stack space         |           |                     |
0x3FFF +---------------------+           +---------------------+ 0x90001FFF

0x4000 +---------------------+
       | Remaining address   |
       | space: unmapped     |
       +---------------------+

<=======> means two address views of the SAME backing bytes.
```

Inclusive end addresses. Host addresses are virtual, not physical.

## Slot records and ownership

**Slots are separate mapping records**, outside guest RAM:

| KVM slot | Guest base | Host base | Size |
| --- | --- | --- | ---: |
| 0 | `0x1000` | `0x70000000` | 4,096 bytes |
| 1 | `0x2000` | `0x90000000` | 8,192 bytes |

Each slot maps a variable-sized range of existing host memory.
[KVM memory registration](https://docs.kernel.org/virt/kvm/api.html#kvm-set-user-memory-region).

```text
boxlite-vmm                 Owns backing RAM and chooses guest layout
    |
    | MemoryRegion { guest_addr, host_addr, size }
    v
boxlite-hypervisor::kvm      Assigns private slot IDs and registers mappings
    |
    v
KVM                         Makes those ranges accessible to the guest
```

Shared fields:
[`MemoryRegion`](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/src/memory.rs#L8-L21)
(no slot ID).

## Follow one byte

Initially: no allocations or slots. Ordered accesses, no concurrent writers.
The drawing shows the state after T2.

| Time | Input/action | State change | Output |
| --- | --- | --- | --- |
| T1 | Allocate and zero both host regions | 12 KiB exists; no slots registered | Two host pointers |
| T2 | Register both regions | Slots 0 and 1 exist; bytes unchanged | Guest can access those ranges |
| T3 | Guest stores `0x4B` at guest physical address `0x2010` | Backing byte changes `00 → 4B` | Guest store completes |
| T4 | Host reads `0x90000010` after the guest stops | No change | Reads `0x4B`, ASCII **K** |

```text
Offset within slot 1 = 0x2010 - 0x2000 = 0x10
Host address         = 0x90000000 + 0x10 = 0x90000010
```

Both accesses reach **the same byte**; the arithmetic locates a host pointer.

Release backing only after guest mappings and host accesses end:
[memory lifetime contract](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/src/vm.rs#L19-L41).
Recheck before claiming current implementation.
