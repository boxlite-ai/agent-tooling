## Architecture

### Current

<details>
<summary><code>overview</code> — How one BoxLite engine runs boxes on your machine and in your own cloud</summary>

```mermaid
flowchart TB
  classDef scope_external fill:#0b0c0d,stroke:#686f76,color:#8b949e,stroke-width:1.5px
  classDef scope_edge fill:#101111,stroke:#979da3,color:#c9d1d9,stroke-width:1.5px
  classDef scope_compute fill:#04110c,stroke:#279e73,color:#34d399,stroke-width:1.5px
  classDef scope_execution fill:#140f03,stroke:#bc8f1b,color:#fbbf24,stroke-width:1.5px
  classDef scope_state fill:#12080d,stroke:#a4497a,color:#db61a2,stroke-width:1.5px
  subgraph callers["External"]
    clients(["Browser, SDK or CLI"])
    registry(["OCI registry"])
    idp(["OIDC identity provider"])
  end
  subgraph local_machine["Your machine · your app, CLI or boxlite serve"]
    local_runtime["Embedded BoxLite runtime"]
    local_boxes[["Box micro-VMs"]]
  end
  subgraph cloud["Cloud · your AWS account or GCP project"]
    subgraph edge_zone["Public edge"]
      edge_lb["Load balancers · TLS"]
    end
    subgraph control_plane["Control plane"]
      api["API + dashboard"]
      proxy["Box proxy"]
    end
    subgraph runner_fleet["Runner fleet × N · nested KVM"]
      runner["Runner<br/>embedded BoxLite runtime"]
      cloud_boxes[["Box micro-VMs"]]
    end
    subgraph state_zone["State"]
      cloud_state[("PostgreSQL · Redis<br/>object storage")]
    end
  end
  registry o_registry_local@-->|"image layers"| local_runtime
  local_runtime o_local_boxes@-->|"create + run"| local_boxes
  clients o_clients_edge@-->|"HTTPS"| edge_lb
  edge_lb o_edge_api@-->|"API"| api
  edge_lb o_edge_proxy@-->|"box previews"| proxy
  idp o_idp_api@-.->|"JWKS keys"| api
  api o_api_runner@-->|"schedule boxes"| runner
  proxy o_proxy_runner@-->|"tunnel"| runner
  registry o_registry_runner@-->|"image layers"| runner
  runner o_runner_boxes@-->|"create + run"| cloud_boxes
  api o_api_state@-->|"state, queues"| cloud_state
  runner o_runner_volumes@-->|"volumes"| cloud_state
  class callers scope_external
  class edge_zone scope_edge
  class control_plane scope_compute
  class runner_fleet scope_execution
  class state_zone scope_state
```

<details>
<summary><code>local_machine</code> — How the BoxLite engine on your machine turns a call into a container in its own micro-VM</summary>

```mermaid
flowchart TB
  classDef default fill:#111418,stroke:#8b949e,color:#ffffff
  classDef accent fill:#002330,stroke:#00b0f0,color:#ffffff,stroke-width:2.5px
  classDef accent_zone fill:#000c11,stroke:#00b0f0,color:#00b0f0,stroke-width:2px
  linkStyle default stroke:#8b949e,stroke-width:1.5px
  classDef scope_external fill:#0b0c0d,stroke:#686f76,color:#8b949e,stroke-width:1.5px
  classDef scope_compute fill:#04110c,stroke:#279e73,color:#34d399,stroke-width:1.5px
  classDef scope_execution fill:#140f03,stroke:#bc8f1b,color:#fbbf24,stroke-width:1.5px
  classDef scope_state fill:#12080d,stroke:#a4497a,color:#db61a2,stroke-width:1.5px
  subgraph callers["External"]
    http_client(["HTTP client<br/>SDKs, CLI --url, curl"])
    registry(["OCI registry"])
  end
  subgraph host_process["Host process · your app, boxlite CLI, boxlite serve or a cloud runner"]
    sdk["SDK bindings<br/>Python · Node.js · Go · C"]
    rest["REST server<br/>boxlite serve :8100"]
    runtime["BoxliteRuntime"]
  end
  subgraph shim_process["boxlite-shim process × N · jailer: bwrap + seccomp or sandbox-exec"]
    vmm["VMM · libkrun<br/>on KVM or Hypervisor.framework<br/>PROPOSED: our own VMM and kernel, issue 1512"]
    gvproxy["gvproxy · network"]
    subgraph micro_vm["micro-VM · libkrunfw kernel"]
      agent["boxlite-guest · gRPC server"]
      container["OCI container · workload"]
    end
  end
  subgraph boxlite_home["State · ~/.boxlite"]
    box_files[("QCOW2 disks, shared dirs")]
    db[("Box database · SQLite")]
    images[("Image cache")]
  end
  http_client e_client_rest@-->|"HTTP /v1/boxes"| rest
  sdk e_sdk_runtime@-->|"Rust API"| runtime
  rest e_rest_runtime@-->|"Rust API"| runtime
  registry e_pull@-->|"image layers"| runtime
  runtime e_spawn_shim@-->|"spawns shim"| vmm
  runtime e_grpc@-->|"gRPC over vsock"| agent
  agent e_run_container@-->|"runs · libcontainer"| container
  vmm e_net@-->|"virtio-net"| gvproxy
  vmm e_block@-->|"virtio-blk · virtio-fs"| box_files
  runtime e_disks@-->|"create disks"| box_files
  runtime e_db@-->|"box state"| db
  runtime e_cache@-->|"cache layers"| images
  class callers scope_external
  class host_process scope_compute
  class shim_process scope_execution
  class boxlite_home scope_state
  class vmm accent
  class micro_vm accent_zone
```

</details>

</details>
