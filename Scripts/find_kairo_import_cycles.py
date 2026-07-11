#!/usr/bin/env python3
from __future__ import annotations

import argparse
import collections
import dataclasses
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Iterable, Mapping


IMPORT_RE = re.compile(
    r"(?m)^\s*(?:(?:pub|priv|prot)\s+)?import\s+"
    r"([A-Za-z_][A-Za-z0-9_]*(?:::(?:[A-Za-z_][A-Za-z0-9_]*|\*))*)"
    r"\s*;"
)


@dataclasses.dataclass(frozen=True, slots=True)
class ImportSite:
    raw: str
    line: int


@dataclasses.dataclass(slots=True)
class GraphResult:
    graph: dict[str, set[str]]
    edge_sites: dict[tuple[str, str], list[ImportSite]]
    unresolved: list[tuple[str, ImportSite]]
    ambiguous: list[tuple[str, ImportSite, tuple[str, ...]]]


def run_git(project: Path, args: list[str], *, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(project), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
        check=False,
    )


def normalize_root(project: Path, raw: str) -> str:
    path = (project / raw).resolve()
    try:
        rel = path.relative_to(project)
    except ValueError as exc:
        raise ValueError(f"source root escapes project root: {raw}") from exc
    return "." if rel == Path(".") else rel.as_posix().rstrip("/")


