# VMM memory: whole layout, mapping records, and one byte

Imagine a tiny BoxLite VM with **12 KiB of RAM**: 4 KiB for a program and 8 KiB
for its data. This illustrates the Linux/KVM design with a 4 KiB host page size.
Addresses, contents, and slot choices are illustrative; this is not a live dump
or a bootable Linux layout. At BoxLite revision `566f07eb`, the memory contract
exists and the native backend is still a
[skeleton](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/README.md#L15-L29).

The spatial sketch shows both regions together. The slot table separates mapping
metadata from RAM contents; the timeline follows one concrete byte.

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

All displayed end addresses are inclusive. These host addresses are process
virtual addresses; the drawing does not imply contiguous physical host RAM.

## Slot records and ownership

**Slots are separate mapping records**, outside guest RAM:

| KVM slot | Guest base | Host base | Size |
| --- | --- | --- | ---: |
| 0 | `0x1000` | `0x70000000` | 4,096 bytes |
| 1 | `0x2000` | `0x90000000` | 8,192 bytes |

A slot describes a range; its size varies. Registration connects existing host
memory to guest addresses.
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

The shared
[`MemoryRegion`](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/src/memory.rs#L8-L21)
contains no KVM slot ID. Slot allocation stays inside the
[KVM backend](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/README.md#L26-L29).

## Follow one byte

Initially, no host allocations or registered slots exist. Assume the guest and
host access the byte in the order shown, with no concurrent writer. T1–T4 indicate
order, not measured duration; the layout above is the state after T2.

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

The guest write and host read access **the same byte**. This calculation locates
the host pointer; it is not an extra guest hardware translation stage.

Keep the backing alive until the guest mapping is gone and every host user has
finished, as required by the
[memory lifetime contract](https://github.com/boxlite-ai/boxlite/blob/566f07eb12893a2950a37a40279d16103974812f/src/hypervisor/src/vm.rs#L19-L41).
Recheck source before presenting this design snapshot as current implementation.
