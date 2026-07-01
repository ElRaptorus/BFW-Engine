#!/usr/bin/env python3
"""
bpmn_add_di.py — Add BPMN DI (Diagram Interchange) coordinates to BPMN files.

Parses each .bpmn file, performs left-to-right auto-layout using
longest-path layering, and appends a <bpmndi:BPMNDiagram> section so
the diagram is visible in BPMN modelers (Evil Studio, bpmn.io, etc.).

Usage:
    python3 bpmn_add_di.py <path> [<path> ...]

Each <path> can be a .bpmn file or a directory (searched recursively).
Files that already contain a <bpmndi:BPMNDiagram> element are skipped.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict, deque


# ── Element dimensions (px, matching bpmn-js defaults) ──────────

EVENT_W, EVENT_H = 36, 36
TASK_W, TASK_H = 100, 80
GATEWAY_W, GATEWAY_H = 50, 50
DATA_OBJ_W, DATA_OBJ_H = 36, 50

# ── Layout tuning ───────────────────────────────────────────────

X_SPACING = 160
Y_SPACING = 100
BASE_X = 180
LANE_Y_PAD = 30

# ── BPMN element type sets ──────────────────────────────────────

EVENT_TAGS = frozenset({
    "startEvent", "endEvent", "intermediateCatchEvent",
    "intermediateThrowEvent", "boundaryEvent",
})
TASK_TAGS = frozenset({
    "task", "userTask", "serviceTask", "manualTask", "scriptTask",
    "businessRuleTask", "sendTask", "receiveTask", "callActivity",
    "subProcess",
})
GATEWAY_TAGS = frozenset({
    "exclusiveGateway", "parallelGateway", "inclusiveGateway",
    "eventBasedGateway", "complexGateway",
})
ALL_FLOW_NODE_TAGS = EVENT_TAGS | TASK_TAGS | GATEWAY_TAGS


def local_name(element):
    tag = element.tag
    return tag.split("}", 1)[1] if tag.startswith("{") else tag


def element_size(kind):
    if kind in EVENT_TAGS:
        return EVENT_W, EVENT_H
    if kind in TASK_TAGS:
        return TASK_W, TASK_H
    if kind in GATEWAY_TAGS:
        return GATEWAY_W, GATEWAY_H
    return TASK_W, TASK_H


# ── Data classes ────────────────────────────────────────────────


class Node:
    __slots__ = ("id", "kind", "name", "attached_to", "w", "h", "cx", "cy")

    def __init__(self, nid, kind, name=None, attached_to=None):
        self.id = nid
        self.kind = kind
        self.name = name
        self.attached_to = attached_to
        self.w, self.h = element_size(kind)
        self.cx = 0.0
        self.cy = 0.0


class Edge:
    __slots__ = ("id", "source", "target")

    def __init__(self, eid, source, target):
        self.id = eid
        self.source = source
        self.target = target


class DataObjRef:
    __slots__ = ("id", "name", "x", "y", "w", "h")

    def __init__(self, nid, name=None):
        self.id = nid
        self.name = name
        self.w, self.h = DATA_OBJ_W, DATA_OBJ_H
        self.x = 0
        self.y = 0


class LaneInfo:
    __slots__ = ("id", "name", "refs", "x", "y", "w", "h")

    def __init__(self, lid, name, refs):
        self.id = lid
        self.name = name
        self.refs = refs
        self.x = self.y = self.w = self.h = 0


# ── Process extraction & layout ─────────────────────────────────


class Process:
    def __init__(self, pid, name):
        self.id = pid
        self.name = name
        self.nodes = {}
        self.edges = []
        self.data_refs = []
        self.lanes = []
        self.boundary_map = {}

    def extract(self, element):
        for child in element:
            tag = local_name(child)
            eid = child.get("id")

            if tag in ALL_FLOW_NODE_TAGS and eid:
                attached = child.get("attachedToRef")
                self.nodes[eid] = Node(eid, tag, child.get("name"), attached)
                if tag == "boundaryEvent" and attached:
                    self.boundary_map[eid] = attached

            elif tag == "sequenceFlow" and eid:
                source = child.get("sourceRef")
                target = child.get("targetRef")
                if source and target:
                    self.edges.append(Edge(eid, source, target))

            elif tag == "dataObjectReference" and eid:
                self.data_refs.append(DataObjRef(eid, child.get("name")))

            elif tag == "laneSet":
                for lane_element in child:
                    if local_name(lane_element) == "lane":
                        lid = lane_element.get("id")
                        lname = lane_element.get("name", "")
                        refs = []
                        for ref_element in lane_element:
                            if local_name(ref_element) == "flowNodeRef" and ref_element.text:
                                refs.append(ref_element.text.strip())
                        if lid:
                            self.lanes.append(LaneInfo(lid, lname, refs))

    def layout(self, base_y=200):
        if not self.nodes:
            return

        boundary_ids = set(self.boundary_map.keys())
        main_ids = set(self.nodes.keys()) - boundary_ids

        outgoing = defaultdict(list)
        incoming = defaultdict(list)
        for edge in self.edges:
            source = edge.source if edge.source not in boundary_ids else self.boundary_map.get(edge.source, edge.source)
            target = edge.target
            if source in main_ids and target in main_ids:
                outgoing[source].append(target)
                incoming[target].append(source)

        # Longest-path layering via Kahn's algorithm
        in_degree = {node_id: len(incoming.get(node_id, [])) for node_id in main_ids}
        sources = [node_id for node_id in main_ids if in_degree[node_id] == 0]
        if not sources:
            sources = [node_id for node_id in main_ids if self.nodes[node_id].kind == "startEvent"]
        if not sources:
            sources = [next(iter(main_ids))]

        layer_of = {node_id: 0 for node_id in main_ids}
        queue = deque(sources)
        visited = set()

        while queue:
            current = queue.popleft()
            visited.add(current)
            for target in outgoing.get(current, []):
                layer_of[target] = max(layer_of[target], layer_of[current] + 1)
                in_degree[target] -= 1
                if in_degree[target] == 0:
                    queue.append(target)

        for node_id in main_ids:
            if node_id not in visited:
                layer_of[node_id] = max(layer_of.values(), default=0) + 1

        layers = defaultdict(list)
        for node_id, layer_index in layer_of.items():
            layers[layer_index].append(node_id)

        # Assign coordinates layer by layer
        node_y_center = {}
        for layer_index in sorted(layers.keys()):
            members = layers[layer_index]
            center_x = BASE_X + layer_index * X_SPACING

            if layer_index == 0:
                count = len(members)
                total_span = (count - 1) * Y_SPACING
                start_y = base_y - total_span / 2
                for position, node_id in enumerate(members):
                    self.nodes[node_id].cx = center_x
                    self.nodes[node_id].cy = start_y + position * Y_SPACING
                    node_y_center[node_id] = self.nodes[node_id].cy
            else:

                def predecessor_median_y(node_id):
                    predecessors = incoming.get(node_id, [])
                    y_values = sorted(node_y_center[predecessor] for predecessor in predecessors if predecessor in node_y_center)
                    if not y_values:
                        return base_y
                    return y_values[len(y_values) // 2]

                members.sort(key=predecessor_median_y)
                count = len(members)

                if count == 1:
                    node_id = members[0]
                    self.nodes[node_id].cx = center_x
                    self.nodes[node_id].cy = predecessor_median_y(node_id)
                    node_y_center[node_id] = self.nodes[node_id].cy
                else:
                    ideal_y_values = [predecessor_median_y(member) for member in members]
                    center_y = sum(ideal_y_values) / len(ideal_y_values)
                    total_span = (count - 1) * Y_SPACING
                    start_y = center_y - total_span / 2
                    for position, node_id in enumerate(members):
                        self.nodes[node_id].cx = center_x
                        self.nodes[node_id].cy = start_y + position * Y_SPACING
                        node_y_center[node_id] = self.nodes[node_id].cy

        # Position boundary events on the bottom border of their host
        host_boundaries = defaultdict(list)
        for boundary_id, host_id in self.boundary_map.items():
            host_boundaries[host_id].append(boundary_id)

        for host_id, boundary_ids_list in host_boundaries.items():
            host = self.nodes.get(host_id)
            if not host:
                continue
            count = len(boundary_ids_list)
            spacing = host.w / (count + 1)
            for position, boundary_id in enumerate(boundary_ids_list):
                boundary_node = self.nodes[boundary_id]
                boundary_node.cx = host.cx - host.w / 2 + spacing * (position + 1)
                boundary_node.cy = host.cy + host.h / 2

        # Position data object references below the flow
        if self.data_refs:
            all_bottoms = [node.cy + node.h / 2 for node in self.nodes.values()]
            max_bottom = max(all_bottoms) if all_bottoms else base_y
            data_object_y = max_bottom + 60
            for position, data_ref in enumerate(self.data_refs):
                data_ref.x = int(BASE_X + position * 120 - data_ref.w / 2)
                data_ref.y = int(data_object_y)

        # Size lanes to wrap their elements
        if self.lanes:
            all_nodes_list = list(self.nodes.values())
            if all_nodes_list:
                min_left = min(node.cx - node.w / 2 for node in all_nodes_list) - 50
                max_right = max(node.cx + node.w / 2 for node in all_nodes_list) + 50
                min_top = min(node.cy - node.h / 2 for node in all_nodes_list) - LANE_Y_PAD
                max_bottom = max(node.cy + node.h / 2 for node in all_nodes_list) + LANE_Y_PAD

                if len(self.lanes) == 1:
                    lane = self.lanes[0]
                    lane.x = int(min_left)
                    lane.y = int(min_top)
                    lane.w = int(max_right - min_left)
                    lane.h = int(max_bottom - min_top)
                else:
                    lane_height = int((max_bottom - min_top) / len(self.lanes))
                    for lane_index, lane in enumerate(self.lanes):
                        lane.x = int(min_left)
                        lane.y = int(min_top + lane_index * lane_height)
                        lane.w = int(max_right - min_left)
                        lane.h = lane_height

    def generate_di(self, diagram_index=1):
        lines = []
        diagram_id = f"BPMNDiagram_{diagram_index}"
        plane_id = f"BPMNPlane_{diagram_index}"

        lines.append(f'  <bpmndi:BPMNDiagram id="{diagram_id}">')
        lines.append(f'    <bpmndi:BPMNPlane id="{plane_id}" bpmnElement="{self.id}">')

        for lane in self.lanes:
            shape_id = f"Shape_{lane.id}"
            lines.append(f'      <bpmndi:BPMNShape id="{shape_id}" bpmnElement="{lane.id}" isHorizontal="true">')
            lines.append(f'        <dc:Bounds x="{lane.x}" y="{lane.y}" width="{lane.w}" height="{lane.h}" />')
            lines.append(f"      </bpmndi:BPMNShape>")

        for node_id, node in self.nodes.items():
            shape_id = f"Shape_{node_id}"
            bounds_x = int(node.cx - node.w / 2)
            bounds_y = int(node.cy - node.h / 2)
            lines.append(f'      <bpmndi:BPMNShape id="{shape_id}" bpmnElement="{node_id}">')
            lines.append(f'        <dc:Bounds x="{bounds_x}" y="{bounds_y}" width="{node.w}" height="{node.h}" />')
            lines.append(f"      </bpmndi:BPMNShape>")

        for data_ref in self.data_refs:
            shape_id = f"Shape_{data_ref.id}"
            lines.append(f'      <bpmndi:BPMNShape id="{shape_id}" bpmnElement="{data_ref.id}">')
            lines.append(f'        <dc:Bounds x="{data_ref.x}" y="{data_ref.y}" width="{data_ref.w}" height="{data_ref.h}" />')
            lines.append(f"      </bpmndi:BPMNShape>")

        for edge in self.edges:
            source_node = self.nodes.get(edge.source)
            target_node = self.nodes.get(edge.target)
            if not source_node or not target_node:
                continue

            edge_id = f"Edge_{edge.id}"

            if source_node.kind == "boundaryEvent":
                source_x = int(source_node.cx)
                source_y = int(source_node.cy + source_node.h / 2)
            else:
                source_x = int(source_node.cx + source_node.w / 2)
                source_y = int(source_node.cy)

            target_x = int(target_node.cx - target_node.w / 2)
            target_y = int(target_node.cy)

            lines.append(f'      <bpmndi:BPMNEdge id="{edge_id}" bpmnElement="{edge.id}">')
            lines.append(f'        <di:waypoint x="{source_x}" y="{source_y}" />')

            if abs(source_y - target_y) > 10 and abs(source_x - target_x) > 50:
                midpoint_x = (source_x + target_x) // 2
                lines.append(f'        <di:waypoint x="{midpoint_x}" y="{source_y}" />')
                lines.append(f'        <di:waypoint x="{midpoint_x}" y="{target_y}" />')

            lines.append(f'        <di:waypoint x="{target_x}" y="{target_y}" />')
            lines.append(f"      </bpmndi:BPMNEdge>")

        lines.append(f"    </bpmndi:BPMNPlane>")
        lines.append(f"  </bpmndi:BPMNDiagram>")
        return "\n".join(lines)


# ── Namespace injection ─────────────────────────────────────────

NS_BPMNDI = 'xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"'
NS_DC = 'xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"'
NS_DI = 'xmlns:di="http://www.omg.org/spec/DD/20100524/DI"'


def ensure_namespace_declarations(content):
    match = re.search(r"(<(?:bpmn:)?definitions\b)([^>]*)(>)", content, re.DOTALL)
    if not match:
        return content

    attributes = match.group(2)
    additions = []
    if "xmlns:bpmndi=" not in attributes:
        additions.append(NS_BPMNDI)
    if "xmlns:dc=" not in attributes:
        additions.append(NS_DC)
    if "xmlns:di=" not in attributes:
        additions.append(NS_DI)

    if not additions:
        return content

    indent_match = re.search(r"\n(\s+)xmlns:", attributes)
    if indent_match:
        indent = indent_match.group(1)
    else:
        indent = "                  "

    new_attributes = attributes
    for addition in additions:
        new_attributes += "\n" + indent + addition

    replacement = match.group(1) + new_attributes + match.group(3)
    return content[: match.start()] + replacement + content[match.end() :]


# ── File processing ─────────────────────────────────────────────


def process_file(filepath):
    with open(filepath, "r", encoding="utf-8") as file_handle:
        content = file_handle.read()

    if "<bpmndi:BPMNDiagram" in content:
        return False, "already has DI"

    try:
        root = ET.fromstring(content)
    except ET.ParseError as error:
        return False, f"XML parse error: {error}"

    processes = []
    for child in root:
        if local_name(child) == "process":
            process_id = child.get("id", "Process_unknown")
            process_object = Process(process_id, child.get("name", ""))
            process_object.extract(child)
            if process_object.nodes:
                processes.append(process_object)

    if not processes:
        return False, "no flow nodes"

    vertical_offset = 0
    diagram_parts = []
    for index, process_object in enumerate(processes):
        process_base_y = 200 + vertical_offset
        process_object.layout(process_base_y)
        diagram_parts.append(process_object.generate_di(index + 1))

        all_bottoms = [node.cy + node.h / 2 for node in process_object.nodes.values()]
        if process_object.data_refs:
            all_bottoms += [data_ref.y + data_ref.h for data_ref in process_object.data_refs]
        vertical_offset = int(max(all_bottoms, default=process_base_y) - 200 + 120)

    diagram_xml = "\n".join(diagram_parts)

    content = ensure_namespace_declarations(content)

    close_match = re.search(r"(</(?:bpmn:)?definitions>)", content)
    if close_match:
        content = (
            content[: close_match.start()].rstrip()
            + "\n"
            + diagram_xml
            + "\n"
            + close_match.group(1)
            + content[close_match.end() :]
        )

    with open(filepath, "w", encoding="utf-8") as file_handle:
        file_handle.write(content)

    return True, f"{len(processes)} process(es)"


def main():
    paths = sys.argv[1:]
    if not paths:
        print("Usage: python3 bpmn_add_di.py <path> [<path> ...]", file=sys.stderr)
        sys.exit(1)

    files = []
    for path in paths:
        if os.path.isfile(path) and path.endswith(".bpmn"):
            files.append(path)
        elif os.path.isdir(path):
            for directory, _subdirectories, filenames in os.walk(path):
                for filename in filenames:
                    if filename.endswith(".bpmn"):
                        files.append(os.path.join(directory, filename))

    updated_count = 0
    skipped_count = 0
    error_count = 0

    for filepath in sorted(files):
        success, message = process_file(filepath)
        relative_path = os.path.relpath(filepath)
        if success:
            updated_count += 1
            print(f"  + {relative_path}  ({message})")
        elif "already" in message:
            skipped_count += 1
            print(f"  ~ {relative_path}  ({message})")
        else:
            error_count += 1
            print(f"  ! {relative_path}  ({message})")

    print(f"\nDone: {updated_count} updated, {skipped_count} skipped, {error_count} errors")


if __name__ == "__main__":
    main()
