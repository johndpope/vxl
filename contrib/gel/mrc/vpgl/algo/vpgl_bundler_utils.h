#ifndef VPGL_BUNDLER_UTILS_H
#define VPGL_BUNDLER_UTILS_H
//:
// \file

#include <vcl_vector.h>

#include <vgl/vgl_point_2d.h>
#include <vgl/vgl_point_3d.h>

#include <vnl/vnl_double_3x3.h>

#include <vpgl/vpgl_perspective_camera.h>
#include <vpgl/algo/vpgl_bundler_inters.h>


// Generally useful function used for RANSAC.
// Randomly chooses n distinct indices into the set
void vpgl_bundler_utils_get_distinct_indices(
    int n, int *idxs, int number_entries);

// Takes in a list of points and
// cameras, and finds the least-squared solution to the intersection
// of the rays generated by the points.
double vpgl_bundler_utils_triangulate_points(
    vpgl_bundler_inters_3d_point &point,
    const vcl_vector<vpgl_bundler_inters_camera> &cameras);

// Takes in four matched points, and fills a 3x3 homography matrix
// Uses the direct linear transform method
void vpgl_bundler_utils_get_homography(
    const vcl_vector<vgl_point_2d<double> > &rhs,
    const vcl_vector<vgl_point_2d<double> > &lhs,
    vnl_double_3x3 &homography);

// Estimates a homography and returns the percentage of inliers
double vpgl_bundler_utils_get_homography_inlier_percentage(
    const vpgl_bundler_inters_match_set &match, 
    double threshold_squared, int num_rounds);


#endif /*VPGL_BUNDLER_UTILS*/