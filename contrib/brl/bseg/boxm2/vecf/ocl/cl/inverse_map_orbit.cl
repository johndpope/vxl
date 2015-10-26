#pragma OPENCL EXTENSION cl_khr_local_int32_base_atomics: enable
#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics: enable


__kernel void map_to_source_and_extract_appearance(  __constant  float           * centerX,//0
                                                     __constant  float           * centerY,//1
                                                     __constant  float           * centerZ,//2
                                                     __constant  uchar           * bit_lookup,//3             //0-255 num bits lookup table
                                                     __global  RenderSceneInfo   * target_scene_linfo,//4
                                                     __global  RenderSceneInfo   * source_scene_linfo,//5
                                                     __global    int4            * target_scene_tree_array,//6       // tree structure for each block
                                                     __global    int4            * source_scene_tree_array,//9       // tree structure for each block
                                                     __global    float           * target_scene_alpha_array,//10      // alpha for each block
                                                     __global    uchar8          * target_rgb_array,
                                                     __global    float           * target_vis_array,


                                                     __global    uchar8          * source_rgb_array,
                                                     //                                          __global    ushort4         * source_nobs_array,
                                                     __global    float           * rotation,//13
                                                     __global    float           * other_rotation,//13
                                                     __global    float           * translation,//12
                                                     __global    float           * other_translation,//12
                                                     __global    uchar           * sphere,
                                                     __global    uchar           * iris,
                                                     __global    uchar           * pupil,
                                                     __global    uchar           * eyelid,
                                                     __global    uchar           * eyelid_crease,
                                                     __global    uchar           * lower_lid,
                                                     //at which voxels should be matched.
                                                     __global    float           * output,//16
                                                     __global    float           * eyelid_geo,//16
#ifdef ANATOMY_CALC
                                                     __global    float           * vis_accum,
#else
                                                     __global    float8          * total_app,
#endif
                                                     __global    float8          * mean_app,
                                                     __global    uchar           * is_right,
                                                     __local     uchar           * cumsum_wkgp,//17
                                                     __local     uchar16         * local_trees_target,//18
                                                     __local     uchar16         * local_trees_source,
                                                     __local     uchar16         * reflected_local_trees_target,//18
                                                     __local     uchar16         * neighbor_trees)//20
{
  int gid = get_global_id(0);
  int lid = get_local_id(0);
  //default values for empty cells
  MOG_INIT(mog_init);

  //-log(1.0f - init_prob)/side_length  init_prob = 0.001f
  float alpha_init = 0.001f/target_scene_linfo->block_len;

  //
  int numTrees = source_scene_linfo->dims.x * source_scene_linfo->dims.y * source_scene_linfo->dims.z;
  float4 target_scene_origin = target_scene_linfo->origin;
  float4 target_scene_blk_dims = convert_float4(target_scene_linfo->dims) ;
  float4 target_scene_maxpoint = target_scene_origin + convert_float4(target_scene_linfo->dims) * target_scene_linfo->block_len ;
  //: each thread will work on a sub_block(tree) of source to match it to locations in the source block
  if (gid < numTrees) {
    local_trees_source[lid] = as_uchar16(source_scene_tree_array[gid]);
    int index_x =(int)( (float)gid/(source_scene_linfo->dims.y * source_scene_linfo->dims.z));
    int rem_x   =( gid- (float)index_x*(source_scene_linfo->dims.y * source_scene_linfo->dims.z));
    int index_y = rem_x/source_scene_linfo->dims.z;
    int rem_y =  rem_x - index_y*source_scene_linfo->dims.z;
    int index_z =rem_y;
    if((index_x >= 0 &&  index_x <= source_scene_linfo->dims.x -1 &&
        index_y >= 0 &&  index_y <= source_scene_linfo->dims.y -1 &&
        index_z >= 0 &&  index_z <= source_scene_linfo->dims.z -1  )) {
      __local uchar16* local_tree = &local_trees_source[lid];
      __local uchar16* neighbor_tree = &neighbor_trees[lid];
      __local uchar * cumsum = &cumsum_wkgp[lid*10];
      __local Eyelid eyelid_param;
      eyelid_from_float_arr(&eyelid_param,eyelid_geo);
      __local OrbitLabels orbit;
      orbit.sphere = sphere; orbit.iris = iris; orbit.pupil = pupil;
      orbit.lower_lid = lower_lid; orbit.eyelid = eyelid; orbit.eyelid_crease = eyelid_crease;
      // iterate through leaves
      cumsum[0] = (*local_tree).s0;
      int cumIndex = 1;
      int MAX_INNER_CELLS, MAX_CELLS,MAX_INNER_CELLS_TARGET,MAX_CELLS_TARGET;
      get_max_inner_outer(&MAX_INNER_CELLS, &MAX_CELLS, source_scene_linfo->root_level);
      get_max_inner_outer(&MAX_INNER_CELLS_TARGET, &MAX_CELLS_TARGET, target_scene_linfo->root_level);
      for (int i=0; i<MAX_CELLS; i++) {
        //if current bit is 0 and parent bit is 1, you're at a leaf
        int pi = (i-1)>>3;           //Bit_index of parent bit
        bool validParent = tree_bit_at(local_tree, pi) || (i==0); // special case for root
        int currDepth = get_depth(i);
        if (validParent && ( tree_bit_at(local_tree, i)==0 )) {

          //: for each leaf node xform the cell and find the correspondence in another block.
          //get the index into this cell data
          int source_data_index = data_index_cached(local_tree, i, bit_lookup, cumsum, &cumIndex) + data_index_root(local_tree); //gets absolute position
          // set intial values in case source is not accessed
          /* source_scene_mog_array[source_data_index] = mog_init; */
          /* source_scene_alpha_array[source_data_index] = alpha_init; */
          // transform coordinates to source scene
          float xg = source_scene_linfo->origin.x + ((float)index_x+centerX[i])*source_scene_linfo->block_len ;
          float yg = source_scene_linfo->origin.y + ((float)index_y+centerY[i])*source_scene_linfo->block_len ;
          float zg = source_scene_linfo->origin.z + ((float)index_z+centerZ[i])*source_scene_linfo->block_len ;


          float4 offset             = (float4)(translation[0],translation[1],translation[2],0) ;
          float4 other_offset       = (float4)(other_translation[0],other_translation[1],other_translation[2],0) ;
          float4 source_p           = (float4)(  xg, yg, zg,0);
          float4 source_p_refl      = (float4)( -xg, yg, zg,0);
          float4 cell_center, cell_center_refl,target_p,target_p_refl;
          unsigned target_data_index, bit_index, target_data_index_refl, bit_index_refl;
          unsigned point_ok,r_point_ok;   int lidvoxel = 0;
          float8 blank_val = (float8)(255,0,148,0,0,0,0,0);
          cell_center.s3=0;
          if(sphere[source_data_index] && !eyelid[source_data_index] )
              {
                target_p      = rotate_point(source_p,rotation)             + offset;
                target_p_refl = rotate_point(source_p_refl,other_rotation)  + other_offset;
                //these don't
              }
            else if((eyelid[source_data_index]) && !sphere[source_data_index]){
              float4 upper_lid_p = is_right[0] ? source_p_refl : source_p;
              target_p = !is_right[0] ?  source_p + offset : source_p_refl + offset;
              target_p_refl = (float4)( - target_p.x, target_p.y, target_p.z, 0);
              float t = compute_t(upper_lid_p.x,upper_lid_p.y,&eyelid_param);
              if(!is_valid_t( t - 0.95, &eyelid_param)){
                lidvoxel = 1;
              }
            }else if ( (eyelid[source_data_index] || lower_lid[source_data_index] || eyelid_crease[source_data_index])){
              target_p = !is_right[0] ?  source_p + offset : source_p_refl + offset;
              target_p_refl = (float4)( - target_p.x, target_p.y, target_p.z, 0);
            }else{
              source_rgb_array[source_data_index] = convert_uchar8(blank_val);
              continue;
}
            point_ok = data_index_world_point(target_scene_linfo, target_scene_tree_array,
                                              local_trees_target,lid,target_p,
                                              &cell_center,
                                              &target_data_index,
                                              &bit_index,bit_lookup);
            r_point_ok = data_index_world_point(target_scene_linfo,  target_scene_tree_array,
                                                reflected_local_trees_target,lid,target_p_refl,
                                                &cell_center_refl,
                                                &target_data_index_refl,
                                                &bit_index_refl,bit_lookup);
#ifdef ANATOMY_CALC
          output[source_data_index] = source_scene_linfo->root_level;
#endif
          if(bit_index >=0 && bit_index < MAX_CELLS_TARGET ){
            if(point_ok && r_point_ok){
            int currDepth = get_depth(bit_index);
            float cell_len = 1.0f/((float)(1<<currDepth));
            float vis_A = target_vis_array[target_data_index];
            float vis_B = target_vis_array[target_data_index_refl];
            float8 color_A =  convert_float8(target_rgb_array[target_data_index]);
            float8 color_B =  convert_float8(target_rgb_array[target_data_index_refl]);
            float8 mean_val = (float8)(29,255,107,0,0,0,0,0);
            //            output[source_data_index] = vis_A;


#ifdef ANATOMY_CALC
            if(is_anatomy(SPHERE,source_data_index, &orbit)){
              AtomicAdd(&vis_accum[SPHERE],vis_A);
              AtomicAddFloat8(&mean_app [SPHERE],color_A * vis_A);      }

            if(is_anatomy(IRIS,source_data_index, &orbit)){
              AtomicAdd(&vis_accum[IRIS],vis_A);
              AtomicAddFloat8(&mean_app [IRIS],color_A * vis_A);         }

            if(is_anatomy(PUPIL,source_data_index,&orbit)){
              AtomicAdd(&vis_accum[PUPIL],vis_A);
              AtomicAddFloat8(&mean_app [PUPIL],color_A * vis_A);        }

            if(is_anatomy(LOWER_LID,source_data_index,&orbit)){
              AtomicAdd(&vis_accum[LOWER_LID],vis_A);
              AtomicAddFloat8(&mean_app [LOWER_LID],color_A * vis_A);    }

            if(is_anatomy(EYELID_CREASE,source_data_index, &orbit)){
              AtomicAdd(&vis_accum[EYELID_CREASE],vis_A);
              AtomicAddFloat8(&mean_app [EYELID_CREASE],color_A * vis_A);}

            if(is_anatomy(EYELID, source_data_index, &orbit)){
              float prob = 1 - exp( -target_scene_alpha_array[target_data_index] * cell_len * target_scene_linfo->block_len);
              if(prob > 0.8){
                AtomicAdd(&vis_accum[EYELID],vis_A);
                AtomicAddFloat8(&mean_app [EYELID],color_A * vis_A);               }
            }
#else
            int anatomy = 1;

            if(is_anatomy(SPHERE,source_data_index, &orbit)){
              mean_val = total_app[0];
            }else if(is_anatomy(IRIS,source_data_index, &orbit)){
                mean_val = total_app[1];
            }else if(is_anatomy(PUPIL,source_data_index,&orbit)){
                  mean_val = total_app[2];
            }else if(is_anatomy(LOWER_LID,source_data_index,&orbit)){
                    mean_val = total_app[4];
            }else if(is_anatomy(EYELID_CREASE,source_data_index, &orbit)){
              mean_val = total_app[5];
            }else   if(is_anatomy(EYELID, source_data_index, &orbit)){
              if( lidvoxel){
                float4 upper_lid_p = is_right[0] ? source_p_refl : source_p;
                float t = compute_t(upper_lid_p.x,upper_lid_p.y,&eyelid_param);
                mean_val = (0.96 - t) * total_app[5] + t * total_app[4]; //blend between crease and lower lid;

              }
              else
                mean_val = mean_app [3]; //actual upper lid color
            }


            source_rgb_array[source_data_index] = convert_uchar8(weight_appearance(vis_A,vis_B,color_A,color_B,mean_val));
#endif

            // here is where interp magic happens
                        //#define DO_INTERP
#ifdef DO_INTERP
              float alphas[8];
              float params[8];
              float weights[12];
              float4 abs_neighbors[8];
              float4 rgb_params[8];

              float cell_len_rw  = cell_len * target_scene_linfo->block_len;
              int nbs_ok = collect_neighbors_and_weights(abs_neighbors,weights,target_p,cell_center, cell_len_rw);
              if(!nbs_ok)
                continue;
              int nb_count = 0; float sum = 0;
              for (unsigned i=0; i<8; i++){
                int neighborBitIndex, nb_data_index;
                float4 nb_cell_center;
                unsigned nb_point_ok = data_index_world_point(target_scene_linfo, target_scene_tree_array,
                                                              neighbor_trees,lid,abs_neighbors[i],
                                                              &nb_cell_center,
                                                              &nb_data_index,
                                                              &neighborBitIndex,bit_lookup);
                if (nb_point_ok){
                  alphas[i] = target_scene_alpha_array[nb_data_index] ;
                  nb_count++;
                  CONVERT_FUNC_FLOAT8(rgb_tuple,target_rgb_array[nb_data_index]);
                  rgb_tuple/=NORM;
                  rgb_params[i].s0123 = rgb_tuple.s0123;

                }else{
                  alphas[i] = 0.0; params[i]=0;
                }
              }

              // interpolate alpha over the source
              if(nb_count>0){
                float alpha_interped = interp_generic_float(abs_neighbors,alphas,target_p);
                uchar8 curr_rgb_tuple = target_rgb_array[target_data_index];
                float4 float_rgb_tuple_interped  = interp_float4(abs_neighbors,rgb_params,target_p); //use the flow interp for float4s
                uchar4 uchar_rgb_tuple_interped  = convert_uchar4_sat_rte(float_rgb_tuple_interped * NORM); // hack-city
                curr_rgb_tuple.s0123 = uchar_rgb_tuple_interped;
                source_rgb_array[source_data_index] = curr_rgb_tuple;}
#endif //interp
            }
          }
        }
      }
    }
  }
}
