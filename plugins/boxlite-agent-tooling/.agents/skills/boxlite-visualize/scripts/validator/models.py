from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

Status = Literal["pass", "fail", "error"]

SCOPE_NAMES = ("external", "edge", "compute", "execution", "state", "observability")
# Dark zone cards: the fill is 8% of the role hue over black and the title wears the hue,
# so zones read as cards on both GitHub themes. Hues match figure.style.ROLE_HUES.
SCOPE_PALETTE = {
    "scope_external": "fill:#0b0c0d,stroke:#686f76,color:#8b949e,stroke-width:1.5px",
    "scope_edge": "fill:#101111,stroke:#979da3,color:#c9d1d9,stroke-width:1.5px",
    "scope_compute": "fill:#04110c,stroke:#279e73,color:#34d399,stroke-width:1.5px",
    "scope_execution": "fill:#140f03,stroke:#bc8f1b,color:#fbbf24,stroke-width:1.5px",
    "scope_state": "fill:#12080d,stroke:#a4497a,color:#db61a2,stroke-width:1.5px",
    "scope_observability": "fill:#110703,stroke:#a3431c,color:#d95926,stroke-width:1.5px",
}
# Every node is a dark card; cyan marks the diagram's subject on at most two elements.
HOUSE_CLASSES = {
    "default": "fill:#111418,stroke:#8b949e,color:#ffffff",
    "accent": "fill:#002330,stroke:#00b0f0,color:#ffffff,stroke-width:2.5px",
    "accent_zone": "fill:#000c11,stroke:#00b0f0,color:#00b0f0,stroke-width:2px",
}
# Grey edges stay visible on white pages and on dark zone cards alike.
HOUSE_LINK_STYLE = "stroke:#8b949e,stroke-width:1.5px"
MAX_ACCENTS = 2


@dataclass(frozen=True)
class Check:
    name: str
    status: Status
    message: str
    evidence: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "status": self.status,
            "message": self.message,
            "evidence": list(self.evidence),
        }


@dataclass
class StateBlock:
    view: str
    state: str
    label: str
    language: str
    content: str
    start_line: int
    topic: str = "overview"


@dataclass
class ParsedDocument:
    text: str
    blocks: dict[tuple[str, str], StateBlock] = field(default_factory=dict)
    architecture_nodes: dict[tuple[str, str], str] = field(default_factory=dict)
    architecture_edges: dict[tuple[str, str], tuple[str, str]] = field(default_factory=dict)
    architecture_edge_labels: dict[tuple[str, str], str] = field(default_factory=dict)
    architecture_boundaries: dict[tuple[str, str], str] = field(default_factory=dict)
    architecture_parents: dict[tuple[str, str], str] = field(default_factory=dict)
    architecture_scopes: dict[tuple[str, str], str] = field(default_factory=dict)
    architecture_accent_zones: set[tuple[str, str]] = field(default_factory=set)
    sequence_nodes: dict[tuple[str, str], str] = field(default_factory=dict)
    sequence_edges: dict[tuple[str, str], tuple[str, str]] = field(default_factory=dict)
    sequence_edge_labels: dict[tuple[str, str], str] = field(default_factory=dict)
    call_graph_nodes: dict[tuple[str, str], dict[str, Any]] = field(default_factory=dict)
    call_graph_edges: dict[tuple[str, str], tuple[str, str]] = field(default_factory=dict)
    rendered_svgs: dict[tuple[str, str], Path] = field(default_factory=dict)


@dataclass
class ValidationContext:
    repo: Path
    document_path: Path
    evidence_path: Path
    report_path: Path
    manifest: Any
    nested: bool = False
    checks: list[Check] = field(default_factory=list)
    parsed: ParsedDocument | None = None
    source_windows: dict[tuple[str, str, int, int], str] = field(default_factory=dict)
    remote_issues: dict[int, dict[str, Any]] = field(default_factory=dict)
    remote_prs: dict[int, dict[str, Any]] = field(default_factory=dict)
    artifacts: list[Path] = field(default_factory=list)

    def add(
        self,
        name: str,
        status: Status,
        message: str,
        evidence: list[str] | tuple[str, ...] = (),
    ) -> None:
        self.checks.append(Check(name, status, message, tuple(evidence)))

    @property
    def has_failures(self) -> bool:
        return any(check.status == "fail" for check in self.checks)

    @property
    def has_tool_errors(self) -> bool:
        return any(check.status == "error" for check in self.checks)

    def items(self) -> list[tuple[str, dict[str, Any]]]:
        if not isinstance(self.manifest, dict):
            return []
        return [
            ("node", item) for item in self.manifest.get("nodes", [])
        ] + [
            ("edge", item) for item in self.manifest.get("edges", [])
        ] + [
            ("boundary", item) for item in self.manifest.get("boundaries", [])
        ]

    def item_map(self, item_type: str) -> dict[str, dict[str, Any]]:
        if item_type not in {"node", "edge", "boundary"} or not isinstance(self.manifest, dict):
            return {}
        key = {"node": "nodes", "edge": "edges", "boundary": "boundaries"}[item_type]
        return {item["id"]: item for item in self.manifest.get(key, []) if "id" in item}

    def state_map(self) -> dict[str, dict[str, Any]]:
        if not isinstance(self.manifest, dict):
            return {}
        return {state["id"]: state for state in self.manifest.get("states", []) if "id" in state}

    def view_ids(self) -> list[str]:
        if not isinstance(self.manifest, dict):
            return []
        views = self.manifest.get("views")
        if isinstance(views, list):
            return [view for view in views if isinstance(view, str)]
        return ["architecture", "sequence", "call_graph"]
