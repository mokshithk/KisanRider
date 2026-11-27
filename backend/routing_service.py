"""
Routing and optimization service for KisanRider freight pooling.

Uses:
1. OpenStreetMap OSRM road-network distance/duration table API
2. Google OR-Tools vehicle routing / Travelling Salesperson Problem (TSP) solver
   with fixed start (rider GPS) and fixed end (common dropoff mandi)
3. OSRM route API for road-following polyline coordinates
4. Fallback deterministic solver using Haversine distance matrix + OR-Tools
   when external OSRM is unreachable or times out
"""

import logging
import math
from typing import Any, Dict, List, Optional, Tuple
import requests
from ortools.constraint_solver import pywrapcp, routing_enums_pb2

logger = logging.getLogger(__name__)

OSRM_TABLE_URL = "http://router.project-osrm.org/table/v1/driving/{coords}"
OSRM_ROUTE_URL = "http://router.project-osrm.org/route/v1/driving/{coords}"
OSRM_TIMEOUT_SECONDS = 5.0


def haversine_distance_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculate the great circle distance between two points in meters."""
    r = 6371000.0  # Earth radius in meters
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)

    a = (
        math.sin(delta_phi / 2.0) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
    )
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return r * c


def get_osrm_distance_matrix(
    coords: List[Tuple[float, float]]
) -> Optional[Tuple[List[List[float]], List[List[float]]]]:
    """
    Query OSRM table service for distance (meters) and duration (seconds) matrix.
    `coords` is a list of (lat, lng) tuples.
    Returns (distance_matrix, duration_matrix) or None if request fails.
    """
    if len(coords) < 2:
        return None

    # OSRM expects {lng},{lat};{lng},{lat}...
    formatted_coords = ";".join(f"{round(lng, 6)},{round(lat, 6)}" for lat, lng in coords)
    url = OSRM_TABLE_URL.format(coords=formatted_coords)

    try:
        resp = requests.get(
            url,
            params={"annotations": "distance,duration"},
            timeout=OSRM_TIMEOUT_SECONDS,
            headers={"User-Agent": "KisanRider-RouteEngine/1.0"},
        )
        if resp.status_code == 200:
            data = resp.json()
            if data.get("code") == "Ok":
                distances = data.get("distances")
                durations = data.get("durations")
                if distances and durations:
                    return distances, durations
    except Exception as e:
        logger.warning(f"OSRM table request failed: {e}")

    return None


def get_osrm_route_geometry(
    ordered_coords: List[Tuple[float, float]]
) -> Optional[Tuple[List[List[float]], float, float]]:
    """
    Query OSRM route service to get the actual road-network geometry.
    Returns (list_of_[lat, lng], total_distance_meters, total_duration_seconds) or None.
    """
    if len(ordered_coords) < 2:
        return None

    formatted_coords = ";".join(f"{round(lng, 6)},{round(lat, 6)}" for lat, lng in ordered_coords)
    url = OSRM_ROUTE_URL.format(coords=formatted_coords)

    try:
        resp = requests.get(
            url,
            params={
                "overview": "full",
                "geometries": "geojson",
                "steps": "false",
            },
            timeout=OSRM_TIMEOUT_SECONDS,
            headers={"User-Agent": "KisanRider-RouteEngine/1.0"},
        )
        if resp.status_code == 200:
            data = resp.json()
            if data.get("code") == "Ok" and data.get("routes"):
                best_route = data["routes"][0]
                dist_m = float(best_route.get("distance", 0.0))
                dur_s = float(best_route.get("duration", 0.0))
                geom = best_route.get("geometry", {}).get("coordinates", [])
                # GeoJSON coordinates are [lng, lat], convert to [lat, lng]
                lat_lng_polyline = [[round(pt[1], 6), round(pt[0], 6)] for pt in geom]
                return lat_lng_polyline, dist_m, dur_s
    except Exception as e:
        logger.warning(f"OSRM route geometry request failed: {e}")

    return None


def solve_tsp_ortools(
    distance_matrix: List[List[float]],
    start_index: int,
    end_index: int,
) -> List[int]:
    """
    Solves TSP with a fixed start and fixed end using Google OR-Tools.
    Returns the ordered list of node indices from start to end.
    """
    num_nodes = len(distance_matrix)
    if num_nodes <= 2:
        return list(range(num_nodes))

    # OR-Tools expects integer transit values
    scale_factor = 100
    int_matrix = [
        [int(round(d * scale_factor)) for d in row]
        for row in distance_matrix
    ]

    manager = pywrapcp.RoutingIndexManager(num_nodes, 1, [start_index], [end_index])
    routing = pywrapcp.RoutingModel(manager)

    def distance_callback(from_index: int, to_index: int) -> int:
        from_node = manager.IndexToNode(from_index)
        to_node = manager.IndexToNode(to_index)
        return int_matrix[from_node][to_node]

    transit_callback_index = routing.RegisterTransitCallback(distance_callback)
    routing.SetArcCostEvaluatorOfAllVehicles(transit_callback_index)

    search_parameters = pywrapcp.DefaultRoutingSearchParameters()
    search_parameters.first_solution_strategy = (
        routing_enums_pb2.FirstSolutionStrategy.PATH_CHEAPEST_ARC
    )
    search_parameters.local_search_metaheuristic = (
        routing_enums_pb2.LocalSearchMetaheuristic.GUIDED_LOCAL_SEARCH
    )
    search_parameters.time_limit.seconds = 2

    solution = routing.SolveWithParameters(search_parameters)

    if solution:
        ordered_nodes = []
        index = routing.Start(0)
        while not routing.IsEnd(index):
            ordered_nodes.append(manager.IndexToNode(index))
            index = solution.Value(routing.NextVar(index))
        ordered_nodes.append(manager.IndexToNode(index))
        return ordered_nodes

    # Fallback to direct sequence if solver fails
    nodes = [start_index]
    nodes.extend([i for i in range(num_nodes) if i != start_index and i != end_index])
    nodes.append(end_index)
    return nodes


def optimize_pool_route(
    rider_lat: float,
    rider_lng: float,
    dropoff_lat: float,
    dropoff_lng: float,
    dropoff_name: str,
    farmers: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Calculates the shortest road pickup sequence:
    Rider -> Stop 1 -> Stop 2 -> ... -> Stop N -> Dropoff Mandi.

    Each farmer dict contains:
    - id: UUID or str (member id)
    - farmer_name: str
    - crop_type: str
    - weight_kg: float
    - pickup_address: str
    - pickup_landmark: Optional[str]
    - lat: Optional[float]
    - lng: Optional[float]
    - requested_pickup_at: Optional[datetime]
    """
    total_weight_kg = sum(float(f.get("weight_kg") or 0.0) for f in farmers)

    # Separate farmers with coordinates vs missing coordinates
    farmers_with_coords = []
    farmers_missing_coords = []
    for f in farmers:
        if f.get("lat") is not None and f.get("lng") is not None:
            farmers_with_coords.append(f)
        else:
            farmers_missing_coords.append(f)

    # Node 0: Rider start
    # Node 1..M: Farmers with coords
    # Node M+1: Destination
    ordered_farmer_items: List[Dict[str, Any]] = []
    route_geometry: List[List[float]] = []
    total_distance_km = 0.0
    estimated_duration_minutes = 0.0
    routing_provider = "OR-Tools + OSRM Road Network"
    routing_status = "OPTIMIZED"
    warning = None

    if not farmers_with_coords:
        # No farmers have valid coordinates
        ordered_farmer_items = [
            {**f, "sequence": idx + 1, "has_coordinates": False}
            for idx, f in enumerate(farmers)
        ]
        return {
            "rider_start": {"lat": rider_lat, "lng": rider_lng, "label": "Rider Location"},
            "destination": {"lat": dropoff_lat, "lng": dropoff_lng, "name": dropoff_name},
            "ordered_stops": ordered_farmer_items,
            "total_weight_kg": total_weight_kg,
            "total_distance_km": 0.0,
            "estimated_duration_minutes": 0.0,
            "route_geometry": [],
            "routing_provider": "None",
            "routing_status": "NO_COORDINATES",
            "warning": "Participating farmers do not have geographic coordinates recorded.",
        }

    points = [(rider_lat, rider_lng)]
    for f in farmers_with_coords:
        points.append((float(f["lat"]), float(f["lng"])))
    points.append((dropoff_lat, dropoff_lng))

    start_idx = 0
    end_idx = len(points) - 1

    # Attempt to retrieve road distance matrix via OSRM
    osrm_res = get_osrm_distance_matrix(points)
    used_osrm = False

    if osrm_res is not None:
        dist_matrix, dur_matrix = osrm_res
        used_osrm = True
    else:
        # Fallback to Haversine distance matrix
        dist_matrix = []
        for i in range(len(points)):
            row = []
            for j in range(len(points)):
                row.append(
                    haversine_distance_meters(
                        points[i][0], points[i][1], points[j][0], points[j][1]
                    )
                )
            dist_matrix.append(row)
        routing_provider = "OR-Tools + Haversine (OSRM Unreachable)"
        routing_status = "APPROXIMATED"
        warning = "Road network routing service is currently unavailable. Sequence optimized using direct geographical distance."

    # Solve TSP
    solved_order = solve_tsp_ortools(dist_matrix, start_idx, end_idx)

    # Reconstruct the ordered farmer list
    ordered_coords: List[Tuple[float, float]] = []
    seq = 1
    for node_idx in solved_order:
        ordered_coords.append(points[node_idx])
        if node_idx != start_idx and node_idx != end_idx:
            # Farmer node
            farmer_item = farmers_with_coords[node_idx - 1]
            ordered_farmer_items.append({
                **farmer_item,
                "sequence": seq,
                "has_coordinates": True,
            })
            seq += 1

    # Append any farmers with missing coordinates at the end with clear flag
    for f in farmers_missing_coords:
        ordered_farmer_items.append({
            **f,
            "sequence": seq,
            "has_coordinates": False,
        })
        seq += 1

    # Fetch road geometry for the solved sequence
    if used_osrm:
        route_res = get_osrm_route_geometry(ordered_coords)
        if route_res is not None:
            route_geometry, dist_m, dur_s = route_res
            total_distance_km = round(dist_m / 1000.0, 2)
            estimated_duration_minutes = round(dur_s / 60.0, 1)
        else:
            # Approximate from matrix
            total_m = sum(
                dist_matrix[solved_order[i]][solved_order[i + 1]]
                for i in range(len(solved_order) - 1)
            )
            total_distance_km = round(total_m / 1000.0, 2)
            estimated_duration_minutes = round((total_distance_km / 35.0) * 60.0, 1)
            route_geometry = [[round(lat, 6), round(lng, 6)] for lat, lng in ordered_coords]
    else:
        total_m = sum(
            dist_matrix[solved_order[i]][solved_order[i + 1]]
            for i in range(len(solved_order) - 1)
        )
        total_distance_km = round(total_m / 1000.0, 2)
        estimated_duration_minutes = round((total_distance_km / 35.0) * 60.0, 1)
        route_geometry = [[round(lat, 6), round(lng, 6)] for lat, lng in ordered_coords]

    return {
        "rider_start": {
            "lat": rider_lat,
            "lng": rider_lng,
            "label": "Rider Location",
        },
        "destination": {
            "lat": dropoff_lat,
            "lng": dropoff_lng,
            "name": dropoff_name,
        },
        "ordered_stops": ordered_farmer_items,
        "total_weight_kg": round(total_weight_kg, 2),
        "total_distance_km": total_distance_km,
        "estimated_duration_minutes": estimated_duration_minutes,
        "route_geometry": route_geometry,
        "routing_provider": routing_provider,
        "routing_status": routing_status,
        "warning": warning,
    }
