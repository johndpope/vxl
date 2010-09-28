#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable

/////////////////////////////////////////////////////////////////
////Refine Tree (refines local tree)
////Depth first search iteration of the tree (keeping track of node level)
////1) parent pointer, 2) child pointer 3) data pointer 4) nothing right now
// Kind of a wierd mix of functions - the tree structure is modified locally, 
// so no tree_buffer information is needed, whereas the data is modified 
// on the global level, so buffers, offsets are used
/////////////////////////////////////////////////////////////////
int refine_tree(__constant RenderSceneInfo * linfo, 
                __local    uchar16         * unrefined_tree,
                __local    uchar16         * refined_tree,
                           int               tree_size, 
                           int               blockIndex,
                __global   float           * alpha_array,
                           float             prob_thresh, 
                __local    uchar           * cumsum, 
                __constant uchar           * bit_lookup,       // used to get data_index
                __global   float           * output)
{
  unsigned gid = get_group_id(0);
  unsigned lid = get_local_id(0);

  //max alpha integrated
  float max_alpha_int = (-1)*log(1.0 - prob_thresh);      
  int cumIndex = 1;
  int numSplit = 0;
  
  //no need to do depth first search, just iterate and check each node along the way
  int currByte = 0;
  for(int i=0; i<585; i++) {
    
    //if current bit is 0 and parent bit is 1, you're at a leaf
    int pi = (i-1)>>3;           //Bit_index of parent bit    
    bool validParent = tree_bit_at(unrefined_tree, pi) || (i==0); // special case for root
    if(validParent && tree_bit_at(unrefined_tree, i)==0) {
      
      //////////////////////////////////////////////////
      //LEAF CODE HERE
      //////////////////////////////////////////////////
      //find side length for cell of this level = block_len/2^currlevel
      int currLevel = get_depth(i);
      float side_len = linfo->block_len/(float) (1<<currLevel);
     
      //get alpha value for this cell;
      int dataIndex = data_index_opt2(unrefined_tree, i, bit_lookup, cumsum, &cumIndex); //gets offset within buffer
      float alpha   = alpha_array[gid*linfo->data_len + dataIndex];
         
      //integrate alpha value
      float alpha_int = alpha * side_len;
      
      //IF alpha value triggers split, tack on 8 children to end of tree array
      if(alpha_int > max_alpha_int && currLevel < linfo->root_level)  {
       
        //change value of bit_at(i) to 1;
        set_tree_bit_at(refined_tree, i, true);
       
        //keep track of number of nodes that split
        numSplit++;
        output[gid]++;
      }
      ////////////////////////////////////////////
      //END LEAF SPECIFIC CODE
      ////////////////////////////////////////////
      
    }
  }
  
  //tree and data size output
  tree_size += numSplit * 8;
  return tree_size;
}

 
///////////////////////////////////////////
//REFINE MAIN
//TODO include CELL LEVEL SOMEHOW to make sure cells don't over split
//TODO include a debug print string at the end to know what the hell is going on.
///////////////////////////////////////////
__kernel
void
refine_bit_scene(__constant  RenderSceneInfo    * linfo,
                 __global    ushort2            * mem_ptrs,         // denotes occupied space in each data buffer
                 __global    ushort             * blocks_in_buffers,// number of blocks in each buffers
                
                 __global    int4               * tree_array,       // tree structure for each block
                 __global    float              * alpha_array,      // alpha for each block
                 __global    uchar8             * mixture_array,    // mixture for each block
                 __global    ushort4            * num_obs_array,    // num obs for each block
                 
                 __constant  uchar              * bit_lookup,       // used to get data_index
                 __local     uchar              * cumsum,           // cumulative sum helper for data pointer
                 __local     uchar16            * local_tree,       // cache current tree into local memory
                 __local     uchar16            * refined_tree,     // refined tree (need old tree to move data over)
                  
                 __private   float                prob_thresh,    //refinement threshold
                 __global    float              * output)        //TODO delete me later
{

  //global id will be the tree buffer
  unsigned gid = get_group_id(0);
  unsigned lid = get_local_id(0);
      
  //go through the tree array and refine it...
  if(gid < linfo->num_buffer) 
  {
    output[gid] == 0.0;

    //cache some buffer variables in registers:
    int numBlocks = convert_int(blocks_in_buffers[gid]); //number of blocks in this buffer;
    int startPtr  = convert_int(mem_ptrs[gid].x);         //points to first element in data buffer
    int endPtr    = convert_int(mem_ptrs[gid].y);         //points to TWO after the last element in data buffer

    //get the (absolute) index of the start and end pointers
    int preRefineStart = startPtr;
    int preRefineEnd   = endPtr;
    
    //Iterate over each tree in buffer=gid      
    for(int i=0; i<numBlocks; i++) {
      
      //---- special case that may not be necessary ----------------------------
      //0. if there aren't 585 cells in this buffer, quit refining 
      int preFreeSpace = (startPtr >= endPtr) ? startPtr-endPtr : linfo->data_len - (endPtr-startPtr);
      if(preFreeSpace < 585) {
        output[gid] = -665;       
        mem_ptrs[gid].x = startPtr;   //store mem pointers before breaking
        mem_ptrs[gid].y = endPtr;     //store mem pointers before breaking
        break;
      }
      //------------------------------------------------------------------------

      
      //1. get current tree information
      (*local_tree)    = as_uchar16(tree_array[gid*linfo->tree_len + i]);
      (*refined_tree)  = (*local_tree);
      int currTreeSize = num_cells(local_tree);
         
      //initialize cumsum buffer and cumIndex
      cumsum[0] = (*local_tree).s0;                     

      //2. determine number of data cells used, datasize = occupied space
      int dataSize = (endPtr > startPtr)? (endPtr-1)-startPtr: linfo->data_len - (startPtr-endPtr)-1;

      //3. refine tree locally (only updates refined_tree and returns new tree size)
      int newSize = refine_tree(linfo, 
                                local_tree,
                                refined_tree, 
                                currTreeSize, 
                                i,
                                alpha_array,
                                prob_thresh, 
                                cumsum,
                                bit_lookup,
                                output);

                                
      //4. update start pointer (as data will be moved up to the end)
      startPtr = (startPtr+currTreeSize)%linfo->data_len;
      
      //5. if there's enough space, move tree
      int freeSpace = (startPtr >= endPtr)? startPtr-endPtr : linfo->data_len - (endPtr-startPtr);
      
/*
      //5.5 if the tree was refined (and it fits) (This TO BE COMBINED WITH BELOW - whtehter or not tree was refined doesn't matter_)
      if(newSize <= freeSpace) {
        
        //6a. update local tree's data pointer (store it back tree buffer)
        ushort buffOffset = (endPtr-1 + linfo->data_len)%linfo->data_len;
        uchar hi = (uchar)(buffOffset >> 8);
        uchar lo = (uchar)(buffOffset & 255);
        (*refined_tree).a = hi; 
        (*refined_tree).b = lo;
        if(newSize > currTreeSize)
          tree_array[gid*linfo->tree_len + i] = as_int4((*refined_tree));
        
        //load data into local memory one at a time, reformat it, and put it back
        // or figure out a data index scheme so that you can rifle through each node... 
        int cumIndex  = 1;
        int oldDataPtr = data_index_opt2(local_tree, 0, bit_lookup, cumsum, &cumIndex); //old root offset within buffer
        int newDataPtr = convert_int(buffOffset);                                       //new root offset within buffer
        
        //next start moving cells
        int offset = gid*linfo->data_len;                   //absolute buffer offset
        float max_alpha_int = (-1)*log(1.0 - prob_thresh);  //used for new leaves...
        for(int j=0; j<585; j++) {

          //--------------------------------------------------------------------
          //4 Cases:
          // - Old cell and new cell exist - transfer data over
          // - new cell exists, old cell doesn't - create new occupancy based on depth
          // - old cell exists, new cell doesn't - uh oh this is bad news
          // - neither cell exists - do nothing and carry on
          //--------------------------------------------------------------------
          //if parent bit is 1, then you're a valid cell
          int pj = (j-1)>>3;           //Bit_index of parent bit    
          bool validCellOld = tree_bit_at(local_tree, pj) || (i==0); 
          bool validCellNew = tree_bit_at(refined_tree, pj) || (i==0); 
          if(validCellOld && validCellNew) {
        
            //move root data to new location
            alpha_array[offset + newDataPtr]   = alpha_array[offset + oldDataPtr];
            mixture_array[offset + newDataPtr] = mixture_array[offset + oldDataPtr];
            num_obs_array[offset + newDataPtr] = num_obs_array[offset + oldDataPtr];

            //increment 
            oldDataPtr = (oldDataPtr+1)%linfo->data_len;
            newDataPtr = (newDataPtr+1)%linfo->data_len;
          } 
          //case where it's a new leaf...
          else if(validCellNew) {
            int currLevel = get_depth(j);
            float side_len = linfo->block_len/(float) (1<<currLevel);
            float new_alpha = max_alpha_int / side_len;  
            alpha_array[offset+newDataPtr] = new_alpha;
            mixture_array[offset+newDataPtr] = (uchar8) 0;
            num_obs_array[offset+newDataPtr] = (ushort4) 0;
            newDataPtr = (newDataPtr+1)%linfo->data_len;
          }          
          
        }
        
      }

      //otherwise it looks like the buffer is full, 
      else {
        //move start pointer back
        startPtr = (startPtr - currTreeSize + linfo->data_len)%linfo->data_len;
        output[gid] = -666;         //signal for buffer full
        mem_ptrs[gid].x = startPtr;
        mem_ptrs[gid].y = endPtr; 
        break;
      }
*/

    } //end for loop

    //update mem pointers before returning
    mem_ptrs[gid].x = startPtr;
    mem_ptrs[gid].y = endPtr; 
    
  } //end if(gid < num_buffer)
  
}

 
 
 
