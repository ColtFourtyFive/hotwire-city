"""Archetype parameter sets. Every number is in studs; +Y is the nose, ground is Z = 0.

A spec is a flat dict. `derive(base, **overrides)` copies a spec and overrides keys.
Profiles given as `*_pts` are lists of (y, value) control points for a monotone cubic.
"""
from __future__ import annotations

import copy


def derive(base, **kw):
    s = copy.deepcopy(base)
    s.update(kw)
    return s


# ---------------------------------------------------------------------------------------------
# SEDAN: 4-door, notch/fastback, the city's everyman car.
# ---------------------------------------------------------------------------------------------
SEDAN = dict(
    name="sedan",
    doors=4,
    length=16.6, width=7.0,
    axle_f=5.05, axle_r=-4.85,
    wheel_r=1.36, tire_w=1.12, rim_ratio=0.66, track_in=0.12, spokes=5, rim_style="split5",
    arch_r=1.6,
    ground=0.74, front_lift=0.34, rear_lift=0.42, rocker_h=0.48,
    rocker_tuck=0.2, bottom_in=0.32, shoulder_tuck=0.1,
    taper_f=0.22, taper_r=0.12,
    flare_f=0.10, flare_r=0.14, flare_len=1.0,
    side_peak=0.12,
    # greenhouse stations
    cowl_y=3.45, roof_front_y=0.95, roof_rear_y=-3.25, deck_y=-5.55,
    shoulder_pts=[(-8.3, 3.22), (-6.0, 3.36), (-3.0, 3.33), (1.0, 3.28), (5.0, 3.12), (8.3, 2.86)],
    belt_pts=[(-8.3, 3.38), (-5.6, 3.62), (-3.0, 3.6), (1.0, 3.52), (3.45, 3.47), (5.4, 3.3), (8.3, 2.98)],
    top_pts=[(-8.3, 3.52), (-7.0, 3.66), (-5.55, 3.72), (-4.6, 4.38), (-3.25, 4.98), (-1.0, 5.14), (0.95, 5.06),
             (2.2, 4.32), (3.45, 3.56), (5.2, 3.32), (8.3, 3.02)],
    roof_hw_pts=[(-3.25, 2.28), (-1.2, 2.44), (0.95, 2.36)],
    hood_crown=0.10, roof_crown=0.20,
    ledge_hood=0.36, ledge_cabin=0.30, hood_edge_in=0.55, gh_bulge=0.05,
    r_bottom=0.16, r_rocker=0.12, r_shoulder=0.12, r_belt=0.07, r_roofedge=0.34, r_roofedge_hood=0.28,
    # ends
    nose_round_y=1.7, nose_round_x=1.25, nose_pow=2.0,
    nose_top_y=0.75, nose_top_z=0.36, nose_bot_y=0.4, nose_bot_z=0.22,
    tail_round_y=1.1, tail_round_x=0.85, tail_pow=2.3,
    tail_top_y=0.5, tail_top_z=0.22, tail_bot_y=0.32, tail_bot_z=0.2,
    nose_ramp=1.6, nose_sweep=0.38, nose_rake=0.10,
    tail_ramp=1.1, tail_sweep=0.22, tail_rake=0.04,
    nose_bulge=0.06, tail_bulge=0.04,
    cap_spacing=0.42,
    station_h=0.40, station_h_arch=0.25, station_h_feature=0.2, end_k=0.2,
)

ARCHETYPES = {
    "sedan": SEDAN,
}