def under_root(path: str, root: str) -> bool:
    if root == ".":
        return True
    return path == root or path.startswith(root + "/")


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments while preserving newlines and string contents."""
    out: list[str] = []
    i = 0
    in_block = False
    quote: str | None = None
    escaped = False

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if in_block:
            if ch == "*" and nxt == "/":
                out.extend((" ", " "))
                i += 2
                in_block = False
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue

        if quote is not None:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
            i += 1
            continue

        if ch in ('"', "'"):
            quote = ch
            out.append(ch)
            i += 1
            continue

        if ch == "/" and nxt == "/":
            out.extend((" ", " "))
            i += 2
            while i < len(text) and text[i] != "\n":
                out.append(" ")
                i += 1
            continue

        if ch == "/" and nxt == "*":
            out.extend((" ", " "))
            i += 2
            in_block = True
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def extract_imports(text: str) -> list[ImportSite]:
    clean = strip_comments(text)
    sites: list[ImportSite] = []
    for match in IMPORT_RE.finditer(clean):
        line = clean.count("\n", 0, match.start()) + 1
        sites.append(ImportSite(match.group(1), line))
    return sites


def module_keys(path: str, roots: Iterable[str]) -> set[str]:
    without_suffix = PurePosixPath(path).with_suffix("")
    keys: set[str] = set()

    for root in roots:
        root_path = PurePosixPath(root)
        try:
            relative = without_suffix if root == "." else without_suffix.relative_to(root_path)
        except ValueError:
            continue

        if relative.parts:
            keys.add("::".join(relative.parts))

    return keys


def build_module_index(paths: Iterable[str], roots: list[str]) -> dict[str, tuple[str, ...]]:
    index: dict[str, set[str]] = collections.defaultdict(set)
    for path in paths:
        for key in module_keys(path, roots):
            index[key].add(path)
    return {key: tuple(sorted(values)) for key, values in index.items()}


def resolve_import(raw: str, index: Mapping[str, tuple[str, ...]]) -> tuple[str | None, tuple[str, ...]]:
    parts = raw.split("::")
    if parts and parts[-1] == "*":
        parts.pop()

    # Imports may end in a symbol. Resolve the longest prefix that names a file.
    for end in range(len(parts), 0, -1):
        key = "::".join(parts[:end])
        matches = index.get(key)
        if not matches:
            continue
        if len(matches) == 1:
            return matches[0], ()
        return None, matches

    return None, ()


def build_graph(contents: Mapping[str, str], roots: list[str]) -> GraphResult:
    paths = sorted(contents)
    index = build_module_index(paths, roots)
    graph = {path: set() for path in paths}
    edge_sites: dict[tuple[str, str], list[ImportSite]] = collections.defaultdict(list)
    unresolved: list[tuple[str, ImportSite]] = []
    ambiguous: list[tuple[str, ImportSite, tuple[str, ...]]] = []

    for source, text in contents.items():
        for site in extract_imports(text):
            target, candidates = resolve_import(site.raw, index)
            if target is not None:
                graph[source].add(target)
                edge_sites[(source, target)].append(site)
            elif candidates:
                ambiguous.append((source, site, candidates))
            else:
                unresolved.append((source, site))

    return GraphResult(graph, dict(edge_sites), unresolved, ambiguous)


def tarjan_scc(graph: Mapping[str, set[str]]) -> list[set[str]]:
    index = 0
    indices: dict[str, int] = {}
    lowlink: dict[str, int] = {}
    stack: list[str] = []
    on_stack: set[str] = set()
    result: list[set[str]] = []

    sys.setrecursionlimit(max(2000, len(graph) * 4))

    def visit(node: str) -> None:
        nonlocal index
        indices[node] = index
        lowlink[node] = index
        index += 1
        stack.append(node)
        on_stack.add(node)

        for target in graph.get(node, ()):
            if target not in indices:
                visit(target)
                lowlink[node] = min(lowlink[node], lowlink[target])
            elif target in on_stack:
                lowlink[node] = min(lowlink[node], indices[target])

        if lowlink[node] != indices[node]:
            return

        component: set[str] = set()
        while True:
            member = stack.pop()
            on_stack.remove(member)
            component.add(member)
            if member == node:
                break
        result.append(component)

    for node in graph:
        if node not in indices:
            visit(node)

    return result


def cyclic_components(graph: Mapping[str, set[str]]) -> list[set[str]]:
    result: list[set[str]] = []
    for component in tarjan_scc(graph):
        if len(component) > 1:
            result.append(component)
        else:
            node = next(iter(component))
            if node in graph.get(node, set()):
                result.append(component)
    return result


def shortest_path(
    graph: Mapping[str, set[str]],
    start: str,
    goal: str,
    allowed: set[str],
) -> list[str] | None:
    if start == goal:
        return [start]

    queue = collections.deque([start])
    previous: dict[str, str | None] = {start: None}

    while queue:
        node = queue.popleft()
        for target in sorted(graph.get(node, ())):
            if target not in allowed or target in previous:
                continue
            previous[target] = node
            if target == goal:
                path = [goal]
                cursor: str | None = goal
                while previous[cursor] is not None:
                    cursor = previous[cursor]
                    path.append(cursor)
                path.reverse()
                return path
            queue.append(target)

    return None


def representative_cycle(graph: Mapping[str, set[str]], component: set[str]) -> list[str]:
    best: list[str] | None = None

    for source in sorted(component):
        if source in graph.get(source, set()):
            candidate = [source, source]
            if best is None or len(candidate) < len(best):
                best = candidate

        for target in sorted(graph.get(source, set()) & component):
            if target == source:
                continue
            return_path = shortest_path(graph, target, source, component)
            if return_path is None:
                continue
            candidate = [source, *return_path]
            if best is None or len(candidate) < len(best):
                best = candidate

    if best is None:
        raise RuntimeError("internal error: cyclic SCC had no cycle")
    return best


def read_worktree(project: Path, roots: list[str]) -> dict[str, str]:
    contents: dict[str, str] = {}

    for root in roots:
        base = project if root == "." else project / root
        if not base.exists():
            raise FileNotFoundError(f"source root does not exist: {base}")
        for path in base.rglob("*.k"):
            if not path.is_file():
                continue
            rel = path.relative_to(project).as_posix()
            contents[rel] = path.read_text(encoding="utf-8", errors="replace")

    return contents


def read_revision(project: Path, revision: str, roots: list[str]) -> dict[str, str]:
    pathspecs = [] if roots == ["."] else roots
    listed = run_git(project, ["ls-tree", "-r", "--name-only", revision, "--", *pathspecs])
    if listed.returncode != 0:
        raise RuntimeError(listed.stderr.strip() or f"cannot read Git revision {revision}")

    contents: dict[str, str] = {}
    for path in listed.stdout.splitlines():
        if not path.endswith(".k") or not any(under_root(path, root) for root in roots):
            continue
        shown = run_git(project, ["show", f"{revision}:{path}"])
        if shown.returncode != 0:
            raise RuntimeError(shown.stderr.strip() or f"cannot read {revision}:{path}")
        contents[path] = shown.stdout

    return contents


def changed_files(project: Path, revision: str | None) -> set[str]:
    args = ["diff", "--name-only", "--diff-filter=ACMR"]
    if revision is not None:
        args.append(revision)
    args.append("--")

    changed = run_git(project, args)
    result = set(changed.stdout.splitlines()) if changed.returncode == 0 else set()

    untracked = run_git(project, ["ls-files", "--others", "--exclude-standard"])
    if untracked.returncode == 0:
        result.update(untracked.stdout.splitlines())

    return {path for path in result if path.endswith(".k")}


def edges(graph: Mapping[str, set[str]]) -> set[tuple[str, str]]:
    return {(source, target) for source, targets in graph.items() for target in targets}


def format_edge(
    source: str,
    target: str,
    edge_sites: Mapping[tuple[str, str], list[ImportSite]],
) -> str:
    sites = edge_sites.get((source, target), [])
    if not sites:
        return f"{source} -> {target}"
    first = min(sites, key=lambda site: site.line)
    return f"{source}:{first.line} --[{first.raw}]--> {target}"


def print_cycle(
    cycle: list[str],
    edge_sites: Mapping[tuple[str, str], list[ImportSite]],
    indent: str = "    ",
) -> None:
    for source, target in zip(cycle, cycle[1:]):
        print(indent + format_edge(source, target, edge_sites))


def write_dot(
    destination: Path,
    graph: Mapping[str, set[str]],
    components: list[set[str]],
    changed: set[str],
    new_edges: set[tuple[str, str]],
) -> None:
    cyclic_nodes = set().union(*components) if components else set()
    lines = ["digraph kairo_import_cycles {", '  rankdir="LR";']

    for node in sorted(cyclic_nodes):
        attrs = []
        if node in changed:
            attrs.append('shape="box"')
            attrs.append('style="bold"')
        attr_text = " [" + ", ".join(attrs) + "]" if attrs else ""
        lines.append(f'  "{node}"{attr_text};')

    for source in sorted(cyclic_nodes):
        for target in sorted(graph.get(source, set()) & cyclic_nodes):
            attrs = ' [penwidth="3"]' if (source, target) in new_edges else ""
            lines.append(f'  "{source}" -> "{target}"{attrs};')

    lines.append("}")
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Find circular Kairo imports and identify cycle-closing imports added since a Git revision."
    )
    parser.add_argument("project", nargs="?", default=".", help="repository root (default: current directory)")
    parser.add_argument(
        "--source-root",
        action="append",
        default=[],
        metavar="DIR",
        help="import namespace root; repeat for multiple roots (default: Compiler if present, otherwise .)",
    )
    parser.add_argument(
        "--compare",
        default="HEAD",
        metavar="REV",
        help="compare current graph against this Git revision (default: HEAD)",
    )
    parser.add_argument(
        "--no-compare",
        action="store_true",
        help="only inspect the current tree",
    )
    parser.add_argument(
        "--dot",
        type=Path,
        help="write cyclic subgraph as Graphviz DOT",
    )
    parser.add_argument(
        "--show-unresolved",
        action="store_true",
        help="print unresolved and ambiguous imports",
    )
    args = parser.parse_args()

    project = Path(args.project).resolve()
    if not project.is_dir():
        print(f"error: not a directory: {project}", file=sys.stderr)
        return 2

    raw_roots = args.source_root
    if not raw_roots:
        raw_roots = ["Compiler"] if (project / "Compiler").is_dir() else ["."]

    try:
        roots = [normalize_root(project, root) for root in raw_roots]
        current_contents = read_worktree(project, roots)
        current = build_graph(current_contents, roots)
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if not current_contents:
        print("error: no .k files found under source roots", file=sys.stderr)
        return 2

    compare_revision = None if args.no_compare else args.compare
    baseline: GraphResult | None = None
    if compare_revision is not None:
        try:
            baseline_contents = read_revision(project, compare_revision, roots)
            baseline = build_graph(baseline_contents, roots)
        except RuntimeError as exc:
            print(f"warning: baseline comparison disabled: {exc}", file=sys.stderr)
            compare_revision = None

    changed = changed_files(project, compare_revision)
    current_components = cyclic_components(current.graph)
    baseline_components = cyclic_components(baseline.graph) if baseline is not None else []

    baseline_signatures = {frozenset(component) for component in baseline_components}
    new_edges = edges(current.graph) - edges(baseline.graph) if baseline is not None else set()

    def component_priority(component: set[str]) -> tuple[int, int, int, tuple[str, ...]]:
        is_new = frozenset(component) not in baseline_signatures if baseline is not None else False
        touches_changed = bool(component & changed)
        internal_new_edges = sum(
            1 for source, target in new_edges if source in component and target in component
        )
        return (
            0 if is_new else 1,
            0 if touches_changed else 1,
            -internal_new_edges,
            tuple(sorted(component)),
        )

    current_components.sort(key=component_priority)

    print(f"scanned: {len(current_contents)} Kairo files")
    print(f"resolved import edges: {len(edges(current.graph))}")
    print(f"unresolved imports: {len(current.unresolved)}")
    print(f"ambiguous imports: {len(current.ambiguous)}")
    print(f"cyclic SCCs: {len(current_components)}")

    if baseline is not None:
        new_component_count = sum(
            1 for component in current_components
            if frozenset(component) not in baseline_signatures
        )
        print(f"new import edges since {compare_revision}: {len(new_edges)}")
        print(f"new cyclic SCCs since {compare_revision}: {new_component_count}")

    if current_components:
        print("\n=== CIRCULAR IMPORT COMPONENTS ===")
        for number, component in enumerate(current_components, 1):
            is_new = baseline is not None and frozenset(component) not in baseline_signatures
            tags = []
            if is_new:
                tags.append(f"NEW SINCE {compare_revision}")
            if component & changed:
                tags.append("TOUCHES CHANGED FILES")
            suffix = f" [{' | '.join(tags)}]" if tags else ""

            print(f"\n[{number}] {len(component)} file(s){suffix}")
            for member in sorted(component):
                marker = " *" if member in changed else ""
                print(f"  {member}{marker}")

            cycle = representative_cycle(current.graph, component)
            print("  representative shortest cycle:")
            print_cycle(cycle, current.edge_sites, indent="    ")

            internal_new = sorted(
                (source, target)
                for source, target in new_edges
                if source in component and target in component
            )
            if internal_new:
                print("  new internal import edges:")
                for source, target in internal_new:
                    print("    " + format_edge(source, target, current.edge_sites))

    cycle_closers: list[tuple[str, str, list[str]]] = []
    for source, target in sorted(new_edges):
        if source == target:
            cycle_closers.append((source, target, [source, source]))
            continue
        allowed = set(current.graph)
        return_path = shortest_path(current.graph, target, source, allowed)
        if return_path is not None:
            cycle_closers.append((source, target, [source, *return_path]))

    if baseline is not None and cycle_closers:
        print(f"\n=== NEW CYCLE-CLOSING EDGES SINCE {compare_revision} ===")
        for source, target, cycle in cycle_closers:
            print("\n  added edge:")
            print("    " + format_edge(source, target, current.edge_sites))
            print("  cycle completed by that edge:")
            print_cycle(cycle, current.edge_sites, indent="    ")

    if args.show_unresolved and (current.unresolved or current.ambiguous):
        print("\n=== UNRESOLVED IMPORTS ===")
        for source, site in sorted(current.unresolved, key=lambda item: (item[0], item[1].line)):
            print(f"  {source}:{site.line}: {site.raw}")

        print("\n=== AMBIGUOUS IMPORTS ===")
        for source, site, candidates in sorted(
            current.ambiguous, key=lambda item: (item[0], item[1].line)
        ):
            print(f"  {source}:{site.line}: {site.raw}")
            for candidate in candidates:
                print(f"    -> {candidate}")

    if args.dot is not None:
        try:
            write_dot(args.dot, current.graph, current_components, changed, new_edges)
            print(f"\nwrote DOT graph: {args.dot}")
        except OSError as exc:
            print(f"error: cannot write DOT graph: {exc}", file=sys.stderr)
            return 2

    return 1 if current_components else 0


if __name__ == "__main__":
    raise SystemExit(main())