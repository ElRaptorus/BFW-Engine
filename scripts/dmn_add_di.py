#!/usr/bin/env python3
"""Add DMNDI (DMN Diagram Interchange) coordinates to DMN files that lack them.

Usage:
    python3 scripts/dmn_add_di.py path/to/file.dmn   # single file
    python3 scripts/dmn_add_di.py path/to/dir         # all .dmn files in directory

Files that already contain a <dmndi:DMNDI> element are skipped.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

DMN_NS = "https://www.omg.org/spec/DMN/20191111/MODEL/"
DMNDI_NS = "https://www.omg.org/spec/DMN/20191111/DMNDI/"
DC_NS = "http://www.omg.org/spec/DMN/20180521/DC/"
DI_NS = "http://www.omg.org/spec/DMN/20180521/DI/"

SHAPE_TYPES = {"decision", "inputData", "businessKnowledgeModel", "knowledgeSource", "decisionService"}

DECISION_WIDTH = 180
DECISION_HEIGHT = 80
INPUT_DATA_WIDTH = 180
INPUT_DATA_HEIGHT = 45
BKM_WIDTH = 180
BKM_HEIGHT = 80
KS_WIDTH = 180
KS_HEIGHT = 80
DS_WIDTH = 200
DS_HEIGHT = 100

HORIZONTAL_SPACING = 240
VERTICAL_SPACING = 140

START_X = 100
START_Y = 100


def strip_ns(tag):
    """Remove namespace URI from an element tag."""
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


def get_local_href(href):
    """Extract local element ID from an href like '#Decision_A' or 'ns#Decision_A'."""
    if not href:
        return None
    if "#" in href:
        fragment = href.split("#", 1)[1]
        if href.startswith("#"):
            return fragment
        return None
    return None


def collect_elements(root):
    """Collect all DRD-visible elements and their relationships."""
    elements = {}
    edges = []

    for child in root:
        local_tag = strip_ns(child.tag)
        element_id = child.get("id")

        if local_tag in SHAPE_TYPES and element_id:
            elements[element_id] = {
                "id": element_id,
                "type": local_tag,
                "name": child.get("name", element_id),
                "dependencies": [],
            }

            for sub in child:
                sub_tag = strip_ns(sub.tag)

                if sub_tag == "informationRequirement":
                    req_id = sub.get("id")
                    for ref in sub:
                        ref_tag = strip_ns(ref.tag)
                        href = ref.get("href", "")
                        target = get_local_href(href)
                        if target and target in elements or target:
                            edge_type = "information"
                            edges.append({
                                "id": req_id or f"edge_{element_id}_{target}",
                                "source": target,
                                "target": element_id,
                                "type": edge_type,
                            })
                            elements[element_id]["dependencies"].append(target)

                elif sub_tag == "knowledgeRequirement":
                    req_id = sub.get("id")
                    for ref in sub:
                        ref_tag = strip_ns(ref.tag)
                        href = ref.get("href", "")
                        target = get_local_href(href)
                        if target:
                            edges.append({
                                "id": req_id or f"edge_{element_id}_{target}",
                                "source": target,
                                "target": element_id,
                                "type": "knowledge",
                            })
                            elements[element_id]["dependencies"].append(target)

                elif sub_tag == "authorityRequirement":
                    req_id = sub.get("id")
                    for ref in sub:
                        href = ref.get("href", "")
                        target = get_local_href(href)
                        if target:
                            edges.append({
                                "id": req_id or f"edge_{element_id}_{target}",
                                "source": target,
                                "target": element_id,
                                "type": "authority",
                            })
                            elements[element_id]["dependencies"].append(target)

    for child in root:
        local_tag = strip_ns(child.tag)
        if local_tag == "knowledgeSource":
            element_id = child.get("id")
            if element_id:
                for sub in child:
                    sub_tag = strip_ns(sub.tag)
                    if sub_tag == "authorityRequirement":
                        req_id = sub.get("id")
                        for ref in sub:
                            href = ref.get("href", "")
                            target = get_local_href(href)
                            if target:
                                edges.append({
                                    "id": req_id or f"edge_{element_id}_{target}",
                                    "source": target,
                                    "target": element_id,
                                    "type": "authority",
                                })
                                if element_id in elements:
                                    elements[element_id]["dependencies"].append(target)

    return elements, edges


def topological_layers(elements):
    """Assign elements to layers using topological sorting (Kahn's algorithm).

    Layer 0 = elements with no dependencies (inputs, standalone BKMs).
    Higher layers = elements that depend on lower layers.
    Elements in cycles get placed in a fallback layer.
    """
    in_degree = defaultdict(int)
    dependents = defaultdict(list)
    all_ids = set(elements.keys())

    for eid, edata in elements.items():
        local_deps = [d for d in edata["dependencies"] if d in all_ids]
        in_degree[eid] = len(local_deps)
        for dep in local_deps:
            dependents[dep].append(eid)

    layers = {}
    queue = [eid for eid in all_ids if in_degree[eid] == 0]
    current_layer = 0

    while queue:
        for eid in queue:
            layers[eid] = current_layer
        next_queue = []
        for eid in queue:
            for dep in dependents[eid]:
                in_degree[dep] -= 1
                if in_degree[dep] == 0:
                    next_queue.append(dep)
        queue = next_queue
        current_layer += 1

    for eid in all_ids:
        if eid not in layers:
            layers[eid] = current_layer

    return layers


def compute_layout(elements, layers):
    """Compute x,y positions for all elements.

    Layout: top-to-bottom, with layer 0 (inputs) at the bottom,
    highest layer (root decisions) at the top.
    """
    if not layers:
        return {}

    max_layer = max(layers.values())

    layer_groups = defaultdict(list)
    for eid, layer in layers.items():
        layer_groups[layer].append(eid)

    for layer in layer_groups:
        layer_groups[layer].sort()

    positions = {}
    for layer_num, eids in layer_groups.items():
        visual_row = max_layer - layer_num
        y = START_Y + visual_row * VERTICAL_SPACING

        total_width = len(eids) * DECISION_WIDTH + (len(eids) - 1) * (HORIZONTAL_SPACING - DECISION_WIDTH)
        start_x = START_X + max(0, (max_layer * HORIZONTAL_SPACING - total_width) // 2) if len(eids) > 0 else START_X

        for i, eid in enumerate(eids):
            x = start_x + i * HORIZONTAL_SPACING
            etype = elements[eid]["type"]

            if etype == "inputData":
                w, h = INPUT_DATA_WIDTH, INPUT_DATA_HEIGHT
            elif etype == "businessKnowledgeModel":
                w, h = BKM_WIDTH, BKM_HEIGHT
            elif etype == "knowledgeSource":
                w, h = KS_WIDTH, KS_HEIGHT
            elif etype == "decisionService":
                w, h = DS_WIDTH, DS_HEIGHT
            else:
                w, h = DECISION_WIDTH, DECISION_HEIGHT

            positions[eid] = {"x": x, "y": y, "width": w, "height": h}

    return positions


def generate_dmndi_xml(elements, edges, positions, indent="  "):
    """Generate the DMNDI XML block as a string."""
    lines = []
    lines.append(f"{indent}<dmndi:DMNDI>")
    lines.append(f"{indent}  <dmndi:DMNDiagram id=\"DMNDiagram_1\" name=\"DRD\">")

    for eid in sorted(positions.keys()):
        pos = positions[eid]
        shape_id = f"Shape_{eid}"
        lines.append(
            f'{indent}    <dmndi:DMNShape id="{shape_id}" dmnElementRef="{eid}">'
        )
        lines.append(
            f'{indent}      <dc:Bounds x="{pos["x"]}" y="{pos["y"]}" '
            f'width="{pos["width"]}" height="{pos["height"]}"/>'
        )
        lines.append(f"{indent}    </dmndi:DMNShape>")

    seen_edges = set()
    for edge in edges:
        source_id = edge["source"]
        target_id = edge["target"]

        if source_id not in positions or target_id not in positions:
            continue

        edge_key = (edge["id"], source_id, target_id)
        if edge_key in seen_edges:
            continue
        seen_edges.add(edge_key)

        source_pos = positions[source_id]
        target_pos = positions[target_id]

        source_center_x = source_pos["x"] + source_pos["width"] // 2
        source_top_y = source_pos["y"]
        target_center_x = target_pos["x"] + target_pos["width"] // 2
        target_bottom_y = target_pos["y"] + target_pos["height"]

        edge_id = f"Edge_{edge['id']}"
        dmn_element_ref = edge["id"]

        lines.append(
            f'{indent}    <dmndi:DMNEdge id="{edge_id}" dmnElementRef="{dmn_element_ref}">'
        )
        lines.append(
            f'{indent}      <di:waypoint x="{source_center_x}" y="{source_top_y}"/>'
        )
        lines.append(
            f'{indent}      <di:waypoint x="{target_center_x}" y="{target_bottom_y}"/>'
        )
        lines.append(f"{indent}    </dmndi:DMNEdge>")

    lines.append(f"{indent}  </dmndi:DMNDiagram>")
    lines.append(f"{indent}</dmndi:DMNDI>")

    return "\n".join(lines)


def ensure_namespace_declarations(content):
    """Ensure the definitions element has all required namespace declarations for DMNDI."""
    required_ns = {
        'xmlns:dmndi': f'"{DMNDI_NS}"',
        'xmlns:dc': f'"{DC_NS}"',
        'xmlns:di': f'"{DI_NS}"',
    }

    definitions_match = re.search(r"<definitions\b[^>]*>", content, re.DOTALL)
    if not definitions_match:
        return content

    definitions_tag = definitions_match.group(0)
    modified_tag = definitions_tag

    for attr, value in required_ns.items():
        if attr not in definitions_tag:
            insert_pos = modified_tag.rfind(">")
            modified_tag = modified_tag[:insert_pos] + f'\n             {attr}={value}' + modified_tag[insert_pos:]

    if modified_tag != definitions_tag:
        content = content.replace(definitions_tag, modified_tag, 1)

    return content


def process_file(filepath):
    """Process a single DMN file, adding DMNDI if missing."""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    if "<dmndi:DMNDI" in content:
        print(f"  SKIP (already has DMNDI): {filepath}")
        return False

    ET.register_namespace("", DMN_NS)
    try:
        root = ET.fromstring(content)
    except ET.ParseError as e:
        print(f"  ERROR (XML parse): {filepath}: {e}")
        return False

    elements, edges = collect_elements(root)

    if not elements:
        print(f"  SKIP (no DRD elements): {filepath}")
        return False

    layers = topological_layers(elements)
    positions = compute_layout(elements, layers)

    if not positions:
        print(f"  SKIP (no positions computed): {filepath}")
        return False

    content = ensure_namespace_declarations(content)

    dmndi_block = generate_dmndi_xml(elements, edges, positions)

    closing_tag = "</definitions>"
    if closing_tag not in content:
        print(f"  ERROR (no closing </definitions>): {filepath}")
        return False

    content = content.replace(closing_tag, f"\n{dmndi_block}\n{closing_tag}")

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    element_count = len(positions)
    edge_count = len([e for e in edges if e["source"] in positions and e["target"] in positions])
    print(f"  ADDED DMNDI: {filepath} ({element_count} shapes, {edge_count} edges)")
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 dmn_add_di.py <file_or_directory>")
        sys.exit(1)

    target = sys.argv[1]
    files = []

    if os.path.isfile(target):
        files = [target]
    elif os.path.isdir(target):
        for root_dir, _, filenames in os.walk(target):
            for fn in sorted(filenames):
                if fn.endswith(".dmn"):
                    files.append(os.path.join(root_dir, fn))
    else:
        print(f"ERROR: {target} is not a file or directory")
        sys.exit(1)

    modified = 0
    skipped = 0
    errors = 0

    print(f"Processing {len(files)} DMN file(s)...")
    for filepath in files:
        try:
            if process_file(filepath):
                modified += 1
            else:
                skipped += 1
        except Exception as e:
            print(f"  ERROR: {filepath}: {e}")
            errors += 1

    print(f"\nDone: {modified} modified, {skipped} skipped, {errors} errors")


if __name__ == "__main__":
    main()
