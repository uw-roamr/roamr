#pragma once
#include <vector>

// frontier exploration algorithm

// start by spinning to generate initial map

// in a loop (until no frontiers are found):
// find all frontiers
// cluster frontiers
// find largest unexplored cluster
// path plan to centroid of said cluster
// spin

namespace planning{

    struct Frontier{
        double x, y;
    };

    struct Cluster{
        std::vector<Frontier&> frontiers;
    };

    void initial_spin();


    bool find_frontiers();
    void cluster_frontiers();
    // A* plan to largest cluster

    void explore_full_map();

}; // namespace controls
