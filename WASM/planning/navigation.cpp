#include "planning/navigation.h"

namespace planning {



    void initial_spin();

    
    bool find_frontiers(std::vector<Frontier>& frontiers){

        const int num_found = 0;

        return num_found > 0;
    }
    Cluster cluster_frontiers(
        std::vector<Frontier>& frontiers)
    {

    }
    
    void explore_full_map(){
        // wait for init conditions to be satisfied:
        // lidar is active
        // wheel odom is active

        initial_spin();

        std::vector<Frontier> frontiers;
        // clusters
        Cluster largest_cluster;

        while(find_frontiers(frontiers)){
            largest_cluster = cluster_frontiers(frontiers);

            // navigate (check feasibility)

            //spin
        }
        
        // A* plan to largest cluster
    }
}; //namespace planning